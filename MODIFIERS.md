# Which modifier keys can this bug actually stick?

Scope question raised after the Shift / RAlt work: the repro so far has only
exercised **LShift** and **RAlt**. What about Ctrl, Caps Lock, Num Lock, Scroll
Lock, Win, Fn, Insert? And in particular:

> Can any of this explain a machine with **no physical Right Ctrl key** reporting
> Right Ctrl as stuck?

**Yes — completely, and it is the cleanest example of the bug there is.** Details
in §3. Code refs are from `fix/windows/16422-caps-lock-state-on-keyboard-switch`
at `a70538106c`, paths relative to `windows/src/engine/keyman32/`.

---

## 1. There are two separate caches, not one

The investigation so far has been about one cache. There are two, with different
contents, different failure modes, and different resync coverage. Keeping them
apart is the whole of this document.

| | **Cache A** — `m_ModifierKeyboardState[256]` | **Cache B** — `Globals::ShiftState()` |
|---|---|---|
| where | `serialkeyeventserver.cpp:51` | `k32_globals.cpp`, a DWORD bitfield |
| holds | 6 bytes: L/R Shift, Ctrl, Alt | K_SHIFT, L/RCTRL, L/RALT + **CAPITAL, NUMLOCK** |
| written by | `UpdateLocalModifierState` (`:554`) | `ProcessModifierChange` (`kmhook_getmessage.cpp:450`), `ProcessToggleChange` (`aiTIP.cpp:102`) |
| seeded | `GetKeyboardState` **once**, `InitThread` `:251` | — |
| resynced from OS | **never** | `GetCapsAndNumlockState()` (`kmhook_getmessage.cpp:418`) — see §4 |
| what corruption does | **injects real phantom keypresses system-wide** | wrong rule matching: wrong case, or no output |

Cache A is the dangerous one, because it is not merely consulted — it is
**re-asserted as real key events** by `keybd_shift_reset()`. Cache B only makes
Keyman mis-map; Cache A makes the whole machine behave as if a key were held.

---

## 2. Exactly six keys are in scope for the phantom-press bug

Cache A is fed only through `isModifierKey()` (`k32_lowlevelkeyboardhook.cpp:62`),
which returns TRUE for **nine VKs collapsing to six slots** and nothing else:

```
VK_LCONTROL VK_RCONTROL VK_CONTROL
VK_LMENU    VK_RMENU    VK_MENU
VK_LSHIFT   VK_RSHIFT   VK_SHIFT
```

`UpdateLocalModifierState` reinforces this with `default: return;` (`:578`), and
both `keybd_shift_release` / `keybd_shift_reset` iterate the same hardcoded six:

```c
const BYTE modifiers[6] = { VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT };
```

So the scope boundary is provable from code, not inferred:

| key | in Cache A? | can be phantom-pressed? | verdict |
|---|---|---|---|
| L/R **Shift** | yes | yes | **vulnerable** — measured, 2/2 each side |
| L/R **Alt** | yes | yes | **vulnerable** — measured, 2/2 each side |
| L/R **Ctrl** | yes | yes | **vulnerable — MEASURED 2026-08-24, 7/7 each side.** See §2b |
| **Caps Lock** | no | no | immune to phantom press; has its own bug (§4) |
| **Num Lock** | no | no | immune to phantom press; has its own bug (§4) |
| **Scroll Lock** | no | no | **immune.** `VK_SCROLL` appears nowhere in keyman32 |
| **Win** (L/R), **Apps** | no | no | **immune.** `VK_LWIN`/`VK_RWIN`/`VK_APPS` appear nowhere in keyman32; Keyman's `.kmn` modifier vocabulary has no Win either |
| **Fn** | no | no | **immune by construction.** Fn is resolved in keyboard firmware/EC and does not surface to Windows as a virtual key on essentially all hardware |
| **Insert** | no | no | immune — but see §5, there is a registry footgun nearby |

## 2a-wire. The defect observed directly, at the wire — 2026-08-25

Everything before this was inferred from cache state plus `GetAsyncKeyState`.
`kmaltgr.ps1` installs a `WH_KEYBOARD_LL` hook and records `vkCode`, `scanCode`,
`flags` and `dwExtraInfo` for every event on the machine, so the injection
itself can be watched. Running it alongside a single `kmmods.ps1` LShift trial
captured the whole `keybd_shift_release` / `keybd_shift_reset` cycle:

```
 7371.5  DN  LSHIFT  scan=0x2A  INJ  KM-SERIALIZED   <- the harness's LShift, replayed
10119.4  DN  vk0x0E  scan=0xFF  INJ                  <- keybd_sendprefix, down
10169.2  UP  vk0x0E  scan=0xFF  INJ                  <- keybd_sendprefix, up
10200.5  UP  LSHIFT  scan=0xFF  INJ                  <- keybd_shift_release
10845.6  DN  LSHIFT  scan=0xFF  INJ                  <- keybd_shift_reset RE-PRESSES it
...
13962.4  DN  LSHIFT  scan=0xFF  INJ                  <- and again, with NO matching UP
19302.2  UP  LSHIFT  scan=0x2A  INJ  KM-SERIALIZED   <- the harness's recovery sweep
```

The tool's own analysis flagged it:

```
[UNMATCHED KEYDOWN] 1 Keyman-injected KEYDOWN(s) with no later KEYUP
```

**That is `keybd_shift_reset` (`keybd_shift.cpp:161-176`) caught in the act.**
Not inferred from a stale cache, not deduced from typed output — the unmatched
KEYDOWN, on the wire, with Keyman's own `SCAN_FLAG_KEYMAN_KEY_EVENT` (`0xFF`,
`keyman64.h:132`) stamped on it. This is the single most direct piece of evidence
in the repo and it should be what a PR description leads with.

### Two markers worth knowing, both confirmed against source

| marker | meaning |
|---|---|
| `scanCode = 0xFF` | `SCAN_FLAG_KEYMAN_KEY_EVENT` (`keyman64.h:132`). Keyman **synthesized** this key. `keybd_shift_reset`'s phantom presses carry it. |
| `dwExtraInfo = 0x4B4D0000` | `EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT` (`keyman64.h:134`), "KM" in ASCII. `serialkeyeventserver.cpp:488/495/526` **replaying a real user keystroke**, with its original scan code. |

They are different paths and must not be conflated: a replayed user key is the
serializer doing its job; a `0xFF` key is Keyman inventing one. Only the second
can be a phantom.

### The prefix VK, observed (bears on I11)

`vk0x0E scan=0xFF` appears repeatedly — `keybd_sendprefix` bracketing each batch,
exactly as `keybd_shift.cpp:112-118` describes. In this capture **every prefix
KEYDOWN had a matching KEYUP**, so I11's non-atomic `PostDummyKeyEvent` path did
not misfire here. That is one clean run, not a clearance: the two emitters are
still different (`keybd_sendprefix` is atomic, `PostDummyKeyEvent` is not) and
`kmmods.ps1` did observe one `PREFIX-LATCH` on 2026-08-24. Keep watching.

---

## 2b. §2 measured, not inferred — 2026-08-24

§2 was derived from reading `isModifierKey()` and the two `modifiers[6]` arrays.
`kmmods.ps1` now tests it. Same keyboard (`sil_cameroon_qwerty`), same window,
same stimulus (candidate `I`: hold, freeze confirmed live, release into the
stall) applied to every key. The oracle is `GetAsyncKeyState` taken while the
harness holds nothing, so any high bit is a phantom by definition.

**Negative controls ran FIRST**, from a verified-clean cache — see §2c for why
that ordering is not optional.

| key | §2 predicted | self-latched | held set |
|---|---|---|---|
| Insert | immune | **0/2** | none |
| Num Lock | immune | **0/2** | none |
| Caps Lock | immune | **0/2** | none |
| Scroll Lock | immune | **0/2** | none |
| Left Shift | can latch | **2/2** | `LSHIFT` |
| Right Shift | can latch | **2/2** | `RSHIFT` |
| Left Ctrl | can latch | **2/2** (+5/5 in a dedicated run) | `LCTRL` |
| Right Ctrl | can latch | **2/2** (+5/5 in a dedicated run) | `RCTRL` |
| Left Alt | can latch | **2/2** | `LALT` |
| Right Alt | can latch | **2/2** | `RALT` |

**§2 holds exactly as written.** Six keys latch, deterministically — every single
trial, no intermittency. The four immune keys never appeared in the held list
under the identical stimulus. The "L/R Ctrl — never tested" caveat is lifted:
Ctrl latches on both sides, 7/7 per side across two runs.

**And the freeze is the mechanism on this axis too, not just for LShift.**
Candidate `A` — the identical hold-and-release with **no freeze posted** — was run
across all ten keys: **0/20 latched**, every trial `CLEAN`, including the six that
latch 2/2 with the freeze. Previously this repo could only say that for LShift,
via `kmproof.ps1`; it is now measured for all six. Note also that every latch
above was obtained at `-LoadThreads 0`: the confirmed freeze alone is sufficient,
no CPU load is needed.

### Two things the text oracle could not have caught

**A latched Ctrl can coexist with perfectly clean text.** `RCTRL p1` and `p2`
both read `held=RCTRL` while the text probe returned `jkq` — lowercase, correct,
indistinguishable from clean. This is *worse* than §6's warning, which said only
that Ctrl produces no case change. It means `kmproof.ps1` would have scored these
trials **CLEAN**: not "unreadable, retry", not "NO-OUTPUT", but a positive clean
verdict on a machine with a phantom Ctrl held system-wide. Any text-only oracle is
blind here, and no amount of re-running would have found it.

**A latched Alt empties the probe entirely.** Every `LALT` and `RALT` trial
returned `<empty>`; `kmproof`'s `Probe()` treats that as an unreliable read to be
retried, so it would have discarded the evidence three times and then reported
the last undecided read. The state oracle carried the measurement in both cases.

### Do not read side-collapse into this

An earlier pass looked like it showed a Right Ctrl latch dragging Left Ctrl with
it — plausible, because `do_keybd_event` (`keybd_shift.cpp:63-88`) collapses
`VK_RCONTROL`/`VK_LCONTROL` to a bare `VK_CONTROL` and passes
`SCAN_FLAG_KEYMAN_KEY_EVENT` (`0xFF`, `keyman64.h:132`) as the scan code, which is
not a real scan code and leaves Windows nothing but the extended bit to resolve
the side from.

