<#
  kmproof.ps1 - three-arm controlled test: is the stuck-modifier wedge specific
                to KEYMAN, or is it a property of the Cameroon layout / of
                Windows / of this test harness?

  WHY THIS EXISTS
  ---------------
  A single-keyboard rig can answer "WHAT transitions Keyman from clean to
  wedged", but it cannot, on its own, support the claim in TRIGGER.md that the
  bug is Keyman's. A single-arm result is consistent with at least four other
  explanations:

    (a) the Cameroon LAYOUT is at fault, whoever implements it
    (b) WINDOWS drops the modifier KEYUP and every IME would suffer
    (c) this HARNESS manufactures the phantom Shift with its own SendInput
    (d) something else on this machine is eating keystrokes

  This script rules (a)-(d) out by holding the stimulus constant and varying
  ONLY the active keyboard, across three arms:

    US      en-US / 00000409 / KBDUS.DLL         - Microsoft, no special chars
    MSKLC   af    / a0000436 / CAMQ2017.dll      - Microsoft clone of the
                                                   Cameroon layout
    Keyman  aal-Latn-CM / TIP 0x2000 /
            sil_cameroon_qwerty                  - Keyman

  The freeze stimulus (WM_KEYMAN_CONTROL cmd 20 -> keyman.exe) is posted on
  EVERY arm, including the two Microsoft arms. keyman.exe is running throughout.
  That is deliberate and it is the whole point: the stall, the key sequence, the
  timings and the target window are identical in all three arms. The only
  variable is which keyboard owns the keystrokes. So:

    Keyman wedges + MSKLC does not  =>  kills (a) and (b): same layout, same
                                        OS, different implementation, different
                                        outcome.
    US does not wedge               =>  kills (c) and (d): the harness's own
                                        keystrokes do not produce a phantom
                                        Shift by themselves.

  Expected mechanism, for reference: Keyman's low-level hook only swallows and
  re-injects keystrokes when a Keyman keyboard is active
  (k32_lowlevelkeyboardhook.cpp:229-240, !isKeymanKeyboardActive -> pass
  through). On the two Microsoft arms Keyman never touches the keys, so it has
  no cached modifier state to get wrong. The null result on those arms is
  PREDICTED by the mechanism, not merely observed.

  TWO ORACLES
  -----------
  Deadkey  ';e' then RAlt+N.  CLEAN = U+0259 U+014B ("schwa eng")
                              WEDGED = U+0259 U+014A ("schwa CAPITAL eng")
           Sharp, and it also proves the layout is really doing its job. Valid
           on the two Cameroon arms ONLY - US English cannot produce U+0259 at
           all, which is exactly why a second oracle is needed.

  Ascii    'a' 'b' 'c', no Shift sent.  CLEAN = 'abc'   WEDGED = 'ABC'
           Layout-agnostic: those three keys are unshifted on all three arms, so
           a phantom Shift shows up as 'ABC' whichever keyboard is active. This
           is the oracle the cross-arm comparison actually rests on, because it
           is the SAME measurement in all three arms.

  Both oracles run on every arm. Which ones are trustworthy per arm is not
  assumed - it is established by a fingerprint step (below) and recorded.

  FINGERPRINTING
  --------------
  Before any trial, each arm types both probes once and the exact codepoints are
  logged. An oracle is marked VALID for that arm only if its clean form actually
  appeared. This is what makes the US arm honest (its deadkey oracle is expected
  to be marked invalid, and the log will show precisely what US produced
  instead) and it is also a guard against a mis-switch: langid 0x2000 is shared
  by the Keyman Cameroon and Keyman Yoruba profiles in the registry, so the
  Keyman arm is only accepted if the deadkey fingerprint really yields
  U+0259 U+014B.

  ARM ORDER
  ---------
  Default order is US, MSKLC, Keyman - controls first, treatment last. The
  Keyman wedge is PERSISTENT (failure counts are strictly bimodal), so measuring
  the controls before it removes any chance of a leftover wedge colouring them. The script also records whether a wedge
  survived an arm switch.

  THE HKL ORACLE, CORRECTED
  -------------------------
  Earlier rigs in this project all recorded that the HKL is not trustworthy.
  That is an artefact of WHICH THREAD was asked. Windows 11 Notepad is a
  multi-threaded WinUI app: the top-level 'Notepad' frame window sits on a
  thread pinned at 0x0409 forever, while the focused 'RichEditD2DPT' edit
  control lives on a different thread that does track the input locale.
  Resolving the thread from MainWindowHandle reads the frame thread and always
  says 0x0409 - which is what produced the old "HKL said 0x0409 while ';e'
  correctly produced U+0259" note.

  Read from GetGUIThreadInfo(0).hwndFocus instead and the HKL is reliable, and
  positively discriminates all three arms. Verified by a same-thread A/B on
  2026-08-23, notepad pid 5500 tid 3196:

      MSKLC active  -> HKL 0xF0C00436  langid 0x0436
      Keyman active -> HKL 0x04092000  langid 0x2000

  Every function here that needs to know the active keyboard uses the focus
  thread. Get-FocusKeyboard is the only place the HKL is read.

  The full HKL matters, not just the langid: en-US carries two input methods on
  this machine (US 00000409 and Dvorak 00010409). Dvorak would silently break
  the Ascii oracle, since 'abc' is not 'abc' on a Dvorak layout. The US arm
  therefore requires the high word to be 0x0409 too, and an accidental landing
  on Dvorak is rejected rather than measured.

  SAFETY
  ------
  ClearField uses Ctrl+A then Delete. That is safe in Notepad and is NEVER safe
  against anything holding data you care about. Notepad is all the repro needs,
  so this script refuses to run against any other process unless
  -IKnowClearFieldIsDestructive is passed.

  Load emulation is capped at 6 runspaces: 32 exhausted memory and crashed the
  host PowerShell during an earlier session.

  This script does not restart Keyman. If an arm cannot reach a clean baseline
  the arm is abandoned and reported, because the documented recovery is a Keyman
  restart and doing that unattended would destroy the state worth looking at.

  USAGE
    .\kmproof.ps1                                  # all three arms, 3 passes
    .\kmproof.ps1 -FingerprintOnly                 # just show me the layouts
    .\kmproof.ps1 -Only I -Repeat 5                # the deterministic trigger
    .\kmproof.ps1 -SwitchMode Manual               # I will switch by hand
    .\kmproof.ps1 -Arms Keyman,MSKLC -LoadThreads 4
#>
[CmdletBinding()]
param(
  [string]$TargetProcess = 'notepad',

  # Arm order is the run order. Controls before treatment by default.
  [string[]]$Arms = @('US','MSKLC','Keyman'),

  # Candidate trigger ids to run, e.g. -Only A,I . Empty = all.
  [string[]]$Only = @(),

  # Passes through the candidate list, per arm.
  [int]$Repeat = 3,

  # Auto   = drive Win+Space until the wanted arm is confirmed on the focus thread
  # Manual = pause and wait for the operator to switch by hand
  [ValidateSet('Auto','Manual')][string]$SwitchMode = 'Auto',

  [int]$SwitchTries = 12,
  [int]$LoadThreads = 0,

  # Switch-stress mode: N cycles of Keyman -> MSKLC -> Keyman with NO freeze
  # ever posted, probing on Keyman each time. Tests whether the arm switch is
  # itself a trigger, independently of the freeze. 0 = off.
  [int]$SwitchStress = 0,

  # Charge test: N repetitions of {run candidate I on MSKLC $ChargeTrials times,
  # confirming MSKLC output stays perfect, then switch to Keyman ONCE and probe}.
  # Tests whether the freeze+release corrupts Keyman's state while a NON-Keyman
  # keyboard is active. Paired control is -SwitchStress (same switches, no
  # freeze), which came back 10/10 clean. 0 = off.
  [int]$ChargeTest = 0,
  [int]$ChargeTrials = 5,

  # Sweep mode: the shortest end-to-end demonstration, as an A/B/A.
  #   phase TRIGGER - walk US -> MSKLC -> Keyman applying the trigger on each
  #   phase WEDGED  - walk the same three again, applying NOTHING, and read what
  #                   each keyboard emits while Keyman is wedged
  #   phase CLEARED - clear the wedge, then walk the three again
  # Phase WEDGED is the sharpest statement of "this is Keyman only": the
  # Microsoft keyboards still type perfectly on the same machine, in the same
  # session, at the same moment that Keyman is producing garbage.
  [switch]$Sweep,
  [int]$SweepTrials = 1,

  [switch]$FingerprintOnly,
  [switch]$IKnowClearFieldIsDestructive,
  [string]$LogDir = "$env:TEMP\kmrepro"
)
$ErrorActionPreference = 'Stop'

# `powershell -File script.ps1 -Only A,B` passes "A,B" as ONE string, not an
# array, so a comma list silently matches nothing and every candidate is
# skipped. Same trap for -Arms. Split them back out. (Inherited from
# an earlier harness, where this bug cost a whole run.)
function Split-CommaArg([string[]]$v) {
  if ($v.Count -eq 1 -and $v[0] -match ',') { $v = @($v[0] -split '\s*,\s*') }
  return @($v | Where-Object { $_ } | ForEach-Object { $_.Trim() })
}
$Only = @((Split-CommaArg $Only) | ForEach-Object { $_.ToUpper() })
$Arms = @(Split-CommaArg $Arms)

