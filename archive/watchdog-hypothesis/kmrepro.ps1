<#
  kmrepro.ps1 - Keyman for Windows 18.0.245 low-level-hook watchdog repro rig
  Targets: bug(windows) "keyboard active but no text output / stuck Alt or Alt-Shift"

  Mechanism under test (introduced 18.0.245, commit 83251358b0):
    windows/src/engine/keyman32/LowLevelHookWatchDog.cpp
    - keyman.exe stamps LastLowLevelEventTick in the WH_KEYBOARD_LL hook proc
    - every hooked process posts KMC_WATCHDOG_KEYEVENT (21) on every WM_KEYDOWN
    - if (LastGetMessageEventTick - LastLowLevelEventTick) >= 1000ms, keyman.exe
      calls UnhookWindowsHookEx + SetWindowsHookExW on WH_KEYBOARD_LL
    - a modifier KEYUP that lands in that gap never reaches
      serialkeyeventserver.cpp m_ModifierKeyboardState[], which then stays 0x80
      forever, and keybd_shift_reset() re-injects a phantom modifier KEYDOWN on
      every subsequent keystroke.

  Usage:  powershell -ExecutionPolicy Bypass -File kmrepro.ps1 <Command> [opts]
  Commands: Status Arm Disarm Freeze GhostKey ModWatch Soak TraceStart TraceStop
#>
[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [ValidateSet('Status','Arm','Disarm','Freeze','GhostKey','ModWatch','Soak','TraceStart','TraceStop','Probe','Baseline','AutoTest')]
  [string]$Command = 'Status',
  [string]$TargetProcess = 'notepad',   # GhostKey/Soak/Baseline/AutoTest: target window
  [ValidateSet('Clean','Freeze','Ghost')][string]$Scenario = 'Clean',  # AutoTest scenario
  [int]$Iterations = 10,        # AutoTest: probe cycles
  [int]$Count       = 1,        # GhostKey: how many ghost keydowns
  [int]$IdleMs      = 1500,     # GhostKey/Soak: required keyboard-idle before posting
  [int]$Minutes     = 10,       # Soak: duration
  [int]$IntervalMs  = 2500,     # Soak: ms between ghost keys
  [int]$HookTimeout = 200,      # Arm: HKCU LowLevelHooksTimeout value (ms)
  [int]$StuckMs     = 2000,     # ModWatch: alert if modifier held this long while idle
  [string]$LogDir   = "$env:TEMP\kmrepro"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

Add-Type -Namespace Km -Name Native -MemberDefinition @'
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern uint RegisterWindowMessage(string lpString);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
                                                 uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  [DllImport("user32.dll")]
  public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)]
  public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")]
  public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  [DllImport("kernel32.dll")]
  public static extern uint GetTickCount();
  // keybd_event is used deliberately instead of SendInput: it produces events
  // that reach WH_KEYBOARD_LL exactly like physical keys, and Keyman only
  // filters on dwExtraInfo != 0 (k32_lowlevelkeyboardhook.cpp:227), so passing
  // 0 makes Keyman treat these as real user input.
  [DllImport("user32.dll")]
  public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")]
  public static extern uint MapVirtualKey(uint uCode, uint uMapType);
  [DllImport("user32.dll")]
  public static extern IntPtr GetKeyboardLayout(uint idThread);
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);
'@

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue

# ---- constants taken directly from the Keyman source ------------------------
$RWM_KEYMAN_CONTROL      = 'WM_KEYMAN_CONTROL'                      # keymancontrol.h:70
$KMC_WATCHDOG_FAKEFREEZE = 20                                       # keymancontrol.h:52
$WM_KEYDOWN              = 0x0100
$KM_REGKEY               = 'HKCU:\Software\Keyman\Keyman Engine'    # registry.h:39
$KM_ETW_GUID             = '{DA621615-E08B-4283-918E-D2502D3757AE}' # k32_dbg.cpp:59
$DESKTOP_REGKEY          = 'HKCU:\Control Panel\Desktop'

$MODS = [ordered]@{ 'LShift'=0xA0; 'RShift'=0xA1; 'LCtrl'=0xA2; 'RCtrl'=0xA3; 'LAlt'=0xA4; 'RAlt'=0xA5 }

function Get-KeymanMasterController {
  # UfrmKeyman7Main.pas:617 -> RegisterMasterController(Application.Handle)
  # A Delphi VCL Application handle window has class 'TApplication'.
  $proc = Get-Process -Name keyman -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) { return [IntPtr]::Zero }
  $script:kmFound = [IntPtr]::Zero
  $script:kmPid   = $proc.Id
  $cb = [Km.Native+EnumWindowsProc]{
    param($h, $l)
    $opid = 0
    [void][Km.Native]::GetWindowThreadProcessId($h, [ref]$opid)
    if ($opid -eq $script:kmPid) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][Km.Native]::GetClassName($h, $sb, 256)
      if ($sb.ToString() -eq 'TApplication') { $script:kmFound = $h; return $false }
    }
    return $true
  }
  [void][Km.Native]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:kmFound
}

