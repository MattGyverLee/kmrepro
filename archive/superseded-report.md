# Summary — Keyman stuck-modifier wedge

Investigated on **Keyman for Windows 18.0.249.0**, Windows 11 Pro 26200, against
`sil_cameroon_qwerty` in Notepad.

Full write-up: **`TRIGGER.md`** (§3 is the controlled proof). Fix: `FIX-PROPOSAL.md`.

## What happens

A modifier key's KEYUP is released while keyman.exe's main thread — the thread
that owns the `WH_KEYBOARD_LL` hook — is blocked. Keyman never observes the
release, its cached modifier state stays latched, and `keybd_shift_reset()` then
re-presses that modifier *for real* ahead of every injected batch, with no
matching KEYUP.

## Minimal repro

`kmproof.ps1` — a three-keyboard controlled test. `kmhunt.ps1` is the earlier
single-keyboard version; it can show the wedge but cannot attribute it, because
with one keyboard you cannot separate Keyman from the layout, from Windows, or
from the harness.

```powershell
cd D:\Github\_Projects\_KM\kmrepro
.\kmproof.ps1 -Sweep -SweepTrials 1 -LoadThreads 4   # shortest end-to-end demo
.\kmproof.ps1 -ChargeTest 3 -LoadThreads 4           # the decisive experiment
```

Roughly 90 seconds for the sweep. It walks US English, the Microsoft Cameroon
QWERTY 2017 clone and the Keyman Cameroon keyboard, triggering on each, then
walks all three again applying nothing, then clears and walks them once more.

## What is established

**Cause is Keyman's alone.** Under an identical trigger, identical load and the
same layout, the Microsoft implementations are untouched:

| arm | trials | wedged |
|---|---|---|
| US English (`00000409`) | 10 | 0 |
| MS Cameroon QWERTY 2017 (`a0000436`) | 10 | 0 |
| switch-only, no stall (control) | 10 | 0 |
| Keyman `sil_cameroon_qwerty` | — | wedges |

The two Cameroon keyboards are output-identical when working (both `U+0259 U+014B`
for `;e`+RAlt+N), so the layout cannot account for the difference.

**The cache is corrupted even when no Keyman keyboard is active.** Five triggers
applied while the *Microsoft* layout is active leave its output byte-perfect
(0/15 disturbed), then switching to Keyman reveals it already wedged — **3/3,
deterministic**. Verified in source: the `WM_KEYMAN_MODIFIER_EVENT` post at
`k32_lowlevelkeyboardhook.cpp:198` is not gated on `isKeymanKeyboardActive`,
whose pass-through check sits 35 lines later at `:233`.

**Consequence is machine-wide.** Once wedged, every keyboard on the machine is
affected with no trigger applied to it, because the phantom Shift is genuinely
held as far as Windows is concerned. `Ctrl+A` is delivered as `Ctrl+Shift+A` in
unrelated applications. This is a system-wide stuck Shift, not a Keyman-typing
glitch — and it explains field reports of "the whole machine went strange".

**It is recoverable.** A KEYUP for each of the six modifiers clears it, as does
ordinary physical typing. Not a permanent state.

## What is not established

- The **field path** that stalls the hook thread. The repro induces it with
  `KMC_WATCHDOG_FAKEFREEZE`, a debug-only command. Mechanism proven, field
  trigger not.
- Whether **physical** keystrokes behave as injected ones do. Keyman can
  distinguish them (`LLKHF_INJECTED`, `dwExtraInfo`).
- Why the field symptom **persists until a Keyman restart** when reproduced
  wedges clear on a modifier edge. Possibly a second factor.
- The **watchdog hypothesis is unsupported** — the `LowLevelHookWatchDog` ghost
  key was absent from every reproducing run.
