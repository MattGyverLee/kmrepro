# Phantom Right Ctrl — where the seed actually comes from

Addendum to [`MODIFIERS.md`](MODIFIERS.md) §3. The main body of this
investigation is about modifier keys getting stuck that **physically exist** —
L/R Shift, L/R Alt, Left Ctrl — where the wedge self-heals on the next real tap.
This doc is the other case: a phantom **Right** Ctrl on hardware with **no Right
Ctrl key**, where nothing can heal it.

`MODIFIERS.md` §3a-c already explain the phantom press and why it persists. What
they leave open is §3d, the **seed**: where does that first extended-Ctrl KEYDOWN
come from, on a machine that cannot produce one?

**Answered here, from source: the seed is not a Right Ctrl event at all.** It is
an *unsided* `VK_CONTROL` carrying one flag bit, from any injector, and it needs
no Right Ctrl key, no `E0 1D` hardware scan code, and no particular keyboard,
region, or chassis.

Code refs are `windows/src/engine/keyman32/` at `a70538106c`.

---

## 1. The ternary is the seed

`serialkeyeventserver.cpp:554-558`:

```c
void UpdateLocalModifierState(BYTE bVk, BOOL fIsExtendedKey, BYTE bScan, BOOL fIsUp) {
  switch (bVk) {
  case VK_CONTROL:
    // Left and right control are distinguished by a 0xE0 prefix byte
    bVk = fIsExtendedKey ? VK_RCONTROL : VK_LCONTROL;
```

`isModifierKey()` (`k32_lowlevelkeyboardhook.cpp:62-77`) admits nine VKs — the six
sided ones **plus the three unsided** `VK_CONTROL` (0x11) / `VK_MENU` /
`VK_SHIFT`. This ternary is what gives an unsided one a side.

So the RCTRL slot is written by **any `VK_CONTROL` event with the extended bit
set.** Not `VK_RCONTROL` (0xA3). Not a hardware `E0 1D`. Just VK 0x11 plus one
bit — and the bit is chosen by whoever sent the event, not derived from hardware.

That is the whole answer to §3d. Everything below is the supporting chain and the
consequences.

## 2. The chain, verified end to end

| step | ref | what happens |
|---|---|---|
| 1 | `k32_lowlevelkeyboardhook.cpp:198-201` | `isModifierKey(hs->vkCode) && flag_ShouldSerializeInput` → `PostMessage(WM_KEYMAN_MODIFIER_EVENT, hs->vkCode, ...)`. `vkCode` passed **verbatim** — no normalisation |
| 2 | `:83-87` | `LLKHFFlagstoWMKeymanKeyEventFlags` folds `LLKHF_EXTENDED` → `KEYEVENTF_EXTENDEDKEY` into lParam |
| 3 | `serialkeyeventserver.cpp:440` | handler accepts `WM_KEYMAN_MODIFIER_EVENT` |
| 4 | `:535-540` | unpacks lParam, calls `UpdateLocalModifierState` with `fIsExtendedKey` from that bit |
| 5 | `:558` | side resolved — extended ⇒ `VK_RCONTROL` |
| 6 | `:581` | `m_ModifierKeyboardState[VK_RCONTROL] = 0x80` |

### 2a. The post at step 1 is unfiltered

This is the part that widens the seed population, so it is worth stating flatly.

The post is gated on **one** condition: `flag_ShouldSerializeInput`, which
defaults TRUE (`k32_globals.cpp:91`, `keyman32.cpp:231`
`Reg_GetDebugFlag(..., TRUE)`).

It is **not** gated on `isKeymanKeyboardActive`, not on `dwExtraInfo`, not on
`LLKHF_INJECTED`. And it sits ~30 lines **before** the pass-through filter at
`:229-233`. So Cache A accepts modifier writes from sources Keyman explicitly
excludes from everything else it does.

`LLKHF_INJECTED` is never consulted anywhere on this path. "This came from real
hardware" is not a distinction the code is capable of making — which also settles
why `MODIFIERS.md` §3b's injected KEYUP was a sufficient test rather than a proxy.

The filter at `:235` names a specific injector:

> `dwExtraInfo` is set to `0x4321DCBA` by **mstsc** which does prefiltering. So we
> ignore for anything where `dwExtraInfo!=0` because it probably is not hardware
> generated…

Keyman's own source identifies the **RDP client** as an injector of key events,
excludes it at `:229` — and has already accepted it into Cache A at `:201`.

## 3. No physical key is required at any stage