**It was an artefact.** `LCTRL` had run in the arm immediately before, and the
apparent pairing was §2c residue. Re-run alone from a clean cache, `RCTRL` latches
`RCTRL` and nothing else — 2/2. Same for `RSHIFT`.

So the extended bit alone *is* sufficient to resolve the side even with a `0xFF`
scan code, at least for Ctrl. Note the asymmetry in `do_keybd_event` though: for
Shift it takes the trouble to set `scan = SCANCODE_RSHIFT` explicitly, while for
Ctrl and Alt it leaves `0xFF` and relies purely on `KEYEVENTF_EXTENDEDKEY`. That
asymmetry is unexplained and still worth asking about, but the measurement says
it is not currently producing a wrong-side latch.

---

## 2c. The latch set ACCUMULATES within a session — mechanism unknown

Not predicted by anything in this document, and it changes how the harness has to
be run.

Held set at the end of each arm, one run, in run order:

```
INSERT     none
NUMLOCK    none
CAPSLOCK   none
SCROLL     none
LSHIFT     LSHIFT
RSHIFT     LSHIFT,RSHIFT
LCTRL      LSHIFT,RSHIFT,LCTRL
RCTRL      LSHIFT,RSHIFT,LCTRL,RCTRL
LALT       LSHIFT,RSHIFT,LCTRL,RCTRL,LALT
RALT       LSHIFT,RSHIFT,LCTRL,RCTRL,LALT,RALT
```

Monotonic. It never shrank. And this is **not** a failure to clean up between
trials: every trial logged `recovered by the explicit KEYUP sweep alone`, and
every following trial's pre-check read `held=none`. The OS-level state was
genuinely cleared each time. The next arm's poke brought all of it back.

So the residue survives somewhere the injected KEYUP sweep does not reach — which
is consistent with §3c, where Cache A re-confirms its own contents on every
injected batch.

**But "Cache A is simply additive" is NOT supported, and must not be written up
as a finding.** The state does *not* survive between script invocations.

### What resets it — two hypotheses tested and both killed, 2026-08-24

`kmmods.ps1 -FocusTest` latches LShift, clears OS state, confirms by poking that
the cache still re-asserts it, then applies exactly one intervention:

| intervention | latch cleared? |
|---|---|
| wait **30 s**, foreground untouched | **no** — `held=LSHIFT` |
| minimise + restore the target (focus out and back), no wait | **no** — `held=LSHIFT` |
| **new process, 9 s later** | **yes** — `held=none`, text probe clean |

So it is **not a timer** and **not the focus resync**. The obvious candidate was
`KM_FOCUSCHANGED` → `GetCapsAndNumlockState` (`kmhook_getmessage.cpp:357`), which
resyncs five modifiers as well as the two toggles (finding 4a) and would have
explained everything neatly. **It does not survive contact with the measurement.**
Minimise/restore is a genuine focus loss and regain — verified, the target was
foreground again — and the latch came straight back on the next poke.

What does clear it is crossing a **process boundary**: the injecting PowerShell
exits, a new one starts, and 9 seconds later the cache reads clean — far *less*
elapsed time than the 30 s wait that did nothing.

**This bears directly on I6** (`TODO.md`), which asks whether Cache A is one
instance per machine or one per host process. A latch that dies with the
injecting process and not with time or focus is evidence for process- or
thread-scoped state, seeded once at `InitThread`
(`serialkeyeventserver.cpp:251`). Note the injecting process is *not* the host —
Notepad and keyman.exe both run continuously across all of these runs — so
whatever is scoped this way is not obviously either of them, and that is exactly
what makes it worth chasing.

### The sweep confound, tested and also killed

Process exit was confounded with something mundane: the script's `finally` runs a
*second* consecutive `Release-All` with no injected batch between the two, which
no in-loop recovery ever does. So "two back-to-back sweeps cleared it" fitted
every observation just as well, and implied a completely different fix.

`kmmods.ps1 -SweepTest -SweepCount N`, one N per process:

| sweeps applied, no batch between | OS state after | cache cleared? |
|---|---|---|
| 1 (reproduces the in-loop recovery) | `held=none` | **no** — poke returns `LSHIFT` |
| 2 (reproduces the `finally` path) | `held=none` | **no** — poke returns `LSHIFT` |

**Also dead.** Note what the middle column says: the KEYUP sweep genuinely does
clear OS-level key state, every time. The very next injected batch puts it back.

### Where that leaves it

Four interventions tested, one works:

| intervention | clears the latch? |
|---|---|
| wait 30 s | no |
| focus out and back (minimise/restore, verified) | no |
| 1 KEYUP sweep | no |
| 2 consecutive KEYUP sweeps | no |
| **new process, 9 s later** | **yes** |

Crossing a process boundary is the only thing that has ever cleared this, and it
does so in *less* elapsed time than the wait that did nothing.

**Read as support for I6, but not as proof, and here is the caveat that matters.**
The injecting process is not the host: Notepad and keyman.exe both ran
continuously across every run above. So if this is Keyman state, it is scoped to
something that tracks the *injector*, which would be genuinely surprising and
worth chasing. But an alternative has not been excluded — that some of what is
being observed is cleaned up by **Windows** when the injecting process exits,
rather than by anything in Keyman at all. Distinguishing those needs an injector
that can be made to exit without the observer exiting with it, which this harness
cannot currently do. Until then the mechanism is open — `TODO.md` I12.

