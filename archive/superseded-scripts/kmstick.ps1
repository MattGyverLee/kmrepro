<#
  kmstick.ps1 - minimal reproduction of the stuck-modifier bug.

  Isolated from kmwedge.ps1 by elimination on 18.0.249.0:
    ghost key (watchdog) only ................. 0 / 27 failures
    heavy CPU load only ....................... 0 / 10 failures
    blocked keyman.exe main thread only ...... 10 / 10 failures   <-- the trigger

  So the LowLevelHookWatchDog is NOT involved. The trigger is simply:
  release a modifier while keyman.exe's main thread - the thread that owns
  WH_KEYBOARD_LL - is blocked. Keyman's LL hook swallows every keystroke and
  re-injects it (k32_lowlevelkeyboardhook.cpp:255-259), so if that thread cannot
  run, the modifier's KEYUP is lost and the key stays down in WINDOWS' OWN key
  state, observable via GetAsyncKeyState.

  This script types NOTHING. It only holds a modifier, blocks keyman.exe,
  releases the modifier, and reads GetAsyncKeyState. That makes it layout
  independent, so the SAME test can run with a Keyman keyboard active and with
  the plain US keyboard active - which is the discriminator for how widely
  users are exposed:

    sticks only with a Keyman keyboard selected
        -> exposure limited to active Keyman typing
    sticks whenever keyman.exe is merely RUNNING
        -> every Keyman user is exposed in every app, regardless of layout

  Because the block is delivered with KMC_WATCHDOG_FAKEFREEZE (a debug-only
  command), this is a mechanism demonstration, not yet a field repro. The field
  equivalent is whatever else stalls that thread for ~1s on a slow machine.

  Gotcha honoured: keybd_event with dwExtraInfo = 0 is deliberate - Keyman only
  filters on dwExtraInfo != 0, so 0 makes synthesized keys look like real input.
#>
[CmdletBinding()]
param(
  [ValidateSet('LShift','RShift','LCtrl','RCtrl','LAlt','RAlt')][string]$Modifier = 'LShift',
  [int]$Iterations   = 10,
  [int]$HoldMs       = 1400,   # how long the modifier is held before the block
  [int]$ReleaseDelay = 100,    # ms between posting the block and releasing
  [int]$SettleMs     = 400,    # wait after release before reading key state
  [int]$DrainMs      = 6000,   # let the 5s fakefreeze finish before next iteration
  [switch]$NoFreeze,           # CONTROL: never post cmd 20
  [string]$TargetProcess = '', # if set, bring this process to the foreground first,
                               # so the layout under test is that app's layout
  [switch]$TypeAfter,          # after releasing, tap one key so Keyman actually
                               # PROCESSES a keystroke. keybd_shift_reset() only runs
                               # on a processed key, so with no typing the phantom
                               # re-injection path is never entered at all.
  [string]$LogDir    = "$env:TEMP\kmrepro"
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

Add-Type -Namespace Ks -Name Native -MemberDefinition @'
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern uint RegisterWindowMessage(string lpString);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern short GetKeyState(int vKey);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint tid);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
'@

$FLAG_KEYUP = 0x0002
$FLAG_EXT   = 0x0001
$KMC_FAKEFREEZE = 20

$MODS = @{
  LShift = @{ Vk = 0xA0; Ext = $false }
  RShift = @{ Vk = 0xA1; Ext = $true  }
  LCtrl  = @{ Vk = 0xA2; Ext = $false }
  RCtrl  = @{ Vk = 0xA3; Ext = $true  }
  LAlt   = @{ Vk = 0xA4; Ext = $false }
  RAlt   = @{ Vk = 0xA5; Ext = $true  }
}
$ALL_MODS = @(
  @{ Vk = 0xA0; Ext = $false; Label = 'LShift' }
  @{ Vk = 0xA1; Ext = $true;  Label = 'RShift' }
  @{ Vk = 0xA2; Ext = $false; Label = 'LCtrl'  }
  @{ Vk = 0xA3; Ext = $true;  Label = 'RCtrl'  }
  @{ Vk = 0xA4; Ext = $false; Label = 'LAlt'   }
  @{ Vk = 0xA5; Ext = $true;  Label = 'RAlt'   }
)

