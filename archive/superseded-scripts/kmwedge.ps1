<#
  kmwedge.ps1 - targeted attempt to wedge Keyman's cached modifier state.

  WHY THIS EXISTS
  ---------------
  kmrepro.ps1's Ghost scenario does trigger the LowLevelHookWatchDog breach
  (>1s keyboard idle, then a PostMessage'd WM_KEYDOWN that the LL hook never
  sees, so LastGetMessageEventTick - LastLowLevelEventTick >= 1000). But it
  fires that reinstall while NO modifier is held, so the hook swap is harmless
  and 20 iterations came back clean on 18.0.249.

  The documented failure needs the swap to land BETWEEN a modifier's KEYDOWN
  and its KEYUP:
    - m_ModifierKeyboardState[] (serialkeyeventserver.cpp) is fed ONLY by
      WM_KEYMAN_MODIFIER_EVENT posted from the LL hook proc.
    - If the hook is torn out and reinstalled across that window, the KEYUP is
      seen by no Keyman LL hook at all, so no event is posted and the byte
      stays 0x80 forever.
    - PrepareInjectedInput() -> keybd_shift_reset() then injects a phantom
      modifier KEYDOWN with no matching KEYUP on every subsequent keystroke.

  So: hold a modifier, go idle past the 1000ms threshold, post the ghost key to
  force the reinstall, and release the modifier INTO that reinstall window.
  The exact race offset is unknown, so sweep it rather than guess.

  Gotchas honoured (HANDOFF.md section 9):
   - RAlt is 0xA5 and MUST be sent EXTENDED; UpdateLocalModifierState()
     distinguishes L/R Alt purely by the extended flag.
   - Delete is likewise an EXTENDED key.
   - keybd_event with dwExtraInfo = 0 is deliberate: Keyman only filters on
     dwExtraInfo != 0, so 0 makes synthesized keys look like real user input.
   - No single-letter or alias-shadowing helper names (Cp would resolve to
     Copy-Item; aliases outrank functions).

  Ctrl+A is used to clear the target. That is safe in Notepad and MUST NOT be
  used against FieldWorks (RootSite treats it as record-wide navigation).
