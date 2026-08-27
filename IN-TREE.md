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

**Commit hashes below are current as of 2026-08-27.** The branch was rebased at some point after
the original landing described in this section; every hash in this file up to the previous revision
was a pre-rebase alias no longer reachable from `HEAD` (verified with `git merge-base --is-ancestor`
against the untouched pre-rebase state, preserved locally as `backup/8064-preswap-4be29681b6`).
Hashes below are remapped by matching commit subjects and, where a commit was folded into another
during the rebase, by matching the test names and files each commit actually introduces. Two commits
this file previously cited no longer exist as separable commits at all — see the *Follow-on* table's
footnote.

Four commits, in this order, landed the Cache A fix itself. The first is landable on its own: it
characterises the defect without proposing a fix, so it keeps its value even if the fix is reworked
in review.

| commit (current) | subject | files |
|---|---|---|
| `914795bf58` | `test(windows): characterise the serial key event server modifier cache` | `tests/keybd_shift.tests.cpp` (new), `tests/keyman32.tests.vcxproj`, `serialkeyeventserver.cpp` |
| `4aff8fc10e` | `fix(windows): clear cached modifiers the OS reports up before injecting` | `keymanengine.h`, `keybd_shift.cpp`, `serialkeyeventcommon.h`, `serialkeyeventserver.cpp`, + tests appended |
| `bbb22576c2` | `chore(windows): add a build entry point for the fakefreeze support tool` | `support/fakefreeze/build.sh` (new), `support/fakefreeze/fakefreeze.vcxproj`, `support/build.sh` |
| `b7971ec715` | `docs(windows): add the GH-8064 manual test, producer enumeration and triage` | `test/manual-tests/GH-8064 - stuck-modifier-phantom-keydown/README.md`, `MODIFIER-PRODUCERS.md`, `TRIAGE.md` (all new) |

Totals and the "64 lines across 3 files" production-change figure are unverified against the current
tree and are superseded by §2's *Follow-on* and §2's newest-commits addendum below, which carry
current, re-measured totals.

### Results

**Current, 2026-08-27, at `HEAD` (`169d2f7c86`):**

| gate | result |
|---|---|
| `test:x86` | **72 pass, 1 disabled** |
| `test:x64` | **71 pass, 1 disabled** |
| `keyman32.dll`, Win32 Debug | links clean, 0 warnings |
| `keyman64.dll`, x64 Debug | links clean, 0 warnings |
| `keymanarm64.dll` | **still not built** — no ARM64 MSVC libraries on this machine. See §6 |
| Delphi | ~~still not installed~~ **Delphi 12.0 CE, 2026-08-27** — the OSK changes are compiled and measured; see §2b |

The 72/71 figure is the cumulative result of every commit on the branch, not just the four covered
by this section — the branch grew by two more rounds of work after the original four-commit landing
(a ten-commit follow-on, then a further round adding the `host32` reproduction harness) before the
four newest commits (§2a) landed. Do not attribute the whole delta to any one round. Immediately
before the four newest commits, the suite stood at **51 pass / 50 pass, 4 disabled** (x86/x64); before
that, at the point this section originally described, it was **33/33 pass, 2 disabled** (see
*Follow-on* below). The disabled count is now **1**, not 2 or 4 — three of the four `DISABLED_` probes
this repo's earlier revisions described as "run by hand, never in CI" were converted to self-detecting
tests in the newest round; see §2a.

| gate, at the original four-commit landing (historical) | result |
|---|---|
| `test:x86` | 19/19 pass (1 disabled) |
| `test:x64` | 18/18 pass (1 disabled) |
| `fakefreeze.exe`, x86 and x64 | builds via the new `build.sh`; clean rebuild leaves the tree clean |
| name collisions | none. `PGETASYNCKEYSTATE` and `ReconcileModifierCache` appear nowhere else in the repo, and there was no pre-existing `GetAsyncKeyState` typedef |
| blast radius of the header change | `keymanengine.h` is included by exactly two files, both PCHs (`keyman32/pch.h`, `keyman32/tests/pch.h`). Only two MSBuild projects are affected and both build. `kmtip.vcxproj` links `keyman32.lib` but includes no keyman32 header; `mcompile.vcxproj` includes only `kbd.h` |

### Follow-on — the review's five gaps, implemented

