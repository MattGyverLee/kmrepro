# Cache B — the un-read modifier/toggle state bug

> Split out of the parent [kmrepro](../README.md) investigation. This is a
> **different defect** from the stuck-modifier bug ([#8064]) that repo is about —
> different cache, different symptom, different fix. Keep them apart.
>
> [#8064]: https://github.com/keymanapp/keyman/issues/8064
> [#16422]: https://github.com/keymanapp/keyman/issues/16422
> [#16423]: https://github.com/keymanapp/keyman/issues/16423

---

## 4. The un-read-state bug: Caps, Num, and the five modifiers

Separate defect, separate cache (B), no phantom keypress — the symptom is wrong
output or no output while every physical key is genuinely up.

Cache B's toggle flags are written by `ProcessToggleChange` (`aiTIP.cpp:102-118`),
which runs **only when Keyman observes a Caps/NumLock keydown**. Miss that event
— blocked hook, another keyboard active, another app calling `keybd_event`, lock
screen — and `CAPITALFLAG` is stale. That is the Caps Lock bug, and **#16423**.

There are two resync helpers, and the coverage between them is uneven:

```
RefreshToggleState()        capsstate.cpp:39   -> CAPITAL, NUMLOCK           (2 flags)
GetCapsAndNumlockState()    kmhook_getmessage.cpp:418
                                               -> RefreshToggleState()
                                                  + K_SHIFT, L/RCTRL, L/RALT (7 flags)
```

Call sites:

| trigger | handler | flags resynced |
|---|---|---|
| keyboard activated (`TIPActivateKeyboard`, `aiTIP.cpp:73`, deferred to next key event at `:186` — **this is #16422**) | `RefreshToggleState()` | **2** — Caps, Num only |
| focus moves to a different window (`KM_FOCUSCHANGED` + `KMF_WINDOWCHANGED` + `IsFocusedThread`, `kmhook_getmessage.cpp:357`) | `GetCapsAndNumlockState()` | **7** |

`GetCapsAndNumlockState` is called from **exactly one place**. So:

### Finding 4a — #16422's resync is two flags short of its own sibling set

A keyboard switch resyncs Caps and Num but leaves `K_SHIFTFLAG`, `LCTRLFLAG`,
`RCTRLFLAG`, `LALTFLAG`, `RALTFLAG` stale. Same bug, same cache, same trigger,
one field over — the fix is to call `GetCapsAndNumlockState()` (or factor out its
modifier half) from the `FToggleStateRefreshRequired` branch at `aiTIP.cpp:186-189`
instead of `RefreshToggleState()`.

Note the naming is why this was easy to miss: the function that resyncs *all five
modifiers* is called `GetCapsAndNumlockState`.

### Finding 4b — both helpers use the wrong API for the modifier half

`GetCapsAndNumlockState` tests modifiers with `GetKeyState(...) < 0`
(`:423-436`). `GetKeyState` reports the **calling thread's processed input
queue** — which is precisely the thing that is stale after events were dropped.
The correct oracle for "is this key physically down right now" is
`GetAsyncKeyState`.

For the toggle bits (`GetKeyState(...) & 1`) `GetKeyState` is fine — toggles are
not queue-dependent in the same way. It is only the five `< 0` modifier tests
that ask the wrong source.

### Finding 4c — Shift has no L/R split in Cache B, Ctrl and Alt do

`ProcessModifierChange` (`kmhook_getmessage.cpp:453-457`):

```c
case VK_SHIFT:   flag = K_SHIFTFLAG; break;                        // one flag
case VK_MENU:    flag = isExtended ? RALTFLAG  : LALTFLAG;  break; // two
case VK_CONTROL: flag = isExtended ? RCTRLFLAG : LCTRLFLAG; break; // two
```

This makes Cache B **more** robust for Shift (any Shift release clears the only
flag) and **less** robust for Ctrl and Alt (L and R latch independently, and a
left-side release cannot clear a right-side latch). Another reason the right-hand
modifiers are the ones that get stuck, and consistent with the field reports
being about RAlt and Right Ctrl rather than the left-hand keys.

---

---

## Why this is not the stuck-modifier bug

From [`../MODIFIERS.md`](../MODIFIERS.md) §1 — the distinction the parent repo
exists to maintain:

| | **Cache A** — `m_ModifierKeyboardState[256]` | **Cache B** — `Globals::ShiftState()` |
|---|---|---|
| where | `serialkeyeventserver.cpp:51` | `k32_globals.cpp`, a DWORD bitfield |
| holds | 6 bytes: L/R Shift, Ctrl, Alt | K_SHIFT, L/RCTRL, L/RALT + **CAPITAL, NUMLOCK** |
| written by | `UpdateLocalModifierState` (`:554`) | `ProcessModifierChange` (`kmhook_getmessage.cpp:450`), `ProcessToggleChange` (`aiTIP.cpp:102`) |
| seeded | `GetKeyboardState` **once**, `InitThread` `:251` | — |
| resynced from OS | **never** | `GetCapsAndNumlockState()` (`kmhook_getmessage.cpp:418`) |
| what corruption does | **injects real phantom keypresses system-wide** | wrong rule matching: wrong case, or no output |
| upstream issue | [#8064] | [#16422] / [#16423] |

Cache A is re-asserted as **real key events** by `keybd_shift_reset()`, so it
latches the whole machine. Cache B only makes Keyman mis-map. Same staleness
shape, very different severity.
