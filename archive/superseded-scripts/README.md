# ARCHIVED — superseded harness scripts

Archived 2026-08-25. **Do not quote numbers from these.** Use `kmproof.ps1`,
`kmmods.ps1` and `kmaltgr.ps1` in the repository root.

All five carry at least one of the two harness hazards found the hard way
(`TRIGGER.md` §2 "Harness traps", `HAZARDS.md` §1). Archiving them closes
`TODO.md` **H4** — "propagate the known harness traps to the older scripts" — by
removing its subject rather than by fixing five dead scripts.

| script | was | why archived |
|---|---|---|
| `kmhunt.ps1` | probe → action → probe trigger hunt. **Historically the instrument that first found the wedge** | Single keyboard, so it cannot *attribute* the wedge — with one keyboard you cannot separate Keyman from the layout, from Windows, or from the harness. Superseded by `kmproof.ps1`'s three-arm design. Also resolves the HKL from the top-level window and uses `Write-Host` |
| `kmflex.ps1` | FieldWorks driver — clicking between an Ngoreme and an English field as a keyboard-switch vector | FieldWorks testing is **out of scope** (`TEST-PLAN.md` §7) and `HAZARDS.md` §2 records real lexical-data corruption caused by it. Same two hazards |
| `kmshot.ps1` | screen capture + positional click, for targets UI Automation cannot read | Only ever used by `kmflex.ps1` |
| `kmwedge.ps1` | early wedge rig | Structured on the wrong assumption — trigger inside each iteration |
| `kmstick.ps1` | earliest stuck-key probe | Superseded wholesale |

**Why `Write-Host` is a correctness hazard, not a speed one:** measured on this
machine with a congested console, `Write-Host` costs **4301 ms/line** versus
`[Console]::Out.WriteLine` at 0.4 ms. Multi-second dead time can let a 5 s freeze
expire before the probe runs, silently turning a trial into a no-freeze control.

**Why the top-level-window HKL is wrong:** Windows 11 Notepad's frame window sits
on a thread pinned at `0x0409` forever, while the focused edit control is on a
different thread that tracks the input locale correctly. Resolve from
`GetGUIThreadInfo(0).hwndFocus` instead.

## `logs/`

The output of these scripts, moved here with them so nothing left in the live
`logs/` directory carries a measurement hazard.

| file | from |
|---|---|
| `hunt.txt` | `kmhunt.ps1` — the original discovery run. Historically important, **not citable** |
| `stick-LShift.txt` | `kmstick.ps1` — the minimal no-typing probe. A negative control: it does **not** reproduce, which is what bounds the minimal recipe |
| `wedge-18_0_249_0-LShift.txt`, `wedge-18_0_249_0-RAlt.txt` | `kmwedge.ps1` |
