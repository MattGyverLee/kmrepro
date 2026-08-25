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
your finger is on it. It does that by pressing Shift for real, so Windows itself
ends up believing your finger is on Shift too.

That is the whole bug: Keyman missed one key-release while it was busy, and it
never notices the mistake.

**Two things make this worse than it first appears** (both measured — see §3):

- Keyman keeps that note **even when you are not using a Keyman keyboard at all.**
  So the damage can be done silently while you are typing on an ordinary Windows
  keyboard, and only appears the moment you switch back to your Keyman one. This
  is why it so often seems to break "on switching keyboards" for no reason.
- Nothing about your keyboard layout is at fault. A Microsoft-built clone of the
  very same Cameroon keyboard, typing the very same keys, comes through perfectly
  in the same conditions that corrupt Keyman.
- **Once it goes wrong, it goes wrong everywhere — not just in your Keyman
  typing.** Because Keyman holds Shift down for real, Windows itself now thinks
  your finger is on Shift. Every other keyboard on the machine starts producing
  capitals, and ordinary shortcuts change meaning in every application: Ctrl+A
  arrives as Ctrl+Shift+A. So a user may well report "my whole computer has gone
  strange", with no reason to connect it to their keyboard software.

### Why it is so hard to catch — and why load is NOT the answer

The bug needs two things to coincide: Keyman's main thread unresponsive for around
a second, **and a modifier KEYUP arriving inside that window**. Either alone is
harmless.

It is tempting to say "so slow, loaded machines see it more often". **That was
tested and it is not what the numbers say.** Under 32 CPU hogs on 16 cores, with
no induced stall: **0/10**. With the stall and *zero* load: **10/10**. Load is
neither necessary nor sufficient. The full table is in `TEST-PLAN.md` §1.

What load plausibly does is raise the *rate* at which the thread is briefly
starved, which would raise the *chance* of the coincidence. That is a reasonable
inference and it fits the field reports of slower machines and enormous FieldWorks
databases suffering more — but it is an inference, not a measurement here, and it
must not be stated as one. The measured statement is narrower and stronger: **the
stall is the mechanism, and it has to coincide with a modifier release.**

