# The Keyman "stuck modifier / no text output" bug — what triggers it

Two descriptions of the same thing: a plain-language one for bug reports, release
notes and talking to users, and a technical one for the engineers who will fix it.

Investigated on **Keyman for Windows 18.0.249.0**, Windows 11 Pro 26200, against
`sil_cameroon_qwerty` in Notepad and FieldWorks (Ngoreme project).

---

## 1. Human description

### What the user sees

You are typing normally. Suddenly the keyboard "goes wrong":

- Everything comes out **capitalised**, as if Shift were held down — `;e` gives
  `:E` instead of `ə`.
- Or **nothing appears at all**, especially in FieldWorks, while Keyman still
  shows the correct keyboard as active.
- It behaves exactly as if a modifier key were physically stuck down, but no key
  is stuck. Wiggling the keyboard does nothing.
- Restarting Keyman fixes it. Rebooting fixes it more thoroughly. Often it also
  clears by itself after you click around and type for a bit.

### What is actually happening

Keyman does not simply watch your typing — it **intercepts every keystroke,
decides what it should become, and then re-injects the result**. To do that it
installs a system-wide keyboard hook.

That hook is serviced by **Keyman's main program thread — the same thread that
draws its windows and dialogs**. So every keystroke on the machine has to be
handled by a thread that is also doing other work.

If that thread is busy for about a second, Windows stops waiting for it and
handles the keystroke without Keyman. Usually harmless. But if the keystroke
Windows gives up on is the **release** of a modifier key — the moment you let go
of Shift — then Keyman never learns that you let go.

Keyman keeps its own private note of which modifiers you are holding. That note is
now wrong, and **nothing ever checks it against reality**. From then on, every
single keystroke gets "Shift" helpfully re-applied, because Keyman still believes
your finger is on it.

That is the whole bug: Keyman missed one key-release while it was busy, and it
never notices the mistake.

### Why slow and heavily loaded machines are worse

The bug needs Keyman's main thread to be unresponsive for around a second at the
wrong instant. On a fast, idle machine that essentially never happens. On a slow
machine, or one running a very large FieldWorks database, that thread being
briefly starved is routine — which matches the field reports exactly: **slower
machines and enormous databases see this far more often.**

This also means it is **probably not a new bug**. Nothing about the mechanism
requires any recent change to Keyman, which fits a problem that has been reported
for years without ever being pinned down.

### Why it seems to fix itself

Any genuine physical press or release of a modifier key corrects Keyman's note.
So as soon as you actually use Shift or Ctrl again, or click and type normally,
the problem may vanish — which is a large part of why it has been so hard to
catch.

### What we can tell users right now

Before restarting Keyman, try **tapping each of Shift, Ctrl and Alt once (both
left and right)**. That often clears it in seconds. It is not a fix, but it is far
cheaper than restarting or rebooting.

---

## 2. Technical description

### The trigger, in one sentence

> **A modifier key's KEYUP is released while keyman.exe's main thread — the thread
> that owns the `WH_KEYBOARD_LL` hook — is blocked, so Keyman never observes the
> release and its cached modifier state stays latched.**

### The defect chain

**1. The low-level keyboard hook is serviced by Keyman's UI thread.**

```
keyman32.cpp:368   *Globals::FSingleThread() = GetWindowThreadProcessId(Handle, NULL);
keyman32.cpp:279   *Globals::hhookLowLevelKeyboardProc() =
                     SetWindowsHookExW(WH_KEYBOARD_LL, kmnLowLevelKeyboardProc,
                                       hinst, Globals::get_FSingleThread());
```

`Handle` is keyman.exe's main window, so `FSingleThread` is its Delphi UI thread.
A `WH_KEYBOARD_LL` callback runs on the thread that installed it, therefore
**every keystroke on the machine is gated on keyman.exe's UI thread** — a thread
that also runs dialogs, COM calls and the updater.

**2. Keys are swallowed and re-injected asynchronously.**

```
k32_lowlevelkeyboardhook.cpp:198-202   // modifier -> WM_KEYMAN_MODIFIER_EVENT (PostMessage)
k32_lowlevelkeyboardhook.cpp:249-260   // key      -> WM_KEYMAN_KEY_EVENT     (PostMessage)
                                       // then return_SendDebugExit(1)  <-- consumed
```

With a Keyman keyboard active the event is consumed from the system queue; its
re-injection depends entirely on the serializer thread later calling `SendInput`.

**3. A blocked thread means Windows drops the event.**

Windows enforces `LowLevelHooksTimeout` (`HKCU\Control Panel\Desktop`). A hook
that does not return in time is bypassed and may be evicted. Keyman therefore
**never sees that KEYUP at all**.

