# #8064 — Ross's field evidence, and what this repo adds toward closing it

Upstream: **[keymanapp/keyman#8064][i8064]** — *"bug(windows): modifier key
occasionally is 'stuck on'"*. Opened by **rc-swag (Ross)** 2023-01-23, still open,
milestone 20.0. **File evidence there. Do not open a new issue.**

This folder mirrors Ross's own notes so the crosswalk below can be checked against
a source rather than against a summary of one.

| file | provenance |
|---|---|
| `ross-observations-2025-11-27.txt` | `Observations_so_far.txt` from [`RC_logs_2.zip`][rc2], attached to #8064 |
| `ross-system3-info.txt` | scenario note — Edge, PR text, focus to Excel/VSCode. Log line 477512 |
| `ross-system8-info.txt` | scenario note — Excel save, stuck Shift on the number row |

**Not mirrored, and owed:** `test3_lowlevel.xlsx` and `RC_Logs_1.zip`, also on the
issue. The xlsx is the per-event timeline. Until it is cross-checked against
`../logs/` — `../TEST-PLAN.md` **T13** — the "same event shape" claim
below is structural, not event-for-event.

---

## 1. Ross reached most of this independently, from field logs

He has three affected systems, real user scenarios, and Keyman's own logs. What he
does not have is a deterministic trigger or causal attribution. **This repo is the
other half of his work, not a competing account of it.**

| Ross, verbatim from the field | this repo | status of the pairing |
|---|---|---|
| *"`m_ModifierKeyboardState=[LS:80 … RS:80 …]` — There is never a return to RS:0. **Why**"* | Cache A is seeded from the OS exactly once (`serialkeyeventserver.cpp:251`) and never reconciled; its only writer is `:581`, driven only by the events the LL hook posts — `WM_KEYMAN_MODIFIER_EVENT` **and** `WM_KEYMAN_KEY_EVENT`, via `UpdateLocalModifierState`'s three call sites at `:508`/`:514`/`:535` | **his question, answered.** `../MODIFIERS.md` §1, proof step 2 |
| *"the last message of this type is a **pressed and not released** … extra: `4b4d0000` which means injected by keyman. There is no message after this to say the key is released"* | `keybd_shift_reset()` emits a KEYDOWN for every modifier the cache believes is held, with **no matching KEYUP** | **his observation, reproduced at the wire.** `kmaltgr.ps1` captured `DN LSHIFT scan=0xFF` unmatched during a live trial — `../MODIFIERS.md` §2a-wire, proof step 4 |
| *"746 `Key pressed` and only 221 `Key released`"* | a dropped modifier KEYUP is the seed; the hook is bypassed when its owning thread stalls past `LowLevelHooksTimeout` | **the same defect from opposite ends** — he counted the deficit, this repo caused one on demand. Proof step 3 |
| *"pressing the left shift key would not release the stuck shift key but pressing the **right** Shift key did"* — independently on **System 8 and System 1** | a latched modifier is cleared **only by the exact matching KEYUP**: not by typing, not by tapping the other side | **mutual confirmation, and the most valuable single pairing.** Measured deliberately in `../MODIFIERS.md` §3b; he saw it twice in the field without looking for it |
| quotes the `keybd_shift.cpp` comment on Keyman stuffing `scan = 0xFF`, and why Right Shift is the exception | same function. RShift is emitted as `VK_SHIFT` + `SCANCODE_RSHIFT`; RCtrl as `VK_CONTROL` + `KEYEVENTF_EXTENDEDKEY` | same code, proof step 5. `../TEST-PLAN.md` T-P3/T-P4 assert exactly this |
| *"489136 flags of `11` indicate it was injected but the extra: is 0 so not by Keyman"* | `kmaltgr.ps1` decodes both Keyman markers — `scan 0xFF` = synthesized, `extraInfo 0x4B4D0000` = serializer replay (`keyman64.h:132-134`) | his read is right. An injected event with `scan != 0xFF` **and** `extra == 0` is a third party, and is the only unexplained event in his trace |

Note that the latched key on System 8 was **Right** Shift, and that he had a Right
Shift available to press. §2a is about what that availability concealed.

---

## 2. The two things he could not see from a log

Neither is a disagreement with him, and neither is closed by the repro. The
deterministic trigger is what makes the defect *demonstrable*; it is not what he
was conceptually missing. He had the seed (a lost KEYUP), the cache (*"never a
return to RS:0"*), the marker decode (`4b4d0000`), the press/release asymmetry
(746/221), the side-specificity, and the right source file — most of the defect
chain, from field logs alone.

What a log could not give him was **scope** and **the gate**.

### 2a. Scope — his evidence base can only ever contain Shift

All three of his systems are **Shift**. System 3 is a case change (`THEN` → `HEN`).
System 8 is the shifted number row — typing `2025` into Excel and getting `@)@%`.
System 1 is Shift. He accordingly describes a stuck-*Shift* bug.

That is not a coincidence in his sample. It is a **filter**, and
[`../MODIFIERS.md` §2b][m2b] is where it becomes visible:

> `RCTRL p1` and `p2` both read `held=RCTRL` while the text probe returned `jkq` —
> lowercase, correct, indistinguishable from clean. […] Every `LALT` and `RALT`
> trial returned `<empty>`.

**Shift is the only one of the six latchable keys whose latch produces output a
user can see, describe and report.** A latched Ctrl produces *correct text*. A
latched Alt produces *nothing at all*. So a Ctrl or Alt latch either never becomes
a bug report, or becomes a differently-shaped one — "no output", "keyboard dead",
"Alt key continuously pressed". [Community 9977][c9977] is that last shape, filed
as its own problem; the swallowed-keys behaviour in [`../MODIFIERS.md` §2b][m2b]
makes it a strong candidate for this same defect, though nobody has diagnosed it.
His sample is therefore structurally incapable of growing toward the general shape,
however many reports arrive — the Ctrl and Alt cases are triaged away from him
before they reach him.

**The cost of that is concrete: it turns his best finding into a curiosity.** He
reports *"pressing the left shift key would not release the stuck shift key but
pressing the right Shift key did"* as an oddity about Shift, twice, on two
independent systems. It is the **rule** — a latch is cleared only by the exact
matching KEYUP — and the rule has a case with no user recovery at all: **Right Ctrl
on hardware that has no Right Ctrl key.** He had the rule in his hands and could
only read it as a quirk, because a Shift-only sample contains nothing but keys that
have two physical instances. That worst case is not hypothetical: this dev machine
has no physical Right Ctrl (the user's report, corroborated at the wire), so `../MODIFIERS.md` §3b's *"the
workaround is unavailable to the user"* is a direct observation here rather than an
extrapolation.

This is the single most useful thing to hand him, because it re-scopes his own
evidence rather than replacing it.

### 2b. The gate — "no Keyman keyboard was active" does not exclude Keyman

The modifier post at `k32_lowlevelkeyboardhook.cpp:198` sits **35 lines before**
the `!isKeymanKeyboardActive` pass-through at `:233`, and does not consult it. So
the cache is charged on *every* modifier keystroke on the machine, whichever
keyboard is active, while it is only *consumed* when a Keyman keyboard is active.
Measured **3/3** — charge while a Microsoft layout is active, fire on switching
back ([`../TRIGGER.md` §3][tr3], `kmproof.ps1 -ChargeTest`).

Now look at where his two scenarios happen: **Microsoft Edge, writing a PR** and
**Excel, saving a document.** Ordinary English work in non-Keyman applications.
Under *"no Keyman keyboard was active, so Keyman is uninvolved"* both read as
confounds — and that is exactly the reasoning that kept getting applied to this
bug for years.

**In fairness to Ross: he filed them as evidence, so he was not dismissing them.**
The gap is that he had no way to *defend* them. §3's charge-test row is what makes
those two scenarios on-mechanism rather than merely suspicious, and it is worth
leading with for that reason alone.

### 2c. Two puzzles in his own notes that source answers directly

Both are questions he raises and leaves open. Neither needs an experiment.

| his note | the answer |
|---|---|
| *"before each letter. So either I did that or it is a clue."* — on the release/re-press he sees around every letter | **It is the code, unconditionally.** `PrepareInjectedInput()` wraps *every* injected batch in `keybd_shift(…FALSE…)` / `keybd_shift(…TRUE…)` (`serialkeyeventserver.cpp:384` → `keybd_shift.cpp:161`). That is the emitter. Not his keystrokes |
| *"I am not sure how I would have managed a backspace and right shift at the same time."* | **They do not have to be simultaneous.** The latch happens once, when the KEYUP is lost; *any* later injected batch re-emits the phantom. Backspace is a frequent batch-forcer, not a co-cause |

That second one is what unblocks his framing of the three co-occurring events.

### 2d. His three co-occurring events, re-read

*"A modifier (shift) has been pressed / A backspace has been pressed /
**Application focus has changed**."*

Two are consequences; one is the lead this repo actually needs.

| his event | role in the mechanism |
|---|---|
| **modifier pressed** | necessary — it is the modifier whose KEYUP is then lost |
| **backspace pressed** | **the reveal, not a cause** — per 2c above. His own note *"for backspace the event server does release/set of the modifier key"* is exactly this code path |
| **application focus changed** | **the lead.** A focus change is a plausible source of the UI-thread stall this repo could only induce artificially. His trace shows `WM_KEYUP` for backspace and then `WM_KILLFOCUS`, and his note reads *"the focus for the current, which has the shift press, is removed while the key is still pressed"* |

That third row is [`../TODO.md`][todo] **I3** — *what actually stalls keyman.exe's
UI thread in the field?* — this repo's single largest open gap. **His field
observation is the best available answer to it, and this repo's stimulus is the
best available way to make his scenario reproducible on demand.** That is the
collaboration, stated plainly.

### Two things to ask him

1. **Does a CapsLock toggle really clear a latched Shift?** His System 3 note says
   *"it appears the caps lock is toggled to resolve the shift being stuck."* This
   repo measured the two caches as **separate** ([`../MODIFIERS.md`][m2b] §1) and
   measured CapsLock as **0/2 latched** under the identical stimulus (§2b). If a
   CapsLock toggle genuinely clears a latched Shift, that is a Cache A ↔ Cache B
   interaction this repo has no evidence for, and it would change where the fix
   belongs. His wording is ambiguous about whether he observed it or did it.
2. **What emitted the injected event at line 489136**, `flags=0x11`, `extra=0`? Not
   Keyman, by Keyman's own markers — and it is the only unexplained event in his
   trace.

---

## 3. What this repo adds

All measured on 18.0.249.0 / Windows 11 Pro 26200, on **one machine** — say that
before anyone else does.

| addition | result | where |
|---|---|---|
| **A deterministic trigger.** Stall the hook-owning thread, release the modifier *during* the stall | 10/10, and 0/10 without the stall | `../TRIGGER.md` §2, `../TEST-PLAN.md` §1 |
| **Causal attribution.** Three arms, one stimulus, only the active keyboard varies | US **0/10**, MS Cameroon QWERTY 2017 **0/10**, Keyman wedges. The two Cameroon layouts are output-identical when working, so the layout cannot account for it | `../TRIGGER.md` §3 |
| **Load is not the mechanism** | 32 CPU hogs on 16 cores: **0/10**. Freeze alone at zero load: **10/10** | `../TEST-PLAN.md` §1. This is why it never reproduced on a clean VM |
| **Scope, with negative controls.** Which keys can actually latch | exactly six — L/R Shift, Ctrl, Alt, all 2/2 (Ctrl 7/7 per side). Insert / NumLock / CapsLock / ScrollLock **0/2** under the identical stimulus | `../MODIFIERS.md` §2b |
| **Blast radius is machine-wide**, not Keyman-only | once latched, every keyboard and every application is affected; `Ctrl+A` arrives as `Ctrl+Shift+A`, and `GetAsyncKeyState` agrees the key is held | `../TRIGGER.md` §3 |
| **The cache is charged while no Keyman keyboard is active** | **3/3.** The modifier post at `k32_lowlevelkeyboardhook.cpp:198` sits 35 lines *before* the `!isKeymanKeyboardActive` pass-through at `:233` and does not consult it | `../TRIGGER.md` §3, `kmproof.ps1 -ChargeTest`. **This is what makes his Edge and Excel scenarios defensible (§2b)** |
| **The phantom KEYDOWN, on the wire** | not inferred from logs — captured by a `WH_KEYBOARD_LL` hook during a live trial | `../MODIFIERS.md` §2a-wire |
| **A stuck Ctrl reads CLEAN to a text oracle** | RCTRL latched while the text probe returned correct lowercase; a latched Alt empties the probe entirely | `../MODIFIERS.md` §2b. **This is why careful testers saw nothing — and why the field sample is all Shift (§2a)** |

The load row and the oracle row together explain the years of *"cannot
reproduce"*: the stimulus has to be arranged rather than stumbled into, and the two
worst keys are invisible to the obvious oracle. Note that neither of those is a
*repro* problem — see §2.

### This repo's own retractions

Offer these before anyone finds them.

- **The watchdog hypothesis this investigation started from is wrong.** Provoking
  the hook reinstall is not required for any of it: every reproduction here was
  obtained with the reinstall never provoked at all (`kmproof.ps1` 3/3 candidate
  I, 10/10 sweep; `kmmods.ps1` six slots 2/2). This **corroborates mcdurdin's own
  note** on #8064 that #15219 probably did not resolve it, which turns a
  retraction into agreement.
- **H6 (Right Shift extended flag) was raised, then disproved** at the wire.
  Windows resolves the side from the side-specific VK, not the flag.
- **Only three scripts are citable** — `kmproof.ps1`, `kmmods.ps1` and
  `kmaltgr.ps1`, which are clean on both known measurement hazards. Every number
  in this repo comes from one of those three.

---

## 4. What would actually close #8064

Ordered so each step is defensible on its own. IDs are the task IDs in
`../TODO.md` and `../TEST-PLAN.md` §6.

### Make it reproducible by anyone else

Today the stimulus needs either this repo's PowerShell or a hand-built binary.

- **P0** — add `fakefreeze/build.sh`. The stimulus **already ships in Keyman**
  (`windows/src/support/fakefreeze/`, mcdurdin 2025-11-17) and its handler is an
  ungated `Sleep(5000)` on the hook-owning thread. There is simply no `build.sh`,
  so `./windows/build.sh` never produces it, and nobody but its author can run it.
  **Highest-value single item here.**
- **P1** — restore `RightAltEmulationCheck.tests.cpp` to the vcxproj. It has not
  run since 2025-12-09, dropped by a merge. Independent of everything else.

### Turn it into a failing test in Keyman's own harness

No elevation, no TSF, no installed Keyman: the `keyman32` gtest suite links the
engine as a **static library** into a console exe and is already wired to TeamCity.
`keybd_shift_release` / `keybd_shift_reset` never call `SendInput` — they fill a
caller-supplied `INPUT[]`, so they are pure functions over a 256-byte array.

- **T-R2** — the bug in eight lines: make the thread queue disagree with physical
  state, exactly what a dropped KEYUP produces, then watch the modifier half of
  `GetCapsAndNumlockState()` believe the stale one. **Lead with this.**
- **T-P1** — the phantom press, in Keyman's own harness: stale cache in, unmatched
  extended-Ctrl KEYDOWN out. Passes today; it is the artifact, not the gate.
- **P4** — the manual app under `windows/src/test/manual-tests/`, modelled on
  mcdurdin's own `keyboard_ll_identifier`. Must add what that template lacks:
  decoded `dwExtraInfo`, an **unmatched-KEYDOWN detector** as the pass/fail oracle,
  a stall button, and a live `GetAsyncKeyState` panel over the six slots plus the
  prefix VK. **This is the artifact Ross can run on the three affected systems** —
  it replaces PowerShell-through-Notepad with something the team maintains.

### Fix it

Currently deferred by direction, not by analysis.

- **D1** — re-validate Cache A from the OS at batch start, and let the OS win. A
  missed KEYUP then self-heals on the next keystroke instead of persisting
  indefinitely. Seeding from the OS is already the accepted pattern at
  `InitThread()`; this makes it recurring rather than once. Prefer
  `GetAsyncKeyState` — `GetKeyboardState` reflects the calling thread's processed
  queue, which is precisely what is stale.
- **D2** — get `WH_KEYBOARD_LL` off keyman.exe's UI thread. The serializer already
  owns a dedicated thread with its own pump; the hook should follow it. Until it
  does, *any* long operation on that thread silently drops user keystrokes, and no
  downstream repair fully covers that.
- **D5** — a decision, not a task: **do not** fix this by gating the modifier post
  on `isKeymanKeyboardActive`. Per the #7337 comment the post exists to keep the
  serialized queue in sync across keystrokes Keyman does not otherwise process;
  suppressing it trades this bug for a different desync. D1 handles it by
  correcting the cache immediately before use.

### Answer the last open questions

- **I3** — what stalls the thread in the field. **Ross's focus-change observation
  is the lead.** Test it against `fakefreeze` and the manual app.
- **I5** — does Cache A exist in the 64-bit engine? `serialkeyeventserver.cpp` is
  `#ifndef _WIN64`. Every coverage claim depends on this, and today it is inference.
- **I7** — confirm on hardware with **no physical Right Ctrl**. Partly answered:
  this dev machine is that class. Field hardware still owed.

### Stop it recurring on any platform

Class A — an unpaired synthetic modifier KEYDOWN — is **structurally absent
everywhere but Windows**. No `keybd_shift_reset` analogue exists in `linux/`,
`mac/`, `android/` or `ios/`; Android and iOS do not use Core at all. So the
cross-platform work is about *guarantees*, not ports.

- **X8** — implement the `modifier_state` validation **Core already documents and
  never enforces**. `km_core_process_event` promises the modifiers *"set at the time
  key `vk` was pressed"* and documents `KM_CORE_STATUS_INVALID_ARGUMENT` for an
  invalid modifier state, but `km_core_processevent_api.cpp:44` validates only
  `state_ != nullptr`, and `KM_CORE_MODIFIER_MASK_*` appears nowhere in `core/src/`
  outside two LDML asserts. Contradictory bit pairs and chiral/non-chiral mixes pass
  straight through. One funnel, four platforms, **no API bump** — it makes a
  documented promise true rather than changing a signature. **The strongest
  genuinely cross-platform lever available.**
- **X6** — write down the invariant that has been holding by accident: *a platform
  layer must never synthesize a modifier key event it does not also pair.* Today the
  guarantee for class A is the *absence* of code, recorded nowhere, and one
  well-meaning patch could remove it.
- **X2 / X3** — macOS is the one real sibling. `currentModifiers` is a cached global
  written only from the CGEventTap `kCGEventFlagsChanged` callback, and the key
  event's authoritative `modifierFlags` is deliberately discarded. The tap can be
  disabled by the system and nothing re-seeds the cache — not on tap re-enable, not
  on `activateServer`. Much safer than Windows (absolute assignment, so it self-heals
  on the next flags change; never drives injection) but Shift/Caps can be stale for
  an unbounded window.
- **X10** — extend the shared `c keys:` fixture grammar with explicit modifier
  down/up. Today `kmx.cpp:238` sends the *same* `modifier_state` for keydown and
  keyup, so the shared fixtures **cannot express this bug class at all**. Those
  fixtures are consumed by three harnesses across four platforms and two of the
  three auto-glob the directory, so this is the best enforcement available.

### What Core cannot do

Core stores no modifier state — the platform hands it a `uint16_t` per event and
Core passes it through. **X8 catches malformed state, not plausible-but-stale
state.** The channel that could carry ground truth is closed by contract: the
`KM_CORE_EVENT_KEYBOARD_ACTIVATED` payload is documented *"Currently unused, must be
nullptr."* Opening it is a public API bump, a Debian symbols regen, the
`api-verification.yml` gate and three call sites — its own issue, justified only if
platforms actually share the defect. On this evidence only macOS does, and X2/X3 are
far cheaper.

Do not lean on `api-verification.yml` as the guard: it runs `dpkg-gensymbols`
against the Linux `.deb` only. `km_core_process_event` is a plain C symbol, so a
change to parameter *meaning* is invisible to it, enum values never appear in the
symbol table, and it can be skipped with a PR trailer. It is an ABI check, not a
semantic one.

---

[i8064]: https://github.com/keymanapp/keyman/issues/8064
[m2b]: ../MODIFIERS.md
[tr3]: ../TRIGGER.md
[todo]: ../TODO.md
[c9977]: https://community.software.sil.org/t/vedic-sanskrit-keyboard-continuously-presses-alt-key-on-windows-11/9977
[rc2]: https://github.com/user-attachments/files/23785339/RC_logs_2.zip
