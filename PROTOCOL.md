# Keyman 18.0.245 watchdog regression - test protocol

Hypothesis under test: the `LowLevelHookWatchDog` added in **18.0.245**
(commit `83251358b0`) tears out and reinstalls `WH_KEYBOARD_LL` on a healthy
system, and a modifier KEYUP lost in that gap permanently corrupts
`m_ModifierKeyboardState[]` in `serialkeyeventserver.cpp`, producing
"Keyman keyboard active, no text output, looks like Alt is held".

Machine state as of setup: **Keyman 18.0.238** (no watchdog) = CONTROL.

---

## Vocabulary

| Term | Meaning |
|---|---|
| CONTROL | Keyman <= 18.0.244. `LowLevelHookWatchDog` does not exist. |
| TREATMENT | Keyman >= 18.0.245. Watchdog present. |
| Ghost key | `PostMessage(WM_KEYDOWN)` - seen by Keyman's GetMessage hook, invisible to the LL hook. |
| Phantom modifier | `GetAsyncKeyState` says a modifier is down while the keyboard is idle. |

## Why a ghost key is the trigger

```
LastLowLevelEventTick   <- stamped by the WH_KEYBOARD_LL hook proc
LastGetMessageEventTick <- stamped when keyman.exe drains KMC_WATCHDOG_KEYEVENT,
                           posted by kmnGetMessageProc on EVERY WM_KEYDOWN
if (LastGM - LastLL) >= 1000ms  ->  Unhook + SetWindowsHookEx on WH_KEYBOARD_LL
```

A `PostMessage`d `WM_KEYDOWN` bumps `LastGM` but never `LastLL`. Send one after
1000ms+ of keyboard idle and the arithmetic says "hook is dead" even though it
is perfectly alive. Real software does this constantly - RDP/Citrix clients, VM
consoles, macro tools, some accessibility software - and so does any app that
stalls its message pump for a second and then drains a backlogged keydown.
**FieldWorks, doing per-keystroke decomposition, is exactly that app.**

---

## Setup (once)

Run everything from `powershell -ExecutionPolicy Bypass -File kmrepro.ps1 <Cmd>`.

```
kmrepro.ps1 Status                 # confirm version / master controller window
kmrepro.ps1 Arm -HookTimeout 200   # enables Keyman ETW logging + shortens LL hook timeout
```
Then **sign out and back in** (required for `LowLevelHooksTimeout`), and restart Keyman.

