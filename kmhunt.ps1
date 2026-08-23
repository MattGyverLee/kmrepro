<#
  kmhunt.ps1 - find what TRANSITIONS Keyman from clean to wedged.

  WHY
  ---
  Failure counts across the whole 18.0.249 session were strictly bimodal:
    27->0   10->10   10->10   10->10   10->0   8->0   1->0
  All-or-nothing, never a middling rate. That is the signature of a PERSISTENT
  wedged state, not a per-iteration race: once Keyman's cached modifier state is
  wrong, EVERY subsequent keystroke gets a phantom Shift, so every iteration
  fails. A run that starts clean shows 0/N; a run that starts wedged shows N/N.

  So `əŊ` is the SYMPTOM being read out, not the trigger. kmwedge.ps1 was
  structured on the wrong assumption (trigger inside each iteration).

  WHAT THIS DOES
  --------------
  Probe -> candidate action -> probe. If the probe flips from əŋ to əŊ, that
  candidate is the trigger. Each candidate is tried from a verified-clean state,
  and after any wedge we attempt recovery and re-verify before continuing, so
  candidates cannot contaminate each other.

  The probe is behavioural (types ;e then RAlt+N and reads back), because the
  HKL is not a trustworthy oracle and GetAsyncKeyState alone missed the wedge
  in several runs.

  REQUIRES the Cameroon keyboard (sil_cameroon_qwerty) active in the target:
  ';e' -> U+0259, RAlt+N -> U+014B.

  Load emulation is deliberately capped: 32 Start-Job runspaces exhausted memory
  and crashed the host PowerShell during an earlier run.
#>
[CmdletBinding()]
param(
  [string]$TargetProcess = 'notepad',
  [string[]]$Only = @(),        # run only these candidate ids, e.g. -Only A,D
  [int]$Repeat = 1,             # repeat the whole candidate list N times
  [switch]$AsciiOracle,         # LAYOUT-AGNOSTIC oracle: type 'abc', compare case
                                # sensitively. 'abc' is unshifted on BOTH the Cameroon
                                # Keyman keyboard and plain US, so a phantom Shift shows
                                # as 'ABC' either way. This is what makes the
                                # Keyman-vs-Microsoft-keyboard comparison valid - the
                                # ;e/RAlt+N oracle cannot run on a US layout at all.
  [int]$LoadThreads = 0,        # capped at 6
  [string]$LogDir = "$env:TEMP\kmrepro"
)
$ErrorActionPreference = 'Stop'
# `powershell -File script.ps1 -Only A,B` passes "A,B" as ONE string, not an
# array, so a comma list silently matched nothing and every candidate was
# skipped. Split it back out.
if ($Only.Count -eq 1 -and $Only[0] -match ',') { $Only = @($Only[0] -split '\s*,\s*') }
$Only = @($Only | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpper() })
if ($LoadThreads -gt 6) { $LoadThreads = 6 }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type -Namespace Kh -Name N -MemberDefinition @'
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern uint RegisterWindowMessage(string s);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out UIntPtr res);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint tid);
  public delegate bool EW(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EW cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
'@

$UP = 2; $EXT = 1; $FREEZE = 20
$SCHWA = [string][char]0x0259
$ENG   = [string][char]0x014B   # lowercase eng - the clean result
$ENGUP = [string][char]0x014A   # CAPITAL eng  - the wedged result

$log = Join-Path $LogDir 'hunt.txt'
# Write-Host measured at 4301 ms/line on this machine once the console host is
# congested, vs 0.4 ms for [Console]::Out.WriteLine (Add-Content is 1.8 ms, so it
# is not the file I/O). That is a CORRECTNESS bug here, not just slowness: Say is
# called between a candidate's trigger and the probe, and from inside candidate
# I's action, so seconds of dead time let a 5s freeze expire before the probe and
# silently degrade a trial into a no-freeze control. See TRIGGER.md harness traps.
function Say([string]$t) { $l = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $t; [Console]::Out.WriteLine($l); Add-Content -Path $log -Value $l -Encoding utf8 }

function Kd([int]$v, [switch]$E) { $f = 0; if ($E) { $f = $EXT }; [Kh.N]::keybd_event([byte]$v, [byte][Kh.N]::MapVirtualKey($v,0), $f, [UIntPtr]::Zero) }
function Ku([int]$v, [switch]$E) { $f = $UP; if ($E) { $f = $f -bor $EXT }; [Kh.N]::keybd_event([byte]$v, [byte][Kh.N]::MapVirtualKey($v,0), $f, [UIntPtr]::Zero) }
function Tp([int]$v, [int]$g = 70, [switch]$E) { Kd $v -E:$E; Start-Sleep -Milliseconds 40; Ku $v -E:$E; Start-Sleep -Milliseconds $g }

$MODS = @(
  @{V=0xA0;E=$false;L='LShift'}, @{V=0xA1;E=$true; L='RShift'}
  @{V=0xA2;E=$false;L='LCtrl'},  @{V=0xA3;E=$true; L='RCtrl'}
  @{V=0xA4;E=$false;L='LAlt'},   @{V=0xA5;E=$true; L='RAlt'}
)
# CRITICAL: there are TWO Cameroon keyboards on this machine - the Keyman TIP
# (sil_cameroon_qwerty, langid 0x2000) and a Microsoft/MSKLC layout. BOTH map
# ';e' -> U+0259, so the behavioural check CANNOT tell them apart, and Win+Space
# cycling lands on either. That is the most likely cause of candidate B being
# intermittent between runs: on the MS layout Keyman passes keys through
# (k32_lowlevelkeyboardhook.cpp:229-240, !isKeymanKeyboardActive) instead of
# swallowing them, so the trial is not the same experiment at all.
# Log the langid on EVERY trial so no result is unattributable.
#   0x2000 = Keyman TIP    anything else = a non-Keyman layout
function ActiveLangId {
  $p = 0
  $tid = [Kh.N]::GetWindowThreadProcessId($target, [ref]$p)
  return ([Kh.N]::GetKeyboardLayout($tid).ToInt64() -band 0xFFFF)
}
function LayoutTag {
  $l = ActiveLangId
  $name = if ($l -eq 0x2000) { 'KEYMAN' } else { 'non-Keyman' }
  return ('0x{0:X4}/{1}' -f $l, $name)
}

function ModsHeld {
  $h = @(); foreach ($m in $MODS) { if ((([Kh.N]::GetAsyncKeyState($m.V)) -band 0x8000) -ne 0) { $h += $m.L } }
  if ($h.Count -eq 0) { return 'none' }; return ($h -join ',')
}
function ClearMods { foreach ($m in $MODS) { Ku $m.V -E:$m.E; Start-Sleep -Milliseconds 60 }; Start-Sleep -Milliseconds 250 }
function TapAllMods { foreach ($m in $MODS) { Kd $m.V -E:$m.E; Start-Sleep -Milliseconds 90; Ku $m.V -E:$m.E; Start-Sleep -Milliseconds 90 }; Start-Sleep -Milliseconds 300 }

$np = Get-Process -Name $TargetProcess -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $np) { Say "[FAIL] no '$TargetProcess' window"; exit 1 }
$target = $np.MainWindowHandle
[void][Kh.N]::SetForegroundWindow($target); Start-Sleep -Milliseconds 600