foreach ($a in $Arms) {
  if ($a -notin @('US','MSKLC','Keyman')) { throw "unknown arm '$a' (expected US, MSKLC or Keyman)" }
}
if ($LoadThreads -gt 6) { $LoadThreads = 6 }
if ($TargetProcess -ne 'notepad' -and -not $IKnowClearFieldIsDestructive) {
  throw "ClearField does Ctrl+A then Delete. That is safe in Notepad and destructive anywhere that holds data you care about. Pass -IKnowClearFieldIsDestructive to override."
}
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct KpRect { public int Left, Top, Right, Bottom; }

[StructLayout(LayoutKind.Sequential)]
public struct KpGuiThreadInfo {
  public int cbSize;
  public int flags;
  public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
  public KpRect rcCaret;
}

public static class Kp {
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern uint RegisterWindowMessage(string s);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out UIntPtr res);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint tid);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint idThread, ref KpGuiThreadInfo gti);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
}
'@

$UP = 2; $EXT = 1; $FREEZE_CMD = 20
$SCHWA = [string][char]0x0259   # U+0259 LATIN SMALL LETTER SCHWA
$ENG   = [string][char]0x014B   # U+014B LATIN SMALL LETTER ENG     - clean
$ENGUP = [string][char]0x014A   # U+014A LATIN CAPITAL LETTER ENG   - wedged
$CLEAN_DEADKEY = $SCHWA + $ENG
# TWO wedge depths, both real, observed 2026-08-23:
#   partial - only the eng is shifted: schwa + CAPITAL eng
#   full    - Shift is applied to EVERYTHING, so ';' -> ':' and 'e' -> 'E' too.
#             TRIGGER.md already described this as "in the fuller form, :E<ENG>".
# The full form scored OTHER until it was added here, which made a correctly
# reproduced wedge look like an unreadable probe.
$WEDGE_DEADKEY = $SCHWA + $ENGUP                                  # partial
$WEDGE_FULL    = [string][char]0x003A + [string][char]0x0045 + $ENGUP   # ':' 'E' ENG

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$log     = Join-Path $LogDir "proof-$stamp.txt"
$csvPath = Join-Path $LogDir "proof-$stamp.csv"
$jsonPath= Join-Path $LogDir "proof-$stamp.json"

# DO NOT use Write-Host here. Measured on this machine 2026-08-23, with 15
# conhost processes alive after a few background runs:
#
#     Write-Host              4301 ms per line
#     [Console]::Out.WriteLine   0.4 ms per line
#     Add-Content                1.8 ms per line
#
# A 10,000x difference, and it is NOT the file I/O - Add-Content is fine. This
# is not merely a speed problem, it is a CORRECTNESS problem for a timing
# experiment: Say is called between a candidate's trigger action and the probe
# that reads the result, and candidate I calls it from INSIDE the action. Four
# seconds of unplanned dead time at those points lets a 5s freeze expire before
# the probe runs, and gives Keyman time to recover, so trials silently
# degenerate into no-freeze controls.
#
# The earlier rigs in this project all used Write-Host in their own Say
# functions and were all exposed to this. Earlier runs in this session logged
# sub-millisecond, so the stall appears only once the console host is congested
# - which means past results may have been distorted without anything looking
# wrong in the logs. Worth re-checking any timing-sensitive conclusion drawn
# from a long session.
function Say([string]$t) {
  $l = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $t
  [Console]::Out.WriteLine($l)
  Add-Content -Path $log -Value $l -Encoding utf8
}

# ---- key injection ---------------------------------------------------------
function Kd([int]$v, [switch]$E) { $f = 0; if ($E) { $f = $EXT }; [Kp]::keybd_event([byte]$v, [byte][Kp]::MapVirtualKey($v,0), $f, [UIntPtr]::Zero) }
function Ku([int]$v, [switch]$E) { $f = $UP; if ($E) { $f = $f -bor $EXT }; [Kp]::keybd_event([byte]$v, [byte][Kp]::MapVirtualKey($v,0), $f, [UIntPtr]::Zero) }
function Tp([int]$v, [int]$g = 70, [switch]$E) { Kd $v -E:$E; Start-Sleep -Milliseconds 40; Ku $v -E:$E; Start-Sleep -Milliseconds $g }

# RShift carries E=$false as a matter of form: Right Shift is scan 0x36 and is
# not extended, while only RCtrl (E0 1D) and RAlt (E0 38) are. The flag makes no
# difference to behaviour here either way.
#
# Measured at the wire with kmaltgr.ps1, 2026-08-25. Injecting VK_RSHIFT with the
# extended flag and without it produces byte-identical events at a
# WH_KEYBOARD_LL hook - both `RSHIFT scan=0x36 EXT|INJ`. Windows resolves the
# side from the side-specific VIRTUAL KEY (0xA1), not from the scan code or the
# extended flag, and it reports LLKHF_EXTENDED for Right Shift either way. So
# ClearMods and TapAllMods do release and tap Right Shift correctly, and the
# six-modifier KEYUP sweep is six keys.
#
# WHERE THE EXTENDED BIT DOES DECIDE THE SIDE: when the caller passes the
# GENERIC vk. Keyman's do_keybd_event (keybd_shift.cpp:63-88) collapses
# VK_LSHIFT/VK_RSHIFT to VK_SHIFT, VK_L/RCONTROL to VK_CONTROL and
# VK_L/RMENU to VK_MENU, at which point the scan code and the extended bit are
# the only discriminators left. That is exactly why it sets
# scan = SCANCODE_RSHIFT explicitly for Right Shift - and why it is worth asking
# what its bare 0xFF scan code plus an extended bit resolves to for Ctrl and Alt
# (MODIFIERS.md s2b).
$MODS = @(
  @{V=0xA0;E=$false;L='LShift'}, @{V=0xA1;E=$false;L='RShift'}
  @{V=0xA2;E=$false;L='LCtrl'},  @{V=0xA3;E=$true; L='RCtrl'}
  @{V=0xA4;E=$false;L='LAlt'},   @{V=0xA5;E=$true; L='RAlt'}
)
function ModsHeld {
  $h = @()
  foreach ($m in $MODS) { if ((([Kp]::GetAsyncKeyState($m.V)) -band 0x8000) -ne 0) { $h += $m.L } }
  if ($h.Count -eq 0) { return 'none' }
  return ($h -join ',')
}
function ClearMods { foreach ($m in $MODS) { Ku $m.V -E:$m.E; Start-Sleep -Milliseconds 60 }; Start-Sleep -Milliseconds 250 }
function TapAllMods { foreach ($m in $MODS) { Kd $m.V -E:$m.E; Start-Sleep -Milliseconds 90; Ku $m.V -E:$m.E; Start-Sleep -Milliseconds 90 }; Start-Sleep -Milliseconds 300 }

# ---- the ONLY place the active keyboard is read ----------------------------
# Resolves the thread from GetGUIThreadInfo(0).hwndFocus, not from the
# top-level window. See "THE HKL ORACLE, CORRECTED" in the header.
function Get-FocusKeyboard {
  $g = New-Object KpGuiThreadInfo
  $g.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($g)
  if (-not [Kp]::GetGUIThreadInfo(0, [ref]$g)) {
    return [pscustomobject]@{ Ok=$false; Hkl=0; LangId=0; HighWord=0; Tid=0; Class=''; Arm='<no-gui-info>' }
  }
  $h = $g.hwndFocus
  if ($h -eq [IntPtr]::Zero) { $h = $g.hwndActive }
  if ($h -eq [IntPtr]::Zero) {
    return [pscustomobject]@{ Ok=$false; Hkl=0; LangId=0; HighWord=0; Tid=0; Class=''; Arm='<no-focus>' }
  }
  $p = 0
  $tid = [Kp]::GetWindowThreadProcessId($h, [ref]$p)
  $hkl = [Kp]::GetKeyboardLayout($tid).ToInt64()
  $sb = New-Object System.Text.StringBuilder 256
  [void][Kp]::GetClassName($h, $sb, 256)
  $lang = $hkl -band 0xFFFF
  $high = ($hkl -shr 16) -band 0xFFFF
  return [pscustomobject]@{
    Ok       = $true
    Hkl      = $hkl
    LangId   = $lang
    HighWord = $high
    Tid      = $tid
    Pid      = $p
    Class    = $sb.ToString()
    Arm      = (Resolve-Arm $lang $high)
  }
}

