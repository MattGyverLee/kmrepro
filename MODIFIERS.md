# Which modifier keys can this bug actually stick?

Scope question raised after the Shift / RAlt work: the repro so far has only
exercised **LShift** and **RAlt**. What about Ctrl, Caps Lock, Num Lock, Scroll
Lock, Win, Fn, Insert? And in particular:

> Can any of this explain a machine with **no physical Right Ctrl key** reporting
> Right Ctrl as stuck?

**Yes — completely, and it is the cleanest example of the bug there is.** Details
in §3. Code refs are from `fix/windows/16422-caps-lock-state-on-keyboard-switch`
at `a70538106c`, paths relative to `windows/src/engine/keyman32/`.

---

## 1. There are two separate caches, not one

The investigation so far has been about one cache. There are two, with different
contents, different failure modes, and different resync coverage. Keeping them
apart is the whole of this document.

| | **Cache A** — `m_ModifierKeyboardState[256]` | **Cache B** — `Globals::ShiftState()` |
|---|---|---|
| where | `serialkeyeventserver.cpp:51` | `k32_globals.cpp`, a DWORD bitfield |
| holds | 6 bytes: L/R Shift, Ctrl, Alt | K_SHIFT, L/RCTRL, L/RALT + **CAPITAL, NUMLOCK** |
| written by | `UpdateLocalModifierState` (`:554`) | `ProcessModifierChange` (`kmhook_getmessage.cpp:450`), `ProcessToggleChange` (`aiTIP.cpp:102`) |
| seeded | `GetKeyboardState` **once**, `InitThread` `:251` | — |
| resynced from OS | **never** | `GetCapsAndNumlockState()` (`kmhook_getmessage.cpp:418`) — see §4 |
| what corruption does | **injects real phantom keypresses system-wide** | wrong rule matching: wrong case, or no output |

Cache A is the dangerous one, because it is not merely consulted — it is
**re-asserted as real key events** by `keybd_shift_reset()`. Cache B only makes
Keyman mis-map; Cache A makes the whole machine behave as if a key were held.

---

## 2. Exactly six keys are in scope for the phantom-press bug

Cache A is fed only through `isModifierKey()` (`k32_lowlevelkeyboardhook.cpp:62`),
which returns TRUE for **nine VKs collapsing to six slots** and nothing else:

```
VK_LCONTROL VK_RCONTROL VK_CONTROL
VK_LMENU    VK_RMENU    VK_MENU
VK_LSHIFT   VK_RSHIFT   VK_SHIFT
```

`UpdateLocalModifierState` reinforces this with `default: return;` (`:578`), and
both `keybd_shift_release` / `keybd_shift_reset` iterate the same hardcoded six:

```c
const BYTE modifiers[6] = { VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT };
```

So the scope boundary is provable from code, not inferred:

| key | in Cache A? | can be phantom-pressed? | verdict |
|---|---|---|---|
| L/R **Shift** | yes | yes | **vulnerable** — demonstrated |
| L/R **Alt** | yes | yes | **vulnerable** — demonstrated (RAlt) |
| L/R **Ctrl** | yes | yes | **vulnerable — never tested. See §3.** |
| **Caps Lock** | no | no | immune to phantom press; has its own bug (§4) |
| **Num Lock** | no | no | immune to phantom press; has its own bug (§4) |
| **Scroll Lock** | no | no | **immune.** `VK_SCROLL` appears nowhere in keyman32 |
| **Win** (L/R), **Apps** | no | no | **immune.** `VK_LWIN`/`VK_RWIN`/`VK_APPS` appear nowhere in keyman32; Keyman's `.kmn` modifier vocabulary has no Win either |
| **Fn** | no | no | **immune by construction.** Fn is resolved in keyboard firmware/EC and does not surface to Windows as a virtual key on essentially all hardware |
| **Insert** | no | no | immune — but see §5, there is a registry footgun nearby |

**Practical consequence.** The user-facing symptom set is bounded: a stuck Shift,
Ctrl or Alt, either side. A report of "stuck Caps Lock" or "stuck Num Lock" is a
*different* defect (§4), and a report of "stuck Win key" or "stuck Fn" is not this
bug at all — Keyman never touches those keys.