$root = [System.Windows.Automation.AutomationElement]::FromHandle($target)
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Document)
$docEl = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
if (-not $docEl) { Say '[FAIL] no Document element'; exit 1 }
$vp = $docEl.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)

$script:km = [IntPtr]::Zero
$kp = (Get-Process keyman -ErrorAction SilentlyContinue | Select-Object -First 1).Id
if ($kp) {
  $cb = [Kh.N+EW]{ param($h,$l)
    $p=0; [void][Kh.N]::GetWindowThreadProcessId($h,[ref]$p)
    if ($p -eq $kp) { $sb=New-Object System.Text.StringBuilder 256; [void][Kh.N]::GetClassName($h,$sb,256)
      if ($sb.ToString() -eq 'TApplication') { $script:km=$h; return $false } }
    return $true }
  [void][Kh.N]::EnumWindows($cb,[IntPtr]::Zero)
}
$msg = [Kh.N]::RegisterWindowMessage('WM_KEYMAN_CONTROL')
function Freeze { if ($script:km -ne [IntPtr]::Zero) { [void][Kh.N]::PostMessage($script:km,$msg,[IntPtr]$FREEZE,[IntPtr]::Zero) } }

# PostMessage is ASYNCHRONOUS: posting cmd 20 does not tell us when keyman.exe
# actually enters its Sleep(5000). With a fixed delay the modifier KEYUP can be
# released BEFORE the freeze has begun, in which case the candidate degenerates
# into the no-freeze control and comes back clean. That is the most likely reason
# candidate B is intermittent between runs.
#
# WaitForFreeze blocks until keyman.exe stops answering WM_NULL, i.e. until the
# stall is CONFIRMED live, so the release is guaranteed to land inside it.
function WaitForFreeze([int]$timeoutMs = 3000) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
    $r = [UIntPtr]::Zero
    $ok = [Kh.N]::SendMessageTimeout($script:km, 0, [IntPtr]::Zero, [IntPtr]::Zero, 2, 60, [ref]$r)
    if ($ok -eq [IntPtr]::Zero) { return $true }   # no reply = thread is blocked
    Start-Sleep -Milliseconds 20
  }
  return $false
}