Two consequences that hold regardless of mechanism:

1. **Only arms that run before the first latch are clean measurements.** Negative
   controls must go first, which is now `kmmods.ps1`'s default order, or Keyman
   must be restarted between blocks. The first attempt at this table scored all
   four immune keys as "2/2 latched" purely because six carried-over slots were
   still held — none of the four ever appeared in the held list. The summary now
   reports a `self` column (did *this* key latch) separately from `any`.
2. **If it holds in the field, the symptom compounds rather than swapping.** A
   user would accumulate stuck modifiers across a session rather than trading one
   for another. Worth checking against the field reports, which describe
   persistence until a Keyman restart.

---

**Practical consequence.** The user-facing symptom set is bounded: a stuck Shift,
Ctrl or Alt, either side. A report of "stuck Caps Lock" or "stuck Num Lock" is a
*different* defect (§4), and a report of "stuck Win key" or "stuck Fn" is not this
bug at all — Keyman never touches those keys.

---

## 2a. Can a **letter or number** key get stuck?

Asked 2026-08-24. Short answer: **not by this bug, provably — but yes by a
different one, and that one has never been written down.**

### Not via Cache A. This is provable, not inferred.

`do_keybd_event()` is the single funnel through which the modifier machinery
emits key events, and it has **exactly four call sites in the entire engine**,
all in `keybd_shift.cpp`:

| line | what it emits |
|---|---|
| `:116` / `:117` | the prefix VK, down then up — always a matched pair |
| `:144` | `modifiers[i]`, KEYUP (`keybd_shift_release`) |
| `:169` | `modifiers[i]`, KEYDOWN (`keybd_shift_reset`) |

`modifiers[6]` is the same hardcoded six in both functions. `UpdateLocalModifierState`
ends in `default: return;` (`:578`). There is no path by which a letter or a
digit reaches Cache A or `keybd_shift_reset`. **A stuck letter is not this bug**,
and a field report of one should not be filed against it.

### But there is a second unmatched-KEYDOWN path, and it takes any VK

`kmprocess.cpp:181-182`, in the `use(final)` default-output path:

```c
_td->app->QueueAction(QIT_VKEYDOWN, _td->state.vkey);
_td->app->QueueAction(QIT_VKEYUP,   _td->state.vkey);
```

`QueueAction` (`appint/appint.cpp:51-57`) is **fallible**:

```c
if(QueueSize > MAXACTIONQUEUE - 1) { MessageBeep(0xFFFFFFFF); return FALSE; }
```

**Both return values are ignored.** `MAXACTIONQUEUE` is 1024 (`appint.h:51`). At
exactly `QueueSize == 1023` the VKEYDOWN takes the last slot and the VKEYUP is
silently refused. `aiWin2000Unicode.cpp:138-166` then builds the `INPUT` batch
from the queue — `QIT_VKEYDOWN` and `QIT_VKEYUP` are handled in **separate,
independent `case` arms with nothing pairing them** — and `SendInput`s a real
KEYDOWN for `_td->state.vkey`, **the key the user just pressed**, with no KEYUP
anywhere. That is a stuck letter or number, machine-wide, by the same
unmatched-KEYDOWN shape as the modifier bug.

Contrast `QIT_CHAR` (`:183-195`) and `QIT_BACK` (`:206-218`), which each emit
down **and** up inside one loop iteration and therefore cannot split. Only the
VKEY pair is exposed.

**Reachability — do not overstate this.** It needs all of: a legacy
(non-TSF) app (`IsLegacy()`), a keyboard requesting default output
(`use(final)`-style), and a single keystroke that queued ≥1023 actions. That is
narrow. It is not everyday typing, and nothing here says it has happened in the
field.

**Two things make it worth logging anyway.** First, `KMQueueAction`
(`calldll.cpp:368`) is an *exported* entry point, so the queue is not only filled
by the keyboard itself. Second, the failure has a **distinctive audible
signature**: `QueueAction` calls `MessageBeep` on the way to refusing. A field
report of *"it beeped and then a letter got stuck"* is this, not Cache A.

Corroborating detail: `aiWin2000Unicode.cpp:154-163` carries an existing
workaround (`I2787`, "Reset keyboard state so Chrome doesn't get confused") that
calls `GetKeyboardState`/`SetKeyboardState` to zero the key's state byte right
after queueing a VKEYDOWN. That only touches the *calling thread's* state and
runs *before* `SendInput` delivers anything, so it cannot clear the async,
system-wide latch — but its existence shows someone already hit "VKEYDOWN leaves
key state behind".

### How to measure it

`kmmods.ps1` watches `KEY_A`, `KEY_Z`, `KEY_1` and `SPACE` with `GetAsyncKeyState`
on **every** trial, whichever modifier is under test, and scores a held letter as
`KEY-LATCH:<id>` rather than folding it into the Cache A verdict. `-IncludeOrdinary`
additionally applies the stimulus to them. The three mechanisms are kept apart in
the output on purpose:

| verdict | mechanism | file |
|---|---|---|
| `PHANTOM:<mod>` | Cache A, `keybd_shift_reset` re-press | `keybd_shift.cpp:161-176` |
| `CACHEB-SHIFT` | Cache B, stale cached flag, OS clean | `aiTIP.cpp` / `kmhook_getmessage.cpp` |
| `KEY-LATCH:<key>` | dropped `QIT_VKEYUP` | `kmprocess.cpp:181-182` |
| `PREFIX-LATCH` | dropped prefix KEYUP | `keyman32.cpp:923-926`, see §5 |

---

## 3. Right Ctrl on a keyboard with no Right Ctrl key

This is the highest-value case, because it is the one where the phantom is
provably **not** hardware and provably **not** self-healing.

### 3a. The press is synthesized in software

`keybd_shift_reset()` (`keybd_shift.cpp:161-176`) emits, for every byte in Cache A
sitting at `0x80`, a KEYDOWN **with no matching KEYUP**. For `VK_RCONTROL`,
`do_keybd_event()` (`keybd_shift.cpp:69-73`) rewrites it:

```c
case VK_RCONTROL:
  flags |= KEYEVENTF_EXTENDEDKEY;
  /*fallthrough*/
case VK_LCONTROL:
  vk = VK_CONTROL;
  break;
```

`VK_CONTROL` + `KEYEVENTF_EXTENDEDKEY` is precisely the byte pattern Windows
resolves to Right Ctrl. After `SendInput`, `GetAsyncKeyState(VK_RCONTROL) < 0`
**system-wide, on hardware that has no Right Ctrl key.** No physical key is
involved at any point. The phantom is entirely Keyman's own injection.

### 3b. And the user cannot clear it

The documented workaround — "tap each of Shift, Ctrl, Alt once, both sides" —
works because a genuine physical KEYUP reaches `UpdateLocalModifierState` and
writes `0`. The clearing event for the `VK_RCONTROL` slot is specifically
`VK_CONTROL` + extended + KEYUP.

**A user with no Right Ctrl key cannot produce that event.** The workaround is
unavailable for exactly this key on exactly this hardware, and Cache A has no
other resync path — it is seeded once at `:251` and never re-read. The only exit
is restarting Keyman.

### 3b measured, 2026-08-24

`kmmods.ps1 -Latch RCTRL` injects the byte pattern `keybd_shift_reset` produces
(`vk=0x11 VK_CONTROL, scan=0x1D, KEYEVENTF_EXTENDEDKEY`, no matching KEYUP) and
then tries each clearing action in turn:

| # | action | cleared it? |
|---|---|---|
| 0 | inject the unmatched KEYDOWN | `GetAsyncKeyState(VK_RCONTROL)` held, `CONTROL*` aggregate held |
| 1 | type `jkq` | **no** — and the text came back `<empty>`, the keys were swallowed |
| 2 | tap the **other side** (Left Ctrl), down+up | **no** |
| 3 | the exact matching Right Ctrl KEYUP | **yes** |

**§3b is confirmed.** Only the exact matching KEYUP clears the slot. Tapping Left
Ctrl — which every keyboard has — does nothing for it, so the workaround genuinely
is unavailable to a user whose hardware lacks a physical Right Ctrl, and for them
persistence-until-Keyman-restart is expected behaviour rather than a mystery.

Step 2 is the one that mattered: had the sibling tap cleared it, the whole
missing-key story would have collapsed, because Left Ctrl is always available.

#### This dev machine IS the affected hardware class — confirmed 2026-08-25

Worth stating plainly, because it was assumed rather than established until now:
**this machine has no physical Right Ctrl key.** The `kmaltgr.ps1` MSKLC capture
recorded seven clean Ctrl tap pairs, every one arriving as `LCTRL scan=0x1D`
non-extended with a matching KEYUP — those were the Left Ctrl, and there is no
right-hand one to press.

So §3 is not being reasoned about at arm's length. The development machine is a
member of the exact hardware population the section describes, which is why §3b's
"the workaround is unavailable to the user" is a direct observation here rather
than an extrapolation.

**Step 3 used an injected KEYUP, and that is sufficient — provably, not merely
plausibly.** `kmmods.ps1` injects with `dwExtraInfo = 0` and the real `scan=0x1D`,
so the filter at `k32_lowlevelkeyboardhook.cpp:233`
(`dwExtraInfo != 0 || scanCode == SCAN_FLAG_KEYMAN_KEY_EVENT`) cannot distinguish
it from hardware — both pass identically, and `LLKHF_INJECTED` is never consulted.
A physical Right Ctrl on an external keyboard would therefore be a positive
control on a path with no branch in it. Cheap if such a keyboard is already at
hand; not worth sourcing one, and **not** a substitute for the field-hardware
reading that item 2 actually needs.

This closes a gap `FIX-PROPOSAL.md` currently lists as unexplained: *"The field
reports describe persistence until a Keyman restart; that gap is unexplained."*
For L/R Shift and L/R Alt the wedge self-heals on the next physical tap, which is
why the repro kept seeing it clear. For a missing-key modifier it cannot heal.
**Persistence-until-restart is expected behaviour when the latched key does not
physically exist.**

### 3c. Worse: the latch re-arms itself

