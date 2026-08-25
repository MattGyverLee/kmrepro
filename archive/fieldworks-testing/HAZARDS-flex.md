# ARCHIVED — FieldWorks / FLEx operational hazards

**Archived 2026-08-25. FieldWorks testing is out of scope** — the reproduction
needs only Notepad (`TEST-PLAN.md` §1, §7). Kept verbatim because two of these
hazards corrupted live Ngoreme lexical data, and because the safety rules in §2
must be re-read by anyone who ever points a harness at FLEx again.

The hazards here that are **not** FieldWorks-specific — extended navigation keys,
PowerShell name collisions, the `dwExtraInfo = 0` rule, the `keyman.exe` version
read, and the Notepad half of the HKL correction — survived into the live
`../../HAZARDS.md`. Everything else is FLEx-only and stays here.

---

# HAZARDS — read before touching the harness code

Extracted from `HANDOFF.md` §9-10 when that document was archived. These are
operational hazards, not findings. Every one of them cost real time, and two of
them corrupted live language data.

The oracle and comparison traps live in `TRIGGER.md` ("Harness traps found the
hard way") — that list is about *measuring* correctly. This one is about not
breaking things while you measure.

---

## 1. Harness gotchas

These cost hours and twice corrupted live language data.

1. **Navigation keys MUST carry `KEYEVENTF_EXTENDEDKEY`.** Unextended, Left's scan
   code `0x4B` *is* numpad-4, Right `0x4D` is numpad-6, Home `0x47` is numpad-7 —
   they insert characters instead of moving the caret. **This corrupted the user's
   lexicon twice.** **FieldWorks testing is now out of scope** (`TEST-PLAN.md` §7)
   and the driver that caused this is gone. The entry is kept so nobody rebuilds
   one without routing every navigation key through a single guarded helper that
   sets `KEYEVENTF_EXTENDEDKEY`.
2. **PowerShell variable names are case-insensitive.** `$EXT` (constant) collided
   with `$Ext` (switch parameter). Same class of bug: a helper named `R` resolved
   to the built-in alias for `Invoke-History` — aliases outrank functions.
3. **`GetKeyboardLayout()` — partly rehabilitated, but still not the oracle in
   FLEx.** The Notepad half of this was a wrong-thread artifact: multi-threaded UI
   apps keep the top-level frame window on a thread pinned at `0x0409` for the
   life of the process, while the focused edit control sits on a different thread
   that does track the input locale. `GetWindowThreadProcessId(MainWindowHandle)`
   reads the frame thread and is stale forever. Resolve from
   `GetGUIThreadInfo(0).hwndFocus` and it discriminates cleanly — verified by
   same-thread A/B on 2026-08-23 (Keyman `0x04092000`, MS Cameroon `0xF0C00436`,
   US `0x04090409`). `kmproof.ps1` and `kmmods.ps1` rely on this; any new
   HKL helper should return **both** readings — frame thread and focus thread —
   plus a `Diverged` flag, so a stale frame-thread value is visible rather than
   silently believed.

   **The FLEx observation above is NOT explained by that, and is not retracted.**
   FLEx changes keyboards *programmatically* from its writing-system combo, which
   is a different path from a user TSF switch and may not update any thread's HKL
   promptly. That case has not been re-tested with the focus-thread fix. So in
   FLEx: still **type and read back**; treat the HKL as a hint and check
   `Diverged`. In Notepad the HKL is now trustworthy.
4. **In FLEx, never send Home/End/Ctrl+A.** RootSite treats them as record-wide
   navigation; the caret leaves the field.
5. **In FLEx, never collapse a selection with Right at end-of-field.** It moves to
   the *next field*, so every read silently advances the caret and a later Tab
   count overshoots. Use `Read-AndClear`, which leaves the Shift+Left selection
   active and deletes it with one Backspace — atomic, caret unmoved.
6. **Tab is unusable for the FLEx field switch.** Tabbing past an entry's last
   field advances to the **next record**. Use absolute clicks.
7. **FieldWorks exposes NO UI Automation text** (zero Document/Edit/Text
   elements). Clipboard or screenshot only. Notepad, by contrast, exposes a clean
   `ValuePattern` on `RichEditD2DPT` — prefer Notepad for anything that doesn't
   need FLEx specifically.
8. **`keybd_event` with `dwExtraInfo = 0` is deliberate.** Keyman only filters on
   `dwExtraInfo != 0` (`k32_lowlevelkeyboardhook.cpp:229`), so 0 makes Keyman treat
   synthesized keys as real user input. Do not "fix" this to SendInput with a
   marker.
9. `keyman.exe`'s `Path` is unreadable from an unelevated shell — read the version
   from the registry.
10. FLEx field Y-coordinates **shift between entries** and as fields gain content.
    Re-check by hand if anything looks wrong. Current test entry:
    Ngq Citation Form `(1000, 325)`, Eng Note `(1000, 490)`.

---

## 2. Safety rules — live language data

- **The FLEx database contains real Ngoreme language data.** The user has said the
  DB is restorable and any entry is expendable, and created a dedicated test entry
  (headword `Ngq`, entry 698/2234) — **use only that entry**.
- Every FLEx write must be self-cleaning (`Read-AndClear`). Verify the entry is
  unchanged after a run — verify by hand, and prefer not driving FieldWorks at all.
- **Do not spam Ctrl+Z to fix mistakes.** The undo stack mixes your changes with
  the user's work; an over-undo silently reverts their edits. If you corrupt
  something, say so and let the user restore.
- Claude Code's auto-mode classifier may block synthesized keystrokes into
  FieldWorks. That is a reasonable block — surface it to the user rather than
  working around it.

---


## 3. Two hazards worth restating

Both are easy to undo by accident while "cleaning up" code.

- **`keybd_event` with `dwExtraInfo = 0` is deliberate** (gotcha 8). Keyman only
  filters on `dwExtraInfo != 0`, so 0 is what makes it treat synthesized keys as
  real user input. Converting these calls to `SendInput` with a marker would make
  the whole harness invisible to Keyman and every test would silently pass.
- **The FLEx HKL caveat is not retracted** (gotcha 3). The Notepad half was a
  wrong-thread artifact and is fixed. FLEx changes keyboards *programmatically*
  from its writing-system combo, which is a different code path and has not been
  re-tested with the focus-thread fix. `TRIGGER.md` marks the HKL question
  "SOLVED" — that applies to Notepad. In FLEx, still type and read back.
