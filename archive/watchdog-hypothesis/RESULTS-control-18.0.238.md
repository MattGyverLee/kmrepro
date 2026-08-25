# CONTROL BASELINE - Keyman 18.0.238 (no watchdog)

Captured 2026-08-22 16:10-16:25. Machine: Win11 Pro 26200. Target: Notepad.
Keyboard: `sil_cameroon_qwerty` (Keyman TIP, HKL `0x04092000`, langid `0x2000`).
`LowLevelHooksTimeout` = Windows default. Keyman ETW logging = off.

## Keyman-engagement proof

Every run gates on two characters that the Windows US layout cannot produce:

| probe | keys | expected | got |
|---|---|---|---|
| deadkey | `;` `e` | U+0259 SCHWA | `ə` |
| ralt | RAlt(extended) + `N` | U+014B ENG | `ŋ` |

Both produced on every run, so Keyman was confirmed in the input path.
(The `shift` probe `abcDEFghi` is *not* engagement proof - the plain US layout
produces the same string. It is the stuck-modifier detector only.)

## Results

| scenario | iterations | failures | no-output | phantom modifiers | keyman unresponsive |
|---|---|---|---|---|---|
| Baseline / ghost burst | 20 posts | - | - | **0** | **0** |
| AutoTest Clean | 3 | **0** | 0 | **0** | - |
| AutoTest Ghost | 15 | **0** | 0 | **0** | - |
| AutoTest Freeze | 15 | **0** | 0 | **0** | - |

Combined expected string `abcDEFghiəŋ` reproduced exactly on all 33 AutoTest
iterations.

## Key control observations

1. **`KMC_WATCHDOG_FAKEFREEZE` (cmd 20) is INERT on 18.0.238.** Posting it and
   then measuring `SendMessageTimeout(WM_NULL)` returned in 0 ms. On 18.0.245+
   the same post must block keyman.exe's main thread for ~5 s. This single
   measurement is a clean version discriminator.
2. **Ghost keys are harmless on 18.0.238.** 15 iterations of
   `PostMessage(WM_KEYDOWN)` after >1.5 s keyboard idle produced zero phantom
   modifiers and zero output corruption, because `LowLevelHookWatchDog` does not
   exist in this build. Any failure of this scenario on 18.0.245+ is therefore
   attributable to the watchdog, not to the ghost key itself.
3. keyman.exe responsiveness: 0-8 ms across all samples.

## What this baseline licenses

Re-run the identical commands on 18.0.245+ and any non-zero cell in the table
above is a regression introduced between 18.0.238 and that build. The
`autotest-*.txt` reports in `%TEMP%\kmrepro\` are directly diffable.

```
kmrepro.ps1 Baseline -Count 20
kmrepro.ps1 AutoTest -Scenario Clean  -Iterations 3
kmrepro.ps1 AutoTest -Scenario Ghost  -Iterations 15
kmrepro.ps1 AutoTest -Scenario Freeze -Iterations 15
```

## Automation coverage

| step | automated? | note |
|---|---|---|
| detect Keyman keyboard active | yes | thread HKL langid `0x2000` |
| synthesize physical keystrokes | yes | `keybd_event`, `dwExtraInfo=0` so Keyman treats them as real |
| right-Alt as distinct from left-Alt | yes | `KEYEVENTF_EXTENDEDKEY`; Keyman splits L/R Alt on that bit alone |
| read output text back | yes (Notepad) | UI Automation `ValuePattern` on `RichEditD2DPT` |
| detect phantom modifier | yes | `GetAsyncKeyState` while keyboard idle |
| detect keyman.exe frozen | yes | `SendMessageTimeout(WM_NULL)` |
| localise which rule broke | yes | per-segment re-run on failure |
| test modifier-tap workaround | yes | taps all 6 modifiers, re-probes, records recovery |
| **read output text in FieldWorks** | **NO** | UIA exposes zero Document/Edit/Text elements inside FLEx; its RootSite view is custom-drawn. Needs human eyes. |
| ETW ring trace | needs elevation | one elevated shell, `TraceStart` / `TraceStop` |
| the upgrade itself | no | manual |

FieldWorks caveat: the phantom-modifier oracle and the ETW log still work there,
so the *cause* is detectable in FLEx automatically - only the *symptom*
("no text appeared") needs a person. **Nothing has been typed into FieldWorks**;
doing so writes to real Ngoreme language data and needs explicit approval.

---

# FieldWorks control baseline (added later)

Test entry: headword **Ngq**, entry 698/2234.
Citation Form (Ngq writing system) = `Ngq`; Note (Eng writing system) = `Eng`.

Each iteration types into the live fields, reads back via clipboard, and
backspaces what it typed. The entry was byte-identical before and after all
12 iterations.

## Per-iteration sequence

| step | field | keys | expected |
|---|---|---|---|
| 1 | Citation Form (Ngq) | `;` `e` | U+0259 `ə` |
| 2 | Citation Form (Ngq) | RAlt(ext)+`N` | U+014B `ŋ` |
| 3 | **click** Note (Eng) | `;` `e` | literal `;e` |
| 4 | **click back** Citation Form (Ngq) | `;` `e` | U+0259 `ə` |
| 5 | Citation Form (Ngq) | RAlt(ext)+`N` | U+014B `ŋ` |

Steps 4-5 are the #15055 vector: does the Keyman keyboard still work after
switching away to a Microsoft layout and back?

## Results - Keyman 18.0.238

| scenario | iterations | failures | phantom modifiers |
|---|---|---|---|
| Clean  | 2 | **0** | **0** |
| Ghost  | 5 | **0** | **0** |
| Freeze | 5 | **0** | **0** |

All 12 iterations produced `ə` and `ŋ` both before and after the keyboard
switch, and literal `;e` in the English field.

## Findings about FLEx automation (hard-won)

1. **Clicking a field DOES switch the keyboard.** Proven behaviourally: the Eng
   field returns literal `;e` while the Ngq field returns `ə`.
2. **Tab is NOT usable for the switch.** Tabbing past an entry's last field
   advances to the NEXT RECORD. On this minimal test entry a fixed tab count
   walked straight out of entry 698 into 699. Absolute clicks cannot drift.
3. **`GetKeyboardLayout()` does not track TSF profile switches.** After landing
   in the Eng field it still reported the Keyman HKL `0x04092000` while the FLEx
   writing-system combo had already flipped to "English". Never use the HKL as
   the oracle - type and read back instead.
4. **Never send Home/End/Ctrl+A inside a RootSite view.** They navigate the whole
   record, not the field.
5. **Never collapse a selection with the Right arrow at end-of-field.** It moves
   to the next field, so every read silently advanced the caret. Delete the
   selection with a single Backspace instead - that is atomic and leaves the
   caret where it started.
6. **Navigation keys must carry `KEYEVENTF_EXTENDEDKEY`.** Unextended, Left's
   scan code `0x4B` is numpad-4, Right `0x4D` is numpad-6, Home `0x47` is
   numpad-7 - so they insert characters instead of moving the caret. This one
   corrupted live data twice before it was found.

## Commands to re-run on 18.0.245+

```
kmflex.ps1 Switch -Scenario Clean  -Iterations 2
kmflex.ps1 Switch -Scenario Ghost  -Iterations 5
kmflex.ps1 Switch -Scenario Freeze -Iterations 5
```
Field coordinates are `-RelX 1000 -RelY 325` (Ngq) and `-EngX 1000 -EngY 490`
(Eng); re-check them with `Shot` if the entry layout changes.
