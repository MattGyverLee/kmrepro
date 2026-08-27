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
set.** No hardware `E0 1D` is needed, and no `VK_RCONTROL` (0xA3) is needed. Just
VK 0x11 plus one bit — and the bit is chosen by whoever sent the event, not
derived from hardware.

That is the whole answer to §3d. Everything below is the supporting chain and the
consequences.

### 1a. What this does *not* say: software Ctrl is not automatically RCtrl

Worth stating explicitly, because it is an easy and damaging overstatement — one
that would be refuted in about a minute by anyone reading `:558`.

An injected Ctrl does not *become* Right Ctrl. The injector **chooses** the side,
and nothing validates the choice against the hardware. There are three routes and
two destinations:

| what the injector sends | route | lands in |
|---|---|---|
| unsided `VK_CONTROL` (0x11), extended **set** | ternary, `:558` | **RCTRL** |
| unsided `VK_CONTROL` (0x11), extended **clear** | ternary, `:558` | **LCTRL** |
| sided `VK_RCONTROL` (0xA3) | pass-through, `:567-575` | **RCTRL** — flag never consulted |
| sided `VK_LCONTROL` (0xA2) | pass-through, `:567-575` | **LCTRL** — flag never consulted |

Two consequences that matter for how this gets described:

- **The unsided default is LCTRL, not RCTRL.** A program firing Ctrl+V without
  thinking about sides — the common case — lands in the *Left* slot. Reaching the
  RCTRL slot takes deliberate intent: either ticking the extended flag, or naming
  the right-hand VK.
- **The sided route bypasses the ternary entirely.** `SendInput` with
  `wVk = VK_RCONTROL` falls straight through `:567-575` to the write at `:581`
  with the extended bit never examined. For tooling that means "right Ctrl"
  specifically — a remapper restoring a key the chassis lacks — this is the more
  likely path of the two, because sending the sided VK is the obvious way to
  express it.

So the correct claim is not *"software Ctrl is read as RCtrl"*. It is: **the side
is asserted by the sender, on a machine that may have no such key, and Keyman
records the assertion without any means of checking it.**

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
| **seed** | unsided `VK_CONTROL` + extended, **or** sided `VK_RCONTROL`, from any injector (§1, §1a) | **no** |
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

Note that this is *not* specifically the byte pattern `keybd_shift_reset`
produces: that stamps `scan = SCAN_FLAG_KEYMAN_KEY_EVENT` (`0xFF`,
`keybd_shift.cpp:169`), while the harness sends the real `0x1D`. The reading is
the stronger one: it is the byte pattern **any** caller doing
`keybd_event(VK_CONTROL, ..., KEYEVENTF_EXTENDEDKEY, ...)` produces — and, unlike
Keyman's own `0xFF` events, it is one the `:229-233` filter cannot tell from
hardware. The experiment is done and the result stands; only the reading of it was
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
- **Keyman itself** — `do_keybd_event` (`keybd_shift.cpp:68-72`) emits exactly
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
| An unsided Ctrl with the bit **clear** lands in LCTRL, not RCTRL — the unsided default is Left | **proven from source** (`:558`, else-branch). Not yet measured; §10.1 |
| A **sided** `VK_RCONTROL` (0xA3) injection reaches the RCTRL slot via `:567-575`, bypassing the ternary and ignoring the flag | **proven from source** — §1a |
| Nothing on this path reads the scan code for Ctrl | **proven from source** (`:566` uses `bScan` for `VK_SHIFT` only) |
| The modifier post at `:201` is unfiltered and precedes the `:229` filter | **proven from source** |
| `LLKHF_INJECTED` is never consulted on this path | **proven from source** |
| An unsided `VK_CONTROL` + extended, unmatched, latches the RCTRL slot | **MEASURED 2026-08-24** — `kmmods.ps1:980`, `MODIFIERS.md` §3b step 0 |
| Only the exact matching extended KEYUP clears it | **MEASURED 2026-08-24** — `MODIFIERS.md` §3b, 4 steps |
| A latched RCTRL swallows keystrokes entirely | **MEASURED 2026-08-24** — `jkq` returned `<empty>` |
| A latched Ctrl reads CLEAN to a text-only oracle | **MEASURED** — `MODIFIERS.md` §2b. This is why careful testers saw nothing |
| This machine is the affected hardware class (no physical Right Ctrl) | **established 2026-08-25 on the user's report**, corroborated by the wire capture — a capture cannot prove a key's absence. `MODIFIERS.md` §3b |
| **Which real-world injector seeded it on a field machine** | **UNKNOWN, and still worth asking.** This doc reduces the hypothesis space; it does not identify a culprit |

