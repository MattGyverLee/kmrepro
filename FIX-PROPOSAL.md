# FIX PROPOSAL — phantom stuck modifier (Keyman for Windows)

This is **[keymanapp/keyman#8064][i8064]**. Read
[`issue-8064/README.md`](issue-8064/README.md) first — Ross (rc-swag) owns the
issue, has independently reached most of this from field logs, and authored the
commit that created the cache feed.

Derived from a deterministic repro on 18.0.249.0: candidate A (identical stimulus,
no stall) **0/20** across all ten candidate keys; candidate I (modifier released
into a *confirmed* stall) **10/10**, and 3/3 on the charge test. Reproduce with
`kmproof.ps1` and `kmmods.ps1`.

Code refs were originally taken from `fix/windows/16422-caps-lock-state-on-keyboard-switch`,
which happened to be the checked-out branch when the drafts were written. **That is
incidental and slightly misleading** — this is Cache A / #8064, and the Caps Lock defect on
that branch is a different bug with its own pull request, [#16423][p16423]. Every code
reference here was re-verified on 2026-08-26 against upstream `master` @ `deeff0456f`, and
the fix landed on `fix/windows/8064-reconcile-modifier-cache`, branched from that upstream
base rather than from the Caps Lock branch, so none of #16423's commits are ancestors of it.

Each fix below is stated twice: in prose under "Fixes, in order of value",
and as a diff against current code under "The fixes as code".

**Status as of 2026-08-26 — fix 1 is no longer a draft.** It has been written,
compiled, unit-tested and committed on branch
`fix/windows/8064-reconcile-modifier-cache` (fix commit `a26aa611b5`, based on
`origin/master` @ `deeff0456f`). `test:x86` **19/19 pass**, `test:x64` **18/18
pass** (1 disabled on each), and both `keyman32.dll` (Win32 Debug) and
`keyman64.dll` (x64 Debug) link clean with zero warnings. The authoritative
record of that work — build environment, commits, measured results, and eleven
corrections to this repo's own analysis — is [`IN-TREE.md`](IN-TREE.md); where it
and this file disagree, it wins. The rest of this document remains draft or has
been dropped:

| fix | standing as of 2026-08-26 |
|---|---|
| **1** — reconcile the cache against the OS before each batch | **implemented, compiled, tested, committed** — `a26aa611b5`; see IN-TREE §2 |
| **2** — get the LL hook off the UI thread | uncompiled sketch, deliberately out of scope, separate PR (IN-TREE C-5) |
| **3** — watchdog reconcile | **REFUTED and dropped** (IN-TREE C-3) — retained below with its retraction so nobody re-raises it |
| **4** — `WHR_MODIFIER_DESYNC` reporting | out of the minimal change: needs Delphi, and is reported *by* the dropped fix 3 (IN-TREE C-4) |
| **5** — cherry-pick the Sentry telemetry | out of the minimal change, same reasons, and still needs the rate limiter flagged below |

Every code claim in this file was re-checked against `origin/master` @
`deeff0456f` and **all of them held**. The corrections that came out of that
re-check are folded in below, each attributed to its IN-TREE clause.

[i8064]: https://github.com/keymanapp/keyman/issues/8064
[p16423]: https://github.com/keymanapp/keyman/pull/16423

## The defect chain

1. **The LL hook callback runs on keyman.exe's UI thread.**
   `keyman32.cpp:368` sets `FSingleThread` to the thread owning keyman.exe's main
   window, and `keyman32.cpp:279` installs `WH_KEYBOARD_LL` against it. A
   `WH_KEYBOARD_LL` callback is serviced by the installing thread's message loop,
   so **every keystroke on the machine is gated on keyman.exe's Delphi main
   thread.** That thread also runs dialogs, COM, and the update UI.

2. **Keyman swallows each key and defers re-injection.**
   `k32_lowlevelkeyboardhook.cpp:249-260`: with a Keyman keyboard active, the key
   is `PostMessage`d to the serializer and the hook returns `1` — consumed from
   the system queue. Modifiers additionally post
   `WM_KEYMAN_MODIFIER_EVENT` at `:198-202`.

2a. **That modifier post is NOT gated on a Keyman keyboard being active.**
   `:198` fires on `isModifierKey(vkCode) && flag_ShouldSerializeInput` only. The
   `!isKeymanKeyboardActive` pass-through at `:229-240` is **31 lines later**
   (IN-TREE C-7 — this file previously said 35) and does not guard it. So the
   cache is updated for *every modifier keystroke on the machine*, whichever
   keyboard is active, while it is only *consumed* when a Keyman keyboard is
   active.

   Measured 3/3: five triggers applied with the **Microsoft** Cameroon layout
   active leave its output byte-perfect, then switching to Keyman reveals it
   already wedged. Charge while inactive, fire on activation
   (`kmproof.ps1 -ChargeTest`).

   This is why the bug looked intermittent for years: "no Keyman keyboard was
   active, so Keyman is uninvolved" is false reasoning, and it is exactly the
   reasoning that kept getting applied.

   **Do not fix this by gating the post on `isKeymanKeyboardActive`.** Per the
   comment at `:193` (#7337) the post exists to keep the serialized queue in sync
   across keystrokes Keyman does not otherwise process; suppressing it trades this
   bug for a different desync. Fix #1 below already handles it, because it
   corrects the cache immediately before use.

   Two facts about `k32_lowlevelkeyboardhook.cpp` that an auditor will find, and
   that this repo had stated loosely (IN-TREE C-6, C-7):

   - The `#ifndef _WIN64` guard covers **lines 31-299**, not the whole file. The three `#include`s at `:25-27` sit above it.
     A new include in that file goes above line 31; new code goes inside.
   - There is a **second** unguarded emitter above the pass-through:
     `PostVisualKeyboardModifierEvent` at `:186-188`, on the same `isModifierKey`
     predicate and **not** even gated on `flag_ShouldSerializeInput`. It feeds the
     on-screen keyboard rather than the modifier cache, so it is **not part of
     #8064** — but anyone auditing "what runs before the pass-through" will find
     two emitters, not one, and should not mistake it for a second instance of
     this bug.

3. **If the thread stalls, Windows drops the event.**
   Windows enforces `LowLevelHooksTimeout`; a hook that does not return in time is
   bypassed (and can be evicted). Keyman therefore **never observes that KEYUP**.

4. **The modifier cache is write-only from that one event stream.**
   `serialkeyeventserver.cpp:581` — `m_ModifierKeyboardState[bVk] = fIsUp ? 0 : 0x80`
   is reachable *only* from `UpdateLocalModifierState`, whose three call sites
   (`:508`, `:514`, `:535`) all sit in the one window procedure serving
   `WM_KEYMAN_MODIFIER_EVENT` **and** `WM_KEYMAN_KEY_EVENT`. Both are posted from
   the same LL hook, so a stall starves the cache either way — but the feed is
   both messages, not the modifier post alone. It is seeded from the OS once, at
   `serialkeyeventserver.cpp:251` (`GetKeyboardState`) in `InitThread()`, and
   **never re-validated for the life of the process.**

5. **The stale byte is then actively re-asserted.**
   `PrepareInjectedInput()` (`:384-400`) wraps every batch in
   `keybd_shift(...FALSE...)` / `keybd_shift(...TRUE...)`, and
   `keybd_shift_reset()` (`keybd_shift.cpp:161-176`) emits a **KEYDOWN for every
   modifier the cache believes is held, with no matching KEYUP**. So one missed
   KEYUP becomes a phantom modifier re-pressed on every **queued output batch** —
   whenever a Keyman rule produces output — until something else happens to
   update the cache.

   **Correction, and the PR must use this wording** (IN-TREE C-1): this file
   previously said *every subsequent keystroke*, which is too strong and a
   reviewer who checks will find it false. The call graph settles it: `keybd_shift`
   has **exactly two call sites in the entire repository**
   (`serialkeyeventserver.cpp:388` release, `:399` reset), both inside
   `PrepareInjectedInput`, whose only caller is `ProcessQueuedKeyEvents()` (`:353`),
   whose only caller is `WndProc` under `if (msg == WM_USER)` (`:417-419`). Plain
   keystrokes travel the `WM_KEYMAN_KEY_EVENT` path (`:440+`), which calls
   `SendInput` directly and never touches `keybd_shift`.

   The **user-visible symptom is unchanged** by that correction, and that is worth
   saying in the same breath so the narrowing does not read as a downgrade: once
   the phantom KEYDOWN lands, the modifier is genuinely held at the OS, so *those*
   plain keystroke replays on the `WM_KEYMAN_KEY_EVENT` path arrive shifted too —
   as does every other keystroke on the machine. The batch is where the phantom is
   *pressed*; the damage is not confined to batches.

   The same fact is what makes fix 1 complete: one statement at the top of that
   one function covers **100 %** of the phantom-press surface.

Observed signature: `;e`+RAlt+N yields `əŊ` (U+0259 **U+014A**) instead of `əŋ`
(U+0259 **U+014B**), with `GetAsyncKeyState(VK_LSHIFT)` also reporting down.

## Fixes, in order of value

### 1. Re-validate the cache against the OS before each injected batch  (the real fix)

**This is the fix that landed** — `a26aa611b5`. In `PrepareInjectedInput()`,
before the first `keybd_shift()`, read the six modifier bytes from the OS and let
the OS win. A missed KEYUP is then corrected before anything can act on it,
instead of persisting for the life of the process.

Seeding from the OS is already the accepted pattern (`InitThread()` line 251) —
this just makes it recurring rather than once.

**It is preventive, not curative** (IN-TREE C-2), and this changes how it has to
be argued. After a modifier KEYUP is dropped, the OS reports that modifier **up**
while the cache says **down**; `ReconcileModifierCache` sees exactly that
disagreement. But once the first phantom KEYDOWN has been sent, the modifier is
*genuinely* held at the OS — cache and OS now **agree**, and a
`GetAsyncKeyState`-based reconcile can no longer detect anything wrong. So batch
start is not merely a good placement: it is the **last point at which prevention
is possible**. The fix qualifies because it is the first statement in
`PrepareInjectedInput` and `keybd_shift_reset` is only ever reached from further
down that same function.

**The corollary must not be over-claimed: this cannot *recover* an
already-latched process.** For that, see "Recovery for users, available today"
below.

Subtleties that must be respected:
- Resync **only at batch start**, before any of Keyman's own synthetic events, or
  the deliberate release/re-press inside the batch will fight the resync.
- Prefer `GetAsyncKeyState` over `GetKeyboardState` for physical state here:
  `GetKeyboardState` reflects the calling thread's *processed* input queue, which
  is precisely what is stale.
- **Do not filter `SCAN_FLAG_KEYMAN_KEY_EVENT` /
  `EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT`.** Earlier drafts of this file
  advised it. That advice belongs to a design that reads the event stream; a
  `GetAsyncKeyState`-based reconcile reads OS key state, so **there is no event to
  filter** and the shipped fix does no such filtering (IN-TREE §2, C-10).
- `GetAsyncKeyState`'s **low bit is shared machine-wide** (IN-TREE C-8). Windows
  documents that the "pressed since last query" bit can be consumed by any process
  and tells callers not to rely on it. The fix adds six reads per output batch.
  `kmhook_callwndproc.cpp:121-123` already calls `GetAsyncKeyState`, so this is not
  a new dependency — but it belongs in the PR description rather than being
  discovered by a reviewer.

**The cache is fed by Keyman's *own* synthetic modifier events, and the fix works
with that loop rather than against it** (IN-TREE C-10). The post at
`k32_lowlevelkeyboardhook.cpp:198` fires on `isModifierKey(vkCode)` alone and does
not exclude Keyman's own injected events, because the pass-through is 31 lines
further down. So on every batch, `keybd_shift_release`'s KEYUP drives the cache
byte to `0` and `keybd_shift_reset`'s KEYDOWN drives it back to `0x80`. When
reconcile clears a stale byte, both halves emit **nothing**, so no feedback
messages are generated and there is nothing to race: the stale byte cannot be
resurrected by Keyman's own events. The mid-feedback window — a later batch
beginning while the cache sits at the intermediate `0` — is **pre-existing, not
introduced**, since reconcile only ever clears and a byte already `0` is untouched.

**One residual regression risk, accepted and documented** (IN-TREE C-9). If the
previous batch's re-press KEYDOWN has not yet been reflected in
`GetAsyncKeyState` when the next batch begins, reconcile can clear a **genuinely
held** modifier. Consequence: one output batch emitted unshifted while the user
holds the key; the cache re-arms on that modifier's next physical KEYDOWN.
Self-healing, and strictly smaller than a machine-wide latch on a key the keyboard
may not have. The window is many milliseconds and several thread transitions wide
(app → LL hook → `PostMessage` → client → `WM_USER` → server thread). No debounce
was added; the trade is stated in the shipped code comment rather than left for a
reviewer to find.

This is the same class of fix as the caps-lock resync in **#16422** — both are
"stop trusting cached lock/modifier state, re-derive it from the OS". Whether they
should share a helper was asked and answered **no**; see the note under fix 1's
diffs. It landed as an independent patch.

### 2. Get the LL hook off the UI thread  (the structural fix)

Install `WH_KEYBOARD_LL` from a dedicated thread that owns nothing but a message
pump. The serializer already does exactly this
(`serialkeyeventserver.cpp:90`, `CreateThread` + its own loop) — the hook should
follow the same pattern. Until it does, *any* long operation on keyman.exe's main
thread silently drops user keystrokes, and no amount of downstream repair fully
covers that.

This is also why `KMC_WATCHDOG_FAKEFREEZE` can break input at all: its
`Sleep(5000)` (`UfrmKeyman7Main.pas:868`) runs on the hook-owning thread.

### 3. Watch the right thing  — **REFUTED, dropped 2026-08-26**

> **Retraction.** `ISerialKeyEventServer::GetServer()` is `NULL` in every process
> except keyman.exe, so this reconcile would return immediately almost everywhere
> it runs; the full argument and what remains useful about it are kept under
> "Fix 3" in "The fixes as code" (IN-TREE C-3).

`LowLevelHookWatchDog` watches whether the *hook* looks alive. It does not watch
whether the *modifier state* is sane, which is the part that actually harms users.
The proposal was a cheap invariant: when idle, if any cached modifier is `0x80`
while `GetAsyncKeyState` says it is up, clear it. Self-healing, no user action.
The reasoning about *which invariant matters* is sound and still worth carrying
into any future watchdog work; the *placement* is what fails.

### 4. Make the phantom re-press non-silent  — **out of the minimal change**

`keybd_shift_reset()` emitting an unmatched KEYDOWN is intentional (restoring a
genuinely-held modifier) but indistinguishable from asserting a stale one. Gate it
on a fresh OS check, and log when the two disagree — that disagreement *is* the
bug, and today nothing reports it.

Deferred on three counts (IN-TREE C-4): it spans Delphi, which is **not installed
on the dev machine** (Delphi builds happen elsewhere, so any patch here would have
been one more never-compiled draft); it is reported *by* the now-dropped fix 3; and
it still needs the rate limiter flagged under fix 5. **The diagnostic need is
already met**: `SendDebugMessageFormat` inside the shipped `ReconcileModifierCache`
logs every clear, with no cross-language edit.

### 5. Cherry-pick the telemetry  — **out of the minimal change**

`930ae121c4` (Sentry event on hook reinstall) is on master only. Stable-18 is
currently blind. Extend it to report cache/OS modifier disagreement, not just
reinstalls. Deferred for the same three reasons as fix 4.

## The fixes as code

> **Read the standing of each diff before reading the diff.** Fix 1 below is the
> code that shipped, and it is annotated as such. Fix 3 is retained only for the
> record and must not be applied. Fixes 2, 4 and 5 are still under the warning:
>
> **[WARN] PENDING IN-PLACE TESTING — applies to fixes 2, 4 and 5 only.** Written
> against `../keyman` @ `a70538106c`
> (`fix/windows/16422-caps-lock-state-on-keyboard-switch`). **Never compiled,
> never run**, and never applied to a working tree. Read them as reviewed drafts of
> the shape of each fix, not as patches ready to land. The original reason nothing
> here had been compiled — no restored NuGet package in that checkout — has since
> been resolved (IN-TREE §1, "Blocker 1"), so "uncompiled" now means "not yet
> attempted", not "not attemptable". **`keyman32.vcxproj` compiles with warnings as
> errors** (`C2220`): an unreferenced parameter (`C4100`) alone fails the build, so
> any of these drafts has to be made warning-clean, not merely correct. Tests for
> fix 1 and the seams they need are in [`TEST-PLAN.md`](TEST-PLAN.md) — "The code"
> and "The minimal seams" — read alongside IN-TREE §4, which measures three of that
> plan's six risks and invalidates the drafted `T-P6` and `T-S4`.

One correction to make before the diffs, because it changes how fix 2 has to be
written even though it changes nothing about the diagnosis:

> **The hook is installed with `dwThreadId` from `Globals::get_FSingleThread()`,
> and in production that value is `0`.** `kmcomapi/com/system/keymancontrol.pas:792` (not under `keyman32/`) calls
> `Keyman_Initialise(0, False)`, so `FSingleApp` is `FALSE`, so
> `keyman32.cpp:370` sets `*Globals::FSingleThread() = 0` — a *global*
> `WH_KEYBOARD_LL` hook. Windows still delivers the callback on the thread that
> **called** `SetWindowsHookExW`, which is keyman.exe's main thread because that
> is where `Keyman_Initialise` runs. So the conclusion in "The defect chain" step 1
> stands unchanged, but the fix is to move the *call site* to a dedicated thread,
> not to change that parameter. A patch that only edits the `dwThreadId` argument
> would do nothing.

### Fix 1 — re-validate the cache against the OS before each injected batch

> **This is what shipped, not a draft.** Committed as `a26aa611b5` on
> `fix/windows/8064-reconcile-modifier-cache`, based on `origin/master` @
> `deeff0456f`. Verified: **`test:x86` 19/19 pass**, **`test:x64` 18/18 pass** (1
> disabled on each; the x86-only `isModifierKey` case correctly compiles out on
> x64); **`keyman32.dll` Win32 Debug and `keyman64.dll` x64 Debug both link clean
> with 0 warnings**. `PGETASYNCKEYSTATE` and `ReconcileModifierCache` collide with
> nothing in the repo, and there was no pre-existing `GetAsyncKeyState` typedef.
> Blast radius of the header change was checked, not assumed: `keymanengine.h` is
> included by exactly two files, both PCHs (`keyman32/pch.h`,
> `keyman32/tests/pch.h`), so only two MSBuild projects are affected and both
> build. Not verified: **ARM64** — see "What this does not do". Full record in
> [`IN-TREE.md`](IN-TREE.md) §2.
>
> The production change is **64 lines across 3 files, roughly 40 of them comment**.
> The executable part is one typedef, one declaration, a ten-line loop, and one
> call. The diffs below give the shipped executable change verbatim; the in-tree
> comment wording differs in places and additionally carries the C-9 trade recorded
> in fix 1's prose above.

Three hunks. The new function, its declaration, and the one line that is
actually the fix.

The state reader is a parameter rather than a direct `GetAsyncKeyState` call for
one reason: it makes the function pure and unit-testable with no OS, no thread and
no stall. That is the only seam this fix needs. (gmock is not linked into
`keyman32.tests.vcxproj`, so a plain function pointer is also the only stub shape
available.)

**The typedef is `PGETASYNCKEYSTATE`, not `PFNGETASYNCKEYSTATE`** as earlier drafts
of this file had it. The engine's own precedent is `globals.h:153-162` —
`typedef BOOL (WINAPI *PKEYMANINIT)();`. `PFN` appears nowhere in this codebase, so
the `PFN` spelling would have been the only one of its kind.

**The declaration sits above the `#ifndef _WIN64` region**, immediately after the
`keybd_shift` declaration, so both architectures see it. That placement is what
lets the function be unit-tested on x64 even though its only production call site
is 32-bit-only.

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
+typedef SHORT (WINAPI *PGETASYNCKEYSTATE)(int vKey);
+
+/**
+  Clears any of the six cached modifier bytes that the OS reports as up. Only
+  ever clears -- never sets -- so a modifier pressed between this read and the
+  following SendInput cannot be spuriously asserted.
+
+  Returns TRUE if the cache disagreed with the OS. That disagreement is
+  keymanapp/keyman#8064, and nothing reports it today.
+*/
+BOOL ReconcileModifierCache(LPBYTE const kbd, PGETASYNCKEYSTATE pfnGetAsyncKeyState);
```

```diff
--- a/windows/src/engine/keyman32/keybd_shift.cpp
+++ b/windows/src/engine/keyman32/keybd_shift.cpp
@@ -201,3 +201,33 @@ void keybd_shift(LPINPUT pInputs, int *n, BOOL isReset, LPBYTE const kbd) {
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
+  calling thread's processed input queue, which is precisely the source that is
+  stale.
+*/
+BOOL ReconcileModifierCache(LPBYTE const kbd, PGETASYNCKEYSTATE pfnGetAsyncKeyState) {
+  const BYTE modifiers[6] = { VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT };
+  BOOL disagreed = FALSE;
+
+  for (int i = 0; i < _countof(modifiers); i++) {
+    if ((kbd[modifiers[i]] & 0x80) && pfnGetAsyncKeyState(modifiers[i]) >= 0) {
+      SendDebugMessageFormat("cache says held but OS says up, clearing vkey=%s", Debug_VirtualKey(modifiers[i]));
+      kbd[modifiers[i]] = 0;
+      disagreed = TRUE;
+    }
+  }
+
+  return disagreed;
+}
```

```diff
--- a/windows/src/engine/keyman32/serialkeyeventserver.cpp
+++ b/windows/src/engine/keyman32/serialkeyeventserver.cpp
@@ -382,6 +382,12 @@
   void PrepareInjectedInput() {
+    // Let the OS win before we assert anything, and do it as the FIRST statement
+    // of this function: once keybd_shift_reset below has pressed the phantom for
+    // real, cache and OS agree and the disagreement is no longer detectable. This
+    // is the last point at which prevention is possible. #8064
+    ReconcileModifierCache(m_ModifierKeyboardState, GetAsyncKeyState);
+
     DWORD nInputs = min(m_pSharedData->nInputs, MAX_KEYEVENT_INPUTS);
 
     m_nInputs = 0;
     keybd_shift(m_pInputs, &m_nInputs, FALSE, m_ModifierKeyboardState);
 
@@ -396,6 +400,9 @@
     }
 
+    // Deliberately not reconciled here. Between the two keybd_shift calls the batch has released
+    // modifiers itself, so the OS state mid-batch is Keyman's own and must not be treated as ground
+    // truth -- reconciling here would fight the restore.
     keybd_shift(m_pInputs, &m_nInputs, TRUE, m_ModifierKeyboardState);
   }
```

Five things to say out loud in the PR, because each is easy to get wrong on
review:

- **The reconcile must be at batch start only.** The second `keybd_shift` call
  restores what the first one released; a resync between them would read Keyman's
  own synthetic state and fight the restore. The inline comment above exists to
  stop a later reader "improving" it.
- **The asymmetry is deliberate.** Cached-up + OS-down is left alone. Setting the
  cache there would assert a modifier the user may release before `SendInput`
  runs, which is the same latch this fix removes, just seeded differently.
- **It is preventive, not curative** — it cannot recover an already-latched
  process. Say so before a reviewer or a user infers otherwise (IN-TREE C-2).
- **The phantom is re-pressed per output batch, not per keystroke.** `keybd_shift`
  has exactly two call sites, both in `PrepareInjectedInput`, reached only on
  `WM_USER`. Claiming per-keystroke re-pressing invites a reviewer to falsify the
  PR's own description (IN-TREE C-1, and "The defect chain" step 5 above).
- **The two accepted costs**: six shared-low-bit `GetAsyncKeyState` reads per batch
  (IN-TREE C-8) and the one residual risk of clearing a genuinely-held modifier
  (IN-TREE C-9). Both are set out in fix 1's prose above; neither should be left
  for a reviewer to discover.

The natural discipline question — *does this share a helper with the caps-lock
resync in #16422?* — is worth asking but the answer here is no. That work resyncs
toggle state from `GetKeyState` into `Globals::ShiftState()`, a different cache
with a different source and a different consumer. What the two share is the
principle, not the code. The seam that *is* shared is `RefreshModifierShiftState`
(TEST-PLAN "S1"), and it belongs to `capslock/`.

### Fix 2 — get the LL hook off the UI thread

> **Confirmed out of scope, 2026-08-26** (IN-TREE C-5). The decision was taken on
> this section's own evidence, not over its objection: the unresolved items listed
> at the end of it — `RestartLowLevelHook`, per-thread globals, shutdown ordering —
> are exactly the reasons, and this section already argued that fix 1 "should land
> first and independently". It did. Fix 2 is a separate PR, and the `[WARN]` above
> still applies to every diff below.

Sketched, not drafted: this is a lifetime and shutdown-ordering change as much as
a threading one, and it is the fix least suited to being written by anyone who is
not going to run it. The pattern to copy is in the same file as the bug — the
serializer's own pump thread, `serialkeyeventserver.cpp:90`.

```diff
--- a/windows/src/engine/keyman32/keyman32.cpp
+++ b/windows/src/engine/keyman32/keyman32.cpp
@@ -275,10 +275,52 @@
 #ifndef _WIN64
-BOOL InitLowLevelHook() {
-  HINSTANCE hinst = GetModuleHandle(LIBRARY_NAME);
-
-  *Globals::hhookLowLevelKeyboardProc() = SetWindowsHookExW(WH_KEYBOARD_LL, (HOOKPROC) kmnLowLevelKeyboardProc, hinst, Globals::get_FSingleThread());   // I4124
-  return Globals::get_hhookLowLevelKeyboardProc() != NULL;
-}
+/*
+  The WH_KEYBOARD_LL callback is delivered on the thread that installed the hook,
+  and Windows bypasses -- and may evict -- a hook that does not return within
+  LowLevelHooksTimeout. Installing it from keyman.exe's main thread therefore
+  gates every keystroke on the machine on a thread that also runs dialogs, COM and
+  the updater. When the dropped event is a modifier KEYUP, the serializer's
+  modifier cache is stranded and every later batch re-presses a modifier that is
+  not held. See keymanapp/keyman#8064.
+
+  So the hook is installed from, and serviced by, a thread that owns nothing but a
+  message pump. Same pattern as SerialKeyEventServer's thread.
+
+  Note: dwThreadId stays as it was. In production Globals::get_FSingleThread() is
+  0 -- a global hook -- and it is the *installing thread*, not that parameter,
+  that determines which message queue services the callback.
+*/
+static HANDLE s_hHookThread = NULL;
+static HANDLE s_hHookThreadReady = NULL, s_hHookThreadExit = NULL;
+static DWORD s_idHookThread = 0;
+
+static DWORD WINAPI HookThreadProc(LPVOID) {
+  HINSTANCE hinst = GetModuleHandle(LIBRARY_NAME);
+
+  *Globals::hhookLowLevelKeyboardProc() =
+    SetWindowsHookExW(WH_KEYBOARD_LL, (HOOKPROC) kmnLowLevelKeyboardProc, hinst, Globals::get_FSingleThread());   // I4124
+
+  // Unblock InitLowLevelHook whether or not the install succeeded; it reports.
+  SetEvent(s_hHookThreadReady);
+
+  if (Globals::get_hhookLowLevelKeyboardProc() == NULL) {
+    return 1;
+  }
+
+  // Nothing but a pump. Any work added here reintroduces the defect.
+  MSG msg;
+  for (;;) {
+    DWORD wait = MsgWaitForMultipleObjects(1, &s_hHookThreadExit, FALSE, INFINITE, QS_ALLINPUT);
+    if (wait == WAIT_OBJECT_0) {
+      break;
+    }
+    while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
+      TranslateMessage(&msg);
+      DispatchMessage(&msg);
+    }
+  }
+
+  UnhookWindowsHookEx(Globals::get_hhookLowLevelKeyboardProc());
+  *Globals::hhookLowLevelKeyboardProc() = NULL;
+  return 0;
+}
+
+BOOL InitLowLevelHook() {
+  s_hHookThreadReady = CreateEvent(NULL, FALSE, FALSE, NULL);
+  s_hHookThreadExit = CreateEvent(NULL, FALSE, FALSE, NULL);
+  if (!s_hHookThreadReady || !s_hHookThreadExit) {
+    DebugLastError("CreateEvent");
+    return FALSE;
+  }
+
+  s_hHookThread = CreateThread(NULL, 0, HookThreadProc, NULL, 0, &s_idHookThread);
+  if (!s_hHookThread) {
+    DebugLastError("CreateThread");
+    return FALSE;
+  }
+
+  WaitForSingleObject(s_hHookThreadReady, 5000);
+  return Globals::get_hhookLowLevelKeyboardProc() != NULL;
+}
```

`UninitLowLevelHook` has to change with it — the unhook now belongs to the owning
thread, so the main thread signals and waits rather than calling
`UnhookWindowsHookEx` itself:

```diff
 BOOL UninitLowLevelHook() {
-  BOOL RetVal = TRUE;
-  if(Globals::get_hhookLowLevelKeyboardProc() && !UnhookWindowsHookEx(Globals::get_hhookLowLevelKeyboardProc()))    // I4124
-    RetVal = FALSE;
-
-  *Globals::hhookLowLevelKeyboardProc() = NULL;
-  return RetVal;
+  if (s_hHookThread == NULL) {
+    return TRUE;
+  }
+
+  SetEvent(s_hHookThreadExit);
+  if (WaitForSingleObject(s_hHookThread, 5000) != WAIT_OBJECT_0) {
+    DebugLastError("WaitForSingleObject(s_hHookThread)");
+  }
+
+  CloseHandle(s_hHookThread);
+  CloseHandle(s_hHookThreadExit);
+  CloseHandle(s_hHookThreadReady);
+  s_hHookThread = NULL;
+  return Globals::get_hhookLowLevelKeyboardProc() == NULL;
 }
```

What is unresolved and why this is a sketch:

- **`RestartLowLevelHook` and the watchdog.** `LowLevelHookWatchDog::ReinstallHook`
  calls it from the main thread. With the hook owned elsewhere, reinstall has to be
  marshalled to the owning thread — or the thread has to be torn down and
  recreated, which changes what "reinstall" means.
- **`kmnLowLevelKeyboardProc` now runs on a thread with no thread globals.** It
  reaches `ThreadGlobals()`, and `Globals_InitThread` is called per thread; the new
  thread needs the same treatment, and its TLS teardown must not race the pump's
  exit.
- **`__try/__except` inside the callback** (`k32_lowlevelkeyboardhook.cpp:50-58`)
  is per-thread and unaffected, but the exception reporting path writes global
  debug state that has never been touched from two threads at once.
- **This does not remove the need for fix 1.** A dedicated pump makes the stall
  far less likely; it does not make a dropped event impossible, and nothing else
  in the system ever re-derives the cache. Fix 1 is the one that keeps the dropped
  event harmless, so it should land first and independently — and, as of
  2026-08-26, it has.

### Fix 3 — watch the modifier state, not just hook liveness  — **REFUTED, DROPPED, DO NOT APPLY**

> **[WARN] Retraction, 2026-08-26 (IN-TREE C-3).** This fix would be **close to a
> no-op**, and it is dropped. `LowLevelHookWatchDog::KeyEventReceivedInGetMessageProc()`
> runs from the GetMessage hook, which is injected into **every** application's
> process. `ISerialKeyEventServer::GetServer()` returns `sm_server`, which is only
> ever constructed where the server runs — **keyman.exe**. In every other process
> it is `NULL`, so the proposed reconcile returns immediately. And in keyman.exe
> itself, the GetMessage hook only ever sees keyman.exe's own keystrokes. So the
> watchdog runs almost exclusively in processes where it can do nothing, and the
> proposal buys almost nothing while **adding a cross-process write to a 256-byte
> array**.
>
> Kept, not deleted, because this repo's convention is to retain refuted material
> with its retraction so nobody re-raises it. Everything below is the reasoning as
> it stood, preserved so a future reader can see why it looked right.

**Why it looked attractive, and still reads that way.**
`LowLevelHookWatchDog` appears to run at exactly the right moment — shortly after
each keystroke seen by the GetMessage hook — and it already has the machinery to
report. It just checks the wrong invariant: hook liveness rather than modifier
sanity. That diagnosis of *which invariant matters* survives the retraction and is
worth carrying into any future watchdog work. What does not survive is the
assumption that this call site can reach the cache. The cache belongs to the
server, so the draft needed one accessor — and that accessor is precisely where the
proposal fails, because `GetServer()` is `NULL` wherever the watchdog actually
runs.

```diff
--- a/windows/src/engine/keyman32/serialkeyeventserver.h
+++ b/windows/src/engine/keyman32/serialkeyeventserver.h
@@ -10,6 +10,14 @@ class ISerialKeyEventServer {
 public:
   virtual ~ISerialKeyEventServer() {}
   virtual HWND GetWindow() const = 0;
+
+  /**
+    Clear any cached modifier the OS reports as up, and return TRUE if the cache
+    disagreed. Safe to call at idle from any thread: it only ever clears bytes,
+    and a byte cleared in error is re-set by the next physical modifier event.
+    #8064
+  */
+  virtual BOOL ReconcileModifierState() = 0;
 
   static ISerialKeyEventServer *GetServer() {
     return sm_server;
```

```diff
--- a/windows/src/engine/keyman32/serialkeyeventserver.cpp
+++ b/windows/src/engine/keyman32/serialkeyeventserver.cpp
@@ -119,6 +119,10 @@
   virtual HWND GetWindow() const {
     // At destruction time, m_hwnd may be NULL
     return m_hwnd;
   }
+
+  virtual BOOL ReconcileModifierState() {
+    return ReconcileModifierCache(m_ModifierKeyboardState, GetAsyncKeyState);
+  }
```

```diff
--- a/windows/src/engine/keyman32/LowLevelHookWatchDog.cpp
+++ b/windows/src/engine/keyman32/LowLevelHookWatchDog.cpp
@@ -39,6 +39,11 @@
  */

 #include "pch.h"
+// pch.h reaches only keyman64.h and keymanengine.h, and neither includes this;
+// the serial key event server is not on the engine's precompiled header path.
+#ifndef _WIN64
+#include "serialkeyeventserver.h"
+#endif

@@ -63,9 +68,29 @@ void LowLevelHookWatchDog::KeyEventReceivedInGetMessageProc() {
   // This is a good place to check if we are still alive -- shortly after each
   // keystroke event in the GetMessage hook, as this means at worst we'll have
   // one or two keystrokes where Keyman must recover
   if(!CheckIfHookIsAlive()) {
     ReinstallHook();
   }
+
+  // Hook liveness is not the invariant users feel. A modifier cached as held
+  // while the OS reports it up makes every later injected batch re-press it for
+  // real, machine-wide, until something happens to correct the cache -- and for a
+  // modifier the keyboard does not physically have, nothing does. Check the
+  // invariant that actually harms people, at the same cadence. #8064
+  ReconcileModifierState();
 }
+
+void LowLevelHookWatchDog::ReconcileModifierState() {
+#ifndef _WIN64
+  ISerialKeyEventServer *server = ISerialKeyEventServer::GetServer();
+  if (server == NULL) {
+    return;
+  }
+
+  if (server->ReconcileModifierState()) {
+    Globals::PostMasterController(wm_keyman_control, MAKELONG(KMC_WATCHDOG_HOOK_REINSTALL, WHR_MODIFIER_DESYNC), 0);
+  }
+#endif
+}
```

Two things that draft got wrong on the first pass, both worth flagging because
they are the kind of thing that only shows up when the x64 leg of the build runs:

- **`serialkeyeventserver.h` is not on the engine's PCH path.** The engine `pch.h`
  includes only `keyman64.h` and `keymanengine.h`, and neither reaches it. Without
  the explicit include this does not compile at all.
- **`ISerialKeyEventServer` is `#ifndef _WIN64`** (`serialkeyeventserver.h:5`),
  but `LowLevelHookWatchDog.cpp` is compiled for **both** architectures — only its
  `Keyman_WatchDogKeyEvent` export is guarded (`:102`). So the body has to be
  guarded too, or the x64 build breaks. On x64 the function is then a no-op, which
  is correct for now and is the same open question as [`TODO.md`](TODO.md) I5: whether
  Cache A exists in the 64-bit engine at all.

```diff
--- a/windows/src/engine/keyman32/LowLevelHookWatchDog.h
+++ b/windows/src/engine/keyman32/LowLevelHookWatchDog.h
@@ -28,4 +28,10 @@ public:
 private:
   static bool CheckIfHookIsAlive();
   static void ReinstallHook();
+
+  /**
+   * @brief Clear any cached modifier the OS reports as up, and report the
+   *        disagreement if there was one.
+   */
+  static void ReconcileModifierState();
 };
```

**The claim this section previously made about placement is retracted.** It said
fix 1 "corrects the batch about to be sent, and fix 3 catches the case where the
user stops typing into Keyman entirely and the stale byte would otherwise sit
there. Both, or the wedge survives in one direction or the other." **On the C-3
reading it does not catch that case either.** In the focused application's process
`GetServer()` is `NULL` and the reconcile returns before touching anything; in
keyman.exe the GetMessage hook sees only keyman.exe's own keystrokes, which is not
the "stopped typing into Keyman" scenario. The wedge is not covered in that
direction by this fix, and the PR must not say it is. Fix 1's own limit is stated
honestly in its prose above: preventive, not curative (IN-TREE C-2).

**The ordering hazard this section flagged is moot along with the fix**, and is
recorded here only so that a future attempt at cross-process reconciliation starts
from it rather than rediscovering it. As drafted, `ReconcileModifierState` would run
from the GetMessage-hook message path in the *focused* application's process, while
`PrepareInjectedInput` runs on the server thread in keyman.exe — both writing the
same 256-byte array. Because both only ever *clear* bytes, and the writes are single
aligned byte stores, a lost update would degrade to "corrected one keystroke later"
rather than to corruption. That analysis holds; it is the cross-process write itself
that the retraction rules out as unjustified for what it buys.

### Fix 4 — make the phantom re-press non-silent  — **out of the minimal change**

> **[WARN] Not applied, not compiled** (IN-TREE C-4). Three reasons, all standing:
> `WHR_MODIFIER_DESYNC` spans `keymancontrol.h`, `KeymanControlMessages.pas` and
> `UfrmKeyman7Main.pas`, and **Delphi is not installed on the dev machine** — the
> Delphi environment include is an empty stub and Delphi builds happen elsewhere,
> so a patch here would have been one more never-compiled draft; it is reported *by*
> the **now-dropped fix 3**; and it still needs the rate limiter flagged under fix 5.
>
> **The diagnostic need is already met without any of this.**
> `SendDebugMessageFormat` inside the shipped `ReconcileModifierCache` names the
> exact VK on every clear, with no cross-language edit and no new event type.

Partly delivered by fix 1 on its own: `ReconcileModifierCache` logs each clear via
`SendDebugMessageFormat`, and returns whether it found anything. What would be left
is the reporting code, which needs a new event type on both sides of the C++/Delphi
boundary — the two constant lists are mirrored by hand and have to move together.

```diff
--- a/windows/src/engine/keyman32/keymancontrol.h
+++ b/windows/src/engine/keyman32/keymancontrol.h
@@ -56,6 +56,7 @@
 // KMC_WATCHDOG_HOOK_REINSTALL event types
 #define WHR_TIMING         0  // 19.0 - report on timing
 #define WHR_INIT_FAILURE   1  // 19.0 - hook failed to (re)install
 #define WHR_UNINIT_FAILURE 2  // 19.0 - hook failed to uninstall
+#define WHR_MODIFIER_DESYNC 3 // 19.0 - cached modifier state disagreed with the OS (#8064)
```

```diff
--- a/windows/src/global/delphi/general/KeymanControlMessages.pas
+++ b/windows/src/global/delphi/general/KeymanControlMessages.pas
@@ -61,6 +61,7 @@
   // KMC_WATCHDOG_HOOK_REINSTALL event types
   WHR_TIMING         = 0;  // 19.0 - report on timing
   WHR_INIT_FAILURE   = 1;  // 19.0 - hook failed to (re)install
   WHR_UNINIT_FAILURE = 2;  // 19.0 - hook failed to uninstall
+  WHR_MODIFIER_DESYNC = 3; // 19.0 - cached modifier state disagreed with the OS (#8064)
```

### Fix 5 — cherry-pick the telemetry, and give it something to say  — **out of the minimal change**

> **[WARN] Not applied, not compiled** (IN-TREE C-4). Same three reasons as fix 4:
> Delphi is not installed here, the extension reports a disagreement found by the
> dropped fix 3, and the rate limiter below is a prerequisite rather than a caution.
> The cherry-pick of `930ae121c4` to stable-18 remains worth doing on its own merits
> and is independent of #8064.

`930ae121c4` (Sentry event on hook reinstall) is master-only; stable-18 is blind.
The cherry-pick is that commit unchanged. The one-line extension is what makes it
report the thing users actually experience:

```diff
--- a/windows/src/engine/keyman/UfrmKeyman7Main.pas
+++ b/windows/src/engine/keyman/UfrmKeyman7Main.pas
@@ -861,6 +861,7 @@
     KMC_WATCHDOG_HOOK_REINSTALL:
       case wParam of
         WHR_TIMING:         TKeymanSentryClient.ReportMessage('Watchdog: low level hook reinstalled, threshold exceeded at '+IntToStr(lParam)+' msec');
         WHR_INIT_FAILURE:   TKeymanSentryClient.ReportMessage('Watchdog: low level hook install failed with error '+IntToStr(lParam));
         WHR_UNINIT_FAILURE: TKeymanSentryClient.ReportMessage('Watchdog: low level hook uninstall failed with error '+IntToStr(lParam));
+        WHR_MODIFIER_DESYNC: TKeymanSentryClient.ReportMessage('Watchdog: cached modifier state disagreed with the OS and was corrected');
       end;
```

A prerequisite on this one that is easy to skip: a **rate limit** is needed before
this ships. Once the cache is stranded, `ReconcileModifierCache` finds the
disagreement, clears it, and the very next dropped event can strand it again — a
user in a bad state could generate one Sentry event per **output batch**. (This
file previously said "per keystroke"; that overstates the rate for the same reason
as IN-TREE C-1, and it is still far too many.) Report the first occurrence per
process, or per N minutes, not every one.

### What this does not do

Recorded so the PR does not imply otherwise.

- **It does not explain what stalls the thread in the field.** Fix 1 makes the
  consequence harmless and fix 2 would make the stall less likely, but the field
  trigger is **still open** (`TODO.md` I3, IN-TREE §6). Ross's focus-change
  observation is the lead. Landing fix 1 must not be read as closing I3.
- **It does not recover an already-latched process.** Fix 1 is preventive, and once
  the phantom KEYDOWN has landed cache and OS agree, so nothing downstream can
  detect the wedge (IN-TREE C-2). With fix 3 dropped there is no in-process
  self-healing path at all; recovery remains the six-modifier KEYUP sweep below, or
  ordinary physical typing.
- **It does not cover 64-bit hosts unless the inference in `TODO.md` I5 holds** —
  **still open** (IN-TREE §6). Correction to what this file used to say: it is not
  true that "everything in fix 1 lives inside `#ifndef _WIN64`". The *call site*
  is inside that region by construction, but the declaration sits above it and
  `ReconcileModifierCache` is architecture-neutral and unit-tested on both legs.
  The working assumption remains that keyman.exe is 32-bit and hosts the single
  server whose `SendInput` reaches 64-bit apps like any other injected input —
  **unverified**, and it is the assumption the whole "machine-wide" claim rests on.
- **The ARM64 leg is unbuilt** (IN-TREE §6). There are no ARM64 MSVC libraries on
  the dev machine — `VC\Tools\MSVC\14.44.35207\lib\` holds only `x86`, `x64` and
  `onecore` — so `keymanarm64.dll` was never produced. `keybd_shift.cpp` has no
  architecture guard and the new declaration sits outside the `_WIN64` region, so it
  *should* compile; that is **unverified** and CI or an ARM64 toolset must confirm
  it. Do not claim three-architecture coverage in the PR.
- **It does not remove the unmatched KEYDOWN.** `keybd_shift_reset` still emits
  one for a genuinely-held modifier, because that is its job. Fix 1 only makes the
  cache it reads trustworthy. Any test asserting "reset never emits an unmatched
  KEYDOWN" is asserting against the design, not against the bug — see
  `TEST-PLAN.md` T-R3, which is `DISABLED_` for exactly that reason. T-R3 **is**
  `KEYBD_SHIFT.DISABLED_ResetDoesNotPressAKeyThatIsNotHeld` as it shipped -- one
  test, two names -- and it is run by hand and never in CI (IN-TREE §1).
- **It does not revisit the watchdog hypothesis this investigation started from** —
  that hypothesis remains *unsupported*; see the Caveats below. Nothing in the
  landed work touches it either way.

---

## Recovery for users, available today

Sending a plain **KEYUP for each of the six modifiers** clears it — verified,
every wedge in the repro recovered this way, and no press is needed. Ordinary
physical typing does the same, which is why the symptom appears to "fix itself"
when a user starts interacting. This is a valid stopgap for support to hand out,
and cheaper than "restart Keyman".

## Caveats — do not overstate these in a PR

- The stall is induced deliberately, with `KMC_WATCHDOG_FAKEFREEZE`. The
  mechanism is proven; the *field* path that stalls that thread is not. CPU load
  alone (32 hogs / 16 cores) did **not** reproduce it, so do not offer load as the
  explanation. **Ross's focus-change observation is the best lead** —
  [`issue-8064/README.md`](issue-8064/README.md) §2.

  Correction worth carrying: this command is **not** debug-only. Its handler at
  `UfrmKeyman7Main.pas:868` is a bare `Sleep(5000)` with no gate, and it already
  ships as `windows/src/support/fakefreeze/` (mcdurdin, 2025-11-17). The reason
  nobody else could run it was that the directory had no `build.sh`, so
  `./windows/build.sh` never produced it — `TEST-PLAN.md` **P0**. **That is now
  fixed**: `5274fec612` adds `support/fakefreeze/build.sh` and registers
  `:fakefreeze` in `support/build.sh`, verified by
  `./windows/src/support/build.sh --debug test:fakefreeze` → exit 0, with x86 and
  x64 both building and a clean rebuild leaving the tree clean (IN-TREE §5). Note
  for anyone running the full cascade: `./windows/src/support/build.sh test` fails
  earlier at `oskbulkrenderer`, a Delphi project, because Delphi is not installed
  here. Environmental.
- **"Keyman is required" is measured, not inferred** — see `TRIGGER.md` §3.
  Three-arm controlled test, same stimulus and load throughout:
  US English **0/10** wedged, Microsoft Cameroon QWERTY 2017 **0/10** wedged
  (output byte-identical to Keyman's when working), Keyman wedged. Switch-only
  control with no stall: 0/10. "Keyman is required" is a fact, not an inference.
- **Blast radius is wider than this document implies.** Once wedged, *every*
  keyboard on the machine is affected — US and the Microsoft Cameroon layout both
  produce capitals with no trigger applied to them, because `keybd_shift_reset()`
  presses Shift *for real* with no matching KEYUP and `GetAsyncKeyState` agrees it
  is held. Ctrl+A is delivered as Ctrl+Shift+A system-wide. The user-visible bug
  is a stuck Shift across the whole machine, not a Keyman-typing glitch. Lead the
  PR with that.
- Every reproduced wedge here cleared on the next KEYUP — with one exception
  worth noting: one run went from wedged to **emitting nothing at all** under the
  same six-modifier sweep (`TODO.md` I4). So recovery is reliable but not
  guaranteed. The field reports' persistence-until-restart is **no longer a gap**:
  a latched modifier is cleared only by its exact matching KEYUP, and when the
  latched key does not physically exist that event cannot be produced
  (`MODIFIERS.md` §3b, measured; `Phantom_RCTRL.md` §3-4).
- The **watchdog hypothesis this investigation started from is not supported** —
  every reproduction here was obtained with the watchdog's hook-reinstall never
  provoked at all (`kmproof.ps1` 3/3 candidate I, 10/10 sweep; `kmmods.ps1` six
  slots 2/2). The freeze alone is sufficient. This agrees with
  mcdurdin's own note on #8064 that the watchdog PRs probably did not resolve it.
  **This stands unchanged, and it is a separate finding from the retraction of fix
  3** — that one is about where a watchdog *reconcile* could run, this one is about
  whether watchdog activity is part of the *cause*. It is not.
- `serialkeyeventserver.cpp` ends in `#endif // !_WIN64`. Confirm the equivalent
  path for 64-bit host apps before assuming a fix covers them.
- **`keyman32.vcxproj` compiles with warnings as errors** (`C2220`) — an
  unreferenced parameter (`C4100`) alone fails the build. Any patch still drafted
  in this file has to be made **warning-clean**, not merely correct, before it can
  be claimed to build (IN-TREE §1).
- **The landed work covers x86 and x64 only.** `keymanarm64.dll` was never built
  for want of an ARM64 toolset on this machine, so three-architecture coverage is
  an expectation, not a result (IN-TREE §6).
- **The branch is not pushed and no PR is open**, and #8064 has not been commented
  on. [`MEETING-PREP.md`](MEETING-PREP.md) is still the brief, and the issue is
  still Ross's (IN-TREE §6).