function Get-KeymanVersionString {
  foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\Keyman\Keyman Desktop',
                     'HKLM:\SOFTWARE\Keyman\Keyman Desktop')) {
    $ver = (Get-ItemProperty -Path $key -Name version -ErrorAction SilentlyContinue).version
    if ($ver) { return $ver }
  }
  return 'unknown'
}

$log = Join-Path $LogDir ('stick-{0}.txt' -f $Modifier)
function Report([string]$text) {
  $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $text
  Write-Host $line
  Add-Content -Path $log -Value $line -Encoding utf8
}

function Send-Down([int]$vk, [bool]$ext) {
  $flags = 0
  if ($ext) { $flags = $FLAG_EXT }
  [Ks.Native]::keybd_event([byte]$vk, [byte][Ks.Native]::MapVirtualKey($vk, 0), $flags, [UIntPtr]::Zero)
}
function Send-Up([int]$vk, [bool]$ext) {
  $flags = $FLAG_KEYUP
  if ($ext) { $flags = $flags -bor $FLAG_EXT }
  [Ks.Native]::keybd_event([byte]$vk, [byte][Ks.Native]::MapVirtualKey($vk, 0), $flags, [UIntPtr]::Zero)
}

function Get-ModsHeld {
  $held = @()
  foreach ($item in $ALL_MODS) {
    if (([Ks.Native]::GetAsyncKeyState($item.Vk) -band 0x8000) -ne 0) { $held += $item.Label }
  }
  if ($held.Count -eq 0) { return 'none' }
  return ($held -join ',')
}

function Clear-AllModifiers {
  foreach ($item in $ALL_MODS) { Send-Up $item.Vk $item.Ext; Start-Sleep -Milliseconds 60 }
  Start-Sleep -Milliseconds 250
}

function Get-KeymanController {
  $proc = Get-Process -Name keyman -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) { return [IntPtr]::Zero }
  $script:foundHwnd = [IntPtr]::Zero
  $script:keymanPid = $proc.Id
  $callback = [Ks.Native+EnumWindowsProc] {
    param($hwnd, $lparam)
    $wpid = 0
    [void][Ks.Native]::GetWindowThreadProcessId($hwnd, [ref]$wpid)
    if ($wpid -eq $script:keymanPid) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][Ks.Native]::GetClassName($hwnd, $sb, 256)
      if ($sb.ToString() -eq 'TApplication') { $script:foundHwnd = $hwnd; return $false }
    }
    return $true
  }
  [void][Ks.Native]::EnumWindows($callback, [IntPtr]::Zero)
  return $script:foundHwnd
}

function Get-ForegroundLayout {
  $hwnd = [Ks.Native]::GetForegroundWindow()
  $wpid = 0
  $tid  = [Ks.Native]::GetWindowThreadProcessId($hwnd, [ref]$wpid)
  $hkl  = [Ks.Native]::GetKeyboardLayout($tid)
  $lang = $hkl.ToInt64() -band 0xFFFF
  $name = 'other'
  if ($lang -eq 0x2000) { $name = 'KEYMAN' } elseif ($lang -eq 0x0409) { $name = 'US-MS' }
  $procName = 'unknown'
  try { $procName = (Get-Process -Id $wpid -ErrorAction SilentlyContinue).ProcessName } catch {}
  return [pscustomobject]@{ Hkl = $hkl; LangId = $lang; Name = $name; Proc = $procName }
}

$mod    = $MODS[$Modifier]
$hwndKm = Get-KeymanController
$msg    = [Ks.Native]::RegisterWindowMessage('WM_KEYMAN_CONTROL')

if ($TargetProcess) {
  $tproc = Get-Process -Name $TargetProcess -ErrorAction SilentlyContinue |
           Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($tproc) {
    [void][Ks.Native]::SetForegroundWindow($tproc.MainWindowHandle)
    Start-Sleep -Milliseconds 600
  }
}
$layout = Get-ForegroundLayout

