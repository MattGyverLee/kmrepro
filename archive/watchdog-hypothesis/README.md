# ARCHIVED — the LowLevelHookWatchDog hypothesis

**Archived 2026-08-25. The hypothesis in this folder was tested and NOT supported.**
Nothing here should be presented as a current finding. It is kept because a
negative result is only citable with its raw evidence attached.

## The hypothesis

That the `LowLevelHookWatchDog` added in Keyman **18.0.245** (commit `83251358b0`,
PRs [#15179] / [#15219]) was itself the cause: that it tears the `WH_KEYBOARD_LL`
hook out and reinstalls it, and that a keystroke landing in that window is lost.

The rig tested it with a **ghost key** — a synthetic keystroke posted while
keyman.exe was unresponsive, intended to provoke Windows into uninstalling the
hook so the watchdog would reinstall it.

## The verdict

**Not supported.** The ghost key was absent from every reproducing run.

| arm | ghost key | freeze | CPU load | iters | failures |
|---|---|---|---|---|---|
| Ghost | yes | no | 0 | 27 | **0** |
| Load only | no | no | 32 | 10 | **0** |
| Freeze | no | **yes** | 0 | 10 | **10** |
| Freeze + load | no | **yes** | 32 | 10 | **10** |

Source: `RESULTS-treatment-18.0.249.md`, Addendum 2. `RESULTS-control-18.0.238.md`
is the pre-watchdog control — all clean, which is consistent with the watchdog
being irrelevant rather than protective.

This is **corroboration, not just a retraction**: mcdurdin reached the same
conclusion independently on 2026-05-26 on [#8064] — *"@rc-swag notes that stuck key
logs still have lowlevelkeyboardproc messages, so this probably does not resolve
that issue."* A bot auto-closed #8064 on the strength of #15219; Marc reopened it.

## What the null result did establish, and where it now lives

Three things survived and were promoted out of this folder before it was archived.
Cite the live document, not this one:

| finding | now lives in |
|---|---|
| **Load is not the mechanism.** 32 CPU hogs on 16 cores: 0/10. Freeze alone at zero load: 10/10 | `TEST-PLAN.md` §1 (table reproduced inline) |
| **The freeze is the mechanism**, and it must coincide with a modifier **KEYUP** | `TRIGGER.md` §2, `MODIFIERS.md` §2b |
| The stimulus is a `Sleep(5000)` on the hook-owning UI thread, reachable without a debug build | `TEST-PLAN.md` §1 (`fakefreeze`, P0) |

## Contents

| file | what |
|---|---|
| `PROTOCOL.md` | the test protocol written for this hypothesis |
| `RESULTS-control-18.0.238.md` | control baseline, pre-watchdog build. All clean |
| `RESULTS-treatment-18.0.249.md` | the treatment run. Watchdog confirmed present and live; the hypothesised failure did not reproduce in 45 iterations. **Addendum 2 is the load/freeze table above** |
| `HANDOFF.md` | handoff doc framed on this hypothesis. Its live content was extracted first — hazards and safety rules to `HAZARDS.md`, secondary suspects and the ruled-out list to `TODO.md` §1 / §1a |
| `kmrepro.ps1` | the rig. `Status`, `Arm`, `Freeze`, `GhostKey`, `ModWatch`, `Soak`, `AutoTest`. Carries both known-bad harness patterns (top-level-window HKL, `Write-Host`) |
| `logs/*-Ghost.txt` | the ghost-key arm's raw logs — **the null result's evidence** |
| `logs/*-Clean.txt`, `*-Freeze.txt`, `baseline-*.txt` | the rig's other arms, moved here with it. The `-Freeze` runs are the 10/10 rows in the table above; the `-Clean` runs are the switch-only control |

`kmrepro.ps1 Status` was the only mode with residual value, for build
identification. It is one line and needs no script:

```powershell
(Get-Item "${env:ProgramFiles(x86)}\Keyman\Keyman Desktop\keyman.exe").VersionInfo.FileVersion
```

The freeze stimulus it posted is implemented independently, and correctly, in both
live scripts (`kmproof.ps1` / `kmmods.ps1`, `Freeze` + `WaitForFreeze` — the async
`PostMessage` is confirmed to have landed before the trial proceeds, which
`kmrepro.ps1` did not do).

[#8064]: https://github.com/keymanapp/keyman/issues/8064
[#15179]: https://github.com/keymanapp/keyman/pull/15179
[#15219]: https://github.com/keymanapp/keyman/pull/15219