**4. The cached modifier state is write-only, and never re-validated.**

```
serialkeyeventserver.cpp:251   GetKeyboardState(m_ModifierKeyboardState);   // InitThread() - ONCE
serialkeyeventserver.cpp:581   m_ModifierKeyboardState[bVk] = fIsUp ? 0 : 0x80;
```

Line 581 is reachable only from `UpdateLocalModifierState`, driven only by the
posted events from step 2. It is seeded from the OS exactly once, at thread
startup, and **never reconciled with the OS again for the lifetime of the
process**. A missed KEYUP leaves the byte at `0x80` indefinitely.

**5. The stale byte is then actively re-asserted on every keystroke.**

```
serialkeyeventserver.cpp:384-400   PrepareInjectedInput()
                                     keybd_shift(..., FALSE, m_ModifierKeyboardState)  // release
                                     ... copy the real key events ...
                                     keybd_shift(..., TRUE,  m_ModifierKeyboardState)  // re-press
keybd_shift.cpp:161-176            keybd_shift_reset()  // KEYDOWN for every modifier
                                                        // the cache thinks is held,
                                                        // with NO matching KEYUP
```

So one missed KEYUP becomes a phantom modifier re-pressed ahead of **every
subsequent injected batch**. This is why the symptom is persistent rather than a
one-off glitch, and why it can present as "no output at all": with Alt latched,
keys arrive as `WM_SYSKEYDOWN` and are eaten as menu accelerators.

### Reproduction

`kmhunt.ps1` — probe, one action, probe. Behavioural oracle, **case-sensitive**.

| candidate | modifier | keyman.exe blocked? | observed |
|---|---|---|---|
| **A** (control) | LShift held 1.5 s, released | no | clean |
| **B** | LShift held, released *into* the block | yes | **wedged** |
| **I** | as B, but block confirmed live first | yes | see reliability note |

```powershell
cd D:\Github\_Projects\_KM\kmrepro
powershell -ExecutionPolicy Bypass -File .\kmhunt.ps1 -Only A,B -Repeat 3
```

Wedged signature: `;e` + RAlt+N yields `əŊ` (U+0259 **U+014A**) instead of `əŋ`
(U+0259 **U+014B**); in the fuller form, `:EŊ` — Shift applied to everything.
`GetAsyncKeyState(VK_LSHIFT)` also reports down while it lasts.

The block is induced with `KMC_WATCHDOG_FAKEFREEZE` (wParam 20 on
`WM_KEYMAN_CONTROL`), whose handler is `Sleep(5000)` on the hook-owning thread
(`UfrmKeyman7Main.pas:868`). That is a **debug-only** command: it demonstrates the
mechanism, it is not the field path. The field equivalent is whatever else stalls
that thread for ~1 s.

### RELIABILITY — read this before quoting the repro

**Apparent intermittency was a harness artifact, now explained.** Candidate B
wedged **3/3 at 22:32** and **0/3 at 22:58** on the same command with the freeze
verified landing (WM_NULL round-trip 4747 ms, same pid, same hwnd). The cause was
almost certainly the two-Cameroon-keyboards confound below: the clean runs had
drifted onto the **Microsoft** layout, where the wedge is unreachable by
construction. The trigger is believed deterministic when the **Keyman** keyboard
is genuinely active — but that has not yet been demonstrated with a trustworthy
active-keyboard check in place, so treat the rate as unverified rather than
proven.

Two confounders, the second now understood:

1. **`PostMessage` is asynchronous** — posting cmd 20 does not establish when the
   `Sleep(5000)` actually begins, so a fixed 100 ms delay can release the modifier
   *before* the block starts, degenerating B into control A. Candidate **I** waits
   for the block to be confirmed live (`WaitForFreeze`) to remove this; it was
   0/4 on its first outing, so this is not the whole story.
2. **There are two Cameroon keyboards on this machine** — the Keyman TIP
   (langid `0x2000`) and a Microsoft/MSKLC layout. **Both map `;e` -> U+0259**, so
   the behavioural check cannot distinguish them, and Win+Space cycling lands on
   either. On a non-Keyman layout Keyman *passes keys through* rather than
   swallowing them (`k32_lowlevelkeyboardhook.cpp:229-240`,
   `!isKeymanKeyboardActive`), so such a trial is a different experiment
   altogether. `kmhunt.ps1` now logs the langid on every trial; **earlier results
   predate that and are therefore unattributable.** Re-run before trusting any
   rate.

**RESOLVED — the wedge was on the KEYMAN keyboard, not the MS layout.** Confirmed
by direct observation (the user was watching the layout indicator during the runs).

This resolves the intermittency in a specific and reassuring direction:

- With the **Keyman** keyboard active, Keyman **swallows** each key
  (`k32_lowlevelkeyboardhook.cpp:249-260`) and the wedge is reachable — candidate
  B fires.
- With the **MS Cameroon** layout active, `!isKeymanKeyboardActive` sends the key
  down the pass-through branch (`:229-240`), nothing is swallowed, and the wedge is
  **not reachable** — candidate B is clean by construction.

Since both layouts satisfy the `;e` -> U+0259 check, the "clean" runs were almost
certainly trials that had silently landed on the MS layout, i.e. **not the
experiment at all**. The trigger itself is very likely deterministic *given the
Keyman keyboard is genuinely active*; the variance was in the harness, not in
Keyman.

This also confirms the mechanism requires Keyman's swallow-and-reinject path, not
merely the presence of its hook — which is the answer to the "is Keyman required?"
question that had been open, and it means the fix must land in the Keyman path.

### The remaining harness gap: detecting WHICH Cameroon keyboard is active

`kmhunt.ps1` now logs the langid per trial, but **that oracle is not trustworthy
here**: during the 22:57 restore it reported `0x2000` on every cycle *including*
the iterations where `;e` produced a literal `;e`. That is gotcha #3 again — the
HKL does not track TSF profile switches in Notepad.

So neither available oracle distinguishes the two Cameroon keyboards:

| oracle | Keyman Cameroon | MS Cameroon | distinguishes? |
|---|---|---|---|
| `;e` -> U+0259 | yes | yes | **no** |
| `GetKeyboardLayout` langid | 0x2000 | (stale, also reads 0x2000) | **no** |

Fix this before trusting any further rate. Two workable approaches:

1. **Ask Keyman directly.** `KMC_GETLASTKEYMANID` (wParam 12) / `KMC_GETLASTACTIVE`
   (11) on `WM_KEYMAN_CONTROL`, sent to keyman.exe's `TApplication` window, report
   the active Keyman keyboard. If Keyman says no Keyman keyboard is active, abort
   the trial as invalid rather than recording it as clean. **This is the right
   fix** — it asks the component that actually knows.
2. **Find a keystroke the two layouts answer differently.** MSKLC supports only
   single dead-key + base; the Keyman keyboard can express longer context. A
   three-key rule unique to `sil_cameroon_qwerty` would be a pure behavioural
   discriminator needing no IPC.

Until one of these is in place, `kmhunt.ps1` should treat a trial as **INVALID**,
not CLEAN, whenever it cannot prove the Keyman keyboard was active — silently
scoring an unreachable-by-construction trial as a pass is exactly what produced
the misleading 0/3 and 0/4 results above.

### Harness traps found the hard way

- **PowerShell `-eq`/`-ne`/`-match` are case-insensitive, and U+014A/U+014B are
  the upper/lowercase ENG pair** — so the wedged output compares *equal* to the
  clean output. Any oracle here must use `-ceq`/`-cne`. This silently produced
  false negatives across a whole earlier round of testing. **The symptom is a case
  change; the comparison must be case-sensitive.**
- **A bare Alt press+release is the Windows menu-activation gesture.** It produces
  a near-perfect impersonation of this bug (no output, keyboard "active", modifier
  apparently stuck) with Keyman entirely uninvolved. Verified: the same run with
  the trigger removed still "failed" 5/10. **Prefer LShift for modifier tests.**
- `GetKeyboardLayout()` is an unreliable and app-dependent oracle — it reported
  `0x0409` in Notepad while Keyman was demonstrably live, and reported correctly
  in FieldWorks. Always verify behaviourally, and never gate a test on the HKL.
- The wedge is often **transient at the OS level**, so an external probe run
  seconds later reports clean. Measure inside the failing iteration.

### What is NOT established

- That the watchdog is involved. **It is not**: the LowLevelHookWatchDog ghost key
  was absent from every reproducing run. The hypothesis this investigation began
  with (`83251358b0`, 18.0.245) is unsupported.
- That Keyman is strictly required (see the layout confound above).
- The field path that stalls the thread. CPU load alone did not do it (32 hogs on
  16 cores — and that crashed the host PowerShell with `OutOfMemoryException`).
- Why the field symptom persists until a Keyman restart when most reproduced
  wedges here cleared on the next modifier edge. There may be a second factor.

### Fix

See `FIX-PROPOSAL.md`. In short: (1) re-validate `m_ModifierKeyboardState[]`
against the OS at the start of each injected batch and let the OS win — the same
class of fix as the caps-lock resync in **#16422**, and they should land as one
shared helper; (2) move the `WH_KEYBOARD_LL` hook off the UI thread onto a
dedicated pump, as the serializer already does (`serialkeyeventserver.cpp:90`).