#>
[CmdletBinding()]
param(
  [string]$TargetProcess = 'notepad',
  [ValidateSet('RAlt','LShift','LCtrl','RShift')][string]$Modifier = 'RAlt',
  [int]$Reps        = 2,        # repetitions per delay offset
  [int]$IdleMs      = 1400,     # modifier-held idle before ghost key (> 1000ms threshold)
  [int]$MinDelayMs  = 0,        # release-offset sweep, low bound
  [int]$MaxDelayMs  = 400,      # release-offset sweep, high bound
  [int]$StepMs      = 50,
  [switch]$AlsoFreeze,          # additionally post cmd 20 to stall the hook owner
  [switch]$NoGhost,             # CONTROL: hold/release the modifier but never post the
                                # ghost key, so the watchdog is never provoked. Any
                                # failure here is a harness artifact, not Keyman.
  [switch]$DismissMenu,         # after releasing the modifier, tap Escape twice to
                                # close any menu the bare Alt press activated
  [switch]$SkipEngagementGate,  # do not require U+0259/U+014B. Needed to run the SAME
                                # recipe on a NON-Keyman layout (the discriminator for
                                # whether Keyman is required at all). The per-run
                                # learned-baseline comparison and the GetAsyncKeyState
                                # phantom check both still work on any layout.
  [int]$LoadThreads = 0,        # emulate a slow machine: N background CPU hogs
  [string]$LogDir   = "$env:TEMP\kmrepro"
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type -Namespace Kw -Name Native -MemberDefinition @'
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern uint RegisterWindowMessage(string lpString);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
                                                 uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
'@

$FLAG_KEYUP     = 0x0002
$FLAG_EXT       = 0x0001
$WM_KEYDOWN     = 0x0100
$KMC_FAKEFREEZE = 20

$MODS = @{
  LShift = @{ Vk = 0xA0; Ext = $false }
  RShift = @{ Vk = 0xA1; Ext = $true  }
  LCtrl  = @{ Vk = 0xA2; Ext = $false }
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

$kmVersion = Get-KeymanVersionString
$log = Join-Path $LogDir ("wedge-{0}-{1}.txt" -f ($kmVersion -replace '[^0-9]', '_'), $Modifier)
function Report([string]$text) {
  $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $text
  Write-Host $line
  Add-Content -Path $log -Value $line -Encoding utf8
}

function Send-Down([int]$vk, [bool]$ext) {
  $flags = 0
  if ($ext) { $flags = $FLAG_EXT }
  [Kw.Native]::keybd_event([byte]$vk, [byte][Kw.Native]::MapVirtualKey($vk, 0), $flags, [UIntPtr]::Zero)
}
function Send-Up([int]$vk, [bool]$ext) {
  $flags = $FLAG_KEYUP
  if ($ext) { $flags = $flags -bor $FLAG_EXT }
  [Kw.Native]::keybd_event([byte]$vk, [byte][Kw.Native]::MapVirtualKey($vk, 0), $flags, [UIntPtr]::Zero)
}
function Send-Tap([int]$vk, [int]$gap = 60, [bool]$ext = $false) {
  Send-Down $vk $ext
  Start-Sleep -Milliseconds 40
  Send-Up $vk $ext
  Start-Sleep -Milliseconds $gap
}

function Get-ModsHeld {
  $held = @()
  foreach ($item in $ALL_MODS) {
    if (([Kw.Native]::GetAsyncKeyState($item.Vk) -band 0x8000) -ne 0) { $held += $item.Label }
  }
  if ($held.Count -eq 0) { return 'none' }
  return ($held -join ',')
}

function Get-TargetWindow {
  $proc = Get-Process -Name $TargetProcess -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $proc) { return [IntPtr]::Zero }
  return $proc.MainWindowHandle
}

function Get-KeymanController {
  $proc = Get-Process -Name keyman -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) { return [IntPtr]::Zero }
  $script:foundHwnd = [IntPtr]::Zero
  $script:keymanPid = $proc.Id
  $callback = [Kw.Native+EnumWindowsProc] {
    param($hwnd, $lparam)
    $wpid = 0
    [void][Kw.Native]::GetWindowThreadProcessId($hwnd, [ref]$wpid)
    if ($wpid -eq $script:keymanPid) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][Kw.Native]::GetClassName($hwnd, $sb, 256)
      if ($sb.ToString() -eq 'TApplication') { $script:foundHwnd = $hwnd; return $false }
    }
    return $true
  }
  [void][Kw.Native]::EnumWindows($callback, [IntPtr]::Zero)
  return $script:foundHwnd
}

function Get-UiaValue([IntPtr]$hwnd) {
  try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Document)
    $doc = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $doc) { return $null }
    return $doc.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
  } catch { return $null }
}