Ten further commits on the same branch, **as this file originally described it on 2026-08-26**. Of
the six items in
[`REVIEW-8064-reconcile-modifier-cache.md`](REVIEW-8064-reconcile-modifier-cache.md):
items 1, 4 and 5 are **fixed**, item 6 is **refuted** (its premise was wrong), item 3
is **answered in the negative** and item 2 is **unchanged**. Dispositions are recorded
inline in that file; the short version, hashes remapped to current (see the note at the top of §2):

| commit (current) | subject |
|---|---|
| `7417907360` | `refactor(windows): define the managed modifier set once` |
| `6af2853ffc` | `refactor(windows): extract PrepareInjectedInputBatch so the batch path is testable` |
| `4aff8fc10e` | `fix(windows): clear cached modifiers the OS reports up before injecting` — also absorbs what was a separate red-first pinning commit (`test(windows): pin the batch reconcile so removing it fails the suite`) |
| `132210bd97` | `fix(windows): release modifiers the OS holds but the cache does not` — **this is one commit now, not two.** The rebase squashed the deliberately-red characterisation test and its fix into a single commit; the `PREPARE_INJECTED_INPUT_BATCH.OsHeldModifierIsReleasedBeforeTheOutputKeys` test and the fix that turns it green both live here |
| `914795bf58` | `test(windows): characterise the serial key event server modifier cache` — also absorbs a separate fresh-thread `GetKeyboardState` probe (`DISABLED_FreshThreadKeyboardStateReflectsLiveModifiers` lives here now) |
| `b7971ec715` | `docs(windows): add the GH-8064 manual test, producer enumeration and triage` — also absorbs two separate docs commits that enumerated producers and added the triage procedure |
| `cd2bd44dd0` | `fix(windows): release sticky OSK modifiers on every teardown path` — **UNVERIFIED, Delphi unavailable** |

