<#
  kmmods.ps1 - WHICH modifier keys can this bug actually stick?

  WHY THIS EXISTS
  ---------------
  kmproof.ps1 answers "is the wedge Keyman's?" by holding the stimulus constant
  and varying the KEYBOARD across three arms. It answered that. But it only ever
  exercised two keys - LShift and RAlt - so it cannot say anything about the
  other four Cache A slots, and it cannot say anything at all about the keys
  MODIFIERS.md claims are immune.

  This script varies the MODIFIER and holds the keyboard constant. It is the
  other axis of the same experiment, and it is TODO items H1 (L/R Ctrl arms),
  H2 (a Ctrl-capable oracle) and H3 (missing-key permanence) in one harness.

  WHAT THE CODE PREDICTS (MODIFIERS.md section 2)
  -----------------------------------------------
  Cache A - m_ModifierKeyboardState[256], serialkeyeventserver.cpp:51 - is fed
  only through isModifierKey() (k32_lowlevelkeyboardhook.cpp:62), which returns
  TRUE for nine VKs collapsing to six slots and nothing else. keybd_shift_reset
  re-asserts exactly those six:

      const BYTE modifiers[6] = { VK_LMENU, VK_RMENU, VK_LCONTROL,
                                  VK_RCONTROL, VK_LSHIFT, VK_RSHIFT };

  So the prediction is sharp and falsifiable:

      L/R Shift, L/R Ctrl, L/R Alt   -> CAN be phantom-pressed
      Insert, Win, Apps, NumLock,
      CapsLock, ScrollLock           -> CANNOT, at all, ever

  Both halves are tested here. The immune keys are not skipped as "obviously
  fine" - they are run as NEGATIVE CONTROLS under the identical stimulus,
  because a code-derived table is inference and this repo has already been
  burned by inference that measured differently (TRIGGER.md's harness traps).
  If any of them latches, MODIFIERS.md section 2 is wrong and the script says
  so in those words.

  THE ORACLE PROBLEM, AND HOW IT IS SOLVED  (TODO H2)
  ---------------------------------------------------
  kmproof's oracles both detect SHIFT and only Shift:

      Ascii    'abc' vs 'ABC'          - a case change
      Deadkey  U+0259 U+014B vs 014A   - a case change

  A stuck CTRL produces no case change. It swallows keys and fires accelerators,
  so the field comes back EMPTY, which kmproof scores NO-OUTPUT - and Probe()
  explicitly treats NO-OUTPUT as an unreliable read to be retried, NOT as
  evidence of a wedge. A stuck Ctrl therefore reads as "flaky probe, discard".
  That is the same false-negative shape as the case-insensitive -eq trap, and it
  is why no Ctrl result exists yet.

  A stuck ALT is worse: it turns every letter into a menu mnemonic, so the probe
  not only reads empty, it leaves the app in a menu and corrupts the NEXT probe.

  The fix is to stop inferring the modifier from the text and read it directly.
  MODIFIERS.md section 3a states the observable plainly: after keybd_shift_reset
  injects its unmatched KEYDOWN, GetAsyncKeyState(VK_RCONTROL) < 0 SYSTEM-WIDE.
  So:

    ORACLE 1 - STATE (authoritative, modifier-agnostic, types nothing)
      GetAsyncKeyState across all 13 keys of interest plus the three aggregate
      VKs, taken when the harness is holding nothing. Any high bit is a phantom
      by definition. This names WHICH key is stuck, works for every key equally,
      and cannot be confused by accelerators, menus or swallowed keys.

    ORACLE 2 - TEXT (comparable with kmproof, subordinate to oracle 1)
      Three letters. lower = clean, UPPER = shifted, empty = swallowed. Run only
      when oracle 1 says it is safe to type.

  Crossing the two is where the value is, because it separates the two caches
  that MODIFIERS.md section 1 is built on:

      text UPPER + Shift held async   -> PHANTOM-LSHIFT   Cache A: a real key
                                                          state Keyman injected
      text UPPER + nothing held async -> CACHEB-SHIFT     Cache B: Keyman's
                                                          cached flag is wrong,
                                                          the OS is clean
      text empty + Ctrl held async    -> PHANTOM-LCTRL    Cache A, invisible to
                                                          kmproof today
      text empty + nothing held       -> SWALLOWED        keys vanished; neither
                                                          cache explains it

  No previous script in this repo could tell those four apart.

  THE POKE
  --------
  Cache A can be corrupt while OS key state is still clean: the phantom is only
  EMITTED when keybd_shift_reset runs, which happens when Keyman prepares an
  injected batch. So a bare state snapshot after the stimulus can read clean on
  a machine that is already charged. Every state probe is therefore preceded by
  a POKE - one keystroke through the Keyman keyboard, forcing a batch - and both
  the before-poke and after-poke snapshots are recorded. A latch that appears
  only in the after-poke snapshot is Keyman injecting it, which is the exact
  claim in section 3a.

  SAFETY - READ THIS BEFORE ADDING KEYS
  -------------------------------------
  Holding real modifiers down for 1.4 seconds on a live desktop is not free:

    Alt / Apps  releasing a lone Alt activates the menu bar; every later
                keystroke then goes to the menu. Escape twice after, always.
    Ctrl        accelerators. THE PROBE ALPHABET IS FIXED AT j / k / q AND MUST
                NOT BE WIDENED. Current Notepad binds Ctrl+B, Ctrl+I and Ctrl+U
                to bold / italic / underline, Ctrl+A select-all, Ctrl+C copy
                (which also clobbers the clipboard), Ctrl+E search-with-Bing,
                Ctrl+F/H/G find/replace/goto, and - the destructive ones -
                Ctrl+N, Ctrl+T, Ctrl+W, Ctrl+O, Ctrl+S, Ctrl+P. j, k and q are
                bound to nothing, in the menus or the editor, under Ctrl or Alt.
                This is why the alphabet is not 'abc' like kmproof's.
    Win         releasing a lone Win opens Start and steals focus. Worse, the
                script must never type while Win is latched: Win+L LOCKS THE
                WORKSTATION and would end the run. The Win arms are therefore
                OFF by default and behind -IncludeWin, and the state oracle
                hard-refuses to type whenever a Win key reads held.
    Toggles     CapsLock/NumLock/ScrollLock flip on the KEYDOWN. A flipped
                CapsLock would silently invert every later text probe, so the
                pre-trial toggle state is recorded, restored, and verified
                restored, before anything is typed.
    Insert      extended. Unextended, scan 0x52 IS numpad-0 and types a digit -
                HAZARDS.md H1. Every key in the catalog carries an explicit
                Ext flag.

  THE RIGHT SHIFT EXTENDED FLAG
  -----------------------------
  The extended flag does not decide Right Shift's side, so a rig that sets it
  either way still sweeps all six modifiers. Stated here because it looks like a
  bug on its face and has been raised as one.

  Measured at the wire with kmaltgr.ps1, 2026-08-25: injecting VK_RSHIFT with
  the extended flag and without it produces byte-identical events at a
  WH_KEYBOARD_LL hook - both `RSHIFT scan=0x36 EXT|INJ`. Windows resolves the
  side from the side-specific VIRTUAL KEY (0xA1) and reports LLKHF_EXTENDED for
  Right Shift regardless of what the caller passed. On this path the flag is
  ignored, and the six-modifier sweeps really are six keys.

  Right Shift genuinely is scan 0x36 and unextended, so this catalog marks it
  Ext=$false - as a matter of form, not because it changes behaviour.

  WHERE THE BIT DOES DECIDE THE SIDE: when the caller passes the GENERIC vk.
  Keyman's do_keybd_event (keybd_shift.cpp:63-88) collapses the side-specific
  VKs to VK_SHIFT / VK_CONTROL / VK_MENU, after which the scan code and extended
  bit are the only discriminators left. It sets scan = SCANCODE_RSHIFT explicitly
  for Right Shift for exactly that reason, while passing a bare 0xFF for Ctrl and
  Alt (see s2b).

  MODES
    (default)      matrix: every modifier in -Mods x every candidate in -Only
    -CatalogOnly   print the catalog and one state snapshot, inject nothing,
                   and do not even require a target window
    -Latch <MOD>   H3 permanence arm - latch one key the way keybd_shift_reset
                   does and measure what, if anything, clears it
    -StateOnly     never type; state oracle only. The safe way to run the Win
                   or Ctrl arms.

  USAGE
    .\kmmods.ps1 -CatalogOnly
    .\kmmods.ps1                                    # 6 Cache A keys + immune controls
    .\kmmods.ps1 -Mods LCTRL,RCTRL -Only I -Repeat 5
    .\kmmods.ps1 -Mods LWIN,RWIN -IncludeWin -StateOnly
    .\kmmods.ps1 -Latch RCTRL                       # the missing-Right-Ctrl story
#>
[CmdletBinding()]
param(
  [string]$TargetProcess = 'notepad',

  # Which modifiers to test. Default is the six Cache A slots plus the immune
  # keys that are safe to exercise unattended. Win/Apps are excluded by default;
  # see -IncludeWin.
  # ORDER IS THE RUN ORDER, AND IT MATTERS. Cache A accumulates: measured
  # 2026-08-24, once a slot latches it stays latched in Keyman's cache for the
  # rest of the session even though the OS-level state clears between trials. So
  # every arm after the first latch runs against a contaminated cache. Negative
  # controls therefore go FIRST, while the cache is still clean - same reasoning
  # as kmproof.ps1's "controls before treatment" arm order.
  [string[]]$Mods = @('INSERT','NUMLOCK','CAPSLOCK','SCROLL',
                      'LSHIFT','RSHIFT','LCTRL','RCTRL','LALT','RALT'),

  # Adds LWIN, RWIN, APPS to whatever -Mods says. A separate switch because a
  # stuck Win key plus a typed 'l' locks the workstation and ends the run.
  [switch]$IncludeWin,

  # Adds KEY_A, KEY_Z, KEY_1, SPACE - applies the stimulus to ordinary letter /
  # number keys. They are WATCHED on every run regardless; this only makes them
  # targets too. Note a held letter auto-repeats for the whole 1.4 s hold and
  # floods the field; that is harmless (the field is cleared through UIA) but it
  # does mean far more events per trial than a modifier hold produces.
  [switch]$IncludeOrdinary,

  # The keyboard is the CONSTANT here, not the variable. Keyman is the only arm
  # that wedges (kmproof settled that); the others are available as controls.
  [ValidateSet('Keyman','MSKLC','US')][string]$Keyboard = 'Keyman',

  [string[]]$Only = @(),
  [int]$Repeat = 3,

  [ValidateSet('Auto','Manual')][string]$SwitchMode = 'Auto',
  [int]$SwitchTries = 12,
  [int]$LoadThreads = 0,

  # H3. Latch one modifier by direct injection, the way keybd_shift_reset does,
  # then measure what clears it. Disruptive by design - always released in the
  # finally block.
  [string]$Latch = '',

  # Never type. State oracle only. Slower to interpret but cannot trip an
  # accelerator, a menu or a shell shortcut.
  [switch]$StateOnly,

  # I12. Does the accumulated latch set clear on a focus change, on the passage of
  # time, or neither? Runs both arms with a shared latch procedure so the two
  # explanations can actually be separated. Types nothing except the latch
  # stimulus and the pokes.
  [switch]$FocusTest,
  [int]$FocusWaitSeconds = 30,

  # I12 discriminator. Latch a modifier, then apply N consecutive KEYUP sweeps
  # with NO injected batch between them, and see whether the cache lets go.
  # ONE N PER PROCESS: a fresh process is the only thing known to clear the
  # cache, so running several N in one process contaminates every arm after the
  # first. Compare across invocations, never within one.
  [switch]$SweepTest,
  [int]$SweepCount = 1,

  [switch]$CatalogOnly,
  [switch]$IKnowClearFieldIsDestructive,
  [string]$LogDir = "$env:TEMP\kmrepro"
)
$ErrorActionPreference = 'Stop'

# `powershell -File script.ps1 -Mods A,B` passes "A,B" as ONE string, not an
# array, so a comma list silently matches nothing and every entry is skipped.
# Inherited from an earlier harness, where this bug cost a whole run.
function Split-CommaArg([string[]]$v) {
  if ($null -eq $v) { return @() }
  if ($v.Count -eq 1 -and $v[0] -match ',') { $v = @($v[0] -split '\s*,\s*') }
  return @($v | Where-Object { $_ } | ForEach-Object { $_.Trim() })
}
$Mods  = @((Split-CommaArg $Mods) | ForEach-Object { $_.ToUpper() })
$Only  = @((Split-CommaArg $Only) | ForEach-Object { $_.ToUpper() })
$Latch = $Latch.Trim().ToUpper()

if ($LoadThreads -gt 6) { $LoadThreads = 6 }   # 32 runspaces crashed the host once
if ($TargetProcess -ne 'notepad' -and -not $IKnowClearFieldIsDestructive) {
  throw "This types into the target and clears it between probes. Safe in Notepad; destructive in anything holding data you care about. Notepad is all the repro needs. Pass -IKnowClearFieldIsDestructive to override."
}
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct KmRect { public int Left, Top, Right, Bottom; }

[StructLayout(LayoutKind.Sequential)]
public struct KmGuiThreadInfo {
  public int cbSize;
  public int flags;
  public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
  public KmRect rcCaret;
}

public static class Km {
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern uint RegisterWindowMessage(string s);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out UIntPtr res);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("user32.dll")] public static extern short GetKeyState(int vk);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint tid);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint idThread, ref KmGuiThreadInfo gti);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
}
'@