function Get-KeyboardIdleMs {
  $lii = New-Object Km.Native+LASTINPUTINFO
  $lii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lii)
  [void][Km.Native]::GetLastInputInfo([ref]$lii)
  return ([Km.Native]::GetTickCount() - $lii.dwTime)
}

function Get-ModifierSnapshot {
  $s = @{}
  foreach ($k in $MODS.Keys) { $s[$k] = (([Km.Native]::GetAsyncKeyState($MODS[$k]) -band 0x8000) -ne 0) }
  return $s
}

function Get-ModsDownString($snap) {
  $d = @($snap.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })
  if ($d.Count -eq 0) { return 'none' }
  return ($d -join ',')
}

function Write-Log($msg) {
  $line = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $msg
  # NOT Write-Host: 4301 ms/line vs 0.4 ms once conhost congests. See TRIGGER.md.
  [Console]::Out.WriteLine($line)
  Add-Content -Path "$LogDir\kmrepro.log" -Value $line -Encoding utf8
}

function Get-ProcessMainWindow([string]$name) {
  # Find a top-level visible window belonging to $name. Notepad on Win11 hosts
  # its edit control in a child window, but WH_GETMESSAGE is THREAD-scoped, so
  # posting to any window of that thread is sufficient to trip the hook.
  $p = Get-Process -Name $name -ErrorAction SilentlyContinue |
       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($p) { return $p.MainWindowHandle }
  return [IntPtr]::Zero
}

function Test-KeymanResponsive([int]$TimeoutMs = 6000) {
  # Objective freeze oracle. WM_NULL is a no-op; if keyman.exe's main thread is
  # inside Sleep(5000) it cannot pump, so SendMessageTimeout returns 0 (timeout).
  $hwnd = Get-KeymanMasterController
  if ($hwnd -eq [IntPtr]::Zero) { return [pscustomobject]@{ Ok=$false; Ms=-1; Reason='no controller window' } }
  $res = [UIntPtr]::Zero
  $sw  = [Diagnostics.Stopwatch]::StartNew()
  # 0x0002 = SMTO_ABORTIFHUNG, 0x0001 = SMTO_BLOCK
  $r = [Km.Native]::SendMessageTimeout($hwnd, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero, 0x0003, $TimeoutMs, [ref]$res)
  $sw.Stop()
  return [pscustomobject]@{ Ok = ($r -ne [IntPtr]::Zero); Ms = [int]$sw.ElapsedMilliseconds; Reason = '' }
}

$KEYEVENTF_KEYUP      = 0x0002
$KEYEVENTF_EXTENDEDKEY = 0x0001

function Send-PhysicalKey([byte]$vk, [switch]$Up, [switch]$Extended) {
  $scan = [byte]([Km.Native]::MapVirtualKey($vk, 0))
  $flags = 0
  if ($Up)       { $flags = $flags -bor $KEYEVENTF_KEYUP }
  if ($Extended) { $flags = $flags -bor $KEYEVENTF_EXTENDEDKEY }
  [Km.Native]::keybd_event($vk, $scan, $flags, [UIntPtr]::Zero)
}

function Send-PhysicalTap([byte]$vk, [int]$GapMs = 25, [switch]$Extended) {
  Send-PhysicalKey $vk -Extended:$Extended
  Start-Sleep -Milliseconds $GapMs
  Send-PhysicalKey $vk -Up -Extended:$Extended
  Start-Sleep -Milliseconds $GapMs
}

function Send-PhysicalString([string]$s, [int]$GapMs = 40) {
  foreach ($ch in $s.ToCharArray()) {
    $vk = [byte][char]([string]$ch).ToUpper()
    Send-PhysicalTap $vk $GapMs
  }
}

function Get-UiaText([IntPtr]$hwnd) {
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if (-not $root) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition(
              [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
              [System.Windows.Automation.ControlType]::Document)
    $doc = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $doc) { return $null }
    $vp = $null
    if ($doc.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
      return $vp.Current.Value
    }
    $tp = $null
    if ($doc.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$tp)) {
      return $tp.DocumentRange.GetText(-1)
    }
    return $null
  } catch { return $null }
}