The last row is the honest boundary. "Any injector that sets the bit" is a much
smaller claim than "we know what did it."

### 9a. Why this machine has never seeded it — the negative control has a mechanism

Checked 2026-08-25. This machine is in the affected hardware class (no physical
Right Ctrl — the user's report, corroborated at the wire, `MODIFIERS.md` §3b) and has been throughout the
investigation, yet has never produced a phantom Right Ctrl outside deliberate
injection. **The reason appears to be that none of the candidate injectors are
present:**

| checked for | result |
|---|---|
| VirtualBox, VMware, Parallels | **not installed** |
| Citrix, TeamViewer, AnyDesk | **not installed** |
| AutoHotkey, PowerToys, Synergy | **not installed** |
| vendor mouse/keyboard suites (Logitech, Razer) | **not installed** |
| `TermService` / `UmRdpService` (RDP listener) | **Stopped** |
| `vmcompute` (Hyper-V platform — WSL2 / Sandbox / Docker) | Running; does not inject into the host session |
| **this Windows install running as a VM *guest*** | **no — bare metal** (confirmed by the user, 2026-08-25) |

**The two VM roles are different mechanisms and both had to be excluded:**

- **Host role** — a hypervisor running *on* this machine. Its window grabs and
  releases the keyboard, and its host key is typically Ctrl-based. Covered by the
  registry scan above.
- **Guest role** — this Windows running *inside* a hypervisor, with guest
  additions / guest tools injecting synthesized keystrokes into the session.
  **This is the more dangerous role for this defect**, because injecting
  synthesized input into the guest OS is precisely what those tools exist to do,
  and the host→guest translation has to reconstruct the extended flag rather than
  pass hardware through.

Both are negative here, so the VM path is excluded on this machine in both
directions.

So the null result on this machine is **explained, not merely unlucky**, and that
strengthens rather than weakens §1: the mechanism is there, the hardware class is
there, and the only missing ingredient is an injector.

**Method caveat:** this was a scan of the two `Uninstall` registry hives. It can
miss per-user installs, MSIX/Store packages, and portable executables — portable
AutoHotkey in particular would not appear. Treat it as strong evidence rather than
proof.

**Sharpens the field question.** Since the dev machine and the reporter's machine
*both* lack a physical Right Ctrl, the keyboard is a constant and cannot be the
differentiator. The difference is software present on hers and absent here, which
makes the §10.3 inventory the highest-value question in this document.

### 9b. VirtualBox: the strongest named candidate — verified from vendor docs

Confirmed against the VirtualBox manual, 2026-08-25. Two facts, both quoted:

1. **The default Host key on Windows and Linux hosts is Right Ctrl.** *"By
   default, this is the right Ctrl key on your keyboard."* On a **macOS** host it
   is the left Command key instead — so this candidate applies to a Windows or
   Linux host, not to Parallels/Fusion on a Mac.
2. **VirtualBox synthesizes and injects Ctrl-bearing chords into the guest.**
   *"Host key + Del sends Ctrl+Alt+Del to reboot the guest OS"* — the manual
   describes VirtualBox translating key combinations for the VM rather than
   passing raw keystrokes through.

Combine those with VirtualBox's capture model — *"your keyboard is owned by the VM
if the VM window on your host desktop has the keyboard focus"*, and the Host key
is what releases that ownership — and the shape is exactly what the seed needs:

> **The default gesture for escaping a VirtualBox window is a Right Ctrl press
> whose entire purpose is to cause a keyboard-ownership transition.** The press
> and its release straddle the moment ownership changes.

Keyman runs in the **guest**. So if the reporter's Windows is a VirtualBox guest on
a Windows or Linux host, the single most routine thing she does — tapping the Host
key to get her cursor back — is a Right Ctrl event delivered across an ownership
boundary, on a guest that may have no Right Ctrl key of its own to clear it with.

**What is still untested:** whether VirtualBox forwards the Host key down to the
guest at all, or swallows it entirely. If it is swallowed there is no seed from
that gesture, and the injected-chord path (fact 2) is the remaining route. That is
the single cheapest experiment left in this document — install VirtualBox, run a
Windows guest with the wire logger from `kmaltgr.ps1` inside it, and tap the Host
key. **Do not quote the mechanism as established until that is run**; facts 1 and 2
are verified, the composition is not.

Sources: [VirtualBox manual, Working with Virtual
Machines](https://www.virtualbox.org/manual/topics/working-with-vms.html).

## 10. Next measurements, in order

1. **Route the ternary's other branch.** Inject unsided `VK_CONTROL` (0x11) with
   `$emitExt = $false`, unmatched, and confirm it lands in **LCTRL and not
   RCTRL**. One new cell in a table `kmmods.ps1` already builds. Confirms the
   ternary is the whole story rather than something normalising upstream.
2. **Confirm an unsided post survives to the cache with `dwExtraInfo != 0`.**
   Inject with a non-zero `dwExtraInfo` — mstsc's `0x4321DCBA` is the obvious
   value — and confirm the RCTRL slot still latches. This is the direct test of
   §2a, and it is the one that makes the RDP claim measured rather than read.
3. **Ask the field reporter for injector inventory, not keyboard model.** That
   list is now higher-value than the chassis, and it replaces the hardware
   question in `TODO.md` I2. In rough order of expected yield:
   - **Is her Windows running inside a VM?** Parallels or VMware Fusion on a Mac,
     VirtualBox on Linux — a common enough field configuration, and the *guest*
     role is the higher-risk one (§9a). Ask this as "is Windows itself running in
     a virtual machine", **not** "do you have virtualisation software", because
     the two roles are different mechanisms and users answer the second question
     about the first.
   - **Remote sessions** — RDP, Citrix, TeamViewer, AnyDesk, including support
     sessions someone else initiated. The only source-verified injector (`:235`).
   - **Remapping or hotkey tools** — AutoHotkey, PowerToys Keyboard Manager,
     vendor utilities. Note that a laptop lacking a Right Ctrl is exactly where
     someone installs one to get the key back.
   - **On-screen or touch keyboard**, password manager auto-type.

   Both VM and remote access share the property that actually matters: they
   inject around **focus and session transitions** — connect, disconnect, grab,
   release, minimise — which is where a press and its release get separated. That
   is the only thing the seed needs, and it fits the field pattern of the wedge
   appearing after something environmental changed rather than mid-typing.
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

### 11a. The mstsc pass-through race, named in §2a and §10.2, is now fixed — 2026-08-27

§2a above already identified `mstsc`'s `dwExtraInfo=0x4321DCBA` as the source-verified injector that
reaches the cache-feed post while being excluded from the pass-through filter — exactly the emitter
population this document exists to describe. `IN-TREE.md` §2a records that the equivalent race —
not this document's seed question, but the ordering race between a batch's own restore press and a
real release passing through un-eaten under RDP, the touch panel, console focus, or a
`GetGUIThreadInfo` failure — is now closed by a post-batch verification pass (`5ba72fa3c9`), unit-
tested rather than reasoned about. **This does not settle §10 item 2 of this document** (confirming an
unsided post survives to the cache with `dwExtraInfo != 0`, which is a claim about the *seed*, not
about the *race*): that remains an open harness measurement, unrelated to whether the race is fixed.
Do not read the race fix as resolving the seed question this document still owes.

[i8064]: https://github.com/keymanapp/keyman/issues/8064