# Arm identity from the full HKL. Deliberately strict: anything unrecognised
# comes back as a descriptive string rather than being coerced into an arm, so a
# mis-switch can never be silently measured as a result.
function Resolve-Arm([int64]$lang, [int64]$high) {
  # Only the unsubstituted US layout has high word 0x0409. en-US's OTHER input
  # method on this machine (Dvorak, preload d0010409 -> substitute 00010409)
  # comes back as high word 0xF002: a substitution handle, NOT the 0x0001 you
  # would guess from the layout id. Observed 2026-08-23. Any en-US that is not
  # exactly 0x04090409 is therefore rejected rather than measured, because 'abc'
  # is not 'abc' on Dvorak and the Ascii oracle would silently lie.
  if ($lang -eq 0x0409 -and $high -eq 0x0409) { return 'US' }
  if ($lang -eq 0x0409)                       { return ('en-US-not-plain-US-0x{0:X4}-REJECT' -f $high) }
  if ($lang -eq 0x0436)                       { return 'MSKLC' }
  if ($lang -eq 0x2000)                       { return 'Keyman' }
  if ($lang -eq 0x046A)                       { return 'Keyman-Yoruba' }
  if ($lang -eq 0x100C)                       { return 'fr-CH' }
  return ('unknown-0x{0:X4}' -f $lang)
}

function Format-Keyboard($k) {
  if (-not $k.Ok) { return $k.Arm }
  return ('{0} (HKL=0x{1:X8} langid=0x{2:X4} tid={3} cls={4})' -f $k.Arm, $k.Hkl, $k.LangId, $k.Tid, $k.Class)
}

$ARM_LABEL = @{
  US     = 'US English - Microsoft, 00000409 / KBDUS.DLL'
  MSKLC  = 'Cameroon QWERTY 2017 - Microsoft MSKLC, a0000436 / CAMQ2017.dll, under af'
  Keyman = 'Cameroon QWERTY - Keyman sil_cameroon_qwerty, TIP {25C4EE49-...} under aal-Latn-CM'
}

# ---- target window + text readback ----------------------------------------
$np = Get-Process -Name $TargetProcess -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $np) { Say "[FAIL] no '$TargetProcess' window"; exit 1 }
$target = $np.MainWindowHandle
[void][Kp]::SetForegroundWindow($target); Start-Sleep -Milliseconds 600

$root = [System.Windows.Automation.AutomationElement]::FromHandle($target)
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Document)
$docEl = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
if (-not $docEl) { Say '[FAIL] no Document element'; exit 1 }
$vp = $docEl.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)

function Get-DocText {
  try { $t = $vp.Current.Value } catch { $t = '' }
  if ($null -eq $t) { $t = '' }
  return $t
}
function Show-Cp([string]$t) {
  if (-not $t) { return '<empty>' }
  return (($t.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ')
}
function Assert-Foreground {
  if ([Kp]::GetForegroundWindow() -ne $target) {
    Tp 0x1B 80      # Escape - dismiss a Start menu or switcher we tripped
    [void][Kp]::SetForegroundWindow($target)
    Start-Sleep -Milliseconds 400
  }
  return ([Kp]::GetForegroundWindow() -eq $target)
}

# ---- keyman.exe control window + the freeze stimulus -----------------------
$script:km = [IntPtr]::Zero
$kp = (Get-Process keyman -ErrorAction SilentlyContinue | Select-Object -First 1).Id
if ($kp) {
  $cb = [Kp+EnumWindowsProc]{ param($h,$l)
    $p=0; [void][Kp]::GetWindowThreadProcessId($h,[ref]$p)
    if ($p -eq $kp) {
      $sb=New-Object System.Text.StringBuilder 256; [void][Kp]::GetClassName($h,$sb,256)
      if ($sb.ToString() -eq 'TApplication') { $script:km=$h; return $false }
    }
    return $true }
  [void][Kp]::EnumWindows($cb,[IntPtr]::Zero)
}
$msg = [Kp]::RegisterWindowMessage('WM_KEYMAN_CONTROL')

# Posted on EVERY arm, including the Microsoft ones. Identical stimulus is the
# basis of the whole comparison - see the header.
function Freeze {
  if ($script:km -ne [IntPtr]::Zero) { [void][Kp]::PostMessage($script:km,$msg,[IntPtr]$FREEZE_CMD,[IntPtr]::Zero) }
}

# PostMessage is ASYNCHRONOUS: posting cmd 20 does not tell us when keyman.exe
# actually enters its Sleep(5000). With a fixed delay the modifier KEYUP can be
# released BEFORE the freeze begins, in which case the candidate degenerates
# into the no-freeze control and comes back clean. That is why candidate B is
# intermittent and candidate I is not.
function WaitForFreeze([int]$timeoutMs = 3000) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
    $r = [UIntPtr]::Zero
    $ok = [Kp]::SendMessageTimeout($script:km, 0, [IntPtr]::Zero, [IntPtr]::Zero, 2, 60, [ref]$r)
    if ($ok -eq [IntPtr]::Zero) { return $true }   # no reply = thread is blocked
    Start-Sleep -Milliseconds 20
  }
  return $false
}

# ---- probes ----------------------------------------------------------------
# Clears the field outright rather than counting backspaces: a dropped deadkey
# changes the character count, and miscounted backspaces then corrupt the NEXT
# probe.
# CRITICAL: clear PROGRAMMATICALLY, not with keystrokes.
#
# The original version sent Ctrl+A then Delete. That works fine on a clean
# machine and FAILS SILENTLY the moment the wedge fires: with a phantom LShift
# latched, Ctrl+A becomes Ctrl+Shift+A and Delete becomes Shift+Delete, so the
# field is never emptied. Every subsequent probe then reads the whole
# accumulated buffer and scores OTHER regardless of which keyboard is active.
#
# That artifact produced a bogus "[CLAIM FAILS] a Microsoft keyboard was also
# not-CLEAN" verdict in the 10:15 sweep - US and MSKLC were fine; the readback
# was broken. Any keystroke-based clear is unusable in exactly the state this
# script exists to measure.
#
# UIA SetValue touches no keys, so it cannot be perturbed by a stuck modifier
# and cannot perturb Keyman's cached state either. Keystrokes remain only as a
# fallback if the pattern refuses.
function ClearField {
  try {
    $vp.SetValue('')
    Start-Sleep -Milliseconds 120
    if ([string]::IsNullOrEmpty((Get-DocText))) { return }
  } catch { }
  # Fallback. Release modifiers first or this cannot work while wedged - but
  # note that releasing them may itself clear the wedge, so a run that lands
  # here is not a clean measurement and says so.
  Say '        [WARN] UIA SetValue clear failed; falling back to keystrokes (may disturb the wedge)'
  ClearMods
  Kd 0x11; Start-Sleep -Milliseconds 70
  Tp 0x41 40
  Ku 0x11; Start-Sleep -Milliseconds 120
  Tp 0x2E 40 -E                       # Delete is an EXTENDED key
  Start-Sleep -Milliseconds 200
}

function ProbeAsciiOnce {
  ClearField
  Tp 0x41 110; Tp 0x42 110; Tp 0x43 110          # 'a' 'b' 'c' - no Shift sent
  Start-Sleep -Milliseconds 450
  $t = Get-DocText
  $state = 'OTHER'
  # -ceq, not -eq: PowerShell's -eq is CASE-INSENSITIVE, so 'abc' -eq 'ABC' is
  # TRUE and the wedged result would compare equal to the clean one.
  if     ($t -ceq 'abc') { $state = 'CLEAN' }
  elseif ($t -ceq 'ABC') { $state = 'WEDGED' }
  elseif ([string]::IsNullOrEmpty($t)) { $state = 'NO-OUTPUT' }
  return [pscustomobject]@{ Oracle='Ascii'; State=$state; Text=$t; Cp=(Show-Cp $t); Mods=(ModsHeld) }
}

function ProbeDeadkeyOnce {
  ClearField
  Tp 0xBA 130; Tp 0x45 130                       # ';' then 'e'  -> U+0259
  Start-Sleep -Milliseconds 200
  Kd 0xA5 -E; Start-Sleep -Milliseconds 130      # RAlt DOWN (extended)
  Tp 0x4E 130                                    # 'N'          -> U+014B
  Ku 0xA5 -E; Start-Sleep -Milliseconds 600      # RAlt UP
  $t = Get-DocText
  $state = 'OTHER'
  # Same -ceq trap, and worse here: U+014A/U+014B are the upper/lowercase ENG
  # pair, so -eq reported every WEDGED state as CLEAN until it was caught.
  $variant = ''
  if     ($t -ceq $CLEAN_DEADKEY) { $state = 'CLEAN' }
  elseif ($t -ceq $WEDGE_DEADKEY) { $state = 'WEDGED'; $variant = 'partial' }
  elseif ($t -ceq $WEDGE_FULL)    { $state = 'WEDGED'; $variant = 'full' }
  elseif ([string]::IsNullOrEmpty($t)) { $state = 'NO-OUTPUT' }
  return [pscustomobject]@{ Oracle='Deadkey'; State=$state; Variant=$variant; Text=$t; Cp=(Show-Cp $t); Mods=(ModsHeld) }
}

function ProbeOnce([string]$oracle) {
  if ($oracle -eq 'Ascii') { return ProbeAsciiOnce }
  return ProbeDeadkeyOnce
}

