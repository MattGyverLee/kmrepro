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
  same six-modifier sweep. So recovery is reliable but not guaranteed. The field
  reports describe persistence until a Keyman restart; that gap is unexplained and
  may indicate a second contributing factor.
- The **watchdog hypothesis this investigation started from is not supported** —
  the ghost key was absent from every reproducing run (27 iterations, 0 failures).
  Volunteer this: it agrees with mcdurdin's own note on #8064 that the watchdog PRs
  probably did not resolve it.
- `serialkeyeventserver.cpp` ends in `#endif // !_WIN64`. Confirm the equivalent
  path for 64-bit host apps before assuming a fix covers them.
