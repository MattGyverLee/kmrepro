# FIX PROPOSAL — phantom stuck modifier (Keyman for Windows)

This is **[keymanapp/keyman#8064][i8064]**. Read
[`issue-8064/README.md`](issue-8064/README.md) first — Ross (rc-swag) owns the
issue, has independently reached most of this from field logs, and authored the
commit that created the cache feed.

Derived from a deterministic repro on 18.0.249.0: candidate A (identical stimulus,
no stall) **0/20** across all ten candidate keys; candidate I (modifier released
into a *confirmed* stall) **10/10**, and 3/3 on the charge test. Reproduce with
`kmproof.ps1` and `kmmods.ps1`. Code refs are from
`fix/windows/16422-caps-lock-state-on-keyboard-switch`.

Each fix below is stated twice: in prose under "Fixes, in order of value",
and as a diff against current code under "The fixes as code". The diffs are
**drafts that have never been compiled** — see the warning heading that
section.

[i8064]: https://github.com/keymanapp/keyman/issues/8064

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
   `!isKeymanKeyboardActive` pass-through at `:233` is **35 lines later** and does
   not guard it. So the cache is updated for *every modifier keystroke on the
   machine*, whichever keyboard is active, while it is only *consumed* when a
   Keyman keyboard is active.

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
   KEYUP becomes a phantom modifier re-pressed on *every subsequent keystroke*,
   until something else happens to update the cache.

Observed signature: `;e`+RAlt+N yields `əŊ` (U+0259 **U+014A**) instead of `əŋ`
(U+0259 **U+014B**), with `GetAsyncKeyState(VK_LSHIFT)` also reporting down.

## Fixes, in order of value

### 1. Re-validate the cache against the OS before each injected batch  (the real fix)

In `PrepareInjectedInput()`, before the first `keybd_shift()`, refresh the six
modifier bytes from the OS and let the OS win. A missed KEYUP then self-heals on
the very next keystroke instead of persisting indefinitely.

Seeding from the OS is already the accepted pattern (`InitThread()` line 251) —
this just makes it recurring rather than once.

Two subtleties that must be respected:
- Resync **only at batch start**, before any of Keyman's own synthetic events, or
  the deliberate release/re-press inside the batch will fight the resync.
- Prefer `GetAsyncKeyState` over `GetKeyboardState` for physical state here:
  `GetKeyboardState` reflects the calling thread's *processed* input queue, which
  is precisely what is stale. Ignore events carrying
  `SCAN_FLAG_KEYMAN_KEY_EVENT` / `EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT`.

This is the same class of fix as the caps-lock resync in **#16422** — both are
"stop trusting cached lock/modifier state, re-derive it from the OS". They should
land as one shared helper rather than two independent patches.

### 2. Get the LL hook off the UI thread  (the structural fix)

Install `WH_KEYBOARD_LL` from a dedicated thread that owns nothing but a message
pump. The serializer already does exactly this
(`serialkeyeventserver.cpp:90`, `CreateThread` + its own loop) — the hook should
follow the same pattern. Until it does, *any* long operation on keyman.exe's main
thread silently drops user keystrokes, and no amount of downstream repair fully
covers that.

This is also why `KMC_WATCHDOG_FAKEFREEZE` can break input at all: its
`Sleep(5000)` (`UfrmKeyman7Main.pas:868`) runs on the hook-owning thread.

### 3. Watch the right thing

`LowLevelHookWatchDog` watches whether the *hook* looks alive. It does not watch
whether the *modifier state* is sane, which is the part that actually harms users.
Add a cheap invariant: when idle, if any cached modifier is `0x80` while
`GetAsyncKeyState` says it is up, clear it. Self-healing, no user action.

### 4. Make the phantom re-press non-silent

`keybd_shift_reset()` emitting an unmatched KEYDOWN is intentional (restoring a
genuinely-held modifier) but indistinguishable from asserting a stale one. Gate it
on a fresh OS check, and log when the two disagree — that disagreement *is* the
bug, and today nothing reports it.

### 5. Cherry-pick the telemetry

`930ae121c4` (Sentry event on hook reinstall) is on master only. Stable-18 is
currently blind. Extend it to report cache/OS modifier disagreement, not just
reinstalls.

## The fixes as code

> **[WARN] PENDING IN-PLACE TESTING.** Written against `../keyman` @ `a70538106c`
> (`fix/windows/16422-caps-lock-state-on-keyboard-switch`). **Never compiled,
> never run.** No NuGet package is restored in that checkout, so not one line has
> been through a compiler, and no diff below has been applied to a working tree.
> Read them as reviewed drafts of the shape of each fix, not as patches ready to
> land. Tests for fix 1 and the seams they need are in
> [`TEST-PLAN.md`](TEST-PLAN.md) — "The code" and "The minimal seams".

One correction to make before the diffs, because it changes how fix 2 has to be
written even though it changes nothing about the diagnosis:

> **The hook is installed with `dwThreadId` from `Globals::get_FSingleThread()`,
> and in production that value is `0`.** `keymancontrol.pas:792` calls
> `Keyman_Initialise(0, False)`, so `FSingleApp` is `FALSE`, so
> `keyman32.cpp:370` sets `*Globals::FSingleThread() = 0` — a *global*
> `WH_KEYBOARD_LL` hook. Windows still delivers the callback on the thread that
> **called** `SetWindowsHookExW`, which is keyman.exe's main thread because that
> is where `Keyman_Initialise` runs. So the conclusion in "The defect chain" step 1
> stands unchanged, but the fix is to move the *call site* to a dedicated thread,
> not to change that parameter. A patch that only edits the `dwThreadId` argument
> would do nothing.

### Fix 1 — re-validate the cache against the OS before each injected batch

Three hunks. The new function, its declaration, and the one line that is
actually the fix.

The state reader is a parameter rather than a direct `GetAsyncKeyState` call for
one reason: it makes the function pure and unit-testable with no OS, no thread and
no stall. That is the only seam this fix needs. (gmock is not linked into
`keyman32.tests.vcxproj`, so a plain function pointer is also the only stub shape
available.)

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
 
@@ -396,6 +400,9 @@
     }
 