**One commit's content could not be confidently remapped.** A commit titled `docs(windows): correct
what the modifier-cache seed actually does` touched comments across `k32_lowlevelkeyboardhook.cpp`,
`keybd_shift.cpp` and `serialkeyeventserver.cpp` plus a manual-test README. Its content does not
survive as an isolable commit on the current branch — the same comment territory is now touched by
several later commits (candidates include `fd6f5ac87c` and `bd70725e94`), and there is no reliable way
to say which current commit, if any, is "the" successor. Treat its claims as folded into the current
tree's comments rather than attributable to one commit.

| gate, at this ten-commit follow-on (historical, 2026-08-26) | result |
|---|---|
| `test:x86` | 33/33 pass, 2 disabled (`+14` over the four-commit baseline) |
| `test:x64` | 32/32 pass, 2 disabled (`+14`) |
| both DLLs, full `-t:Rebuild` on Win32 and x64 | 0 compiler warnings, 0 errors |
| FR-014 mutation gate | deleting the reconcile inside `PrepareInjectedInputBatch` turned 3 tests red; every pre-existing case stayed green |
| FR-018 mutation gate | a seventh VK made `MAX_KEYEVENT_INPUTS_MODIFIERS` become 9 on its own |
| G1 | red first, then green |
| G3 — is prevention complete? | no. 3 unmitigated producer paths, 2 in the on-screen keyboard |

**Superseded by §2a below.** Two more rounds of work landed after this ten-commit follow-on — a
`host32` reproduction-harness round, then the four-commit residual-gaps round this file now leads
with — and the gate numbers above are no longer current. See §2's *Results* for the current 72/71
figures and §2a for what the newest four commits did.

**The one result that changes the story:** the on-screen keyboard can strand a
modifier machine-wide, including an unclearable extended Right Control, because
`ResetShiftStates` runs only from `FormClose` and the common dismissal paths go
through `Release`/`FreeAndNil` instead. So #8064's symptom has a second confirmed
producer and a field recurrence must be triaged rather than attributed. The
enumeration is in the Keyman tree at
`windows/src/test/manual-tests/GH-8064 - stuck-modifier-phantom-keydown/MODIFIER-PRODUCERS.md`.

**Since superseded.** The two OSK findings referenced above were UNMITIGATED at this point in the
history. §2a closes the teardown-path chirality collapse; **§2b closes the live click-off as well**,
and rows `2a` and `2b` of the producer enumeration are now `mitigated`, compiled and measured. Do not
read the paragraph above as describing current standing on the OSK — see §2b.

### 2a. Four newest commits, 2026-08-27 — closing residual pathways a five-lens audit found

Landed after the `host32` reproduction-harness round (which is not otherwise covered by this repo).
In order:

| commit | subject |
|---|---|
| `e245c41845` | `fix(windows): pass a key event through when the serializer handoff fails` |
| `5ba72fa3c9` | `fix(windows): release a modifier the OS still holds when the batch ends` |
| `3d64aad790` | `fix(windows): release sticky OSK modifiers by their injected chiral identity` |
| `169d2f7c86` | `docs(windows): re-verify the producer enumeration against the residual fixes` |

**`e245c41845` — the hook stopped destroying input on a failed handoff.** The low-level hook used to
eat the user's key event unconditionally (returning 1, so `CallNextHookEx` was never reached) and
`PostMessage` it to the serial key event server without checking success. When that post failed —
`GetWindow()` returning `NULL` during server startup/teardown, a stalled client blocking
`ProcessQueuedKeyEvents`'s `INFINITE` wait until the 10,000-message queue fills, or `MessageLoop`
exiting on the exit event with key events still queued — the event was simply destroyed. For a
modifier KEYUP specifically, that loss is a direct route into #8064: the matching KEYDOWN had already
been delivered and re-injected, so cache and OS end up **agreeing** the modifier is down — agreement
being the one state the clear-only reconcile is built to trust, so no later batch can ever detect it.
Now the hook eats only on a confirmed post to a non-**`NULL`** window, otherwise falls through to
`CallNextHookEx`; note `PostMessage(NULL, …)` does not fail usefully, it misroutes to the calling
thread's own queue, so the `NULL` window has to be tested for rather than inferred from a return
value. The posting-side modifier trace that `348b59803f` deleted is also restored, scoped to modifier
keys and now recording provenance filtering and post success.

**`5ba72fa3c9` — a post-batch verification pass closes the pass-through race and a related regression.**
`ReconcileModifierCache` runs before a batch is assembled, so it cannot see a user release landing
between `CaptureLiveModifierState` and the batch reaching the OS. Two confirmed sequences end that
way: the **pass-through race** — mstsc stamps `dwExtraInfo=0x4321DCBA`, and the same applies to the
touch panel being visible, console focus, and `GetGUIThreadInfo` failure — under which the user's
modifiers feed the cache but reach the OS un-eaten, so their ordering against a batch's own
`SendInput` is not Keyman's to control; and the C-9 residual this file previously recorded as
"accepted and documented" below. Both leave the batch's own restore press outliving a real release
that the cache correctly learned about (because it was the user's own event, not Keyman's), with the
OS left holding a modifier nobody holds. The fix: `PrepareInjectedInputBatch` reports which managed
modifiers its restore half pressed as a bitmask, and the server posts itself
`WM_KEYMAN_VERIFY_MODIFIER_EVENT` when that mask is non-empty. Posted messages are FIFO, so by the
time it is dispatched every modifier event the hook posted before it — including a racing release —
has already been applied to the cache; the handler then injects a corrective KEYUP for anything the
OS still holds that the cache now says is up. **This is a curative move for the batch-produced case
specifically — see the REVIEW file's item 2 for why it is not the general tray-action cure that item
was asking for.** Separately fixed in the same commit: with `flag_ShouldSerializeInput` off, the G1
union release was releasing live-held modifiers the restore half had no record of — a lost-modifier
regression introduced by G1 itself, now made conditional on the cache actually being fed. Also in
this commit: three of the four `DISABLED_` probes underpinning this design (the fresh-thread
`GetKeyboardState` seed, `SendInput`/`GetAsyncKeyState` visibility ordering, and `dwExtraInfo`
surviving `SendInput` to the hook) now self-detect whether the desktop can exercise the mechanism and
assert for real where it can, rather than running only by hand — gtest 1.8.1.7 has no `GTEST_SKIP`,
so this uses the log-and-pass substitute already established in the test file. **A new measurement
closes an open question rather than merely arguing it:** injecting a third party's generic
`SendInput(wVk=VK_SHIFT, wScan=0)` and reading `GetAsyncKeyState VK_SHIFT=0x8000 VK_LSHIFT=0x8001
VK_RSHIFT=0x0000` while the hook observes `vk=0xA0 scan=0x00 flags=0x10` shows Windows re-chiralises a
scan-0 generic injection **before** the low-level hook — so the cache byte and the live reading land
in the same slot, and the reconcile cannot erase a generic-VK press. An audit had raised that erasure
as a probable defect; it is now closed by measurement.

**`3d64aad790` — OSK teardown now releases by injected chiral identity. UNTESTED, Delphi
unavailable.** `ResetShiftStates` now releases from `FCachedShiftState` directly, one call per chiral
VK with its own extended flag, gated on a live `GetAsyncKeyState` check — bypassing `kbd.ShiftState`
and `kbd.LRShift`, whose `SetLRShift` collapse (`essLCtrl`/`essRCtrl` → `essCtrl`,
`essLAlt`/`essRAlt` → `essAlt`) was the reason teardown could release the wrong key or fail to release
at all. This fixes the `SetLRShift` chirality collapse **for the teardown path only.** Also fixed:
`kbdKeyPressed`'s stale-async re-press, and the `LRShift` regime is now frozen into `LLRShift` so a
mid-keystroke keyboard switch cannot leave a suppression unrestored. **The live click-off path was still open at this
point**; a fix had been written and reverted, because the same `ShiftStateChange` function is also
reached from `UpdateShiftStates`' 50 ms resync, whose press branch fires for physically-held
modifiers — recording those into `FCachedShiftState` would let teardown release a key the user still
has down, reintroducing the I2177 regression. **Closed later the same day — see §2b**, which explains
why that objection turned out not to apply.

**`169d2f7c86` — `MODIFIER-PRODUCERS.md` and `TRIAGE.md` re-verified**, not merely re-read: new rows
for the pass-through race and the eaten-event pipeline loss (both now mitigated, with the row noting
the underlying reasons a handoff can fail — the `INFINITE` mutex wait, `MessageLoop` exiting with
events pending — are untouched; the hook merely degrades safely now), and a new row for
process-termination-while-an-OSK-modifier-is-held (**UNMITIGATED** — no watchdog, no
restore-on-start, and a blind release-all at startup was rejected as unsafe, since it would strip a
modifier the user is genuinely holding at launch). Verdicts deliberately **not** upgraded at this point: the two OSK
findings kept UNMITIGATED even though fixes were in the tree, because Delphi was not installed and
nothing had compiled or run. **Both were upgraded on 2026-08-27 once it did — see §2b.** Rows 1 and 9 of the producer enumeration are marked mitigated but flagged
**source-reasoned, not re-run** — the live `host32` harness that measured the original 5/5-to-0/5
freeze reproduction has not been run against these changes. FR-011 remains unsatisfied; the banner
still says four rows unmitigated.

**Gates for this round:** `test:x86` 72 pass (1 disabled), `test:x64` 71 pass (1 disabled), both
DLLs link clean with 0 warnings. ARM64 still not built; Delphi still not installed.

### 2b. 2026-08-27 — Delphi arrives, the OSK fixes are measured, and two more defects fall out

Delphi 12.0 CE was installed and the OSK changes compiled for the first time. Everything in §2a about
the Pascal side had been source-reasoned; this is what happened when it ran. The record is in the
Keyman tree at `evidence/run-osk-teardown-2026-08-27.txt` and `evidence/run-osk-clickoff-2026-08-27.txt`.

**The checklist earned its keep immediately.** Step 6 — hold a physical modifier, click a sticky one,
dismiss — **failed**. The teardown fix had reintroduced I2177. `UpdateShiftStates` ends with
`kbd.ShiftState := GetAsyncShiftState`, so `kbd.ShiftState` continuously carries physically-held
modifiers, and `kbdShiftChange` assigned it wholesale into `FCachedShiftState`; a click made while
Shift was held cached `essShift` alongside the key clicked, and `ReleaseCached` released it. The
`GetAsyncKeyState` gate cannot catch that, because a physically-held key genuinely *is* down. Three
prior source reads had missed it, including one whose comment asserted the resync could not
contaminate the cache "because `FCachedShiftState` is written from a click and only from a click" —
true of *when* it is written, irrelevant to *what* it captures. Fixed in `4ca0945a12`.

**Finding 4b was then closed, and the objection in §2a turned out not to apply.** Both previously
rejected designs assumed the release path had to *maintain* `FCachedShiftState`, and a write from the
50 ms resync is precisely what produced the I2177 regression. But picking the right VK needs only a
**read** of a record that `kbdShiftChange` already guarantees excludes physically-held modifiers.
Reads and removals cannot reintroduce I2177; only additive writes can. **The click-vs-resync
distinction was never the requirement — it was an artifact of assuming a write.** `791c5f181a`.

**One more defect, caused by the first fix.** `4ca0945a12`'s mask ran *before* `ShiftStateChange`, and
after a `SetLRShift` collapse a click-off leaves `fkcss` carrying nothing from that family, so
`* fkcss` stripped `essRCtrl` from the cache one line before the release read it. The 4b fix was
correct and unreachable, and step 8 failed identically until `ea530407c2` reordered the two and
widened the mask across the Ctrl/Alt families.

**Verdicts.** Rows `2a` and `2b` are now `mitigated`, compiled and confirmed by executed
reproductions in both collapse directions. FR-011 is down to two unmitigated rows, `2c` and `8`.

**Method notes worth carrying forward.**

- The final runs were taken with **`KLOGGING`** defined, so each verdict rests on the injected
  `keybd_event` (`vk`/`scan`/`flags`) rather than on inference from a 60 ms modifier poller. Three
  build cycles were spent inferring event shapes before this was enabled; it should have been step
  one. Note the blind spot: it instruments `keyman.exe` only, and `keyman32.dll` injects from inside
  hooked processes via the C++ ETW path, invisible to an `OutputDebugString` capture.
- Two step-6 runs were **INCONCLUSIVE rather than failed**, because sending a chat message required
  pressing Enter, which meant releasing the very key under test. A log cannot separate "the fix
  released your Shift" from "the tester let go". Pre-typing and sending with the mouse fixed it; so
  did the better instrument — after the dismissal, *typing a letter* and seeing whether it capitalises
  answers the question with no timing judgement at all.
- Three environment defects surfaced and are recorded as **I19**, **I20**, **I21** in `TODO.md`.
  **I19 is the dangerous one**: when the OSK's `VKI` goes nil, `kbd.LRShift` is pinned True, and any
  test needing the chiral collapse becomes unrunnable while still *appearing* to pass.

### The fix, as it originally shipped (historical — see §2a for the residual fixes layered on top)

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

**Updated 2026-08-27.** The read count is now larger than "six per batch": `5ba72fa3c9`'s post-batch
verification pass calls `GetAsyncKeyState` again, once per managed modifier the batch's restore half
pressed, when the corrective `WM_KEYMAN_VERIFY_MODIFIER_EVENT` fires. The shared-low-bit caveat above
applies identically to those reads; nothing about the mechanism changes, there are simply more call
sites now, and the PR description should say so.

### C-9 — one residual regression risk, now substantially closed

**This section previously read "accepted and documented," describing the risk as a deliberate,
undebounced trade-off. `5ba72fa3c9` closes the specific race this section described — not by
debouncing, but by verification.** The original text is kept below for the record, followed by the
current standing.

Original text: if the previous batch's re-press KEYDOWN has not yet been reflected in
`GetAsyncKeyState` when the next batch begins, reconcile can clear a **genuinely held** modifier.
Consequence: one output batch emitted unshifted while the user holds the key; the cache re-arms on
that modifier's next physical KEYDOWN. Self-healing, and strictly smaller than a machine-wide latch
on a key the keyboard may not have. The window is many milliseconds and several thread transitions
wide (app → LL hook → `PostMessage` → client → `WM_USER` → server thread). No debounce was added at
the time this was written.

**Current standing.** `5ba72fa3c9` adds a post-batch self-post, `WM_KEYMAN_VERIFY_MODIFIER_EVENT`,
carrying a bitmask of what the restore half pressed. Because posted messages are FIFO, by the time
that message is dispatched every modifier event the hook posted ahead of it — including a racing
physical release — has already reached the cache, so the handler can inject a corrective KEYUP for
anything the OS still holds that the cache now says is up. This closes the batch-produced instance of
C-9 as a **measured** fix (unit-tested, not merely reasoned about), not by debouncing the window but
by re-checking after it closes. What remains true: this is still a batch-scoped correction, not a
continuous invariant — a race landing after the verification message is itself dispatched (a second
physical event arriving in the few milliseconds the correction takes to queue and apply) is still
possible in principle and is not separately tested. Do not describe C-9 as eliminated as a general
class of race; describe it as closed for the specific sequence this section originally identified.

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

Re-verified 2026-08-27 against the four newest commits. Items below are marked **unchanged** where
this session's work did not touch them, and rewritten where it did.

- **The ARM64 leg is unbuilt — unchanged.** No ARM64 MSVC libraries on this machine. Nothing in the
  four newest commits adds an architecture guard, so the same "should compile, unverified" standing
  applies to their code as to the original fix. CI or a machine with the ARM64 toolset must confirm.
- **The on-screen keyboard can strand a modifier — partly fixed, one path still open.** The teardown
  path (`ResetShiftStates`, reached from every dismissal route since `cd2bd44dd0`) now releases by
  injected chiral identity rather than through the `kbd.LRShift`-collapsed `ShiftStateChange`
  (`3d64aad790`) — but this is **UNTESTED**, Delphi is not installed here, so nothing compiled or ran.
  **The live click-off path is deliberately not fixed.** A fix was written and reverted in this
  session because the function it would change, `ShiftStateChange`, is also reached from the 50 ms
  resync that presses physically-held modifiers, and recording those would reintroduce the I2177
  regression. Tracked as Finding 4b in the Keyman tree's `MODIFIER-PRODUCERS.md`. Because Delphi is
  uncompiled, **neither** OSK verdict is upgraded from `UNMITIGATED` in the producer enumeration —
  see §2a — regardless of what the source now says.
- **The pass-through race and the eaten-event pipeline loss — fixed and unit-tested.** `e245c41845`
  and `5ba72fa3c9` (§2a). These were open items as of the previous revision of this file; they are
  not any more, and this is a C++ fix, so it clears the compiled-and-tested bar this repo requires.
- **The OSK findings are source-derived, not observed.** Unchanged. A scripted attempt to click OSK
  keys could not establish a positive control that the clicks landed, so its null result is not
  evidence either way. Each finding carries its minimal reproduction.
- **`keyboard_ll_identifier` cannot be built here.** Unchanged. It is Delphi with no committed binary,
  and it is the wire logger that supplies the second half of the manual test's FAIL oracle.
- **What stalls keyman.exe's main thread in the field** — [`TODO.md`](TODO.md) **I3** — **still open,
  untouched by the four newest commits.** The fix makes the consequence harmless; it does not explain
  the cause. Ross's focus-change observation is still the best lead.
- **Whether Cache A exists in the 64-bit engine** — [`TODO.md`](TODO.md) **I5** — **still an
  unverified inference, untouched.** The call site is still inside `#ifndef _WIN64` by construction;
  the function itself is architecture-neutral and is unit-tested on both.
