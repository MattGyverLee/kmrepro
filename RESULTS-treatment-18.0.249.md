# RESULTS — treatment run, Keyman 18.0.249.0

Diff partner: `RESULTS-control-18.0.238.md` (18.0.238, all clean).
Run date: 2026-08-22. Rig logic unchanged from the control run except for one
gate fix (see "Rig fix" below).

**Bottom line: BOTH tracks are COMPLETE and every scenario is as clean as the
control. The watchdog code is confirmed present and live on this build, but the
hypothesised failure did NOT reproduce in 45 iterations across Notepad and
FieldWorks. Zero failures, zero phantom modifiers.**

---

## Build identification

| item | control 18.0.238 | treatment 18.0.249.0 |
|---|---|---|
| registry version | 18.0.238 | **18.0.249.0** |
| watchdog code present | no | **yes (18.0.245+)** |
| master controller hwnd | — | 0x706B2 |
| `LowLevelHooksTimeout` | default | default (unset) |
| ETW `debug` flag | unset | unset |

`kmrepro.ps1 Status` self-classified this machine as **TREATMENT group**.

## T2 — the version discriminator (post WM_KEYMAN_CONTROL wParam=20)

| | control 18.0.238 | treatment 18.0.249.0 |
|---|---|---|
| `SendMessageTimeout(WM_NULL)` after cmd 20 | **0 ms** | **4704 ms** |
| verdict | cmd 20 INERT | **FREEZE IS LIVE** |

**The discriminator flipped, exactly as handoff §8 predicted it would.** Command 20
now blocks keyman.exe's main thread — the thread that owns `WH_KEYBOARD_LL` — for
~5 s, matching `Sleep(5000)` in the `KMC_WATCHDOG_FAKEFREEZE` handler
(`UfrmKeyman7Main.pas:868`). T1 responsiveness was 8/0/0 ms, same as control.

### wParam 20 collision — checked and ruled out

`keymancontrol.h` defines **both** `KMC_WATCHDOG_FAKEFREEZE = 20` (line 52) and
`KMC_LANGUAGEHOTKEY = 20` (line 67) as wParam values on the *same*
`WM_KEYMAN_CONTROL` message. `KMC_LANGUAGEHOTKEY` has **no handler anywhere in
`windows/src`** (grepped) — it is a dead constant — so wParam 20 reaches the
fakefreeze handler unambiguously, and the measured ~4.7 s matches `Sleep(5000)`
and nothing in the hotkey path. **The T2 verdict is sound.**
Worth reporting upstream as a latent hazard regardless: if `KMC_LANGUAGEHOTKEY`
is ever revived, posting 20 becomes ambiguous.

---

## Notepad track — COMPLETE (UI Automation oracle)

Expected string `abcDEFghiəŋ`, learned fresh each run. Keyman engagement confirmed
behaviourally every run (`ə` U+0259 **and** `ŋ` U+014B both produced).

| scenario | iterations | failures | no-output | phantom modifiers | control |
|---|---|---|---|---|---|
| Baseline ghost burst | 20 posts | — | — | **0** | 0 |
| AutoTest Clean | 3 | **0** | **0** | **0** | 0 |
| AutoTest Ghost | 15 | **0** | **0** | **0** | 0 |
| AutoTest Freeze | 15 | **0** | **0** | **0** | 0 |

`final mods down: none` on every scenario. **Zero regression vs the control.**

### The Freeze scenario genuinely landed — this is a real negative

A clean `Freeze` result would be worthless if the 5 s block missed the typing
window, so this was verified rather than assumed. Per iteration
(`kmrepro.ps1` iterate loop) the rig posts cmd 20, sleeps **150 ms**, then runs
`Invoke-AllProbes`, which takes ~4.7 s of wall clock (shift ~2.1 s + deadkey
~1.3 s + ralt ~1.3 s). Measured iteration cadence was ~5.5 s. **The typing
therefore straddles the whole 5 s freeze of the hook-owning thread, 15 times,
and output stayed byte-exact with no phantom modifier.**

---

## Rig fix applied (`kmrepro.ps1`, backup at `kmrepro.ps1.bak`)

The `AutoTest` entry gate hard-failed with:

```
keyboard : HKL=0x4090409 langid=0x0409 keymanActive=False
[FAIL] No Keyman keyboard is active in 'notepad'.
```

**This was a false negative in the rig, and it is gotcha #3 biting the rig
itself.** The gate was built on `Test-KeymanKeyboardActive`, i.e.
`GetKeyboardLayout()` — the exact oracle the handoff says never to trust. With the
Keyman keyboard genuinely selected, the HKL still reported `0x0409` while typing
`;e` correctly produced **U+0259**.

The gate was demoted from `break` to `[WARN]`. Nothing is lost: `AutoTest` already
has an authoritative **behavioural** sanity gate a few lines later, which requires
the Keyman-only codepoints to actually appear and `break`s if they do not. That
gate passed on all three scenarios (`[OK] Keyman confirmed engaged`). The rig is
now strictly harder to fool than before.

Recommend the same fix in `kmflex.ps1` if it gates the same way.

## FLEx track — COMPLETE (clipboard oracle, live Ngoreme DB)

Test entry **Ngq**, index **698/2234**, confirmed on screen before any write.
Coordinates re-verified against handoff gotcha #10 and still correct: Ngq Citation
Form `(1000, 325)`, Eng Note `(1000, 490)`. A dry `kmflex.ps1 Click` landed in the
Citation Form and FLEx auto-selected the Keyman keyboard.

| scenario | iterations | failures | phantom modifiers | control |
|---|---|---|---|---|
| Switch Clean | 2 | **0** | **0** | 0 |
| Switch Ghost | 5 | **0** | **0** | 0 |
| Switch Freeze | 5 | **0** | **0** | 0 |

Every iteration reported `ok (schwa/eng before and after switch, Eng field
literal)` — i.e. all five oracle checks passed each time: `ə` and `ŋ` in the Ngq
field before the switch, `;e` literal in the Eng field, and `ə` and `ŋ` again in
the Ngq field after switching back. `mods down: none` after every scenario.

### Post-run safety verification

The entry is **unchanged**: Citation Form still `Ngq`, Note (Eng/Kis) empty, all
NGQ custom fields empty, still 698/2234. Only `Date Modified` advanced, which is
expected since `Read-AndClear` writes and deletes. No residue, no stray characters,
no `Ctrl+Z` used at any point.

### HKL oracle behaves differently in FLEx than in Notepad

Worth recording: in FLEx the HKL **does** track the profile correctly —
`HKL=0x04092000 langid=0x2000 keyboard=KEYMAN` as soon as the Citation Form is
focused. In Notepad, with the same Keyman keyboard genuinely active, it reported
`0x0409`. So gotcha #3 is not "the HKL is always wrong", it is "the HKL is
unreliable and app-dependent" — which is a stronger reason to keep every gate
behavioural.

### Caveat on the FLEx Freeze scenario — partial overlap only

Each `Switch` iteration runs ~19 s (five clipboard round-trips), but the freeze is
a single 5 s block posted at the top of the iteration. So the freeze covers
**steps 1-2 only** — the before-switch deadkey and the before-switch RAlt probe.
The after-switch probes (steps 4-5) execute *after* keyman.exe has resumed.

This still exercises the critical window: step 2 holds **RAlt down and releases it
while keyman.exe's hook-owning thread is blocked**, which is precisely the
modifier-KEYUP-lost-during-hook-swap scenario the hypothesis requires. But a
longer freeze, or a freeze re-posted before each step, would cover the
switch-back path too. **That is the obvious next refinement if this line is
pursued.**

## Interpretation — read this before quoting the numbers

The treatment build is positively identified and the watchdog path is live
(T2 proves the hook-owning thread can be stalled on demand). **The hypothesis is
still not confirmed, and it is now weaker than it was.** The `Ghost` and `Freeze`
scenarios are the ones designed to force the watchdog false-positive, and they
produced 30 consecutive clean iterations on the build that contains the watchdog.

**The load-bearing FLEx test ran and stayed clean**, including the
keyboard-switch path in FieldWorks — the app and the vector the whole hypothesis
is built around. That is a substantially stronger negative than the Notepad
result alone.

What this does *not* establish:

- **No ETW capture was taken** (needs an elevated shell), so there is no direct
  evidence about whether the watchdog fired at all during these runs.
  `Attempting to reinstall hook because watchdog threshold exceeded` remains
  unobserved either way. A clean result with no trace cannot distinguish
  "watchdog never fired" from "watchdog fired and was harmless" — and those two
  have very different implications for the upstream fix. **This is now the single
  highest-value remaining measurement.**
- The synthetic `Ghost`/`Freeze` triggers may not reproduce the real field
  timing. The mechanism needs an app to stall >1 s and then drain a backlogged
  `WM_KEYDOWN` after the user stopped typing. The rig approximates that with a
  posted `WM_KEYDOWN` and a forced 5 s hang; genuine FLEx-under-load timing
  (large DB operations, parser running, Send/Receive) may differ. Note the status
  bar read `Queue: (-/-/-) No Parser Loaded` throughout — FLEx was **idle**, not
  under the load users report.
- The FLEx `Freeze` overlap was partial (see caveat above).
- Only one machine, one keyboard (`sil_cameroon_qwerty`), default
  `LowLevelHooksTimeout`. The handoff's sharper variant — `Arm -HookTimeout 200`
  then sign out and back in — was **not** run, and is designed to raise the hit
  rate.

Per handoff §13: do **not** describe this as a confirmed root cause. It is now
also fair to state the converse plainly — **the documented reproduction protocol
does not reproduce the failure on 18.0.249 under idle conditions.** The watchdog
remains a plausible mechanism on code reading, but this run supplies no
supporting evidence for it, and the burden has shifted toward finding what
additional condition (load, timeout pressure, upgrade-without-reboot state)
users have that this rig does not.

### Suggested next steps, in value order

1. **Elevated ETW capture** (`TraceStart` / `TraceStop`) during a repeat of these
   same scenarios. Answers open question 1 (does the watchdog ever fire?) and
   open question 2 (is a phantom modifier in Windows' key state or only Keyman's
   cache). Without this, further black-box iterations have low yield.
2. **`Arm -HookTimeout 200`, sign out and back in, re-run.** The handoff's own
   sharper variant, not yet tried.
3. **Load FLEx up** — parser running, a large entry, Send/Receive — before the
   `Switch` scenarios, so the message pump actually stalls the way the hypothesis
   requires.
4. **Extend the freeze** to cover a whole `Switch` iteration, or re-post cmd 20
   before each step, so the switch-back path is also covered.
5. **Test the in-place-upgrade state directly** (secondary suspect §4): upgrade
   with `REBOOT=ReallySuppress` and test *before* rebooting, with a stale
   `keyman32.dll` mapped into a long-running FLEx. This run was on an
   already-settled install and would not have caught a version-skew bug.

---

# ADDENDUM — targeted modifier-wedge testing (`kmwedge.ps1`)

Added after the user confirmed the field pattern: **"slower machines and
ginormous databases seem to have more issues."** That is the load condition the
runs above lacked (FLEx was idle, `No Parser Loaded`).

## Why a new instrument was needed

`kmrepro.ps1`'s `Ghost` scenario *does* provoke the watchdog breach, but it fires
the hook reinstall while **no modifier is held**, so the swap is harmless — which
is why 20 iterations came back clean. The documented failure needs the reinstall
to land **between a modifier's KEYDOWN and its KEYUP**, so that the KEYUP is seen
by no Keyman LL hook, no `WM_KEYMAN_MODIFIER_EVENT` is posted, and the
`m_ModifierKeyboardState[]` byte stays `0x80`.

`kmwedge.ps1` holds a modifier down, idles past the 1000 ms threshold, posts the
ghost key to force the reinstall, and releases the modifier **into** that window,
sweeping the release offset (0–400 ms) because the race point is unknown.
Switches: `-NoGhost` (control — never provoke the watchdog), `-DismissMenu`,
`-AlsoFreeze` (post cmd 20), `-LoadThreads N` (slow-machine emulation).

## FALSE POSITIVE FIRST — recorded so nobody re-walks it

The first RAlt sweep reported **9/18 failures, all NO-OUTPUT** — superficially a
dramatic reproduction of "keyboard active but no text output". **It was a harness
artifact.** Three things gave it away and then confirmed it:

1. Failures landed on **every odd iteration** (1,3,5…17) and were **completely
   independent of the release offset**. A genuine race is neither periodic nor
   timing-invariant.
2. `-NoGhost` control (watchdog never provoked): **still 5/10 failures**, same
   alternating pattern. Nothing to do with the watchdog.
3. `-NoGhost -DismissMenu` (Escape after release): **0/10 failures.**

Cause: **a bare Alt press+release is the standard Windows menu-activation
gesture.** Notepad's menu bar took focus and ate the subsequent keystrokes.
Confirmed by the user: *"alt is opening the menu (as it should)."*

This artifact mimics the reported bug almost perfectly — no text output, keyboard
still "active", modifier apparently stuck. **Any future rig that holds a bare Alt
must control for it**, or it will manufacture reproductions on demand. Under heavy
CPU load the artifact got worse (10/10) because the Escape taps were themselves
starved, so `-DismissMenu` is not a reliable defence at load. **Prefer LShift, or
make Alt part of a real chord so it is never pressed alone.**

## Clean negative results (RAlt, menu artifact controlled out)

| configuration | iterations | failures | note |
|---|---|---|---|
| RAlt, ghost, `-DismissMenu` | 27 | 1 | the 1 was iteration 1 (warm-up, pre-settle) |
| RAlt, ghost, `-DismissMenu`, 8 load threads | 27 | **0** | 8 hogs on 16 cores is weak pressure |
| **LShift, ghost, no load** | 27 | **0** | no menu confound at all |

## POSITIVE RESULT — a real, physical stuck modifier

```
kmwedge.ps1 -Modifier LShift -AlsoFreeze -LoadThreads 32 -Reps 2 -MinDelayMs 0 -MaxDelayMs 400 -StepMs 100
```

| metric | value |
|---|---|
| iterations | 10 |
| failures | **10 / 10** |
| no-output | 0 |
| **phantom modifiers** | **10** |
| **recovered by modifier-tap** | **10 / 10** |
| final mods held | none |

Every iteration, at every release offset 0–400 ms:

```
FAIL [PHYSICAL-PHANTOM:LShift]
  expected='əŋ' (U+0259 U+014B)
  got     ='əŊ' (U+0259 U+014A)
  GetAsyncKeyState says: LShift
  RECOVERY: modifier-tap workaround RESTORED output
```

Why this one is credible where the RAlt failures were not:

- **Shift does not open menus**, so the artifact above cannot explain it.
- The signature is **positive, not absent**: output changed to the capital form
  `U+014A` rather than vanishing. A menu-eaten keystroke produces nothing; this
  produced *the wrong thing*, which requires a modifier to actually be applied.
- **`GetAsyncKeyState` reports LShift down** — the phantom is in **Windows' own
  key state**, not merely Keyman's cache. Modifiers were verified clear before
  each iteration.
- It reproduced 10/10 across the whole offset sweep, i.e. it is not a narrow race.

### This answers two of the handoff's open questions