---

## 3. Right Ctrl on a keyboard with no Right Ctrl key

This is the highest-value case, because it is the one where the phantom is
provably **not** hardware and provably **not** self-healing.

### 3a. The press is synthesized in software

`keybd_shift_reset()` (`keybd_shift.cpp:161-176`) emits, for every byte in Cache A
sitting at `0x80`, a KEYDOWN **with no matching KEYUP**. For `VK_RCONTROL`,
`do_keybd_event()` (`keybd_shift.cpp:69-73`) rewrites it:

```c
case VK_RCONTROL:
  flags |= KEYEVENTF_EXTENDEDKEY;
  /*fallthrough*/
case VK_LCONTROL:
  vk = VK_CONTROL;
  break;
```

`VK_CONTROL` + `KEYEVENTF_EXTENDEDKEY` is precisely the byte pattern Windows
resolves to Right Ctrl. After `SendInput`, `GetAsyncKeyState(VK_RCONTROL) < 0`
**system-wide, on hardware that has no Right Ctrl key.** No physical key is
involved at any point. The phantom is entirely Keyman's own injection.

### 3b. And the user cannot clear it

The documented workaround — "tap each of Shift, Ctrl, Alt once, both sides" —
works because a genuine physical KEYUP reaches `UpdateLocalModifierState` and
writes `0`. The clearing event for the `VK_RCONTROL` slot is specifically
`VK_CONTROL` + extended + KEYUP.

**A user with no Right Ctrl key cannot produce that event.** The workaround is
unavailable for exactly this key on exactly this hardware, and Cache A has no
other resync path — it is seeded once at `:251` and never re-read. The only exit
is restarting Keyman.

This closes a gap `FIX-PROPOSAL.md` currently lists as unexplained: *"The field
reports describe persistence until a Keyman restart; that gap is unexplained."*
For L/R Shift and L/R Alt the wedge self-heals on the next physical tap, which is
why the repro kept seeing it clear. For a missing-key modifier it cannot heal.
**Persistence-until-restart is expected behaviour when the latched key does not
physically exist.**

### 3c. Worse: the latch re-arms itself

The modifier post at `k32_lowlevelkeyboardhook.cpp:198` runs **35 lines before**
the filter at `:233` that discards Keyman's own events
(`hs->dwExtraInfo != 0 || hs->scanCode == SCAN_FLAG_KEYMAN_KEY_EVENT`). So the
phantom KEYDOWN that `keybd_shift_reset` just injected is seen by Keyman's own
hook and written straight back into Cache A as `0x80`.

Cache A therefore does not merely *fail to refresh* — it **re-confirms its own
hallucination on every injected batch**. This is a closed loop, and a second
independent reason the state is stable rather than transient.

### 3d. Where does the initial Right Ctrl come from? (open — needs measurement)

§3a-c explain the phantom press and its persistence. What they do not prove is
the **seed**: one extended-Ctrl KEYDOWN whose KEYUP is missed. Candidates, most
to least likely, all testable:

1. **`GetKeyboardState` at `InitThread` (`:251`) captures a transient.** One-shot
   seed at Keyman startup, never corrected. Would present as "broken from login".
2. **Anything that emits `E0 1D`.** RDP / Citrix / VNC, VM guest tools,
   PowerToys / AutoHotkey remaps, KVM switches, on-screen keyboard, and — note
   the irony — **vendor Fn-layer drivers on laptops that lack a Right Ctrl key**,
   which is where that key commonly gets remapped to in the first place.
3. **AltGr.** Windows synthesizes a Ctrl keydown alongside RAlt on AltGr layouts.
   Standard behaviour is *Left* Ctrl, non-extended, so this normally seeds
   `LCTRL` — but Keyman evidently knows the pairing is quirky, because
   `aiTIP.cpp:467` special-cases exactly `TF_MOD_RALT|TF_MOD_LCONTROL`.

   **This one matters most and is cheapest to check.** The Cameroon keyboards use
   RAlt as AltGr on *every accented character*. If any driver in the field emits
   that synthetic Ctrl with the extended bit set, the seed is not exotic at all —
   it is every keystroke the user types.