This does mean it is **probably not a new bug**. Nothing about the mechanism
requires any recent change to Keyman, which fits a problem reported for years
without ever being pinned down — and it is in fact
[#8064](https://github.com/keymanapp/keyman/issues/8064), open since 2023-01-23.
See `issue-8064/README.md`.

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

**3a. The modifier post is NOT gated on a Keyman keyboard being active.**

```
k32_lowlevelkeyboardhook.cpp:198-201   if (isModifierKey(vkCode) && flag_ShouldSerializeInput)
                                         PostMessage(..., WM_KEYMAN_MODIFIER_EVENT, ...)
k32_lowlevelkeyboardhook.cpp:233       if (... || !isKeymanKeyboardActive) -> pass through
```

The post at `:198` precedes the `isKeymanKeyboardActive` check at `:233` by 35
lines and does not consult it. So the cache is updated for **every modifier
keystroke on the machine**, regardless of which keyboard is active, while it is
only *consumed* when a Keyman keyboard is active. This is why the bug can be
charged invisibly on a Microsoft keyboard and fire on switching back — measured
3/3 in §3.

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

Use **`kmproof.ps1`** (fixes the modifier, varies the keyboard) and **`kmmods.ps1`**
(fixes the keyboard, varies the modifier). They are the only two scripts correct on
both known harness hazards below, and the only ones whose numbers should be quoted.

| candidate | modifier | keyman.exe blocked? | observed |
|---|---|---|---|
| **A** (control) | LShift held 1.5 s, released | no | clean — **0/20** across all ten keys |
| **B** | LShift held, released *into* the block | yes | **wedged**, intermittently — the block is posted but not confirmed |
| **I** | as B, but block confirmed live first | yes | **wedged 3/3**, and 10/10 on the sweep |

```powershell
cd D:\Github\_Projects\_KM\kmrepro
# shortest end-to-end demo, ~90 s
powershell -ExecutionPolicy Bypass -File .\kmproof.ps1 -Sweep -SweepTrials 1 -LoadThreads 4
# the decisive experiment: charge while a Microsoft keyboard is active, fire on switching back
powershell -ExecutionPolicy Bypass -File .\kmproof.ps1 -ChargeTest 3 -LoadThreads 4
# the scope matrix, six slots plus immune-key negative controls
powershell -ExecutionPolicy Bypass -File .\kmmods.ps1 -LoadThreads 4
```

The A-vs-B difference is the whole result: **the block is the mechanism**, and
candidate B is intermittent only because `PostMessage` is asynchronous — with a
fixed delay the KEYUP can be released *before* the freeze begins, degenerating the
trial into the A control. Candidate I confirms the block is live first, which is
why it is deterministic.

> Earlier single-keyboard runs are superseded and their numbers should not be
> quoted: with one keyboard you cannot attribute the wedge to Keyman rather than to
> the layout, to Windows, or to the harness.

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
drifted onto the **Microsoft** layout, where the wedge is charged but **cannot be
observed** — the probe reads clean because the corrupted state is Keyman's and
Keyman is not producing the output. (The original wording here said "unreachable
by construction". That was wrong; see §3.)

**Now demonstrated.** With a trustworthy active-keyboard check in place
(focus-thread HKL, §3), candidate I is **3/3 deterministic**, and the paired
control with no freeze is 0/10. The rate is no longer unverified.

Two confounders, the second now understood:

1. **`PostMessage` is asynchronous** — posting cmd 20 does not establish when the
   `Sleep(5000)` actually begins, so a fixed 100 ms delay can release the modifier
   *before* the block starts, degenerating B into control A. Candidate **I** waits
   for the block to be confirmed live (`WaitForFreeze`) to remove this; it was
   0/4 on its first outing, so this is not the whole story.
2. **There are two Cameroon keyboards on this machine** — the Keyman TIP
   (langid `0x2000`) and a Microsoft/MSKLC layout (langid `0x0436`). **Both map
   `;e` -> U+0259**, so the behavioural check alone cannot distinguish them, and
   Win+Space cycling lands on either. The live scripts log the langid on every
   trial; **earlier results predate that and are therefore unattributable.**
   Re-run before trusting any rate.

   Two corrections to what was originally written here. First, the langid *can* be
   trusted — read it off the focus thread (see §3 and the harness traps). Second,
   a trial on the Microsoft layout is **not** "a different experiment altogether":
   the modifier post that corrupts Keyman's cache runs before the
   `!isKeymanKeyboardActive` gate, so such a trial still charges the bug — it just
   cannot show it. That is now the basis of the proof in §3 rather than a
   confound.

**PARTLY RESOLVED, PARTLY WRONG — superseded by the three-arm experiment in §3.**

The wedge *was* on the Keyman keyboard, and the two-Cameroon-keyboards confound
was real. But the conclusion drawn from it below was **false**, and it was false
in the direction that matters:

> ~~With the **MS Cameroon** layout active, `!isKeymanKeyboardActive` sends the key
> down the pass-through branch (`:229-240`), nothing is swallowed, and the wedge is
> **not reachable** — candidate B is clean by construction.~~

That is not what happens. The wedge **is** reachable while the Microsoft layout is
active. It simply cannot be *observed* there, because the corrupted state lives in
Keyman and only affects output once a Keyman keyboard is active again. Measured
3/3, deterministically — see §3.

Consequently this claim must also be withdrawn:

> ~~This also confirms the mechanism requires Keyman's swallow-and-reinject path,
> not merely the presence of its hook.~~

The opposite is true: **the presence of the hook is sufficient.** The
swallow-and-reinject path is what makes the damage *visible*, not what causes it.
The fix must still land in the Keyman path, but it has to cover the case where no
Keyman keyboard is active at all.

### SOLVED: detecting WHICH Cameroon keyboard is active

The HKL **is** a trustworthy oracle. The earlier failures came from asking the
wrong thread.

Windows 11 Notepad is a multi-threaded WinUI app. The top-level `Notepad` frame
window sits on a thread pinned at `0x0409` for the life of the process; the
focused `RichEditD2DPT` edit control lives on a *different* thread, and that one
tracks the input locale correctly. `MainWindowHandle` resolves to the frame
thread — which is why `GetKeyboardLayout` "reported `0x0409` while Keyman was
demonstrably live". It was reporting the truth about a thread that never changes.

Resolve the thread from `GetGUIThreadInfo(0).hwndFocus` instead and it
discriminates all three keyboards cleanly. Verified by same-thread A/B on
2026-08-23, notepad pid 5500 tid 3196:

| keyboard | focus-thread HKL | langid |
|---|---|---|
| Keyman `sil_cameroon_qwerty` (`aal-Latn-CM`) | `0x04092000` | **0x2000** |
| MS `CAMQ2017.dll` (`a0000436`, under `af`) | `0xF0C00436` | **0x0436** |
| MS US English (`00000409`, `KBDUS.DLL`) | `0x04090409` | **0x0409** |

Cross-checked against the Windows tray input indicator read via UI Automation,
which names the active method in words (`aal-Latn-CM / Cameroon QWERTY` vs
`Afrikaans / Cameroon QWERTY 2017`). Two independent oracles, agreeing.

`kmproof.ps1` and `kmmods.ps1` use the focus thread everywhere and read the HKL
in exactly one place (`Get-FocusKeyboard`). Any harness that resolves it from the
top-level window instead is exposed to the stale reading — `TODO.md` H4.

Two traps this exposed, both live:

- **The full HKL matters, not just the langid.** en-US carries two input methods
  on this machine. Win+Space lands on Dvorak as `HKL=0xF0020409` — high word
  `0xF002`, a substitution handle, *not* the `0x0001` you would predict from
  layout id `00010409`. Since `abc` is not `abc` on Dvorak, a langid-only check
  would have let the ASCII oracle silently lie. Require `0x04090409` exactly.
- **langid `0x2000` is shared.** The registry has *both* Keyman Cameroon
  (`{25C4EE49-…}`) and Keyman Yoruba (`{8AC81CC8-…}`) registered under `0x2000`.
  Only the installed profile is reachable here, but the arm should still be
  confirmed behaviourally, not by langid alone.

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
- ~~`GetKeyboardLayout()` is an unreliable and app-dependent oracle.~~ **Corrected:
  it is reliable; the earlier tests asked the wrong thread.** Win11 Notepad's
  top-level frame window sits on a thread pinned at `0x0409` forever, while the
  focused `RichEditD2DPT` edit control is on another thread that tracks the input
  locale correctly. Resolving from `MainWindowHandle` reads the frame thread —
  hence "`0x0409` while Keyman was demonstrably live". Resolve from
  `GetGUIThreadInfo(0).hwndFocus` and it discriminates all three keyboards. Also
  compare the **full** HKL, not just the langid (Dvorak lands as `0xF0020409`).
- **`Write-Host` can cost seconds per call.** Measured on this machine with 15
  conhost processes alive: `Write-Host` **4301 ms/line** vs
  `[Console]::Out.WriteLine` **0.4 ms/line** vs `Add-Content` 1.8 ms/line. Not an
  I/O problem — a console-host problem, and it appears only once the console is
  congested, so nothing looks wrong in the log. This is a **correctness** hazard
  for a timing experiment. An earlier harness logged from inside candidate I's
  action and between trigger and probe, so multi-second dead time could let a 5 s
  freeze expire before the probe ran and silently turn a trial into a no-freeze
  control — which is why its bimodal all-or-nothing counts are not quoted anywhere.
  `kmproof.ps1` and `kmmods.ps1` use `[Console]::Out.WriteLine` throughout.
- The wedge is often **transient at the OS level**, so an external probe run
  seconds later reports clean. Measure inside the failing iteration.
- **Never clear the test field with keystrokes.** Ctrl+A + Delete works fine on a
  clean machine and fails silently the instant the wedge fires: with LShift
  latched, Ctrl+A is delivered as **Ctrl+Shift+A** and Delete as Shift+Delete, so
  the field is never emptied. Every later probe then reads the whole accumulated
  buffer and scores OTHER regardless of which keyboard is active — which produced
  a bogus "a Microsoft keyboard was also not-CLEAN" verdict until it was caught.
  A keystroke-based clear is unusable in exactly the state being measured. Use
  UIA `ValuePattern.SetValue('')`: it touches no keys, so it can neither be
  perturbed by a stuck modifier nor perturb Keyman's cached state. (Verified
  settable on Win11 Notepad, `IsReadOnly=False`.)
- **Distinguish cause from consequence when scoring.** A Microsoft keyboard going
  bad *under the trigger* would refute Keyman-only causation. The same keyboard
  going bad *while already wedged* is the expected consequence and is evidence
  **for** the diagnosis. Scoring both as failures inverts the conclusion.

---

## 3. Proof: it is Keyman — not the layout, not Windows, not the harness

Run with `kmproof.ps1`, 2026-08-23, Keyman 18.0.249.0, Notepad, `-LoadThreads 4`
throughout. Three keyboards, one stimulus. The freeze is posted to keyman.exe on
**every** arm and keyman.exe is running throughout, so the stall, the key
sequence, the timings, the load and the target window are identical in all arms.
The only variable is which keyboard owns the keystrokes.

| arm | keyboard | identity |
|---|---|---|
| US | Microsoft US English | `00000409` / `KBDUS.DLL` |
| MSKLC | Microsoft Cameroon QWERTY 2017 | `a0000436` / `CAMQ2017.dll`, under `af` |
| Keyman | Keyman Cameroon QWERTY | `sil_cameroon_qwerty`, TIP `{25C4EE49-…}` under `aal-Latn-CM` |

### The two keyboards are output-identical when working

Measured, not assumed:

| arm | `;e` then RAlt+N | `abc` (no Shift sent) |
|---|---|---|
| MSKLC | `U+0259 U+014B` | `abc` |
| Keyman | `U+0259 U+014B` | `abc` |
| US | `U+003B U+0065` — plain `;e` | `abc` |

So any divergence under the trigger **cannot** be attributed to the layout. Note
US emits *nothing* for RAlt+N: on a US layout RAlt is plain Alt, a menu
accelerator, not AltGr. That is why the layout-agnostic `abc` / `ABC` oracle is
required — it is the one measurement that is the same in all three arms.

### Candidate I (modifier released into a confirmed stall)

| arm | trials | wedged |
|---|---|---|
| US | 10 | **0** |
| MSKLC | 10 (both oracles) | **0** |

### The charge test — the decisive result

Per rep: five candidate-I trials **while the Microsoft Cameroon layout is
active**, then switch to Keyman once and probe.

| rep | MSKLC output during charging | Keyman on return |
|---|---|---|
| 1 | 5/5 perfect `U+0259 U+014B` | **WEDGED** `U+0259 U+014A`, `mods=LShift` |
| 2 | 5/5 perfect | **WEDGED** `U+0259 U+014A`, `mods=LShift` |
| 3 | 5/5 perfect | **WEDGED** `U+0259 U+014A`, `mods=LShift` |

**MSKLC output: 0/15 disturbed. Keyman on return: 3/3 corrupted.** Deterministic.

Paired control (`-SwitchStress`): the same 60 keyboard switches and the same
deadkey probe on Keyman ten times, with **no freeze ever posted** — 0/10 wedged.
So neither the switching nor the probe is responsible.

### What each arm rules out

- **MSKLC clean** kills "it's the layout" and kills "Windows dropped the KEYUP".
  Same layout, same OS, same stimulus; the Microsoft implementation — which
  relies on Windows' own modifier tracking — stayed correct throughout.
- **US clean, and switch-stress clean** kill "the harness manufactures the
  phantom Shift". The identical injected keystrokes leave both Microsoft
  keyboards perfect.
- **`mods=none` all through charging, `mods=LShift` only after switching to
  Keyman** kills "the OS lost the key". Windows' own `GetAsyncKeyState` was
  correct the entire time until a Keyman keyboard became active — at which point
  a stuck LShift appears in OS-visible state. Keyman is *synthesising* it.

### Cause is Keyman's; the blast radius is the whole machine

These are two different questions and they have different answers. Conflating
them is easy and it understates the bug.

`kmproof.ps1 -Sweep` walks all three keyboards three times: once applying the
trigger, once applying **nothing** while wedged, once after clearing.

| arm | oracle | TRIGGER | WEDGED (nothing applied) | CLEARED |
|---|---|---|---|---|
| US | Ascii | CLEAN | **WEDGED** `ABC` | CLEAN |
| MSKLC | Ascii | CLEAN | **WEDGED** `ABC` | CLEAN |
| MSKLC | Deadkey | CLEAN `əŋ` | **WEDGED** `:EŊ` | CLEAN `əŋ` |
| Keyman | Ascii | **WEDGED** `ABC` | **WEDGED** `ABC` | CLEAN |
| Keyman | Deadkey | **WEDGED** `:EŊ` | **WEDGED** `:EŊ` | CLEAN |

`mods=LShift` on every wedged probe; `mods=none` on every clean one.

- **TRIGGER column — causation.** Under the identical trigger, both Microsoft
  keyboards stay clean and only Keyman wedges. This is what exonerates the layout
  and Windows.
- **WEDGED column — consequence.** With *no trigger applied to them at all*, both
  Microsoft keyboards are now broken too. They are not malfunctioning: they are
  correctly rendering a Shift that Windows genuinely believes is held.
  `GetAsyncKeyState` agrees. Keyman put it there — `keybd_shift_reset()`
  (`keybd_shift.cpp:161-176`) emits a KEYDOWN for every modifier its cache thinks
  is held, with no matching KEYUP.
- **CLEARED column.** All three return to clean, so this is a recoverable desync,
  not lasting damage.

So: **caused only via Keyman, suffered by everything.** Once the wedge fires it is
not a Keyman-typing problem, it is a system-wide stuck-Shift. Confirmed by the
user independently: while wedged, **Ctrl+A is delivered as Ctrl+Shift+A**, so
ordinary shortcuts in unrelated applications change meaning.

This is materially worse than "the Cameroon keyboard types capitals", and it fits
the field reports where users describe the whole machine going strange rather than
just their typing. It should lead the bug report.

**Two wedge depths exist**, both real:

| depth | `;e` + RAlt+N | meaning |
|---|---|---|
| partial | `əŊ` — `U+0259 U+014A` | Shift reached only the eng |
| full | `:EŊ` — `U+003A U+0045 U+014A` | Shift applied to everything, `;`→`:`, `e`→`E` |

An oracle that only knows one of them scores the other as an unreadable probe.

### The mechanism, verified in source

The pass-through argument previously used in this document is wrong, and the
source says exactly why. In `k32_lowlevelkeyboardhook.cpp`:

```cpp
// :193  #7337 Post the modifier state ensuring the serialized queue is in sync
// :198
if (isModifierKey(hs->vkCode) && flag_ShouldSerializeInput) {
  PostMessage(..., WM_KEYMAN_MODIFIER_EVENT, hs->vkCode, ...);   // :201
}
...
// :233 — THIRTY-FIVE LINES LATER
if (hs->dwExtraInfo != 0 || ... || !isKeymanKeyboardActive) {
  return_SendDebugExit(CallNextHookEx(...));                     // pass through
}
```

The modifier post at **:198-201 is not gated on `isKeymanKeyboardActive`.** It is
gated only on `isModifierKey()` and `flag_ShouldSerializeInput`. The
`!isKeymanKeyboardActive` pass-through at **:233** happens afterwards, and only
affects *character* keys.

Therefore **Keyman updates its cached modifier state for every modifier keystroke
on the machine, whether or not any Keyman keyboard is active** — while it only
*consumes* that cache when one is (`serialkeyeventserver.cpp:388,399`
`keybd_shift`). That is precisely charge-while-inactive, fire-on-activation, which
is what the table above measures.

Two further notes from source:

- The comment at :193 says the post exists "ensuring the serialized queue is in
  sync". The synchronisation mechanism is the desynchronisation vector: the post
  is dropped when the hook thread is blocked, and the cache is seeded from the OS
  exactly once (`serialkeyeventserver.cpp:251`, `InitThread`) and never
  reconciled again (`:581` is the only writer).
- `isKeymanKeyboardActive` is maintained by a *GetMessage* hook
  (`kmhook_getmessage.cpp:405`, matching the KMTip CLSID in an atom string), so it
  flips on window/focus/TSF activity — which is the "fire on switch" half of the
  observed behaviour.

### Consequence for the fix

`FIX-PROPOSAL.md`'s fix #1 — reconcile `m_ModifierKeyboardState[]` against the OS
at the start of every injected batch, OS wins — **is still sufficient**, and this
finding strengthens the case for it.

That is worth stating carefully, because it is easy to get backwards. Injection
only happens when a Keyman keyboard *is* active, so a resync at batch start
corrects the cache immediately before it is used, whatever corrupted it and
whenever. It does not matter that the corruption occurred while Keyman was a
bystander.

What this finding does change:

- **It rules out any fix based on preventing the corruption instead of correcting
  it.** Gating the modifier post on `isKeymanKeyboardActive` looks attractive and
  is the wrong move: the post at `:198` exists precisely to keep the serialized
  queue in sync across keystrokes Keyman does not otherwise see. Suppressing it
  would trade this bug for a different desync. Correct-before-use beats
  prevent-corruption here.
- **It invalidates a diagnostic shortcut.** "No Keyman keyboard was active, so
  Keyman's state is fine" is false, and it is the reasoning that made this bug
  look intermittent for years. Anything asserting Keyman is uninvolved because its
  keyboard was inactive needs re-examining.
- **It raises the priority of fix #3** (the idle invariant: if a cached modifier
  says held while `GetAsyncKeyState` says up, clear it). Corruption can now sit
  latent and invisible for an arbitrarily long time before firing, so self-healing
  while idle is worth more than the original write-up implies.