$UP = 2; $EXT = 1; $FREEZE_CMD = 20

$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$log      = Join-Path $LogDir "mods-$stamp.txt"
$csvPath  = Join-Path $LogDir "mods-$stamp.csv"
$jsonPath = Join-Path $LogDir "mods-$stamp.json"

# DO NOT use Write-Host. Measured 4301 ms/line on a congested console vs 0.4 ms
# for [Console]::Out.WriteLine. That is not a speed problem, it is a CORRECTNESS
# problem: Say is called between the trigger and the probe, and four seconds of
# dead time lets the 5 s freeze expire, silently turning a trial into a
# no-freeze control. Full note at kmproof.ps1:256.
function Say([string]$t) {
  $l = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $t
  [Console]::Out.WriteLine($l)
  Add-Content -Path $log -Value $l -Encoding utf8
}

# ---- key injection ---------------------------------------------------------
# dwExtraInfo stays 0 ON PURPOSE. Keyman filters its own events on
# dwExtraInfo != 0 (k32_lowlevelkeyboardhook.cpp:227), so 0 is what makes it
# treat these as real user input. Converting to SendInput with a marker would
# make the whole harness invisible to Keyman and every test would silently pass.
# HAZARDS.md H4.
function Kd([int]$v, [switch]$E) { $f = 0;   if ($E) { $f = $f -bor $EXT }; [Km]::keybd_event([byte]$v, [byte][Km]::MapVirtualKey($v,0), $f, [UIntPtr]::Zero) }
function Ku([int]$v, [switch]$E) { $f = $UP; if ($E) { $f = $f -bor $EXT }; [Km]::keybd_event([byte]$v, [byte][Km]::MapVirtualKey($v,0), $f, [UIntPtr]::Zero) }
function Tp([int]$v, [int]$g = 70, [switch]$E) { Kd $v -E:$E; Start-Sleep -Milliseconds 40; Ku $v -E:$E; Start-Sleep -Milliseconds $g }

# ---- the modifier catalog --------------------------------------------------
# Ext is the KEYEVENTF_EXTENDEDKEY flag and it is NOT cosmetic. Get it wrong and
# the OS sees a different key entirely: unextended Insert (0x52) is numpad-0 and
# types a digit (HAZARDS.md H1). Only RCtrl (E0 1D), RAlt (E0 38), Insert (E0 52),
# L/RWin (E0 5B/5C) and Apps (E0 5D) are extended. Right SHIFT is scan 0x36 and
# is NOT - see the header note about kmproof.ps1's table.
#
# NumLock is the documented exception: Microsoft's own sample for toggling it
# (KB Q127190) passes KEYEVENTF_EXTENDEDKEY with scan 0x45, so it is flagged
# extended here to match the pattern that is known to work.
#
# CacheA  - is this VK in isModifierKey() / the modifiers[6] arrays? i.e. does
#           the CODE predict it can be phantom-pressed? This is the hypothesis
#           column; the run fills in the observation column.
# Hazard  - drives the post-stimulus cleanup, see Invoke-Hygiene.
#
# Class - 'modifier' is a Cache A slot; 'lock' is a toggle; 'other' is a
#         non-modifier key Keyman's modifier code never touches; 'ordinary' is a
#         plain letter/number/space. The ordinary keys exist because of the
#         ORDINARY KEYS block below - they are always WATCHED, and only INJECTED
#         with -IncludeOrdinary.
$MODCAT = @(
  [pscustomobject]@{ Id='LSHIFT';   Vk=0xA0; Ext=$false; Scan=0x2A; CacheA=$true;  Toggle=$false; Hazard='none';  Class='modifier'; Label='Left Shift' }
  [pscustomobject]@{ Id='RSHIFT';   Vk=0xA1; Ext=$false; Scan=0x36; CacheA=$true;  Toggle=$false; Hazard='none';  Class='modifier'; Label='Right Shift (0x36, NOT extended)' }
  [pscustomobject]@{ Id='LCTRL';    Vk=0xA2; Ext=$false; Scan=0x1D; CacheA=$true;  Toggle=$false; Hazard='accel'; Class='modifier'; Label='Left Ctrl' }
  [pscustomobject]@{ Id='RCTRL';    Vk=0xA3; Ext=$true;  Scan=0x1D; CacheA=$true;  Toggle=$false; Hazard='accel'; Class='modifier'; Label='Right Ctrl (E0 1D)' }
  [pscustomobject]@{ Id='LALT';     Vk=0xA4; Ext=$false; Scan=0x38; CacheA=$true;  Toggle=$false; Hazard='menu';  Class='modifier'; Label='Left Alt' }
  [pscustomobject]@{ Id='RALT';     Vk=0xA5; Ext=$true;  Scan=0x38; CacheA=$true;  Toggle=$false; Hazard='menu';  Class='modifier'; Label='Right Alt / AltGr (E0 38)' }
  [pscustomobject]@{ Id='INSERT';   Vk=0x2D; Ext=$true;  Scan=0x52; CacheA=$false; Toggle=$false; Hazard='none';  Class='other';    Label='Insert (E0 52 - unextended is numpad-0)' }
  [pscustomobject]@{ Id='LWIN';     Vk=0x5B; Ext=$true;  Scan=0x5B; CacheA=$false; Toggle=$false; Hazard='shell'; Class='other';    Label='Left Windows' }
  [pscustomobject]@{ Id='RWIN';     Vk=0x5C; Ext=$true;  Scan=0x5C; CacheA=$false; Toggle=$false; Hazard='shell'; Class='other';    Label='Right Windows' }
  [pscustomobject]@{ Id='APPS';     Vk=0x5D; Ext=$true;  Scan=0x5D; CacheA=$false; Toggle=$false; Hazard='menu';  Class='other';    Label='Apps / context menu' }
  [pscustomobject]@{ Id='NUMLOCK';  Vk=0x90; Ext=$true;  Scan=0x45; CacheA=$false; Toggle=$true;  Hazard='none';  Class='lock';     Label='Num Lock' }
  [pscustomobject]@{ Id='CAPSLOCK'; Vk=0x14; Ext=$false; Scan=0x3A; CacheA=$false; Toggle=$true;  Hazard='none';  Class='lock';     Label='Caps Lock' }
  [pscustomobject]@{ Id='SCROLL';   Vk=0x91; Ext=$false; Scan=0x46; CacheA=$false; Toggle=$true;  Hazard='none';  Class='lock';     Label='Scroll Lock' }

  # ---- ORDINARY KEYS -------------------------------------------------------
  # "Can a LETTER or NUMBER get stuck?" The Cache A answer is a flat no, and it
  # is provable rather than inferred: do_keybd_event() has exactly FOUR call
  # sites in the whole engine, all in keybd_shift.cpp, and they only ever pass
  # modifiers[i] or the prefix VK. UpdateLocalModifierState ends in
  # `default: return;`. Nothing in the modifier path can emit a letter.
  #
  # But there is a SECOND, unrelated path that can, and it has the same
  # unmatched-KEYDOWN shape:
  #
  #   kmprocess.cpp:181-182   app->QueueAction(QIT_VKEYDOWN, _td->state.vkey);
  #                           app->QueueAction(QIT_VKEYUP,   _td->state.vkey);
  #
  #   QueueAction (appint.cpp:51-57) returns FALSE and beeps when the queue is
  #   full at MAXACTIONQUEUE = 1024. BOTH return values are ignored. At exactly
  #   QueueSize == 1023 the VKEYDOWN lands and the VKEYUP is silently dropped.
  #   aiWin2000Unicode.cpp:138-166 then SendInputs a real KEYDOWN for
  #   _td->state.vkey - the key the user just pressed, i.e. an ordinary letter
  #   or digit - with no KEYUP anywhere. That is a stuck letter key.
  #
  # So these are watched on EVERY trial, whatever modifier is under test. If a
  # letter ever reads held, that is not Cache A and must not be reported as it.
  [pscustomobject]@{ Id='KEY_A';    Vk=0x41; Ext=$false; Scan=0x1E; CacheA=$false; Toggle=$false; Hazard='none';  Class='ordinary'; Label='letter A' }
  [pscustomobject]@{ Id='KEY_Z';    Vk=0x5A; Ext=$false; Scan=0x2C; CacheA=$false; Toggle=$false; Hazard='none';  Class='ordinary'; Label='letter Z' }
  [pscustomobject]@{ Id='KEY_1';    Vk=0x31; Ext=$false; Scan=0x02; CacheA=$false; Toggle=$false; Hazard='none';  Class='ordinary'; Label='digit 1' }
  # Alt+Space opens the window system menu, so SPACE is hazard=menu even though
  # it is an ordinary key.
  [pscustomobject]@{ Id='SPACE';    Vk=0x20; Ext=$false; Scan=0x39; CacheA=$false; Toggle=$false; Hazard='menu';  Class='ordinary'; Label='Space' }
)
$MODBYID = @{}
foreach ($m in $MODCAT) { $MODBYID[$m.Id] = $m }
$ORDINARY_IDS = @($MODCAT | Where-Object { $_.Class -eq 'ordinary' } | ForEach-Object { $_.Id })

# ---- the prefix ("zap") VK -------------------------------------------------
# keybd_sendprefix() (keybd_shift.cpp:112-118) injects a dummy key down+up
# around any batch that releases a modifier, so a bare Alt does not open the
# menu. The VK is Globals::get_vk_prefix(), default _VK_PREFIX_DEFAULT = 0x0E
# (aiTIP.h:36) - a RESERVED, undefined VK, chosen precisely so no app maps it.
# It is registry-overridable and UNVALIDATED: k32_globals.cpp:374-380 does
# `f_vk_prefix = reg.ReadInteger(REGSZ_ZapVirtualKeyCode)` straight into a value
# later cast to (BYTE). MODIFIERS.md section 5 covers that much.
#
# What section 5 does NOT cover, and why this is watched here: there are TWO
# emitters of the prefix, and only one is atomic.
#
#   keybd_sendprefix()      writes down+up into the shared INPUT array, flushed
#                           by a single SendInput. Atomic - the pair cannot split.
#   PostDummyKeyEvent()     keyman32.cpp:923-926, TWO separate legacy
#                           keybd_event() calls. NOT atomic. Anything that stops
#                           the thread between line 924 and line 925 - including
#                           the very stall this whole investigation is about -
#                           loses the KEYUP and leaves the prefix VK latched.
#
# On a default machine that latch is VK 0x0E, which no application maps, so it
# is invisible in any text probe - but GetAsyncKeyState reports it, which makes
# it directly measurable. That is exactly what the state oracle is for.
function Get-ZapVk {
  # k32_globals.cpp reads HKEY_LOCAL_MACHINE only, so HKCU is not consulted here
  # even though a stray value there would look alarming in a registry dump.
  foreach ($p in @('HKLM:\SOFTWARE\Keyman\Keyman Engine','HKLM:\SOFTWARE\WOW6432Node\Keyman\Keyman Engine')) {
    try {
      $v = (Get-ItemProperty -Path $p -Name 'zap virtual key code' -ErrorAction Stop).'zap virtual key code'
      if ($null -ne $v) { return [pscustomobject]@{ Vk=([int]$v -band 0xFF); Source=$p; Overridden=$true } }
    } catch { }
  }
  return [pscustomobject]@{ Vk=0x0E; Source='default _VK_PREFIX_DEFAULT (aiTIP.h:36) - no registry override'; Overridden=$false }
}
$ZAP = Get-ZapVk

