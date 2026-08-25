# Test plan — Caps Lock / Cache B ([#16422] / [#16423])

> Split out of the parent [kmrepro](../TEST-PLAN.md) plan. Different defect from
> the stuck-modifier bug ([#8064]); see [FINDINGS.md](FINDINGS.md).
>
> [#8064]: https://github.com/keymanapp/keyman/issues/8064
> [#16422]: https://github.com/keymanapp/keyman/issues/16422
> [#16423]: https://github.com/keymanapp/keyman/issues/16423

These are the two cleanest red-to-green tests in the whole investigation: both
fail today, both pass once F1/F2 land, and neither needs a new API, a stall, a
timer, elevation or a desktop.

## Harness

Identical to the parent plan — see [`../TEST-PLAN.md`](../TEST-PLAN.md) §3.1.
[`windows/src/engine/keyman32/tests/`][tests], gtest 1.8.1.7 via NuGet, MSBuild.
`build.sh` links the engine as a **static library** into a console exe, so there
is no elevation, no TSF and no installed Keyman. Run with:

```bash
./windows/src/engine/keyman32/build.sh --debug configure build test:x64
```

> **The vcxproj has no glob** — every test `.cpp` must be listed in
> `<ClCompile>`. See the parent plan's **P1**.

---

### Red — fail today, pass after the fix

New `tests/capsstate.tests.cpp`:

- **T-R1** *(finding 4a)* — set `K_SHIFTFLAG|LCTRLFLAG|RCTRLFLAG|LALTFLAG|RALTFLAG` on `Globals::ShiftState()`, call [`RefreshToggleState()`][cs39], assert all clear. RED: it touches only `CAPITALFLAG`/`NUMLOCKFLAG`. Fix = [TODO F1][todo].
- **T-R2** *(finding 4b)* — `SetKeyboardState` with `ks[VK_LCONTROL]=0x80` makes the thread queue disagree with physical state (exactly what a dropped KEYUP produces); call [`GetCapsAndNumlockState()`][gm418]; assert `LCTRLFLAG` clear. RED: [`:425`][gm418] uses `GetKeyState(...) < 0`. Fix = [TODO F2][todo]. **Lead with this — it is the bug in eight lines.**

---

## Fixes that turn them green

**F1** (resync all seven flags on keyboard switch) and **F2** (`GetAsyncKeyState`
for the modifier half) — see [TODO.md](TODO.md). **F3** is the rename that would
have prevented 4a in the first place; **F4** is finding 4c for the PR
description; **F5** is the scoping question for the reviewer.

Optional seam **S1** — `GetCapsAndNumlockState` currently has **no header
declaration**, only a file-local forward decl at `kmhook_getmessage.cpp:71`. Give
it one (natural home: `capsstate.h`, beside `RefreshToggleState`) so T-R1 can
assert the real call path rather than the helper in isolation. Precedent:
`ReadAltGrFlagFromKbdDll(name, out)` was split out of
`KeyboardGivesCtrlRAltForRAlt()` purely for testability.

[tests]: https://github.com/keymanapp/keyman/tree/master/windows/src/engine/keyman32/tests
[vcx]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/tests/keyman32.tests.vcxproj
[cs39]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/capsstate.cpp#L39
[gm418]: https://github.com/keymanapp/keyman/blob/master/windows/src/engine/keyman32/kmhook_getmessage.cpp#L418
[todo]: TODO.md