- **Open question 2 ("is the phantom modifier in Windows' own key state, or only
  in Keyman's cache?") — ANSWERED: Windows' own key state.** `GetAsyncKeyState`
  sees it. The handoff called this "the single most valuable measurement to
  obtain… it tells the Keyman team which side of the fence to fix." Obtained
  without ETW.
- **Open question 3 ("does the modifier-tap workaround recover a wedged
  session?") — ANSWERED: yes, 10/10.** Tapping each of the six modifiers once
  fully restored correct output with no Keyman restart. **This is a shippable
  field workaround.**

### THE CONTROL DID RUN — AND IT RULES THE WATCHDOG OUT

The `-NoGhost` control was launched before the session was interrupted and **ran
to completion** at 18:27–18:30. Its results are in
`%TEMP%\kmrepro\wedge-18_0_249_0-LShift.txt` from line 125.

| run | ghost key | `-AlsoFreeze` | load | iters | failures | phantom |
|---|---|---|---|---|---|---|
| 18:21 | yes | no | 0 | 27 | **0** | 0 |
| 18:23 | yes | **yes** | **32** | 10 | **10** | 10 |
| **18:27** | **NO** | **yes** | **32** | 10 | **10** | **10** |

**The ghost key is not required.** With it never posted the watchdog is never
provoked, yet the stuck Shift reproduces 10/10 with an identical signature
(`əŊ`, `GetAsyncKeyState says: LShift`, recovered by modifier-tap). Combined
across both runs that is **20/20 with the same recipe**.

So the trigger is **NOT the LowLevelHookWatchDog**, and this is a different bug
from the one this investigation set out to test. The `-AlsoFreeze` + heavy-load
pair is what does it.

### STILL CONFOUNDED — freeze vs load

Two variables remain entangled: cmd 20 (blocking keyman.exe's main thread) and
32 CPU hogs. The clean 18:21 run had **neither**. These two runs decide it and
were **blocked by a tooling restriction, not attempted**:

```powershell
# A. Field-relevant: heavy load ONLY, no debug command at all.
#    If this fails, the trigger needs no Keyman debug command - ordinary CPU
#    starvation is enough, which would explain the field reports directly.
powershell -ExecutionPolicy Bypass -File .\kmwedge.ps1 -Modifier LShift -NoGhost -LoadThreads 32 -Reps 2 -MinDelayMs 0 -MaxDelayMs 400 -StepMs 100

# B. Freeze ONLY, no load. If this fails, blocking the hook-owning thread is
#    sufficient on its own and the minimal repro is very small.
powershell -ExecutionPolicy Bypass -File .\kmwedge.ps1 -Modifier LShift -NoGhost -AlsoFreeze -Reps 2 -MinDelayMs 0 -MaxDelayMs 400 -StepMs 100
```

### AND THE ONE THAT PROVES IT IS KEYMAN AT ALL

Nothing so far demonstrates Keyman is implicated rather than plain Windows
input-queue behaviour under starvation. The field reports say Microsoft keyboards
are unaffected, so this is directly testable and is the **highest-value single
run**:

**Switch Notepad to the plain US keyboard (no Keyman) and repeat the failing
recipe.** `kmwedge.ps1` cannot do it as written — its behavioural gate requires
`ə`/`ŋ` and will refuse — so either add a `-SkipEngagementGate` switch and
compare the shift-case of ASCII output, or hold LShift, block/starve, release,
and read `GetAsyncKeyState(VK_LSHIFT)` directly with no typing at all. The latter
is the cleanest possible discriminator:

- Shift sticks **only with Keyman active** -> Keyman's LL hook is losing the
  KEYUP. A real Keyman bug, in `serialkeyeventserver.cpp` /
  `k32_lowlevelkeyboardhook.cpp` territory.
- Shift sticks **either way** -> this is Windows dropping input for a starved
  low-level hook, and Keyman is at most an aggravating factor (it installs the
  hook that gets evicted).

**A plausible reading that does NOT need the watchdog:** cmd 20 blocks
keyman.exe's main thread, which owns `WH_KEYBOARD_LL`. The LL hook swallows every
keystroke and re-injects it. If the Shift KEYUP arrives while that thread is
blocked and Windows evicts the slow hook, the KEYUP is dropped and Shift stays
down in Windows' state. **On a slow machine with a huge FLEx database, ordinary
CPU starvation could stall that thread the same way cmd 20 does — no watchdog
required.** That would match the field observation directly, and it is a
*different* bug from the one this investigation set out to test.

Note also that `-AlsoFreeze` uses `KMC_WATCHDOG_FAKEFREEZE`, a **debug-only**
command. A reproduction that depends on it is not by itself a field repro. The
load-only run is therefore the more field-relevant test, and it has not been done
at sufficient load.

## Status of the overall hypothesis

**The watchdog hypothesis is now effectively refuted as the cause of what we can
reproduce.** It was not reproduced in 45 clean iterations plus 64 `kmwedge`
iterations, and the one thing that *does* reproduce reproduces just as well with
the watchdog never provoked.

What we have instead is **a separate, reliably reproducible bug**: a
physically-stuck Shift (visible to `GetAsyncKeyState`, i.e. in Windows' own key
state) when a modifier is released while keyman.exe's hook-owning main thread is
blocked and the machine is under heavy CPU load. 20/20 across two runs, at every
release offset 0–400 ms, with a working recovery (tap each modifier once).

This is a much better match for the reported field pattern — *"slower machines
and ginormous databases seem to have more issues"* — than the watchdog ever was,
because CPU starvation of the hook-owning thread is exactly what a slow machine
running a huge FLEx database produces, and it requires no 18.0.245 code change at
all. **That also means it is probably not a regression**, which would fit a
symptom that has resisted diagnosis for years.

Two caveats before anyone acts on that: the freeze-vs-load isolation is not done,
and it is not yet shown that Keyman is required at all (see the two sections
above). Both are cheap to settle.

## Files

| file | state |
|---|---|
| `kmwedge.ps1` | new; parse-checked; `-NoGhost`/`-DismissMenu`/`-AlsoFreeze`/`-LoadThreads` |
| `kmrepro.ps1` | HKL gate demoted to `[WARN]`; backup `kmrepro.ps1.bak` |
| `kmflex.ps1` | unmodified |
| `%TEMP%\kmrepro\wedge-18_0_249_0-*.txt` | raw kmwedge logs |

**FLEx was NOT used for any `kmwedge` run** — Notepad only. `kmwedge.ps1` uses
Ctrl+A to clear the target, which must never be sent to FieldWorks (gotcha #4).
The Ngq entry was last verified unchanged after the `kmflex` runs.


---

# ADDENDUM 2 — isolation completed, and an important reframing

## The trigger, isolated by elimination (LShift, 18.0.249.0)

| ghost key (watchdog) | `-AlsoFreeze` | CPU load | iters | failures |
|---|---|---|---|---|
| yes | no | 0 | 27 | **0** |
| no | no | **32** | 10 | **0** |
| **no** | **yes** | 0 | 10 | **10** |
| no | yes | 32 | 10 | **10** |
| yes | yes | 32 | 10 | **10** |

**Necessary and sufficient: blocking keyman.exe's main thread.** The watchdog is
not involved (ghost key never posted in three of these). Heavy CPU load alone does
nothing. Load is not even required — freeze alone is 10/10.

## But the minimal repro is NOT as small as it looked

`kmstick.ps1` was written to strip the recipe to its core: hold LShift, block
keyman.exe, release, read `GetAsyncKeyState`. **It does not reproduce.**

| kmstick configuration | layout | iters | stuck |
|---|---|---|---|
| no typing | US-MS 0x0409 (VS Code) | 6 | **0** |
| no typing | Keyman 0x046A (Notepad) | 6 | **0** |
| `-TypeAfter` (one 'a') | Keyman 0x046A (Notepad) | 6 | **0** |

So releasing a modifier during the block is **not sufficient**. What kmwedge does
in addition: a `Ctrl+A`/`Delete` clear, a `;e` **multi-key deadkey rule**, and an
**RAlt+N chord** — i.e. Keyman actually processing real keystrokes, including
modifier chords, across the blocked window. The user's own observation matches:
*"whatever you're doing to get əŊ seems to trigger it."* The `əŊ` string IS the
kmwedge probe output with Shift wrongly applied (U+014A capital eng instead of
U+014B).

**Correction to Addendum 1:** describing the trigger as "release a modifier while
the thread is blocked" was an over-minimisation. Keyman must also be processing
keystrokes through that window.

## REFRAMING — this may be transient, not a wedged cache

Three separate live captures were taken **between** runs, while the user reported
seeing the stuck Shift:

- `GetAsyncKeyState` / `GetKeyState`: **all modifiers clear**, CapsLock off.
- Behavioural: typed lowercase `abc` into Notepad -> got `abc` (U+0061 U+0062
  U+0063). Not uppercase.

Yet **inside** a failing kmwedge iteration the same measurement reported
`GetAsyncKeyState says: LShift` and output `əŊ`. Both cannot be permanent.

The reading that fits every observation: while keyman.exe's main thread is blocked
for ~5 s, the LShift KEYUP is **delayed rather than lost**. For those seconds
Windows genuinely reports Shift down and Keyman applies it, so in-loop detection
fires and the user sees stuck-Shift behaviour. When the thread resumes, the KEYUP
is processed and everything clears by itself.

That also means the **"modifier-tap workaround RESTORED output" result is
confounded**: the taps take ~1 s, by which time the freeze may simply have ended.
Addendum 1's claim that open question 3 is answered should be treated as
UNPROVEN. Note the recovery rate was 10/10 with load but only **3/10** without —
consistent with a timing coincidence, not a real fix.

### Why this matters for attribution

The **field** bug is persistent: users must restart Keyman or reboot. What is
reproduced here is a **transient ~5 s stall** that self-heals. Unless a slow
machine can stall that thread indefinitely, **this is probably a related but
distinct phenomenon**, and it should not be reported as the field bug.

Open question 2 (Windows' key state vs Keyman's cache) is therefore **still
open**. The in-loop `GetAsyncKeyState` hit says Windows' state — but only while
the thread is blocked, which is expected behaviour for a delayed KEYUP and does
not require a corrupted `m_ModifierKeyboardState[]` at all.

## Next steps

1. **Distinguish delayed from lost.** Sample `GetAsyncKeyState(VK_LSHIFT)` on a
   tight timer (every 100 ms) from before the release until 10 s after, through
   one freeze. A clean decay at ~5 s = delayed KEYUP, self-healing, not the field
   bug. Still down at 10 s = genuinely lost, and then it IS the field bug.
   **This single measurement settles the whole question and nothing else should
   be reported before it.**
2. Run the same recipe with `-SkipEngagementGate` on the **plain US layout**
   (switch added to `kmwedge.ps1`, untested). Sticks on US too -> not Keyman.
3. Find a *non-debug* way to stall keyman.exe's main thread. Everything here used
   `KMC_WATCHDOG_FAKEFREEZE`, a debug-only command, so none of it is yet a field
   repro. 32 CPU hogs on 16 cores did not do it.
4. Restore Notepad to the Cameroon keyboard before any comparison run — it drifted
   to Yoruba (0x046A) mid-session, so the last kmstick runs used a different
   keyboard from the kmwedge runs.

## Files added

| file | state |
|---|---|
| `kmstick.ps1` | new, parse-checked. Minimal no-typing probe; `-TargetProcess`, `-TypeAfter`, `-NoFreeze`. Does NOT reproduce - kept as the negative control that bounds the minimal recipe. |
| `kmwedge.ps1` | `-SkipEngagementGate` added (declared, not yet wired into the gate - finish that before using it) |


---

# ADDENDUM 3 — TRIGGER FOUND, AND A HARNESS BUG THAT INVALIDATED EARLIER RESULTS

## First: a bug in my own detector that must be understood before reading anything above

`kmhunt.ps1` reported a state as CLEAN while printing its codepoints as
`U+0259 U+014A` and `mods=LShift` — a contradiction that exposed the cause:

**PowerShell's `-eq`, `-ne`, `-match` and `-notmatch` are CASE-INSENSITIVE, and
U+014A / U+014B are the uppercase/lowercase ENG pair.** So the wedged result
`əŊ` compares EQUAL to the clean result `əŋ`.

Consequences:

- `kmwedge.ps1` compared `$got -ne $learned`. **Case-blind.** It therefore could
  never detect the wedge from the text at all — every detection it made came from
  `GetAsyncKeyState`, which only reports true while Shift is *still physically
  down*. That is timing-dependent, which is exactly why results looked
  **bimodal** (10/10 when the freeze was still active at measurement time, 0/N
  when it had ended). **The bimodality was a measurement artifact, not evidence
  of a persistent latent state.** Addendum 2's "persistent wedged state" reasoning
  is therefore wrong, and the user's "maybe something previous triggered it"
  hypothesis - reasonable given that data - is not needed.
- Every "0 failures" freeze-only run in Addendum 2 is a **false negative**.

Fixed to `-ceq` / `-cne` / `-cnotmatch` in both `kmhunt.ps1` and `kmwedge.ps1`.
This is the same family as handoff gotcha #2 (PowerShell case-insensitivity) and
belongs in that list: **any oracle comparing Keyman output must be
case-sensitive, because the whole symptom IS a case change.**

Also fixed: `powershell -File script.ps1 -Only A,B` passes `"A,B"` as one string,
not an array, so the candidate filter silently matched nothing and reported "no
candidate wedged Keyman" after running zero candidates.

## The trigger, with a clean A/B control

`kmhunt.ps1 -Only A,B -Repeat 3` — probe, one action, probe. Behavioural oracle
(`;e` then RAlt+N), case-sensitive.

| candidate | modifier held | keyman.exe blocked? | result |
|---|---|---|---|
| **A** | LShift 1.5 s, then released | **no** | **clean 3/3** |
| **B** | LShift 1.5 s, released *into* the block | **yes** | ***WEDGED 3/3*** |

Wedged signature: output `əŊ` (`U+0259 U+014A`), `mods=LShift`.

A and B differ in **exactly one thing**. So:

> **TRIGGER: releasing a modifier while keyman.exe's main thread — the thread
> that owns `WH_KEYBOARD_LL` — is blocked.**

Deterministic, 3/3, no CPU load required, no ghost key, **no watchdog**.
Candidate E (release, re-press, release, all inside the block) also wedges 3/3.

Ruled out as triggers by the same method:
- **A** bare modifier hold + release with no block — clean.
- **D** rapid tap of all six modifiers (the old "recovery" sweep) — clean, so the
  recovery routine is not itself causing what it appears to fix.
- Heavy CPU load alone — clean (Addendum 2, and that result does not depend on
  the case bug since it was 0 by both oracles).

## Recovery

`kmhunt` recovered every wedge with an **explicit KEYUP sweep alone** — one bare
`keybd_event(vk, KEYUP)` per modifier, no press needed. Full press+release taps
were never required. The user also observed that simply clicking and typing
normally cleared it, which is consistent: any real physical modifier edge
resyncs the state.

This supersedes Addendum 1's "modifier-tap workaround" claim, which was
confounded (10/10 with load vs 3/10 without, i.e. it was partly the freeze
expiring). The corrected finding is stronger and simpler: **a KEYUP for each
modifier clears it.**

## What is still NOT established

1. **The block is delivered with `KMC_WATCHDOG_FAKEFREEZE` (wParam 20), a
   debug-only command.** This is a mechanism demonstration, not yet a field
   repro. The field equivalent is whatever else stalls that thread for ~1 s.
   32 CPU hogs on 16 cores did **not** do it (and crashed the host PowerShell
   with `OutOfMemoryException` — 32 `Start-Job` runspaces is memory pressure, not
   just CPU; the load emulator is now capped at 6).
2. **Whether Keyman is required at all.** The same recipe has not been run on the
   plain US layout. `-SkipEngagementGate` was added to `kmwedge.ps1` for exactly
   this and is **declared but not wired into the gate** — finish that first.
3. **Persistence.** Every wedge here was cleared by the next KEYUP sweep, so
   whether it can persist the way the field reports describe (until Keyman
   restart) is untested. A time-resolved sample showed the KEYUP being processed
   at t=323 ms with no block in play, so the mechanism for a *permanent* wedge is
   still unexplained.
4. The `-DismissMenu` mitigation for bare-Alt menu activation is unreliable under
   load (its Escape taps get starved). Prefer LShift for any modifier test.

## Why this is a better fit for the field reports than the watchdog

The trigger needs only that keyman.exe's main thread be unable to run while a
modifier is released. On a slow machine with a very large FLEx database, that
thread being starved for ~1 s is ordinary. It requires **no 18.0.245 code
change**, which is consistent with a symptom that has resisted diagnosis for
years rather than a fresh regression — and with the user's report that slower
machines and larger databases see it more.

The watchdog hypothesis this investigation was built to test is **not supported**:
the ghost key was absent from every reproducing run.

## Files

| file | state |
|---|---|
| `kmhunt.ps1` | new. Probe/action/probe trigger hunt, case-sensitive oracle, 8 candidates, `-Only`, `-Repeat`. **This is the instrument that found it.** |
| `kmwedge.ps1` | case comparison fixed; `-SkipEngagementGate` declared but NOT wired |
| `kmstick.ps1` | negative control - the no-typing minimal probe does not reproduce |
| `%TEMP%\kmrepro\hunt.txt` | hunt log |

## Reproduce it

```powershell
# Needs the Cameroon Keyman keyboard active in Notepad (';e' -> U+0259).
cd D:\Github\_Projects\_KM\kmrepro
powershell -ExecutionPolicy Bypass -File .\kmhunt.ps1 -Only A,B -Repeat 3
# A stays clean; B wedges every time.
```