# Keys that are snapshotted but NEVER injected by this script.
$WATCHONLY = @(
  [pscustomobject]@{ Id='ZAPVK'; Vk=$ZAP.Vk }
)

# The aggregate VKs. Windows reports these as down when either side is down, so
# a disagreement - VK_CONTROL down while neither VK_LCONTROL nor VK_RCONTROL is -
# is itself a diagnostic and is worth logging rather than collapsing away.
$AGGREGATES = @(
  [pscustomobject]@{ Id='SHIFT*';   Vk=0x10 }
  [pscustomobject]@{ Id='CONTROL*'; Vk=0x11 }
  [pscustomobject]@{ Id='MENU*';    Vk=0x12 }
)

$CACHEA_IDS = @($MODCAT | Where-Object { $_.CacheA } | ForEach-Object { $_.Id })

if ($IncludeWin)      { $Mods = @(@($Mods + @('LWIN','RWIN','APPS')) | Select-Object -Unique) }
if ($IncludeOrdinary) { $Mods = @(@($Mods + $ORDINARY_IDS) | Select-Object -Unique) }
foreach ($id in $Mods) {
  if (-not $MODBYID.ContainsKey($id)) { throw "unknown key '$id'. Known: $($MODCAT.Id -join ', ')" }
}
if ($Latch -and -not $MODBYID.ContainsKey($Latch)) { throw "unknown -Latch key '$Latch'" }
if (-not $IncludeWin) {
  $winAsked = @($Mods | Where-Object { $_ -in @('LWIN','RWIN','APPS') })
  if ($winAsked.Count -gt 0) { throw "$($winAsked -join ', ') require -IncludeWin (a latched Win key plus a typed 'l' locks the workstation)." }
}
if (-not $IncludeOrdinary) {
  $ordAsked = @($Mods | Where-Object { $_ -in $ORDINARY_IDS })
  if ($ordAsked.Count -gt 0) { throw "$($ordAsked -join ', ') require -IncludeOrdinary. They are watched on every run either way; the switch only makes them stimulus targets." }
}

# The probe alphabet. j, k, q - see the SAFETY block in the header. Not 'abc'.
$PROBE_VKS   = @(0x4A, 0x4B, 0x51)
$PROBE_LOWER = 'jkq'
$PROBE_UPPER = 'JKQ'
$POKE_VK     = 0x4A     # a single 'j' - bound to nothing under Ctrl or Alt

# ---- state oracle ----------------------------------------------------------
# The authoritative, modifier-agnostic, keystroke-free reading. Everything else
# in this script is subordinate to it.
#
# GetAsyncKeyState high bit = the key is down as far as the OS is concerned,
# system-wide. When the harness is holding nothing, any high bit is a phantom BY
# DEFINITION - which is exactly the observable MODIFIERS.md section 3a names for
# keybd_shift_reset's unmatched KEYDOWN.
#
# GetKeyState & 1 = toggle state, which GetAsyncKeyState does not report at all.
# Only meaningful for the three lock keys.
function Get-ModState {
  $held = @(); $raw = @{}
  foreach ($m in $MODCAT) {
    $down = ((([Km]::GetAsyncKeyState($m.Vk)) -band 0x8000) -ne 0)
    $raw[$m.Id] = $down
    if ($down) { $held += $m.Id }
  }
  $agg = @()
  foreach ($a in $AGGREGATES) {
    $down = ((([Km]::GetAsyncKeyState($a.Vk)) -band 0x8000) -ne 0)
    $raw[$a.Id] = $down
    if ($down) { $agg += $a.Id }
  }
  # Watch-only keys are never injected by this script, so a high bit here can
  # only have come from something else on the machine - which is the point.
  $watch = @()
  foreach ($w in $WATCHONLY) {
    $down = ((([Km]::GetAsyncKeyState($w.Vk)) -band 0x8000) -ne 0)
    $raw[$w.Id] = $down
    if ($down) { $watch += $w.Id }
  }
  $tog = @{
    CAPSLOCK = (([Km]::GetKeyState(0x14)) -band 1)
    NUMLOCK  = (([Km]::GetKeyState(0x90)) -band 1)
    SCROLL   = (([Km]::GetKeyState(0x91)) -band 1)
  }
  $heldTxt = 'none'; if ($held.Count -gt 0) { $heldTxt = ($held -join ',') }
  $aggTxt  = 'none'; if ($agg.Count  -gt 0) { $aggTxt  = ($agg  -join ',') }
  if ($watch.Count -gt 0) { $heldTxt = $heldTxt + '+' + ($watch -join ',') }
  return [pscustomobject]@{
    Held       = $held
    HeldText   = $heldTxt
    Agg        = $agg
    AggText    = $aggTxt
    Watch      = $watch
    Toggle     = $tog
    ToggleText = ('caps={0} num={1} scroll={2}' -f $tog.CAPSLOCK,$tog.NUMLOCK,$tog.SCROLL)
    Raw        = $raw
    # The subset MODIFIERS.md section 2 says CAN latch...
    CacheAHeld = @($held | Where-Object { $_ -in $CACHEA_IDS })
    # ...an ordinary letter/number, which points at kmprocess.cpp:181-182 and
    # NOT at Cache A - a different defect that must not be reported as this one...
    KeyHeld    = @($held | Where-Object { $_ -in $ORDINARY_IDS })
    # ...and everything else it says cannot latch. Anything here refutes the table.
    OtherHeld  = @($held | Where-Object { $_ -notin $CACHEA_IDS -and $_ -notin $ORDINARY_IDS })
  }
}

# Is it safe to send letters right now? A latched Win key means no, ever:
# Win+L locks the workstation and the run is over. Ctrl and Alt are survivable
# with the fixed j/k/q alphabet, which is bound to nothing.
function Get-TypeSafety($st) {
  if ($st.Raw['LWIN'] -or $st.Raw['RWIN']) { return [pscustomobject]@{ Safe=$false; Why='a Windows key reads HELD - refusing to type (Win+L would lock the session)' } }
  if ($st.Raw['APPS'])                     { return [pscustomobject]@{ Safe=$false; Why='Apps key reads HELD - a context menu would eat the probe' } }
  return [pscustomobject]@{ Safe=$true; Why='' }
}

# ---- the only place the active keyboard is read ----------------------------
# GetGUIThreadInfo(0).hwndFocus, NOT the top-level window. Windows 11 Notepad
# keeps its frame window on a thread pinned at 0x0409 forever while the focused
# RichEditD2DPT sits on a thread that does track the input locale, so resolving
# from MainWindowHandle reads the wrong thread and always says US.
# HAZARDS.md H3; kmproof.ps1 "THE HKL ORACLE, CORRECTED".
function Resolve-Arm([int64]$lang, [int64]$high) {
  # en-US carries two input methods on this machine (US 00000409 and Dvorak,
  # which comes back as high word 0xF002, a substitution handle). 'jkq' is not
  # 'jkq' on Dvorak, so anything that is not exactly 0x04090409 is rejected
  # rather than measured.
  if ($lang -eq 0x0409 -and $high -eq 0x0409) { return 'US' }
  if ($lang -eq 0x0409)                       { return ('en-US-not-plain-US-0x{0:X4}-REJECT' -f $high) }
  if ($lang -eq 0x0436)                       { return 'MSKLC' }
  if ($lang -eq 0x2000)                       { return 'Keyman' }
  if ($lang -eq 0x046A)                       { return 'Keyman-Yoruba' }
  return ('unknown-0x{0:X4}' -f $lang)
}
function Get-FocusKeyboard {
  $g = New-Object KmGuiThreadInfo
  $g.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($g)
  if (-not [Km]::GetGUIThreadInfo(0, [ref]$g)) {
    return [pscustomobject]@{ Ok=$false; Hkl=0; LangId=0; HighWord=0; Tid=0; Pid=0; Class=''; Arm='<no-gui-info>' }
  }
  $h = $g.hwndFocus
  if ($h -eq [IntPtr]::Zero) { $h = $g.hwndActive }
  if ($h -eq [IntPtr]::Zero) {
    return [pscustomobject]@{ Ok=$false; Hkl=0; LangId=0; HighWord=0; Tid=0; Pid=0; Class=''; Arm='<no-focus>' }
  }
  $p = 0
  $tid = [Km]::GetWindowThreadProcessId($h, [ref]$p)
  $hkl = [Km]::GetKeyboardLayout($tid).ToInt64()
  $sb = New-Object System.Text.StringBuilder 256
  [void][Km]::GetClassName($h, $sb, 256)
  $lang = $hkl -band 0xFFFF
  $high = ($hkl -shr 16) -band 0xFFFF
  return [pscustomobject]@{
    Ok=$true; Hkl=$hkl; LangId=$lang; HighWord=$high; Tid=$tid; Pid=$p
    Class=$sb.ToString(); Arm=(Resolve-Arm $lang $high)
  }
}
function Format-Keyboard($k) {
  if (-not $k.Ok) { return $k.Arm }
  return ('{0} (HKL=0x{1:X8} langid=0x{2:X4} tid={3} cls={4})' -f $k.Arm,$k.Hkl,$k.LangId,$k.Tid,$k.Class)
}

# ---- target window + text readback ----------------------------------------
# -CatalogOnly deliberately does not need a target: the catalog and the state
# snapshot are useful on any machine, with or without Notepad open.
$target = [IntPtr]::Zero
$vp     = $null
if (-not $CatalogOnly) {
  $np = Get-Process -Name $TargetProcess -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $np) { Say "[FAIL] no '$TargetProcess' window. Open it and re-run (or use -CatalogOnly)."; exit 1 }
  $target = $np.MainWindowHandle
  [void][Km]::SetForegroundWindow($target); Start-Sleep -Milliseconds 600

  $root  = [System.Windows.Automation.AutomationElement]::FromHandle($target)
  $cond  = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Document)
  $docEl = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
  if (-not $docEl) { Say '[FAIL] no Document element'; exit 1 }
  $vp = $docEl.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
}