The modifier post at `k32_lowlevelkeyboardhook.cpp:198` runs **35 lines before**
the filter at `:233` that discards Keyman's own events
(`hs->dwExtraInfo != 0 || hs->scanCode == SCAN_FLAG_KEYMAN_KEY_EVENT`). So the
phantom KEYDOWN that `keybd_shift_reset` just injected is seen by Keyman's own
hook and written straight back into Cache A as `0x80`.

Cache A therefore does not merely *fail to refresh* — it **re-confirms its own
hallucination on every injected batch**. This is a closed loop, and a second
independent reason the state is stable rather than transient.

### 3d. Where does the initial Right Ctrl come from? (open — needs measurement)

§3a-c explain the phantom press and its persistence. What they do not prove is
the **seed**: one extended-Ctrl KEYDOWN whose KEYUP is missed. Candidates, most
to least likely, all testable:

1. **`GetKeyboardState` at `InitThread` (`:251`) captures a transient.** One-shot
   seed at Keyman startup, never corrected. Would present as "broken from login".
2. **Anything that emits `E0 1D`.** RDP / Citrix / VNC, VM guest tools,
   PowerToys / AutoHotkey remaps, KVM switches, on-screen keyboard, and — note
   the irony — **vendor Fn-layer drivers on laptops that lack a Right Ctrl key**,
   which is where that key commonly gets remapped to in the first place.
3. **AltGr.** Windows synthesizes a Ctrl keydown alongside RAlt on AltGr layouts.
   Standard behaviour is *Left* Ctrl, non-extended, so this normally seeds
   `LCTRL` — but Keyman evidently knows the pairing is quirky, because
   `aiTIP.cpp:467` special-cases exactly `TF_MOD_RALT|TF_MOD_LCONTROL`.

   **This one matters most and is cheapest to check.** The Cameroon keyboards use
   RAlt as AltGr on *every accented character*. If any driver in the field emits
   that synthetic Ctrl with the extended bit set, the seed is not exotic at all —
   it is every keystroke the user types.

Test for (3): log `KBDLLHOOKSTRUCT.vkCode` / `scanCode` / `flags & LLKHF_EXTENDED`
for the Ctrl event that accompanies AltGr, on the affected hardware. Partly done
— see §3d-measured immediately below.

### 3d-measured. I1 answered on this machine: the AltGr Ctrl is never extended — 2026-08-25

Two physical `kmaltgr.ps1 -Watch 45` runs, one per arm. **The answer is NO on this
machine, on both arms, and for different reasons.**

| arm | input | synthetic Ctrl? | side | extended? | n |
|---|---|---|---|---|---|
| Keyman TIP | **physical** | **none at all** | — | — | 20 presses |
| MSKLC (`0x0436`) | **physical** | **yes**, `scan=0x21D` | **LEFT** | **no** | 22 presses |
| MSKLC | injected | yes, `scan=0x21D` | LEFT | no | `-Arms` |
| US | injected | none | — | — | `-Arms` |

#### The MSKLC arm — the one that actually exercises `KLLF_ALTGR`

This is the reading that decides item 3, because MSKLC is the only arm whose
layout sets `KLLF_ALTGR` and therefore the only one where Windows synthesizes
anything. 22 physical AltGr presses, and **all 22 paired with a non-extended
LEFT Ctrl**:

```
 83.2  DN  LCTRL  scan=0x21D  ALTDOWN       <- synthetic, 15.8 ms ahead of the RAlt
 99.0  DN  RALT   scan=0x38   EXT|ALTDOWN
115.9  UP  LCTRL  scan=0x21D                <- and released first, too
130.5  UP  RALT   scan=0x38   EXT
```

44 of 44 Ctrl events carried `scanCode 0x21D`, Windows' own marker for the fake
AltGr Ctrl, so this is positive identification rather than an unrelated Ctrl
landing nearby. Lead time was 14.5–17.1 ms on every one of the 22. Analysis 3:
*"No E0-prefixed Ctrl reached the hook from any source during this run."*

**So the AltGr path on this machine seeds `LCTRL`, which is textbook Windows
behaviour.** The physical result is identical to the injected one, which also
retroactively justifies using `-Arms` as a cheap proxy on this particular path.

Do not read this as an all-clear. An `LCTRL` seed is **still a stuck Ctrl** —
`LCTRL` latches 7/7 (§2b). It is merely *clearable*, because every keyboard has a
physical Left Ctrl. The severity escalation item 3 is really about needs the
*extended* variant, and that is now a field-hardware question only.

#### The Keyman arm — nothing to synthesize in the first place

20 physical press/release cycles with the Keyman TIP focused, 128 events:
**not one Ctrl event of any kind.** Not extended, not non-extended — none. No
`scan=0x21D` anywhere, and Analysis 3 again reported no E0-prefixed Ctrl from any
source.

These were real fingers, not injection. Every press arrives as a pair — the
physical event, then Keyman's serializer replaying it ~16 ms later:

```
41298.9  DN  RALT  scan=0x38  EXT|ALTDOWN                       <- physical
41315.0  DN  RALT  scan=0x38  EXT|INJ|ALTDOWN  KM-SERIALIZED    <- serializer replay
41362.0  UP  RALT  scan=0x38  EXT
41377.6  UP  RALT  scan=0x38  EXT|INJ          KM-SERIALIZED
```

