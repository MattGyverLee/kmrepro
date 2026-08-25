> **ARCHIVED 2026-08-25.** Superseded by `../TEST-PLAN.md`, which absorbed the
> unique content: the concrete gtest names and their red/green status (§3), the
> build/verification commands, the PCH and vcxproj-glob traps, and the manual-app
> procedure (§4). Kept only for the longer per-test rationale. Where the two
> disagree, `../TEST-PLAN.md` wins — this draft predates the Ross/#8064 framing
> and the cross-platform survey.

# Port the kmrepro stuck-modifier findings into Keyman's own test structure

## Context

`kmrepro` is a PowerShell investigation harness that proved, on this machine, that
Keyman for Windows 18.0.249 can inject a **phantom modifier KEYDOWN with no matching
KEYUP**, latching a modifier system-wide until Keyman restarts. The evidence is strong
(deterministic 2/2–7/7 per key, three-arm controlled attribution, and a wire capture of
the unmatched KEYDOWN) but it lives in PowerShell scripts the Keyman team does not use,
driven through Notepad.

This plan moves that work into Keyman's repo in the two forms the team actually accepts:

1. **A manual Delphi test app** under `windows/src/test/manual-tests/` — the main dev's
   stated preference, and the form Marc Durdin himself used for this exact subject area
   in Oct 2025.
2. **Headless gtests** in the existing `keyman32` suite — cheap, no elevation, already
   wired into CI.

The E2E cost objection is real but does not apply to (2): that suite links the engine as
a **static library** into a console exe. See "Correcting the cost premise" below.

Two facts settle the scope up front:

