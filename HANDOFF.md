# HANDOFF — Keyman for Windows 18.0.245 "no text output / stuck modifier" investigation

**Status:** control baseline complete on 18.0.238. Waiting on the user to upgrade
to 18.0.245+ so the same tests can be re-run and diffed.
**Location of everything:** `D:\Github\_Projects\_KM\kmrepro\` (outside the git tree).
**Keyman repo:** `D:\Github\_Projects\_KM\keyman` (branch
`fix/windows/16422-caps-lock-state-on-keyboard-switch`).

---

## 1. The problem being investigated

Users auto-upgrading to the latest Keyman 18 report that, especially in
FieldWorks, typing produces **no text output at all**. The Keyman keyboard is
still shown as active. It behaves "as if Alt or Alt-Shift is stuck down".
Restarting Keyman or rebooting fixes it. Microsoft keyboards are unaffected.

The user (Keyman/SIL developer) already has a separate PR for a related caps-lock
bug (#16422), fixing code >12 years old — consistent with a long-latent bug newly
triggered by something else.

## 2. Primary hypothesis — the 18.0.245 low-level-hook watchdog

`83251358b0` *"fix(windows): reinstall low level keyboard hook if it gets removed"*
(cherry-pick of PR #15179, fixing #8064), first released in **18.0.245
(28 Nov 2025)**. It is the **only functional change to the Windows keystroke
engine in the whole 18.0 stable line after 18.0.235**.

### Mechanism

`windows/src/engine/keyman32/LowLevelHookWatchDog.cpp`:

```cpp
#define WATCHDOG_THRESHOLD 1000
// LastLowLevelEventTick   <- stamped by the WH_KEYBOARD_LL hook proc (keyman.exe)
// LastGetMessageEventTick <- stamped when keyman.exe drains KMC_WATCHDOG_KEYEVENT
if (LastGetMessageEventTick - LastLowLevelEventTick >= 1000) ReinstallHook();
//   -> UnhookWindowsHookEx(WH_KEYBOARD_LL) then SetWindowsHookExW(...)
```

`windows/src/engine/keyman32/kmhook_getmessage.cpp:152-158` — every hooked
process now posts `KMC_WATCHDOG_KEYEVENT` on **every** `WM_KEYDOWN`, and this post
happens **before** the `SCAN_FLAG_KEYMAN_KEY_EVENT` check, so Keyman's own
re-injected output feeds the same counter.

### Why it can false-positive

The GetMessage hook runs in the **target app's** thread when that app pumps its
queue. If an app stalls >1 s and then drains a backlogged `WM_KEYDOWN` after the
user has stopped typing (so `LastLowLevelEventTick` is no longer advancing), the
arithmetic says "hook is dead" and a perfectly healthy hook is torn out and
reinstalled. **FieldWorks — which the user says now decomposes text on every
keystroke — is exactly that kind of app.**

### Why a reinstall causes "no output"

1. Keyman's LL hook **swallows** every keystroke and re-injects it
   (`k32_lowlevelkeyboardhook.cpp:255-259`, `return_SendDebugExit(1)`).
2. Modifier state lives in `m_ModifierKeyboardState[]` in
   `serialkeyeventserver.cpp`, fed **only** by `WM_KEYMAN_MODIFIER_EVENT` posted
   from that LL hook.
3. If the hook is swapped out between a modifier **down** and its **up**, the
   KEYUP never arrives and the byte stays `0x80` forever.
4. `PrepareInjectedInput()` (`serialkeyeventserver.cpp:384-399`) then calls
   `keybd_shift_reset`, which injects a **KEYDOWN for every modifier the cached
   state says is held, with no matching KEYUP** — on every subsequent keystroke.
   The app ends up genuinely in Alt mode: keys arrive as `WM_SYSKEYDOWN`, are
   eaten as menu accelerators, and nothing is typed.

Nothing clears that array except restarting Keyman — matching the user reports.

### Candidate field workaround (UNVERIFIED — worth testing)

`UpdateLocalModifierState` (`serialkeyeventserver.cpp:581`) is driven by
`WM_KEYMAN_MODIFIER_EVENT`, which a *physical* press+release does post for both
edges. So **tapping each of L/R Shift, Ctrl, Alt once should clear the stuck byte
without restarting Keyman.** The rig tests this automatically on every failure
(it taps all six modifiers and re-probes). It has never fired on the control
build because no failure has occurred there yet.

## 3. Version timeline

| Version | Date | Windows engine change |
|---|---|---|
| 18.0.235 | 2025-04-23 | first stable |
| 18.0.239 | 2025-08-21 | update-check rework (kmshell only) |
| 18.0.241 | 2025-09-18 | — |
| 18.0.242 | 2025-09-29 | locale-name caching; MSI advertised-shortcut fix |
| 18.0.244 | 2025-10-31 | — |
| **18.0.245** | **2025-11-28** | **LowLevelHookWatchDog + all C++ rebuilt v142→v143** |
| 18.0.246 | 2026-02-04 | core normalization (LDML only) |
| 18.0.247–249 | Mar 2026 | nothing in `windows/` or `core/` |

Anyone upgrading from ≤18.0.244 to 18.0.249 gets the watchdog for the first time.

## 4. Secondary suspects (not yet tested)

- **VC++ v142→v143 rebuild** (`d7b16aece9`, also 18.0.245). Every C++ binary
  recompiled. Runtime linkage stayed `MultiThreaded` (static) so this is **not** a
  VC redist problem, but new codegen can surface latent races. Confounder, not
  a cause.
- **In-place upgrade with `REBOOT=ReallySuppress`** (`RunTools.pas:514`,
  `REINSTALLMODE=vomus REINSTALL=ALL`). `keyman32.dll`/`kmtip.dll` are mapped
  into every running app, so replacement defers to reboot while `keyman.exe` is
  updated immediately. There is **no version handshake anywhere** between engine
  components (grepped). Explains the "started right after the update" clustering
  and why rebooting fixes it more thoroughly than restarting Keyman.
- `LangSwitchManager.pas` rework (18.0.245). An intermediate commit had a real
  bug (bare `Free` freeing `Self`) but it was fixed in the same release — nothing
  shipped broken. Low priority, but it is Alt-adjacent.

## 5. RULED OUT

- **Core normalization changes in 18.0.246** affect **LDML keyboards only**.
  `kmx_processor::supports_normalization()` returns `false`
  (`core/src/kmx/kmx_processor.hpp:83`), so KMN/KMX keyboards — essentially all
  SIL keyboards — never enter that path. Cannot cause complete input failure.
  The user explicitly deprioritised normalization.
- 18.0.247, 248, 249 contain no `windows/` or `core/` changes at all.

---

## 6. The rig

| File | Purpose |
|---|---|
| `kmrepro.ps1` | Main rig. Notepad tests, ghost keys, freeze, ETW, modifier watch. |
| `kmflex.ps1` | FieldWorks driver. Keyboard-switch test with clipboard oracle. |
| `kmshot.ps1` | Standalone screenshot / positional click helper. |
| `RESULTS-control-18.0.238.md` | **The baseline. Diff against this.** |
| `PROTOCOL.md` | Longer-form test protocol and triage tree. |
| `reports/` | Raw run logs + screenshots from the control run. |

### Key constants (verified against source)

| Thing | Value | Source |
|---|---|---|
| Control message | `RegisterWindowMessage("WM_KEYMAN_CONTROL")` | `keymancontrol.h:70` |
| Fake-freeze command | `wParam = 20` (`KMC_WATCHDOG_FAKEFREEZE`) | `keymancontrol.h:52` |
| Watchdog key event | `wParam = 21` | `keymancontrol.h:53` |
| Master controller window | class `TApplication` in `keyman.exe` | `UfrmKeyman7Main.pas:617` |
| ETW provider GUID | `{DA621615-E08B-4283-918E-D2502D3757AE}` | `k32_dbg.cpp:59` |
| ETW enable switch | `HKCU\Software\Keyman\Keyman Engine\debug = 1` | `registry.h:39`, `k32_globals.cpp:695` |
| Installed version | `HKLM\SOFTWARE\WOW6432Node\Keyman\Keyman Desktop\version` | — |

**`KMC_WATCHDOG_FAKEFREEZE` shipped in stable 18.0.245.** The commit message says
the "fakefreeze project" wasn't cherry-picked, but the *handler* was
(`UfrmKeyman7Main.pas:856` → `Sleep(5000)` on keyman.exe's **main thread**, which
owns `WH_KEYBOARD_LL`). Posting command 20 hangs the hook owner on demand.
On 18.0.238 command 20 is unassigned, so it is an inert no-op.

### Probes (the Cameroon keyboard, `sil_cameroon_qwerty`)

| probe | keys | expected | proves |
|---|---|---|---|
| deadkey | `;` `e` | U+0259 `ə` | Keyman multi-key rule + cached context |
| ralt | RAlt(**extended**) + `N` | U+014B `ŋ` | right-Alt modifier path |
| shift | `abc` + LShift-held `def` + `ghi` | `abcDEFghi` | stuck-modifier detector ONLY |

**The shift probe is not Keyman-engagement proof** — the plain US layout produces
the same string. Always gate on `ə`/`ŋ`.

---

## 7. Control baseline — Keyman 18.0.238 (ALL CLEAN)

### Notepad (UI Automation oracle)

| scenario | iterations | failures | phantom modifiers |
|---|---|---|---|
| Baseline ghost burst | 20 posts | — | 0 |
| AutoTest Clean | 3 | 0 | 0 |
| AutoTest Ghost | 15 | 0 | 0 |
| AutoTest Freeze | 15 | 0 | 0 |

`abcDEFghiəŋ` exact on all 33 iterations.

### FieldWorks (clipboard oracle, test entry `Ngq`, entry 698/2234)

| scenario | iterations | failures | phantom modifiers |
|---|---|---|---|
| Switch Clean | 2 | 0 | 0 |
| Switch Ghost | 5 | 0 | 0 |
| Switch Freeze | 5 | 0 | 0 |

Also: **`SendMessageTimeout(WM_NULL)` to keyman.exe returned in 0 ms after
posting command 20** — the version discriminator.

---

## 8. WHAT TO DO NEXT

Once the user is on 18.0.245+, run exactly these and diff against
`RESULTS-control-18.0.238.md`:

```powershell
cd D:\Github\_Projects\_KM\kmrepro
powershell -ExecutionPolicy Bypass -File .\kmrepro.ps1 Status
powershell -ExecutionPolicy Bypass -File .\kmrepro.ps1 Baseline -Count 20
powershell -ExecutionPolicy Bypass -File .\kmrepro.ps1 AutoTest -Scenario Clean  -Iterations 3
powershell -ExecutionPolicy Bypass -File .\kmrepro.ps1 AutoTest -Scenario Ghost  -Iterations 15
powershell -ExecutionPolicy Bypass -File .\kmrepro.ps1 AutoTest -Scenario Freeze -Iterations 15
powershell -ExecutionPolicy Bypass -File .\kmflex.ps1  Switch   -Scenario Ghost  -Iterations 5
powershell -ExecutionPolicy Bypass -File .\kmflex.ps1  Switch   -Scenario Freeze -Iterations 5
```

**First thing to check:** does `Baseline`'s T2 now report
`VERDICT: FREEZE IS LIVE`? If yes, the watchdog code is present and command 20
blocks keyman.exe. That alone confirms you are on the treatment build.

**Any non-zero failure or phantom-modifier count is a regression.**

Optional, sharper:
- `kmrepro.ps1 Arm -HookTimeout 200` then **sign out and back in** — makes Windows
  evict a slow LL hook aggressively, raising the hit rate. `Disarm` reverses it.
- In an **elevated** shell: `kmrepro.ps1 TraceStart` … `TraceStop`. 64 MB circular
  ETW ring, never grows, safe to leave running for days. Then search the decoded
  trace for:
  - `Attempting to reinstall hook because watchdog threshold exceeded` ← smoking gun
  - `Attempt to reinstall low level hook may have failed` ← worse: no hook at all
  - `m_ModifierKeyboardState=[LS:.. LC:.. LA:.. RS:.. RC:.. RA:..]` ← the stuck byte

---

## 9. GOTCHAS — read before touching the code

These cost hours and twice corrupted live language data.

1. **Navigation keys MUST carry `KEYEVENTF_EXTENDEDKEY`.** Unextended, Left's scan
   code `0x4B` *is* numpad-4, Right `0x4D` is numpad-6, Home `0x47` is numpad-7 —
   they insert characters instead of moving the caret. **This corrupted the user's
   lexicon twice.** All navigation now routes through `Nav()` in `kmflex.ps1`.
2. **PowerShell variable names are case-insensitive.** `$EXT` (constant) collided
   with `$Ext` (switch parameter). Same class of bug: a helper named `R` resolved
   to the built-in alias for `Invoke-History` — aliases outrank functions.
3. **`GetKeyboardLayout()` does NOT track TSF profile switches.** It reported the
   Keyman HKL while FLEx's writing-system combo had already flipped to English.
   **Never use the HKL as the oracle — type and read back instead.**
4. **In FLEx, never send Home/End/Ctrl+A.** RootSite treats them as record-wide
   navigation; the caret leaves the field.
5. **In FLEx, never collapse a selection with Right at end-of-field.** It moves to
   the *next field*, so every read silently advances the caret and a later Tab
   count overshoots. Use `Read-AndClear`, which leaves the Shift+Left selection
   active and deletes it with one Backspace — atomic, caret unmoved.
6. **Tab is unusable for the FLEx field switch.** Tabbing past an entry's last
   field advances to the **next record**. Use absolute clicks.
7. **FieldWorks exposes NO UI Automation text** (zero Document/Edit/Text
   elements). Clipboard or screenshot only. Notepad, by contrast, exposes a clean
   `ValuePattern` on `RichEditD2DPT` — prefer Notepad for anything that doesn't
   need FLEx specifically.
8. **`keybd_event` with `dwExtraInfo = 0` is deliberate.** Keyman only filters on
   `dwExtraInfo != 0` (`k32_lowlevelkeyboardhook.cpp:227`), so 0 makes Keyman treat
   synthesized keys as real user input. Do not "fix" this to SendInput with a
   marker.
9. `keyman.exe`'s `Path` is unreadable from an unelevated shell — read the version
   from the registry.
10. FLEx field Y-coordinates **shift between entries** and as fields gain content.
    Re-check with `kmflex.ps1 Shot` if anything looks wrong. Current test entry:
    Ngq Citation Form `(1000, 325)`, Eng Note `(1000, 490)`.

---

## 10. SAFETY RULES

- **The FLEx database contains real Ngoreme language data.** The user has said the
  DB is restorable and any entry is expendable, and created a dedicated test entry
  (headword `Ngq`, entry 698/2234) — **use only that entry**.
- Every FLEx write must be self-cleaning (`Read-AndClear`). Verify the entry is
  unchanged with `kmflex.ps1 Shot` after a run.
- **Do not spam Ctrl+Z to fix mistakes.** The undo stack mixes your changes with
  the user's work; an over-undo silently reverts their edits. If you corrupt
  something, say so and let the user restore.
- Claude Code's auto-mode classifier may block synthesized keystrokes into
  FieldWorks. That is a reasonable block — surface it to the user rather than
  working around it.

---

## 11. Open questions

1. **Does the watchdog actually fire in the field?** No telemetry exists on
   stable-18. Master (19.0) added a Sentry event for every reinstall
   (`930ae121c4`, 10 Dec 2025, `KMC_WATCHDOG_HOOK_REINSTALL`) but it was **not**
   cherry-picked to stable-18. So 18.0.245–249 reinstall the hook silently.
2. **Is the phantom modifier in Windows' own key state, or only in Keyman's
   cache?** `GetAsyncKeyState` vs the ETW `m_ModifierKeyboardState` line
   distinguishes them. This is the single most valuable measurement to obtain —
   it tells the Keyman team which side of the fence to fix.
3. Does the modifier-tap workaround actually recover a wedged session? Rig tests
   it automatically on failure; needs a real failure to answer.
4. Are user reports actually on 245+? Worth collecting exact versions.

## 12. Suggested upstream fixes (from code reading, not yet proposed as a PR)

1. Cherry-pick `930ae121c4` (Sentry reinstall event) to `stable-18.0` — upstream
   is currently blind to how often this fires.
2. Harden the watchdog:
   - Don't post `KMC_WATCHDOG_KEYEVENT` for Keyman's own synthetic events; move
     the post *after* the `SCAN_FLAG_KEYMAN_KEY_EVENT` check.
   - Verify the hook is actually gone rather than inferring from a timer; require
     N consecutive breaches.
   - Never reinstall while a modifier is physically down, or resync
     `m_ModifierKeyboardState[]` from `GetAsyncKeyState` right after a reinstall.
     **This is the same class of fix as the user's caps-lock resync in #16422 —
     the two probably belong together.**
   - Retry `InitLowLevelHook()` on failure; today a failed reinstall leaves Keyman
     with no hook and no recovery path.
3. Consider whether auto-update should force an engine restart or prompt for
   reboot rather than `REBOOT=ReallySuppress`, given there is no version handshake.

## 13. Honest status of the evidence

The code path and the symptoms match closely, and the control baseline is clean
and repeatable. But **the hypothesis is NOT yet confirmed**: nothing has been
reproduced on 18.0.245+, and there is no field telemetry. Do not describe this as
a confirmed root cause in any bug report until the treatment run shows
`watchdog threshold exceeded` or a phantom modifier. The control baseline exists
precisely so that result will be unambiguous.