**Why there is nothing to see:** the AltGr→Ctrl synthesis is a property of the
*layout* — a `KBDTABLES` carrying `KLLF_ALTGR`. The Keyman TIP sits on a US base
layout, which does not set that flag, so Windows performs no synthesis and the
right-hand Alt key is simply `VK_RMENU`. On this arm **AltGr seeds neither Ctrl
slot**, which is a stronger result than "non-extended, therefore only `LCTRL`".

#### The serializer only engages on a Keyman keyboard

Incidental but load-bearing, and it needs care. The Keyman-arm run doubled
**every** keystroke with a `KM-SERIALIZED` replay. The MSKLC-arm run produced
**zero** replays across 102 events. So `serialkeyeventserver.cpp` replays only
when a Keyman keyboard is actually processing the key.

That has to be held alongside the separately-measured claim that **the wedge is
charged while a non-Keyman keyboard is active** (3/3, `kmproof.ps1 -ChargeTest`).
Both are true and they are not in conflict — charging the wedge is not the same
act as replaying a keystroke — but anyone quoting one should know about the
other, because "Keyman is inert on other layouts" is the wrong conclusion to draw
from the null above.

#### Footnote: the LCTRL branch, and a source comment that is wrong

Three things worth keeping from this same measurement, because they bear on where
a fix goes rather than on the RCTRL seed question.

**1. The AltGr Ctrl arrives already sided, so it never touches the ternary.**
`kmaltgr.ps1:239-241` renders `0x11` as `CONTROL` and `0xA2` as `LCTRL`; the
capture printed **`LCTRL`**, so `vkCode` was `0xA2`. It therefore takes the
*pass-through* case at `serialkeyeventserver.cpp:567-575`, **not** the
`fIsExtendedKey` ternary at `:558` that `Phantom_RCTRL.md` §1 identifies as the
RCTRL seed. So the comment at `:574` — *"These are technically not needed but
perhaps some app will send them through SendInput and we'll have to deal with
them?"* — **is wrong.** That case carries the highest-frequency Ctrl traffic on an
AltGr layout: 44/44 events in this run. A fix aimed at the ternary would miss it
entirely.

**2. Keyman's source already documents a missing LCtrl KEYUP.** `:449-482`:
*"When Windows has a European layout that uses AltGr installed, it can emit an
additional LCtrl down via software when RAlt is pressed. **However, the
corresponding LCtrl up is never received** […] So we simulate the release of the
Left Control key ourselves […] and hope for the best."* The LCTRL seed condition
is therefore documented engine behaviour on every AltGr layout, not something
anyone has to hunt for.

**3. That rescue (`:447`) has three conjuncts, and each is a failure mode.** If
any fails, no simulated release is emitted and the LCTRL slot stays at `0x80`:

- `wParam == VK_RMENU` — the *sided* 0xA5 only. An injector sending unsided
  `VK_MENU` + extended updates the cache via the ternary at `:562` and **skips the
  rescue.** The cache normalises nine VKs; the rescue matches one.
- `GetKeyState(VK_LCONTROL) < 0` — **the rescue depends on the processed-input-queue
  state whose staleness is this entire bug** (`FIX-PROPOSAL.md:89-91`). Under the
  UI-thread stall it reads "LCtrl is not down" and declines to release it.
- The RAlt KEYUP must arrive at all.

**Where that leaves LCTRL:** the frequent-but-clearable mirror of §3. Any physical
Left Ctrl tap clears it — sided `0xA2` → `:567` → `:581` writes `0`, proven from
source. **The join is not measured end to end:** the synthesis is measured (22/22
above), the latch is measured (7/7, §2b), the composition of the two is inference.
Do not quote it as established.

#### Still owed

**Affected field hardware.** This is now the *only* remaining part of item 3, and
it is the part that decides severity. A vendor Fn-layer driver emitting `E0 1D`
on a laptop with no Right Ctrl key is §3d item 2 territory, and nothing measured
on this machine touches it.

The US arm was never tested physically. Low value: US is not an AltGr layout, it
is not a configuration any Cameroon user runs, and injected `-Arms` already shows
no synthesis. Noted for completeness, not as a gap.

---

## 4. The un-read-state bug: Caps, Num, and the five modifiers