+    // NOT reconciled here. Between the two keybd_shift calls the batch has
+    // deliberately released and re-pressed modifiers, so the OS state mid-batch
+    // is Keyman's own and must not be treated as ground truth.
     keybd_shift(m_pInputs, &m_nInputs, TRUE, m_ModifierKeyboardState);
   }
```

Two things to say out loud in the PR, because both are easy to get wrong on
review:

- **The reconcile must be at batch start only.** The second `keybd_shift` call
  restores what the first one released; a resync between them would read Keyman's
  own synthetic state and fight the restore. The inline comment above exists to
  stop a later reader "improving" it.
- **The asymmetry is deliberate.** Cached-up + OS-down is left alone. Setting the
  cache there would assert a modifier the user may release before `SendInput`
  runs, which is the same latch this fix removes, just seeded differently.

The natural discipline question — *does this share a helper with the caps-lock
resync in #16422?* — is worth asking but the answer here is no. That work resyncs
toggle state from `GetKeyState` into `Globals::ShiftState()`, a different cache
with a different source and a different consumer. What the two share is the
principle, not the code. The seam that *is* shared is `RefreshModifierShiftState`
(TEST-PLAN "S1"), and it belongs to `capslock/`.

### Fix 2 — get the LL hook off the UI thread

Sketched, not drafted: this is a lifetime and shutdown-ordering change as much as
a threading one, and it is the fix least suited to being written by anyone who is
not going to run it. The pattern to copy is in the same file as the bug — the
serializer's own pump thread, `serialkeyeventserver.cpp:88`.

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
  in the system ever re-derives the cache. Fix 1 is the one that makes the damage
  recoverable, so it should land first and independently.

### Fix 3 — watch the modifier state, not just hook liveness

`LowLevelHookWatchDog` already runs at exactly the right moment — shortly after
each keystroke seen by the GetMessage hook — and already has the machinery to
report. It just checks the wrong invariant. The cache belongs to the server, so
this needs one accessor.

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

Note the placement: this is *self-healing at idle*, and it is not a substitute
for fix 1. The watchdog only runs when the GetMessage hook sees a keystroke, and
the phantom press happens on the injection path — so fix 1 corrects the batch
about to be sent, and fix 3 catches the case where the user stops typing into
Keyman entirely and the stale byte would otherwise sit there. Both, or the wedge
survives in one direction or the other.

**Ordering hazard worth stating in the PR:** `ReconcileModifierState` runs from the
GetMessage-hook message path in the *focused* application's process, while
`PrepareInjectedInput` runs on the server thread in keyman.exe. Both write the same
256-byte array. Because both only ever *clear* bytes, and the writes are single
aligned byte stores, a lost update degrades to "corrected one keystroke later"
rather than to corruption — but say so explicitly rather than leaving a reviewer
to work out whether the array needs a lock.

### Fix 4 — make the phantom re-press non-silent

Mostly delivered by fixes 1 and 3: `ReconcileModifierCache` logs each clear via
`SendDebugMessageFormat`, and returns whether it found anything. What is left is
the reporting code, which needs a new event type on both sides of the C++/Delphi
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

### Fix 5 — cherry-pick the telemetry, and give it something to say

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

A caution on this one that is easy to skip: a **rate limit** is needed before this
ships. Once the cache is stranded, `ReconcileModifierState` finds the
disagreement, clears it, and the very next dropped event can strand it again — a
user in a bad state could generate one Sentry event per keystroke. Report the
first occurrence per process, or per N minutes, not every one.

### What this does not do

Recorded so the PR does not imply otherwise.

- **It does not explain what stalls the thread in the field.** Fixes 1 and 3 make
  the damage recoverable and fix 2 makes the stall less likely, but the field
  trigger is still open (`TODO.md` I3). Ross's focus-change observation is the
  lead.
- **It does not cover 64-bit hosts unless the inference in `TODO.md` I5 holds.**
  Everything in fixes 1 and 3 lives inside `#ifndef _WIN64`. The working
  assumption is that keyman.exe is 32-bit and hosts the single server whose
  `SendInput` reaches 64-bit apps like any other injected input — **unverified**,
  and it is the assumption the whole "machine-wide" claim rests on.
- **It does not remove the unmatched KEYDOWN.** `keybd_shift_reset` still emits
  one for a genuinely-held modifier, because that is its job. Fix 1 only makes the
  cache it reads trustworthy. Any test asserting "reset never emits an unmatched
  KEYDOWN" is asserting against the design, not against the bug — see
  `TEST-PLAN.md` T-R3, which is `DISABLED_` for exactly that reason.

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
  ships as `windows/src/support/fakefreeze/` (mcdurdin, 2025-11-17). The only
  reason nobody else can run it is that the directory has no `build.sh`, so
  `./windows/build.sh` never produces it — `TEST-PLAN.md` **P0**.
- ~~The **US-layout control was never run**, so "Keyman is required" is a strong
  inference from the code path, not a measured fact.~~ **Now measured** — see
  `TRIGGER.md` §3. Three-arm controlled test, same stimulus and load throughout:
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
  slots 2/2). The freeze alone is sufficient. Volunteer this: it agrees with
  mcdurdin's own note on #8064 that the watchdog PRs probably did not resolve it.
- `serialkeyeventserver.cpp` ends in `#endif // !_WIN64`. Confirm the equivalent
  path for 64-bit host apps before assuming a fix covers them.
