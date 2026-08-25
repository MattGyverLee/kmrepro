# Test plan — porting these findings into Keyman

**Plan only. No Keyman code changes proposed here.**
Before talking to the team, read **[MEETING-PREP.md](MEETING-PREP.md)** — this is [#8064][i8064], it is Ross's issue, and he has already found much of it independently.

Mechanism: [MODIFIERS.md]. Three-arm proof: [TRIGGER.md]. Log: [TODO.md]. Safety: [HAZARDS.md]. Ross's field evidence and the closure path: [issue-8064/](issue-8064/README.md).

Code refs are `keymanapp/keyman` @ `a70538106c`, paths under `windows/src/engine/keyman32/`.

---

## 1. Why it has not reproduced on a clean VM

**Load was never the mechanism.** Measured on 18.0.249.0:

| ghost key | freeze | CPU load | iters | failures |
|---|---|---|---|---|
| yes | no | 0 | 27 | **0** |
| no | no | 32 | 10 | **0** |
| no | **yes** | 0 | 10 | **10** |
| no | **yes** | 32 | 10 | **10** |

Freeze alone with zero load: 10/10. Every latch in [MODIFIERS.md §2b][m2b] was at `-LoadThreads 0`.

**The missing precondition**, per mcdurdin in [`LowLevelHookWatchDog.cpp:6-12`][wd]:

> The hook can be uninstalled when keyman.exe becomes unresponsive for more than 200msec (default timeout) […] **The hook will only be uninstalled if a key is pressed while Keyman is unresponsive.**

For *this* bug that key must be a modifier **KEYUP** — the event whose loss strands Cache A (§2 step 3). On an idle VM a stall and a modifier release never coincide; under load they coincide too rarely to catch.

**The stimulus already ships in Keyman.** [`windows/src/support/fakefreeze/`][ff], mcdurdin 2025-11-17 ([`711541be60`][ff-commit]) — *"pause for 5 seconds to force Windows to silently uninstall the low level keyboard hook."* Handler is ungated: [`UfrmKeyman7Main.pas:868`][fz-handler] is a bare `Sleep(5000)`. No debug flag, no special build.

> **P0 — `fakefreeze` has no `build.sh`**, so `./windows/build.sh` never produces it. Siblings [`wow64kbd`][w64], `etl2log`, `oskbulkrenderer`, `texteditor` do. This is the highest-value item here.

### Repro recipe

Preconditions: **R1** a Keyman keyboard is active — read the HKL from `GetGUIThreadInfo(0).hwndFocus`, not `MainWindowHandle` ([why][kp]); **R2** `flag_ShouldSerializeInput` ≠ 0 ([`keyman32.cpp:231`][fsi], default 1); **R3** 32-bit host — Cache A is `#ifndef _WIN64` ([`serialkeyeventserver.cpp:7`][sks7]), 64-bit is open as [TODO I5][todo]; **R4** note `LowLevelHooksTimeout`.

1. Hold Left Shift. 2. Run `fakefreeze.exe`. 3. **Release the modifier during the freeze.** 4. Type a key. 5. Output capitalises; `GetAsyncKeyState(VK_LSHIFT) < 0` system-wide.

Step 3 is what a smoke test never does. It cannot be produced by load — it must be arranged.

**Two more reasons a careful tester sees nothing:** a stuck Ctrl/Alt causes *no case change* (keys are swallowed), so a text oracle scores it CLEAN — [MODIFIERS.md §2b][m2b] shows RCTRL held while text read correct lowercase. And a bare Alt press/release mimics the bug with Keyman uninvolved ([HAZARDS gotcha 4][hz]). Use `GetAsyncKeyState`; prefer LShift.

### Prior art — Ross owns this code

[`90eb7c77ec`][c7337] *ensure all modifier events go to seralized queue* (2022-10-13) **is #7337** — the commit that added the feed at [`k32_lowlevelkeyboardhook.cpp:200`][llh200]. Also [`f7391e3a46`][cdbg] (modifier debug logging) and branch `origin/docs/windows/12728/keystroke-life-cycle` → [`keystroke-lifecycle.md`][klc], which states the blind spot exactly:

> There is another Hook LowLevelKeyboardProc used for the serial event server but it is **out of scope for this document**. […] This explanation of the lifecycle talks **as if the keystrokes come in order**.

The bug lives entirely in that out-of-scope part, and consists precisely of keystrokes *not* arriving in order.

---

## 2. Proof chain

| # | claim | citation |
|---|---|---|
| 1 | LL hook runs on keyman.exe's Delphi **UI thread** — the thread that also runs dialogs, COM, updater | [`keyman32.cpp:368`][k368], [`:279`][k279] |
| 2 | Cache A seeded **once**, never reconciled; one writer only | [`serialkeyeventserver.cpp:251`][sks251], [`:581`][sks581] |
| 3 | Its sole feed is a `PostMessage`; a stall drops it. **That one stale byte is the entire residue of the delay** | [`k32_lowlevelkeyboardhook.cpp:200`][llh200] |
| 4 | Every injected batch re-presses what the cache believes → **KEYDOWN with no KEYUP** | [`:384`][sks384] → [`keybd_shift.cpp:161`][kbsr] |
| 5 | Right Ctrl is emitted as `VK_CONTROL`+`KEYEVENTF_EXTENDEDKEY` — a key the machine may not have; only the exact KEYUP clears it | [`keybd_shift.cpp:69`][kb69], [MODIFIERS §3b][m3b] |
| 6 | Feed sits **32 lines before** the pass-through filter ⇒ the cache re-confirms its own hallucination, and charges while Keyman is inactive (**3/3**) | [`:229`][llh229], [TRIGGER §3][tr3] |
| 7 | *(different defect — see [`capslock/`](capslock/README.md))* Cache B: keyboard switch resyncs **2** flags, focus change resyncs **7**; the modifier half reads `GetKeyState` (thread queue — the stale source) | [`capsstate.cpp:39`][cs39], [`kmhook_getmessage.cpp:418`][gm418], [`aiTIP.cpp:186`][ai186] |

**Key enabler for testing:** `keybd_shift_release`/`keybd_shift_reset` never call `SendInput` — they only fill a caller-supplied `INPUT[]`. They are pure functions over a 256-byte array.

**Do not** "fix" step 6 by gating the feed on `isKeymanKeyboardActive` — see [TODO D5][todo]; per the #7337 comment it exists to keep the queue in sync, and suppressing it trades this bug for a different desync.

---

## 3. Automated tests (TDD)

**Harness:** [`tests/keyman32.tests.vcxproj`][vcx] — gtest 1.8.1.7 via NuGet, MSBuild. [`build.sh:111-148`][ebs] links the engine as a **static library** into a console exe: no elevation, no TSF, no installed Keyman, no Notepad. Reached by `builder_run_child_actions` → `/windows/build.sh test` → TeamCity ([`windows-actions.inc.sh`][tc]). **No CI change needed.** Limits: TeamCity only (no GHA runs Windows tests), x86/x64 only (`test:arm64` disabled pending #15065).

> **P1 — the vcxproj has no glob.** [`RightAltEmulationCheck.tests.cpp`][raec] is on disk but absent from `<ClCompile>`: added by `404a9ea244`, dropped by merge `4ac24f7b7b` (2025-12-09). **It has not run since.** Restore the line; treat a failure as a separate finding.

### Red — fail today, pass after the fix

Two of the three red tests belong to the **Caps Lock / Cache B** defect
([#16422]/[#16423]), not to [#8064]. They have moved with it, to
[`capslock/TEST-PLAN.md`](capslock/TEST-PLAN.md): **T-R1** (the keyboard-switch
resync covers 2 of 7 flags) and **T-R2** (`GetKeyState` reads the stale source).
Both land in the same [`keyman32` gtest suite][vcx] described above.

What remains here, for Cache A:

- **T-R3** *(Cache A invariant)* — `keybd_shift(…, TRUE, kbd)` with `kbd[VK_RCONTROL]=0x80` must emit no KEYDOWN for a VK `GetAsyncKeyState` reports up. RED. Fix = [TODO D1][todo]. ⚠️ Unlike the Cache B pair this asserts the *shape of the fix*, not current-vs-correct behaviour — flag it in review.

> Worth being honest about the consequence of the split: the two cleanest
> red-to-green tests are Cache B's. #8064's automated story is mostly **proof**
> tests (below) plus T-R3, because `keybd_shift_reset` is *correct given its
> inputs* — the defect is that its input is stale.

### Proof — pass today; the artifact to show the team

New `tests/keybd_shift.tests.cpp`, starting `#include "pch.h"` (the PCH is mandatory). `keybd_shift()` is already declared in `keymanengine.h:231`, which `pch.h` already includes — no `extern` needed. For Cache A there is no red test without first choosing the fix, because [`keybd_shift_reset`][kbsr] is *correct given its inputs*; the defect is that its input is stale.

Simulate the stall by constructing its **consequence** — the stale byte array — directly. No sleeps, no threads, no message pump, no flake.

| id | gtest name | asserts | today |
|---|---|---|---|
| **T-P1** | `ResetRepressesFromCache` | given `kbd[VK_LSHIFT]=0x80`, reset emits `VK_SHIFT` KEYDOWN + prefix — **the phantom press, in Keyman's own harness** | passes — the defect, characterised |
| **T-P2** | `ReleaseEmitsPrefixThenKeyups` | release emits prefix down+up, then the `VK_SHIFT` KEYUP | passes — locks the contract |
| **T-P3** | `RightControlCollapsesToExtendedControl` | `VK_RCONTROL` → `wVk == VK_CONTROL` with `KEYEVENTF_EXTENDEDKEY` (proof step 5) | passes |
| **T-P4** | `RightShiftCollapsesToShiftWithRightScanCode` | `VK_RSHIFT` → `wVk == VK_SHIFT`, `wScan == SCANCODE_RSHIFT` | passes |
| **T-P5** | `ModifierEventCountNeverExceedsReserve` | worst case, all six set, ≤ `MAX_KEYEVENT_INPUTS_MODIFIERS` (8, `serialkeyeventcommon.h`) | passes — guards a comment-only invariant |
| **T-P6** | `IsModifierKeyAcceptsExactlyNineVks` | [`isModifierKey`][llh62] accepts exactly nine VKs → six slots | passes. **x86 only** — that file is `#ifndef _WIN64`, so guard or skip rather than breaking the x64 run |
| **T-R3** | `ResetDoesNotPressAKeyThatIsNotHeld` | reset must not emit a KEYDOWN for a modifier the OS reports up | **FAILS** — the function has no live-state input |

### Verification

```bash
# the only thing that must go green in CI
./windows/src/engine/keyman32/build.sh --debug configure build test:x64
./windows/src/engine/keyman32/build.sh --debug test:x86     # isModifierKey coverage
./windows/build.sh test                                     # child action still cascades
```

Expect all to pass except `ResetDoesNotPressAKeyThatIsNotHeld`, which must fail with a message naming the phantom VK. Confirm `RightAltEmulationCheck` now appears in the run output — that is the proof P1 worked.

**Trap:** `keyman32.tests.vcxproj` has **no glob**. Every test `.cpp` must be listed in the `<ClCompile>` ItemGroup (~line 231), which is exactly how `RightAltEmulationCheck.tests.cpp` went dark for eight months.

Bar to clear, from [`windows/src/test/unit-tests/README.md`][utr]: *"They should not have complex environmental requirements nor require an installed version of the software in order to complete."* These clear it — a 256-byte array and a function call.

### Optional seams

Precedent: `ReadAltGrFlagFromKbdDll(name,out)` was split out of `KeyboardGivesCtrlRAltForRAlt()` purely for testability — rationale is in [the test's own comment][raec].
**S1** give [`GetCapsAndNumlockState`][gm418] a header decl (it has none, only a file-local forward decl at `:71`) and factor its modifier half so [`aiTIP.cpp:186`][ai186] can call it = [TODO F1/F3][todo]. **S2** extract [`UpdateLocalModifierState`][sks554]'s VK-normalisation into a free function — today it is a private method of a class defined inside the `.cpp`, behind `#ifndef _WIN64`, whose ctor spawns a thread and a file mapping.

**Order:** P1 → T-P1…T-P6 → T-R1/T-R2 → F1/F2 turn them green → T-R3 + S1/S2 only if Cache A is picked up.

---

## 4. Manual Windows test

**Goes in** `windows/src/test/manual-tests/GH-16423 - stuck-modifier-phantom-keydown/`. That directory's [README][mtr]: *"intended to be run manually, so there is generally no build process included."* No builder registration, no CI, no elevation. Naming follows `GH-<issue> - <slug>` (cf. `GH-140 - shift states`).

**Model on** [`keyboard_ll_identifier/`][klid] — mcdurdin [`cb6063a954`][klid-commit], `Relates-to: #14890`. Already a minimal wire logger: a VCL form with `WH_KEYBOARD_LL` filtering exactly the nine VKs `isModifierKey()` accepts. Stall idiom already exists too: [`test_i5394 - modifiers out of sync`][i5394] (a `chkShiftDelay` box doing `Sleep(500)`×5 in `FormKeyDown` while logging `GetKeyState` vs `GetAsyncKeyState`) and [`test_i4793`][i4793].

**Must add:** **M1** log `dwExtraInfo` + decoded flags — the template logs `vkCode scanCode flags` only, so it cannot show `scanCode=0xFF` (`SCAN_FLAG_KEYMAN_KEY_EVENT`, Keyman synthesized) or `dwExtraInfo=0x4B4D0000` (`EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT`, Keyman replayed), both in [`keyman64.h:132-134`][k64h]. **M2** unmatched-KEYDOWN detector — **the pass/fail oracle**. **M3** a stall button posting `KMC_WATCHDOG_FAKEFREEZE`, folding §1's step 2 into one click. **M4** live `GetAsyncKeyState` panel over the six Cache A modifiers + the prefix VK (`0x0E`, [`aiTIP.h:36`][aih36]) — text oracles see neither.

Keep the **LL hook**, not the commented-out `Application.OnMessage` variant: the WM_KEY* path is downstream of the drop and cannot observe it. README must state the manual procedure and that a **global** hook is active (every keystroke on the machine is logged).

**Naming:** the slug above says `GH-16423`, which is the *Cache B* PR. This app is for **#8064** — name it `GH-8064 - stuck-modifier-phantom-keydown/`.

### The manual procedure the README must carry

Against a real Keyman install with a Keyman keyboard active:

1. Launch; confirm modifier events log with decoded flags and `dwExtraInfo`.
2. Press and hold **Left Shift**; click the stall button; **release Shift during the stall**.
3. Type a key to force an injected batch.
4. Expect a `scanCode = 0xFF` `VK_SHIFT` KEYDOWN with **no matching KEYUP**, and the `GetAsyncKeyState` panel showing Shift held while nothing is physically pressed.
5. Confirm the app reports `[UNMATCHED KEYDOWN]` — that is the oracle, not the text.
6. Recover: send a plain KEYUP for each of the six modifiers, or type normally.

Cross-check against [`logs/`](logs/) — `mods-prefix-latch-evidence.txt` and the two `altgr-physical-*` captures show exactly this sequence, so the two harnesses should agree event for event ([T13](#6-task-log)).

**Do not** run any of this against FieldWorks. [HAZARDS.md][hz] records real lexical-data corruption from navigation keys sent without `KEYEVENTF_EXTENDEDKEY`.

---

## 5. Cross-platform

Two bug classes; they do not travel together. **A** = re-injected modifier KEYDOWN with no KEYUP → system-wide latch. **B** = stale cached modifier/CAPS → wrong rule match.

| | engine | modifier source | class A | class B |
|---|---|---|---|---|
| **Windows** | Core | cached globals + `m_ModifierKeyboardState[256]` | **YES** | **YES** |
| **Linux** | Core | function-local, rebuilt from the IBus event every keystroke ([`engine.c:1009`][lx1009]) | No | narrow — Ctrl/Alt chirality only |
| **macOS** | Core | **cached global**, *replacing* the event's own flags ([`KMInputMethodEventHandler.m:121`][mac121]) | No | **YES** |
| **Android** | KeymanWeb | `event.getModifiers()` per event; class has 2 `final` fields, `onKeyUp` → `return false` | No | No |
| **iOS** | KeymanWeb | none — no hardware-key API present at all | No | No |

**Class A is structurally absent everywhere but Windows.** No `keybd_shift_reset` analogue exists outside `windows/`. Linux injects only a paired F24 sentinel and uses `EV_LED` for caps (never a synthetic `KEY_CAPSLOCK`), and explicitly *suppresses* modifier forwarding; macOS always emits down+up and smuggles OSK modifiers via `kCGEventSourceUserData` to avoid touching real state; Android synthesizes only `KEYCODE_TAB`/`KEYCODE_ENTER` as balanced pairs scoped to one `InputConnection`; iOS emits text, not keys. **There is no code to fix.**

**Android/iOS are not affected by construction** — neither uses Keyman Core (no JNI/NDK/`.so` under `android/`, no `.a`/`.framework` under `ios/`); both host KeymanWeb in a WebView. Android filters modifier keys out before Keyman sees them (scan code → 0) and re-sends `CAPS`/`NO_CAPS` etc. on *every* keystroke — the re-sync Windows lacks. iOS never intercepts hardware keys at all.

**macOS is the one real finding.** [`KMInputMethodAppDelegate.currentModifiers`][macprop] is written only from the CGEventTap `kCGEventFlagsChanged` callback and read at `determineModifiers`; the key event's authoritative `event.modifierFlags` is deliberately discarded (its own log string says *"using modifierFlags […] instead of event.modifiers"*). The tap can be disabled by the system and nothing resets the cache — not on tap re-enable, not on `activateServer`/`deactivateServer`. Much safer than Windows (absolute assignment, so it self-heals on the next flags-change; never drives injection), but Shift/Caps can be stale for an unbounded window. → **X2/X3**. Fix precedent is in the same codebase: the OSK re-reads `GetCurrentKeyModifiers()` on a timer.

Two nuances worth stating precisely. macOS's *conversion* function [`macToKeymanModifier:`][machelper] is a pure function of its argument — the exposure is one layer up, where the argument is taken from the cache instead of the event. And the **browser** web path does keep a cache ([`hardwareEventKeyboard.ts`][hwek], `modStateFlags`, chirality only, with an explicit AltGr-release workaround) — but Android and iOS use [`PassthroughKeyboard`][ptk], which has no cache at all, so they do not inherit it.

### What "can never bite" actually requires

**1. Core already documents the invariant — and never enforces it.** [`km_core_process_event`][capi] says `modifier_state` is *"The combinations of modifier keys set at the time key `vk` was pressed"* — i.e. at press time, which implicitly forbids a stale cache. It also documents `KM_CORE_STATUS_INVALID_ARGUMENT` for *"an invalid virtual key or modifier state"*. But [`km_core_processevent_api.cpp:44`][cpe] validates only `state_ != nullptr`; `KM_CORE_MODIFIER_MASK_*` appears nowhere in `core/src/` outside two LDML asserts. Contradictory bit pairs, out-of-range bits and chiral+non-chiral mixes all pass straight through.

> **This is the strongest genuinely cross-platform lever available.** Implementing the already-documented validation in that one funnel fires on Windows, macOS, Linux *and* Keyman Developer simultaneously, needs no API version bump (it makes a documented promise true rather than changing a signature), and turns a silent wrong-answer into a caught error. → **X8**

Related documentation bug to fix in the same pass: `KM_CORE_MODIFIER_NOCAPS` is documented as a valid value, but Core infers caps-off from the *absence* of `CAPITALFLAG` ([`kmx_modifiers.cpp:92`][kmxmod]), so a platform passing NOCAPS breaks rule matching. macOS discovered this the hard way and left the code commented out with *"setting NOCAPS in Core breaks keyboards like EuroLatin and Amharic"*. → **X9**

**2. Absence of a re-injection path is the guarantee for class A** — and it is written down nowhere. Record it as an explicit invariant: *a platform layer must never synthesize a modifier key event it does not also pair.* → **X6**

**3. The shared fixtures are the best enforcement that exists — but today they cannot express this bug.** [`common/test/keyboards/baseline/`][fixtures] is consumed by **three** harnesses: the Core kmx harness (Linux/macOS/Windows x64 **and ARM64**, plus WASM), the Linux ibus integration tests (real IBus under X11 **and** Wayland × surrounding-text on/off), and the KeymanWeb Playwright suite (real Chromium). Linux and Web **auto-glob** the directory, so a new fixture registers itself; Core needs one line in `meson.build`.

The blocker: the `c keys:` grammar has no way to say "modifier down … modifier still down … modifier up". [`kmx.cpp:238`][kmxcpp] sends the *same* `modifier_state` for keydown and keyup, and `[K_SHIFT]` arrives with `modifier_state == 0`. Caps lock is the sole exception (it is toggled and fed back). Extending the grammar — e.g. `[+SHIFT]` / `[-SHIFT]` — plus wiring `capsLock:` into the web harness (`baseline.tests.ts:157` is still `// TODO-web-core: set capslock state`, which is why `k_0700`/`k_0701` are skipped on Web) would give a real three-platform contract test. → **X10**

**4. Core cannot catch the Windows bug itself.** Core stores no modifier/toggle state; the platform hands it a `uint16_t` per event and Core passes it through ([`kmx_processor.cpp:263`][kmxp], [`state.hpp:216`][sthpp]). Validation (item 1) catches *malformed* state, not *plausible-but-stale* state. The channel that could carry ground truth is closed: [`keyman_core_api.h`][capi] — *"Additional event-specific data. **Currently unused, must be nullptr.**"* Opening it (`km_core_keyboard_activated_data`) means a public API bump, Debian symbols regen, the `api-verification.yml` gate and three call sites — **own issue**, justified only if platforms actually share the defect. On this evidence only macOS does, and X2/X3 are far cheaper.

**5. Do not rely on `api-verification.yml`.** It runs `dpkg-gensymbols` against the Linux `.deb` only. `km_core_process_event` is a plain C symbol, so any change to parameter *meaning* is invisible to it; enum values never appear in the symbol table; and it can be skipped outright with a `Keyman-Api-Check: skip` PR trailer. It is an ABI check, not a semantic one.

**6. Note the CI trigger map** ([`trigger-definitions.inc.sh`][trig]): `watch_android` and `watch_ios` are `web|common/web` — **not** `core`. `watch_linux` includes `common/test/keyboards/baseline`. So a Core-side change does not trigger Android/iOS builds at all, which is a further reason the mobile guarantee has to rest on their architecture rather than on Core.

---

## 6. Task log

Idiom follows [TODO.md]. Series chosen to avoid collision with existing I/H/F/D/T.

**Port** — `[ ]` **P0** add `fakefreeze/build.sh` (pattern: [`wow64kbd/build.sh`][w64]) · **P1** restore `RightAltEmulationCheck.tests.cpp` to the vcxproj · **P2** `tests/keybd_shift.tests.cpp` (T-P1…T-P6) · **P3** `tests/capsstate.tests.cpp` (T-R1, T-R2) · **P4** the manual app · **P5** extend [`keystroke-lifecycle.md`][klc] to cover the serializer, folding in §2 · **P6** settle S1/S2 with the reviewer before T-R3.

**Cross-platform** — `[ ]` **X1** reset Linux `{l,r}{ctrl,alt}_pressed` in `focus_in` (set only in the ctor, never re-synced on focus/reset/enable/disable — the closest structural sibling to the Windows bug) · **X2** reconcile macOS `currentModifiers` against the event, caching only the L/R chirality bits IMK lacks · **X3** re-seed it when the event tap re-enables · **X4** a macOS test for the cached path — every existing test builds an `NSEvent` with explicit `modifierFlags:` and exercises the *read-from-event* path, so `determineModifiers`/`currentModifiers`/`eventTapFunction` have **no test at all** · **X5** a dropped-KEYUP test for Linux — `tests/KeyHandling.cpp` always emits balanced pairs · **X6** write down the no-unpaired-modifier-injection invariant · **X7** *(minor)* no unit test for `PassthroughKeyboard.raiseKeyEvent`, the function Android actually calls · **X8** **implement the documented `modifier_state` validation** in [`km_core_processevent_api.cpp`][cpe] — one funnel, four platforms, no API bump · **X9** fix the `KM_CORE_MODIFIER_NOCAPS` documentation (it is documented as valid but breaks rule matching) · **X10** extend the `c keys:` grammar with explicit modifier down/up so the shared fixtures can express this bug class, and wire `capsLock:` into the web harness.

**Investigations** *(recorded in [TODO.md] alongside I1-I12)* — `[ ]` **I13** does `fakefreeze` reproduce on a clean VM? Direct test of §1; a null result here means something else differs and is worth knowing · **I14** which emitter latched the prefix VK? [TODO I11][todo] measured 1/116, but the wire capture saw every prefix KEYDOWN matched, so it caught only the atomic path ([`keybd_sendprefix`][kbsp]); [`PostDummyKeyEvent`][pdke] uses two separate `keybd_event` calls and is not atomic. · **I15** does Ross's focus-change observation answer **I3** (the stall source)? See [MEETING-PREP.md](MEETING-PREP.md) §2.

**Gates** — `[ ]` **T11** `keyman32/build.sh --debug configure build test:x64` and `test:x86` green except deliberate reds · **T12** `/windows/build.sh test` still cascades · **T13** manual app reproduces per §1 and agrees event-for-event with [`logs/`](logs/).

---

## 7. Conventions

Branch `<type>/<scope>/<issue>-<slug>` ([`prepare-commit-msg:56`][pcm]) — a matching name auto-fills the commit prefix and `Fixes:` trailer. Commits `test(windows): …` / `chore(windows): add …`, imperative, no trailing period, trailers after a blank line; types and scopes hook-enforced from [`resources/scopes/`][scopes]. C++ per [`.clang-format`][cf] — 2-space, `ColumnLimit: 130`, attached braces, `PointerAlignment: Left`. A test-only PR normally needs no user test ([CONTRIBUTING][contrib]); the manual app's README serves as one.

**Out of scope:** the Cache A fix itself ([TODO D1/D2][todo] — repro and analysis only, per direction 2026-08-23); the Core API change (§5.4); any FieldWorks-based testing ([HAZARDS][hz] records real lexical-data corruption).

---

[MODIFIERS.md]: MODIFIERS.md
[TRIGGER.md]: TRIGGER.md
[TODO.md]: TODO.md
[HAZARDS.md]: HAZARDS.md
[todo]: TODO.md
[hz]: HAZARDS.md
[m2b]: MODIFIERS.md
[m3b]: MODIFIERS.md
[tr3]: TRIGGER.md
[kp]: kmproof.ps1

[k368]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/keyman32.cpp#L368
[k279]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/keyman32.cpp#L279
[pdke]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/keyman32.cpp#L923
[fsi]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/keyman32.cpp#L231
[sks7]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/serialkeyeventserver.cpp#L7
[sks251]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/serialkeyeventserver.cpp#L251
[sks384]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/serialkeyeventserver.cpp#L384
[sks554]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/serialkeyeventserver.cpp#L554
[sks581]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/serialkeyeventserver.cpp#L581
[llh62]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/k32_lowlevelkeyboardhook.cpp#L62
[llh200]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/k32_lowlevelkeyboardhook.cpp#L200
[llh229]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/k32_lowlevelkeyboardhook.cpp#L229
[kb69]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/keybd_shift.cpp#L69
[kbsp]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/keybd_shift.cpp#L112
[kbsr]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/keybd_shift.cpp#L161
[cs39]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/capsstate.cpp#L39
[gm418]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/kmhook_getmessage.cpp#L418
[ai186]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/appint/aiTIP.cpp#L186
[aih36]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/appint/aiTIP.h#L36
[k64h]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/keyman64.h#L132
[wd]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/LowLevelHookWatchDog.cpp#L6
[ebs]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/build.sh#L111
[utr]: https://github.com/keymanapp/keyman/blob/master/windows/src/test/unit-tests/README.md
[vcx]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/tests/keyman32.tests.vcxproj
[raec]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/tests/RightAltEmulationCheck.tests.cpp

[ff]: https://github.com/keymanapp/keyman/tree/master/windows/src/support/fakefreeze
[ff-commit]: https://github.com/keymanapp/keyman/commit/711541be60
[w64]: https://github.com/keymanapp/keyman/blob/master/windows/src/support/wow64kbd/build.sh
[fz-handler]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman/UfrmKeyman7Main.pas#L868
[klid]: https://github.com/keymanapp/keyman/tree/master/windows/src/test/manual-tests/keyboard_ll_identifier
[klid-commit]: https://github.com/keymanapp/keyman/commit/cb6063a954
[mtr]: https://github.com/keymanapp/keyman/blob/master/windows/src/test/manual-tests/README.md
[i5394]: https://github.com/keymanapp/keyman/tree/master/windows/src/test/manual-tests/test_i5394%20-%20modifiers%20out%20of%20sync
[i4793]: https://github.com/keymanapp/keyman/tree/master/windows/src/test/manual-tests/test_i4793
[klc]: https://github.com/keymanapp/keyman/blob/docs/windows/12728/keystroke-life-cycle/windows/docs/internal/keystroke-lifecycle.md
[c7337]: https://github.com/keymanapp/keyman/commit/90eb7c77ec
[cdbg]: https://github.com/keymanapp/keyman/commit/f7391e3a46
[tc]: https://github.com/keymanapp/keyman/blob/master/resources/teamcity/windows/windows-actions.inc.sh

[lx1009]: https://github.com/keymanapp/keyman/blob/master/linux/ibus-keyman/src/engine.c#L1009
[mac121]: https://github.com/keymanapp/keyman/blob/master/mac/Keyman4MacIM/Keyman4MacIM/KMInputMethodEventHandler.m#L121
[macprop]: https://github.com/keymanapp/keyman/blob/master/mac/Keyman4MacIM/Keyman4MacIM/KMInputMethodAppDelegate.h#L79
[kmxp]: https://github.com/keymanapp/keyman/blob/master/core/src/kmx/kmx_processor.cpp#L263
[sthpp]: https://github.com/keymanapp/keyman/blob/master/core/src/state.hpp#L216
[capi]: https://github.com/keymanapp/keyman/blob/master/core/include/keyman/keyman_core_api.h
[fixtures]: https://github.com/keymanapp/keyman/tree/master/common/test/keyboards/baseline
[machelper]: https://github.com/keymanapp/keyman/blob/master/mac/KeymanEngine4Mac/KeymanEngine4Mac/CoreWrapper/CoreHelper.m#L88
[hwek]: https://github.com/keymanapp/keyman/blob/master/web/src/app/browser/src/hardwareEventKeyboard.ts
[ptk]: https://github.com/keymanapp/keyman/blob/master/web/src/app/webview/src/passthroughKeyboard.ts
[cpe]: https://github.com/keymanapp/keyman/blob/master/core/src/km_core_processevent_api.cpp#L44
[kmxmod]: https://github.com/keymanapp/keyman/blob/master/core/src/kmx/kmx_modifiers.cpp#L92
[kmxcpp]: https://github.com/keymanapp/keyman/blob/master/core/tests/unit/kmx/kmx.cpp#L238
[trig]: https://github.com/keymanapp/keyman/blob/master/resources/build/ci/trigger-definitions.inc.sh#L56
[vkeys]: https://github.com/keymanapp/keyman/blob/master/core/include/keyman/keyman_core_api_vkeys.h#L18

[pcm]: https://github.com/keymanapp/keyman/blob/master/resources/git-hooks/prepare-commit-msg#L56
[scopes]: https://github.com/keymanapp/keyman/tree/master/resources/scopes
[cf]: https://github.com/keymanapp/keyman/blob/master/.clang-format
[contrib]: https://github.com/keymanapp/keyman/blob/master/CONTRIBUTING.md#user-testing
[i8064]: https://github.com/keymanapp/keyman/issues/8064
[#16422]: https://github.com/keymanapp/keyman/issues/16422
[#16423]: https://github.com/keymanapp/keyman/issues/16423