# ---- the behavioural wedge probe -------------------------------------------
# Clears the field outright rather than counting backspaces: a dropped deadkey
# changes the character count, and miscounted backspaces then corrupt the NEXT
# probe. Ctrl+A/Delete is safe in Notepad (never in FLEx - gotcha #4).
function ClearField {
  Kd 0x11; Start-Sleep -Milliseconds 70
  Tp 0x41 40
  Ku 0x11; Start-Sleep -Milliseconds 120
  Tp 0x2E 40 -E                       # Delete is an EXTENDED key
  Start-Sleep -Milliseconds 200
}

function ProbeOnceAscii {
  ClearField
  Tp 0x41 110; Tp 0x42 110; Tp 0x43 110                      # 'a' 'b' 'c' - no shift sent
  Start-Sleep -Milliseconds 450
  $t = $vp.Current.Value
  if ($null -eq $t) { $t = '' }
  $cp = if ($t) { (($t.ToCharArray() | ForEach-Object {'U+{0:X4}' -f [int]$_}) -join ' ') } else { '<empty>' }
  $state = 'OTHER'
  if     ($t -ceq 'abc') { $state = 'CLEAN' }                # -ceq: case IS the symptom
  elseif ($t -ceq 'ABC') { $state = 'WEDGED' }
  elseif ([string]::IsNullOrEmpty($t)) { $state = 'NO-OUTPUT' }
  return [pscustomobject]@{ State=$state; Text=$t; Cp=$cp; Mods=(ModsHeld) }
}

function ProbeOnce {
  if ($AsciiOracle) { return ProbeOnceAscii }
  ClearField
  Tp 0xBA 130; Tp 0x45 130                                   # ';' 'e'  -> schwa
  Start-Sleep -Milliseconds 200
  Kd 0xA5 -E; Start-Sleep -Milliseconds 130                  # RAlt DOWN (extended)
  Tp 0x4E 130                                                # 'N'
  Ku 0xA5 -E; Start-Sleep -Milliseconds 600                  # RAlt UP
  $t = $vp.Current.Value
  if ($null -eq $t) { $t = '' }
  $cp = if ($t) { (($t.ToCharArray() | ForEach-Object {'U+{0:X4}' -f [int]$_}) -join ' ') } else { '<empty>' }
  # -ceq, NOT -eq: PowerShell's -eq is CASE-INSENSITIVE, and U+014A/U+014B are
  # the upper/lowercase ENG pair - so 'eng' -eq 'ENG' is TRUE and the wedged
  # result compares equal to the clean one. This silently reported WEDGED
  # states as CLEAN until it was caught.
  $state = 'OTHER'
  if     ($t -ceq ($SCHWA + $ENG))   { $state = 'CLEAN' }
  elseif ($t -ceq ($SCHWA + $ENGUP)) { $state = 'WEDGED' }
  elseif ([string]::IsNullOrEmpty($t)) { $state = 'NO-OUTPUT' }
  return [pscustomobject]@{ State=$state; Text=$t; Cp=$cp; Mods=(ModsHeld) }
}

# The deadkey probe is itself flaky (a dropped ';' yields 'e' instead of schwa),
# so read up to 3 times and take the first state seen twice. OTHER/NO-OUTPUT are
# treated as unreliable reads to be retried, NOT as evidence of a wedge - only
# CLEAN and WEDGED are trusted verdicts.
function Probe {
  $seen = @()
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $r = ProbeOnce
    $seen += $r
    $same = @($seen | Where-Object { $_.State -eq $r.State })
    if ($same.Count -ge 2 -and ($r.State -eq 'CLEAN' -or $r.State -eq 'WEDGED')) { return $r }
    Start-Sleep -Milliseconds 250
  }
  $decided = @($seen | Where-Object { $_.State -eq 'CLEAN' -or $_.State -eq 'WEDGED' })
  if ($decided.Count -gt 0) { return $decided[-1] }
  return $seen[-1]
}