| stage | mechanism | needs a Right Ctrl key? |
|---|---|---|
| **seed** | unsided `VK_CONTROL` + extended, from any injector (§1) | **no** |
| **latch** | `:581` writes `0x80` | **no** |
| **re-assert** | `keybd_shift_reset` (`keybd_shift.cpp:161-176`) emits a KEYDOWN for the slot; the LL hook sees it at `:201`, before the `:229` filter, and writes it back (`MODIFIERS.md` §3c) | **no** |
| **clear** | requires `VK_CONTROL` + extended + **KEYUP** | **yes — and it can never come** |

Only the exit requires the key. That asymmetry is the entire defect: every step
that *creates* the state is reachable in software, and the only step that
*destroys* it is gated on hardware the user does not have.

`MODIFIERS.md` §3b measured the exit conditions directly — typing does not clear
it, tapping Left Ctrl does not clear it, only the exact matching KEYUP does.

## 4. The seed only has to fire once, ever

Cache A is read from the OS exactly once, at `InitThread`
(`serialkeyeventserver.cpp:251`, `GetKeyboardState`), and **never re-validated for
the life of the process**. There is no expiry, no timer, no resync path.

So this is not a hunt for a recurring mechanism. **A single transient at any point
in the process lifetime is sufficient**, after which §3c's loop sustains it
indefinitely. Any search framed as "what does this user do that keeps triggering
it?" is framed wrong; the right question is "did anything, once, since Keyman
started?"

## 5. This was already measured here — the interpretation was the gap

`kmmods.ps1:980`:

```powershell
'RCTRL'  { $emitVk = 0x11; $emitExt = $true  }   # VK_CONTROL + extended
```

**That is the unsided form.** So `MODIFIERS.md` §3b step 0 — the injection that
latched the slot, survived typing `jkq`, survived a Left Ctrl tap, and cleared
only on the exact matching KEYUP — was already a demonstration of the *general*
seed, not merely of Keyman's own re-assertion pattern.

§3b describes that byte pattern as *"the byte pattern `keybd_shift_reset`
produces"*, which is true and undersells it. It is equally the byte pattern that
**any** caller doing `keybd_event(VK_CONTROL, ..., KEYEVENTF_EXTENDEDKEY, ...)`
produces. The experiment is done and the result stands; only the reading of it was
missing.

## 6. The emitter population

The requirement drops from *"hardware or a driver emitting `E0 1D`"* to
*"anything that injects Ctrl with `KEYEVENTF_EXTENDEDKEY` set."* The flag is
caller-chosen and Keyman validates nothing, so:

- **mstsc / RDP, Citrix, VNC** — named at `:235`; excluded at `:229`, accepted at
  `:201`. FieldWorks deployments are frequently remoted.
- **Auto-type and macro tooling** — password managers, AutoHotkey, RPA, macro
  utilities, installers. `keybd_event(VK_CONTROL, …)` is the idiomatic legacy
  call and the side bit is an afterthought nobody validates.
- **On-screen and accessibility keyboards** — including Keyman's own OSK, which
  `serialkeyeventserver.cpp:481` cross-references
  (`PostVisualKeyboardModifierEvent`, `TfrmOSKOnScreenKeyboard.OskModifierEvent`).
- **Keyman itself** — `do_keybd_event` (`keybd_shift.cpp:69-73`) emits exactly
  `VK_CONTROL` + `KEYEVENTF_EXTENDEDKEY` for RCTRL, which is why §3c's loop
  sustains the latch once seeded.
- **The §3d.2 list still applies** — VM guest tools, KVM switches, PowerToys /
  AHK remaps, vendor Fn-layer drivers — but they are now one entry in a much
  larger set rather than the whole search space.

## 7. What this demotes

Three lines of enquiry get smaller, and it is worth being explicit so nobody
spends more time on them:

- **The ANSI-vs-ISO / regional keyboard axis.** Not a variable. The seed path has
  no hardware precondition, and AltGr is a layout property (`KLLF_ALTGR`) rather
  than a key — measured on this ANSI machine at `MODIFIERS.md` §3d-measured, where
  the MSKLC arm synthesised a Ctrl on 22/22 physical presses.
- **The `E0 1D` hardware hunt.** An `E0`-prefixed scan code is *sufficient* but
  not *necessary*. Nothing in the chain reads the scan code for Ctrl — `:566` uses
  `bScan` only for `VK_SHIFT`.