Report '================ kmstick ================'
Report ("when          : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Report ("keyman version: {0}" -f (Get-KeymanVersionString))
Report ("keyman.exe    : {0}" -f $(if ($hwndKm -eq [IntPtr]::Zero) { 'NOT RUNNING' } else { 'hwnd=0x{0:X}' -f $hwndKm.ToInt64() }))
Report ("foreground    : {0}  HKL=0x{1:X} langid=0x{2:X4} -> {3}" -f $layout.Proc, $layout.Hkl.ToInt64(), $layout.LangId, $layout.Name)
Report ("modifier      : {0} (vk=0x{1:X2} extended={2})" -f $Modifier, $mod.Vk, $mod.Ext)
Report ("hold={0}ms  releaseDelay={1}ms  settle={2}ms  iterations={3}" -f $HoldMs, $ReleaseDelay, $SettleMs, $Iterations)
Report ("freeze posted : {0}" -f (-not $NoFreeze))
if ($NoFreeze) { Report '[INFO] CONTROL RUN - keyman.exe is never blocked.' }
if ($hwndKm -eq [IntPtr]::Zero -and -not $NoFreeze) {
  Report '[FAIL] keyman.exe is not running, so it cannot be blocked. Use -NoFreeze for a control.'
  exit 1
}
Report 'NOTE: this test types nothing - it only reads GetAsyncKeyState.'
Report ''

$stuck = 0
for ($i = 1; $i -le $Iterations; $i++) {
  # start from a known-clean modifier state
  if ((Get-ModsHeld) -ne 'none') { Clear-AllModifiers }
  $pre = Get-ModsHeld
  if ($pre -ne 'none') {
    Report ("  iter {0,3} : SKIPPED - could not clear modifiers first (held: {1})" -f $i, $pre)
    continue
  }

  Send-Down $mod.Vk $mod.Ext
  Start-Sleep -Milliseconds $HoldMs

  if (-not $NoFreeze) {
    [void][Ks.Native]::PostMessage($hwndKm, $msg, [IntPtr]$KMC_FAKEFREEZE, [IntPtr]::Zero)
  }

  Start-Sleep -Milliseconds $ReleaseDelay
  Send-Up $mod.Vk $mod.Ext
  Start-Sleep -Milliseconds $SettleMs

  if ($TypeAfter) {
    # One 'a'. Enough to make Keyman process a key, which is what enters
    # PrepareInjectedInput() -> keybd_shift_reset().
    Send-Down 0x41 $false
    Start-Sleep -Milliseconds 60
    Send-Up 0x41 $false
    Start-Sleep -Milliseconds 300
  }

  $asyncHeld = (([Ks.Native]::GetAsyncKeyState($mod.Vk) -band 0x8000) -ne 0)
  $syncHeld  = (([Ks.Native]::GetKeyState($mod.Vk) -band 0x8000) -ne 0)

  if ($asyncHeld -or $syncHeld) {
    $stuck++
    Report ("  iter {0,3} : STUCK  GetAsyncKeyState={1} GetKeyState={2}  all held: {3}" -f $i, $asyncHeld, $syncHeld, (Get-ModsHeld))
    Clear-AllModifiers
    $after = Get-ModsHeld
    Report ("             after explicit KEYUP sweep: {0}" -f $after)
  } else {
    Report ("  iter {0,3} : clean" -f $i)
  }

  if (-not $NoFreeze) { Start-Sleep -Milliseconds $DrainMs }
}

Clear-AllModifiers
Report ''
Report '--- RESULT ---'
Report ("  modifier        : {0}" -f $Modifier)
Report ("  iterations      : {0}" -f $Iterations)
Report ("  STUCK           : {0}" -f $stuck)
Report ("  layout under test: {0} (langid 0x{1:X4})" -f $layout.Name, $layout.LangId)
Report ("  final mods held : {0}" -f (Get-ModsHeld))
Report '========================================='
Report ("[OK] report -> {0}" -f $log)