### Scope limits of this proof

- One machine, one Windows build (11 Pro 26200), one Keyman build (18.0.249.0).
- The stall is induced with the debug-only `KMC_WATCHDOG_FAKEFREEZE`. This proves
  the *mechanism*; it is not the field path.
- All keystrokes are **injected** (`keybd_event`). Injection is demonstrably
  sufficient to trigger the wedge, but Keyman can distinguish synthetic keys
  (`LLKHF_INJECTED`, and the `dwExtraInfo`/`SCAN_FLAG_KEYMAN_KEY_EVENT` checks at
  :229-233), so a physical-keyboard result is not strictly implied.
- Recovery: the injected six-modifier sweep cleared it 3/3, and a physical
  double-tap on LShift also clears it. One earlier run went wedged →
  `NO-OUTPUT` under the same sweep, so recovery is not perfectly reliable.

### Reproducing it

```powershell
cd D:\Github\_Projects\_KM\kmrepro
.\kmproof.ps1 -FingerprintOnly                      # identify all three keyboards
.\kmproof.ps1 -Only I -Repeat 5 -LoadThreads 4      # three-arm comparison
.\kmproof.ps1 -SwitchStress 10 -LoadThreads 4       # control: switches, no freeze
.\kmproof.ps1 -ChargeTest 3 -LoadThreads 4          # charge while inactive, fire on switch
.\kmproof.ps1 -Sweep -SweepTrials 1 -LoadThreads 4  # shortest end-to-end demo (A/B/A)
```

---

### What is NOT established

- That the watchdog is involved. **It is not**: the LowLevelHookWatchDog ghost key
  was absent from every reproducing run. The hypothesis this investigation began
  with (`83251358b0`, 18.0.245) is unsupported.
- The field path that stalls the thread. CPU load alone did not do it (32 hogs on
  16 cores — and that crashed the host PowerShell with `OutOfMemoryException`).
  `-LoadThreads 4` plus the debug freeze is what reproduces here.
- Whether physical keystrokes behave as injected ones do — see scope limits in §3.
- Why the field symptom persists until a Keyman restart when reproduced wedges
  here cleared on a modifier edge. There may be a second factor.

**Now established** (was "that Keyman is strictly required"): Keyman is required,
and more than that — the corruption occurs while Keyman is not even the active
keyboard. See §3.

### Fix

See `FIX-PROPOSAL.md`. In short: (1) re-validate `m_ModifierKeyboardState[]`
against the OS at the start of each injected batch and let the OS win — the same
class of fix as the caps-lock resync in **#16422**, and they should land as one
shared helper; (2) move the `WH_KEYBOARD_LL` hook off the UI thread onto a
dedicated pump, as the serializer already does (`serialkeyeventserver.cpp:90`).
