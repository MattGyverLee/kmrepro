# IN-TREE — what has landed in Keyman, and on what evidence

Written 2026-08-26. This is the first document here that describes **compiled, executed,
committed** work rather than drafts. Everything in [`FIX-PROPOSAL.md`](FIX-PROPOSAL.md) and
[`TEST-PLAN.md`](TEST-PLAN.md) that carried a *"never compiled, never run"* warning for Cache A is
superseded by this file; the warnings that remain there are the ones that are still true.

Companion Keyman checkout: `../keyman`, branch
**`fix/windows/8064-reconcile-modifier-cache`**, based on `origin/master` @ `deeff0456f`
(upstream `keymanapp/keyman`, not the fork's `master`).

> **Scope change, recorded.** [`TEST-PLAN.md`](TEST-PLAN.md) §7 listed the Cache A fix itself as out
> of scope, *"repro and analysis only, per direction 2026-08-23"*. Direction 2026-08-26 supersedes
> that: the fix was to be written, tested and made minimal. It has been.

> **Cache B is not on this branch, by construction.** The Caps Lock defect
> ([#16422][i16422]) is already a separate pull request, [#16423][p16423], on branch
> `fix/windows/16422-caps-lock-state-on-keyboard-switch`. This work is branched from
> `origin/master`, **not** from that branch, so neither of its two commits (`a70538106c`,
> `5d073fa44f`) is an ancestor here — verified, not assumed. Nothing under `capsstate.cpp`,
> `kmhook_getmessage.cpp` or `aiTIP.cpp` is touched, and seam **S1**
> (`RefreshModifierShiftState`) is untouched and still belongs to [`capslock/`](capslock/README.md).
>
> The only Caps Lock references on the branch are **negative controls** in the new tests —
> `isModifierKey(VK_CAPITAL)` must be false, and `kbd[VK_CAPITAL]` must survive reconciliation
> untouched. Those assert the boundary between the two defects rather than crossing it.

---

## 1. The build environment, established for the first time

Every previous document in this repo was written against a checkout in which **not one line had
been through a compiler**. That is no longer the case, and the reason it was true is worth
recording, because it was not "no toolchain" — it was two solvable blockers.

| fact | detail |
|---|---|
| **The gtest suite builds and runs** | baseline on an unmodified tree: `7 tests from 3 test cases, 7 PASSED`, on both `test:x86` and `test:x64` |
| Compiler actually used | **VS 2022 Community at `D:\Large Program Files\VS 2022`** (17.14.38), MSVC `14.44.35207`, `PlatformToolset v143`, Windows SDK `10.0.26100.0` at `D:\Windows Kits\10\` |
| The trap | there is a **second** VS 2022 install, `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`, with **no `VC/` directory at all** — its MSBuild cannot compile C++. `vswhere -latest`, which `resources/build/win/configure_environment.inc.sh` uses, resolves to the Community install, so the build scripts pick the right one |
| Blocker 1 — NuGet | the gtest package was not restored anywhere. One-time fix: `msbuild.exe tests/keyman32.tests.vcxproj -t:Restore -p:RestorePackagesConfig=true`. No standalone `nuget.exe` needed. Now present under `tests/packages/`, which is gitignored |
| Blocker 2 — `configure` | **do not run `build.sh configure`.** It pulls the `@/core:win` dependency, which builds core for arm64 and dies: `LINK : fatal error LNK1104: cannot open file 'libcpmtd.lib'`. `VC\Tools\MSVC\14.44.35207\lib\` holds only `x86`, `x64`, `onecore` — no `arm64`. `test:x86` and `test:x64` do not trigger that dependency and need no `configure` |
| Delphi | **not installed.** `delphi_environment_generated.inc.sh` is an empty stub. Delphi builds happen on a separate machine, which is one reason the telemetry fixes were dropped from the minimal change |

### The commands that work

```bash
# from the repo root of ../keyman
./windows/src/engine/keyman32/build.sh --debug test:x86
./windows/src/engine/keyman32/build.sh --debug test:x64

# the demonstration artifact: run by hand, never in CI
cd windows/src/engine/keyman32
./tests/bin/Win32/Debug/keyman32.tests.exe --gtest_also_run_disabled_tests \
  --gtest_filter='KEYBD_SHIFT.DISABLED_ResetDoesNotPressAKeyThatIsNotHeld'
```

To build a `.vcxproj` directly, `KEYMAN_ROOT` **must** be exported first or you get misleading
`C1083` errors naming `\common\windows\cpp\src\*.cpp`:

```bash
export KEYMAN_ROOT="D:/Github/_Projects/_KM/keyman"
source "$KEYMAN_ROOT/resources/build/win/visualstudio_environment_generated.inc.sh"
msbuild.exe keyman32.vcxproj -t:Build -p:Platform=Win32 -p:Configuration=Debug -clp:Verbosity=minimal -nologo
```

> **`keyman32.vcxproj` compiles with warnings as errors** (`C2220`). An unreferenced parameter
> (`C4100`) is enough to fail the build. Any patch drafted for this engine has to be
> warning-clean, not merely correct.

---

## 2. What landed

Four commits, in this order. The first is landable on its own: it characterises the defect without
proposing a fix, so it keeps its value even if the fix is reworked in review.

| commit | subject | files |
|---|---|---|
| `204e63493b` | `test(windows): characterise phantom modifier re-press in serial key event server` | `tests/keybd_shift.tests.cpp` (new), `tests/keyman32.tests.vcxproj` |
| `a26aa611b5` | `fix(windows): reconcile cached modifier state with the OS before injecting` | `keymanengine.h`, `keybd_shift.cpp`, `serialkeyeventserver.cpp`, + tests appended |
| `5274fec612` | `chore(windows): add a build entry point for the fakefreeze support tool` | `support/fakefreeze/build.sh` (new), `support/fakefreeze/fakefreeze.vcxproj`, `support/build.sh` |
| `78a0c22edc` | `test(windows): add manual test for the stuck modifier phantom KEYDOWN` | `test/manual-tests/GH-8064 - stuck-modifier-phantom-keydown/README.md` (new) |

Totals: **671 insertions across 9 files**, of which the production change is **64 lines across 3
files, roughly 40 of them comment**. The executable production change is one typedef, one
declaration, a ten-line loop, and one call.

### Results

| gate | result |
|---|---|
| `test:x86` | **19/19 pass** (1 disabled) at `a26aa611b5`; **33/33 pass** (2 disabled) after the follow-on branch — see *Follow-on* below |
| `test:x64` | **18/18 pass** (1 disabled) at `a26aa611b5`; **32/32 pass** (2 disabled) after the follow-on — the x86-only `isModifierKey` case correctly compiles out |
| `keyman32.dll`, Win32 Debug | links clean, 0 warnings |
| `keyman64.dll`, x64 Debug | links clean, 0 warnings |
| `keymanarm64.dll` | **not built** — no ARM64 MSVC libraries on this machine. See §6 |
| `fakefreeze.exe`, x86 and x64 | builds via the new `build.sh`; clean rebuild leaves the tree clean |
| name collisions | none. `PGETASYNCKEYSTATE` and `ReconcileModifierCache` appear nowhere else in the repo, and there was no pre-existing `GetAsyncKeyState` typedef |
| blast radius of the header change | `keymanengine.h` is included by exactly two files, both PCHs (`keyman32/pch.h`, `keyman32/tests/pch.h`). Only two MSBuild projects are affected and both build. `kmtip.vcxproj` links `keyman32.lib` but includes no keyman32 header; `mcompile.vcxproj` includes only `kbd.h` |

### Follow-on — the review's five gaps, implemented

Ten further commits on the same branch. Of the six items in
[`REVIEW-8064-reconcile-modifier-cache.md`](REVIEW-8064-reconcile-modifier-cache.md):
items 1, 4 and 5 are **fixed**, item 6 is **refuted** (its premise was wrong), item 3
is **answered in the negative** and item 2 is **unchanged**. Dispositions are recorded
inline in that file; the short version:

| commit | subject |
|---|---|
| `d922477da8` | `refactor(windows): define the managed modifier set once` |
| `1ae2df282c` | `refactor(windows): extract PrepareInjectedInputBatch so the batch path is testable` |
| `ae1f348b1a` | `test(windows): pin the batch reconcile so removing it fails the suite` |
| `13c083f216` | `test(windows): characterise the lost-modifier-KEYDOWN mirror defect` (deliberately red) |
| `00b17ee604` | `fix(windows): release modifiers the OS holds but the cache does not` |
| `6b07cff02b` | `test(windows): probe what GetKeyboardState returns on a fresh thread` |
| `14d2dc5c08` | `docs(windows): correct what the modifier-cache seed actually does` — the `//TODO: #8064` removal it also made was later reverted, since #8064 is not resolved |
| `e09c7bf645` | `docs(windows): enumerate modifier producers and add the triage procedure` |
| `cb4911ac5b` | `docs(windows): link the drafted producer issues and correct a source path` |
| `c1a7fa7992` | `fix(windows): release sticky OSK modifiers on every teardown path` — **UNVERIFIED, Delphi unavailable** |

| gate | result |
|---|---|
| `test:x86` | **33/33 pass**, 2 disabled (`+14` over the baseline) |
| `test:x64` | **32/32 pass**, 2 disabled (`+14`) |
| both DLLs, full `-t:Rebuild` on Win32 and x64 | **0 compiler warnings, 0 errors** |
| FR-014 mutation gate | deleting the reconcile inside `PrepareInjectedInputBatch` turns **3 tests red**; every pre-existing case stays green |
| FR-018 mutation gate | a seventh VK makes `MAX_KEYEVENT_INPUTS_MODIFIERS` become 9 **on its own** |
| G1 | red first (`13c083f216`), then green |
| G3 — is prevention complete? | **no.** 3 unmitigated producer paths, 2 in the on-screen keyboard |

**The one result that changes the story:** the on-screen keyboard can strand a
modifier machine-wide, including an unclearable extended Right Control, because
`ResetShiftStates` runs only from `FormClose` and the common dismissal paths go
through `Release`/`FreeAndNil` instead. So #8064's symptom has a second confirmed
producer and a field recurrence must be triaged rather than attributed. The
enumeration is in the Keyman tree at
`windows/src/test/manual-tests/GH-8064 - stuck-modifier-phantom-keydown/MODIFIER-PRODUCERS.md`.

### The fix, as it actually shipped

```cpp
// keymanengine.h, immediately after the keybd_shift declaration and ABOVE the #ifndef _WIN64
// region, so both architectures see it
typedef SHORT (WINAPI *PGETASYNCKEYSTATE)(int vKey);
BOOL ReconcileModifierCache(LPBYTE const kbd, PGETASYNCKEYSTATE pfnGetAsyncKeyState);
```

```cpp
// keybd_shift.cpp
BOOL ReconcileModifierCache(LPBYTE const kbd, PGETASYNCKEYSTATE pfnGetAsyncKeyState) {
  const BYTE modifiers[6] = { VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT };
  BOOL disagreed = FALSE;

  for (int i = 0; i < _countof(modifiers); i++) {
    if ((kbd[modifiers[i]] & 0x80) && pfnGetAsyncKeyState(modifiers[i]) >= 0) {
      SendDebugMessageFormat("cache says held but OS says up, clearing vkey=%s", Debug_VirtualKey(modifiers[i]));
      kbd[modifiers[i]] = 0;
      disagreed = TRUE;
    }
  }

  return disagreed;
}
```

```cpp
// serialkeyeventserver.cpp, first statement of PrepareInjectedInput
ReconcileModifierCache(m_ModifierKeyboardState, GetAsyncKeyState);
```

Two deviations from the draft in `FIX-PROPOSAL.md`, both deliberate:

- **`PGETASYNCKEYSTATE`, not `PFNGETASYNCKEYSTATE`.** The engine's own precedent is
  `globals.h:153-162` — `typedef BOOL (WINAPI *PKEYMANINIT)();`. `PFN` appears nowhere in this
  codebase.
- **No filtering of `SCAN_FLAG_KEYMAN_KEY_EVENT` / `EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT`.**
  That advice applied to a design that reads the event stream. This one reads `GetAsyncKeyState`,
  so there is no event to filter. See §3 C-10.

---

## 3. Corrections to this repo's own analysis

Every code claim in `FIX-PROPOSAL.md` and `TEST-PLAN.md` was re-checked against
`origin/master @ deeff0456f`. **All of them held.** But eleven things need correcting or adding, and
four of them change how the work has to be argued.

### C-1 — "re-pressed on every subsequent keystroke" is too strong

`keybd_shift` has **exactly two call sites in the entire repository**
(`serialkeyeventserver.cpp:388` release, `:399` reset), both inside `PrepareInjectedInput`, whose
only caller is `ProcessQueuedKeyEvents()` (`:353`), whose only caller is `WndProc` under
`if (msg == WM_USER)` (`:417-419`).

So the phantom is re-pressed on every **queued output batch** — whenever a Keyman rule produces
output — not on every keystroke. Plain keystrokes travel the `WM_KEYMAN_KEY_EVENT` path (`:440+`),
which calls `SendInput` directly and never touches `keybd_shift`.

The user-visible symptom is unchanged: once the phantom KEYDOWN lands, *those* plain replays arrive
shifted. But the PR must not claim per-keystroke re-pressing, because a reviewer who checks will
find it false.

The same fact is what makes the fix complete: one statement at the top of that one function covers
**100 %** of the phantom-press surface.

### C-2 — the fix is preventive, not curative

Not stated in `FIX-PROPOSAL.md`, and it changes the argument.

After a modifier KEYUP is dropped, the OS reports that modifier **up** while the cache says
**down**. `ReconcileModifierCache` sees exactly that disagreement. But once the first phantom
KEYDOWN has been sent, the modifier is *genuinely* held at the OS — cache and OS now **agree**, and
a `GetAsyncKeyState`-based reconcile can no longer detect anything wrong.

So the fix works only if it runs before the first phantom press. It does, because it is the first
statement in `PrepareInjectedInput` and `keybd_shift_reset` is only ever reached from further down
that same function. Batch start is therefore not merely a good placement — it is the **last point
at which prevention is possible**.

Corollary, which must not be over-claimed: this cannot *recover* an already-latched process.

### C-3 — Fix 3 of `FIX-PROPOSAL.md` would be close to a no-op. Dropped

`LowLevelHookWatchDog::KeyEventReceivedInGetMessageProc()` runs from the GetMessage hook, which is
injected into **every** application's process. `ISerialKeyEventServer::GetServer()` returns
`sm_server`, which is only ever constructed where the server runs — keyman.exe. In every other
process it is `NULL`, so the proposed reconcile returns immediately. In keyman.exe itself, the
GetMessage hook only sees keyman.exe's own keystrokes.

So it buys almost nothing, while adding a cross-process write to a 256-byte array. `FIX-PROPOSAL.md`
argued fix 3 was needed to catch "the case where the user stops typing into Keyman entirely"; on
this reading it does not catch that case either.

### C-4 — Fixes 4 and 5 need Delphi, and are coupled to the dropped fix 3

`WHR_MODIFIER_DESYNC` spans `keymancontrol.h`, `KeymanControlMessages.pas` and
`UfrmKeyman7Main.pas`. It is reported *by* fix 3, which is dropped, and `FIX-PROPOSAL.md` itself
flags that it needs a rate limiter first — a stranded cache could emit one Sentry event per
keystroke. Out of the minimal change. `SendDebugMessageFormat` inside
`ReconcileModifierCache` covers the diagnostic need with no cross-language edit.

### C-5 — Fix 2 stays out, per its own draft's advice

`FIX-PROPOSAL.md` says fix 1 "should land first and independently", and the fix 2 draft leaves
`RestartLowLevelHook`, per-thread globals and shutdown ordering unresolved. Agreed. Separate PR.

### C-6 — `k32_lowlevelkeyboardhook.cpp` is not entirely inside `#ifndef _WIN64`

The guard is **lines 31-299**. The three `#include`s at 25-27 sit above it. Any new include in that
file goes above line 31; any new code goes inside. Cosmetic here, but this repo states it as
"the whole file".

### C-7 — the gap between the two posts is 31 lines, not 35

Modifier post at `k32_lowlevelkeyboardhook.cpp:198-202`; `!isKeymanKeyboardActive` pass-through at
`:229-240`. The conclusion is unaffected — the post still precedes the filter and is not guarded by
it.

**New, and not recorded anywhere here:** there is a *second* unguarded emitter above the
pass-through — `PostVisualKeyboardModifierEvent` at `:186-188`, on the same `isModifierKey`
predicate and **not** even gated on `flag_ShouldSerializeInput`. It feeds the on-screen keyboard
rather than Cache A, so it is not part of #8064, but anyone auditing "what runs before the
pass-through" will find two things, not one.

### C-8 — `GetAsyncKeyState`'s low bit is shared, and that is a real side effect

Windows documents that the "pressed since last query" bit can be consumed by any process, and tells
callers not to rely on it. The fix adds six reads per output batch. `kmhook_callwndproc.cpp:121-123`
already calls `GetAsyncKeyState`, so this is not a new dependency — but it belongs in the PR
description rather than being discovered by a reviewer.

### C-9 — one residual regression risk, accepted and documented

If the previous batch's re-press KEYDOWN has not yet been reflected in `GetAsyncKeyState` when the
next batch begins, reconcile can clear a **genuinely held** modifier. Consequence: one output batch
emitted unshifted while the user holds the key; the cache re-arms on that modifier's next physical
KEYDOWN. Self-healing, and strictly smaller than a machine-wide latch on a key the keyboard may not
have.

The window is many milliseconds and several thread transitions wide (app → LL hook → `PostMessage`
→ client → `WM_USER` → server thread). No debounce was added. The trade is stated in the code
comment rather than left for a reviewer to find.

### C-10 — the cache is fed by Keyman's *own* synthetic modifier events

**New. Nothing in this repo notes it, and it matters twice.**

The post at `k32_lowlevelkeyboardhook.cpp:198` fires on `isModifierKey(vkCode)` alone. It does not
exclude Keyman's own injected events, because the `SCAN_FLAG_KEYMAN_KEY_EVENT` pass-through is 31
lines further down. So on every batch, `keybd_shift_release`'s KEYUP drives the cache byte to `0`
and `keybd_shift_reset`'s KEYDOWN drives it back to `0x80`.

- **The fix works with the loop, not against it.** When reconcile clears a stale byte, the release
  and reset halves emit *nothing*, so no feedback messages are generated and there is nothing to
  race. The stale byte cannot be resurrected by Keyman's own events.
- **The mid-feedback window is pre-existing, not introduced.** Because the feed is a `PostMessage`,
  a later batch can begin while the cache sits at the intermediate `0`, and reset then restores
  nothing. That is equally true *without* the fix, since reconcile only ever clears and a byte
  already `0` is untouched. So the fix adds no exposure here; C-9 is the only risk it does add.
- It is also why the draft's advice to filter Keyman's own markers does not apply — see §2.

### C-11 — a stale comment in `keybd_shift.cpp`, worth fixing in passing some day

`keybd_shift.cpp:129-130` says `keybd_shift_release`'s `kbd` parameter is the array "in which we
will store the initial modifier state for later restoration by `keybd_shift_reset`". The function
never writes `kbd` — it only reads it. Both halves read a cache owned entirely by the server. Not
touched by this change; recorded so the next reader is not misled by it.

---

## 4. Test-plan risks: three now measured

[`TEST-PLAN.md`](TEST-PLAN.md) listed six risks "in the order they will bite". Result:

| risk | standing now |
|---|---|
| **1. The `Globals_InitProcess()` fixture may be the wrong shape** — may open the live server's file mapping on a machine with Keyman running | **NOT a problem. Measured.** The fixture works, on a machine with Keyman installed and running. The `S0` fallback (prefix-VK parameter) is not needed and should be dropped from the plan |
| **2. The `csGlobals` hazard is reasoned, not observed** | **still unmeasured**, and now unmeasurable through this path: the fixture calls `Globals_InitProcess()`, so the zeroed `CRITICAL_SECTION` was never provoked. Leave it as reasoning |
| **3. The leak detector fails any test that leaks** | **MEASURED, AND IT FIRES — but not for the predicted reason.** Not `Globals_InitProcess` (that balances cleanly). It fires on **`SCOPED_TRACE`**: gtest 1.8.1's `ScopedTrace` pushes onto a trace-stack vector whose capacity is retained after the scope exits, and `_CrtMemDifference` reports it as a **168-byte leak**. Fix: drop `SCOPED_TRACE`, use per-assertion `<<` messages. **This invalidates the drafted `T-P6` and `T-S4`, both of which used it** |
| **4. `_countof` in an `int` loop** | non-issue in `keybd_shift.cpp`, which already does it. In the tests it is cast to `(int)`. The real finding is adjacent: **warnings are errors** in `keyman32.vcxproj` |
| **5. `T-P6` asserts a count over the whole VK range** | fine as drafted; passes |
| **6. `RightAltEmulationCheck` may fail on restore** | **MEASURED — it compiles and PASSES.** 20 tests / 7 cases with it enabled. So `P1` is a safe one-line change. It was deliberately **not** landed on this branch: it is unrelated to #8064 and belongs in its own commit, so a future failure there is never read as a regression from this work |

---

## 5. Deviations from the plan, and why

### The manual test is a procedure, not a new Delphi app

`TEST-PLAN.md` **P4** proposed a Delphi VCL app modelled on `keyboard_ll_identifier`, with M1-M4
additions. Replaced by
`windows/src/test/manual-tests/GH-8064 - stuck-modifier-phantom-keydown/README.md`, a procedure over
tools that already exist. Reasons:

- `manual-tests/README.md` says these tests have "generally no build process included", so a
  README-driven procedure is the directory's own convention, not a shortcut.
- Delphi is not installed on this machine, so a new VCL app could not have been compiled — it would
  have been one more never-built draft, which is exactly what this session was meant to stop
  producing.
- **M1 is a nice-to-have, not a prerequisite.** `keyboard_ll_identifier` already logs `scanCode`
  (`keyboard_ll_identifier_unit.pas:52`), so `scan = 0xFF` — the marker that identifies the phantom
  as Keyman-synthesized — **is visible today**. Only `dwExtraInfo` is missing, and the phantom does
  not need it.
- The oracle is two PowerShell snippets, **both executed before being written into the README**:
  `GetAsyncKeyState` over `0xA0`-`0xA5`, and a `keybd_event` KEYUP sweep for recovery.

The full app remains worth building for `I14` and for watching the wedge form in real time. It is
no longer on the critical path.

### `fakefreeze` was registered, not left unregistered

`TEST-PLAN.md` **P0** said the script alone is not enough and `:fakefreeze` must be registered in
`support/build.sh`, while noting the narrower alternative of leaving it unregistered "exactly as
`wow64kbd` is today". Registered, on this evidence:

- Modelled on **`etl2log`** — registered, C++, and it sets `OutDir`/`IntDir` — rather than on
  `wow64kbd`, whose `build.sh` declares outputs under `bin/Win32/...` that its vcxproj never
  produces. That is a latent bug in `wow64kbd` and a bad template.
- **`fakefreeze.vcxproj` had no `OutDir`/`IntDir`**, so MSBuild wrote to `Debug/` (Win32) and
  `x64/Debug/`. `windows/src/.gitignore` covers `**/bin/<Platform>/` and `**/obj/<Platform>/` — not
  those. That is why `fakefreeze/.gitignore` exists with a lone `x64/` line. Setting `OutDir`/
  `IntDir` the etl2log way puts everything under already-ignored paths; the `x64/` line is now dead
  but was left alone.
- **The registration risk was checked, not assumed.** `support/build.sh` runs
  `builder_run_child_actions clean configure build test publish install`, and `fakefreeze/build.sh`
  declares only `clean configure build`. In `--builder-child` mode the builder prints
  `Parameter 'test' is not supported, ignoring` and **succeeds**. Verified by running
  `./windows/src/support/build.sh --debug test:fakefreeze` → exit 0.
- `:support` is a child of `windows/src/build.sh:26`, so `./windows/build.sh` does reach it — which
  is the entire point of P0.
- The tool is deliberately **not** copied to `WINDOWS_PROGRAM_SUPPORT`: built, not packaged.

Note for anyone running the full cascade here: `./windows/src/support/build.sh test` fails at
**`oskbulkrenderer`**, a Delphi project, because Delphi is not installed. Environmental, and it
happens before `fakefreeze` is reached.

### One test exists that the plan did not specify

`RECONCILE_MODIFIER_CACHE.LeavesNonModifierBytesAlone` — asserts that bytes outside the six slots
are untouched whatever the OS reports. It is the negative-space counterpart to
`MODIFIERS.md` §2a's "a stuck letter or number is not this bug", stated as an assertion rather than
as prose.

---

## 6. Still open

Unchanged by this work, and not to be implied otherwise.

- **The ARM64 leg is unbuilt.** No ARM64 MSVC libraries on this machine. `keybd_shift.cpp` has no
  architecture guard and the new declaration sits outside the `_WIN64` region, so it should compile;
  **unverified**. CI or a machine with the ARM64 toolset must confirm.
- **The on-screen keyboard can strand a modifier, and is not fixed.** Three producer paths came back
  `UNMITIGATED` from the G3 audit, two of them in `engine/keyman/viskbd`. Issues are drafted but not
  filed, so **FR-011 is unsatisfied and prevention must not be described as complete**. A fix for two
  of the three is landed **untested** (`c1a7fa7992`) because Delphi is not installed here; the
  `SetLRShift` chirality collapse is not addressed at all. Needs a machine with Delphi.
- **The OSK findings are source-derived, not observed.** A scripted attempt to click OSK keys could
  not establish a positive control that the clicks landed, so its null result is not evidence either
  way. Each finding carries its minimal reproduction.
- **`keyboard_ll_identifier` cannot be built here.** It is Delphi with no committed binary, and it is
  the wire logger that supplies the second half of the manual test's FAIL oracle.
- **What stalls keyman.exe's main thread in the field** — [`TODO.md`](TODO.md) **I3**. The fix makes
  the consequence harmless. It does not explain the cause. Ross's focus-change observation is still
  the best lead.
- **Whether Cache A exists in the 64-bit engine** — [`TODO.md`](TODO.md) **I5**. Still an
  unverified inference. The new call site is inside `#ifndef _WIN64` by construction; the function
  itself is architecture-neutral and is unit-tested on both.
- **`NormalizeModifierVk`** (`TEST-PLAN.md` **S2**) and its tests `T-S5`-`T-S7` — not done. A pure
  testability refactor the fix does not need. Worth doing separately.
- **`P1`**, restoring `RightAltEmulationCheck.tests.cpp` to the vcxproj — probed green, deliberately
  not landed here.
- **`P3`**, the Cache B / Caps Lock tests — untouched, and out of scope for this branch: that
  defect is already PR [#16423][p16423]. See [`capslock/`](capslock/README.md).
- **The branch is not pushed and no PR is open.** #8064 has not been commented on.
  [`MEETING-PREP.md`](MEETING-PREP.md) is still the brief, and the issue is still Ross's.

[i16422]: https://github.com/keymanapp/keyman/issues/16422
[p16423]: https://github.com/keymanapp/keyman/pull/16423