function Format-Codepoints([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return '<empty>' }
  return (($text.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ')
}

function Clear-Target {
  Send-Down 0x11 $false
  Start-Sleep -Milliseconds 60
  Send-Tap 0x41 20 $false          # Ctrl+A - safe in Notepad, NEVER in FLEx
  Send-Up 0x11 $false
  Start-Sleep -Milliseconds 100
  Send-Tap 0x2E 20 $true           # Delete is an EXTENDED key
  Start-Sleep -Milliseconds 200
}

$SCHWA = [string][char]0x0259
$ENG   = [string][char]0x014B

function Invoke-Probes {
  Send-Tap 0xBA 60 $false          # ';'  VK_OEM_1
  Send-Tap 0x45 60 $false          # 'e'          -> schwa
  Send-Down 0xA5 $true             # RAlt DOWN, extended
  Start-Sleep -Milliseconds 80
  Send-Tap 0x4E 60 $false          # 'N'          -> eng
  Send-Up 0xA5 $true
  Start-Sleep -Milliseconds 480
}

function Reset-ModifierCache {
  # Candidate field workaround: a PHYSICAL press+release posts
  # WM_KEYMAN_MODIFIER_EVENT for both edges, so tapping each modifier once
  # should resync m_ModifierKeyboardState[] without restarting Keyman.
  foreach ($item in $ALL_MODS) {
    Send-Down $item.Vk $item.Ext
    Start-Sleep -Milliseconds 90
    Send-Up $item.Vk $item.Ext
    Start-Sleep -Milliseconds 90
  }
  Start-Sleep -Milliseconds 400
}

# ------------------------------------------------------------------ setup ----
$target = Get-TargetWindow
if ($target -eq [IntPtr]::Zero) { Report "[FAIL] no visible '$TargetProcess' window"; exit 1 }
[void][Kw.Native]::SetForegroundWindow($target)
Start-Sleep -Milliseconds 400

$hwndKm = Get-KeymanController
$msg    = [Kw.Native]::RegisterWindowMessage('WM_KEYMAN_CONTROL')
$mod    = $MODS[$Modifier]

Report '================ kmwedge ================'
Report ("when          : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Report ("keyman version: {0}" -f $kmVersion)
Report ("target        : {0} hwnd=0x{1:X}" -f $TargetProcess, $target.ToInt64())
Report ("controller    : 0x{0:X}   WM_KEYMAN_CONTROL=0x{1:X}" -f $hwndKm.ToInt64(), $msg)
Report ("held modifier : {0} (vk=0x{1:X2} extended={2})" -f $Modifier, $mod.Vk, $mod.Ext)
Report ("idle held     : {0}ms   sweep: {1}..{2} step {3}   reps: {4}" -f $IdleMs, $MinDelayMs, $MaxDelayMs, $StepMs, $Reps)
Report ("also freeze   : {0}   load threads: {1}" -f $AlsoFreeze, $LoadThreads)
Report ("no-ghost ctrl : {0}   dismiss menu: {1}" -f $NoGhost, $DismissMenu)
if ($NoGhost) {
  Report '[INFO] CONTROL RUN: the ghost key is NOT posted, so the watchdog is never'
  Report '       provoked. Failures here are harness artifacts (e.g. a bare Alt press'
  Report '       activating the menu bar), NOT Keyman defects.'
}

$loadJobs = @()
if ($LoadThreads -gt 0) {
  for ($i = 1; $i -le $LoadThreads; $i++) {
    $loadJobs += Start-Job -ScriptBlock {
      $acc = 0.0
      while ($true) { $acc = [math]::Sqrt([math]::Abs([math]::Sin($acc) * 1000000.0)) }
    }
  }
  Report ("[INFO] started {0} background CPU hogs to emulate a slow machine" -f $LoadThreads)
  Start-Sleep -Seconds 2
}

try {
  if ($null -eq (Get-UiaValue $target)) { Report "[FAIL] cannot read '$TargetProcess' via UI Automation"; exit 1 }

  # Behavioural engagement gate. The HKL is NOT trustworthy (gotcha #3):
  # verified on 18.0.249 that Notepad reports langid 0x0409 while Keyman is live.
  Clear-Target
  Invoke-Probes
  $learned = Get-UiaValue $target
  Report ("learned clean output = '{0}' ({1})" -f $learned, (Format-Codepoints $learned))
  if ($learned -cnotmatch [regex]::Escape($SCHWA) -or $learned -cnotmatch [regex]::Escape($ENG)) {
    Report '[FAIL] Keyman is NOT processing input (need both U+0259 and U+014B).'
    Report ("       Select the Cameroon Keyman keyboard in '{0}' and re-run." -f $TargetProcess)
    exit 1
  }
  Report '[OK]   Keyman confirmed engaged'
  Report ''

  $delays = @()
  for ($d = $MinDelayMs; $d -le $MaxDelayMs; $d += $StepMs) { $delays += $d }
  Report ('--- sweep: {0} offsets x {1} reps = {2} iterations ---' -f $delays.Count, $Reps, ($delays.Count * $Reps))

  $iter = 0; $fail = 0; $phantom = 0; $empty = 0; $recovered = 0
  foreach ($delay in $delays) {
    for ($rep = 1; $rep -le $Reps; $rep++) {
      $iter++
      Clear-Target

      # 1. modifier DOWN, held past the watchdog threshold. Its own KEYDOWN
      #    stamps LastLowLevelEventTick; nothing advances it after that.
      Send-Down $mod.Vk $mod.Ext
      Start-Sleep -Milliseconds $IdleMs

      # 2. optionally stall the hook-owning thread as well
      if ($AlsoFreeze -and $hwndKm -ne [IntPtr]::Zero) {
        [void][Kw.Native]::PostMessage($hwndKm, $msg, [IntPtr]$KMC_FAKEFREEZE, [IntPtr]::Zero)
      }

      # 3. ghost WM_KEYDOWN the LL hook never sees. The target's GetMessage
      #    hook stamps LastGetMessageEventTick -> threshold breach -> hook
      #    reinstall, all while the modifier above is still physically DOWN.
      if (-not $NoGhost) {
        [void][Kw.Native]::PostMessage($target, $WM_KEYDOWN, [IntPtr]0x7C, [IntPtr]0x00410001)
      }

      # 4. release the modifier INTO the reinstall window
      Start-Sleep -Milliseconds $delay
      Send-Up $mod.Vk $mod.Ext
      Start-Sleep -Milliseconds 250

      # A bare Alt press+release activates the Windows menu bar, which then eats
      # subsequent keystrokes and looks exactly like the reported bug. Escape
      # clears it, so the harness can tell menu-mode apart from a wedged Keyman.
      if ($DismissMenu) {
        Send-Tap 0x1B 80 $false
        Send-Tap 0x1B 80 $false
        Start-Sleep -Milliseconds 200
      }

      # 5. did Keyman's cached modifier state survive?
      Clear-Target
      Invoke-Probes
      $got     = Get-UiaValue $target
      $modsNow = Get-ModsHeld

      $bad = @()
      if ([string]::IsNullOrEmpty($got)) { $bad += 'NO-OUTPUT'; $empty++ }
      elseif ($got -cne $learned)        { $bad += 'WRONG-OUTPUT' }   # -cne: -ne is case-INSENSITIVE and U+014A/U+014B are the eng case pair
      if ($modsNow -ne 'none')           { $bad += ('PHYSICAL-PHANTOM:' + $modsNow); $phantom++ }

      if ($bad.Count -gt 0) {
        $fail++
        Report ('  iter {0,3} delay={1,4}ms : FAIL [{2}]' -f $iter, $delay, ($bad -join ' '))
        Report ("             expected='{0}' ({1})" -f $learned, (Format-Codepoints $learned))
        Report ("             got     ='{0}' ({1})" -f $got, (Format-Codepoints $got))
        Report ('             GetAsyncKeyState says: {0}' -f $modsNow)

        # Does the modifier-tap workaround recover it? (handoff open question 3)
        Reset-ModifierCache
        Clear-Target
        Invoke-Probes
        $after = Get-UiaValue $target
        if ($after -eq $learned) {
          $recovered++
          Report '             RECOVERY: modifier-tap workaround RESTORED output'
        } else {
          Report ("             RECOVERY: FAILED, still '{0}' ({1})" -f $after, (Format-Codepoints $after))
        }
      }
      elseif ($iter % 5 -eq 0) {
        Report ('  iter {0,3} delay={1,4}ms : ok' -f $iter, $delay)
      }

      if ($AlsoFreeze) { Start-Sleep -Seconds 6 }   # let the 5s fakefreeze drain
    }
  }

  Report ''
  Report '--- RESULT ---'
  Report ("  held modifier        : {0}" -f $Modifier)
  Report ("  iterations           : {0}" -f $iter)
  Report ("  failures             : {0}" -f $fail)
  Report ("    of which no output : {0}" -f $empty)
  Report ("  phantom modifiers    : {0}" -f $phantom)
  Report ("  recovered by tapping : {0}" -f $recovered)
  Report ("  final mods held      : {0}" -f (Get-ModsHeld))
  Report '========================================='
}
finally {
  foreach ($job in $loadJobs) {
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
  }
  if ($loadJobs.Count -gt 0) { Report '[INFO] stopped background CPU load' }
}
Report ("[OK] report -> {0}" -f $log)