function Test-KeymanKeyboardActive([IntPtr]$hwnd) {
  # Keyman TIPs are registered under the transient language id 0x2000 (and
  # 0x046A etc. for assigned BCP47 tags). A Keyman keyboard being active shows
  # up as a Keyman TIP in the thread's HKL.
  $p = 0
  $tid = [Km.Native]::GetWindowThreadProcessId($hwnd, [ref]$p)
  $hkl = [Km.Native]::GetKeyboardLayout($tid)
  $lang = $hkl.ToInt64() -band 0xFFFF
  return [pscustomobject]@{ Tid=$tid; Hkl=$hkl; LangId=$lang; IsKeyman=($lang -eq 0x2000) }
}

function Set-Foreground([IntPtr]$hwnd) {
  [void][Km.Native]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 250
  return ([Km.Native]::GetForegroundWindow() -eq $hwnd)
}

function Get-KeymanVersion {
  # keyman.exe's Path is not readable from an unelevated shell, so read the
  # installed version out of the registry instead.
  foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Keyman\Keyman Desktop',
                   'HKLM:\SOFTWARE\Keyman\Keyman Desktop')) {
    $v = (Get-ItemProperty -Path $k -Name 'version' -ErrorAction SilentlyContinue).version
    if ($v) { return $v }
  }
  foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Keyman\Keyman Desktop',
                   'HKLM:\SOFTWARE\Keyman\Keyman Desktop')) {
    $rp = (Get-ItemProperty -Path $k -Name 'root path' -ErrorAction SilentlyContinue).'root path'
    if ($rp -and (Test-Path (Join-Path $rp 'keyman.exe'))) {
      return (Get-Item (Join-Path $rp 'keyman.exe')).VersionInfo.FileVersion
    }
  }
  return $null
}