# Both probes are themselves flaky (a dropped ';' yields 'e' instead of schwa),
# so read up to 3 times and take the first state seen twice. OTHER/NO-OUTPUT are
# treated as unreliable reads to be retried, NOT as evidence of a wedge - only
# CLEAN and WEDGED are trusted verdicts.
function Probe([string]$oracle) {
  $seen = @()
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $r = ProbeOnce $oracle
    $seen += $r
    $same = @($seen | Where-Object { $_.State -eq $r.State })
    if ($same.Count -ge 2 -and ($r.State -eq 'CLEAN' -or $r.State -eq 'WEDGED')) { return $r }
    Start-Sleep -Milliseconds 250
  }
  $decided = @($seen | Where-Object { $_.State -eq 'CLEAN' -or $_.State -eq 'WEDGED' })
  if ($decided.Count -gt 0) { return $decided[-1] }
  return $seen[-1]
}

# ---- arm switching --------------------------------------------------------
# Auto mode drives the real user path (Win+Space) rather than poking TSF, and
# verifies the landing with Get-FocusKeyboard after every press. TSF profile
# activation is per-thread inside the owning process and cannot be driven from
# here anyway, so Win+Space is not just the faithful route, it is the only one.
function Tap-WinSpace {
  Kd 0x5B -E; Start-Sleep -Milliseconds 140      # LWIN is an extended key
  Tp 0x20 140
  Ku 0x5B -E; Start-Sleep -Milliseconds 500
}

function Switch-ToArm([string]$want) {
  $k = Get-FocusKeyboard
  if ($k.Arm -eq $want) { return $k }

  if ($SwitchMode -eq 'Manual') {
    Say ("        switch to arm '{0}' by hand now ({1})" -f $want, $ARM_LABEL[$want])
    Say  '        waiting up to 120s for the focus thread to confirm it...'
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
    Say ("        Win+Space #{0} -> {1}" -f $i, (Format-Keyboard $k))
    if ($k.Arm -eq $want) { return $k }
  }
  return $k
}

# ---- fingerprint ---------------------------------------------------------
# Establishes, rather than assumes, which oracles mean anything on this arm.
#   TWO DIFFERENT QUESTIONS, which the first version of this conflated and got
#   wrong on the 09:26 run:
#     "is this the keyboard I think it is?"  -> LayoutOk
#     "is it currently unwedged?"            -> Valid
#   A deadkey fingerprint of U+0259 U+014A is the STRONGEST POSSIBLE proof that
#   the Cameroon keyboard is active - nothing else on this machine can emit
#   schwa at all - while simultaneously proving it is wedged. Treating that as
#   "wrong keyboard, skip the arm" threw away the entire treatment arm and
#   turned a reproduced wedge into an INCONCLUSIVE verdict. CLEAN and WEDGED
#   both confirm the layout; only OTHER/NO-OUTPUT mean the layout is wrong or
#   unreadable.
function Get-Fingerprint([string]$arm) {
  # 3-attempt Probe, not a single shot: a dropped ';' yields 'e' instead of
  # schwa, and a flaky single read here would mis-identify the layout and skip a
  # good arm.
  $d = Probe 'Deadkey'
  Start-Sleep -Milliseconds 250
  $a = Probe 'Ascii'
  $deadkeyLayoutOk = ($d.State -eq 'CLEAN' -or $d.State -eq 'WEDGED')
  $asciiLayoutOk   = ($a.State -eq 'CLEAN' -or $a.State -eq 'WEDGED')
  $deadkeyValid    = ($d.State -eq 'CLEAN')
  $asciiValid      = ($a.State -eq 'CLEAN')
  Say ("        fingerprint deadkey ';e'+RAlt+N -> {0,-9} {1}" -f $d.State, $d.Cp)
  Say ("        fingerprint ascii   'abc'       -> {0,-9} {1}" -f $a.State, $a.Cp)
  if (-not $deadkeyLayoutOk) {
    Say ("        [NOTE] deadkey oracle does not apply on arm '{0}' - it cannot produce U+0259. Recorded, not counted." -f $arm)
  } elseif (-not $deadkeyValid) {
    Say ("        [NOTE] arm '{0}' is the right keyboard but arrives ALREADY WEDGED. Recovery will be attempted." -f $arm)
  }
  return [pscustomobject]@{
    Arm=$arm
    DeadkeyLayoutOk=$deadkeyLayoutOk; AsciiLayoutOk=$asciiLayoutOk
    DeadkeyValid=$deadkeyValid; AsciiValid=$asciiValid
    ArrivedWedged=(($d.State -eq 'WEDGED') -or ($a.State -eq 'WEDGED'))
    DeadkeyState=$d.State; AsciiState=$a.State
    DeadkeyCp=$d.Cp; DeadkeyText=$d.Text; AsciiCp=$a.Cp; AsciiText=$a.Text
  }
}

# ---- candidate triggers --------------------------------------------------
# Unchanged from the original single-keyboard set, so results stay directly
# comparable across the whole project. Each is one
# discrete action applied from a verified-clean state.
#   A is the internal control: a bare modifier hold with NO freeze. It should
#     stay clean even on the Keyman arm. If A wedges, the freeze is not the
#     mechanism and the story in TRIGGER.md is wrong.
#   I is the primary: B made deterministic by confirming the stall is live
#     before releasing, instead of guessing with a fixed 100ms delay.
$CANDIDATES = @(
  @{ Id='A'; Desc='bare LShift hold 1.5s + release (NO freeze - internal control)'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1500; Ku 0xA0; Start-Sleep -Milliseconds 400 } }

  @{ Id='B'; Desc='LShift held, freeze, release INTO the freeze (fixed 100ms delay)'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1400; Freeze; Start-Sleep -Milliseconds 100
       Ku 0xA0; Start-Sleep -Milliseconds 400 } }

  @{ Id='C'; Desc='LShift held, freeze, release, then type DURING the freeze'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1400; Freeze; Start-Sleep -Milliseconds 100
       Ku 0xA0; Start-Sleep -Milliseconds 150
       Tp 0xBA 60; Tp 0x45 60; Start-Sleep -Milliseconds 300
       for ($i=0;$i -lt 2;$i++){ Tp 8 55 } } }

  @{ Id='D'; Desc='rapid tap of all six modifiers (the "recovery" sweep itself)'; Act={
       TapAllMods } }

  @{ Id='I'; Desc='LShift held, freeze CONFIRMED ACTIVE, then release (primary)'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1400
       Freeze
       $live = WaitForFreeze 3000
       if (-not $live) { Say '        [WARN] freeze never confirmed - this iteration is not a valid trial' }
       Ku 0xA0; Start-Sleep -Milliseconds 400 } }

  @{ Id='E'; Desc='LShift DOWN, freeze, LShift UP then DOWN then UP inside freeze'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1400; Freeze; Start-Sleep -Milliseconds 100
       Ku 0xA0; Start-Sleep -Milliseconds 120
       Kd 0xA0; Start-Sleep -Milliseconds 120
       Ku 0xA0; Start-Sleep -Milliseconds 400 } }

  @{ Id='F'; Desc='Ctrl+Shift chord released OUT OF ORDER during freeze'; Act={
       Kd 0x11; Start-Sleep -Milliseconds 80; Kd 0xA0; Start-Sleep -Milliseconds 1400
       Freeze; Start-Sleep -Milliseconds 100
       Ku 0x11; Start-Sleep -Milliseconds 120     # Ctrl up FIRST
       Ku 0xA0; Start-Sleep -Milliseconds 400 } }

  @{ Id='G'; Desc='RAlt (extended) held, freeze, release into freeze'; Act={
       Kd 0xA5 -E; Start-Sleep -Milliseconds 1400; Freeze; Start-Sleep -Milliseconds 100
       Ku 0xA5 -E; Start-Sleep -Milliseconds 400
       Tp 0x1B 80; Tp 0x1B 80 } }                 # Escape twice: kill any menu

  @{ Id='H'; Desc='LShift held across a freeze re-posted 3x (long stall)'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1400
       Freeze; Start-Sleep -Milliseconds 100
       Freeze; Freeze
       Ku 0xA0; Start-Sleep -Milliseconds 400 } }
)

# ---- load emulation ------------------------------------------------------
$loadJobs = @()
if ($LoadThreads -gt 0) {
  for ($i=1; $i -le $LoadThreads; $i++) {
    $loadJobs += Start-Job -ScriptBlock { $x=0.0; while ($true) { $x=[math]::Sqrt([math]::Abs([math]::Sin($x)*1000000.0)) } }
  }
  Start-Sleep -Seconds 2
}

# ---- run ------------------------------------------------------------------
$results      = @()
$fingerprints = @()
$armNotes     = @()
$wedgeCarried = @()