- **Keyman Core cannot catch this bug.** Core never stores modifier or toggle state; the
  platform computes a `uint16_t` per key event and Core passes it straight through
  (`core/src/kmx/kmx_processor.cpp:263-296`; `core/src/state.hpp:216-218` — *"the
  combinations of modifier keys set at the time key [was pressed]"*). Core receives the
  wrong bit with no second source of truth. The one channel that could carry the truth is
  closed by contract: `core/include/keyman/keyman_core_api.h:1746` documents the
  `KM_CORE_EVENT_KEYBOARD_ACTIVATED` payload as *"Additional event-specific data.
  Currently unused, must be nullptr."* Core's *outbound* caps direction is already tested
  in `core/tests/unit/kmx/kmx_external_event.tests.cpp` against `k_0702___caps_always_off`.
- **`windows/src/test/unit-tests/README.md`** sets the bar for the automated suite:
  *"They should not have complex environmental requirements nor require an installed
  version of the software in order to complete."*

---

## The proof, anchored in Keyman's code

All paths relative to `windows/src/engine/keyman32/`. This is the section to lead a PR
or issue with; every step is a citation, not an inference.

### Step 1 — The low-level hook runs on keyman.exe's Delphi UI thread

```
keyman32.cpp:368   *Globals::FSingleThread() = GetWindowThreadProcessId(Handle, NULL);
keyman32.cpp:279   *Globals::hhookLowLevelKeyboardProc() =
                     SetWindowsHookExW(WH_KEYBOARD_LL, kmnLowLevelKeyboardProc,
                                       hinst, Globals::get_FSingleThread());
```

`Handle` is keyman.exe's main window. That thread also runs dialogs, COM and the updater.
Windows enforces `LowLevelHooksTimeout` (`HKCU\Control Panel\Desktop`): a hook that does
not return in time is **bypassed for that event**, and may be evicted. So a stall on that
thread means Keyman never sees the key event at all.

### Step 2 — Cache A is seeded once and never reconciled with the OS

```
serialkeyeventserver.cpp:51    BYTE m_ModifierKeyboardState[256];
serialkeyeventserver.cpp:251   GetKeyboardState(m_ModifierKeyboardState);   // in InitThread(), ONCE
serialkeyeventserver.cpp:554   void UpdateLocalModifierState(BYTE bVk, BOOL fIsExtendedKey,
                                                             BYTE bScan, BOOL fIsUp) {
serialkeyeventserver.cpp:581     m_ModifierKeyboardState[bVk] = fIsUp ? 0 : 0x80;
```

Line 581 is the **only** writer after the seed. It is reachable only from
`UpdateLocalModifierState`, which runs only on `WM_KEYMAN_MODIFIER_EVENT`. There is no
periodic resync, no re-read of `GetKeyboardState`, nothing.

### Step 3 — That message is the sole feed, and a stall drops it

```
k32_lowlevelkeyboardhook.cpp:200-201
  if (isModifierKey(hs->vkCode) && flag_ShouldSerializeInput) {
    PostMessage(ISerialKeyEventServer::GetServer()->GetWindow(),
                WM_KEYMAN_MODIFIER_EVENT, hs->vkCode, LLKHFFlagstoWMKeymanKeyEventFlags(hs));
  }
```

Combine with Step 1: **a UI-thread stall spanning a modifier KEYUP means that KEYUP's
post never happens, and `m_ModifierKeyboardState[VK_RCONTROL]` stays `0x80` while the key
is physically up.** That single stale byte is the entire residue of the delay — which is
why the delay itself never has to be simulated to test the consequence.

### Step 4 — Every injected batch re-presses whatever the cache believes

```
serialkeyeventserver.cpp:384   void PrepareInjectedInput() {
                                 m_nInputs = 0;
                                 keybd_shift(m_pInputs, &m_nInputs, FALSE, m_ModifierKeyboardState);
                                 ... payload ...
                                 keybd_shift(m_pInputs, &m_nInputs, TRUE,  m_ModifierKeyboardState);
```

```
keybd_shift.cpp:161   void keybd_shift_reset(LPINPUT pInputs, int *n, LPBYTE const kbd) {
                        const BYTE modifiers[6] = { VK_LMENU, VK_RMENU, VK_LCONTROL,
                                                    VK_RCONTROL, VK_LSHIFT, VK_RSHIFT };
                        for (int i = 0; i < _countof(modifiers); i++) {
                          if (kbd[modifiers[i]] & 0x80) {
                            do_keybd_event(pInputs, n, modifiers[i],
                                           SCAN_FLAG_KEYMAN_KEY_EVENT, 0, 0);   // KEYDOWN
```

`keybd_shift_release` (`:132`) emitted a KEYUP for the same key at the start of the batch
— harmless, it was already up. `keybd_shift_reset` then emits a **KEYDOWN with no matching
KEYUP**. That is the phantom press.

**Critically for testability: neither function calls `SendInput`.** They only fill an
`INPUT[]` array supplied by the caller. They are pure functions over a 256-byte state
array.

### Step 5 — For Right Ctrl, the emitted bytes are the ones Windows resolves to a key the machine may not have

```
keybd_shift.cpp:69-73
  case VK_RCONTROL:
    flags |= KEYEVENTF_EXTENDEDKEY;
    /*fallthrough*/
  case VK_LCONTROL:
    vk = VK_CONTROL;
    break;
```

`VK_CONTROL` + `KEYEVENTF_EXTENDEDKEY` is exactly Right Ctrl. Measured consequence
(`MODIFIERS.md` §3b): only the exact matching Right Ctrl KEYUP clears it — typing does
not, and tapping Left Ctrl does not. On hardware with no physical Right Ctrl key the user
cannot clear it at all. The dev machine used for kmrepro is that hardware class.

### Step 6 — The latch re-confirms itself

The modifier post at `:200` sits **32 lines before** the pass-through filter at `:233`:

```
k32_lowlevelkeyboardhook.cpp:229-234
  if (hs->dwExtraInfo != 0 ||
      hs->scanCode == SCAN_FLAG_KEYMAN_KEY_EVENT ||
      hs->vkCode == VK_PROCESSKEY ||
      hs->vkCode == VK_PACKET ||
      !isKeymanKeyboardActive) {
    // This key event was generated by Keyman, so pass it through
```

So Keyman's own phantom KEYDOWN is seen by its own hook and written back into Cache A as
`0x80`. Two consequences, both counter-intuitive and both worth stating explicitly in any
write-up:

- Cache A does not merely fail to refresh — it **re-confirms its own hallucination on
  every injected batch**.
- Because `:200` is not gated on `isKeymanKeyboardActive`, **Keyman updates its cached
  modifier state for every modifier keystroke on the machine, whether or not a Keyman
  keyboard is active.** "No Keyman keyboard was active, therefore Keyman is uninvolved"
  is invalid reasoning here. Measured: charging the wedge under the Microsoft Cameroon
  layout, then switching to Keyman once, corrupted output 3/3.

### Step 7 — Cache B: the separate, simpler defect (findings 4a/4b/4c)

Different cache, different symptom (wrong output, no OS key actually held).

```
capsstate.cpp:39            RefreshToggleState()      -> CAPITAL, NUMLOCK                (2 flags)
kmhook_getmessage.cpp:418   GetCapsAndNumlockState()  -> RefreshToggleState()
                                                         + K_SHIFT, L/RCTRL, L/RALT      (7 flags)
```

| trigger | handler | flags resynced |
|---|---|---|
| keyboard activated (`appint/aiTIP.cpp:67`, deferred to next key event at `:186` — this is #16422) | `RefreshToggleState()` | **2** |
| focus moves to another window (`kmhook_getmessage.cpp:357`) | `GetCapsAndNumlockState()` | **7** |

- **4a** — a keyboard switch resyncs Caps and Num but leaves `K_SHIFTFLAG`, `LCTRLFLAG`,
  `RCTRLFLAG`, `LALTFLAG`, `RALTFLAG` stale. Same bug, same cache, same trigger, one field
  over. The naming is why it was missed: the function that resyncs all five modifiers is
  called `GetCapsAndNumlockState`.
- **4b** — `kmhook_getmessage.cpp:423-436` tests modifiers with `GetKeyState(...) < 0`,
  which reports the **calling thread's processed input queue** — precisely the thing that
  is stale after events were dropped. `GetAsyncKeyState` is the correct oracle for "is
  this key physically down". Leave the `& 1` toggle reads on `GetKeyState`;
  `GetAsyncKeyState` does not report toggle state at all.
- **4c** — `ProcessModifierChange` (`kmhook_getmessage.cpp:450-457`) gives Shift one flag
  but Ctrl and Alt two each, so a left-side release cannot clear a right-side latch. Not a
  bug; it explains why field reports name RAlt and Right Ctrl. Belongs in the PR
  description, not in code.

---

## Deliverable 1 — the manual Windows test (primary)

### Where it goes

`windows/src/test/manual-tests/<name>/` — one directory per investigation. Per
`windows/src/test/manual-tests/README.md`: *"These tests are intended to be run manually,
so there is generally no build process included."* Nothing to register in any `build.sh`,
no CI wiring, no elevation.

**Naming.** Two live conventions; use the GitHub-era one:
- `GH-<issue> - <slug>` — e.g. `GH-140 - shift states`, `GH-4275 - contextex-mismatch-with-if`
- bare descriptive — e.g. `keyboard_ll_identifier`, `caps-lock-stores`

Proposed: **`GH-16423 - stuck-modifier-phantom-keydown`**.

### What to model it on

`windows/src/test/manual-tests/keyboard_ll_identifier/` — added by Marc Durdin,
`cb6063a954`, Oct 2025, `Relates-to: #14890`. It is already a minimal `kmaltgr.ps1`: a
Delphi VCL form installing `WH_KEYBOARD_LL` and filtering exactly the nine modifier VKs
that `isModifierKey()` accepts.

```pascal
if s.vkCode in [VK_LCONTROL, VK_RCONTROL, VK_LMENU, VK_RMENU, VK_LSHIFT, VK_RSHIFT,
                VK_CONTROL, VK_SHIFT, VK_MENU] then
  if Assigned(Form1) then
    Form1.memo1.Lines.Add(Format('%08.8x %08.8x %08.8x', [s.vkCode, s.scanCode, s.flags]));
```

Files to produce (mirroring that directory exactly):
`README.md`, `<name>.dpr`, `<name>.dproj`, `<name>_unit.pas`, `<name>_unit.dfm`.

The delay-simulation idiom also already exists in-tree and should be reused rather than
reinvented — `test_i5394 - modifiers out of sync/ui5394.pas` has a `chkShiftDelay`
checkbox that does `Sleep(500)` ×5 inside `FormKeyDown` while logging `GetKeyState` vs
`GetAsyncKeyState`; `test_i4793/test_i4793.pas` does `Sleep(500)` in `WM_KEYDOWN`.

### What it must add over `keyboard_ll_identifier`

Four things, each traceable to a step in the proof:

1. **`dwExtraInfo` and a decoded flags column.** The existing app logs `vkCode scanCode
   flags` only. The two markers that make the evidence readable are
   `scanCode = 0xFF` (`SCAN_FLAG_KEYMAN_KEY_EVENT`, `keyman64.h:132` — Keyman synthesized
   this) and `dwExtraInfo = 0x4B4D0000`
   (`EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT`, `keyman64.h:134` — Keyman replayed a real
   user keystroke). Decode `LLKHF_EXTENDED`/`LLKHF_INJECTED`/`LLKHF_UP`/`LLKHF_ALTDOWN`.
2. **Unmatched-KEYDOWN pairing.** Track each `scanCode = 0xFF` KEYDOWN and flag any with
   no later KEYUP of the same VK. This is the oracle that produced kmrepro's single most
   direct piece of evidence, and it is the pass/fail criterion for the whole test.
3. **A stall button** — post `WM_KEYMAN_CONTROL` cmd 20 (`KMC_WATCHDOG_FAKEFREEZE`) to
   keyman.exe, so the tester can induce the stall from inside the app instead of needing
   a second tool.
4. **A live `GetAsyncKeyState` panel** across the six Cache A modifiers plus the prefix VK
   (`Globals::get_vk_prefix()`, default `0x0E`, `aiTIP.h:36`), so a latch is visible
   without typing. Text oracles cannot see a stuck Ctrl (no case change, keys are
   swallowed) or the prefix VK (no app maps `0x0E`).

`README.md` must state the manual procedure and the expected vs observed result, in the
`caps-lock-stores/TestReadme.md` style.

> Note the app installs a global keyboard hook: **every keystroke on the machine is
> visible while it runs.** Say so in the README, as kmrepro's scripts do.

---

## Deliverable 2 — headless gtests (secondary, cheap)

### Correcting the cost premise

The elevation/expense objection is correct for E2E and does not apply here.
`windows/src/engine/keyman32/build.sh:111-148`:

```bash
run_in_vs_env --quiet msbuild.exe keyman32.vcxproj ... "//p:Configuration=${Configuration} Static Library" ...
run_in_vs_env --quiet msbuild.exe tests/keyman32.tests.vcxproj ...
"./tests/bin/${Platform}/${Configuration}/keyman32.tests.exe"
```

Static library linked into a console exe. No elevation, no TSF, no installed Keyman, no
desktop, no Notepad. Already reached by `builder_run_child_actions` from
`windows/src/engine/build.sh:34` → `/windows/build.sh test` → TeamCity
(`resources/teamcity/windows/windows-actions.inc.sh`). **Adding a test requires no CI
change.**

Honest limitations to disclose: TeamCity only (never GitHub Actions — no `windows-latest`
job exists), and x86/x64 only (`test:arm64` commented out pending #15065).

### New file

`windows/src/engine/keyman32/tests/keybd_shift.tests.cpp`, starting `#include "pch.h"`
(PCH is mandatory). `keybd_shift()` is already declared in `keymanengine.h:231`, which
`pch.h` already includes — no `extern` needed.

**Trap:** `keyman32.tests.vcxproj` has **no glob**. Every test `.cpp` must be listed in the
`<ClCompile>` ItemGroup (~line 231).

### Tests

Simulate the stall by constructing its consequence — the stale byte array — directly. No
sleeps, no threads, no message pump, no flake.

| test | asserts | today |
|---|---|---|
| `ReleaseEmitsPrefixThenKeyups` | given `kbd[VK_LSHIFT]=0x80`, release emits prefix down+up then `VK_SHIFT` KEYUP | passes — locks the contract |
| `ResetRepressesFromCache` | given the same, reset emits `VK_SHIFT` KEYDOWN + prefix | passes — **this is the defect, characterized** |
| `RightControlCollapsesToExtendedControl` | `VK_RCONTROL` → `wVk == VK_CONTROL` with `KEYEVENTF_EXTENDEDKEY` (Step 5) | passes |
| `RightShiftCollapsesToShiftWithRightScanCode` | `VK_RSHIFT` → `wVk == VK_SHIFT`, `wScan == SCANCODE_RSHIFT` | passes |
| `ModifierEventCountNeverExceedsReserve` | worst case (all six set) ≤ `MAX_KEYEVENT_INPUTS_MODIFIERS` (8, `serialkeyeventcommon.h`) | passes — guards a comment-only invariant |
| `ResetDoesNotPressAKeyThatIsNotHeld` | reset must not emit KEYDOWN for a modifier the OS reports up | **FAILS** — the function has no live-state input |

Only the last fails today, and it fails by asserting the fix's shape (re-validate Cache A
against the OS at batch start — kmrepro's D1). Flag that in review: it is a design
opinion, not a neutral observation.

`isModifierKey` is `k32_lowlevelkeyboardhook.cpp:62` inside `#ifndef _WIN64`, so its test
is x86-only — guard it or skip it rather than breaking the x64 run.

### Also worth carrying

**`RightAltEmulationCheck.tests.cpp` has not run since Dec 2025.** It is on disk but absent
from the `<ClCompile>` ItemGroup — added by `404a9ea244`, silently dropped by merge
`4ac24f7b7b` (*chore(windows): Merge branch 'epic/win-arm'…*). One line to restore. Verify
it still passes before including it; if it fails, that is a separate finding, not
something to bundle.

---

## Optional: seams, only if wanted

Two findings are unreachable against the code as it stands. Both follow the precedent of
`ReadAltGrFlagFromKbdDll(name, out)` being split out of `KeyboardGivesCtrlRAltForRAlt()`
purely so it could be tested — the rationale is written into that test's comment.

- **4a** — factor the modifier half of `GetCapsAndNumlockState()` into a helper the
  `FToggleStateRefreshRequired` branch at `aiTIP.cpp:186-189` can also call. Then a test
  can dirty `*Globals::ShiftState()` with all five modifier flags, run the keyboard-switch
  path with nothing physically held, and assert all seven clear. Fails today (only Caps
  and Num clear).
- **Event sequence** — `UpdateLocalModifierState` is a private method of a class defined
  inside `serialkeyeventserver.cpp`, behind `#ifndef _WIN64`, whose constructor spawns a
  thread and a file mapping. Extracting its VK-normalisation + array write into a free
  function makes "deliver the KEYDOWN, omit the KEYUP, assert the cache is stale" testable.

Without these the branch stays purely additive but 4a is only assertable indirectly.

---

## Conventions

- **Branch** `<type>/<scope>/<issue>-<slug>` (`resources/git-hooks/prepare-commit-msg:56-61`).
  Suggested: `test/windows/16423-stuck-modifier-tests`. A matching branch name auto-fills
  the commit prefix and the `Fixes:` trailer.
- **Commit** `test(windows): <imperative, no trailing period>` for the gtests,
  `chore(windows): add <app>` for the manual app (matching `cb6063a954`). Types and scopes
  are hook-enforced from `resources/scopes/`. Trailers on their own line after a blank
  line: `Fixes: #16423` or `Relates-to: #16423`.
- **C++ style** `.clang-format`: 2-space indent, `ColumnLimit: 130`, attached braces,
  `PointerAlignment: Left`. New C++ file header is the short form
  (`RightAltEmulationCheck.cpp:1-5`); Delphi uses `windows/src/header_template.txt`.
- **PR** — a test-only PR normally needs no user test (`CONTRIBUTING.md:324-337`), but the
  manual app's README *is* effectively the user test; reference it.

---

## Verification

```bash
# gtests — the only thing that must go green in CI
./windows/src/engine/keyman32/build.sh --debug configure build test:x64
./windows/src/engine/keyman32/build.sh --debug test:x86     # isModifierKey coverage
```

Expect: all pass except `ResetDoesNotPressAKeyThatIsNotHeld`, which must fail with a
message naming the phantom VK. Confirm `RightAltEmulationCheck` now appears in the run
output — proof the vcxproj registration works.

```bash
./windows/build.sh test    # confirm the child action still cascades and nothing else broke
```

**Manual app** — build the `.dproj` in Delphi, then, against a real Keyman install with a
Keyman keyboard active:

1. Launch; confirm modifier events log with decoded flags.
2. Press and hold Left Shift; click the stall button; release Shift during the stall.
3. Type a key to force an injected batch.
4. Expect a `scanCode = 0xFF` `VK_SHIFT` KEYDOWN with no matching KEYUP, and the
   `GetAsyncKeyState` panel showing Shift held while nothing is physically pressed.
5. Confirm the app reports `[UNMATCHED KEYDOWN]`.

Cross-check against `kmrepro/logs/` — the wire capture there shows exactly this
sequence, so the two harnesses should agree event for event.

**Do not** attempt any of this against FieldWorks; kmrepro's `HAZARDS.md` records real
lexical-data corruption from navigation keys sent without `KEYEVENTF_EXTENDEDKEY`.

---

## Out of scope

- The Cache A fix itself (kmrepro D1/D2). Direction as of 2026-08-23 is repro + analysis
  only; the tests characterize current behaviour rather than assert a fix.
- The Core API change (`km_core_keyboard_activated_data`) — public API version bump,
  Debian symbols regen, `api-verification.yml` gate, three platform call sites. Own issue.
- The Linux/macOS staleness comparison (`linux/ibus-keyman/src/engine.c:779`,
  `mac/.../CoreWrapper.m:251`) — worth doing before proposing the API change, not before
  this.