function Get-DocText {
  if ($null -eq $vp) { return '' }
  try { $t = $vp.Current.Value } catch { $t = '' }
  if ($null -eq $t) { $t = '' }
  return $t
}
function Show-Cp([string]$t) {
  if (-not $t) { return '<empty>' }
  return (($t.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ')
}
function Assert-Foreground {
  if ($target -eq [IntPtr]::Zero) { return $true }
  if ([Km]::GetForegroundWindow() -ne $target) {
    Tp 0x1B 80
    [void][Km]::SetForegroundWindow($target)
    Start-Sleep -Milliseconds 400
  }
  return ([Km]::GetForegroundWindow() -eq $target)
}

# Clear PROGRAMMATICALLY. A keystroke-based clear (Ctrl+A then Delete) fails
# silently in exactly the state this script measures: with a phantom Shift
# latched it becomes Ctrl+Shift+A and Shift+Delete and the field never empties,
# after which every probe reads the accumulated buffer and scores OTHER. With a
# phantom Ctrl latched it is worse still. UIA SetValue touches no keys.
#
# There is deliberately NO keystroke fallback. kmproof has one; here it would be
# actively misleading, because a keystroke clear is meaningless while a modifier
# is latched and a latched modifier is the entire subject.
function ClearField {
  if ($null -eq $vp) { return $false }
  try {
    $vp.SetValue('')
    Start-Sleep -Milliseconds 120
    if ([string]::IsNullOrEmpty((Get-DocText))) { return $true }
  } catch { }
  Say '        [WARN] UIA SetValue clear failed. Not falling back to keystrokes - see the comment.'
  return $false
}

# ---- keyman.exe control window + the freeze stimulus -----------------------
$script:km = [IntPtr]::Zero
$kp = (Get-Process keyman -ErrorAction SilentlyContinue | Select-Object -First 1).Id
if ($kp) {
  $cb = [Km+EnumWindowsProc]{ param($h,$l)
    $p=0; [void][Km]::GetWindowThreadProcessId($h,[ref]$p)
    if ($p -eq $kp) {
      $sb=New-Object System.Text.StringBuilder 256; [void][Km]::GetClassName($h,$sb,256)
      if ($sb.ToString() -eq 'TApplication') { $script:km=$h; return $false }
    }
    return $true }
  [void][Km]::EnumWindows($cb,[IntPtr]::Zero)
}
$msg = [Km]::RegisterWindowMessage('WM_KEYMAN_CONTROL')
function Freeze {
  if ($script:km -ne [IntPtr]::Zero) { [void][Km]::PostMessage($script:km,$msg,[IntPtr]$FREEZE_CMD,[IntPtr]::Zero) }
}
# PostMessage is asynchronous: posting cmd 20 does not tell us when keyman.exe
# actually enters its Sleep(5000). With a fixed delay the KEYUP can be released
# BEFORE the freeze begins and the trial degenerates into a no-freeze control.
# That is why kmproof's candidate B is intermittent and candidate I is not.
function WaitForFreeze([int]$timeoutMs = 3000) {
  if ($script:km -eq [IntPtr]::Zero) { return $false }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
    $r = [UIntPtr]::Zero
    $ok = [Km]::SendMessageTimeout($script:km, 0, [IntPtr]::Zero, [IntPtr]::Zero, 2, 60, [ref]$r)
    if ($ok -eq [IntPtr]::Zero) { return $true }   # no reply = the UI thread is blocked
    Start-Sleep -Milliseconds 20
  }
  return $false
}

# ---- recovery --------------------------------------------------------------
# Release EVERY key in the catalog with its correct extended flag, then read
# back. "Which recovery worked" is data, not housekeeping: it is the direct test
# of MODIFIERS.md section 3b, which says a latched slot can only be cleared by
# the exact matching KEYUP - so a modifier the keyboard does not physically have
# cannot be cleared at all.
#
# The six Cache A keys are released UNCONDITIONALLY, because that is exactly the
# documented user workaround ("tap each of Shift, Ctrl, Alt, both sides") and
# keeping it unconditional keeps the result comparable with kmproof's ClearMods.
# Everything else is released ONLY if it currently reads held. An orphan KEYUP
# for a key that was never down is a no-op in the best case, but this function
# also runs in the finally block of every invocation, and sending an unprovoked
# Win KEYUP into the shell on the way out is not a risk worth taking for no gain.
function Release-All {
  $st = Get-ModState
  foreach ($m in $MODCAT) {
    if ($m.Toggle) { continue }               # toggles are not "held"; tapping one flips state
    if (-not $m.CacheA -and -not $st.Raw[$m.Id]) { continue }
    Ku $m.Vk -E:$m.Ext
    Start-Sleep -Milliseconds 45
  }
  foreach ($a in $AGGREGATES) { Ku $a.Vk; Start-Sleep -Milliseconds 30 }
  Start-Sleep -Milliseconds 250
}
function Tap-AllCacheA {
  foreach ($m in $MODCAT) {
    if (-not $m.CacheA) { continue }
    Kd $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 90
    Ku $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 90
  }
  Tp 0x1B 80; Tp 0x1B 80        # a lone Alt tap activates the menu bar; dismiss it
  Start-Sleep -Milliseconds 300
}

# Post-stimulus cleanup, driven by the catalog's Hazard column. Runs BEFORE the
# state snapshot for the menu/shell classes, because a menu that owns the focus
# makes every later probe meaningless - but Escape is itself a real keystroke
# that could perturb Keyman, so what was sent is recorded on the row.
function Invoke-Hygiene($m) {
  $acts = @()
  switch ($m.Hazard) {
    'menu'  { Tp 0x1B 90; Tp 0x1B 90; $acts += 'esc x2' }
    'shell' { Start-Sleep -Milliseconds 500; Tp 0x1B 90; Tp 0x1B 90; $acts += 'esc x2 (start menu)' }
    default { $acts += 'none' }
  }
  if (-not (Assert-Foreground)) { $acts += 'FOREGROUND-LOST' }
  return ($acts -join '+')
}

# Toggles flip on the KEYDOWN, so any stimulus that presses one leaves the
# machine in a different state than it found it. A flipped CapsLock would invert
# every later text probe and quietly turn CLEAN into WEDGED for the rest of the
# run, so this restores and VERIFIES rather than assuming.
function Restore-Toggle($m, $before) {
  if (-not $m.Toggle) { return 'n/a' }
  $cur = (Get-ModState).Toggle[$m.Id]
  if ($cur -eq $before) { return ('unchanged({0})' -f $cur) }
  Tp $m.Vk 120 -E:$m.Ext
  Start-Sleep -Milliseconds 200
  $after = (Get-ModState).Toggle[$m.Id]
  if ($after -eq $before) { return ('flipped {0}->{1}, restored' -f $before,$cur) }
  return ('*** FLIPPED {0}->{1} AND COULD NOT RESTORE (now {2}) ***' -f $before,$cur,$after)
}

# ---- oracles ---------------------------------------------------------------
# The poke. Cache A can be corrupt while OS key state is still clean, because
# the phantom is only EMITTED when keybd_shift_reset runs, which happens when
# Keyman prepares an injected batch. One keystroke through the Keyman keyboard
# forces that batch. Snapshots either side, so a row can say whether the latch
# pre-existed or whether Keyman produced it on the spot.
function Invoke-Poke {
  $before = Get-ModState
  $safety = Get-TypeSafety $before
  if (-not $safety.Safe) {
    return [pscustomobject]@{ Before=$before; After=$before; Poked=$false; Why=$safety.Why }
  }
  [void](ClearField)
  Tp $POKE_VK 160
  Start-Sleep -Milliseconds 250
  $after = Get-ModState
  [void](ClearField)
  return [pscustomobject]@{ Before=$before; After=$after; Poked=$true; Why='' }
}

# The text oracle. Subordinate to the state oracle and only run when typing is
# safe. The alphabet is FIXED at j / k / q - see the SAFETY block in the header
# for the full list of what Ctrl+letter does in current Notepad and why 'abc'
# (kmproof's alphabet) is no longer safe.
function Probe-TextOnce {
  if (-not (ClearField)) { return [pscustomobject]@{ Text=''; Cp='<clear-failed>'; Kind='UNREADABLE' } }
  foreach ($v in $PROBE_VKS) { Tp $v 110 }
  Start-Sleep -Milliseconds 450
  $t = Get-DocText
  # -ceq, NOT -eq. PowerShell's -eq is case-INSENSITIVE, so 'jkq' -eq 'JKQ' is
  # TRUE and every wedged result would compare equal to the clean one. This trap
  # has already cost this repo a full round of results.
  $kind = 'OTHER'
  if     ($t -ceq $PROBE_LOWER) { $kind = 'LOWER' }
  elseif ($t -ceq $PROBE_UPPER) { $kind = 'UPPER' }
  elseif ([string]::IsNullOrEmpty($t)) { $kind = 'EMPTY' }
  return [pscustomobject]@{ Text=$t; Cp=(Show-Cp $t); Kind=$kind }
}

# THE CLASSIFIER. This is the part kmproof.ps1 cannot do.
#
# Crossing the state oracle with the text oracle separates the two caches that
# MODIFIERS.md section 1 is built on, and separates both from "the keys just
# vanished", which is a third thing neither cache explains:
#
#   held Cache A key            -> PHANTOM:<ID>   Cache A. A real OS-level key
#                                                 state Keyman injected. Machine
#                                                 wide; affects every app.
#   held non-Cache-A key        -> SCOPE-BREAK    MODIFIERS.md section 2 is wrong.
#   nothing held + text UPPER   -> CACHEB-SHIFT   Cache B. Keyman's cached shift
#                                                 flag is wrong while the OS is
#                                                 clean. The #16423 class.
#   nothing held + text EMPTY   -> SWALLOWED      Keys went into Keyman and did
#                                                 not come out. Neither cache
#                                                 explains it.
#   nothing held + text lower   -> CLEAN
function Get-Verdict($state, $text) {
  # Ordered most-specific first: each of these has a DIFFERENT mechanism behind
  # it, and collapsing them into one "wedged" bucket is exactly the mistake that
  # left Ctrl unmeasured for so long.
  if ($state.Watch.Count -gt 0)      { return ('PREFIX-LATCH:' + ($state.Watch -join '+')) }
  if ($state.KeyHeld.Count -gt 0)    { return ('KEY-LATCH:'    + ($state.KeyHeld -join '+')) }
  if ($state.OtherHeld.Count -gt 0)  { return ('SCOPE-BREAK:'  + ($state.OtherHeld -join '+')) }
  if ($state.CacheAHeld.Count -gt 0) { return ('PHANTOM:'      + ($state.CacheAHeld -join '+')) }
  if ($null -eq $text)               { return 'STATE-CLEAN' }
  switch ($text.Kind) {
    'LOWER'      { return 'CLEAN' }
    'UPPER'      { return 'CACHEB-SHIFT' }
    'EMPTY'      { return 'SWALLOWED' }
    'UNREADABLE' { return 'UNREADABLE' }
    default      { return ('OTHER:' + $text.Cp) }
  }
}

# ---- arm switching --------------------------------------------------------
# Auto mode drives the real user path (Win+Space) and verifies the landing on
# the focus thread after every press. TSF profile activation is per-thread
# inside the owning process and cannot be driven from here anyway, so Win+Space
# is not just the faithful route, it is the only one.
function Tap-WinSpace {
  Kd 0x5B -E; Start-Sleep -Milliseconds 140       # LWIN is extended
  Tp 0x20 140
  Ku 0x5B -E; Start-Sleep -Milliseconds 500
}
function Switch-ToArm([string]$want) {
  $k = Get-FocusKeyboard
  if ($k.Arm -eq $want) { return $k }
  if ($SwitchMode -eq 'Manual') {
    Say ("  switch to '{0}' by hand now. Waiting up to 120s..." -f $want)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 120) {
      Start-Sleep -Milliseconds 700
      $k = Get-FocusKeyboard
      if ($k.Arm -eq $want) { return $k }
    }
    return $k
  }
  for ($i = 1; $i -le $SwitchTries; $i++) {
    [void](Assert-Foreground)
    Tap-WinSpace
    [void](Assert-Foreground)
    $k = Get-FocusKeyboard
    Say ("  Win+Space #{0} -> {1}" -f $i, (Format-Keyboard $k))
    if ($k.Arm -eq $want) { return $k }
  }
  return $k
}

# ---- candidates ------------------------------------------------------------
# Each takes the catalog entry for the modifier under test, so the SAME stimulus
# runs against all thirteen keys. That is the point: the only variable is which
# key is held, which is what makes the immune keys a real negative control
# rather than a different experiment.
#
#   A is the internal control - a bare hold with NO freeze. If A latches
#     anything, the freeze is not the mechanism and TRIGGER.md is wrong.
#   I is the primary - kmproof's candidate B made deterministic by confirming
#     the stall is live before releasing, instead of guessing with a fixed delay.
#   X is new here. It holds LShift as well and releases the key under test
#     FIRST. ProcessModifierChange gives Shift one combined K_SHIFTFLAG while
#     Ctrl and Alt get independent L/R flags (MODIFIERS.md finding 4c), so an
#     out-of-order release across two different modifiers is the case most
#     likely to strand one of them.
$CANDIDATES = @(
  @{ Id='A'; Desc='bare hold 1.5s + release, NO freeze (internal control)'; Act={ param($m)
       Kd $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 1500
       Ku $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 400 } }

  @{ Id='I'; Desc='hold, freeze CONFIRMED ACTIVE, release into the stall (primary)'; Act={ param($m)
       Kd $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 1400
       Freeze
       $live = WaitForFreeze 3000
       if (-not $live) { Say '        [WARN] freeze never confirmed - this iteration is NOT a valid trial' }
       Ku $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 400 } }

  @{ Id='E'; Desc='hold, freeze, then up/down/up entirely inside the stall'; Act={ param($m)
       Kd $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 1400
       Freeze; [void](WaitForFreeze 3000)
       Ku $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 120
       Kd $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 120
       Ku $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 400 } }

  @{ Id='H'; Desc='hold across a freeze re-posted 3x (long stall)'; Act={ param($m)
       Kd $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 1400
       Freeze; Start-Sleep -Milliseconds 100
       Freeze; Freeze
       Ku $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 400 } }

  @{ Id='X'; Desc='LShift + this key, freeze, release THIS key first (out of order)'; Act={ param($m)
       Kd 0xA0; Start-Sleep -Milliseconds 80
       Kd $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 1400
       Freeze; [void](WaitForFreeze 3000)
       Ku $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 120
       Ku 0xA0; Start-Sleep -Milliseconds 400 } }
)