# ---- candidate triggers ----------------------------------------------------
# Each is one discrete action, applied from a verified-clean state.
$CANDIDATES = @(
  @{ Id='A'; Desc='bare LShift hold 1.5s + release (no freeze)'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1500; Ku 0xA0; Start-Sleep -Milliseconds 400 } }

  @{ Id='B'; Desc='LShift held, freeze, release INTO the freeze'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1400; Freeze; Start-Sleep -Milliseconds 100
       Ku 0xA0; Start-Sleep -Milliseconds 400 } }

  @{ Id='C'; Desc='LShift held, freeze, release, then type DURING the freeze'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1400; Freeze; Start-Sleep -Milliseconds 100
       Ku 0xA0; Start-Sleep -Milliseconds 150
       Tp 0xBA 60; Tp 0x45 60; Start-Sleep -Milliseconds 300
       for ($i=0;$i -lt 2;$i++){ Tp 8 55 } } }

  @{ Id='D'; Desc='rapid tap of all six modifiers (the "recovery" sweep itself)'; Act={
       TapAllMods } }

  # I is B made DETERMINISTIC: wait until the stall is confirmed live before
  # releasing, instead of guessing with a fixed 100ms delay. B is left exactly
  # as it was.
  @{ Id='I'; Desc='LShift held, freeze CONFIRMED ACTIVE, then release'; Act={
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

  @{ Id='H'; Desc='LShift held across a freeze that is re-posted 3x (long stall)'; Act={
       Kd 0xA0; Start-Sleep -Milliseconds 1400
       Freeze; Start-Sleep -Milliseconds 100
       Freeze; Freeze
       Ku 0xA0; Start-Sleep -Milliseconds 400 } }
)

$loadJobs = @()
if ($LoadThreads -gt 0) {
  for ($i=1; $i -le $LoadThreads; $i++) {
    $loadJobs += Start-Job -ScriptBlock { $x=0.0; while ($true) { $x=[math]::Sqrt([math]::Abs([math]::Sin($x)*1000000.0)) } }
  }
  Start-Sleep -Seconds 2
}

try {
  Say '================ kmhunt ================'
  Say ("target={0} hwnd=0x{1:X}  keyman ctrl=0x{2:X}  load={3}" -f $TargetProcess,$target.ToInt64(),$script:km.ToInt64(),$LoadThreads)
  if ($AsciiOracle) { Say 'probe: ASCII abc (layout-agnostic)   CLEAN=abc   WEDGED=ABC' }
  else { Say 'probe: ;e then RAlt+N   CLEAN=U+0259 U+014B   WEDGED=U+0259 U+014A' }
  Say ''

  $pre = Probe
  Say ("initial state: {0}  '{1}' ({2})  mods={3}" -f $pre.State,$pre.Text,$pre.Cp,$pre.Mods)
  if ($pre.State -ne 'CLEAN') {
    Say '[WARN] not starting clean - attempting recovery before the hunt'
    ClearMods; TapAllMods
    $pre = Probe
    Say ("after recovery: {0} ({1})" -f $pre.State,$pre.Cp)
    if ($pre.State -ne 'CLEAN') { Say '[FAIL] cannot reach a clean baseline; aborting'; exit 1 }
  }
  Say ''

  $hits = @()
  for ($pass=1; $pass -le $Repeat; $pass++) {
    foreach ($c in $CANDIDATES) {
      if ($Only.Count -gt 0 -and $Only -notcontains $c.Id) { continue }
      & $c.Act
      Start-Sleep -Milliseconds 300
      $post = Probe
      $tag = if ($post.State -eq 'CLEAN') { 'clean ' } else { '*** ' + $post.State + ' ***' }
      Say ("pass {0} [{1}] {2,-52} layout={3,-18} -> {4} ({5}) mods={6}" -f $pass,$c.Id,$c.Desc,(LayoutTag),$tag,$post.Cp,$post.Mods)

      if ($post.State -ne 'CLEAN') {
        $hits += ("pass{0}/{1}: {2} -> {3}" -f $pass,$c.Id,$c.Desc,$post.State)
        # try to get back to clean so the next candidate starts fair
        ClearMods
        $r1 = Probe
        if ($r1.State -ne 'CLEAN') {
          Say ("        explicit KEYUP sweep did NOT recover ({0}); trying modifier taps" -f $r1.Cp)
          TapAllMods
          $r2 = Probe
          Say ("        after modifier taps: {0} ({1})" -f $r2.State,$r2.Cp)
          if ($r2.State -ne 'CLEAN') {
            Say '        STILL WEDGED - this is the persistent field symptom. Stopping so it can be examined live.'
            Say '        (Keyman restart is the documented recovery.)'
            break
          }
        } else {
          Say ("        recovered by explicit KEYUP sweep alone ({0})" -f $r1.Cp)
        }
      }
      # let any 5s freeze finish before the next candidate
      Start-Sleep -Milliseconds 5200
    }
  }

  Say ''
  Say '--- RESULT ---'
  if ($hits.Count -eq 0) { Say '  no candidate wedged Keyman' }
  else { foreach ($h in $hits) { Say ("  WEDGED BY: {0}" -f $h) } }
  Say ("  final probe: {0}" -f (Probe).State)
  Say '========================================'
}
finally {
  foreach ($j in $loadJobs) { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue }
}