`Arm` writes exactly two values, both undone by `Disarm`:
- `HKCU\Software\Keyman\Keyman Engine\debug = 1` (Keyman's ETW logging switch)
- `HKCU\Control Panel\Desktop\LowLevelHooksTimeout = 200`

Shortening `LowLevelHooksTimeout` makes Windows evict a slow LL hook aggressively.
It does not create the bug; it raises the hit rate of a race that is already there.

Logging, in an **elevated** shell:
```
kmrepro.ps1 TraceStart    # 64MB circular ring - never grows, leave it for days
... reproduce ...
kmrepro.ps1 TraceStop
```

---

## Run 1 - CONTROL (do this NOW, before upgrading)

You are on 18.0.238. Capture the baseline first; you cannot get it back after
the upgrade without a downgrade.

Run every experiment below and record the results. Expected on CONTROL:
**zero** phantom modifiers, **zero** hook reinstalls. `Freeze` is an inert no-op
(command 20 is unassigned before 18.0.245) - that itself confirms the plumbing
is version-gated rather than misfiring.

---

## Experiment A - forced freeze (stuck modifier, wide window)

Tests the *pre-existing* #8064 race that 18.0.245 tried to fix, and whether the
watchdog's recovery makes it better or worse.

1. Window 1: `kmrepro.ps1 ModWatch`
2. Focus **Notepad**, select the Ngoreme Keyman keyboard, type `abc` so the
   process is hooked and `_td->FInitialised` is set.
3. Window 2: `kmrepro.ps1 Freeze`   (keyman.exe main thread sleeps 5s)
4. Within those 5 seconds: **hold Left Shift**, type `abc`, **release Left Shift**.
5. Wait 5s. Read ModWatch.

| Observation | Meaning |
|---|---|
| `[STUCK] LShift DOWN ... PHANTOM MODIFIER` | modifier KEYUP was lost - the core failure |
| Typing now produces nothing / wrong case | user-visible symptom reproduced |
| Nothing logged | freeze window missed; retry, or lower `-HookTimeout` |

Repeat with **Left Alt** - that is the variant your users describe.

## Experiment B - ghost key (the 18.0.245 regression proper)

Tests whether a *healthy* hook gets torn out. This is the differential test.

1. Elevated shell: `kmrepro.ps1 TraceStart`
2. Focus Notepad with the Keyman keyboard, type one character.
3. **Hands off the keyboard.** `kmrepro.ps1 GhostKey -Count 20 -IdleMs 1500`
4. `kmrepro.ps1 TraceStop`, then decode and search the trace.

| Result | Meaning |
|---|---|
| `Attempting to reinstall hook because watchdog threshold exceeded` | **CONFIRMED** - healthy hook torn out on demand |
| `Attempt to reinstall low level hook may have failed` | worse - Keyman now has no LL hook at all until restart |
| nothing (CONTROL run) | correct baseline; the code does not exist |

If B fires on TREATMENT and is silent on CONTROL, the regression is proven,
independent of whether you catch a stuck modifier.

## Experiment C - soak (the real-world model)

The one that should reproduce your users' failure without any freeze at all.

1. Elevated shell: `kmrepro.ps1 TraceStart`
2. Window 1: `kmrepro.ps1 ModWatch`
3. Focus **FieldWorks**, Ngoreme keyboard, in a real vernacular field.
4. Window 2: `kmrepro.ps1 Soak -Minutes 30 -IntervalMs 2500`
5. Go back to FieldWorks and **type naturally for 30 minutes** - normal typing,
   normal Shift use for capitals, normal pauses. Do not baby it.
6. Watch for output stopping. When it does, run the triage below *before*
   restarting anything.

Soak forces a hook reinstall roughly every 2.5s during your natural typing
pauses. Each one is a chance to swallow a modifier KEYUP. If the hypothesis is
right, a stuck modifier should appear within minutes on TREATMENT and never on
CONTROL.

---

## Triage - run this the moment output stops

Do it in this order. It separates the two failure modes, and step 2 may be a
field workaround you can give users today.

1. **Does Notepad also fail?**
   - Yes -> system-wide (Keyman engine). No -> FieldWorks-specific (TSF/kmtip).
2. **Tap each modifier once**: LShift, RShift, LCtrl, RCtrl, LAlt, RAlt.
   - Typing recovers -> stuck `m_ModifierKeyboardState`. The LL hook is alive.
     A physical press+release posts `WM_KEYMAN_MODIFIER_EVENT` for both edges and
     clears the byte (`serialkeyeventserver.cpp:581`). **Tell users to try this
     instead of restarting Keyman.**
   - No recovery -> go to 3.
3. **Does a Keyman hotkey still work** (e.g. the keyboard-switch hotkey)?
   - No -> the LL hook is gone entirely; `InitLowLevelHook()` failed and there
     is no retry path. Only a Keyman restart fixes it.
4. **Check ModWatch** for a phantom modifier, and the ETW trace for
   `m_ModifierKeyboardState=[LS:.. LC:.. LA:.. RS:.. RC:.. RA:..]`.
   - Non-zero byte in the log while ModWatch shows nothing down -> phantom lives
     only in Keyman's cache.
   - Both show it down -> `keybd_shift_reset()` has injected a real phantom
     KEYDOWN into Windows' own keyboard state.

That last distinction is the single most valuable measurement in the whole
exercise - it tells the Keyman team exactly which side of the fence to fix.

---

## Recording results

For each run note: Keyman version, experiment, ghost keys posted, reinstalls
seen in the trace, phantom modifiers seen, whether typing failed, and which
triage step recovered it. A one-line-per-run table is enough for a bug report.

`kmrepro.ps1` appends everything to `%TEMP%\kmrepro\kmrepro.log`.

## Teardown

```
kmrepro.ps1 TraceStop      # elevated
kmrepro.ps1 Disarm
```
then sign out and back in to restore the default `LowLevelHooksTimeout`.