**Moved.** This is a *separate defect* — Cache B, no phantom keypress, symptom is
wrong output or no output while every physical key is genuinely up. It is
Keyman issues [#16422] / [#16423], not [#8064].

Findings **4a** (the keyboard-switch resync is two flags short of its sibling
set), **4b** (both helpers use `GetKeyState` where `GetAsyncKeyState` is
required) and **4c** (Shift has no L/R split in Cache B, Ctrl and Alt do) now
live in **[`capslock/FINDINGS.md`](capslock/FINDINGS.md)**.

The Cache A / Cache B distinction itself stays in §1 above — it is what keeps
the two defects apart, and both documents need it.

[#16422]: https://github.com/keymanapp/keyman/issues/16422
[#16423]: https://github.com/keymanapp/keyman/issues/16423
[#8064]: https://github.com/keymanapp/keyman/issues/8064

## 5. Insert, and the `Zap Virtual Key Code` footgun

`VK_INSERT` (0x2D) appears nowhere in keyman32, so Insert cannot be latched or
phantom-pressed. But something adjacent is worth knowing about.

`keybd_sendprefix()` (`keybd_shift.cpp:112-118`) injects a dummy key down+up
around any batch that releases a modifier, to stop a bare Alt from opening the
menu. That key is `Globals::get_vk_prefix()`, defaulting to
`_VK_PREFIX_DEFAULT = 0x0E` (`aiTIP.h:36`) — a **reserved/undefined VK**, chosen
precisely so it does nothing.

It is **registry-overridable**: `k32_globals.cpp:374-380` reads
`REGSZ_ZapVirtualKeyCode` and will use any VK put there. Set it to `0x2D` and
Keyman injects Insert around every modifier-bearing keystroke — overtype mode
toggling on and off, which is exactly the kind of "the keyboard has gone weird"
report that gets filed as a stuck-modifier bug.

Checked on this machine (2026-08-23): **not set**, in either
`HKCU\Software\Keyman\Keyman Engine` or
`HKLM\Software\WOW6432Node\Keyman\Keyman Engine`. So the default 0x0E is in use
and Insert is ruled out *here*. Cheap to check on an affected machine; worth
adding to any diagnostic script. (`kmmods.ps1` now reads it and prints
it in its catalog; note `k32_globals.cpp:375` opens **HKLM only**, so a stray
HKCU value looks alarming in a registry dump but is not actually read.)

### 5a. The prefix has two emitters, and only one of them is atomic

Added 2026-08-24. This is the part that makes the prefix VK more than a
configuration curiosity.

| emitter | how | atomic? |
|---|---|---|
| `keybd_sendprefix()` — `keybd_shift.cpp:112-118` | writes down+up into the shared `INPUT` array, flushed by **one** `SendInput` | **yes** — the pair cannot split |
| `PostDummyKeyEvent()` — `keyman32.cpp:923-926` | **two separate legacy `keybd_event()` calls** | **no** |

`PostDummyKeyEvent` is called from `k32_lowlevelkeyboardhook.cpp:294`,
`kmhook_keyboard.cpp:146` and `:195`. Nothing guarantees the two `keybd_event`
calls are not separated — including by the very UI-thread stall this whole
investigation is about. Lose the second one and the prefix VK is latched down
with no matching KEYUP: the same defect shape as Cache A, in a different file,
on a key that is not a modifier at all.

On a default machine the latched key is VK `0x0E`, which no application maps, so
it is **invisible to every text-based oracle** — `kmproof.ps1` could not see it
under any circumstances. `GetAsyncKeyState(0x0E)` reports it perfectly, which is
why `kmmods.ps1` watches it as `ZAPVK` and never injects it: the script cannot be
the source, so a high bit there can only have come from Keyman.

Whether it actually happens is **unmeasured**. The point is that nothing prevents
it and nothing until now was looking.

---

## 6. What this changes about the repro

The harness has only ever exercised LShift and RAlt. Three gaps, in priority
order:

1. ~~**Ctrl has never been tested at all**~~ — **done 2026-08-24.** Both sides
   latch, 7/7 each, deterministically. See §2b.
2. ~~**A missing-key arm.**~~ — **done 2026-08-24**, `kmmods.ps1 -Latch`. Only the
   exact matching KEYUP cleared a latched Right Ctrl; neither typing nor a Left
   Ctrl tap touched it. See §3b. Still worth confirming on real affected hardware
   (`TODO.md` I7), but the claim no longer rests on code reading alone.
3. **The AltGr-to-Ctrl extended-bit question** (§3d item 3). An LL-hook logger
   recording `vkCode` / `scanCode` / `LLKHF_EXTENDED` for the synthetic Ctrl that
   accompanies AltGr. If it is ever extended, the seed is every keystroke and the
   severity of this whole bug goes up sharply. **Answered NO on this machine**
   (§3d-measured, 2026-08-25): the Keyman arm synthesizes no Ctrl whatsoever, and
   the MSKLC arm's synthetic Ctrl is `LCTRL`, non-extended. Still owed: a physical
   reading on the MSKLC arm, and anything at all from field hardware.

Also worth noting for the oracle design: the existing case-sensitivity trap
(`-ceq` / `-cne`) is a **Shift**-specific artifact. A stuck Ctrl produces no case
change at all — it produces swallowed keys and stray accelerators. The
`abc`/`ABC` oracle will read **CLEAN** under a stuck Ctrl. Any Ctrl arm needs a
different probe (e.g. whether a literal `a` arrives at all), or it will report
false negatives the same way the case-insensitive comparison did.

---

## 7. Where fixes belong

Per direction on 2026-08-23:

- **Stuck-modifier (Cache A) work — not being fixed in Keyman code yet.** Stays
  here as repro + analysis. §3 is the part to lead with when it does go upstream:
  it is the mechanism, it is provable from code, and it explains the persistence
  the current write-ups flag as unexplained.
- **Un-read-modifier-state (Cache B) work — split out to
  [`capslock/`](capslock/README.md)**, and belongs on the #16423 branch, which is
  already "stop trusting cached lock state, re-read it". Findings **4a**, **4b**
  and **4c** and the fixes that follow from them now live there.
