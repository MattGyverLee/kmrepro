# Review: `fix/windows/8064-reconcile-modifier-cache`

Static review of the proposed fix for
[#8064](https://github.com/keymanapp/keyman/issues/8064) — *bug(windows):
modifier key occasionally is "stuck on"*.

**Scope reviewed:** 4 commits, 9 files, plus the surrounding machinery — the low
level keyboard hook, `LowLevelHookWatchDog`, the serial key event client, and the
on-screen keyboard's modifier injection.

**Not done:** nothing was built or run. The toolchain needed is the full
Visual Studio + Delphi Keyman build. Everything below is static analysis.

**Branch contents, as originally reviewed:**

| commit (original hash — see note) | subject |
|---|---|
| `204e63493b` | test(windows): characterise phantom modifier re-press in serial key event server |
| `a26aa611b5` | fix(windows): reconcile cached modifier state with the OS before injecting |
| `5274fec612` | chore(windows): add a build entry point for the fakefreeze support tool |
| `78a0c22edc` | test(windows): add manual test for the stuck modifier phantom KEYDOWN |

> **Hash note, added 2026-08-27.** The branch was rebased after this review was written. None of the
> four hashes above are reachable from the current `HEAD`; the pre-rebase branch is preserved locally
> as `backup/8064-preswap-4be29681b6`. Matched by content (test names and files touched, not just
> subject text), their current equivalents are `914795bf58`, `4aff8fc10e`, `bbb22576c2` and
> `b7971ec715` respectively — see [`IN-TREE.md`](IN-TREE.md) §2 for the full remap and what each
> commit absorbed during the rebase. The branch has also grown substantially since this review: a
> ten-commit follow-on (dispositions recorded inline below), a `host32` reproduction-harness round,
> and four more commits closing residual pathways — see `IN-TREE.md` §2a. Current gates are
> `test:x86` 72 pass / 1 disabled, `test:x64` 71 pass / 1 disabled.

---

## Outcome — this review was executed, and two of its own claims did not survive

Everything below is the original static review, **left unedited**. It generated a
work plan which has now been implemented and measured across ten commits; the
dispositions are recorded inline against each item. Items 1, 4 and 5 are fixed,
item 6 is refuted, item 3 is answered in the negative, item 2 is unchanged. Read the review for the reasoning and the
`**DISPOSITION**` notes for what actually happened.

Two items were **wrong**, and are marked as such rather than quietly corrected:

- **Item 6** asserted the seed is "effectively empty". It is not. Measured, a
  thread that has never pumped input gets *live* modifier state from
  `GetKeyboardState`; the process main thread is the one that answers stale. The
  documentation was **understating** the seed, not overstating it.
- **Item 3** judged the on-screen keyboard "not obviously broken" on the strength
  of its own reconcile and cleanup. Both were checked. `tmrCheckTimer` cannot
  clear a stuck modifier by construction, and the cleanup does not run on the
  common ways of dismissing the OSK. The OSK **is** broken, and it can strand an
  unclearable Right Control.

Item 3's correction is the significant one: it means **prevention is not
complete**, which was the question the whole review existed to answer.

| item | disposition |
|---|---|
| 1 — the mirror defect | **fixed**, red test first, then fix — squashed into one commit by the branch rebase, `132210bd97` (originally two: `13c083f216` then `00b17ee604`; see the hash note above) |
| 2 — no cure available | **the general tray-action cure is still not built — but see the 2026-08-27 addition below: a narrower, batch-scoped curative move has since landed** |
| 3 — the OSK is a second producer | **partly fixed, 2026-08-27 — see the addition below.** Originally UNMITIGATED with the review's judgement reversed |
| 4 — the fix itself is not under test | **fixed.** Batch path extracted and pinned; deleting the reconcile now turns 3 tests red |
| 5 — the modifier table is triplicated | **fixed.** One definition, reserve derived from its length |
| 6 — documentation overstates the seed | **refuted.** It understated it. Documentation corrected in the opposite direction |
| smaller: the two `#8064` TODOs | **removed** |
| smaller: `SendInput` partial return | **commented, not changed** — deliberately, per the no-behaviour-change gate |

Suite: **19/19 x86 and 18/18 x64 before, 33/33 and 32/32 after** this ten-commit
follow-on, 2 disabled each. **Stale as of 2026-08-27** — the branch has since grown
by a `host32` reproduction-harness round and the four residual-gap commits described
above; current gates are **72 pass / 1 disabled (x86), 71 pass / 1 disabled (x64)**,
see [`IN-TREE.md`](IN-TREE.md) §2 and §2a. Both DLLs rebuild warning-clean throughout.
Full evidence in the PR body for the follow-on branch (not yet opened — see
`IN-TREE.md` §6); the producer enumeration is in the Keyman tree at
`windows/src/test/manual-tests/GH-8064 - stuck-modifier-phantom-keydown/MODIFIER-PRODUCERS.md`.

---

## Verdict

The fix is correct, minimal, and — importantly — **placed in the only spot that
actually works**. Reasons first, then the residual risk, which is the part that
matters given the repro was contrived rather than observed.

---

## What is right, and verified

**The call site is not just convenient, it is necessary.** `PrepareInjectedInput`
is the only production caller of `keybd_shift` anywhere in the tree (one call
site each for release and reset). More to the point — a batch *can* be assembled
while the LL hook is uninstalled, which is the actual window of the defect:
`aiWin2000Unicode.cpp:235` calls `SignalServer` from the focused app's
GetMessage-hook path, completely independent of the LL hook. So an injected batch
— and therefore the phantom press — can happen before
`LowLevelHookWatchDog::ReinstallHook` ever notices anything is wrong.
Reconciling at the top of `PrepareInjectedInput` covers that; reconciling in the
watchdog would not have.

**The asymmetry (clear only, never set) is the right default** and is correctly
reasoned in the docstring. An unmatched KEYUP cannot latch anything; an unmatched
KEYDOWN latches machine-wide. Clearing is on the safe side of that.

**`GetAsyncKeyState` over `GetKeyState` / `GetKeyboardState` is right** — the
latter two read the calling thread's processed queue, which is precisely the
stale source.

**Only one server exists.** `serialkeyeventserver.cpp` is `#ifndef _WIN64`,
`keyman32.vcxproj` builds Win32/x64/ARM64, and `keyman32.cpp:398` guards
`Startup()` the same way. There is no second, unreconciled cache in the x64 or
ARM64 engine. The file-header comment claiming the server runs in
`keymanhp.x64.exe` / `keymanhp.arm64.exe` is stale, but the code is fine.

**Bonus catch:** `ModifierEventCountNeverExceedsReserve` pins
`MAX_KEYEVENT_INPUTS_MODIFIERS = 8` against `keybd_shift`'s actual output. That
header comment ("This value depends on keybd_shift behaviour") had no enforcement
before. `PrepareInjectedInput`'s loop bound lands the buffer at exactly 256 of
256 — one off and it is a heap overrun. Good test to have.

> **DISPOSITION.** `MAX_KEYEVENT_INPUTS_MODIFIERS` is no longer the literal `8`;
> it is now `(KEYMAN_MODIFIER_VK_COUNT + 2)`, derived from the length of the one
> shared modifier table (item 5). The reserve therefore tracks the set
> automatically — verified by adding a seventh VK and watching the macro become 9
> with no edit to it. `ModifierEventCountNeverExceedsReserve` still passes, and a
> second case now drives the union that item 1's fix introduced.

---

## Where it can still bite

### 1. The opposite direction is untreated, and it is the destructive one

Same root cause — the hook is bypassed — but a lost **KEYDOWN** instead of a lost
KEYUP. Cache says up, OS says Ctrl is genuinely held. `keybd_shift_release` emits
nothing, and the batch goes out with Ctrl live.

That is not cosmetic. `aiWin2000Unicode.cpp:206` emits `VK_BACK` for `QIT_BACK`,
and the comment at `serialkeyeventserver.cpp:437-441` says releasing modifiers
around Backspace is the *entire reason* `keybd_shift` exists: Ctrl+Backspace
deletes a word, Alt+Backspace is Undo. So this direction silently destroys user
text where the fixed direction only wedges a modifier.

The docstring dismisses it on re-latch grounds, which is sound *for setting the
cache* — but it does not have to set the cache. The strictly safer variant:

- **release** on `union(cache, OS)` — release anything either source says is down
- **restore** on cache only — unchanged

An unmatched KEYUP cannot latch, so this adds no #8064 risk. Cost: a genuinely
held Ctrl gets released and not re-pressed for one batch. That is visible but
recoverable; a deleted word is not. Worth a decision, not necessarily this PR.

> **DISPOSITION - fixed, and the decision went this way.** The suggested variant is
> exactly what shipped: `ComputeModifierReleaseState` fills a caller-supplied array
> with `union(cache, live OS)` over the managed set, the release half is handed that
> union, and the restore half still reads the cache alone. The asymmetry is
> structural rather than conventional: the restore loop is handed an array the OS's
> view was never written into, so it *cannot* press a modifier released on the OS's
> word alone.
>
> It was demonstrated before it was fixed, which mattered because this item was a
> static claim about a defect whose original repro was contrived. The
> characterisation test fails against the pre-fix tree with `release == -1` - no
> KEYUP emitted at all for a modifier the OS reports held - and landed as its own
> earlier commit before the fix. **Hash note, 2026-08-27:** those were originally two
> commits, `13c083f216` (the red test) then `00b17ee604` (the fix); a later rebase
> of the branch squashed them into one, `132210bd97`, which is what `HEAD` now
> contains. Neither original hash is reachable from `HEAD` any more.
>
> One correction to the reasoning above: the union is computed *explicitly* even
> though, after the reconcile has run, cache-held is already a subset of OS-held so
> the union equals the live state. Writing it as a union states the requirement
> instead of relying on call order, so reordering or removing the reconcile cannot
> silently turn the release half back into a cache-only read.

### 2. There is no cure available, and the reason is structural

The README says the fix cannot recover an already-latched process. That is right,
and it is worth being explicit about *why*, because it bounds what any future fix
can do: once the phantom KEYDOWN lands, the modifier is genuinely down at the OS
and the state is **indistinguishable from a real hold**. No amount of state
inspection recovers it.

Two candidate cures were chased and both fail:

- **Propagate `LLKHF_INJECTED`.** It is available in the hook and
  `LLKHFFlagstoWMKeymanKeyEventFlags` discards it; lParam bits 2-15 are free.
  Tracking physical-vs-injected would let the server tell its own re-presses from
  the user's. But it does not help here: in the lost-KEYUP case Keyman never
  *saw* the release, so "physically held" is latched too. Same blindness.
- **Resync in `ReinstallHook()`.** That is the one place that knows input was
  dropped — but by the time it fires the phantom may already be out, and at that
  point cache and OS agree. Nothing to see.

So prevention is the whole game, which makes the strength of item 1 above matter
more than it otherwise would.

The one thing that *is* available and would genuinely help users: **an explicit
"release all modifiers" action** — the README's own Recovery snippet, wired to a
tray item or hotkey. The README correctly identifies the worst field case: a
latched Right Ctrl on a keyboard with no Right Ctrl key is unclearable by any
keystroke the user can produce, and the only escape today is restarting Keyman.
`KEYBD_SHIFT.RightControlCollapsesToExtendedControl` is a test for exactly that
scenario. Turning "restart Keyman" into "click this" is cheap and is the only
curative move on the table.

> **DISPOSITION - unchanged, and confirmed. The tray action is still not built.**
> Both candidate cures were re-examined and both still fail for the reasons given.
>
> Two additions from execution. First, the "no cure" argument is *why* no rescue
> action was added to the fix branch: a machine restart clears any wedge and
> upgrading Keyman requires a restart, so nobody can reach the fixed build already
> wedged. **If Keyman's install ever stops requiring a restart, that reasoning
> lapses.** Second, the recovery snippet was measured against every shape
> `keybd_shift` can emit - Left Shift, extended Right Ctrl, and Right Shift by scan
> code - and the `0xA0`-`0xA5` KEYUP sweep clears all three. So the "release all
> modifiers" action is known to work before anyone builds it.
>
> **Addition, 2026-08-27 — a narrower cure has since landed, and the distinction from
> the tray action matters.** `5ba72fa3c9` adds a post-batch verification pass:
> `PrepareInjectedInputBatch` reports which modifiers its restore half pressed, the
> server posts itself `WM_KEYMAN_VERIFY_MODIFIER_EVENT`, and — because posted
> messages are FIFO and land behind any racing user release — the handler injects a
> corrective KEYUP for anything the OS still holds that the cache now says is up.
> **This is genuinely curative, not merely preventive, for the specific case it
> covers**: a modifier the batch itself just wedged, within that same batch's
> lifetime. It is not the cure this item was asking for. The tray action's whole
> point was recovering an **already-latched process** — a wedge that formed at some
> unknown point in the past, possibly minutes or hours ago, with no batch in flight
> to trigger a verification post. The post-batch pass never fires for that case: it
> only runs when a batch's own restore half pressed something, so a wedge from a
> dropped KEYUP with no subsequent Keyman-triggered batch is exactly as
> unrecoverable as before. Do not describe this as closing item 2 — it closes a
> different, narrower problem that happens to overlap in mechanism.

### 3. There is a second, entirely separate producer of stuck modifiers

`UfrmOSKOnScreenKeyboard.pas` — `ShiftStateChange` / `PrepState` /
`kbdKeyPressed` — injects bare modifier KEYDOWNs
(`do_keybd_event(vk, 0, FExtended, 0)`) with no queued KEYUP, to make the OSK's
sticky modifiers real machine-wide. It has its own reconcile (`tmrCheckTimer`
against `GetAsyncShiftState`) and its own cleanup
(`TfrmVisualKeyboard.FormClose` -> `ResetShiftStates`), so it is not obviously
broken — but **#12611 in that same file is a previously fixed stuck-Left-Shift
bug of the identical shape.**

This branch does not touch it, and should not. But it is directly relevant to the
sufficiency question: field reports of "modifier stuck on" are indistinguishable
between the two paths, and given that #8064's repro was contrived rather than
observed, **there is no evidence that the reports which opened #8064 came from
the serializer path at all**. If the symptom recurs after this ships, the OSK is
where to look before concluding the fix failed. A sentence to that effect belongs
in the PR body — it protects the fix from being wrongly blamed.

> **DISPOSITION — UNMITIGATED. This item's judgement is reversed, and it is the most
> consequential finding of the whole exercise.**
>
> "It has its own reconcile and its own cleanup, so it is not obviously broken" was
> the reasonable reading. Both mechanisms were checked and neither works:
>
> - **`tmrCheckTimer` cannot clear a stuck modifier, by construction.** It runs
>   every 50 ms but reconciles the OSK's cache *toward* the OS
>   (`FShiftState := FNewShiftState`), and emits a key event only when both chiral
>   Alts or both chiral Ctrls are set. For a single stuck modifier it emits nothing,
>   and once its cache has absorbed the stuck bit its own guard
>   (`if GetAsyncShiftState <> FShiftState`) stops it running at all.
> - **The cleanup does not run.** `ResetShiftStates` is reached only from
>   `FormClose`, which fires only on `TCustomForm.Close` — the OSK's own X button, or
>   a tab switch. The tray menu toggle, tray double-click, `KMC_ONSCREENKEYBOARD` and
>   Keyman shutdown all reach `Release` or `FreeAndNil`, and `Release` posts
>   `CM_RELEASE` then calls `Free`, which runs `OnDestroy` and never `OnClose`. Once
>   the form is freed its timer is gone too, so nothing left in the process can
>   release the modifier.
>
> Worse, the modifier can be an **extended `VK_RCONTROL`** — chiral emission is the
> default — so this path reproduces the exact worst field case in item 2. And
> `ResetShiftStates` is *itself* a producer: it routes through `PrepState`, which
> presses as well as releases, so for up to 50 ms after a modifier-off click the
> cleanup can press a modifier the user is no longer holding.
>
> The sentence this item asked for is in the PR body. But it now says more than
> "look at the OSK first": the OSK is a **confirmed** producer, so a field
> recurrence is triaged rather than attributed. `MODIFIER-PRODUCERS.md` and
> `TRIAGE.md` were added to the Keyman tree for that purpose, and FR-011 — every
> enumerated path carries a verdict or an issue number — is **not satisfied**.
>
> Fixes for the two OSK findings are drafted and landed **untested**; Delphi was not
> available. The `SetLRShift` chirality collapse, which strands Right Control even on
> hardware that has the key, is not fixed at all.
>
> **Addition, 2026-08-27.** `3d64aad790` fixes the `SetLRShift` chirality collapse — but
> **only for the teardown path**. `ResetShiftStates` now releases each held modifier by
> its recorded injected chiral identity (`FCachedShiftState`, one call per chiral VK,
> gated on a live `GetAsyncKeyState` check) instead of routing through
> `ShiftStateChange`, which is what collapsed the identity in the first place. Still
> **UNTESTED** — Delphi is not installed here, so this has not compiled or run, and the
> producer enumeration's verdict is correctly left at UNMITIGATED for that reason, not
> upgraded on the strength of source reasoning. **The live click-off path is
> deliberately still open.** The obvious fix — making `ShiftStateChange` itself
> maintain an injection-accurate `FCachedShiftState` — was written and reverted this
> session, because that same function is also reached from `UpdateShiftStates`' 50 ms
> resync, whose press branch fires for modifiers the user is physically holding;
> recording those would let teardown release a key the user still has down, which is
> the exact I2177 regression this file's "not obviously broken" original judgement was
> already wrong about once. So: this item moves from wholly unmitigated to **partly
> fixed, unverified, with the live click-off path knowingly left open** — not to
> mitigated, and not to closed.

### 4. The one line that is the entire fix is the one thing not under test

Seven new `RECONCILE_MODIFIER_CACHE` tests all pass if you delete
`serialkeyeventserver.cpp:392`. `PrepareInjectedInput` is a private method of a
class defined inside a `.cpp`, so the test project cannot reach it. Given the fix
*is* one call at one site, this is the highest-value thing to pin and it is not
pinned. Lifting `PrepareInjectedInput`'s body into a free function alongside
`keybd_shift` — taking the cache, the reader, and the shared-data pointer — would
make it reachable, in the same style the fix already used for
`ReconcileModifierCache`.

> **DISPOSITION - fixed, exactly as suggested.** The body of `PrepareInjectedInput`
> was lifted verbatim into `PrepareInjectedInputBatch` in `keybd_shift.cpp`, taking
> the buffer, the cache, the shared-data pointer and the reader; the method became a
> single delegating statement. Five batch-level cases were added, and deleting the
> reconcile call inside the extracted function turns **three of them red** - while
> every pre-existing `KEYBD_SHIFT` and `RECONCILE_MODIFIER_CACHE` case stays green,
> which is precisely the hole this item identified.
>
> Two corrections. **There are six `RECONCILE_MODIFIER_CACHE` tests, not seven** -
> the seventh is `DISABLED_ResetDoesNotPressAKeyThatIsNotHeld`, which belongs to the
> `KEYBD_SHIFT` fixture. And the coverage has a **residual**: deleting the
> *delegating statement* still leaves the suite green, because that one line is
> unreachable from gtest by construction. The unprotected surface shrank from the
> entire fix to one statement whose only job is to call the tested function. That is
> a reduction, not elimination, and the PR says so.
>
> Incidentally, deleting the reconcile call does not even compile: the orphaned
> reader parameter trips `C4100` under warnings-as-errors.

### 5. The modifier table is now triplicated

`keybd_shift_release`, `keybd_shift_reset`, and `ReconcileModifierCache` each
carry their own `const BYTE modifiers[6]`. If the set ever changes, reconcile
silently under-covers and every test still passes.
`IsModifierKeyAcceptsExactlyNineVks` guards the hook's set but not this one. One
shared table closes it.

> **DISPOSITION - fixed, and the table was in fact quadruplicated.** The fourth copy
> was the batch reserve: `MAX_KEYEVENT_INPUTS_MODIFIERS` was the literal `8`, an
> unlinked restatement of the same fact, with a comment that said only "This value
> depends on keybd_shift behaviour".
>
> `KeymanModifierVks` is now defined once in `keybd_shift.cpp`, declared in
> `keymanengine.h` outside the `_WIN64` region so both architectures and the gtest
> project see it, and all three loops iterate it. `KEYMAN_MODIFIER_VK_COUNT` derives
> the reserve.
>
> Accepted by a mutation check rather than a test, since a behaviour-preserving
> refactor has no red-first cycle: adding a seventh VK and bumping the count - one
> edit in each of two files, nothing else touched - made the release half, the
> restore half **and** the reconcile all cover it, and took the reserve to 9 on its
> own, so an all-held batch emitted exactly 9 events against a reserve of 9. Both
> edits reverted, counts confirmed unchanged. This is recorded in the PR as *not*
> test-driven.
>
> A comment at the definition records that this table is **not** the hook's nine
> accepted VKs and that the two must not be unified.

### 6. Documentation overstates the seed

`InitThread` calls `GetKeyboardState(m_ModifierKeyboardState)` on the newly
created server thread. `GetKeyboardState` returns the *calling thread's* copy,
and a thread that has never pumped input has an effectively empty one — so
"seeded from the OS exactly once", repeated in the docstring, the inline comment,
the README and the test header, is generous. Benign (zeros cannot latch), but for
a fix whose principal artifact is its documentation, worth correcting — or just
make it a `ReconcileModifierCache`-style seed and the sentence becomes true.

> **DISPOSITION — REFUTED BY MEASUREMENT. This item is wrong, and its suggested fix
> would have made things worse.**
>
> A `DISABLED_` probe holds Left Shift and reads both threads:
>
> ```
> this thread : GetKeyboardState ok=1 byte=0x00, GetAsyncKeyState=0x8001
> fresh thread: GetKeyboardState ok=1 byte=0x81, GetAsyncKeyState=0x8000
> ```
>
> Reproduced over four runs; the fresh thread's high bit was set every time and the
> main thread's never was. **A thread that has never pumped input gets live modifier
> state.** The process main thread, whose input queue the injected event never
> reached, is the one that answers stale. `InitThread` reads before `RegisterClass`
> and `CreateWindow`, so it is exactly that queue-less case.
>
> So "seeded from the OS exactly once" is **substantively correct**, and the four
> documents were *understating* the seed rather than overstating it. All four were
> expanded to state the measurement and cite the probe. The planned correction would
> have replaced a true sentence with a false one.
>
> The alternative this item offers — "just make it a `ReconcileModifierCache`-style
> seed" — is doubly wrong: the seed already reads live OS state, and writing live
> state into the cache is what the restore half then presses, which is the unmatched
> KEYDOWN this whole exercise exists to prevent.
>
> One real consequence, in the opposite direction to "benign": a live seed is a
> genuine **launch-time latch source**. A modifier held as Keyman starts is captured
> into the cache and goes stale if the user releases it before the hook feed begins.
> `ReconcileModifierCache` — already shipped — closes it.

---

## Smaller things

- ~~`fakefreeze`'s `bin/` and `obj/` are untracked~~ — **wrong, retracted.**
  `windows/src/.gitignore:7,12` cover `**/obj/Win32/` and `**/bin/Win32/`, which
  is exactly what the `OutDir`/`IntDir` override produces. The original probe
  tested `bin/foo` without the platform segment and missed the rule.
  `IN-TREE.md` §5 records the choice as deliberate — modelled on `etl2log`, and
  chosen over `wow64kbd` precisely because `wow64kbd` declares outputs its
  vcxproj never produces. The lone `x64/` line in `fakefreeze/.gitignore` is now
  dead, which `IN-TREE.md` also already records.
- ~~`fakefreeze/build.sh` omits `create-windows-output-folders`~~ — **retracted
  as a finding.** It is deliberate: the tool is built, not packaged, so it never
  writes into the shared output tree and has nothing to copy to
  `WINDOWS_PROGRAM_SUPPORT`. `WIN32_TARGET_PATH=bin/Win32/$TARGET_PATH` lines up
  with the override, so `builder_describe_outputs` is right.
- `k32_lowlevelkeyboardhook.cpp:190` and `:199` still say
  `//TODO: #8064. Can remove debug message once issue #8064 is resolved`. If this
  branch closes the issue, they should go.
  > **DISPOSITION - done: both TODOs removed, and both debug messages with them.** The
  > comment says "Can remove debug message once issue #8064 is resolved", so the code
  > block goes with the comment. Removing the reminder while keeping the diagnostic it
  > pointed at was an intermediate state nobody wanted, and it was corrected.
  >
  > Neither `FHotkeyShiftState` nor `isUp` becomes unused, so there is no C4189/C4100
  > under warnings-as-errors; confirmed by a full rebuild of both platforms.
  >
  > Nothing in the triage procedure depended on these two. The signal `TRIAGE.md` uses
  > is the key-event log carrying the scan code, which is a different line and is
  > untouched. That distinction matters because `KL.Log` does not exist at all --
  > `klog.pas:26` reads `{DEFINE KLOGGING}` with the `$` missing and `KLOGGING` appears
  > nowhere else in the tree -- so `SendDebugMessageFormat` is the only live log stream
  > and should not be thinned without checking what depends on it.
  >
  > **Addendum, 2026-08-27.** The removal held until `e245c41845`, which restores a trace
  > at the same site for a different reason: `specs/003-8064-debug-log-adequacy` identifies
  > the posting-side modifier trace as one of the few signals that actually helps diagnose
  > a stuck modifier, unaware this branch had deleted it. The restored trace is not the old
  > per-keystroke message — it is scoped to modifier keys and records provenance filtering
  > and post success, which the old one did not. The disposition above (TODOs and their
  > messages are gone) is still accurate; a new, narrower trace now occupies similar
  > territory for an unrelated reason.
- `ProcessQueuedKeyEvents` checks `SendInput(...) == 0` but ignores a partial
  return. Not a latch source (the reset KEYDOWNs are last, so truncation drops
  them, which is the safe direction), but `!= m_nInputs` is the honest check.
  > **DISPOSITION - commented, deliberately not changed.** The reasoning above is now
  > recorded at the call site. Changing the check would be an unrelated behaviour fix
  > riding along in a phase gated on "no behaviour change", so it was left alone. The
  > event ordering it depends on - release half, output keys, restore half last - is
  > now pinned by a test rather than left as a comment.

---

## Bottom line

The fix cannot be defeated by the mechanism it was written for — the call sits
directly in front of the only phantom-press site, and covers the
hook-uninstalled window that a watchdog-based fix would have missed.

What it does **not** cover is the *mirror* of that mechanism (item 1, the
data-destroying half), and it shares the field symptom with a second code path it
does not touch (item 3).

Neither is a reason to hold the branch. Items 1 and 4 are what should be
addressed before calling #8064 **closed** rather than **mitigated**.