- **"Affected field hardware decides severity"** (`TODO.md` I1's still-owed item).
  It does not, any more. The seed is a software path present on every Windows
  machine running Keyman. Field hardware is still worth reading for
  *attribution* — which injector actually did it — but no longer for *severity*.

## 8. Why §3d-measured found nothing, and why that was not a null result

`MODIFIERS.md` §3d-measured killed AltGr as the RCTRL seed on this machine: all 22
physical AltGr presses paired with a **non-extended LEFT** Ctrl, 44/44 carrying
`scan=0x21D`.

That result is correct and stands. The reason it looked like a dead end is that
**the AltGr path does not go through this ternary at all.** Its synthetic Ctrl
arrives already sided as `VK_LCONTROL` (0xA2) and takes the pass-through case at
`:567-575` instead. See §3d-measured's "Footnote: the LCTRL branch" in `MODIFIERS.md` for that half — including a source comment at `:574` that the measurement contradicts.

So the seed hunt was looking at the one Ctrl path that cannot produce an RCTRL
latch. The ternary at `:558` is the path that can, and it is fed by injection
rather than by layout.

## 9. Measured, proven, and still open

| claim | status |
|---|---|
| The ternary at `:558` assigns the side from the extended bit alone | **proven from source** |
| Nothing on this path reads the scan code for Ctrl | **proven from source** (`:566` uses `bScan` for `VK_SHIFT` only) |
| The modifier post at `:201` is unfiltered and precedes the `:229` filter | **proven from source** |
| `LLKHF_INJECTED` is never consulted on this path | **proven from source** |
| An unsided `VK_CONTROL` + extended, unmatched, latches the RCTRL slot | **MEASURED 2026-08-24** — `kmmods.ps1:980`, `MODIFIERS.md` §3b step 0 |
| Only the exact matching extended KEYUP clears it | **MEASURED 2026-08-24** — `MODIFIERS.md` §3b, 4 steps |
| A latched RCTRL swallows keystrokes entirely | **MEASURED 2026-08-24** — `jkq` returned `<empty>` |
| A latched Ctrl reads CLEAN to a text-only oracle | **MEASURED** — `MODIFIERS.md` §2b. This is why careful testers saw nothing |
| This machine is the affected hardware class (no physical Right Ctrl) | **confirmed at the wire 2026-08-25** — `MODIFIERS.md` §3b |
| **Which real-world injector seeded it on a field machine** | **UNKNOWN, and still worth asking.** This doc reduces the hypothesis space; it does not identify a culprit |

The last row is the honest boundary. "Any injector that sets the bit" is a much
smaller claim than "we know what did it."

## 10. Next measurements, in order

1. **Route the ternary's other branch.** Inject unsided `VK_CONTROL` (0x11) with
   `$emitExt = $false`, unmatched, and confirm it lands in **LCTRL and not
   RCTRL**. One new cell in a table `kmmods.ps1` already builds. Confirms the
   ternary is the whole story rather than something normalising upstream.
2. **Confirm an unsided post survives to the cache with `dwExtraInfo != 0`.**
   Inject with a non-zero `dwExtraInfo` — mstsc's `0x4321DCBA` is the obvious
   value — and confirm the RCTRL slot still latches. This is the direct test of
   §2a, and it is the one that makes the RDP claim measured rather than read.
3. **Ask the field reporter for injector inventory, not keyboard model.** RDP or
   Citrix session? Password manager with auto-type? AutoHotkey, PowerToys, vendor
   hotkey utility? On-screen keyboard? That list is now higher-value than the
   chassis, and it replaces the hardware question in `TODO.md` I2.
4. **Re-scope I2.** From "enumerate the real-world `E0 1D` emitters" to
   "enumerate injectors that set `KEYEVENTF_EXTENDEDKEY` on `VK_CONTROL`" — a
   different and larger set, reachable by inspecting software rather than
   sourcing hardware.

## 11. What this changes for the fix

Nothing about the recommended fix, which is a point in its favour.
`FIX-PROPOSAL.md` §1 — re-validate the six modifier bytes from the OS at batch
start, preferring `GetAsyncKeyState` — covers this seed as it covers every other,
because it does not care how the byte got wrong.

Two notes for the PR text:

- **Do not describe the seed as exotic or hardware-dependent.** It is an unsided
  `VK_CONTROL` with one flag bit, from any injector, needing to happen once. That
  is a stronger and simpler motivation for the resync than the hardware story,
  and it is defensible from source alone.
- `FIX-PROPOSAL.md:167` can drop *"The field reports describe persistence until a
  Keyman restart; that gap is unexplained."* It is explained: the latched key does
  not physically exist, so the clearing event cannot be produced (§3), and Cache A
  has no other resync path (§4).

[i8064]: https://github.com/keymanapp/keyman/issues/8064