try {
  Say '=================== kmproof: three-arm controlled test ==================='
  Say ("target={0} hwnd=0x{1:X}  keyman ctrl=0x{2:X}  load={3}  switch={4}  repeat={5}" -f $TargetProcess,$target.ToInt64(),$script:km.ToInt64(),$LoadThreads,$SwitchMode,$Repeat)
  if ($script:km -eq [IntPtr]::Zero) {
    Say '[WARN] keyman.exe TApplication window not found - the freeze stimulus will be a NO-OP on every arm.'
    Say '       Every result below would then be a no-freeze control. Fix this before quoting any of it.'
  }
  Say ("arms  = {0}" -f ($Arms -join ' -> '))
  Say  'order = controls first, treatment last (the Keyman wedge is persistent)'
  Say ("log   = {0}" -f $log)
  Say ''
  Say ("startup keyboard: {0}" -f (Format-Keyboard (Get-FocusKeyboard)))

  # ENTRY PROBE. Establishes whether the machine was ALREADY wedged before this
  # script touched anything. Without it, a wedge found later cannot be
  # attributed: the 09:26 run reached the Keyman arm wedged and there was no way
  # to tell whether a trial did it, the arm switch did it, or it walked in that
  # way. Ascii, because it is the one oracle valid on every layout here.
  $entry = Probe 'Ascii'
  Say ("entry probe (Ascii, on whatever was active): {0} ({1}) mods={2}" -f $entry.State,$entry.Cp,$entry.Mods)
  if ($entry.State -ne 'CLEAN') {
    Say '[IMPORTANT] the machine was ALREADY NOT CLEAN before any trial ran. Every arm below inherits that.'
  }
  Say ''

  # ---- switch-stress mode ------------------------------------------------
  # Prompted by the 09:26 run: the Keyman arm was reached ALREADY WEDGED, having
  # been clean minutes earlier, and no trial had run on it. The only things that
  # had happened in between were ten freeze+release trials on the two MICROSOFT
  # arms and the Win+Space switches themselves. This mode isolates the second
  # possibility by removing the freeze entirely.
  if ($SwitchStress -gt 0) {
    Say '================ SWITCH-STRESS MODE ================'
    Say '  No freeze is EVER posted in this mode. The only stimulus is switching keyboards.'
    Say '  If Keyman wedges here, the switch is a trigger in its own right.'
    Say ''
    $wedgeAt = 0
    for ($c = 1; $c -le $SwitchStress; $c++) {
      $k1 = Switch-ToArm 'MSKLC'
      if ($k1.Arm -ne 'MSKLC')  { Say ("  [ABORT] cycle {0} could not reach MSKLC" -f $c); break }
      $k2 = Switch-ToArm 'Keyman'
      if ($k2.Arm -ne 'Keyman') { Say ("  [ABORT] cycle {0} could not reach Keyman" -f $c); break }
      $p = Probe 'Deadkey'
      Say ("  cycle {0,-3} back on Keyman -> {1,-9} ({2}) mods={3}" -f $c,$p.State,$p.Cp,$p.Mods)
      $results += [pscustomobject]@{
        Arm='Keyman'; Pass=$c; Candidate='SWITCH'; Desc='Win+Space to MSKLC and back, NO freeze'; Oracle='Deadkey'
        State=$p.State; Cp=$p.Cp; Text=$p.Text; Mods=$p.Mods
        LangId=('0x{0:X4}' -f $k2.LangId); Hkl=('0x{0:X8}' -f $k2.Hkl)
        ArmConfirmed=$true; Valid=($p.State -eq 'CLEAN' -or $p.State -eq 'WEDGED'); LoadThreads=$LoadThreads
      }
      if ($p.State -eq 'WEDGED') {
        $wedgeAt = $c
        Say ("  *** WEDGED after {0} switch cycle(s), with NO freeze posted ***" -f $c)
        break
      }
      ClearMods
    }
    Say ''
    Say 'SWITCH-STRESS RESULT'
    if ($wedgeAt -gt 0) {
      Say ("  The arm switch ALONE wedged Keyman after {0} cycle(s). The freeze is NOT required." -f $wedgeAt)
      Say  '  TRIGGER.md would then need to widen its mechanism: a keyboard switch is'
      Say  '  sufficient to desynchronise Keyman''s cached modifier state, and the'
      Say  '  freeze is one way to starve the hook thread rather than the only way.'
    } else {
      Say ("  {0} switch cycles, no wedge. The switch alone is NOT sufficient." -f $SwitchStress)
      Say  '  That leaves the freeze trials on the Microsoft arms as the thing that wedged Keyman,'
      Say  '  which would mean Keyman tracks modifier state even when its own keyboard is inactive.'
    }
    if ($results.Count -gt 0) {
      $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
      Say ("  csv  : {0}" -f $csvPath)
    }
    Say ("  log  : {0}" -f $log)
    Say '==============================================================='
    return
  }

  # ---- sweep mode --------------------------------------------------------
  # One pass through all three keyboards per phase. Returns the rows so the
  # caller owns accumulation ($results += inside a function would only mutate a
  # function-local copy).
  function Invoke-SweepPass([string]$label, [int]$triggers) {
    $rows = @()
    foreach ($arm in @('US','MSKLC','Keyman')) {
      $k = Switch-ToArm $arm
      if ($k.Arm -ne $arm) {
        Say ("  [{0,-7}] {1,-7} SKIP - could not switch (focus thread says {2})" -f $label,$arm,$k.Arm)
        continue
      }
      for ($t = 1; $t -le $triggers; $t++) {
        Kd 0xA0; Start-Sleep -Milliseconds 1400
        Freeze
        $live = WaitForFreeze 3000
        if (-not $live) { Say ("  [{0,-7}] {1,-7} [WARN] freeze not confirmed on trigger {2} - not a valid trial" -f $label,$arm,$t) }
        Ku 0xA0; Start-Sleep -Milliseconds 400
        Start-Sleep -Milliseconds 5200          # let the 5s freeze finish
      }
      # US cannot express the deadkey oracle at all; the other two can.
      $oracles = @('Ascii')
      if ($arm -ne 'US') { $oracles = @('Ascii','Deadkey') }
      $what = 'observe only'
      if ($triggers -gt 0) { $what = ("{0} trigger(s)" -f $triggers) }
      foreach ($o in $oracles) {
        $p = Probe $o
        Say ("  [{0,-7}] {1,-7} {2,-8} {3,-14} -> {4,-9} ({5}) mods={6}" -f $label,$arm,$o,$what,$p.State,$p.Cp,$p.Mods)
        $rows += [pscustomobject]@{
          Arm=$arm; Pass=0; Candidate=('sweep-' + $label); Desc=("sweep phase " + $label + ', ' + $what); Oracle=$o
          State=$p.State; Cp=$p.Cp; Text=$p.Text; Mods=$p.Mods
          LangId=('0x{0:X4}' -f $k.LangId); Hkl=('0x{0:X8}' -f $k.Hkl)
          ArmConfirmed=$true; Valid=($p.State -eq 'CLEAN' -or $p.State -eq 'WEDGED'); LoadThreads=$LoadThreads
          Phase=$label
        }
      }
    }
    return $rows
  }

  function Get-SweepState($rows, [string]$arm, [string]$oracle) {
    $r = @($rows | Where-Object { $_.Arm -eq $arm -and $_.Oracle -eq $oracle })
    if ($r.Count -eq 0) { return '-' }
    return $r[-1].State
  }

  if ($Sweep) {
    Say '================ SWEEP: trigger / observe-wedged / clear / observe-clean ================'
    Say ("  {0} trigger(s) per keyboard in the TRIGGER phase; later phases apply NOTHING." -f $SweepTrials)
    Say ''

    Say '---- phase 1: TRIGGER (walk all three, trigger on each) ----'
    $p1 = Invoke-SweepPass 'TRIGGER' $SweepTrials
    $results += $p1
    $kmAfter1 = Get-SweepState $p1 'Keyman' 'Deadkey'
    Say ''

    $p2 = @()
    if ($kmAfter1 -eq 'CLEAN') {
      Say ("---- phase 2: SKIPPED - Keyman came back CLEAN after {0} trigger(s) per keyboard ----" -f $SweepTrials)
      Say  '     The bug was not triggered, so there is no wedged state to observe.'
      Say  '     Re-run with a higher -SweepTrials (the charge test needed 5 on MSKLC).'
    } else {
      Say '---- phase 2: WEDGED (walk all three again, applying NOTHING) ----'
      Say  '     This is the Keyman-only claim in its sharpest form: same machine, same'
      Say  '     session, same moment. Do the Microsoft keyboards still type correctly?'
      $p2 = Invoke-SweepPass 'WEDGED' 0
      $results += $p2
    }
    Say ''

    Say '---- phase 3: CLEAR the wedge ----'
    $k = Switch-ToArm 'Keyman'
    $cleared = $false
    if ($k.Arm -eq 'Keyman') {
      ClearMods; TapAllMods
      $rec = Probe 'Deadkey'
      Say ("  injected recovery (ClearMods + TapAllMods) -> {0} ({1})" -f $rec.State,$rec.Cp)
      $cleared = ($rec.State -eq 'CLEAN')
      if (-not $cleared) {
        # A physical double-tap on LShift is known to clear this where the
        # injected sweep does not - injected keys carry LLKHF_INJECTED and
        # Keyman can tell them apart. Ask for one rather than giving up.
        Say  '  injected recovery did not clear it.'
        Say  '  ACTION NEEDED: double-tap the physical LEFT SHIFT key now. Waiting up to 90s...'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 90) {
          Start-Sleep -Milliseconds 1500
          $rec = Probe 'Deadkey'
          if ($rec.State -eq 'CLEAN') { $cleared = $true; break }
        }
        if ($cleared) { Say ("  cleared by physical keystroke after {0:N0}s" -f $sw.Elapsed.TotalSeconds) }
        else          { Say  '  still not clear. Keyman restart is the documented fallback; not doing that here.' }
      }
    } else {
      Say ("  [SKIP] could not reach Keyman to clear (saw {0})" -f $k.Arm)
    }
    Say ''

    $p3 = @()
    if ($cleared) {
      Say '---- phase 4: CLEARED (walk all three again, applying NOTHING) ----'
      $p3 = Invoke-SweepPass 'CLEARED' 0
      $results += $p3
    } else {
      Say '---- phase 4: SKIPPED - the wedge was never cleared ----'
    }
    Say ''

    # ---- matrix -----------------------------------------------------------
    Say 'SWEEP MATRIX'
    Say ('  {0,-7} {1,-8} {2,-11} {3,-11} {4,-11}' -f 'arm','oracle','TRIGGER','WEDGED','CLEARED')
    foreach ($arm in @('US','MSKLC','Keyman')) {
      $oracles = @('Ascii')
      if ($arm -ne 'US') { $oracles = @('Ascii','Deadkey') }
      foreach ($o in $oracles) {
        Say ('  {0,-7} {1,-8} {2,-11} {3,-11} {4,-11}' -f $arm,$o,
              (Get-SweepState $p1 $arm $o), (Get-SweepState $p2 $arm $o), (Get-SweepState $p3 $arm $o))
      }
    }
    Say ''

    # ---- verdict ----------------------------------------------------------
    # The phase a Microsoft arm goes bad in decides what it MEANS. The first
    # version of this treated any non-CLEAN Microsoft probe as refuting the
    # claim, which is wrong: during the WEDGED phase a Microsoft keyboard
    # emitting ABC is the EXPECTED consequence of Keyman having injected a real
    # LShift KEYDOWN with no matching KEYUP, and is evidence FOR the diagnosis,
    # not against it. Only the TRIGGER phase can refute Keyman-only causation.
    Say 'SWEEP VERDICT'
    $msTrigger = @($p1 | Where-Object { ($_.Arm -eq 'US' -or $_.Arm -eq 'MSKLC') -and $_.State -ne 'CLEAN' })
    $msWedged  = @($p2 | Where-Object { ($_.Arm -eq 'US' -or $_.Arm -eq 'MSKLC') -and $_.State -ne 'CLEAN' })
    $msCleared = @($p3 | Where-Object { ($_.Arm -eq 'US' -or $_.Arm -eq 'MSKLC') -and $_.State -ne 'CLEAN' })

    if ($kmAfter1 -eq 'CLEAN') {
      Say ("  [NOT TRIGGERED] one pass with {0} trigger(s) per keyboard did not wedge Keyman." -f $SweepTrials)
      Say  '                  Raise -SweepTrials and re-run before drawing any conclusion.'
    } elseif ($msTrigger.Count -gt 0) {
      Say ('  [CAUSATION CLAIM FAILS] the trigger itself disturbed a Microsoft keyboard in {0} probe(s):' -f $msTrigger.Count)
      foreach ($r in $msTrigger) { Say ('      {0} {1} {2} -> {3} ({4})' -f $r.Phase,$r.Arm,$r.Oracle,$r.State,$r.Cp) }
      Say  '      That would mean this is not Keyman-specific. Investigate before quoting.'
    } else {
      Say  '  [CAUSED BY KEYMAN ONLY] Under the identical trigger, US and MSKLC stayed CLEAN'
      Say  '      while Keyman wedged. The layout is not at fault and neither is Windows.'
      if ($msWedged.Count -gt 0) {
        Say  ''
        Say  '  [BUT THE DAMAGE IS MACHINE-WIDE] Once wedged, the Microsoft keyboards are'
        Say  '      affected too, with NO trigger applied to them:'
        foreach ($r in $msWedged) { Say ('      {0,-7} {1,-8} -> {2} ({3}) mods={4}' -f $r.Arm,$r.Oracle,$r.State,$r.Cp,$r.Mods) }
        Say  '      They are not malfunctioning - they are correctly rendering a Shift that is'
        Say  '      genuinely held as far as Windows is concerned. GetAsyncKeyState agrees.'
        Say  '      Keyman synthesised it: keybd_shift_reset() emits a KEYDOWN for every'
        Say  '      modifier its cache believes is held, with no matching KEYUP.'
        Say  '      So: caused only via Keyman, suffered by everything.'
      } elseif ($p2.Count -gt 0) {
        Say  '      During the WEDGED phase the Microsoft keyboards stayed CLEAN, so the bad'
        Say  '      state did NOT escape into OS-level key state on this run.'
      }
      if ($cleared -and $p3.Count -gt 0 -and $msCleared.Count -eq 0) {
        Say  ''
        Say  '  [RECOVERABLE] After clearing, all three keyboards are CLEAN again - a'
        Say  '      recoverable desync, not permanent damage.'
      }
    }

    if ($results.Count -gt 0) {
      $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
      Say ("  csv  : {0}" -f $csvPath)
    }
    Say ("  log  : {0}" -f $log)
    Say '==============================================================='
    return
  }

  # ---- charge test -------------------------------------------------------
  # THE experiment for the sharpened claim. Two runs of the three-arm test both
  # reached the Keyman arm ALREADY WEDGED, with the previous arm's exit probe
  # CLEAN, and -SwitchStress then showed 10/10 clean for the switches alone. By
  # elimination the freeze+release trials are doing it - but those trials ran
  # while a MICROSOFT keyboard was active, which the k32 pass-through reasoning
  # in TRIGGER.md says should be inert. This measures that directly instead of
  # inferring it, and it is the paired treatment for -SwitchStress's control.
  #
  # Read the output as: MSKLC output stays perfect throughout the charging phase
  # (so the Microsoft implementation is genuinely unaffected), and yet Keyman is
  # found corrupted the moment its keyboard becomes active again.
  if ($ChargeTest -gt 0) {
    Say '================ CHARGE TEST ================'
    Say ("  Per rep: {0} x candidate I on MSKLC (Keyman keyboard INACTIVE), then switch to Keyman and probe." -f $ChargeTrials)
    Say  '  Paired control is -SwitchStress: identical switches, no freeze.'
    Say ''
    $charged = 0; $reps = 0; $msklcDirty = 0; $msklcTrials = 0
    for ($r = 1; $r -le $ChargeTest; $r++) {
      $k1 = Switch-ToArm 'MSKLC'
      if ($k1.Arm -ne 'MSKLC') { Say ("  [ABORT] rep {0} could not reach MSKLC" -f $r); break }

      $pre = Probe 'Deadkey'
      if ($pre.State -ne 'CLEAN') {
        Say ("  rep {0}: MSKLC does not start clean ({1}) - rep abandoned, not counted" -f $r,$pre.Cp)
        continue
      }

      $dirtyHere = 0
      for ($t = 1; $t -le $ChargeTrials; $t++) {
        Kd 0xA0; Start-Sleep -Milliseconds 1400
        Freeze
        $live = WaitForFreeze 3000
        if (-not $live) { Say ("      rep {0} trial {1}: [WARN] freeze never confirmed - not a valid charging trial" -f $r,$t) }
        Ku 0xA0; Start-Sleep -Milliseconds 400
        $m = Probe 'Deadkey'
        $msklcTrials++
        if ($m.State -ne 'CLEAN') { $dirtyHere++; $msklcDirty++ }
        Say ("      rep {0} charge trial {1} on MSKLC -> {2,-9} ({3}) mods={4}" -f $r,$t,$m.State,$m.Cp,$m.Mods)
        $results += [pscustomobject]@{
          Arm='MSKLC'; Pass=$r; Candidate='I-charge'; Desc='candidate I while Keyman keyboard INACTIVE'; Oracle='Deadkey'
          State=$m.State; Cp=$m.Cp; Text=$m.Text; Mods=$m.Mods
          LangId=('0x{0:X4}' -f $k1.LangId); Hkl=('0x{0:X8}' -f $k1.Hkl)
          ArmConfirmed=$true; Valid=($m.State -eq 'CLEAN' -or $m.State -eq 'WEDGED'); LoadThreads=$LoadThreads
        }
        Start-Sleep -Milliseconds 5200
      }

      $k2 = Switch-ToArm 'Keyman'
      if ($k2.Arm -ne 'Keyman') { Say ("  [ABORT] rep {0} could not reach Keyman" -f $r); break }
      $post = Probe 'Deadkey'
      $reps++
      $verdict = 'clean'
      if ($post.State -ne 'CLEAN') { $verdict = '*** ' + $post.State + ' ***'; $charged++ }
      Say ("  rep {0}: MSKLC dirty {1}/{2} during charging  ->  Keyman on return: {3} ({4}) mods={5}" -f `
            $r,$dirtyHere,$ChargeTrials,$verdict,$post.Cp,$post.Mods)
      $results += [pscustomobject]@{
        Arm='Keyman'; Pass=$r; Candidate='I-fire'; Desc='first probe after switching back to Keyman'; Oracle='Deadkey'
        State=$post.State; Cp=$post.Cp; Text=$post.Text; Mods=$post.Mods
        LangId=('0x{0:X4}' -f $k2.LangId); Hkl=('0x{0:X8}' -f $k2.Hkl)
        ArmConfirmed=$true; Valid=($post.State -eq 'CLEAN' -or $post.State -eq 'WEDGED'); LoadThreads=$LoadThreads
      }

      if ($post.State -ne 'CLEAN') {
        # Does INJECTED recovery work? A physical LShift double-tap is known to
        # clear this; the six-modifier injected sweep was seen to make it worse
        # (wedged -> NO-OUTPUT). Record which, because it bears on whether
        # LLKHF_INJECTED changes how Keyman treats the keys.
        ClearMods; TapAllMods
        $rec = Probe 'Deadkey'
        Say ("        injected recovery (ClearMods+TapAllMods) -> {0} ({1})" -f $rec.State,$rec.Cp)
        if ($rec.State -ne 'CLEAN') {
          Say  '        injected recovery FAILED. Physical keys may still clear it; this harness cannot test that.'
          Say  '        Stopping: the state is worth examining live, and later reps would not start clean.'
          break
        }
      }
    }
    Say ''
    Say 'CHARGE TEST RESULT'
    Say ("  MSKLC output during charging : {0}/{1} trials NOT clean" -f $msklcDirty,$msklcTrials)
    Say ("  Keyman on return             : {0}/{1} reps corrupted" -f $charged,$reps)
    if ($reps -eq 0) {
      Say '  [INCONCLUSIVE] no rep completed.'
    } elseif ($charged -gt 0 -and $msklcDirty -eq 0) {
      Say  '  [CONFIRMED] The same keystrokes that leave the Microsoft keyboard PERFECT leave'
      Say  '              Keyman corrupted - and Keyman was not even the active keyboard.'
      Say  '              This is stronger than "Keyman-only": the layout is irrelevant, and'
      Say  '              Keyman keeps modifier state it should not be keeping while inactive.'
      Say  '              TRIGGER.md must drop the !isKeymanKeyboardActive pass-through argument.'
    } elseif ($charged -eq 0) {
      Say  '  [NOT REPRODUCED] Keyman came back clean every rep. The charge hypothesis is not supported'
      Say  '                   by this run; the earlier wedges need another explanation.'
    } else {
      Say  '  [MIXED] MSKLC output was also disturbed during charging, so this is not a clean'
      Say  '          Keyman-only result. Investigate before quoting.'
    }
    if ($results.Count -gt 0) {
      $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
      Say ("  csv  : {0}" -f $csvPath)
    }
    Say ("  log  : {0}" -f $log)
    Say '==============================================================='
    return
  }

  foreach ($arm in $Arms) {
    Say ('================ ARM: {0} ================' -f $arm)
    Say ('  {0}' -f $ARM_LABEL[$arm])

    # A wedge left over from the previous arm is itself a datapoint.
    $carriedIn = $null

    $k = Switch-ToArm $arm
    if ($k.Arm -ne $arm) {
      Say ("  [SKIP] could not reach arm '{0}' - focus thread reports {1}" -f $arm, (Format-Keyboard $k))
      Say  '  [SKIP] this arm contributes NOTHING to the result. Not silently dropped: see the summary.'
      $armNotes += [pscustomobject]@{ Arm=$arm; Note='SKIPPED - could not switch'; Detail=(Format-Keyboard $k) }
      continue
    }
    Say ("  confirmed: {0}" -f (Format-Keyboard $k))

    $fp = Get-Fingerprint $arm
    $fingerprints += $fp

    # -FingerprintOnly stops here: switch, identify, record what the keyboard
    # actually emits, run no trials. This is the cheap sanity pass to run first,
    # and it is what establishes for TRIGGER.md that US genuinely cannot produce
    # the special characters.
    if ($FingerprintOnly) { Say '  [FingerprintOnly] no trials run on this arm'; Say ''; continue }

    # The Keyman arm is only accepted if the deadkey fingerprint really yields
    # schwa+eng: langid 0x2000 is shared by the Keyman Cameroon and Keyman
    # Yoruba profiles in the registry.
    # LayoutOk, not Valid: an arm that arrives wedged is the right keyboard and
    # must be recovered and measured, not skipped. See Get-Fingerprint.
    if ($arm -eq 'Keyman' -and -not $fp.DeadkeyLayoutOk) {
      Say '  [SKIP] arm says Keyman/0x2000 but the deadkey fingerprint is neither schwa+eng nor schwa+ENG - this is a different Keyman keyboard.'
      $armNotes += [pscustomobject]@{ Arm=$arm; Note='SKIPPED - 0x2000 but wrong deadkey fingerprint'; Detail=$fp.DeadkeyCp }
      continue
    }
    if (-not $fp.AsciiLayoutOk) {
      Say '  [SKIP] the Ascii oracle is unreadable on this arm, so the cross-arm measurement cannot be made here.'
      $armNotes += [pscustomobject]@{ Arm=$arm; Note='SKIPPED - ascii oracle unreadable'; Detail=$fp.AsciiCp }
      continue
    }
    if ($fp.ArrivedWedged) {
      Say '  [IMPORTANT] this arm ARRIVED WEDGED. Whatever wedged it happened BEFORE any trial here.'
      Say '              Compare against the previous arm''s exit probe to localise it.'
      $armNotes += [pscustomobject]@{ Arm=$arm; Note='ARRIVED WEDGED before any trial'; Detail=$fp.DeadkeyCp }
    }

    # Oracles to run on this arm. Ascii always (it is the comparable one);
    # Deadkey wherever the layout can express it, wedged or not.
    $oracles = @('Ascii')
    if ($fp.DeadkeyLayoutOk) { $oracles += 'Deadkey' }
    Say ("  oracles in play: {0}" -f ($oracles -join ', '))

    $base = Probe 'Ascii'
    Say ("  baseline (Ascii): {0} '{1}' ({2}) mods={3}" -f $base.State,$base.Text,$base.Cp,$base.Mods)
    if ($base.State -ne 'CLEAN') {
      Say '  [WARN] not starting clean - attempting recovery'
      ClearMods; TapAllMods
      $base = Probe 'Ascii'
      Say ("  after recovery: {0} ({1})" -f $base.State,$base.Cp)
      if ($base.State -ne 'CLEAN') {
        Say '  [SKIP] cannot reach a clean baseline on this arm. Not restarting Keyman - that would destroy the state.'
        $armNotes += [pscustomobject]@{ Arm=$arm; Note='SKIPPED - no clean baseline'; Detail=$base.Cp }
        continue
      }
    }
    Say ''

    for ($pass = 1; $pass -le $Repeat; $pass++) {
      foreach ($c in $CANDIDATES) {
        if ($Only.Count -gt 0 -and $Only -notcontains $c.Id) { continue }

        # Confirm the arm has not drifted under us mid-pass. A Win+Space by a
        # human, or a focus change, would otherwise mis-attribute the trial.
        $kNow = Get-FocusKeyboard
        $armOk = ($kNow.Arm -eq $arm)

        & $c.Act
        Start-Sleep -Milliseconds 300

        foreach ($oracle in $oracles) {
          $post = Probe $oracle
          $valid = $armOk -and ($post.State -eq 'CLEAN' -or $post.State -eq 'WEDGED')
          $tag = 'clean '
          if ($post.State -ne 'CLEAN') { $tag = '*** ' + $post.State + ' ***' }
          $vtag = ''
          if (-not $valid) { $vtag = '  [INVALID' + $(if (-not $armOk) { '/arm-drift' } else { '/unreadable' }) + ']' }

          Say ("  {0} p{1} [{2}] {3,-9} {4,-58} langid=0x{5:X4} -> {6} ({7}) mods={8}{9}" -f `
                $arm,$pass,$c.Id,$oracle,$c.Desc,$kNow.LangId,$tag,$post.Cp,$post.Mods,$vtag)

          $results += [pscustomobject]@{
            Arm=$arm; Pass=$pass; Candidate=$c.Id; Desc=$c.Desc; Oracle=$oracle
            State=$post.State; Cp=$post.Cp; Text=$post.Text; Mods=$post.Mods
            LangId=('0x{0:X4}' -f $kNow.LangId); Hkl=('0x{0:X8}' -f $kNow.Hkl)
            ArmConfirmed=$armOk; Valid=$valid; LoadThreads=$LoadThreads
          }
        }

        # recover so the next candidate starts fair
        $lastState = ($results | Where-Object { $_.Arm -eq $arm -and $_.Pass -eq $pass -and $_.Candidate -eq $c.Id } | Select-Object -Last 1).State
        if ($lastState -ne 'CLEAN') {
          ClearMods
          $r1 = Probe 'Ascii'
          if ($r1.State -ne 'CLEAN') {
            Say ("        explicit KEYUP sweep did NOT recover ({0}); trying modifier taps" -f $r1.Cp)
            TapAllMods
            $r2 = Probe 'Ascii'
            Say ("        after modifier taps: {0} ({1})" -f $r2.State,$r2.Cp)
            if ($r2.State -ne 'CLEAN') {
              Say '        STILL WEDGED - this is the persistent field symptom. Ending this arm so it can be examined live.'
              Say '        (Keyman restart is the documented recovery. This script will not do it for you.)'
              $armNotes += [pscustomobject]@{ Arm=$arm; Note='arm ended early - persistent wedge'; Detail=("pass $pass candidate " + $c.Id) }
              $carriedIn = $arm
              break
            }
          } else {
            Say ("        recovered by explicit KEYUP sweep alone ({0})" -f $r1.Cp)
          }
        }
        Start-Sleep -Milliseconds 5200      # let any 5s freeze finish
      }
      if ($carriedIn) { break }
    }

    # EXIT PROBE. Pairs with the next arm's fingerprint to bracket the arm
    # switch. If an arm exits CLEAN and the next arm's fingerprint is WEDGED,
    # then nothing in this arm's trials did it and the switch itself (Win+Space,
    # which holds LWIN across a TSF profile change) becomes the prime suspect -
    # see -SwitchStress, which tests exactly that with no freeze at all.
    $exit = Probe 'Ascii'
    Say ("  exit probe (Ascii): {0} ({1}) mods={2}" -f $exit.State,$exit.Cp,$exit.Mods)
    $armNotes += [pscustomobject]@{ Arm=$arm; Note=('exit probe ' + $exit.State); Detail=$exit.Cp }

    if ($carriedIn) {
      $wedgeCarried += [pscustomobject]@{ Arm=$arm; Note='left wedged at end of arm' }
      Say ('  [NOTE] arm {0} ends WEDGED. The next arm''s fingerprint will show whether it survives the switch.' -f $arm)
    }
    Say ''
  }

  # ---- summary -----------------------------------------------------------
  Say '=========================== SUMMARY ==========================='
  Say ''
  Say 'Fingerprints (what each keyboard actually produced):'
  foreach ($f in $fingerprints) {
    $dk = 'not applicable'
    if ($f.DeadkeyLayoutOk -and $f.DeadkeyValid) { $dk = 'VALID' }
    elseif ($f.DeadkeyLayoutOk)                  { $dk = 'VALID but arrived WEDGED' }
    Say ("  {0,-7} deadkey={1,-28} ascii={2,-20} deadkeyOracle={3}" -f $f.Arm,$f.DeadkeyCp,$f.AsciiCp,$dk)
  }
  Say ''

  $valid = @($results | Where-Object { $_.Valid })
  Say ('Trials: {0} recorded, {1} valid, {2} discarded' -f $results.Count, $valid.Count, ($results.Count - $valid.Count))
  Say ''
  Say 'Wedge rate by arm and candidate (valid trials only, Ascii oracle - the comparable one):'
  Say ('  {0,-10} {1,-8} {2,-8} {3,-8} {4}' -f 'candidate','US','MSKLC','Keyman','description')
  $cands = @($CANDIDATES | Where-Object { $Only.Count -eq 0 -or $Only -contains $_.Id })
  foreach ($c in $cands) {
    $cells = @{}
    foreach ($arm in @('US','MSKLC','Keyman')) {
      $set = @($valid | Where-Object { $_.Arm -eq $arm -and $_.Candidate -eq $c.Id -and $_.Oracle -eq 'Ascii' })
      if ($set.Count -eq 0) { $cells[$arm] = '  -  ' }
      else {
        $w = @($set | Where-Object { $_.State -eq 'WEDGED' }).Count
        $cells[$arm] = ('{0}/{1}' -f $w, $set.Count)
      }
    }
    Say ('  {0,-10} {1,-8} {2,-8} {3,-8} {4}' -f $c.Id, $cells['US'], $cells['MSKLC'], $cells['Keyman'], $c.Desc)
  }
  Say ''

  if ($fingerprints | Where-Object { $_.DeadkeyLayoutOk }) {
    Say 'Same table, Deadkey oracle (Cameroon arms only - sharper, catches NO-OUTPUT too):'
    Say ('  {0,-10} {1,-8} {2,-8} {3}' -f 'candidate','MSKLC','Keyman','description')
    foreach ($c in $cands) {
      $cells = @{}
      foreach ($arm in @('MSKLC','Keyman')) {
        $set = @($valid | Where-Object { $_.Arm -eq $arm -and $_.Candidate -eq $c.Id -and $_.Oracle -eq 'Deadkey' })
        if ($set.Count -eq 0) { $cells[$arm] = '  -  ' }
        else {
          $w = @($set | Where-Object { $_.State -ne 'CLEAN' }).Count
          $cells[$arm] = ('{0}/{1}' -f $w, $set.Count)
        }
      }
      Say ('  {0,-10} {1,-8} {2,-8} {3}' -f $c.Id, $cells['MSKLC'], $cells['Keyman'], $c.Desc)
    }
    Say ''
  }

  # ---- the verdict, stated conservatively --------------------------------
  function ArmWedges([string]$arm) {
    $set = @($valid | Where-Object { $_.Arm -eq $arm -and $_.Oracle -eq 'Ascii' })
    $w   = @($set | Where-Object { $_.State -eq 'WEDGED' }).Count
    return [pscustomobject]@{ Arm=$arm; N=$set.Count; Wedged=$w }
  }
  $sUS = ArmWedges 'US'; $sMS = ArmWedges 'MSKLC'; $sKM = ArmWedges 'Keyman'
  Say ('Arm totals (Ascii): US {0}/{1}   MSKLC {2}/{3}   Keyman {4}/{5}' -f $sUS.Wedged,$sUS.N,$sMS.Wedged,$sMS.N,$sKM.Wedged,$sKM.N)
  Say ''

  $armsRun = @('US','MSKLC','Keyman') | Where-Object { (ArmWedges $_).N -gt 0 }
  $missing = @('US','MSKLC','Keyman') | Where-Object { (ArmWedges $_).N -eq 0 }

  Say 'VERDICT'
  if ($missing.Count -gt 0) {
    Say ('  [INCONCLUSIVE] no valid trials on: {0}' -f ($missing -join ', '))
    Say  '  A three-arm claim needs all three arms. Do not quote this run in TRIGGER.md.'
  }
  elseif ($sKM.Wedged -gt 0 -and $sMS.Wedged -eq 0 -and $sUS.Wedged -eq 0) {
    Say  '  [PROOF] The wedge appeared ONLY on the Keyman arm.'
    Say ('          Keyman {0}/{1} wedged; MSKLC 0/{2}; US 0/{3}.' -f $sKM.Wedged,$sKM.N,$sMS.N,$sUS.N)
    Say  '          MSKLC clean rules out the layout and rules out Windows dropping the KEYUP:'
    Say  '          same layout, same OS, same stimulus, different implementation.'
    Say  '          US clean rules out this harness manufacturing the phantom Shift.'
  }
  elseif ($sKM.Wedged -eq 0) {
    Say  '  [NOT REPRODUCED] Keyman did not wedge in this run. Nothing is proven either way.'
    Say  '                   Try -LoadThreads 4..6 and a higher -Repeat; the trigger needs the'
    Say  '                   Keyman main thread starved at the wrong instant.'
  }
  else {
    Say  '  [CLAIM FAILS] the wedge appeared on a Microsoft arm too.'
    if ($sMS.Wedged -gt 0) { Say ('                MSKLC {0}/{1} - so this is NOT Keyman-specific. TRIGGER.md must be corrected.' -f $sMS.Wedged,$sMS.N) }
    if ($sUS.Wedged -gt 0) { Say ('                US {0}/{1} - the HARNESS is suspect; its own SendInput may be creating the phantom Shift.' -f $sUS.Wedged,$sUS.N) }
  }
  Say ''

  $ctrlA = @($valid | Where-Object { $_.Candidate -eq 'A' -and $_.Arm -eq 'Keyman' -and $_.Oracle -eq 'Ascii' })
  if ($ctrlA.Count -gt 0) {
    $aw = @($ctrlA | Where-Object { $_.State -eq 'WEDGED' }).Count
    if ($aw -eq 0) { Say ('  internal control A (no freeze) on Keyman: 0/{0} wedged - consistent with the freeze being the mechanism.' -f $ctrlA.Count) }
    else { Say ('  [WARN] internal control A (NO freeze) wedged {0}/{1} on Keyman. The freeze is then NOT the mechanism and the TRIGGER.md story needs rework.' -f $aw,$ctrlA.Count) }
  }
  foreach ($n in $armNotes)     { Say ('  [NOTE] {0}: {1} ({2})' -f $n.Arm,$n.Note,$n.Detail) }
  foreach ($n in $wedgeCarried) { Say ('  [NOTE] {0}: {1}' -f $n.Arm,$n.Note) }

  if ($results.Count -gt 0) {
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    @{ Stamp=$stamp; Arms=$Arms; Repeat=$Repeat; LoadThreads=$LoadThreads; SwitchMode=$SwitchMode
       Fingerprints=$fingerprints; Results=$results; ArmNotes=$armNotes } |
      ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
    Say ''
    Say ("  csv  : {0}" -f $csvPath)
    Say ("  json : {0}" -f $jsonPath)
  }
  Say ("  log  : {0}" -f $log)
  Say '==============================================================='
}
finally {
  foreach ($j in $loadJobs) { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue }
}
