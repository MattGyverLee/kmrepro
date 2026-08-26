# Test plan — porting these findings into Keyman

**Plan, plus draft code that has never been compiled.** No Keyman code change
is proposed here as a landed patch; the blocks in "The code" and "The minimal
seams" below are drafts pending in-place testing.
Before talking to the team, read **[MEETING-PREP.md](MEETING-PREP.md)** — this is [#8064][i8064], it is Ross's issue, and he has already found much of it independently.

Mechanism: [MODIFIERS.md]. Three-arm proof: [TRIGGER.md]. Log: [TODO.md]. Harness hazards: [HAZARDS.md]. Ross's field evidence and the closure path: [issue-8064/](issue-8064/README.md).

Code refs are `keymanapp/keyman` @ `a70538106c`, paths under `windows/src/engine/keyman32/`.

---

## 1. Why it has not reproduced on a clean VM

**Load was never the mechanism.** Measured on 18.0.249.0:

| freeze | CPU load | iters | failures |
|---|---|---|---|
| no | 32 | 10 | **0** |
| **yes** | 0 | 10 | **10** |
| **yes** | 32 | 10 | **10** |

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

**Two more reasons a careful tester sees nothing:** a stuck Ctrl/Alt causes *no case change* (keys are swallowed), so a text oracle scores it CLEAN — [MODIFIERS.md §2b][m2b] shows RCTRL held while text read correct lowercase. And a bare Alt press/release mimics the bug with Keyman uninvolved ([TRIGGER.md §"Harness traps found the hard way"][tr3]). Use `GetAsyncKeyState`; prefer LShift.

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
| 6 | Feed sits **35 lines before** the pass-through filter ⇒ the cache re-confirms its own hallucination, and charges while Keyman is inactive (**3/3**) | [`:229`][llh229], [TRIGGER §3][tr3] |
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

- **T-R3** *(Cache A invariant)* — `keybd_shift(…, TRUE, kbd)` with
  `kbd[VK_LSHIFT]=0x80` must emit no KEYDOWN for a VK `GetAsyncKeyState`
  reports up. RED. Fix = [TODO D1][todo].

  **[WARN]** Unlike the Cache B pair this asserts the *shape of the fix*, not
  current-vs-correct behaviour — and on inspection it asserts against the
  design, because re-pressing a genuinely-held modifier is what
  `keybd_shift_reset` is *for* and from inside the function a stale byte and a
  real one are identical. So it is written `DISABLED_` and run by hand as a
  demonstration artifact, never as a CI gate. Its green counterpart is
  `ReconcileThenResetPressesNothing` in [The minimal seams](#the-minimal-seams),
  and the one-line diff between the two *is* D1. Both are drafted, uncompiled,
  in [The code](#the-code).

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
| **T-R3** | `DISABLED_ResetDoesNotPressAKeyThatIsNotHeld` | reset must not emit a KEYDOWN for a modifier the OS reports up | **fails by design** — the function has no live-state input. `DISABLED_`, run by hand |
| **T-S1-S7** | `RECONCILE_MODIFIER_CACHE.*`, `NORMALIZE_MODIFIER_VK.*` | the two seams below, incl. `ReconcileThenResetPressesNothing` = T-R3 + one line | pass **once the seams land** |

### The code

> **[WARN] PENDING IN-PLACE TESTING.** Everything in this subsection was written
> against `../keyman` @ `a70538106c` and has **never been compiled and never been
> run** — the NuGet package is not restored in that checkout, so not one line has
> been through a compiler. Treat each block as a reviewed draft, not a result.
> The risk list is at the end of the subsection; its first item is the one most
> likely to bite.

#### gtest 1.8.1 is the constraint, not gtest

`tests/packages.config` pins
`Microsoft.googletest.v140.windesktop.msvcstl.static.rt-static` **1.8.1.7**.
Checked against the `release-1.8.1` headers, because the current googletest
documentation describes a much later API and quietly offers things this build
does not have:

| construct | in 1.8.1 | consequence here |
|---|---|---|
| `GTEST_SKIP()` | **absent** — added in 1.10.0 | precondition guards use `GTEST_LOG_(WARNING)` + `SUCCEED()` + `return` |
| `INSTANTIATE_TEST_SUITE_P` | **absent** — 1.8.1 has `INSTANTIATE_TEST_CASE_P` | no parameterised test is used below |
| `TYPED_TEST_SUITE` | **absent** — 1.8.1 has `TYPED_TEST_CASE` | not used |
| gmock | **not linked** — `AdditionalDependencies` names no gmock lib | no `EXPECT_THAT`, no `MOCK_METHOD`; the stub readers below are plain function pointers |
| `TEST`, `TEST_F`, `EXPECT_EQ/NE/LE`, `ASSERT_EQ/NE/TRUE`, `EXPECT_TRUE/FALSE`, `SUCCEED`, `SCOPED_TRACE`, `GTEST_LOG_`, `DISABLED_` prefix | present | the whole vocabulary used below |

`SetUp`/`TearDown` are declared without `override`, matching the existing
`kmprocessactions.tests.cpp` fixture.

#### T-P1…T-P6, T-R3 — `tests/keybd_shift.tests.cpp` (new)

`keybd_shift()` is the only one of the four functions in `keybd_shift.cpp` with a
header declaration (`keymanengine.h:231`), and `pch.h` already includes that
header — so no `extern` is needed and every assertion goes through the public
entry point. `SCAN_FLAG_KEYMAN_KEY_EVENT` arrives via `keyman64.h:132`, also
already in `pch.h`.

```cpp
#include "pch.h"
#include "kbd.h"                    // SCANCODE_RSHIFT (0x36)
#include "serialkeyeventcommon.h"   // MAX_KEYEVENT_INPUTS, MAX_KEYEVENT_INPUTS_MODIFIERS

/*
  Cache A characterisation tests -- keymanapp/keyman#8064.

  These tests do not stall a thread, sleep, spawn a thread or pump messages.
  A dropped modifier KEYUP has exactly one residue: one byte of the 256-byte
  array that keybd_shift() reads. So the stall is simulated by constructing that
  residue directly, and every test here is a byte array and a function call.
  That keeps them inside the bar set by windows/src/test/unit-tests/README.md:
  "should not have complex environmental requirements nor require an installed
  version of the software in order to complete".
*/

// The prefix VK is seeded by Globals::InitSettings() (k32_globals.cpp:374) from
// HKLM, and Globals_InitProcess() does not call it. Pin it rather than depend on
// the machine's registry.
static const BYTE PREFIX_VK = _VK_PREFIX_DEFAULT;   // appint/aiTIP.h:36 -> 0x0E

class KEYBD_SHIFT : public ::testing::Test {
public:
  void SetUp() {
    // keybd_shift's SendDebugEntry/SendDebugMessageFormat macros evaluate
    // ShouldDebug() -> ThreadGlobals() -> EnterCriticalSection(&csGlobals), and
    // csGlobals is only ever initialised by Globals_InitProcess()
    // (k32_globals.cpp:161). Calling keybd_shift without this enters a zeroed
    // CRITICAL_SECTION: undefined behaviour, not merely untidy. Same pattern as
    // kmprocessactions.tests.cpp.
    Globals_InitProcess();
    Globals::set_vk_prefix(PREFIX_VK);

    memset(kbd, 0, sizeof(kbd));
    memset(inputs, 0, sizeof(inputs));
    n = 0;
  }

  void TearDown() {
    Globals_UninitProcess();
  }

protected:
  BYTE kbd[256];
  INPUT inputs[MAX_KEYEVENT_INPUTS];
  int n;

  // Number of queued events for wVk in one direction.
  int Count(WORD wVk, bool isUp) const {
    int count = 0;
    for (int i = 0; i < n; i++) {
      if (inputs[i].ki.wVk == wVk && (((inputs[i].ki.dwFlags & KEYEVENTF_KEYUP) != 0) == isUp)) {
        count++;
      }
    }
    return count;
  }

  // Index of the first queued event for wVk in one direction, or -1.
  int IndexOf(WORD wVk, bool isUp) const {
    for (int i = 0; i < n; i++) {
      if (inputs[i].ki.wVk == wVk && (((inputs[i].ki.dwFlags & KEYEVENTF_KEYUP) != 0) == isUp)) {
        return i;
      }
    }
    return -1;
  }

  void Rewind() {
    memset(kbd, 0, sizeof(kbd));
    memset(inputs, 0, sizeof(inputs));
    n = 0;
  }
};

/*
  T-P1: the phantom press, in Keyman's own harness.

  Passes today. This is not a red test -- it is the defect, characterised, and it
  is the artifact to put in front of the team. Given a single stale byte,
  keybd_shift_reset presses a modifier for real and never releases it.
*/
TEST_F(KEYBD_SHIFT, ResetRepressesFromCache) {
  kbd[VK_LSHIFT] = 0x80;

  keybd_shift(inputs, &n, TRUE, kbd);

  ASSERT_EQ(n, 3);

  EXPECT_EQ(inputs[0].ki.wVk, (WORD)VK_SHIFT);
  EXPECT_EQ(inputs[0].ki.dwFlags & KEYEVENTF_KEYUP, (DWORD)0);
  EXPECT_EQ(inputs[0].ki.wScan, (WORD)SCAN_FLAG_KEYMAN_KEY_EVENT);

  EXPECT_EQ(inputs[1].ki.wVk, (WORD)PREFIX_VK);
  EXPECT_EQ(inputs[1].ki.dwFlags & KEYEVENTF_KEYUP, (DWORD)0);
  EXPECT_EQ(inputs[2].ki.wVk, (WORD)PREFIX_VK);
  EXPECT_EQ(inputs[2].ki.dwFlags & KEYEVENTF_KEYUP, (DWORD)KEYEVENTF_KEYUP);

  // THE DEFECT: a modifier KEYDOWN with no matching KEYUP anywhere in the batch.
  // Passed to SendInput, this latches the modifier machine-wide.
  EXPECT_EQ(Count(VK_SHIFT, false), 1);
  EXPECT_EQ(Count(VK_SHIFT, true), 0) << "if this ever reads 1, #8064 is fixed at this layer";
}

/*
  T-P2: locks the release contract -- prefix down+up first, then the keyups. The
  prefix is what stops a bare Alt release activating the window menu, so its
  position relative to the keyups is load-bearing, not cosmetic.
*/
TEST_F(KEYBD_SHIFT, ReleaseEmitsPrefixThenKeyups) {
  kbd[VK_LSHIFT] = 0x80;

  keybd_shift(inputs, &n, FALSE, kbd);

  ASSERT_EQ(n, 3);

  EXPECT_EQ(inputs[0].ki.wVk, (WORD)PREFIX_VK);
  EXPECT_EQ(inputs[0].ki.dwFlags & KEYEVENTF_KEYUP, (DWORD)0);
  EXPECT_EQ(inputs[1].ki.wVk, (WORD)PREFIX_VK);
  EXPECT_EQ(inputs[1].ki.dwFlags & KEYEVENTF_KEYUP, (DWORD)KEYEVENTF_KEYUP);

  EXPECT_EQ(inputs[2].ki.wVk, (WORD)VK_SHIFT);
  EXPECT_EQ(inputs[2].ki.dwFlags & KEYEVENTF_KEYUP, (DWORD)KEYEVENTF_KEYUP);

  // The release half is balanced by construction: it only ever emits keyups.
  EXPECT_EQ(Count(VK_SHIFT, false), 0);
}

/*
  T-P3: proof step 5. VK_RCONTROL is never emitted; it collapses to VK_CONTROL
  plus KEYEVENTF_EXTENDEDKEY, and the extended bit is the only thing separating
  the two sides. On hardware with no physical Right Ctrl key the resulting latch
  cannot be cleared by any keystroke the user is able to produce -- MODIFIERS.md
  section 3b, measured.
*/
TEST_F(KEYBD_SHIFT, RightControlCollapsesToExtendedControl) {
  kbd[VK_RCONTROL] = 0x80;
  keybd_shift(inputs, &n, TRUE, kbd);

  int i = IndexOf(VK_CONTROL, false);
  ASSERT_NE(i, -1);
  EXPECT_EQ(inputs[i].ki.dwFlags & KEYEVENTF_EXTENDEDKEY, (DWORD)KEYEVENTF_EXTENDEDKEY);
  EXPECT_EQ(Count(VK_RCONTROL, false), 0) << "VK_RCONTROL must never reach SendInput";

  Rewind();

  kbd[VK_LCONTROL] = 0x80;
  keybd_shift(inputs, &n, TRUE, kbd);

  i = IndexOf(VK_CONTROL, false);
  ASSERT_NE(i, -1);
  EXPECT_EQ(inputs[i].ki.dwFlags & KEYEVENTF_EXTENDEDKEY, (DWORD)0);
  EXPECT_EQ(Count(VK_LCONTROL, false), 0);
}

/*
  T-P4: Right Shift is the exception to Keyman's own synthesized-key marker.
  Shift's side is carried by the scan code alone, so do_keybd_event must spend the
  0xFF marker slot on SCANCODE_RSHIFT instead -- see the keybd_shift.cpp file
  comment. The extended bit is NOT how Shift's side is decided.
*/
TEST_F(KEYBD_SHIFT, RightShiftCollapsesToShiftWithRightScanCode) {
  kbd[VK_RSHIFT] = 0x80;

  keybd_shift(inputs, &n, TRUE, kbd);

  int i = IndexOf(VK_SHIFT, false);
  ASSERT_NE(i, -1);
  EXPECT_EQ(inputs[i].ki.wScan, (WORD)SCANCODE_RSHIFT);
  EXPECT_NE(inputs[i].ki.wScan, (WORD)SCAN_FLAG_KEYMAN_KEY_EVENT)
      << "Right Shift is the one modifier that cannot carry Keyman's synthesized-key marker";
  EXPECT_EQ(inputs[i].ki.dwFlags & KEYEVENTF_EXTENDEDKEY, (DWORD)0)
      << "Shift's side comes from the scan code, never the extended flag";

  Rewind();

  kbd[VK_LSHIFT] = 0x80;
  keybd_shift(inputs, &n, TRUE, kbd);

  i = IndexOf(VK_SHIFT, false);
  ASSERT_NE(i, -1);
  EXPECT_EQ(inputs[i].ki.wScan, (WORD)SCAN_FLAG_KEYMAN_KEY_EVENT);
}

/*
  T-P5: MAX_KEYEVENT_INPUTS_MODIFIERS is 8, and serialkeyeventcommon.h:8-11 says
  so in a comment ending "This value depends on keybd_shift behaviour".
  PrepareInjectedInput reserves exactly that much tail space
  (serialkeyeventserver.cpp:391). Nothing enforces the dependency; this does.
*/
TEST_F(KEYBD_SHIFT, ModifierEventCountNeverExceedsReserve) {
  const BYTE allSix[6] = { VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT };
  for (int i = 0; i < _countof(allSix); i++) {
    kbd[allSix[i]] = 0x80;
  }

  keybd_shift(inputs, &n, TRUE, kbd);
  EXPECT_EQ(n, 8) << "6 modifier keydowns + prefix down + prefix up";
  EXPECT_LE(n, MAX_KEYEVENT_INPUTS_MODIFIERS);

  n = 0;
  keybd_shift(inputs, &n, FALSE, kbd);
  EXPECT_EQ(n, 8) << "prefix down + prefix up + 6 modifier keyups";
  EXPECT_LE(n, MAX_KEYEVENT_INPUTS_MODIFIERS);
}

/*
  T-P6: isModifierKey() decides which key events reach the Cache A feed at
  k32_lowlevelkeyboardhook.cpp:200, so it defines the blast radius. Nine accepted
  VKs collapse to six cache slots. The negative half is the measured result from
  MODIFIERS.md section 2b: those seven keys latched 0/2 under the identical
  stimulus that latched all six modifiers 2/2, and this is why.

  x86 only: the enclosing file is #ifndef _WIN64 (k32_lowlevelkeyboardhook.cpp:31),
  so this compiles out of the x64 run rather than breaking it. It lives in this
  file rather than its own because it is an assertion about Cache A's slot set --
  and because a test file absent from the vcxproj goes dark for eight months,
  which is exactly what happened to RightAltEmulationCheck.tests.cpp.
*/
#ifndef _WIN64
extern BOOL isModifierKey(DWORD vkCode);

TEST(K32LowLevelKeyboardHook, IsModifierKeyAcceptsExactlyNineVks) {
  const DWORD accepted[9] = {
    VK_LCONTROL, VK_RCONTROL, VK_CONTROL,
    VK_LMENU,    VK_RMENU,    VK_MENU,
    VK_LSHIFT,   VK_RSHIFT,   VK_SHIFT,
  };

  int acceptedCount = 0;
  for (DWORD vk = 0; vk < 256; vk++) {
    if (isModifierKey(vk)) {
      acceptedCount++;
    }
  }
  EXPECT_EQ(acceptedCount, (int)_countof(accepted))
      << "the accepted VK set changed; Cache A's six slots and MODIFIERS.md section 2 depend on it";

  for (int i = 0; i < _countof(accepted); i++) {
    SCOPED_TRACE(accepted[i]);
    EXPECT_TRUE(isModifierKey(accepted[i]));
  }

  // Measured immune, 0/2 each, under the stimulus that latched all six modifiers.
  EXPECT_FALSE(isModifierKey(VK_CAPITAL));
  EXPECT_FALSE(isModifierKey(VK_NUMLOCK));
  EXPECT_FALSE(isModifierKey(VK_SCROLL));
  EXPECT_FALSE(isModifierKey(VK_INSERT));
  EXPECT_FALSE(isModifierKey(VK_LWIN));
  EXPECT_FALSE(isModifierKey(VK_RWIN));
  EXPECT_FALSE(isModifierKey(VK_APPS));
}
#endif  // !_WIN64

/*
  T-R3: the gap, stated as an assertion.

  Cache A says Left Shift is held. The OS says it is not. That is precisely the
  state a dropped modifier KEYUP leaves behind, and keybd_shift_reset re-presses
  it anyway, because it has no live-state input to consult.

  DISABLED_ deliberately. This test can never pass without changing what
  keybd_shift is FOR -- re-pressing a genuinely-held modifier is its job, and from
  inside the function a stale byte and a real one are identical. So it is a
  demonstration artifact, not a regression gate, and it must not be allowed to
  turn CI red:

      keyman32.tests.exe --gtest_also_run_disabled_tests \
        --gtest_filter=KEYBD_SHIFT.DISABLED_ResetDoesNotPressAKeyThatIsNotHeld

  The version that does go green is ReconcileThenResetPressesNothing, below. The
  diff between the two is one line, and that one line is fix D1.
*/
TEST_F(KEYBD_SHIFT, DISABLED_ResetDoesNotPressAKeyThatIsNotHeld) {
  // gtest 1.8.1 has no GTEST_SKIP(). Bail out visibly rather than assert on a
  // machine where a modifier really is held -- that would pass for the wrong reason.
  if (GetAsyncKeyState(VK_LSHIFT) < 0) {
    GTEST_LOG_(WARNING) << "Left Shift reads down; precondition unmet, not evaluated";
    SUCCEED();
    return;
  }

  kbd[VK_LSHIFT] = 0x80;

  keybd_shift(inputs, &n, TRUE, kbd);

  EXPECT_EQ(Count(VK_SHIFT, false), 0)
      << "keybd_shift_reset queued a KEYDOWN for VK_SHIFT while GetAsyncKeyState reports it up. "
      << "That unmatched KEYDOWN is keymanapp/keyman#8064: SendInput latches Shift machine-wide "
      << "until the exact matching KEYUP arrives -- which, for Right Ctrl on hardware without the "
      << "key, is never.";
}
```

#### P1 + P2 — `tests/keyman32.tests.vcxproj`

One hunk covers both. The project has **no glob**, which is how
`RightAltEmulationCheck.tests.cpp` went dark for eight months after merge
`4ac24f7b7b`.

```diff
   <ItemGroup>
     <ClCompile Include="gtest_main.cpp" />
     <ClCompile Include="appint.tests.cpp" />
     <ClCompile Include="keyboardoptions.tests.cpp" />
     <ClCompile Include="kmprocessactions.tests.cpp" />
+    <ClCompile Include="RightAltEmulationCheck.tests.cpp" />
+    <ClCompile Include="keybd_shift.tests.cpp" />
     <ClCompile Include="..\..\..\global\cpp\kmtip_guids.cpp" />
     <ClCompile Include="pch.cpp">
```

The restored file is P1 and is **not** part of this investigation: it has not run
since 2025-12-09, so a failure there is a separate finding to raise on its own,
not a regression from this work.

---

### The minimal seams

Three seams, in descending order of value. Each is small enough to review in one
sitting, and each one exists so that something currently untestable becomes a
pure function over its arguments.

#### S3 — `ReconcileModifierCache` (new; the seam fix D1 needs)

D1 is "re-validate Cache A from the OS at batch start". The whole fix is one
function plus one call. Making the state reader a parameter is the entire seam:
with it the function is pure and testable with no OS involvement, no thread and
no stall — and gmock is not linked, so a plain function pointer is the right
shape anyway.

Declaration, next to `keybd_shift` so it needs no new header and reaches the
tests through the existing `pch.h`:

```diff
--- a/windows/src/engine/keyman32/keymanengine.h
+++ b/windows/src/engine/keyman32/keymanengine.h
@@ -229,6 +229,20 @@
 void keybd_shift(LPINPUT pInputs, int* n, BOOL isReset, LPBYTE const kbd);
+
+/**
+  Signature of the live-modifier-state reader used by ReconcileModifierCache.
+  Exists so the reconciliation can be unit tested without touching the OS.
+  Production callers pass GetAsyncKeyState.
+*/
+typedef SHORT(WINAPI* PFNGETASYNCKEYSTATE)(int vKey);
+
+/**
+  Clears any of the six cached modifier bytes that the OS reports as up. Only
+  ever clears -- never sets -- so a modifier pressed between this read and the
+  following SendInput cannot be spuriously asserted.
+
+  Returns TRUE if the cache disagreed with the OS. That disagreement is
+  keymanapp/keyman#8064, and nothing reports it today.
+*/
+BOOL ReconcileModifierCache(LPBYTE const kbd, PFNGETASYNCKEYSTATE pfnGetAsyncKeyState);
```

Definition in `keybd_shift.cpp`, which already owns the six-modifier list and the
whole VK/scan-code/extended-bit story:

```diff
--- a/windows/src/engine/keyman32/keybd_shift.cpp
+++ b/windows/src/engine/keyman32/keybd_shift.cpp
@@ -201,3 +201,32 @@ void keybd_shift(LPINPUT pInputs, int *n, BOOL isReset, LPBYTE const kbd) {
     keybd_shift_release(pInputs, n, kbd);
   }
 }
+
+/**
+  ReconcileModifierCache lets the OS win over the cached modifier state.
+
+  Parameters: kbd                   pointer to keyboard state (256 byte array), the
+                                    cache maintained by the serial key event server
+              pfnGetAsyncKeyState   live-state reader; production passes GetAsyncKeyState
+
+  The cache is seeded from the OS exactly once, in
+  SerialKeyEventServer::InitThread (serialkeyeventserver.cpp:251), and thereafter
+  fed only by messages posted from the low level keyboard hook. A hook that misses
+  its deadline never posts, so a modifier KEYUP can be lost and the cache left
+  latched for the life of the process. keybd_shift_reset then presses that
+  modifier for real, with no matching KEYUP, ahead of every injected batch.
+
+  GetAsyncKeyState rather than GetKeyboardState: GetKeyboardState reports the
+  calling thread's processed input queue, which is the source that is stale.
+*/
+BOOL ReconcileModifierCache(LPBYTE const kbd, PFNGETASYNCKEYSTATE pfnGetAsyncKeyState) {
+  const BYTE modifiers[6] = { VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT };
+  BOOL disagreed = FALSE;
+
+  for (int i = 0; i < _countof(modifiers); i++) {
+    if ((kbd[modifiers[i]] & 0x80) && pfnGetAsyncKeyState(modifiers[i]) >= 0) {
+      SendDebugMessageFormat("cache/OS disagreement, clearing vkey=%s", Debug_VirtualKey(modifiers[i]));
+      kbd[modifiers[i]] = 0;
+      disagreed = TRUE;
+    }
+  }
+
+  return disagreed;
+}
```

The call site — the whole of D1, one line, at batch start and before any of
Keyman's own synthetic events:

```diff
--- a/windows/src/engine/keyman32/serialkeyeventserver.cpp
+++ b/windows/src/engine/keyman32/serialkeyeventserver.cpp
@@ -382,6 +382,10 @@
   void PrepareInjectedInput() {
     DWORD nInputs = min(m_pSharedData->nInputs, MAX_KEYEVENT_INPUTS);
 
+    // Let the OS win before we assert anything. A modifier KEYUP lost to a
+    // stalled hook is corrected here instead of persisting for the life of the
+    // process. #8064
+    ReconcileModifierCache(m_ModifierKeyboardState, GetAsyncKeyState);
+
     m_nInputs = 0;
     keybd_shift(m_pInputs, &m_nInputs, FALSE, m_ModifierKeyboardState);
```

Tests for the seam. These are green the moment the seam lands, and they need no
OS state at all — `T-R3'` is `T-R3` with the reconcile line inserted, which is
the cleanest available statement of what D1 buys:

```cpp
// Appended to tests/keybd_shift.tests.cpp.

namespace {
  // Stub OS modifier state. A file-local array, because gmock is not linked by
  // keyman32.tests.vcxproj.
  BYTE g_stubAsyncState[256];

  SHORT WINAPI StubGetAsyncKeyState(int vKey) {
    // 0x8000 is negative as a SHORT, which is what the "< 0 means down"
    // convention actually tests.
    return (vKey >= 0 && vKey < 256 && g_stubAsyncState[vKey]) ? (SHORT)0x8000 : (SHORT)0;
  }
}

class RECONCILE_MODIFIER_CACHE : public KEYBD_SHIFT {
public:
  void SetUp() {
    KEYBD_SHIFT::SetUp();
    memset(g_stubAsyncState, 0, sizeof(g_stubAsyncState));
  }
};

/*
  T-S1: the stranded byte is cleared, and reset then emits nothing at all --
  no modifier KEYDOWN and, because needsPrefix stays FALSE, no prefix either.
*/
TEST_F(RECONCILE_MODIFIER_CACHE, ClearsCachedModifierTheOsReportsUp) {
  kbd[VK_LSHIFT] = 0x80;              // cache: held
  g_stubAsyncState[VK_LSHIFT] = 0;    // OS: up

  EXPECT_TRUE(ReconcileModifierCache(kbd, StubGetAsyncKeyState));
  EXPECT_EQ(kbd[VK_LSHIFT], (BYTE)0);

  keybd_shift(inputs, &n, TRUE, kbd);
  EXPECT_EQ(n, 0) << "nothing to restore, so not even a prefix keystroke";
}

/*
  T-S2: the legitimate case must not regress. A genuinely held modifier survives
  reconciliation and is still restored -- that restoration is what keeps Alt+F
  from opening the window menu, and breaking it would trade #8064 for a worse bug.
*/
TEST_F(RECONCILE_MODIFIER_CACHE, KeepsCachedModifierTheOsReportsDown) {
  kbd[VK_LSHIFT] = 0x80;                 // cache: held
  g_stubAsyncState[VK_LSHIFT] = 0x80;    // OS: agrees

  EXPECT_FALSE(ReconcileModifierCache(kbd, StubGetAsyncKeyState));
  EXPECT_EQ(kbd[VK_LSHIFT], (BYTE)0x80);

  keybd_shift(inputs, &n, TRUE, kbd);
  EXPECT_EQ(Count(VK_SHIFT, false), 1) << "a real hold must still be restored";
}

/*
  T-S3: the asymmetry is deliberate. If the OS says down and the cache does not,
  we do NOT set the cache: between this read and SendInput the user may release
  the key, and asserting it would create the very latch we are removing.
*/
TEST_F(RECONCILE_MODIFIER_CACHE, NeverSetsAModifierTheCacheDoesNotHold) {
  kbd[VK_RCONTROL] = 0;                   // cache: up
  g_stubAsyncState[VK_RCONTROL] = 0x80;   // OS: down

  EXPECT_FALSE(ReconcileModifierCache(kbd, StubGetAsyncKeyState));
  EXPECT_EQ(kbd[VK_RCONTROL], (BYTE)0);

  keybd_shift(inputs, &n, TRUE, kbd);
  EXPECT_EQ(n, 0);
}

/*
  T-S4: all six slots are covered, not just the one the harness happens to use.
  MODIFIERS.md section 2b measured all six latching 2/2, so all six must clear.
*/
TEST_F(RECONCILE_MODIFIER_CACHE, ClearsAllSixSlots) {
  const BYTE allSix[6] = { VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT };
  for (int i = 0; i < _countof(allSix); i++) {
    kbd[allSix[i]] = 0x80;
  }

  EXPECT_TRUE(ReconcileModifierCache(kbd, StubGetAsyncKeyState));

  for (int i = 0; i < _countof(allSix); i++) {
    SCOPED_TRACE(allSix[i]);
    EXPECT_EQ(kbd[allSix[i]], (BYTE)0);
  }

  keybd_shift(inputs, &n, TRUE, kbd);
  EXPECT_EQ(n, 0);
}

/*
  T-R3': T-R3 with the reconcile line inserted. Green. The one-line diff between
  this test and DISABLED_ResetDoesNotPressAKeyThatIsNotHeld is fix D1.
*/
TEST_F(RECONCILE_MODIFIER_CACHE, ReconcileThenResetPressesNothing) {
  kbd[VK_LSHIFT] = 0x80;
  ReconcileModifierCache(kbd, StubGetAsyncKeyState);   // <-- the fix
  keybd_shift(inputs, &n, TRUE, kbd);

  EXPECT_EQ(Count(VK_SHIFT, false), 0);
}
```

#### S2 — `NormalizeModifierVk` (extraction; unblocks testing the cache writer)

`UpdateLocalModifierState` is the **only** writer to Cache A
(`serialkeyeventserver.cpp:581`), and today it cannot be tested at all: it is a
private method of a class defined inside a `.cpp`, behind `#ifndef _WIN64`, whose
constructor spawns a thread and creates a file mapping. The VK-normalisation half
is a pure function; extracting it costs nothing and makes the chirality rules
assertable.

Declared in `serialkeyeventcommon.h` — which is deliberately *not* `_WIN64`
guarded, so the tests get it on both architectures — and defined in
`keybd_shift.cpp`, which already includes `kbd.h` for `SCANCODE_RSHIFT` and
already documents this exact mapping in its file comment. No new file, no vcxproj
change beyond the one already made for P2.

```diff
--- a/windows/src/engine/keyman32/serialkeyeventcommon.h
+++ b/windows/src/engine/keyman32/serialkeyeventcommon.h
@@ -42,3 +42,17 @@ struct SerialKeyEventSharedData {
 };
+
+/**
+  Maps a modifier key event to the side-specific virtual key that the serial key
+  event server's modifier cache is indexed by.
+
+  Returns FALSE, leaving *pbVkOut untouched, if bVk is not a modifier.
+
+  Extracted from SerialKeyEventServer::UpdateLocalModifierState so the mapping can
+  be tested without constructing the server, which is #ifndef _WIN64 and whose
+  constructor spawns a thread and creates a file mapping. Defined in
+  keybd_shift.cpp, which already carries the VK / scan code / extended bit rules
+  this function depends on.
+*/
+BOOL NormalizeModifierVk(BYTE bVk, BOOL fIsExtendedKey, BYTE bScan, BYTE* pbVkOut);
```

```diff
--- a/windows/src/engine/keyman32/keybd_shift.cpp
+++ b/windows/src/engine/keyman32/keybd_shift.cpp
@@ (after ReconcileModifierCache)
+/**
+  See serialkeyeventcommon.h. Note the two different discriminators: Ctrl and Alt
+  are told apart by the extended-key flag, Shift by the scan code alone. That
+  asymmetry is the history described in the do_keybd_event comment above, and it
+  is why a latched Right Ctrl is emitted as VK_CONTROL|EXTENDEDKEY -- a key some
+  hardware does not have.
+*/
+BOOL NormalizeModifierVk(BYTE bVk, BOOL fIsExtendedKey, BYTE bScan, BYTE* pbVkOut) {
+  switch (bVk) {
+  case VK_CONTROL:
+    *pbVkOut = fIsExtendedKey ? VK_RCONTROL : VK_LCONTROL;
+    return TRUE;
+
+  case VK_MENU:
+    *pbVkOut = fIsExtendedKey ? VK_RMENU : VK_LMENU;
+    return TRUE;
+
+  case VK_SHIFT:
+    *pbVkOut = (bScan == SCANCODE_RSHIFT) ? VK_RSHIFT : VK_LSHIFT;
+    return TRUE;
+
+  case VK_LCONTROL:
+  case VK_RCONTROL:
+  case VK_LSHIFT:
+  case VK_RSHIFT:
+  case VK_LMENU:
+  case VK_RMENU:
+    // Technically not needed, but perhaps some app will send them through SendInput
+    *pbVkOut = bVk;
+    return TRUE;
+  }
+
+  return FALSE;
+}
```

The call site shrinks to the one line that is actually the cache write:

```diff
--- a/windows/src/engine/keyman32/serialkeyeventserver.cpp
+++ b/windows/src/engine/keyman32/serialkeyeventserver.cpp
@@ -554,31 +554,12 @@
   void UpdateLocalModifierState(BYTE bVk, BOOL fIsExtendedKey, BYTE bScan, BOOL fIsUp) {
-    switch (bVk) {
-    case VK_CONTROL:
-      // Left and right control are distinguished by a 0xE0 prefix byte
-      bVk = fIsExtendedKey ? VK_RCONTROL : VK_LCONTROL;
-      break;
-    case VK_MENU:
-      // Left and right alt are distinguished by a 0xE0 prefix byte
-      bVk = fIsExtendedKey ? VK_RMENU : VK_LMENU;
-      break;
-    case VK_SHIFT:
-      // Left and right shift are distinguished by scan code alone
-      bVk = bScan == SCANCODE_RSHIFT ? VK_RSHIFT : VK_LSHIFT;
-      break;
-    case VK_LCONTROL:
-    case VK_RCONTROL:
-    case VK_LSHIFT:
-    case VK_RSHIFT:
-    case VK_LMENU:
-    case VK_RMENU:
-      // These are technically not needed but perhaps some app will send them through SendInput
-      // and we'll have to deal with them?
-      break;
-    default:
-      return;
-    }
-
-    m_ModifierKeyboardState[bVk] = fIsUp ? 0 : 0x80;
+    BYTE bNormalizedVk;
+    if (!NormalizeModifierVk(bVk, fIsExtendedKey, bScan, &bNormalizedVk)) {
+      return;
+    }
+
+    m_ModifierKeyboardState[bNormalizedVk] = fIsUp ? 0 : 0x80;
   }
```

```cpp
// Appended to tests/keybd_shift.tests.cpp. No fixture: the function touches no
// global state, which is the point of extracting it.

/*
  T-S5: Ctrl and Alt take their side from the extended-key flag.
*/
TEST(NORMALIZE_MODIFIER_VK, CtrlAndAltChiralityComesFromExtendedFlag) {
  BYTE vk = 0;

  EXPECT_TRUE(NormalizeModifierVk(VK_CONTROL, TRUE, 0x1D, &vk));
  EXPECT_EQ(vk, (BYTE)VK_RCONTROL);
  EXPECT_TRUE(NormalizeModifierVk(VK_CONTROL, FALSE, 0x1D, &vk));
  EXPECT_EQ(vk, (BYTE)VK_LCONTROL);

  EXPECT_TRUE(NormalizeModifierVk(VK_MENU, TRUE, 0x38, &vk));
  EXPECT_EQ(vk, (BYTE)VK_RMENU);
  EXPECT_TRUE(NormalizeModifierVk(VK_MENU, FALSE, 0x38, &vk));
  EXPECT_EQ(vk, (BYTE)VK_LMENU);
}

/*
  T-S6: Shift takes its side from the scan code, and the extended flag is ignored
  entirely. This is the code-level counterpart of the wire measurement in
  README.md: injecting VK_RSHIFT with and without the extended flag produces
  byte-identical events at a WH_KEYBOARD_LL hook.
*/
TEST(NORMALIZE_MODIFIER_VK, ShiftChiralityComesFromScanCodeOnly) {
  BYTE vk = 0;

  EXPECT_TRUE(NormalizeModifierVk(VK_SHIFT, FALSE, SCANCODE_RSHIFT, &vk));
  EXPECT_EQ(vk, (BYTE)VK_RSHIFT);
  EXPECT_TRUE(NormalizeModifierVk(VK_SHIFT, TRUE, SCANCODE_RSHIFT, &vk));
  EXPECT_EQ(vk, (BYTE)VK_RSHIFT) << "the extended flag must not affect Shift";

  EXPECT_TRUE(NormalizeModifierVk(VK_SHIFT, FALSE, 0x2A, &vk));
  EXPECT_EQ(vk, (BYTE)VK_LSHIFT);
  EXPECT_TRUE(NormalizeModifierVk(VK_SHIFT, TRUE, 0x2A, &vk));
  EXPECT_EQ(vk, (BYTE)VK_LSHIFT) << "the extended flag must not affect Shift";
}

/*
  T-S7: non-modifiers are rejected without writing the out parameter. The
  original code reached the cache write only via the default: return, and nothing
  asserted that. A letter key must never index Cache A -- see MODIFIERS.md
  section 2a, "a stuck letter is not this bug".
*/
TEST(NORMALIZE_MODIFIER_VK, RejectsNonModifiersWithoutWriting) {
  BYTE vk = 0xEE;

  EXPECT_FALSE(NormalizeModifierVk('A', FALSE, 0x1E, &vk));
  EXPECT_FALSE(NormalizeModifierVk(VK_CAPITAL, FALSE, 0x3A, &vk));
  EXPECT_FALSE(NormalizeModifierVk(VK_LWIN, TRUE, 0x5B, &vk));
  EXPECT_FALSE(NormalizeModifierVk(VK_INSERT, TRUE, 0x52, &vk));

  EXPECT_EQ(vk, (BYTE)0xEE) << "out parameter must be untouched on rejection";
}
```

#### S1 — `RefreshModifierShiftState` (Cache B; belongs to `capslock/`)

This seam serves the **Caps Lock / Cache B** defect (#16422 / #16423), and the
tests that consume it live in [`capslock/TEST-PLAN.md`](capslock/TEST-PLAN.md).
Recorded here so the two plans do not both claim it.

`GetCapsAndNumlockState` has no header declaration at all — only a file-local
forward declaration at `kmhook_getmessage.cpp:71` — so `aiTIP.cpp:186` cannot
call it, which is `TODO.md` F1/F3.

```diff
--- a/windows/src/engine/keyman32/keymanengine.h
+++ b/windows/src/engine/keyman32/keymanengine.h
@@
+/**
+  Signature of the modifier-state reader used by RefreshModifierShiftState.
+  Production passes GetKeyState. Note that GetKeyState reads the calling thread's
+  processed input queue, which is the stale source -- keeping it a parameter makes
+  that visible, and makes swapping in GetAsyncKeyState a one-line change with a
+  test behind it.
+*/
+typedef SHORT(WINAPI* PFNGETKEYSTATE)(int nVirtKey);
+
+void RefreshModifierShiftState(PFNGETKEYSTATE pfnGetKeyState);
+void GetCapsAndNumlockState();
```

```diff
--- a/windows/src/engine/keyman32/kmhook_getmessage.cpp
+++ b/windows/src/engine/keyman32/kmhook_getmessage.cpp
@@ -68,7 +68,6 @@
 void ProcessWMKeymanControlInternal(HWND hwnd, WPARAM wParam, LPARAM lParam);
 void ProcessWMKeymanControl(WPARAM wParam, LPARAM lParam);
 void ProcessWMKeyman(HWND hwnd, WPARAM wParam, LPARAM lParam);
-void GetCapsAndNumlockState();
 
@@ -418,6 +417,22 @@
+/*
+  RefreshModifierShiftState:
+
+  Rebuilds the five modifier bits of Globals::ShiftState() from the OS. Split out
+  of GetCapsAndNumlockState so that the TIP path (appint/aiTIP.cpp:186) can resync
+  modifiers as well as toggles, and so the flag mapping can be tested with a
+  stubbed reader.
+*/
+void RefreshModifierShiftState(PFNGETKEYSTATE pfnGetKeyState) {
+  const struct { int vk; DWORD flag; } map[] = {
+    { VK_SHIFT,    K_SHIFTFLAG },
+    { VK_RCONTROL, RCTRLFLAG   },
+    { VK_LCONTROL, LCTRLFLAG   },
+    { VK_LMENU,    LALTFLAG    },
+    { VK_RMENU,    RALTFLAG    },
+  };
+
+  DWORD shiftState = Globals::get_ShiftState();
+
+  for (int i = 0; i < _countof(map); i++) {
+    if (pfnGetKeyState(map[i].vk) < 0) {
+      shiftState |= map[i].flag;
+    } else {
+      shiftState &= ~map[i].flag;
+    }
+  }
+
+  *Globals::ShiftState() = shiftState;
+}
+
 void GetCapsAndNumlockState() {   // I4793
   DWORD n = Globals::get_ShiftState();
 
   RefreshToggleState();
 
-  if(GetKeyState(VK_SHIFT) < 0) *Globals::ShiftState() |= K_SHIFTFLAG;
-  else *Globals::ShiftState() &= ~K_SHIFTFLAG;
-
-  if(GetKeyState(VK_RCONTROL) < 0) *Globals::ShiftState() |= RCTRLFLAG;
-  else *Globals::ShiftState() &= ~RCTRLFLAG;
-
-  if(GetKeyState(VK_LCONTROL) < 0) *Globals::ShiftState() |= LCTRLFLAG;
-  else *Globals::ShiftState() &= ~LCTRLFLAG;
-
-  if(GetKeyState(VK_LMENU) < 0) *Globals::ShiftState() |= LALTFLAG;
-  else *Globals::ShiftState() &= ~LALTFLAG;
-
-  if(GetKeyState(VK_RMENU) < 0) *Globals::ShiftState() |= RALTFLAG;
-  else *Globals::ShiftState() &= ~RALTFLAG;
+  RefreshModifierShiftState(GetKeyState);
 
   SendDebugMessageFormat("Enter: %x Exit: %x", n, Globals::get_ShiftState());
 }
```

Behaviour is unchanged: the same five flags, same polarity, and `get_ShiftState()`
is still read after `RefreshToggleState()`. The only difference is that the
read-modify-write is batched into a local before the single store, which matters
only if another thread mutated `ShiftState` mid-function — it does not.

#### S0 — the fallback, only if the fixture proves unusable

If `Globals_InitProcess()` in the fixture turns out to be too heavy in the test
process (see risk 1 below), the alternative is to give `keybd_shift` a variant
that takes the prefix VK as a parameter and does no logging, leaving the existing
function as a one-line wrapper. **Prefer the fixture.** It is already precedent in
`kmprocessactions.tests.cpp`, and S0 duplicates a code path in production to suit
a test, which is the worse trade. Raised only so the reviewer has it — this is
`TEST-PLAN.md` P6.

---

### P0 — `windows/src/support/fakefreeze/build.sh` (new)

The stimulus ships already; only the build entry point is missing. Modelled on
`wow64kbd/build.sh`, minus the ARM64/ARM64EC actions, because
`fakefreeze.vcxproj` declares only `Debug|Win32`, `Release|Win32`, `Debug|x64`
and `Release|x64`. There is no `test` action: the tool's effect is to make Keyman
unresponsive for five seconds, which is not something to run unattended in CI.

```bash
#!/usr/bin/env bash
## START STANDARD BUILD SCRIPT INCLUDE
# adjust relative paths as necessary
THIS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
. "${THIS_SCRIPT%/*}/../../../../resources/build/builder-full.inc.sh"
## END STANDARD BUILD SCRIPT INCLUDE

builder_describe "post a fake freeze message to keyman.exe, to force Windows to uninstall the low level keyboard hook" \
  clean configure build \
  :x86 :x64

builder_parse "$@"

#-------------------------------------------------------------------------------------------------------------------

source "$KEYMAN_ROOT/resources/build/win/environment.inc.sh"

WIN32_TARGET="bin/Win32/$TARGET_PATH/fakefreeze.exe"
X64_TARGET="bin/x64/$TARGET_PATH/fakefreeze.exe"

builder_describe_outputs \
  configure       /resources/build/win/delphi_environment_generated.inc.sh \
  build:x86       /windows/src/support/fakefreeze/$WIN32_TARGET \
  build:x64       /windows/src/support/fakefreeze/$X64_TARGET

#-------------------------------------------------------------------------------------------------------------------

function do_clean() {
  local Platform="$1"
  vs_msbuild fakefreeze.vcxproj -t:Clean "-p:Platform=${Platform}" -Verbosity:minimal
  clean_windows_project_files
}

function do_build() {
  local Platform="$1"
  vs_msbuild fakefreeze.vcxproj -t:Build "-p:Platform=${Platform}" -Verbosity:minimal
}

builder_run_action clean:x86        do_clean Win32
builder_run_action clean:x64        do_clean x64
builder_run_action configure        configure_windows_build_environment
builder_run_action build:x86        do_build Win32
builder_run_action build:x64        do_build x64
```

**A `build.sh` alone is not enough.** `windows/src/support/build.sh` only forwards
to three children, and `wow64kbd` is the cautionary example: it has had a
`build.sh` all along and still never builds from `./windows/build.sh`, because it
was never registered. Both halves are P0:

```diff
--- a/windows/src/support/build.sh
+++ b/windows/src/support/build.sh
@@ -15,6 +15,7 @@ builder_describe \
   :oskbulkrenderer \
   :etl2log \
-  :texteditor
+  :texteditor \
+  :fakefreeze
```

Verify with the output path, not by reading the log:

```bash
./windows/src/support/fakefreeze/build.sh --debug configure build:x86
./windows/build.sh build          # the child action must now cascade
ls windows/src/support/fakefreeze/bin/Win32/Debug/fakefreeze.exe
```

One thing to flag in the PR rather than bury: `:fakefreeze` under
`support/build.sh` means CI builds it on every Windows build. That is the point —
it is how the stimulus becomes reproducible for anyone else — but it is a
reviewer's call, and the narrower alternative is to ship the `build.sh` and leave
it unregistered, exactly as `wow64kbd` is today.

---

### M1 + M2 — the manual app's oracle

Not written out here: the full app is P4, a Delphi VCL form, and the template to
copy is `keyboard_ll_identifier/`, which already has the form, the hook and the
nine-VK filter. Only two things need adding, and they are the whole reason the app
exists, so they are worth stating in code:

```pascal
// M1 -- the template logs vkCode, scanCode and flags only, which cannot show
// either of Keyman's markers. Both constants are keyman64.h:132-134.
const
  SCAN_FLAG_KEYMAN_KEY_EVENT = $FF;          // Keyman synthesized this event
  EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT = $4B4D0000;  // serializer replay
  SCANCODE_ALTGR_FAKE_CTRL = $21D;           // Windows' own AltGr fake-Ctrl marker

function DecorateEvent(const hs: KBDLLHOOKSTRUCT): string;
begin
  Result := '';
  if hs.scanCode = SCAN_FLAG_KEYMAN_KEY_EVENT then
    Result := Result + ' [KM-SYNTH]';
  if hs.dwExtraInfo = EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT then
    Result := Result + ' [KM-SERIALIZED]';
  if hs.scanCode = SCANCODE_ALTGR_FAKE_CTRL then
    Result := Result + ' [ALTGR-FAKE-CTRL]';
  if (hs.flags and LLKHF_INJECTED) <> 0 then
    Result := Result + ' [INJ]';
end;

// M2 -- the pass/fail oracle. Not the text in the edit box: a stuck Ctrl or Alt
// swallows keys and produces no case change at all, so a text probe scores it
// CLEAN. This is what kmproof.ps1's oracle could not see, and why kmmods.ps1 had
// to carry GetAsyncKeyState instead.
procedure TfrmMain.TrackModifier(vkCode: DWORD; isUp: Boolean);
begin
  if isUp then
    FDownAt[vkCode] := 0
  else if FDownAt[vkCode] = 0 then
    FDownAt[vkCode] := GetTickCount64
  else
    // A second KEYDOWN with no intervening KEYUP. Auto-repeat does this too, so
    // the report is a warning, not a verdict.
    Log(Format('[REPEAT KEYDOWN] vk=%s held %dms', [VKName(vkCode), GetTickCount64 - FDownAt[vkCode]]));
end;

procedure TfrmMain.ReportUnmatched;
var
  vk: DWORD;
begin
  // Called on a timer, and after the stall button's batch has flushed.
  for vk in CACHE_A_VKS do
    if (FDownAt[vk] <> 0) and (GetAsyncKeyState(vk) >= 0) then
      Log(Format('[CACHE/OS DISAGREEMENT] vk=%s', [VKName(vk)]))
    else if (FDownAt[vk] <> 0) and not PhysicallyHeld(vk) then
      Log(Format('[UNMATCHED KEYDOWN] vk=%s held %dms -- #8064', [VKName(vk), GetTickCount64 - FDownAt[vk]]));
end;
```

`PhysicallyHeld` is the honest gap in the oracle: nothing in user mode can
distinguish a real hold from a latched phantom, which is exactly why the bug
survived so long. In practice the operator is not touching the keyboard when the
timer fires, so `GetAsyncKeyState` down + `FDownAt <> 0` + no physical contact
**is** the finding — which is why step 6 of the manual procedure exists and why
the app must log every event, not just its own verdict.

---

### Known risks in the above, in the order they will bite

1. **The fixture may be the wrong shape.** `Globals_InitProcess()` reaches
   `Globals_InitThread()` → `ISerialKeyEventClient::Startup()`, which on a machine
   with Keyman running may open the **live** server's file mapping. Harmless in
   principle — the client only opens handles — but it is a real environmental
   dependency inside tests whose whole selling point is having none.
   `kmprocessactions.tests.cpp` already does this, so the precedent is there, but
   it has never been run on a machine with Keyman active *and* wedged. **Check
   this first.** If it is a problem, S0 is the fallback.
2. **The `csGlobals` hazard is reasoned, not observed.** The claim that calling
   `keybd_shift` without `Globals_InitProcess()` enters a zeroed
   `CRITICAL_SECTION` follows from `k32_globals.cpp:96` and `:161`, and a zeroed
   `CRITICAL_SECTION` is documented UB. Whether it hangs, crashes or silently
   works on this Windows build is unmeasured. If it silently works, the fixture is
   merely tidy rather than mandatory — do not restate risk 2 as a finding either way.
3. **The leak detector in `gtest_main.cpp` fails any test that leaks.**
   `Globals_InitProcess` allocates with `LocalAlloc`, not the CRT heap, and
   `TearDown` frees it before `OnTestEnd` — so it should balance. Unverified.
4. **`_countof` in an `int` loop** produces a signed/unsigned comparison at
   `/W3`. The existing `keybd_shift.cpp` does exactly this, so it matches the file,
   but the tests project may carry different warning settings.
5. **T-P6 asserts a count over the whole 0-255 VK range.** If `isModifierKey`
   ever gains a tenth VK the count assertion fires before the named-VK loop,
   which is the intent — but the failure message must be read as "the set
   changed", not "the function is broken".
6. **`RightAltEmulationCheck` may fail on restore.** It reads real `kbdxx.dll`
   files by layout name. Eight months dark; if it fails, that is P1's finding and
   nothing to do with #8064.

---

### Verification

```bash
# the only thing that must go green in CI
./windows/src/engine/keyman32/build.sh --debug configure build test:x64
./windows/src/engine/keyman32/build.sh --debug test:x86     # isModifierKey coverage
./windows/build.sh test                                     # child action still cascades

# the demonstration artifact, run by hand and never in CI
./tests/bin/Win32/Debug/keyman32.tests.exe --gtest_also_run_disabled_tests \
  --gtest_filter=KEYBD_SHIFT.DISABLED_ResetDoesNotPressAKeyThatIsNotHeld
```

**All three CI commands must be fully green.** T-R3 is `DISABLED_`: it cannot pass
without changing what `keybd_shift` is *for*, so it is a demonstration artifact
rather than a regression gate. The last command is how it is shown, and it must
fail there with a message naming the phantom VK. Its green counterpart is
`ReconcileThenResetPressesNothing`, and the one-line diff between the two is fix
D1.

Confirm `RightAltEmulationCheck` now appears in the run output — that is the proof
P1 worked. If it *fails*, that is a separate finding: it has not run since
2025-12-09 and has nothing to do with #8064.

**Trap:** `keyman32.tests.vcxproj` has **no glob**. Every test `.cpp` must be listed in the `<ClCompile>` ItemGroup (~line 231), which is exactly how `RightAltEmulationCheck.tests.cpp` went dark for eight months.

Bar to clear, from [`windows/src/test/unit-tests/README.md`][utr]: *"They should not have complex environmental requirements nor require an installed version of the software in order to complete."* These clear it — a 256-byte array and a function call.

### Seams — summary

Drafted in full in [The minimal seams](#the-minimal-seams) above. Precedent for
doing this at all: `ReadAltGrFlagFromKbdDll(name,out)` was split out of
`KeyboardGivesCtrlRAltForRAlt()` purely for testability — rationale is in [the
test's own comment][raec].

| seam | what it makes testable | scope |
|---|---|---|
| **S3** `ReconcileModifierCache` | the D1 fix itself, as a pure function over the 256-byte array plus an injected state reader | Cache A / #8064 — **the one that matters** |
| **S2** `NormalizeModifierVk` | the *only* writer to Cache A ([`UpdateLocalModifierState`][sks554]), today a private method of a class defined inside the `.cpp`, behind `#ifndef _WIN64`, whose ctor spawns a thread and a file mapping | Cache A / #8064 |
| **S1** `RefreshModifierShiftState` | [`GetCapsAndNumlockState`][gm418], which has no header decl at all — only a file-local forward decl at `:71` — so [`aiTIP.cpp:186`][ai186] cannot call it = [TODO F1/F3][todo] | **Cache B**, belongs to [`capslock/`](capslock/README.md) |
| **S0** prefix-VK parameter | fallback only, if the `Globals_InitProcess()` fixture proves unusable. Duplicates a production path to suit a test; prefer the fixture | Cache A |

**Order:** P1 → T-P1…T-P6 → T-R1/T-R2 → F1/F2 turn them green → S3 +
T-S1…T-S4 + T-R3’ (these stand alone and are worth landing even if D1 is not) →
S2 + T-S5…T-S7 →
T-R3 and S1 only if Cache A is picked up. P0 is independent of all of it and
unblocks everyone else, so it goes first in wall-clock terms.

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

**Do not** run any of this against FieldWorks — it is out of scope (§7) and Notepad is all the repro needs. The reason is in [HAZARDS.md][hz] **H1**: navigation keys sent without `KEYEVENTF_EXTENDEDKEY` insert characters instead of moving the caret, which corrupted real lexical data twice.

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

**Port** — drafts for P0-P2 and the seams are in "The code" and "The minimal seams" above; all are **uncompiled**. `[ ]` **P0** add `fakefreeze/build.sh` (pattern: [`wow64kbd/build.sh`][w64]) **and register `:fakefreeze` in `support/build.sh`** — the script alone is not enough, which is why `wow64kbd` still never builds · **P1** restore `RightAltEmulationCheck.tests.cpp` to the vcxproj · **P2** `tests/keybd_shift.tests.cpp` (T-P1…T-P6, T-R3, and the seam tests T-S1…T-S7) · **P3** `tests/capsstate.tests.cpp` (T-R1, T-R2) · **P4** the manual app · **P5** extend [`keystroke-lifecycle.md`][klc] to cover the serializer, folding in §2 · **P6** settle S1/S2 with the reviewer before T-R3.

**Cross-platform** — `[ ]` **X1** reset Linux `{l,r}{ctrl,alt}_pressed` in `focus_in` (set only in the ctor, never re-synced on focus/reset/enable/disable — the closest structural sibling to the Windows bug) · **X2** reconcile macOS `currentModifiers` against the event, caching only the L/R chirality bits IMK lacks · **X3** re-seed it when the event tap re-enables · **X4** a macOS test for the cached path — every existing test builds an `NSEvent` with explicit `modifierFlags:` and exercises the *read-from-event* path, so `determineModifiers`/`currentModifiers`/`eventTapFunction` have **no test at all** · **X5** a dropped-KEYUP test for Linux — `tests/KeyHandling.cpp` always emits balanced pairs · **X6** write down the no-unpaired-modifier-injection invariant · **X7** *(minor)* no unit test for `PassthroughKeyboard.raiseKeyEvent`, the function Android actually calls · **X8** **implement the documented `modifier_state` validation** in [`km_core_processevent_api.cpp`][cpe] — one funnel, four platforms, no API bump · **X9** fix the `KM_CORE_MODIFIER_NOCAPS` documentation (it is documented as valid but breaks rule matching) · **X10** extend the `c keys:` grammar with explicit modifier down/up so the shared fixtures can express this bug class, and wire `capsLock:` into the web harness.

**Investigations** *(recorded in [TODO.md] alongside I1-I12)* — `[ ]` **I13** does `fakefreeze` reproduce on a clean VM? Direct test of §1; a null result here means something else differs and is worth knowing · **I14** which emitter latched the prefix VK? [TODO I11][todo] measured 1/116, but the wire capture saw every prefix KEYDOWN matched, so it caught only the atomic path ([`keybd_sendprefix`][kbsp]); [`PostDummyKeyEvent`][pdke] uses two separate `keybd_event` calls and is not atomic. · **I15** does Ross's focus-change observation answer **I3** (the stall source)? See [MEETING-PREP.md](MEETING-PREP.md) §2.

**Gates** — `[ ]` **T11** `keyman32/build.sh --debug configure build test:x64` and `test:x86` green except deliberate reds · **T12** `/windows/build.sh test` still cascades · **T13** manual app reproduces per §1 and agrees event-for-event with [`logs/`](logs/).

---

## 7. Conventions

Branch `<type>/<scope>/<issue>-<slug>` ([`prepare-commit-msg:56`][pcm]) — a matching name auto-fills the commit prefix and `Fixes:` trailer. Commits `test(windows): …` / `chore(windows): add …`, imperative, no trailing period, trailers after a blank line; types and scopes hook-enforced from [`resources/scopes/`][scopes]. C++ per [`.clang-format`][cf] — 2-space, `ColumnLimit: 130`, attached braces, `PointerAlignment: Left`. A test-only PR normally needs no user test ([CONTRIBUTING][contrib]); the manual app's README serves as one.

**Out of scope:** the Cache A fix itself ([TODO D1/D2][todo] — repro and analysis only, per direction 2026-08-23); the Core API change (§5.4); any FieldWorks-based testing.

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
[mac121]: https://github.com/keymanapp/keyman/blob/master/mac/Keyman4MacIM/Keyman4MacIM/KMInputMethodEventHandler.m#L124
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