Test for (3): log `KBDLLHOOKSTRUCT.vkCode` / `scanCode` / `flags & LLKHF_EXTENDED`
for the Ctrl event that accompanies AltGr, on the affected hardware. Not yet done.

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

## 5. Insert, and the `Zap Virtual Key Code` footgun

`VK_INSERT` (0x2D) appears nowhere in keyman32, so Insert cannot be latched or
phantom-pressed. But something adjacent is worth knowing about.

`keybd_sendprefix()` (`keybd_shift.cpp:112-118`) injects a dummy key down+up
around any batch that releases a modifier, to stop a bare Alt from opening the
menu. That key is `Globals::get_vk_prefix()`, defaulting to
`_VK_PREFIX_DEFAULT = 0x0E` (`aiTIP.h:36`) — a **reserved/undefined VK**, chosen
precisely so it does nothing.

It is **registry-overridable**: `k32_globals.cpp:374-380` reads
`REGSZ_ZapVirtualKeyCode` and will use any VK put there. Set it to `0x2D` and
Keyman injects Insert around every modifier-bearing keystroke — overtype mode
toggling on and off, which is exactly the kind of "the keyboard has gone weird"
report that gets filed as a stuck-modifier bug.

Checked on this machine (2026-08-23): **not set**, in either
`HKCU\Software\Keyman\Keyman Engine` or
`HKLM\Software\WOW6432Node\Keyman\Keyman Engine`. So the default 0x0E is in use
and Insert is ruled out *here*. Cheap to check on an affected machine; worth
adding to any diagnostic script.

---

## 6. What this changes about the repro

The harness has only ever exercised LShift and RAlt. Three gaps, in priority
order:

1. **Ctrl has never been tested at all**, on either side — despite being the case
   with the strongest field signal and the only one that cannot self-heal (§3).
   Add L/RCtrl arms to the candidate set.
2. **A missing-key arm.** The distinctive claim in §3b is that the wedge becomes
   *permanent* when the latched key does not physically exist. That is testable
   without special hardware: latch `VK_RCONTROL` via injection, then verify no
   amount of physical typing clears it and only a Keyman restart does. This is
   the arm that would explain the field reports the current repro cannot.
3. **The AltGr-to-Ctrl extended-bit question** (§3d item 3). An LL-hook logger
   recording `vkCode` / `scanCode` / `LLKHF_EXTENDED` for the synthetic Ctrl that
   accompanies AltGr. If it is ever extended, the seed is every keystroke and the
   severity of this whole bug goes up sharply.

Also worth noting for the oracle design: the existing case-sensitivity trap
(`-ceq` / `-cne`) is a **Shift**-specific artifact. A stuck Ctrl produces no case
change at all — it produces swallowed keys and stray accelerators. The
`abc`/`ABC` oracle will read **CLEAN** under a stuck Ctrl. Any Ctrl arm needs a
different probe (e.g. whether a literal `a` arrives at all), or it will report
false negatives the same way the case-insensitive comparison did.

---

## 7. Where fixes belong

Per direction on 2026-08-23:

- **Stuck-modifier (Cache A) work — not being fixed in Keyman code yet.** Stays
  here as repro + analysis. §3 is the part to lead with when it does go upstream:
  it is the mechanism, it is provable from code, and it explains the persistence
  the current write-ups flag as unexplained.
- **Un-read-modifier-state (Cache B) work — belongs on the #16423 branch**, which
  is already "stop trusting cached lock state, re-read it". Findings **4a**
  (resync 7 flags, not 2) and **4b** (`GetAsyncKeyState` for the modifier half)
  are the same shape as the Caps fix already on that branch, and are one-line
  changes at `aiTIP.cpp:186-189` and `kmhook_getmessage.cpp:423-436`.

Finding **4c** is an observation, not a bug — but it belongs in the #16423
discussion because it explains *why* the right-hand modifiers are the ones users
report.