# ---- load emulation --------------------------------------------------------
# Capped at 6: 32 runspaces exhausted memory and crashed the host PowerShell in
# an earlier session.
$loadJobs = @()
if ($LoadThreads -gt 0) {
  for ($i=1; $i -le $LoadThreads; $i++) {
    $loadJobs += Start-Job -ScriptBlock { $x=0.0; while ($true) { $x=[math]::Sqrt([math]::Abs([math]::Sin($x)*1000000.0)) } }
  }
  Start-Sleep -Seconds 2
}

$results = @()
$notes   = @()

try {
  Say '============ kmmods: which modifiers can this bug actually stick? ============'
  Say ("target={0} hwnd=0x{1:X}  keyman ctrl=0x{2:X}  keyboard={3}  load={4}  repeat={5}" -f `
        $TargetProcess,$target.ToInt64(),$script:km.ToInt64(),$Keyboard,$LoadThreads,$Repeat)
  if ($script:km -eq [IntPtr]::Zero) {
    Say '[WARN] keyman.exe TApplication window not found - the freeze stimulus is a NO-OP.'
    Say '       Every row below would then be a no-freeze control. Fix this before quoting any of it.'
  }
  Say ("probe alphabet = '{0}' (j/k/q: bound to nothing under Ctrl or Alt in Notepad)" -f $PROBE_LOWER)
  Say ("log = {0}" -f $log)
  Say ''

  # ---- catalog -------------------------------------------------------------
  Say 'KEY CATALOG (Ext and Scan are load-bearing - HAZARDS.md H1)'
  Say ('  {0,-9} {1,-5} {2,-4} {3,-14} {4,-9} {5,-7} {6,-7} {7}' -f 'id','vk','ext','scan','class','cacheA','hazard','label')
  foreach ($m in $MODCAT) {
    $actual = [Km]::MapVirtualKey($m.Vk,0)
    $scanTag = ('0x{0:X2}' -f $m.Scan)
    if ($actual -ne $m.Scan) { $scanTag = ('0x{0:X2}!=map0x{1:X2}' -f $m.Scan,$actual) }
    $tgt = ''
    if ($m.Id -in $Mods) { $tgt = ' <- target' }
    Say ('  {0,-9} 0x{1:X2}  {2,-4} {3,-14} {4,-9} {5,-7} {6,-7} {7}{8}' -f `
          $m.Id,$m.Vk,$(if($m.Ext){'yes'}else{'no'}),$scanTag,$m.Class,$(if($m.CacheA){'YES'}else{'no'}),$m.Hazard,$m.Label,$tgt)
    if ($actual -ne $m.Scan) {
      Say  '           [WARN] MapVirtualKey disagrees with the expected scan code on this machine.'
      Say  '                  Injection uses MapVirtualKey, so this key may be hitting something else.'
    }
  }
  Say ''
  # The prefix VK. Watched, never injected. See the Get-ZapVk comment block.
  Say ('  ZAPVK     0x{0:X2}  watch-only, never injected by this script' -f $ZAP.Vk)
  Say ('            source: {0}' -f $ZAP.Source)
  if ($ZAP.Overridden) {
    Say  '            [WARN] the prefix VK is OVERRIDDEN in the registry. k32_globals.cpp:374-380'
    Say  '                   reads this value with NO validation, so Keyman is injecting a real,'
    Say  '                   app-visible key around every modifier-bearing keystroke. Check that'
    Say  '                   this is deliberate before attributing anything else on this machine.'
  } else {
    Say  '            0x0E is a reserved VK that no application maps, so a latch here is invisible'
    Say  '            in any text probe but fully visible to GetAsyncKeyState. That is the only'
    Say  '            way to catch a lost KEYUP from PostDummyKeyEvent (keyman32.cpp:923-926,'
    Say  '            two separate keybd_event calls, not an atomic SendInput batch).'
  }
  Say ''
  $st0 = Get-ModState
  Say ("baseline state: held={0}  aggregates={1}  {2}" -f $st0.HeldText,$st0.AggText,$st0.ToggleText)
  if ($st0.Held.Count -gt 0) {
    Say '[IMPORTANT] a modifier is already HELD before this script touched anything.'
    Say '            Attempting a release sweep.'
    Release-All
    $st0 = Get-ModState
    Say ("            after release sweep: held={0}" -f $st0.HeldText)
  }
  if ($CatalogOnly) { Say ''; Say 'CatalogOnly - nothing injected.'; Say ("  log : {0}" -f $log); return }
  Say ''

  # ---- H3: the permanence arm ---------------------------------------------
  # MODIFIERS.md section 3b makes the sharpest and least-tested claim in the
  # document: a latched modifier is cleared ONLY by the exact matching KEYUP, so
  # a user whose keyboard has no Right Ctrl key cannot clear a latched Right
  # Ctrl at all and the state persists until Keyman restarts. That is what
  # explains the field reports the current repro cannot.
  #
  # This tests it without needing the hardware: latch the key by injection
  # exactly the way keybd_shift_reset does, then try each candidate clearing
  # action in turn and record which, if any, works.
  if ($Latch) {
    $m = $MODBYID[$Latch]
    Say ('================ PERMANENCE ARM: latch {0} ================' -f $m.Id)
    Say ('  {0}' -f $m.Label)
    Say  '  This latches a real, OS-visible key state. It is released in the finally block no'
    Say  '  matter how this exits, but while it is held EVERY app on the machine sees it.'
    Say ''

    # Emit it the way keybd_shift.cpp:69-73 does. do_keybd_event rewrites
    # VK_RCONTROL to VK_CONTROL + KEYEVENTF_EXTENDEDKEY and VK_LCONTROL to bare
    # VK_CONTROL, so reproducing the byte pattern - not just the VK - is what
    # makes this a faithful stand-in for keybd_shift_reset's unmatched KEYDOWN.
    $emitVk = $m.Vk; $emitExt = $m.Ext
    switch ($m.Id) {
      'RCTRL'  { $emitVk = 0x11; $emitExt = $true  }   # VK_CONTROL + extended
      'LCTRL'  { $emitVk = 0x11; $emitExt = $false }
      'RALT'   { $emitVk = 0x12; $emitExt = $true  }   # VK_MENU + extended
      'LALT'   { $emitVk = 0x12; $emitExt = $false }
      'RSHIFT' { $emitVk = 0xA1; $emitExt = $false }   # shift keeps its side-specific VK
      'LSHIFT' { $emitVk = 0xA0; $emitExt = $false }
    }
    Say ('  emitting KEYDOWN vk=0x{0:X2} scan=0x{1:X2} ext={2}, with NO matching KEYUP' -f `
          $emitVk,[Km]::MapVirtualKey($emitVk,0),$emitExt)
    Kd $emitVk -E:$emitExt
    Start-Sleep -Milliseconds 400

    $s = Get-ModState
    Say ("  after injection: held={0}  aggregates={1}" -f $s.HeldText,$s.AggText)
    if (-not $s.Raw[$m.Id]) {
      Say ('  [FAIL] {0} does not read as held after the injection. The byte pattern above did not' -f $m.Id)
      Say  '         resolve to this key on this machine. Nothing further can be measured.'
    } else {
      Say ('  [LATCHED] GetAsyncKeyState reports {0} held system-wide, with no physical key involved.' -f $m.Id)
      Say  '            That is MODIFIERS.md section 3a reproduced directly.'
      Say ''
      $steps = @()

      # 1. does ordinary typing clear it?
      $tf = Get-TypeSafety (Get-ModState)
      if ($tf.Safe) {
        $t = Probe-TextOnce
        $s = Get-ModState
        $steps += [pscustomobject]@{ Step='type probe'; Cleared=(-not $s.Raw[$m.Id]); Detail=("text={0} held={1}" -f $t.Cp,$s.HeldText) }
        Say ("  1. typed '{0}'                  -> text {1,-26} still held: {2}" -f $PROBE_LOWER,$t.Cp,$s.Raw[$m.Id])
      } else {
        $steps += [pscustomobject]@{ Step='type probe'; Cleared=$false; Detail=('skipped: ' + $tf.Why) }
        Say ("  1. typing skipped               -> {0}" -f $tf.Why)
      }

      # 2. does tapping the OTHER SIDE clear it? This is the crux. If tapping
      #    LCtrl clears a latched RCtrl then the "no physical Right Ctrl" story
      #    collapses, because every keyboard has a Left Ctrl.
      $sibling = $null
      switch ($m.Id) {
        'RCTRL'  { $sibling = $MODBYID['LCTRL']  }
        'LCTRL'  { $sibling = $MODBYID['RCTRL']  }
        'RALT'   { $sibling = $MODBYID['LALT']   }
        'LALT'   { $sibling = $MODBYID['RALT']   }
        'RSHIFT' { $sibling = $MODBYID['LSHIFT'] }
        'LSHIFT' { $sibling = $MODBYID['RSHIFT'] }
      }
      if ($sibling -and (Get-ModState).Raw[$m.Id]) {
        Kd $sibling.Vk -E:$sibling.Ext; Start-Sleep -Milliseconds 90
        Ku $sibling.Vk -E:$sibling.Ext; Start-Sleep -Milliseconds 300
        $s = Get-ModState
        $steps += [pscustomobject]@{ Step=('tap ' + $sibling.Id); Cleared=(-not $s.Raw[$m.Id]); Detail=("held=" + $s.HeldText) }
        Say ("  2. tapped the other side ({0,-6}) -> still held: {1}" -f $sibling.Id,$s.Raw[$m.Id])
        if (-not $s.Raw[$m.Id]) {
          Say  '     [NOTE] the sibling tap CLEARED it. MODIFIERS.md section 3b says only the exact'
          Say  '            matching KEYUP clears the slot, so this needs explaining before the'
          Say  '            "no physical Right Ctrl" story can be quoted.'
        }
      }

      # 3. the exact matching KEYUP - the documented workaround, and the one a
      #    user with no such physical key cannot produce.
      if ((Get-ModState).Raw[$m.Id]) {
        Ku $m.Vk -E:$m.Ext; Start-Sleep -Milliseconds 300
        $s = Get-ModState
        $steps += [pscustomobject]@{ Step=('exact KEYUP ' + $m.Id); Cleared=(-not $s.Raw[$m.Id]); Detail=("held=" + $s.HeldText) }
        Say ("  3. exact matching KEYUP         -> still held: {0}" -f $s.Raw[$m.Id])
      }

      Say ''
      Say 'PERMANENCE RESULT'
      $clearedBy = @($steps | Where-Object { $_.Cleared } | ForEach-Object { $_.Step })
      if ($clearedBy.Count -eq 0) {
        Say ('  Nothing cleared {0}. Keyman restart is the documented fallback; not doing that here.' -f $m.Id)
      } else {
        Say ('  First thing that cleared it: {0}' -f $clearedBy[0])
        if ($clearedBy[0] -like 'exact KEYUP*') {
          Say  '  ONLY the exact matching KEYUP cleared it. That is MODIFIERS.md section 3b confirmed:'
          Say ('  a user on hardware with no physical {0} key cannot produce this event, so for them' -f $m.Id)
          Say  '  the latch persists until Keyman is restarted. Persistence-until-restart is then'
          Say  '  EXPECTED behaviour, not the unexplained gap FIX-PROPOSAL.md currently calls it.'
        }
      }
      foreach ($s2 in $steps) {
        $results += [pscustomobject]@{
          Mod=$m.Id; CacheAPredicted=$m.CacheA; Candidate='LATCH'; Desc='H3 permanence arm'; Pass=1
          Verdict=''; SelfLatched=''; Residual=''
          HeldBeforePoke=''; HeldAfter=''; Agg=''; Toggles=''; ToggleNote=''
          TextKind=''; Cp=''; TextNote=''; Hygiene=''
          Keyboard=$Keyboard; LangId=''; Hkl=''; ArmConfirmed=$true; Valid=$true; LoadThreads=$LoadThreads
          Step=$s2.Step; Cleared=$s2.Cleared; Detail=$s2.Detail
        }
      }
    }
    Say ''
    if ($results.Count -gt 0) { $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8; Say ("  csv : {0}" -f $csvPath) }
    Say ("  log : {0}" -f $log)
    Say '=============================================================================='
    return
  }

  # ---- I12 discriminator: is it the process boundary, or just a 2nd sweep? --
  # MODIFIERS.md section 2c established that the latch survives a 30 s wait and a
  # verified focus round-trip, but not a process boundary crossed 9 s later. That
  # reading is CONFOUNDED, and this mode is the control for it.
  #
  # In the trial loop the recovery is exactly ONE Release-All, and the next
  # trial's poke still finds the cache dirty. But on the way out the script runs
  # a SECOND Release-All from its finally block, with no injected batch between
  # the two - something no in-loop recovery ever does. So "the process boundary
  # cleared it" and "two back-to-back sweeps cleared it" fit every observation
  # equally well, and they imply completely different fixes:
  #
  #   process boundary  -> the state is scoped to something that dies with the
  #                        injecting process. Direct evidence for I6.
  #   second sweep      -> one sweep is simply not enough. That would mean the
  #                        documented user workaround ("tap each of the six") is
  #                        under-specified, and it changes D1 substantially.
  if ($SweepTest) {
    Say ('================ I12 discriminator: {0} consecutive KEYUP sweep(s) ================' -f $SweepCount)
    Say  '  Run this ONCE PER PROCESS per N and compare across invocations. Do not loop N here:'
    Say  '  a fresh process is the only known way to clear the cache, so arm 2 onwards would be'
    Say  '  measuring a cache that arm 1 already dirtied.'
    Say ''

    $lm = $MODBYID['LSHIFT']
    [void](Switch-ToArm $Keyboard)

    Release-All
    $c = Get-ModState
    if ($c.Held.Count -gt 0) { Say ('  [ABORT] could not reach a clean start (held={0})' -f $c.HeldText); return }
    Say  '  clean start confirmed (held=none)'

    Kd $lm.Vk; Start-Sleep -Milliseconds 1400
    Freeze
    if (-not (WaitForFreeze 3000)) { Say '  [WARN] freeze never confirmed - this latch attempt is not valid' }
    Ku $lm.Vk; Start-Sleep -Milliseconds 400

    $p1 = Invoke-Poke
    if (-not $p1.After.Raw['LSHIFT']) { Say '  [ABORT] the stimulus did not latch LSHIFT; nothing to test'; return }
    Say ('  latched: held={0}' -f $p1.After.HeldText)

    # The N sweeps. Nothing is injected between them except the sweeps' own
    # KEYUPs - no poke, no text probe, no batch.
    for ($i = 1; $i -le $SweepCount; $i++) {
      Release-All
      $st = Get-ModState
      Say ('  sweep {0}/{1} -> OS state now held={2}' -f $i,$SweepCount,$st.HeldText)
    }

    # Now poke and see whether the cache re-asserts.
    $p2 = Invoke-Poke
    $cleared = -not $p2.After.Raw['LSHIFT']
    Say ('  poke after {0} sweep(s): held={1}' -f $SweepCount,$p2.After.HeldText)
    Say ''
    Say 'I12 DISCRIMINATOR RESULT'
    Say ('  sweeps={0}  cache cleared={1}' -f $SweepCount,$cleared)
    Say ''
    if ($SweepCount -eq 1 -and -not $cleared) {
      Say  '  Expected: one sweep does not clear it. This reproduces the in-loop behaviour and'
      Say  '  is the control. Now run the same command with -SweepCount 2 in a NEW process.'
    } elseif ($SweepCount -ge 2 -and $cleared) {
      Say ('  [SECOND SWEEP] {0} consecutive sweeps cleared the cache, inside one process, with' -f $SweepCount)
      Say  '  no process boundary involved. So MODIFIERS.md section 2c'"'"'s "crossing a process'
      Say  '  boundary clears it" was an ARTEFACT of the finally block running a second sweep.'
      Say  '  Consequences:'
      Say  '    - the documented workaround ("tap each of the six once") is UNDER-SPECIFIED;'
      Say  '      one pass is not enough and the user would conclude it did not work.'
      Say  '    - D1 changes: the resync has to survive being applied while Keyman is still'
      Say  '      re-asserting, not merely happen once at batch start.'
      Say  '    - I6 gets no support from this after all.'
    } elseif ($SweepCount -ge 2 -and -not $cleared) {
      Say ('  [NOT THE SWEEP] {0} consecutive sweeps did NOT clear it. Combined with the 30 s' -f $SweepCount)
      Say  '  wait and the focus round-trip also failing, and a new process clearing it in 9 s,'
      Say  '  the process boundary survives as the only thing that has ever cleared this.'
      Say  '  That is real evidence for I6: the state is scoped to something that dies with the'
      Say  '  injecting process - which is NOT the host, since Notepad and keyman.exe both ran'
      Say  '  continuously throughout. Worth chasing properly.'
    } else {
      Say  '  Unexpected combination; read the rows above rather than trusting a canned verdict.'
    }
    Release-All
    Say ("  log : {0}" -f $log)
    Say '=============================================================================='
    return
  }

  # ---- I12: what resets the accumulated latch set? -------------------------
  # MODIFIERS.md section 2c. Within a run the held set grows monotonically and
  # never shrinks, even though OS state is cleared after every trial. Between
  # runs it resets with no Keyman restart. Two candidate explanations, and the
  # whole point of this mode is that they are SEPARABLE:
  #
  #   TIME    something resyncs on a timer or an idle trigger.
  #   FOCUS   the focus change as one process exits and the target regains
  #           focus fires KM_FOCUSCHANGED -> GetCapsAndNumlockState
  #           (kmhook_getmessage.cpp:357), which resyncs FIVE MODIFIERS, not
  #           just the two toggles its name suggests (finding 4a). That would
  #           explain the reset exactly.
  #
  # Arm 1 waits without touching focus. Arm 2 changes focus immediately. If only
  # arm 2 clears, it is the focus resync. If arm 1 also clears, it is a timer and
  # the focus hypothesis is not needed. If neither clears, both are wrong.
  #
  # Minimise/restore is used for the focus change rather than Alt+Tab on purpose:
  # Alt+Tab holds a real LALT, which is one of the keys being measured.
  if ($FocusTest) {
    Say '================ I12: what clears the accumulated latch? ================'
    Say  '  Latch a modifier, clear OS state, confirm the cache still re-asserts it,'
    Say  '  then apply exactly one intervention and re-poke.'
    Say ''

    $lm = $MODBYID['LSHIFT']

    # Shared: drive the wedge, then clear OS state, then confirm the cache is
    # still dirty by poking. Returns $true if we have something to test.
    function Set-LatchAndConfirm {
      [void](Switch-ToArm $Keyboard)
      Release-All
      $c = Get-ModState
      if ($c.Held.Count -gt 0) { Say ('    [ABORT] could not reach a clean start (held={0})' -f $c.HeldText); return $false }

      Kd $lm.Vk; Start-Sleep -Milliseconds 1400
      Freeze
      $live = WaitForFreeze 3000
      if (-not $live) { Say '    [WARN] freeze never confirmed - this latch attempt is not valid' }
      Ku $lm.Vk; Start-Sleep -Milliseconds 400

      $p1 = Invoke-Poke
      if (-not ($p1.After.Raw['LSHIFT'])) { Say '    [ABORT] the stimulus did not latch LSHIFT; nothing to test'; return $false }
      Say ('    latched: held={0}' -f $p1.After.HeldText)

      Release-All
      $c2 = Get-ModState
      if ($c2.Held.Count -gt 0) { Say ('    [ABORT] KEYUP sweep did not clear OS state (held={0})' -f $c2.HeldText); return $false }
      Say  '    OS state cleared by the KEYUP sweep (held=none)'

      $p2 = Invoke-Poke
      if (-not ($p2.After.Raw['LSHIFT'])) {
        Say  '    [NOTE] after one poke the latch did NOT come back. The cache was already'
        Say  '           clean, so there is no accumulated state to test in this cycle.'
        return $false
      }
      Say ('    cache still re-asserts it on a poke: held={0}  <- this is what we try to clear' -f $p2.After.HeldText)
      Release-All
      return $true
    }

    $results2 = @()

    # ---- arm 1: WAIT, no focus change --------------------------------------
    Say ('  ---- arm 1: wait {0}s, DO NOT touch focus ----' -f $FocusWaitSeconds)
    if (Set-LatchAndConfirm) {
      $fgBefore = [Km]::GetForegroundWindow()
      Say ('    waiting {0}s (foreground untouched)...' -f $FocusWaitSeconds)
      Start-Sleep -Seconds $FocusWaitSeconds
      $fgAfter = [Km]::GetForegroundWindow()
      $moved = ($fgBefore -ne $fgAfter)
      if ($moved) { Say '    [WARN] the foreground window changed on its own during the wait - arm 1 is confounded' }
      $p = Invoke-Poke
      $cleared = -not ($p.After.Raw['LSHIFT'])
      Say ('    after the wait: held={0}  -> cleared: {1}' -f $p.After.HeldText,$cleared)
      $results2 += [pscustomobject]@{ Arm=('wait ' + $FocusWaitSeconds + 's'); Cleared=$cleared; Held=$p.After.HeldText; Confounded=$moved }
      Release-All
    } else {
      $results2 += [pscustomobject]@{ Arm=('wait ' + $FocusWaitSeconds + 's'); Cleared='n/a'; Held='setup failed'; Confounded=$false }
    }
    Say ''
    Start-Sleep -Seconds 3

    # ---- arm 2: FOCUS CHANGE, no meaningful wait ---------------------------
    Say  '  ---- arm 2: minimise + restore the target (focus out and back), no wait ----'
    if (Set-LatchAndConfirm) {
      [void][Km]::ShowWindow($target, 6)          # SW_MINIMIZE
      Start-Sleep -Milliseconds 900
      [void][Km]::ShowWindow($target, 9)          # SW_RESTORE
      [void][Km]::SetForegroundWindow($target)
      Start-Sleep -Milliseconds 900
      $fgOk = ([Km]::GetForegroundWindow() -eq $target)
      Say ('    focus returned to target: {0}' -f $fgOk)
      if (-not $fgOk) { Say '    [WARN] target is not foreground again - arm 2 is unreliable' }
      $p = Invoke-Poke
      $cleared = -not ($p.After.Raw['LSHIFT'])
      Say ('    after the focus round-trip: held={0}  -> cleared: {1}' -f $p.After.HeldText,$cleared)
      $results2 += [pscustomobject]@{ Arm='focus out+back'; Cleared=$cleared; Held=$p.After.HeldText; Confounded=(-not $fgOk) }
      Release-All
    } else {
      $results2 += [pscustomobject]@{ Arm='focus out+back'; Cleared='n/a'; Held='setup failed'; Confounded=$false }
    }
    Say ''

    Say 'I12 RESULT'
    foreach ($r in $results2) { Say ('  {0,-16} cleared={1,-6} held={2}' -f $r.Arm,$r.Cleared,$r.Held) }
    Say ''
    $w = @($results2 | Where-Object { $_.Arm -like 'wait*' })[0]
    $f = @($results2 | Where-Object { $_.Arm -eq 'focus out+back' })[0]
    if ($w.Cleared -eq 'n/a' -or $f.Cleared -eq 'n/a') {
      Say  '  [INCONCLUSIVE] at least one arm could not be set up. Nothing separated.'
    } elseif ($f.Cleared -and -not $w.Cleared) {
      Say  '  [FOCUS] the focus round-trip cleared it and waiting alone did not.'
      Say ('  That points straight at KM_FOCUSCHANGED -> GetCapsAndNumlockState')
      Say  '  (kmhook_getmessage.cpp:357), which resyncs five modifiers as well as the two'
      Say  '  toggles - finding 4a. MODIFIERS.md section 2c is then explained, and it also'
      Say  '  means a resync path for these five ALREADY EXISTS and simply is not reachable'
      Say  '  from enough places. That is a materially easier fix than D1 proposes: widen the'
      Say  '  trigger rather than add a new resync.'
    } elseif ($w.Cleared -and -not $f.Cleared) {
      Say ('  [TIME] waiting {0}s cleared it without any focus change. Something resyncs on a' -f $FocusWaitSeconds)
      Say  '  timer or an idle trigger. Find it before writing D1 - it may already be the fix.'
    } elseif ($w.Cleared -and $f.Cleared) {
      Say ('  [BOTH] waiting {0}s alone also cleared it, so this run cannot attribute the reset' -f $FocusWaitSeconds)
      Say  '  to the focus change. Re-run with a much shorter -FocusWaitSeconds to find the'
      Say  '  threshold; if a 3s wait does NOT clear it but a focus change does, that separates them.'
    } else {
      Say  '  [NEITHER] the latch survived both a wait and a focus round-trip. Both hypotheses'
      Say  '  are wrong, and whatever resets it between script runs is something else -'
      Say  '  process exit, thread teardown, or InitThread re-seeding on a new attach.'
    }
    Say ("  log : {0}" -f $log)
    Say '=============================================================================='
    return
  }

  # ---- the matrix ----------------------------------------------------------
  $k = Switch-ToArm $Keyboard
  if ($k.Arm -ne $Keyboard) {
    Say ("[ABORT] could not reach keyboard '{0}' - focus thread reports {1}" -f $Keyboard,(Format-Keyboard $k))
    Say  '        Every row would be attributed to the wrong keyboard. Refusing to measure.'
    return
  }
  Say ("keyboard confirmed: {0}" -f (Format-Keyboard $k))

  # Baseline text probe. Establishes that the oracle works at all on this
  # keyboard before any modifier is touched, so a later EMPTY reads as "the
  # stimulus swallowed the keys" rather than "this probe never worked".
  if (-not $StateOnly) {
    $b = Probe-TextOnce
    Say ("baseline text probe: {0,-10} {1}" -f $b.Kind,$b.Cp)
    if ($b.Kind -ne 'LOWER') {
      Say '[ABORT] the text oracle does not read clean before any stimulus was applied.'
      Say '        Recover the machine first; measuring from a dirty baseline proves nothing.'
      return
    }
  }

  $cands = @($CANDIDATES | Where-Object { $Only.Count -eq 0 -or $Only -contains $_.Id })
  if ($cands.Count -eq 0) { Say ("[ABORT] -Only {0} matched no candidate" -f ($Only -join ',')); return }
  Say ("modifiers  = {0}" -f ($Mods -join ', '))
  Say ("candidates = {0}" -f (($cands | ForEach-Object { $_.Id }) -join ', '))
  Say ''

  foreach ($modId in $Mods) {
    $m = $MODBYID[$modId]
    Say ('---------------- MODIFIER: {0} ({1}) ----------------' -f $m.Id,$m.Label)
    Say ('  code predicts: {0}' -f $(if ($m.CacheA) { 'IN Cache A - CAN be phantom-pressed' } else { 'NOT in Cache A - CANNOT be phantom-pressed (negative control)' }))

    $togBefore = (Get-ModState).Toggle[$m.Id]
    $endedEarly = $false

    for ($pass = 1; $pass -le $Repeat; $pass++) {
      foreach ($c in $cands) {

        # Confirm nothing has drifted before the trial. A row measured while the
        # keyboard changed under us, or while a previous trial's latch is still
        # live, is not attributable and must not be counted.
        $pre  = Get-ModState
        $kNow = Get-FocusKeyboard
        $armOk = ($kNow.Arm -eq $Keyboard)
        $preClean = ($pre.Held.Count -eq 0)
        if (-not $preClean) {
          Say ('  {0} p{1} [{2}] pre-state DIRTY (held={3}) - sweeping before the trial' -f $m.Id,$pass,$c.Id,$pre.HeldText)
          Release-All
          $pre = Get-ModState
          $preClean = ($pre.Held.Count -eq 0)
        }

        & $c.Act $m
        $hyg = Invoke-Hygiene $m
        Start-Sleep -Milliseconds 300
        $togNote = Restore-Toggle $m $togBefore

        # Oracle 1 first, and BEFORE any typing: it is the authoritative reading
        # and the only one that is safe under every latch.
        $poke  = Invoke-Poke
        $state = $poke.After

        # Oracle 2, only if the state oracle says typing is safe.
        $text = $null; $textNote = ''
        if ($StateOnly) {
          $textNote = 'StateOnly'
        } else {
          $safety = Get-TypeSafety $state
          if ($safety.Safe) { $text = Probe-TextOnce } else { $textNote = $safety.Why }
        }

        $verdict = Get-Verdict $state $text

        # SELF-LATCH vs RESIDUE. The row's headline question is "did THE KEY
        # UNDER TEST latch", not "did anything latch". Those diverge the moment
        # Cache A starts accumulating, and conflating them made the first run
        # score all four negative controls as 2/2 latched when not one of them
        # ever appeared in the held list - the six carried-over Cache A slots
        # did. Same false-positive shape as the case-insensitive -eq trap:
        # the aggregate was true for a reason that had nothing to do with the
        # thing being measured.
        $selfLatched = ($m.Id -in $state.Held)
        $residual    = @($state.Held | Where-Object { $_ -ne $m.Id })
        $residualTxt = 'none'; if ($residual.Count -gt 0) { $residualTxt = ($residual -join ',') }

        $valid   = $armOk -and $preClean -and ($verdict -ne 'UNREADABLE')

        $tk = '-'; $cp = '-'
        if ($text) { $tk = $text.Kind; $cp = $text.Cp }
        $vtag = ''
        if (-not $valid) {
          $why = @()
          if (-not $armOk)               { $why += 'arm-drift' }
          if (-not $preClean)            { $why += 'dirty-pre' }
          if ($verdict -eq 'UNREADABLE') { $why += 'unreadable' }
          $vtag = '  [INVALID/' + ($why -join '+') + ']'
        }

        $selfTag = 'no'; if ($selfLatched) { $selfTag = 'YES' }
        Say ('  {0,-8} p{1} [{2}] self={3,-3} {4,-22} held={5,-22} text={6,-6} {7,-22} hyg={8} tog={9}{10}' -f `
              $m.Id,$pass,$c.Id,$selfTag,$verdict,$state.HeldText,$tk,$cp,$hyg,$togNote,$vtag)
        if ($residual.Count -gt 0) {
          Say ('           residue not attributable to this arm: {0}' -f $residualTxt)
        }
        if ($poke.Poked -and $poke.Before.Held.Count -eq 0 -and $state.Held.Count -gt 0) {
          Say  '           the latch appeared only AFTER the poke keystroke - Keyman injected it on the batch.'
        }

        $results += [pscustomobject]@{
          Mod=$m.Id; CacheAPredicted=$m.CacheA; Candidate=$c.Id; Desc=$c.Desc; Pass=$pass
          Verdict=$verdict; SelfLatched=$selfLatched; Residual=$residualTxt
          HeldBeforePoke=$poke.Before.HeldText; HeldAfter=$state.HeldText; Agg=$state.AggText
          Toggles=$state.ToggleText; ToggleNote=$togNote
          TextKind=$tk; Cp=$cp; TextNote=$textNote; Hygiene=$hyg
          Keyboard=$Keyboard; LangId=('0x{0:X4}' -f $kNow.LangId); Hkl=('0x{0:X8}' -f $kNow.Hkl)
          ArmConfirmed=$armOk; Valid=$valid; LoadThreads=$LoadThreads
          Step=''; Cleared=''; Detail=''
        }

        # Recover so the next trial starts fair, and record WHICH recovery
        # worked - that is the section 3b measurement, not housekeeping.
        if ($state.Held.Count -gt 0) {
          Release-All
          $r1 = Get-ModState
          if ($r1.Held.Count -gt 0) {
            Say ('           explicit KEYUP sweep did NOT clear (held={0}); trying Cache A taps' -f $r1.HeldText)
            Tap-AllCacheA
            $r2 = Get-ModState
            Say ('           after Cache A taps: held={0}' -f $r2.HeldText)
            if ($r2.Held.Count -gt 0) {
              Say  '           STILL LATCHED. This is the persistent field symptom. Ending this modifier so it can be examined live.'
              Say  '           (Keyman restart is the documented recovery. This script will not do it for you.)'
              $notes += [pscustomobject]@{ Mod=$m.Id; Note='ended early - persistent latch'; Detail=("pass $pass candidate " + $c.Id + ' held=' + $r2.HeldText) }
              $endedEarly = $true
              break
            }
          } else {
            Say  '           recovered by the explicit KEYUP sweep alone'
          }
        }
        Start-Sleep -Milliseconds 5200      # let any 5 s freeze finish
      }
      if ($endedEarly) { break }
    }
    Say ''
  }

  # ---- summary -------------------------------------------------------------
  Say '=========================== SUMMARY ==========================='
  $valid = @($results | Where-Object { $_.Valid -eq $true })
  Say ('Trials: {0} recorded, {1} valid, {2} discarded' -f $results.Count,$valid.Count,($results.Count - $valid.Count))
  Say ''
  Say 'Per modifier. "predicted" is what MODIFIERS.md section 2 says from reading the'
  Say 'code; everything to its right is what this run measured.'
  Say '"self" is the only column that answers "can THIS key be stuck". "any" counts'
  Say 'trials where anything at all was held, which after the first latch is mostly'
  Say 'carried-over Cache A residue and says nothing about the key under test.'
  Say ('  {0,-9} {1,-11} {2,-8} {3,-8} {4,-8} {5,-8} {6}' -f 'key','predicted','self','any','cacheB','swallow','n')
  foreach ($modId in $Mods) {
    $m = $MODBYID[$modId]
    $pred = $(if ($m.CacheA) { 'CAN latch' } elseif ($m.Class -eq 'ordinary') { 'no CacheA' } else { 'immune' })
    $set = @($valid | Where-Object { $_.Mod -eq $modId })
    if ($set.Count -eq 0) {
      Say ('  {0,-9} {1,-11} {2,-8} {3,-8} {4,-8} {5,-8} 0' -f $modId,$pred,'-','-','-','-')
      continue
    }
    $self = @($set | Where-Object { $_.SelfLatched -eq $true }).Count
    $lat  = @($set | Where-Object { $_.HeldAfter -ne 'none' }).Count
    $cb   = @($set | Where-Object { $_.Verdict -eq 'CACHEB-SHIFT' }).Count
    $sw   = @($set | Where-Object { $_.Verdict -eq 'SWALLOWED' }).Count
    Say ('  {0,-9} {1,-11} {2,-8} {3,-8} {4,-8} {5,-8} {6}' -f `
          $modId,$pred,('{0}/{1}' -f $self,$set.Count),('{0}/{1}' -f $lat,$set.Count),
          ('{0}/{1}' -f $cb,$set.Count),('{0}/{1}' -f $sw,$set.Count),$set.Count)
  }
  Say ''

  # ---- cache accumulation -------------------------------------------------
  # Measured 2026-08-24 and predicted by nothing in MODIFIERS.md: the held set
  # grows monotonically across arms. OS state IS cleared after every trial - each
  # row logged "recovered by the explicit KEYUP sweep alone" and the next trial's
  # pre-check read clean - yet the next arm's poke brings back every slot latched
  # so far. The residue therefore lives in Keyman's cache, not in Windows, and an
  # injected KEYUP sweep that demonstrably clears OS key state does NOT clear it.
  $growth = @()
  foreach ($modId in $Mods) {
    $set = @($valid | Where-Object { $_.Mod -eq $modId })
    if ($set.Count -eq 0) { continue }
    $growth += [pscustomobject]@{ Mod=$modId; Held=$set[-1].HeldAfter }
  }
  if ($growth.Count -gt 1) {
    Say 'Held set at the end of each arm, in run order (watch for monotonic growth):'
    foreach ($g in $growth) { Say ('  {0,-9} {1}' -f $g.Mod,$g.Held) }
    $sizes = @($growth | ForEach-Object {
      if ($_.Held -eq 'none') { 0 } else { ([regex]::Matches($_.Held, ',')).Count + 1 } })
    $shrank = $false
    for ($i = 1; $i -lt $sizes.Count; $i++) { if ($sizes[$i] -lt $sizes[$i-1]) { $shrank = $true } }
    if (-not $shrank -and $sizes[-1] -gt $sizes[0]) {
      Say ''
      Say  '  [CACHE ACCUMULATION] the held set never shrank across this run: each arm re-'
      Say  '  asserted every slot latched by the arms before it, even though the OS-level state'
      Say  '  was cleared after every single trial and each trial began with a clean pre-check.'
      Say  '  So the residue survives in Keyman somewhere the injected KEYUP sweep does not'
      Say  '  reach.'
      Say  ''
      Say  '  The MECHANISM IS NOT ESTABLISHED, and this run cannot establish it. Measured'
      Say  '  2026-08-24, the state does NOT survive between script invocations - a later run'
      Say  '  started clean without Keyman being restarted. So "Cache A is simply additive" is'
      Say  '  not supported: something resets it on a timescale longer than the ~5 s between'
      Say  '  trials but shorter than the minutes between runs. Do not write this up as a'
      Say  '  finding until that is pinned down - see TODO I12.'
      Say  ''
      Say  '  What DOES follow regardless of mechanism:'
      Say  '    1. Every arm after the first latch ran against contaminated state, so only arms'
      Say  '       BEFORE the first latch are clean measurements. Run the negative controls'
      Say  '       first (the default order does) or restart Keyman between blocks.'
      Say  '    2. If it holds in the field it predicts the symptom COMPOUNDS rather than'
      Say  '       swapping - a user would accumulate stuck modifiers across a session rather'
      Say  '       than trading one for another. Worth checking against the field reports.'
    }
  }
  Say ''

  Say 'Per key x candidate (SELF-latch rate, valid trials only):'
  $hdr = '  {0,-9}' -f 'modifier'
  foreach ($c in $cands) { $hdr += ('{0,-8}' -f $c.Id) }
  Say $hdr
  foreach ($modId in $Mods) {
    $row = '  {0,-9}' -f $modId
    foreach ($c in $cands) {
      $set = @($valid | Where-Object { $_.Mod -eq $modId -and $_.Candidate -eq $c.Id })
      if ($set.Count -eq 0) { $row += ('{0,-8}' -f '  -  ') }
      else {
        $w = @($set | Where-Object { $_.SelfLatched -eq $true }).Count
        $row += ('{0,-8}' -f ('{0}/{1}' -f $w,$set.Count))
      }
    }
    Say $row
  }
  Say ''
  foreach ($c in $cands) { Say ('  {0} = {1}' -f $c.Id,$c.Desc) }
  Say ''

  # ---- verdict, stated conservatively -------------------------------------
  # Asymmetric ON PURPOSE. A latch on an immune key REFUTES the code-derived
  # table outright - one observation is enough. No latch on a Cache A key proves
  # nothing: the trigger is load-dependent and a null is a null.
  Say 'VERDICT'
  $latchedCacheA = @()
  foreach ($modId in $Mods) {
    if (-not $MODBYID[$modId].CacheA) { continue }
    $set = @($valid | Where-Object { $_.Mod -eq $modId -and $_.SelfLatched -eq $true })
    if ($set.Count -gt 0) { $latchedCacheA += $modId }
  }
  # A negative control counts as clean only if IT never latched. Residue from an
  # earlier arm is not evidence about this key in either direction.
  $immuneSelfLatched = @()
  foreach ($modId in $Mods) {
    if ($MODBYID[$modId].CacheA) { continue }
    $set = @($valid | Where-Object { $_.Mod -eq $modId -and $_.SelfLatched -eq $true })
    if ($set.Count -gt 0) { $immuneSelfLatched += $modId }
  }
  $testedImmune = @($Mods | Where-Object { -not $MODBYID[$_].CacheA -and $MODBYID[$_].Class -ne 'ordinary' })

  # Reported BEFORE the Cache A verdict, because both have their own mechanism
  # and neither is the stuck-modifier bug. Filing either of them as "Cache A"
  # would send a fix to the wrong file.
  $keyLatch = @($valid | Where-Object { $_.Verdict -like 'KEY-LATCH:*' })
  if ($keyLatch.Count -gt 0) {
    Say ('  [LETTER/NUMBER KEY LATCHED] {0} trial(s). This is NOT the stuck-modifier bug.' -f $keyLatch.Count)
    foreach ($r in ($keyLatch | Select-Object -First 8)) {
      Say ('      while testing {0} [{1}] pass {2} -> {3}' -f $r.Mod,$r.Candidate,$r.Pass,$r.Verdict)
    }
    Say  '      Cache A cannot do this: do_keybd_event() has four call sites, all in'
    Say  '      keybd_shift.cpp, and they only ever emit modifiers[6] or the prefix VK.'
    Say  '      The candidate mechanism is kmprocess.cpp:181-182 - QueueAction is called'
    Say  '      twice for VKEYDOWN then VKEYUP and BOTH return values are ignored, so at'
    Say  '      QueueSize == MAXACTIONQUEUE-1 (1023) the down lands and the up is dropped.'
    Say  '      QueueAction beeps (MessageBeep) when it refuses, so check whether the'
    Say  '      machine beeped at that moment - that is the distinguishing signature.'
    Say ''
  }
  $prefixLatch = @($valid | Where-Object { $_.Verdict -like 'PREFIX-LATCH:*' })
  if ($prefixLatch.Count -gt 0) {
    Say ('  [PREFIX VK LATCHED] {0} trial(s). VK 0x{1:X2} reads held and this script never injects it.' -f $prefixLatch.Count,$ZAP.Vk)
    Say  '      Only Keyman emits that key. keybd_sendprefix() writes its down+up into one'
    Say  '      atomic SendInput batch and cannot split, but PostDummyKeyEvent()'
    Say  '      (keyman32.cpp:923-926) uses two separate legacy keybd_event() calls with no'
    Say  '      atomicity at all. A stall between those two lines loses the KEYUP.'
    Say  '      This is a THIRD mechanism, distinct from both Cache A and Cache B.'
    Say ''
  }

  if ($immuneSelfLatched.Count -gt 0) {
    Say ('  [SCOPE CLAIM FAILS] a key MODIFIERS.md section 2 calls IMMUNE latched ITSELF: {0}' -f ($immuneSelfLatched -join ', '))
    foreach ($r in (@($valid | Where-Object { $_.Mod -in $immuneSelfLatched -and $_.SelfLatched -eq $true }) | Select-Object -First 12)) {
      Say ('      {0} [{1}] pass {2} -> held={3}' -f $r.Mod,$r.Candidate,$r.Pass,$r.HeldAfter)
    }
    Say  '                      Cache A is fed only through isModifierKey(), which does not accept'
    Say  '                      these VKs, so either the table is wrong or something OTHER than'
    Say  '                      keybd_shift_reset is holding the key down. Establish which before'
    Say  '                      quoting MODIFIERS.md section 2 again.'
  } elseif ($latchedCacheA.Count -gt 0) {
    Say ('  [SCOPE CONFIRMED] latched: {0}' -f ($latchedCacheA -join ', '))
    $notLatched = @($CACHEA_IDS | Where-Object { $_ -in $Mods -and $_ -notin $latchedCacheA })
    if ($notLatched.Count -gt 0) { Say ('                    tested and NOT latched this run: {0}' -f ($notLatched -join ', ')) }
    if ($testedImmune.Count -gt 0) {
      Say ('                    negative controls, never latched THEMSELVES: {0}' -f ($testedImmune -join ', '))
      Say  '                    Same stimulus, same keyboard, same session, and not one of them'
      Say  '                    ever appeared in the held list. That is MODIFIERS.md section 2'
      Say  '                    measured rather than inferred.'
      Say  '                    Read the run order above before quoting it: a control arm that'
      Say  '                    ran AFTER a Cache A key latched still shows residue in its "any"'
      Say  '                    column. Only the "self" column is evidence about that key.'
    }
    $ctrl = @($latchedCacheA | Where-Object { $_ -in @('LCTRL','RCTRL') })
    if ($ctrl.Count -gt 0) {
      Say ''
      Say ('  [NEW] {0} latched. Ctrl had never been exercised on either side (TODO H1) and it is' -f ($ctrl -join ' and '))
      Say  '        the one modifier with no self-healing path in the field reports. Fold this into'
      Say  '        MODIFIERS.md section 2 and lift the "never tested" caveat.'
    }
  } else {
    Say  '  [NOT REPRODUCED] no modifier latched in this run. Nothing is proven either way -'
    Say  '                   the trigger needs the Keyman UI thread starved at the right instant.'
    Say  '                   Try -LoadThreads 4..6 and a higher -Repeat before concluding anything.'
    if ($testedImmune.Count -gt 0) {
      Say  '                   In particular the immune-key controls only mean something when a'
      Say  '                   Cache A key latched in the SAME run. On their own they show nothing.'
    }
  }
  Say ''

  # The A control. If a bare hold with no freeze latches anything, the freeze is
  # not the mechanism and TRIGGER.md's story needs rework.
  $ctrlA = @($valid | Where-Object { $_.Candidate -eq 'A' })
  if ($ctrlA.Count -gt 0) {
    $aw = @($ctrlA | Where-Object { $_.Verdict -like 'PHANTOM:*' -or $_.Verdict -like 'SCOPE-BREAK:*' -or $_.Verdict -like 'KEY-LATCH:*' -or $_.Verdict -like 'PREFIX-LATCH:*' }).Count
    if ($aw -eq 0) { Say ('  internal control A (no freeze): 0/{0} latched - consistent with the freeze being the mechanism.' -f $ctrlA.Count) }
    else           { Say ('  [WARN] internal control A (NO freeze) latched {0}/{1}. The freeze is then NOT the mechanism.' -f $aw,$ctrlA.Count) }
  }

  # Cache B rows are a separate finding and deserve calling out: they are the
  # #16423 class showing up with no OS-level phantom at all.
  $cbRows = @($valid | Where-Object { $_.Verdict -eq 'CACHEB-SHIFT' })
  if ($cbRows.Count -gt 0) {
    Say ''
    Say ('  [CACHE B] {0} trial(s) produced UPPERCASE text while GetAsyncKeyState reported NOTHING held.' -f $cbRows.Count)
    Say  "            No phantom key exists at OS level, so this is not Cache A - it is Keyman's own"
    Say  '            cached shift flag being wrong, the same class as the Caps Lock bug in #16423.'
    Say  '            kmproof.ps1 scores these identically to a real phantom and cannot tell them apart.'
  }
  $swRows = @($valid | Where-Object { $_.Verdict -eq 'SWALLOWED' })
  if ($swRows.Count -gt 0) {
    Say ''
    Say ('  [SWALLOWED] {0} trial(s) produced NO text with nothing held. Keys went into Keyman and did' -f $swRows.Count)
    Say  '              not come out, and neither cache explains that. Candidate for TODO I4, the one'
    Say  '              run that went from wedged to emitting nothing at all.'
  }

  foreach ($n in $notes) { Say ('  [NOTE] {0}: {1} ({2})' -f $n.Mod,$n.Note,$n.Detail) }

  if ($results.Count -gt 0) {
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    @{ Stamp=$stamp; Keyboard=$Keyboard; Mods=$Mods; Repeat=$Repeat; LoadThreads=$LoadThreads
       StateOnly=[bool]$StateOnly; ProbeAlphabet=$PROBE_LOWER; Results=$results; Notes=$notes } |
      ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
    Say ''
    Say ("  csv  : {0}" -f $csvPath)
    Say ("  json : {0}" -f $jsonPath)
  }
  Say ("  log  : {0}" -f $log)
  Say '=============================================================================='
}
finally {
  # Non-negotiable. The permanence arm deliberately leaves a key down, and any
  # candidate can abort mid-hold. Leaving a modifier latched on the user's
  # desktop is not an acceptable exit under any circumstances.
  try { Release-All } catch { }
  foreach ($j in $loadJobs) { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue }
}
