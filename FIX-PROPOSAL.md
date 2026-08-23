# FIX PROPOSAL — phantom stuck modifier (Keyman for Windows)

Derived from a deterministic repro on 18.0.249.0 (`kmhunt.ps1 -Only A,B -Repeat 3`:
A clean 3/3, B wedged 3/3, differing in one line). Code refs are from
`fix/windows/16422-caps-lock-state-on-keyboard-switch`.

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

3. **If the thread stalls, Windows drops the event.**
   Windows enforces `LowLevelHooksTimeout`; a hook that does not return in time is
   bypassed (and can be evicted). Keyman therefore **never observes that KEYUP**.

4. **The modifier cache is write-only from that one event stream.**
   `serialkeyeventserver.cpp:581` — `m_ModifierKeyboardState[bVk] = fIsUp ? 0 : 0x80`
   is reachable *only* from `UpdateLocalModifierState`, driven *only* by those
   posted events. It is seeded from the OS once, at
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

## Recovery for users, available today

Sending a plain **KEYUP for each of the six modifiers** clears it — verified,
every wedge in the repro recovered this way, and no press is needed. Ordinary
physical typing does the same, which is why the symptom appears to "fix itself"
when a user starts interacting. This is a valid stopgap for support to hand out,
and cheaper than "restart Keyman".

## Caveats — do not overstate these in a PR

- The stall is induced with `KMC_WATCHDOG_FAKEFREEZE`, a **debug-only** command.
  The mechanism is proven; the *field* path that stalls that thread is not. CPU
  load alone (32 hogs / 16 cores) did **not** reproduce it.
- The **US-layout control was never run**, so "Keyman is required" is a strong
  inference from the code path, not a measured fact. Run it before asserting it.
- Every reproduced wedge here cleared on the next KEYUP. The field reports
  describe persistence until a Keyman restart; that gap is unexplained and may
  indicate a second contributing factor.
- The **watchdog hypothesis this investigation started from is not supported** —
  the ghost key was absent from every reproducing run.
- `serialkeyeventserver.cpp` ends in `#endif // !_WIN64`. Confirm the equivalent
  path for 64-bit host apps before assuming a fix covers them.