- **`NormalizeModifierVk`** (`TEST-PLAN.md` **S2**) and its tests `T-S5`-`T-S7` — still not done. A
  pure testability refactor the fix does not need. Worth doing separately.
- **`P1`**, restoring `RightAltEmulationCheck.tests.cpp` to the vcxproj — still probed green,
  deliberately not landed here.
- **`P3`**, the Cache B / Caps Lock tests — untouched, and out of scope for this branch: that
  defect is already PR [#16423][p16423]. See [`capslock/`](capslock/README.md).
- **The `host32` live re-run of producer rows 1 and 9 is still owed.** Both are marked mitigated in
  the current `MODIFIER-PRODUCERS.md` but flagged source-reasoned rather than re-run: the live
  `host32` harness that measured the original 5/5-to-0/5 freeze reproduction has not been run against
  the current tree. New with §2a; do not read "mitigated" in that file as re-measured.
- **The branch push status was re-checked, not assumed, 2026-08-27.** Still not usably pushed: the
  local branch's upstream tracking ref (`MattGyverLee/fix/windows/8064-reconcile-modifier-cache`)
  reports **gone** — consistent with a prior push having been superseded by a later rebase that was
  never force-pushed — and no branch of this name is visible on the fork remote. #8064 has not been
  commented on. [`MEETING-PREP.md`](MEETING-PREP.md) is still the brief, and the issue is still
  Ross's.

[i16422]: https://github.com/keymanapp/keyman/issues/16422
[p16423]: https://github.com/keymanapp/keyman/pull/16423
