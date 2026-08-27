# Meeting prep — what will come up

Read before talking to Marc or Ross. Plan: [TEST-PLAN.md]. Mechanism: [MODIFIERS.md]. Log: [TODO.md].

---

## 1. This is not a new bug. It is [#8064][i8064], and it is Ross's

| | |
|---|---|
| **[#8064][i8064]** `bug(windows): modifier key occasionally is 'stuck on'` | **OPEN**, opened by **rc-swag** 2023-01-23, milestone **20.0**, 10 comments, last touched 2026-05-28 |

Original report: typed `Lonh does does`, got `LOnh DOes DOes` — a phantom Shift that persists after Shift is released. That is the same defect [TRIGGER.md] reproduces.

**Do not open a new issue.** Everything here is evidence for #8064. [#16422]/[#16423] are the *Cache B* (caps/toggle) siblings and are separate.

**You are already named in it.** rc-swag, 2023-12-01: *"Another @MattGyverLee has experienced the modifier key when using the IPA keyboard and setting the keyboard option to 'Before'"*, linking [keyboards#2466][kb2466].

Field reports accumulated on the issue: [community 8516][c8516] (framed as "Keyman causing Windows 10 to crash"), [community 8777][c8777], [community 9977][c9977] ("Vedic Sanskrit keyboard continuously presses Alt key on Windows 11"). Worth knowing these exist — the Alt one is the swallowed-keys presentation described in [MODIFIERS.md] §2b, not a different bug.

---

## 2. Ross has independently reached most of the same conclusion

His notes are attached to the issue as [`RC_logs_2.zip`][rc2] → `Observations_so_far.txt` (2025-11-27), plus [`RC_Logs_1.zip`][rc1] and `test3_lowlevel.xlsx`. **Read `test3_lowlevel.xlsx` before the meeting** — it is the single biggest surprise risk, and the only one of the three not yet mirrored here.

The text notes are mirrored in [`issue-8064/`](issue-8064/README.md), which carries the **full** crosswalk, the two questions to ask him, and the ordered closure path. The table below is the short version.

Convergence, in his words vs. this repo:

| Ross, from field logs | kmrepro |
|---|---|
| *"`m_ModifierKeyboardState=[LS:80 … RS:80 …]` — There is never a return to RS:0. **Why**"* | Cache A never reconciled — [MODIFIERS.md] §1, proof step 2 |
| *"the last message of this type is a pressed and not released … **extra: 4b4d0000 which means injected by keyman**. There is no message after this to say the key is released"* | the unmatched KEYDOWN — proof step 4; wire capture in [MODIFIERS.md] §2a-wire |
| *"pressing the left shift key would not release the stuck shift key but pressing the **right** Shift key did"* | only the exact matching KEYUP clears it — [MODIFIERS.md] §3b, measured |
| *"746 `Key pressed` and only 221 `Key released`"* | dropped KEYUPs are the seed — proof step 3 |
| quotes the same `keybd_shift.cpp` RShift/scan-code comment | same function, [proof step 5][tp] |

**He is not wrong and this does not scoop you.** What he lacks is a *deterministic trigger* and *causal attribution*. What this repo adds: the three-arm proof that it is Keyman's and not the layout's or Windows' ([TRIGGER.md] §3), the six-key scope with negative controls ([MODIFIERS.md] §2b), 10/10 determinism from a single stimulus, and the charge-while-inactive result (3/3).

### Where you differ — and it may be the missing piece, not a conflict

Ross's three co-occurring events: *"A modifier (shift) has been pressed / A backspace has been pressed / **Application focus has changed**."* He also notes *"for backspace the event server does release/set of the modifier key."*

Read against the mechanism, those map cleanly:

- **backspace** → forces an injected batch → `PrepareInjectedInput()` → the phantom is *emitted*. That is the emission step, not the cause.
- **focus change** → a plausible **UI-thread stall source** — which is exactly [TODO][todo] **I3**, the open question this repo could not answer ("what actually stalls keyman.exe in the field?").

So his field observation may *answer* our open question, and our stimulus may make his scenario reproducible on demand. Lead with that framing. It is collaborative and it is true.

---

## 3. Prior fixes that will be raised

Four previous attempts at this symptom. Expect *"we've fixed this before."*

| ref | what | why it did not close it |
|---|---|---|
| [#1620][i1620] (2019, mcdurdin, [`eb92df40de`][c1620]) | AltGr causes sticky **Left Control**. Special-case in `serialkeyeventserver.cpp`: on RAlt-up with LCtrl down, synthesize the LCtrl release | Narrow to the AltGr/LCtrl pair. Its comment is directly relevant: Windows emits the synthetic Ctrl with **scan `0x21D`** and *"we are unable to emit that scan code"* — and kmrepro measured exactly `scan=0x21D` on the MSKLC arm ([MODIFIERS.md] §3d-measured). Worth citing; it shows the two investigations are looking at the same wire |
| [#4884][i4884] (2021) | *modifier keys sometimes get stuck* | closed, symptom recurred |
| [#7337][i7337] (2022, rc-swag, [`90eb7c77ec`][c7337]) | *ensure all modifier events go to serialized queue* | **This commit created the Cache A feed** at [`k32_lowlevelkeyboardhook.cpp:200`][llh200]. It fixed a desync; it also made the cache authoritative |
| [#15179][p15179]/[#15219][p15219] (2025, mcdurdin) | LL-hook watchdog — reinstall the hook if Windows removes it | **Marc already knows it did not fix #8064.** 2025-11-26: *"@rc-swag notes that stuck key logs still have lowlevelkeyboardproc messages, so this probably does not resolve that issue."* A bot auto-closed #8064; Marc reopened it: *"Nope, see above. My bad"* |

Note the last row: this repo's own finding that the watchdog is not the mechanism **confirms Marc's own note**. Say so — it turns a retraction into corroboration.

---

## 4. Honest gaps

| gap | status | what to say |
|---|---|---|
| **I3 — what stalls keyman.exe in the field?** | **open, and it is the real gap** | The stimulus is `KMC_WATCHDOG_FAKEFREEZE`, a debug command. It proves the mechanism, not the field frequency. Ross's focus-change observation is the best lead |
| **All keystrokes are injected** (`keybd_event`) | acknowledged | Keyman *can* distinguish synthetic keys (`LLKHF_INJECTED`, and the `dwExtraInfo`/`SCAN_FLAG_KEYMAN_KEY_EVENT` checks). Physical AltGr was verified separately and matched, but only on that path |
| **I5 — does Cache A exist in the 64-bit engine?** | open, inference only | `serialkeyeventserver.cpp` is `#ifndef _WIN64`. Coverage claims depend on this |
| **I12 — the latch set accumulates within a session** | open, 4 hypotheses killed | Not a timer, not focus-change resync. Only a new process cleared it. Do not offer a mechanism |
| **The ARM64 leg of the fix is unbuilt** | open | No ARM64 MSVC libraries on the dev machine. `ReconcileModifierCache` has no architecture guard and the declaration sits outside the `_WIN64` region, so it should compile — but say "should", not "does". CI or an ARM64-toolset machine owes the answer. [`IN-TREE.md`](IN-TREE.md) §6 |
| **The fix is preventive, not curative — mostly still true, 2026-08-27** | by design, and worth volunteering | It stops the latch forming; it cannot recover a process already latched, because by then the modifier is genuinely held and cache and OS agree. **Since qualified:** a post-batch verification pass (`5ba72fa3c9`) is genuinely curative for the narrower case of a race the batch's own restore press caused within that batch's lifetime — not for a wedge that formed earlier with no further Keyman-triggered batch to trigger the check. Offer both halves before a reviewer finds the second one. [`IN-TREE.md`](IN-TREE.md) §3 C-2, §2a |
| **The OSK teardown fix is unverified; the live click-off path is deliberately unfixed** | open, worth volunteering | Delphi is not installed here, so `3d64aad790` has not compiled or run. Its own reverted sibling fix would have reintroduced the I2177 regression by recording physically-held modifiers as releasable. Say both before being asked. [`IN-TREE.md`](IN-TREE.md) §2a |
| **The `host32` live re-run of producer rows 1 and 9 is still owed** | open | Both rows are marked mitigated in the current tree's `MODIFIER-PRODUCERS.md` but on source reasoning, not a re-run of the harness that measured the original 5/5-to-0/5 freeze reproduction. [`IN-TREE.md`](IN-TREE.md) §6 |
| **One machine, one Windows build, one Keyman build** | — | Say it before they do |
| **The summary table inside `logs/mods-prefix-latch-evidence.txt`** | stale | It is the pre-`self`-column version and shows the immune keys as "2/2 latched" from §2c residue. The per-trial lines above it are correct; quote [MODIFIERS.md] §2b rather than that table |
| **I7 — hardware with no physical Right Ctrl** | partly answered | This dev machine *is* that class — on the user's report, corroborated by a wire capture that shows only `LCTRL` taps. Do not say "confirmed at the wire": no capture can prove a key is absent. Field hardware still owed |

---

## 5. Practical realities

- **CI:** no GitHub Actions workflow runs Windows unit tests — no `windows-latest` job exists anywhere. Windows tests run on **TeamCity** only, via `/windows/build.sh test`. `test:arm64` is commented out pending [#15065][i15065].
- **Build:** Delphi 10.3/11 + VS 2022 v143 with x86/x64/ARM64 toolchains are required to build and run the suite locally. If you cannot build it, say so early rather than proposing tests you cannot run.
- **[#16423][i16423] is labelled `user-test-required`** and `has-user-test`. It is a PR-shaped issue and is not merged. Know its state before referencing it.
- **[`RightAltEmulationCheck.tests.cpp`][raec] has not run since 2025-12-09** — dropped from `<ClCompile>` by merge `4ac24f7b7b`. This is a live finding, independent of everything else, and is a goodwill fix.
- **[`fakefreeze`][ff] had no `build.sh`**, so `./windows/build.sh` never produced it and nobody but Marc could run the stimulus. **Fixed 2026-08-26** — `build.sh` added and `:fakefreeze` registered in `support/build.sh`, modelled on `etl2log` rather than the unregistered `wow64kbd`. Marc wrote the tool and will know it exists; the ask is now review, not authorship. [`IN-TREE.md`](IN-TREE.md) §5.

---

## 6. Questions this answers

**Reproducing it.** Load was never the mechanism: 32 CPU hogs gave 0/10; the freeze alone with zero load gave 10/10 ([TEST-PLAN][tp] §1). [`LowLevelHookWatchDog.cpp`][wd] documents the precondition — the hook is only uninstalled *"if a key is pressed while Keyman is unresponsive"* — and for this bug that key must be a modifier **KEYUP**. That never coincides by accident on an idle VM, which is why it has resisted reproduction. `fakefreeze.exe` makes it deterministic.

**What the proposed tests require: no elevation, no TSF, no installed Keyman.** The [`keyman32` gtest suite][vcx] links the engine as a **static library** into a console exe. `keybd_shift_release`/`keybd_shift_reset` never call `SendInput`; they fill a caller-supplied `INPUT[]`, so they are pure functions over a 256-byte array. Nothing here needs a Windows E2E rig.

**Why the test cannot live in Core.** Core stores no modifier state; the platform hands it a `uint16_t` per event and Core passes it through ([`kmx_processor.cpp:263`][kmxp]). It receives the wrong bit with no second source of truth — structurally impossible to test there, not merely awkward. The channel that could carry truth is closed: [`keyman_core_api.h`][capi] documents the activation payload as *"Currently unused, must be nullptr."*

**Cross-platform scope — Windows only, with one exception.** Class A (re-injected unmatched modifier KEYDOWN) exists only on Windows; no `keybd_shift_reset` analogue exists in `linux/`, `mac/`, `android/` or `ios/`. Android and iOS do not use Core at all (KeymanWeb in a WebView); Android re-reads modifier state from every `KeyEvent` and filters modifier keys out before Keyman sees them; iOS has no hardware-key path whatsoever. The one real finding is **macOS**, which caches `currentModifiers` and *discards* the event's own flags — see [TEST-PLAN.md] §5.

**Why not simply gate the `:198` modifier post on `isKeymanKeyboardActive`.** [TODO][todo] **D5**, recorded as a decision rather than a task. Per the #7337 comment, that post exists to keep the serialized queue in sync across keystrokes Keyman does not otherwise process; suppressing it trades this bug for a different desync. D1 (re-validate the cache at batch start) handles it without that cost.

**Relationship to the Caps Lock bug.** Same *class* — stale cached state — but a different cache and a different severity. Cache A injects real keypresses system-wide; Cache B (#16422/#16423) only mis-matches rules. [MODIFIERS.md] §1 has the table.

---

## 7. What to ask for

Reordered 2026-08-26: three of the five original asks are now deliverables rather than
requests, so lead with the review and keep the questions that are still open.

1. Confirm **#8064 is the home** for this evidence.
2. **Review the branch.** `fix/windows/8064-reconcile-modifier-cache`, off upstream
   `master` @ `deeff0456f`: the defect characterised in the `keyman32` gtest suite, the Cache A fix
   ([TODO][todo] **D1**), a `build.sh` for [`fakefreeze`][ff] ([TEST-PLAN.md] **P0**), a manual
   test, a `host32` reproduction harness, and — most recently — four commits closing residual
   pathways a five-lens audit found (the pass-through race, the eaten-event pipeline loss, and the
   OSK teardown chirality collapse). **27 commits now, not four** — still not pushed, still no PR.
   `test:x86` 72 pass, `test:x64` 71 pass, 1 disabled each — both engine DLLs link clean. Full record
   in [`IN-TREE.md`](IN-TREE.md) §2 and §2a.
   - Volunteer the judgement calls rather than waiting to be asked: registering
     `:fakefreeze` puts it in CI's path and the narrower alternative is one line away; the ARM64 leg
     is unbuilt; the fix is preventive for the general case, though a narrow batch-scoped curative
     move has since landed for the case where a batch's own restore press outlives a race it caused
     (`IN-TREE.md` §2a); and the OSK teardown fix is written but **unverified** — Delphi is not
     installed here, so it has not compiled or run — while the OSK's live click-off path is
     deliberately left unfixed, on the record, because the safe fix needs a Delphi compiler to land
     without risking the I2177 regression.
3. Ross's `test3_lowlevel.xlsx` timeline cross-checked against `logs/` — do his field logs and this
   repo's wire captures show the same event shape? **Still the highest-value open question**, because
   it is the nearest thing to a field trigger for **I3**.
4. **I3** — does his focus-change observation explain what stalls the thread in the field? The fix
   makes the consequence harmless; it does not explain the cause, and nothing here does.
5. **I5** — does Cache A exist in the 64-bit engine? Still inference. The fix inherits the question
   rather than settling it: its call site is inside `#ifndef _WIN64`, exactly as the server is.
6. Note that **T-R1** and **T-R2** are Cache B, not Cache A — they belong to the Caps Lock defect
   and its own pull request, [#16423][p16423], not to this branch. Do not let the two be merged in
   discussion; that conflation is what kept #8064 open.

---

[TEST-PLAN.md]: TEST-PLAN.md
[MODIFIERS.md]: MODIFIERS.md
[TRIGGER.md]: TRIGGER.md
[TODO.md]: TODO.md
[todo]: TODO.md
[README.md]: README.md
[tp]: TEST-PLAN.md
[p16423]: https://github.com/keymanapp/keyman/pull/16423

[i8064]: https://github.com/keymanapp/keyman/issues/8064
[i1620]: https://github.com/keymanapp/keyman/issues/1620
[i4884]: https://github.com/keymanapp/keyman/issues/4884
[i7337]: https://github.com/keymanapp/keyman/issues/7337
[i15065]: https://github.com/keymanapp/keyman/issues/15065
[#16422]: https://github.com/keymanapp/keyman/issues/16422
[#16423]: https://github.com/keymanapp/keyman/issues/16423
[i16423]: https://github.com/keymanapp/keyman/issues/16423
[p15179]: https://github.com/keymanapp/keyman/pull/15179
[p15219]: https://github.com/keymanapp/keyman/pull/15219
[kb2466]: https://github.com/keymanapp/keyboards/issues/2466
[rc1]: https://github.com/user-attachments/files/23785348/RC_Logs_1.zip
[rc2]: https://github.com/user-attachments/files/23785339/RC_logs_2.zip
[c1620]: https://github.com/keymanapp/keyman/commit/eb92df40de
[c7337]: https://github.com/keymanapp/keyman/commit/90eb7c77ec
[c8516]: https://community.software.sil.org/t/keyman-causing-windows-10-to-crash/8516
[c8777]: https://community.software.sil.org/t/8777
[c9977]: https://community.software.sil.org/t/vedic-sanskrit-keyboard-continuously-presses-alt-key-on-windows-11/9977

[llh200]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/k32_lowlevelkeyboardhook.cpp#L200
[wd]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/LowLevelHookWatchDog.cpp#L6
[ff]: https://github.com/keymanapp/keyman/tree/master/windows/src/support/fakefreeze
[vcx]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/tests/keyman32.tests.vcxproj
[raec]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/tests/RightAltEmulationCheck.tests.cpp
[kmxp]: https://github.com/keymanapp/keyman/blob/master/core/src/kmx/kmx_processor.cpp#L263
[capi]: https://github.com/keymanapp/keyman/blob/master/core/include/keyman/keyman_core_api.h
