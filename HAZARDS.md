# HAZARDS — read before writing or changing harness code

Five ways to break the *target* rather than mis-measure it. The oracle and
comparison traps are a different list and live in `TRIGGER.md` ("Harness traps
found the hard way") — that one is about measuring correctly. This one is about
not breaking things while you measure.

Every entry below cost real time. All five are target-independent: they apply to
the Notepad-only harness the repro actually uses.

> **Notepad is the only target.** FieldWorks testing is out of scope
> (`TEST-PLAN.md` §7) — the reproduction needs nothing else, and pointing a
> harness at a live language database is how H1 below corrupted real lexical data
> twice.

---

## H1 — navigation keys MUST carry `KEYEVENTF_EXTENDEDKEY`

Unextended, Left's scan code `0x4B` *is* numpad-4, Right `0x4D` is numpad-6, and
Home `0x47` is numpad-7. Send them without the extended flag and they **insert
characters instead of moving the caret** — silently, in whatever has focus.

This is not an app-specific quirk; it is how the scan-code space works, and it is
equally true in Notepad. It corrupted a live lexicon twice before the driver
responsible was retired. Route every navigation key through a single guarded
helper that sets `KEYEVENTF_EXTENDEDKEY` rather than setting the flag at each
call site.

The same rule governs the modifier catalog: `Ext` and `Scan` in `kmmods.ps1` are
load-bearing, not decorative. Insert unextended is numpad-0.

## H2 — PowerShell names are case-insensitive, and aliases outrank functions

`$EXT` (a constant) collided with `$Ext` (a switch parameter) and the two were
the same variable. Same class of bug from the other direction: a helper named `R`
resolved to the built-in alias for `Invoke-History`, because aliases are looked
up before functions.

Give constants and parameters names that differ by more than case, and do not
name a function with one or two letters.

## H3 — resolve the HKL from the focus thread, not the top-level window

Multi-threaded UI apps keep the top-level frame window on a thread pinned at
`0x0409` for the life of the process, while the focused edit control sits on a
different thread that does track the input locale. `GetWindowThreadProcessId(MainWindowHandle)`
reads the frame thread and is **stale forever** — it reports `0x0409` while
Keyman is demonstrably live.

Resolve from `GetGUIThreadInfo(0).hwndFocus` and the HKL discriminates cleanly.
Verified by same-thread A/B on 2026-08-23: Keyman `0x04092000`, MS Cameroon
`0xF0C00436`, US `0x04090409`. Compare the **full** HKL, not just the langid —
Dvorak lands as `0xF0020409` and would silently break an ASCII oracle.

`kmproof.ps1` and `kmmods.ps1` rely on this. Any new HKL helper should return
**both** readings — frame thread and focus thread — plus a `Diverged` flag, so a
stale frame-thread value is visible rather than silently believed.

This was originally written as "`GetKeyboardLayout()` is an unreliable oracle."
That was a wrong-thread artifact and is retracted **for Notepad**, which is the
only target in scope. It is not a general retraction: an app that switches
keyboards programmatically rather than through a user TSF switch takes a
different code path, and that case was never re-tested with the focus-thread fix.
If you ever measure one, type and read back rather than trusting the HKL.

## H4 — `keybd_event` with `dwExtraInfo = 0` is deliberate

Keyman only filters on `dwExtraInfo != 0`
(`k32_lowlevelkeyboardhook.cpp:229`), so **0 is what makes Keyman treat
synthesized keys as real user input.**

Do not "fix" this to `SendInput` with a marker. Doing so makes the entire harness
invisible to Keyman, and every test then passes silently — the worst possible
failure mode, since the rig would report a clean machine no matter what Keyman
did. This is the easiest hazard in the list to undo by accident while tidying
code, which is why it is called out twice.

## H5 — read the `keyman.exe` version from the registry

`keyman.exe`'s `Path` is unreadable from an unelevated shell, so
`Get-Process` cannot give you a version. Read it from the registry, or from the
file directly:

```powershell
(Get-Item "${env:ProgramFiles(x86)}\Keyman\Keyman Desktop\keyman.exe").VersionInfo.FileVersion
```