# ----------------------------------------------------------------------------
switch ($Command) {

'Status' {
  $proc = Get-Process -Name keyman -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($proc) { Write-Host "[OK]   keyman.exe is running, pid=$($proc.Id)" }
  else       { Write-Host "[FAIL] keyman.exe is not running" }

  $ver = Get-KeymanVersion
  if ($ver) {
    Write-Host "[OK]   installed version = $ver"
    try {
      $p = ($ver -split '[\s,]')[0] -split '\.'
      $v = [version]("{0}.{1}.{2}" -f $p[0], $p[1], $p[2])
      if ($v -ge [version]'18.0.245') {
        Write-Host "[WARN] this build CONTAINS LowLevelHookWatchDog (18.0.245+) - TREATMENT group"
      } else {
        Write-Host "[INFO] this build has NO watchdog (< 18.0.245) - CONTROL group"
        Write-Host "[INFO] Freeze/GhostKey should produce NO stuck modifiers here. That is the baseline."
      }
    } catch { Write-Host "[INFO] could not parse version '$ver' for the watchdog check" }
  } else {
    Write-Host "[FAIL] could not determine installed Keyman version"
  }

  $hwnd = Get-KeymanMasterController
  if ($hwnd -ne [IntPtr]::Zero) {
    Write-Host ("[OK]   master controller hwnd=0x{0:X}" -f $hwnd.ToInt64())
  } else {
    Write-Host "[FAIL] could not find keyman.exe TApplication window"
  }

  $dbg = (Get-ItemProperty -Path $KM_REGKEY -Name 'debug' -ErrorAction SilentlyContinue).debug
  if ($null -eq $dbg) { $dbg = '<unset>' }
  Write-Host "[INFO] HKCU\Software\Keyman\Keyman Engine\debug = $dbg   (1 = ETW logging on)"

  $llt = (Get-ItemProperty -Path $DESKTOP_REGKEY -Name 'LowLevelHooksTimeout' -ErrorAction SilentlyContinue).LowLevelHooksTimeout
  if ($null -eq $llt) { $llt = '<unset, Windows default>' } else { $llt = "$llt ms" }
  Write-Host "[INFO] HKCU\Control Panel\Desktop\LowLevelHooksTimeout = $llt"

  Write-Host "[INFO] keyboard idle right now: $(Get-KeyboardIdleMs) ms"
  Write-Host "[INFO] modifiers down right now: $(Get-ModsDownString (Get-ModifierSnapshot))"
}

'Arm' {
  if (-not (Test-Path $KM_REGKEY)) { New-Item -Path $KM_REGKEY -Force | Out-Null }
  Set-ItemProperty -Path $KM_REGKEY -Name 'debug' -Value 1 -Type DWord
  Set-ItemProperty -Path $DESKTOP_REGKEY -Name 'LowLevelHooksTimeout' -Value $HookTimeout -Type DWord
  Write-Host "[OK]   Keyman ETW logging enabled (HKCU\Software\Keyman\Keyman Engine\debug = 1)"
  Write-Host "[OK]   LowLevelHooksTimeout = $HookTimeout ms"
  Write-Host "[WARN] Sign out and back in (or reboot) for LowLevelHooksTimeout to take effect."
  Write-Host "[WARN] Restart Keyman so hooked processes pick up the debug flag."
}

'Disarm' {
  Set-ItemProperty -Path $KM_REGKEY -Name 'debug' -Value 0 -Type DWord -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path $DESKTOP_REGKEY -Name 'LowLevelHooksTimeout' -ErrorAction SilentlyContinue
  Write-Host "[OK]   debug=0; LowLevelHooksTimeout removed. Sign out/in to restore the Windows default."
}

'Freeze' {
  # Posts KMC_WATCHDOG_FAKEFREEZE. UfrmKeyman7Main.pas:856 -> Sleep(5000) on
  # keyman.exe's MAIN thread, which is the thread that owns WH_KEYBOARD_LL.
  # Windows evicts an LL hook whose proc exceeds LowLevelHooksTimeout.
  $hwnd = Get-KeymanMasterController
  if ($hwnd -eq [IntPtr]::Zero) { Write-Log '[FAIL] no master controller window'; break }
  $msg = [Km.Native]::RegisterWindowMessage($RWM_KEYMAN_CONTROL)
  Write-Log ("[FREEZE] posting KMC_WATCHDOG_FAKEFREEZE to hwnd=0x{0:X} msg=0x{1:X}" -f $hwnd.ToInt64(), $msg)
  $ok = [Km.Native]::PostMessage($hwnd, $msg, [IntPtr]$KMC_WATCHDOG_FAKEFREEZE, [IntPtr]::Zero)
  if ($ok) {
    Write-Log '[FREEZE] posted - keyman.exe main thread sleeps 5s NOW. Type into the target app immediately.'
  } else {
    Write-Log "[FAIL] PostMessage failed: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
}

'GhostKey' {
  # Forces the watchdog false-positive WITHOUT any freeze.
  # A PostMessage'd WM_KEYDOWN never passes through WH_KEYBOARD_LL, but IS seen
  # by kmnGetMessageProc, which posts KMC_WATCHDOG_KEYEVENT. With the keyboard
  # idle >1000ms, LastGM - LastLL exceeds the threshold and a perfectly healthy
  # hook is torn out and reinstalled.
  $target = [Km.Native]::GetForegroundWindow()
  Write-Log ("[GHOST] target hwnd=0x{0:X}  vk=0x7C (F13)  n={1}  idleGate={2}ms" -f $target.ToInt64(), $Count, $IdleMs)
  for ($i = 1; $i -le $Count; $i++) {
    while ((Get-KeyboardIdleMs) -lt $IdleMs) { Start-Sleep -Milliseconds 100 }
    $pre  = Get-ModifierSnapshot
    $idle = Get-KeyboardIdleMs
    $ok   = [Km.Native]::PostMessage($target, $WM_KEYDOWN, [IntPtr]0x7C, [IntPtr]0x00410001)
    Write-Log ("[GHOST] {0}/{1} posted={2} idle={3}ms modsDown={4}" -f $i, $Count, $ok, $idle, (Get-ModsDownString $pre))
    Start-Sleep -Milliseconds 300
  }
  Write-Log "[GHOST] done. Search the ETW trace for 'watchdog threshold exceeded'."
}

'ModWatch' {
  # The machine oracle. A modifier that GetAsyncKeyState reports as DOWN while
  # the keyboard is idle is a phantom injected by keybd_shift_reset().
  Write-Log "[WATCH] sampling every 50ms; alert threshold ${StuckMs}ms. Ctrl+C to stop."
  $downSince = @{}
  $alerted   = @{}
  foreach ($k in $MODS.Keys) { $alerted[$k] = $false }
  while ($true) {
    $now  = [Km.Native]::GetTickCount()
    $snap = Get-ModifierSnapshot
    foreach ($k in $MODS.Keys) {
      if ($snap[$k]) {
        if (-not $downSince.ContainsKey($k)) { $downSince[$k] = $now }
        $held = $now - $downSince[$k]
        $idle = Get-KeyboardIdleMs
        if ($held -ge $StuckMs -and -not $alerted[$k] -and $idle -ge $StuckMs) {
          Write-Log "[STUCK] *** $k DOWN for ${held}ms with ${idle}ms keyboard idle - PHANTOM MODIFIER ***"
          $alerted[$k] = $true
        }
      } else {
        if ($downSince.ContainsKey($k)) {
          if ($alerted[$k]) { Write-Log "[STUCK] $k cleared after $($now - $downSince[$k])ms" }
          $downSince.Remove($k) | Out-Null
        }
        $alerted[$k] = $false
      }
    }
    Start-Sleep -Milliseconds 50
  }
}

'Soak' {
  # Experiment C: churn the hook in the background while a human types normally.
  $target = [Km.Native]::GetForegroundWindow()
  Write-Log "[SOAK] $Minutes min, ghost key every ${IntervalMs}ms, idle gate ${IdleMs}ms."
  Write-Log ("[SOAK] locked target hwnd=0x{0:X} - keep that app focused and type naturally." -f $target.ToInt64())
  Write-Log '[SOAK] Run ModWatch in a second PowerShell window.'
  $end = (Get-Date).AddMinutes($Minutes)
  $n = 0; $skipped = 0
  while ((Get-Date) -lt $end) {
    Start-Sleep -Milliseconds $IntervalMs
    if ((Get-KeyboardIdleMs) -lt $IdleMs) { $skipped++; continue }
    $n++
    [void][Km.Native]::PostMessage($target, $WM_KEYDOWN, [IntPtr]0x7C, [IntPtr]0x00410001)
    if ($n % 10 -eq 0) { Write-Log "[SOAK] $n ghost keys posted ($skipped skipped for typing activity)" }
  }
  Write-Log "[SOAK] finished: $n ghost keys posted, $skipped skipped."
}

'Probe' {
  $r = Test-KeymanResponsive
  if ($r.Ok) { Write-Log "[PROBE] keyman.exe responded to WM_NULL in $($r.Ms)ms - main thread is pumping" }
  else       { Write-Log "[PROBE] keyman.exe DID NOT respond within $($r.Ms)ms - main thread is BLOCKED $($r.Reason)" }
}

'Baseline' {
  # Fully automated control/treatment run. No human input required.
  # Produces a report that can be diffed between Keyman versions.
  $report = "$LogDir\baseline-$((Get-KeymanVersion) -replace '[^0-9]','_').txt"
  function Rep($s) { Write-Log $s; Add-Content -Path $report -Value $s -Encoding utf8 }

  Rep "================ kmrepro BASELINE ================"
  Rep "when          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  Rep "keyman version: $(Get-KeymanVersion)"
  $proc = Get-Process -Name keyman -ErrorAction SilentlyContinue | Select-Object -First 1
  Rep "keyman running: $(if($proc){"yes pid=$($proc.Id)"}else{'NO'})"
  $hwnd = Get-KeymanMasterController
  Rep ("controller    : 0x{0:X}" -f $hwnd.ToInt64())
  $llt = (Get-ItemProperty -Path $DESKTOP_REGKEY -Name 'LowLevelHooksTimeout' -ErrorAction SilentlyContinue).LowLevelHooksTimeout
  Rep "LLHooksTimeout: $(if($null -eq $llt){'<default>'}else{$llt})"
  $dbg = (Get-ItemProperty -Path $KM_REGKEY -Name 'debug' -ErrorAction SilentlyContinue).debug
  Rep "keyman debug  : $(if($null -eq $dbg){'<unset>'}else{$dbg})"
  Rep ""

  # --- T1: baseline responsiveness -----------------------------------------
  Rep "--- T1 responsiveness (3 samples, expect all OK, low ms) ---"
  $t1 = @()
  for ($i=1; $i -le 3; $i++) { $r = Test-KeymanResponsive; $t1 += $r; Rep ("  sample {0}: ok={1} {2}ms" -f $i,$r.Ok,$r.Ms); Start-Sleep -Milliseconds 400 }
  Rep ""

  # --- T2: does KMC_WATCHDOG_FAKEFREEZE do anything on this build? ----------
  Rep "--- T2 fakefreeze probe (post cmd 20, then measure responsiveness) ---"
  $msg = [Km.Native]::RegisterWindowMessage($RWM_KEYMAN_CONTROL)
  Rep ("  WM_KEYMAN_CONTROL = 0x{0:X}" -f $msg)
  [void][Km.Native]::PostMessage($hwnd, $msg, [IntPtr]$KMC_WATCHDOG_FAKEFREEZE, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 250
  $r2 = Test-KeymanResponsive 7000
  Rep ("  after cmd 20: ok={0} {1}ms" -f $r2.Ok, $r2.Ms)
  if ($r2.Ms -ge 2000 -or -not $r2.Ok) { Rep "  VERDICT: FREEZE IS LIVE on this build (main thread blocked)" }
  else                                 { Rep "  VERDICT: cmd 20 is INERT on this build (no watchdog code)" }
  Start-Sleep -Seconds 6
  Rep ""

  # --- T3: ghost-key burst with inline phantom-modifier sampling -------------
  Rep "--- T3 ghost-key burst ($Count posts, idle gate ${IdleMs}ms) ---"
  $target = Get-ProcessMainWindow $TargetProcess
  if ($target -eq [IntPtr]::Zero) {
    $target = [Km.Native]::GetForegroundWindow()
    Rep "  WARNING: '$TargetProcess' not found, falling back to foreground window"
  }
  Rep ("  target: {0} hwnd=0x{1:X}" -f $TargetProcess, $target.ToInt64())
  $phantoms = 0; $posted = 0; $unresponsive = 0
  for ($i=1; $i -le $Count; $i++) {
    $spin = 0
    while ((Get-KeyboardIdleMs) -lt $IdleMs -and $spin -lt 200) { Start-Sleep -Milliseconds 100; $spin++ }
    if ((Get-KeyboardIdleMs) -lt $IdleMs) { Rep "  post $i SKIPPED (keyboard not idle)"; continue }
    [void][Km.Native]::PostMessage($target, $WM_KEYDOWN, [IntPtr]0x7C, [IntPtr]0x00410001)
    $posted++
    # sample modifiers for 1.5s after each ghost key
    $hit = @()
    for ($s=0; $s -lt 30; $s++) {
      Start-Sleep -Milliseconds 50
      $snap = Get-ModifierSnapshot
      foreach ($k in $MODS.Keys) { if ($snap[$k] -and $hit -notcontains $k) { $hit += $k } }
    }
    $rr = Test-KeymanResponsive 3000
    if (-not $rr.Ok) { $unresponsive++ }
    if ($hit.Count -gt 0) { $phantoms++; Rep "  post $i : PHANTOM MODIFIER(S) $($hit -join ',')  keymanResponsive=$($rr.Ok)" }
    elseif ($i % 5 -eq 0) { Rep "  post $i : clean (responsive=$($rr.Ok) $($rr.Ms)ms)" }
  }
  Rep ""
  Rep "--- RESULT ---"
  Rep "  ghost keys posted    : $posted / $Count"
  Rep "  phantom modifiers    : $phantoms"
  Rep "  keyman unresponsive  : $unresponsive"
  Rep "  final modifiers down : $(Get-ModsDownString (Get-ModifierSnapshot))"
  Rep "=================================================="
  Write-Host ""
  Write-Host "[OK]   report written to $report"
}

'AutoTest' {
  # Fully automated end-to-end test. No human input required.
  #
  # Expected output is LEARNED from a clean run rather than hard-coded, so this
  # works with any Keyman keyboard. Each subsequent iteration is compared to
  # that learned string; any deviation is a failure.
  $report = "$LogDir\autotest-$((Get-KeymanVersion) -replace '[^0-9]','_')-$Scenario.txt"
  function Rep($s) { Write-Log $s; Add-Content -Path $report -Value $s -Encoding utf8 }

  $target = Get-ProcessMainWindow $TargetProcess
  if ($target -eq [IntPtr]::Zero) { Rep "[FAIL] '$TargetProcess' has no window"; break }
  if (-not (Set-Foreground $target)) { Rep "[WARN] could not bring '$TargetProcess' to the foreground; continuing" }

  $kb = Test-KeymanKeyboardActive $target
  Rep "================ kmrepro AUTOTEST ================"
  Rep "when          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  Rep "keyman version: $(Get-KeymanVersion)"
  Rep "scenario      : $Scenario   iterations: $Iterations"
  Rep ("target        : {0} hwnd=0x{1:X} tid={2}" -f $TargetProcess, $target.ToInt64(), $kb.Tid)
  Rep ("keyboard      : HKL=0x{0:X} langid=0x{1:X4} keymanActive={2}" -f $kb.Hkl.ToInt64(), $kb.LangId, $kb.IsKeyman)
  if (-not $kb.IsKeyman) {
    # NOT a hard failure: GetKeyboardLayout() does not reliably track TSF
    # profile switches, so a live Keyman TIP can still report langid 0x0409.
    # Verified 18.0.249: HKL said 0x0409 while ';e' correctly produced U+0259.
    # The authoritative check is the behavioural "sanity gate" below, which
    # requires the Keyman-only codepoints to actually appear. Trust that one.
    Rep "[WARN] HKL does not show a Keyman langid (0x2000) in '$TargetProcess'."
    Rep "       Not fatal - deferring to the behavioural sanity gate below."
  }
  if ($null -eq (Get-UiaText $target)) { Rep "[FAIL] cannot read text from '$TargetProcess' via UI Automation"; break }
  Rep ""

  function Clear-Target {
    Send-PhysicalKey 0x11                 # Ctrl down
    Send-PhysicalTap  0x41 20             # A
    Send-PhysicalKey 0x11 -Up             # Ctrl up
    Start-Sleep -Milliseconds 120
    Send-PhysicalTap 0x2E 20              # Delete
    Start-Sleep -Milliseconds 250
  }

  # Three probe segments, each exercising a different part of the engine.
  #   shift   - LShift held across a burst. A lost KEYUP corrupts this.
  #             NOTE: this segment alone proves nothing about Keyman - the plain
  #             US layout produces the same string. It is the stuck-modifier
  #             detector only.
  #   deadkey - ';' then 'e' -> U+0259 LATIN SMALL LETTER SCHWA. A multi-key
  #             rule; requires Keyman's cached context to be intact.
  #   ralt    - RIGHT Alt held + N -> U+014B LATIN SMALL LETTER ENG. Requires
  #             the RIGHT-alt modifier state to be correct. RAlt must be sent
  #             EXTENDED: UpdateLocalModifierState() distinguishes L/R Alt
  #             purely by the extended flag (serialkeyeventserver.cpp:557).
  $SCHWA = [char]0x0259   # e
  $ENG   = [char]0x014B   # NG
  $PROBES = @(
    @{ Name='shift';   KeymanProof=$false; Run={
         Send-PhysicalString 'abc'
         Send-PhysicalKey 0xA0; Start-Sleep -Milliseconds 60      # LShift DOWN
         Send-PhysicalString 'def'; Start-Sleep -Milliseconds 60
         Send-PhysicalKey 0xA0 -Up; Start-Sleep -Milliseconds 60  # LShift UP (at risk)
         Send-PhysicalString 'ghi' } }
    @{ Name='deadkey'; KeymanProof=$true;  Must=$SCHWA; Run={
         Send-PhysicalTap 0xBA 60      # VK_OEM_1  ';'
         Send-PhysicalTap 0x45 60 } }  # 'e'   -> schwa
    @{ Name='ralt';    KeymanProof=$true;  Must=$ENG;   Run={
         Send-PhysicalKey 0xA5 -Extended; Start-Sleep -Milliseconds 80   # RAlt DOWN
         Send-PhysicalTap 0x4E 60                                       # N
         Send-PhysicalKey 0xA5 -Up -Extended; Start-Sleep -Milliseconds 80 } }
  )

  function Invoke-Probe($p) { & $p.Run; Start-Sleep -Milliseconds 500 }

  function Invoke-AllProbes {
    foreach ($p in $PROBES) { Invoke-Probe $p }
    Start-Sleep -Milliseconds 300
  }

  # --- learn the expected output of each segment on a clean run --------------
  Rep "--- learned baseline (per segment) ---"
  $exp = @{}
  foreach ($p in $PROBES) {
    Clear-Target
    Invoke-Probe $p
    $exp[$p.Name] = Get-UiaText $target
    Rep ("  {0,-8} -> '{1}'" -f $p.Name, $exp[$p.Name])
  }

  # Sanity gate: if the Keyman-only characters are absent, Keyman is NOT
  # processing input and every later result would be meaningless.
  $engaged = $true
  foreach ($p in $PROBES) {
    if ($p.KeymanProof -and ($exp[$p.Name] -notmatch [regex]::Escape($p.Must))) {
      Rep ("[FAIL] segment '{0}' did not produce U+{1:X4} - Keyman is NOT processing input" -f $p.Name, [int]$p.Must)
      $engaged = $false
    }
  }
  if (-not $engaged) {
    Rep "       Check that the Cameroon Keyman keyboard is selected in '$TargetProcess',"
    Rep "       or that Keyman is not already wedged (tap each modifier once / restart Keyman)."
    break
  }
  Rep "[OK]   Keyman confirmed engaged (schwa and eng both produced)"

  $expected = ($PROBES | ForEach-Object { $exp[$_.Name] }) -join ''
  Rep "  combined expected = '$expected'"
  if ([string]::IsNullOrEmpty($expected)) {
    Rep "[FAIL] clean run produced NO output at all - Keyman may already be wedged."
    break
  }
  Rep ""

  # --- iterate --------------------------------------------------------------
  $msg = [Km.Native]::RegisterWindowMessage($RWM_KEYMAN_CONTROL)
  $hwndKm = Get-KeymanMasterController
  $fail = 0; $phantom = 0; $empty = 0; $ran = 0
  Rep "--- $Iterations iterations of scenario '$Scenario' ---"
  for ($i = 1; $i -le $Iterations; $i++) {
    Clear-Target

    switch ($Scenario) {
      'Freeze' {
        # hang keyman.exe's main thread, then type across the freeze
        [void][Km.Native]::PostMessage($hwndKm, $msg, [IntPtr]$KMC_WATCHDOG_FAKEFREEZE, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 150
      }
      'Ghost' {
        # force the watchdog false-positive: >1s keyboard idle, then a
        # PostMessage'd WM_KEYDOWN that the LL hook never sees
        Start-Sleep -Milliseconds ($IdleMs + 200)
        [void][Km.Native]::PostMessage($target, $WM_KEYDOWN, [IntPtr]0x7C, [IntPtr]0x00410001)
        Start-Sleep -Milliseconds 150
      }
      'Clean' { Start-Sleep -Milliseconds 150 }
    }

    Invoke-AllProbes
    $ran++
    $got  = Get-UiaText $target
    $mods = Get-ModsDownString (Get-ModifierSnapshot)
    $resp = Test-KeymanResponsive 3000

    $bad = @()
    if ([string]::IsNullOrEmpty($got)) { $bad += 'NO-OUTPUT'; $empty++ }
    elseif ($got -ne $expected)        { $bad += 'WRONG-OUTPUT' }
    if ($mods -ne 'none')              { $bad += "PHANTOM:$mods"; $phantom++ }

    if ($bad.Count -gt 0) {
      $fail++
      Rep ("  iter {0,3} : FAIL [{1}]  responsive={2}" -f $i, ($bad -join ' '), $resp.Ok)
      Rep ("           expected='{0}'" -f $expected)
      Rep ("           got     ='{0}'" -f $got)
      # localise: which segment broke?
      foreach ($p in $PROBES) {
        Clear-Target; Invoke-Probe $p
        $seg = Get-UiaText $target
        $mark = if ($seg -eq $exp[$p.Name]) { 'ok  ' } else { 'BAD ' }
        Rep ("           {0} {1,-8} expected='{2}' got='{3}'" -f $mark, $p.Name, $exp[$p.Name], $seg)
      }
      # try the candidate field workaround and record whether it recovers
      foreach ($m in @(0xA0,0xA1,0xA2,0xA3,0xA4,0xA5)) { Send-PhysicalTap $m 30 }
      Clear-Target; Invoke-AllProbes
      $after = Get-UiaText $target
      if ($after -eq $expected) { Rep "           -> RECOVERED by tapping modifiers (stuck m_ModifierKeyboardState)" }
      else                      { Rep "           -> NOT recovered by tapping modifiers (got='$after')" }
    }
    elseif ($i % 5 -eq 0) { Rep ("  iter {0,3} : ok" -f $i) }
  }

  Rep ""
  Rep "--- RESULT ---"
  Rep "  scenario            : $Scenario"
  Rep "  iterations run      : $ran"
  Rep "  failures            : $fail"
  Rep "    of which no output: $empty"
  Rep "  phantom modifiers   : $phantom"
  Rep "  final mods down     : $(Get-ModsDownString (Get-ModifierSnapshot))"
  Rep "=================================================="
  Write-Host ""
  Write-Host "[OK]   report written to $report"
}

'TraceStart' {
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $admin) {
    Write-Host "[FAIL] ETW trace sessions require an ELEVATED PowerShell. Re-run as administrator."
    break
  }
  $etl = "$LogDir\keyman-ring.etl"
  cmd /c "logman stop KeymanRing -ets" 2>&1 | Out-Null
  $out = cmd /c "logman create trace KeymanRing -p ""$KM_ETW_GUID"" 0xFFFFFFFF 5 -mode Circular -max 64 -o ""$etl"" -ets" 2>&1
  $out | Write-Host
  if ($LASTEXITCODE -ne 0 -or ($out -match 'Error')) {
    Write-Host "[FAIL] could not start the trace session (see message above)."
  } else {
    Write-Host "[OK]   circular 64MB ETW ring started -> $etl"
    Write-Host "[INFO] it never grows past 64MB; safe to leave running for days."
  }
}

'TraceStop' {
  $etl = "$LogDir\keyman-ring.etl"
  $out = cmd /c "logman stop KeymanRing -ets" 2>&1
  $out | Write-Host
  if ($LASTEXITCODE -ne 0 -or ($out -match 'Error')) {
    Write-Host "[FAIL] no running KeymanRing session to stop (or not elevated)."
    break
  }
  Write-Host "[OK]   trace stopped -> $etl"
  Write-Host "[NEXT] decode with Keyman's etl2log.exe, or:"
  Write-Host "         tracerpt ""$etl"" -o ""$LogDir\keyman.xml"" -of XML"
  Write-Host "[NEXT] then search for:"
  Write-Host "         'watchdog threshold exceeded'      <- watchdog fired"
  Write-Host "         'reinstall low level hook'         <- reinstall result"
  Write-Host "         'm_ModifierKeyboardState'          <- Keyman's cached modifier state"
  Write-Host "         'kmc_fakefreeze'                   <- Freeze command markers"
}

}
