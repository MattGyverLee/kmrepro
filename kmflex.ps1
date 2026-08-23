<#
  kmflex.ps1 - FieldWorks driver for the Keyman repro rig.

  FLEx auto-switches the active keyboard per writing system, so clicking between
  an Ngq field (Cameroon Keyman keyboard) and an Eng field (US Microsoft layout)
  is a clean, machine-observable keyboard-switch test vector.

  FLEx RootSite views expose NO UI Automation text, so verification is by
  screenshot. Every command that types also captures before/after PNGs.

  Commands:
    Undo    -Times <n>              Ctrl+Z in FLEx
    Where                           report foreground HKL (which keyboard is live)
    Click   -RelX <n> -RelY <n>     click a field, report resulting HKL
    Type    -Text <s>               type literal chars through the live keyboard
    Probe   -RelX -RelY [-Mode]     click a field, run the Keyman probe, screenshot
    Shot    [-Out <png>] [-Full]    capture

  Probe modes:
    deadkey  ';' 'e'            -> U+0259 SCHWA
    ralt     RAlt(ext) + 'N'    -> U+014B ENG
    both     deadkey then ralt
#>
[CmdletBinding()]
param(
  [Parameter(Position=0)][ValidateSet('Undo','Where','Click','Type','Probe','Shot','Read','Clear','Tab','Switch')][string]$Command = 'Where',
  [int]$RelX = 1000, [int]$RelY = 325,
  [int]$Times = 1,
  [string]$Text = '',
  [ValidateSet('deadkey','ralt','both')][string]$Mode = 'both',
  [int]$AltHoldMs = 250,          # how long RAlt is held before/after the letter
  [string]$Out,
  [switch]$Full,
  [switch]$Back,
  [ValidateSet('Clean','Freeze','Ghost')][string]$Scenario = 'Clean',
  [int]$Iterations = 5,
  [int]$Tabs = 7,
  [int]$EngX = 1000, [int]$EngY = 490,   # Note (Eng) field on the test entry
  [string]$Proc = 'FieldWorks',
  [string]$LogDir = "$env:TEMP\kmrepro"
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Namespace Fx -Name N -MemberDefinition @'
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern void keybd_event(byte v, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint t);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int v);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern uint RegisterWindowMessage(string s);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
'@
[void][Fx.N]::SetProcessDPIAware()

$FLAG_KEYUP = 0x0002
$FLAG_EXT   = 0x0001

function Get-Win { (Get-Process -Name $Proc -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1).MainWindowHandle }
function Focus-Win { $h = Get-Win; [void][Fx.N]::SetForegroundWindow($h); Start-Sleep -Milliseconds 400; return $h }

function KD([byte]$v, [switch]$Extended) { $f = 0;          if ($Extended) { $f = $f -bor $FLAG_EXT }; [Fx.N]::keybd_event($v, [byte][Fx.N]::MapVirtualKey($v,0), $f, [UIntPtr]::Zero) }
function KU([byte]$v, [switch]$Extended) { $f = $FLAG_KEYUP; if ($Extended) { $f = $f -bor $FLAG_EXT }; [Fx.N]::keybd_event($v, [byte][Fx.N]::MapVirtualKey($v,0), $f, [UIntPtr]::Zero) }
function Tap([byte]$v, [int]$Gap = 70, [switch]$Extended) { KD $v -Extended:$Extended; Start-Sleep -Milliseconds $Gap; KU $v -Extended:$Extended; Start-Sleep -Milliseconds $Gap }


function Get-KeymanVer {
  foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Keyman\Keyman Desktop','HKLM:\SOFTWARE\Keyman\Keyman Desktop')) {
    $v = (Get-ItemProperty -Path $k -Name 'version' -EA SilentlyContinue).version
    if ($v) { return $v }
  }
  return 'unknown'
}

function Get-KeymanController {
  $p = Get-Process -Name keyman -EA SilentlyContinue | Select-Object -First 1
  if (-not $p) { return [IntPtr]::Zero }
  $script:kf = [IntPtr]::Zero; $script:kp = $p.Id
  $cb = [Fx.N+EnumWindowsProc]{
    param($h,$l)
    $o = 0; [void][Fx.N]::GetWindowThreadProcessId($h, [ref]$o)
    if ($o -eq $script:kp) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][Fx.N]::GetClassName($h,$sb,256)
      if ($sb.ToString() -eq 'TApplication') { $script:kf = $h; return $false }
    }
    return $true
  }
  [void][Fx.N]::EnumWindows($cb,[IntPtr]::Zero)
  return $script:kf
}

function Format-Codepoints2([string]$x) { if ([string]::IsNullOrEmpty($x)) { '<empty>' } else { (($x.ToCharArray()|%{ 'U+{0:X4}' -f [int]$_ }) -join ' ') } }

function Get-Hkl {
  $p = 0
  $t = [Fx.N]::GetWindowThreadProcessId([Fx.N]::GetForegroundWindow(), [ref]$p)
  $h = [Fx.N]::GetKeyboardLayout($t)
  $l = $h.ToInt64() -band 0xFFFF
  $tag = if ($l -eq 0x2000) { 'KEYMAN' } elseif ($l -eq 0x409) { 'US-MS' } else { "other" }
  [pscustomobject]@{ Hkl = ('0x{0:X8}' -f $h.ToInt64()); LangId = ('0x{0:X4}' -f $l); Keyboard = $tag }
}

function Get-ModsDown {
  $m = [ordered]@{ LShift=0xA0; RShift=0xA1; LCtrl=0xA2; RCtrl=0xA3; LAlt=0xA4; RAlt=0xA5 }
  $d = @($m.GetEnumerator() | Where-Object { ([Fx.N]::GetAsyncKeyState($_.Value) -band 0x8000) -ne 0 } | ForEach-Object { $_.Key })
  if ($d.Count -eq 0) { 'none' } else { $d -join ',' }
}

function Capture([string]$path, [switch]$FullScreen) {
  $h = Get-Win
  [void][Fx.N]::SetForegroundWindow($h); Start-Sleep -Milliseconds 400
  $r = New-Object Fx.N+RECT
  [void][Fx.N]::GetWindowRect($h, [ref]$r)
  if ($FullScreen -or ($r.R - $r.L) -le 0) {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $r.L = $b.Left; $r.T = $b.Top; $r.R = $b.Right; $r.B = $b.Bottom
  }
  $w = $r.R - $r.L; $ht = $r.B - $r.T
  $bmp = New-Object System.Drawing.Bitmap $w, $ht
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $ht))
  $g.Dispose(); $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  return $path
}

function Click-Rel([int]$x, [int]$y) {
  $h = Focus-Win
  $r = New-Object Fx.N+RECT
  [void][Fx.N]::GetWindowRect($h, [ref]$r)
  [void][Fx.N]::SetCursorPos(($r.L + $x), ($r.T + $y))
  Start-Sleep -Milliseconds 150
  [Fx.N]::mouse_event(0x0002, 0,0,0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [Fx.N]::mouse_event(0x0004, 0,0,0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 600
}

# IMPORTANT: do NOT use Home/End/Ctrl+A to select inside a FLEx data-entry view.
# RootSite treats them as record-wide navigation, so the caret leaves the field
# (observable as the writing-system combo flipping to English). Select only the
# characters we ourselves typed, with Shift+Left, and never navigate.

# Navigation keys (arrows, Home, End, Insert, Delete, PgUp/PgDn) are EXTENDED
# keys. Sent without KEYEVENTF_EXTENDEDKEY their scan codes are the NUMPAD
# equivalents (Left 0x4B = numpad 4, Right 0x4D = numpad 6, Home 0x47 = numpad 7
# ...), so they insert characters instead of moving the caret. Always -Extended.
function Nav([byte]$vk, [int]$Gap = 60) { Tap $vk $Gap -Extended }

function Select-Back([int]$n) {
  if ($n -le 0) { return }
  KD 0xA0; Start-Sleep -Milliseconds 80                            # Shift down
  for ($i = 0; $i -lt $n; $i++) { Nav 0x25 45 }                    # Left (extended)
  KU 0xA0; Start-Sleep -Milliseconds 200                           # Shift up
}

# Tab / Shift+Tab move between FLEx fields reliably, unlike absolute-coordinate
# clicking (rows shift as fields gain content). Tab is NOT an extended key.
function Nav-Tab([int]$n = 1, [switch]$Back) {
  if ($Back) { KD 0xA0; Start-Sleep -Milliseconds 80 }              # Shift down
  for ($i = 0; $i -lt $n; $i++) { Tap 0x09 260; Start-Sleep -Milliseconds 200 }   # Tab (FLEx needs settle time)
  if ($Back) { KU 0xA0; Start-Sleep -Milliseconds 80 }              # Shift up
  Start-Sleep -Milliseconds 350
}

# Read back the last $n typed chars AND remove them, in one atomic move.
#
# Do NOT collapse the selection with Right first: at the end of a FLEx field the
# Right arrow navigates to the NEXT FIELD, so every read silently advanced the
# caret one field and a later Tab count then overshot out of the entry entirely.
# Instead we leave the Shift+Left selection active and let a single Backspace
# delete it, which returns the caret exactly where it started.
function Read-AndClear([int]$n) {
  try { Set-Clipboard -Value ([string]::Empty) -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Milliseconds 150
  Select-Back $n
  KD 0x11; Start-Sleep -Milliseconds 80                            # Ctrl down
  KD 0x43; Start-Sleep -Milliseconds 80; KU 0x43                   # C
  KU 0x11; Start-Sleep -Milliseconds 500                           # Ctrl up
  $t = ''
  try { $t = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch {}
  if ($null -eq $t) { $t = '' }
  Tap 0x08 90                                                      # Backspace deletes the selection
  Start-Sleep -Milliseconds 250
  return ($t -replace "`r", '' -replace "`n", '')
}

function Get-TypedText([int]$n) {
  # Clear the clipboard first so a stale value can never look like success.
  try { Set-Clipboard -Value ([string]::Empty) -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Milliseconds 150
  Select-Back $n
  KD 0x11; Start-Sleep -Milliseconds 80                            # Ctrl down
  KD 0x43; Start-Sleep -Milliseconds 80; KU 0x43                   # C
  KU 0x11; Start-Sleep -Milliseconds 500                           # Ctrl up
  $t = ''
  try { $t = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch {}
  if ($null -eq $t) { $t = '' }
  Nav 0x27; Start-Sleep -Milliseconds 150                           # Right (collapse selection to end)
  return ($t -replace "`r", '' -replace "`n", '')
}

function Clear-Typed([int]$n) {
  for ($i = 0; $i -lt $n; $i++) { Tap 0x08 70 }                     # Backspace (NOT extended)
  Start-Sleep -Milliseconds 250
}

function Format-Codepoints([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return '<empty>' }
  (($s.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ')
}

switch ($Command) {

'Where' { Get-Hkl | Format-List; "modifiers down: $(Get-ModsDown)" }

'Switch' {
  # Keyboard-switch regression test (the #15055 vector), verified BEHAVIOURALLY.
  #
  # GetKeyboardLayout() does NOT reliably track TSF profile switches - after
  # Tab-ing into an Eng field it still reported the Keyman HKL while the FLEx
  # writing-system combo had already flipped to English. So we do not trust it:
  # we type and read back what actually came out.
  #
  #   Ngq (Citation Form)  ';e' -> U+0259   RAlt+N -> U+014B
  #   Eng (Note)           ';e' -> ';e' literally
  #
  # Everything typed is backspaced off again, so the record is left unchanged.
  $SCHWA = [string][char]0x0259
  $ENG   = [string][char]0x014B
  $log = Join-Path $LogDir ("flexswitch-{0}-{1}.txt" -f ((Get-KeymanVer) -replace '[^0-9]','_'), $Scenario)
  function Rep($s) { $line = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $s; Write-Host $line; Add-Content -Path $log -Value $line -Encoding utf8 }

  Rep "=========== FLEx keyboard-switch test ==========="
  Rep "keyman version : $(Get-KeymanVer)"
  Rep "scenario       : $Scenario   iterations: $Iterations   tabs: $Tabs"

  $msg    = [Fx.N]::RegisterWindowMessage('WM_KEYMAN_CONTROL')
  $hwndKm = Get-KeymanController
  $target = Get-Win

  $fail = 0; $ran = 0
  for ($i = 1; $i -le $Iterations; $i++) {
    # --- anchor on the Ngq Citation Form ---
    Click-Rel $RelX $RelY

    switch ($Scenario) {
      'Freeze' { [void][Fx.N]::PostMessage($hwndKm, $msg, [IntPtr]20, [IntPtr]::Zero); Start-Sleep -Milliseconds 150 }
      'Ghost'  { Start-Sleep -Milliseconds 1700
                 [void][Fx.N]::PostMessage($target, 0x0100, [IntPtr]0x7C, [IntPtr]0x00410001); Start-Sleep -Milliseconds 150 }
      default  { Start-Sleep -Milliseconds 150 }
    }

    $bad = @()

    # --- 1. Keyman deadkey in the Ngq field ---
    Tap 0xBA 90; Tap 0x45 90; Start-Sleep -Milliseconds 400
    $a = Read-AndClear 1
    if ($a -ne $SCHWA) { $bad += "ngq-deadkey-before(got '$a' $(Format-Codepoints $a))" }

    # --- 2. Keyman RAlt rule in the Ngq field ---
    KD 0xA5 -Extended; Start-Sleep -Milliseconds $AltHoldMs
    Tap 0x4E 90
    Start-Sleep -Milliseconds $AltHoldMs; KU 0xA5 -Extended; Start-Sleep -Milliseconds 500
    $b = Read-AndClear 1
    if ($b -ne $ENG) { $bad += "ngq-ralt-before(got '$b' $(Format-Codepoints $b))" }

    # --- 3. switch AWAY to the Eng field, type there ---
    # Tab is NOT usable here: tabbing past an entry's last field advances to the
    # NEXT RECORD, and the minimal test entry has few fields, so a fixed tab
    # count walked straight out of the entry. Absolute clicks cannot drift.
    Click-Rel $EngX $EngY
    Tap 0xBA 90; Tap 0x45 90; Start-Sleep -Milliseconds 400
    $c = Read-AndClear 2
    if ($c -ne ';e') { $bad += "eng-literal(got '$c' $(Format-Codepoints $c))" }

    # --- 4. switch BACK to Ngq, re-run both Keyman rules ---
    Click-Rel $RelX $RelY
    Tap 0xBA 90; Tap 0x45 90; Start-Sleep -Milliseconds 400
    $d = Read-AndClear 1
    if ($d -ne $SCHWA) { $bad += "ngq-deadkey-AFTER-SWITCH(got '$d' $(Format-Codepoints $d))" }

    KD 0xA5 -Extended; Start-Sleep -Milliseconds $AltHoldMs
    Tap 0x4E 90
    Start-Sleep -Milliseconds $AltHoldMs; KU 0xA5 -Extended; Start-Sleep -Milliseconds 500
    $e = Read-AndClear 1
    if ($e -ne $ENG) { $bad += "ngq-ralt-AFTER-SWITCH(got '$e' $(Format-Codepoints $e))" }

    $mods = Get-ModsDown
    if ($mods -ne 'none') { $bad += "PHANTOM:$mods" }

    $ran++
    if ($bad.Count -gt 0) { $fail++; Rep ("  iter {0,3} : FAIL {1}" -f $i, ($bad -join ' | ')) }
    else                  { Rep ("  iter {0,3} : ok  (schwa/eng before and after switch, Eng field literal)" -f $i) }
  }

  Rep ""
  Rep "--- RESULT ---"
  Rep "  iterations : $ran"
  Rep "  failures   : $fail"
  Rep "  mods down  : $(Get-ModsDown)"
  Rep "================================================"
  Write-Host ""
  Write-Host "[OK] report -> $log"
}

'Tab' {
  if ($RelX -ne 0 -or $RelY -ne 0) {
    Click-Rel $RelX $RelY
    "[INFO] anchored by click -> $((Get-Hkl).Keyboard)"
  } else { [void](Focus-Win) }
  Nav-Tab $Times -Back:$Back
  $d = if ($Back) { 'Shift+Tab' } else { 'Tab' }
  "[OK] $d x$Times -> keyboard=$((Get-Hkl).Keyboard) HKL=$((Get-Hkl).Hkl)"
}

'Read'  {
  if ($RelX -ne 0 -or $RelY -ne 0) { Click-Rel $RelX $RelY }
  $t = Get-TypedText $Times
  "[OK] last $Times char(s) = '$t'"
  "[OK] codepoints          = $(Format-Codepoints $t)"
  "[OK] keyboard            = $((Get-Hkl).Keyboard)"
}

'Clear' {
  if ($RelX -ne 0 -or $RelY -ne 0) { Click-Rel $RelX $RelY }
  Clear-Typed $Times
  "[OK] backspaced $Times char(s); keyboard=$((Get-Hkl).Keyboard)"
}

'Shot'  { if (-not $Out) { $Out = Join-Path $LogDir 'flex.png' }; "[OK] $(Capture $Out -FullScreen:$Full)" }

'Undo'  {
  [void](Focus-Win)
  for ($i = 1; $i -le $Times; $i++) {
    KD 0x11; Start-Sleep -Milliseconds 70      # Ctrl down
    Tap 0x5A 70                                 # Z
    KU 0x11; Start-Sleep -Milliseconds 700      # Ctrl up
    "[OK] Ctrl+Z #$i"
  }
  Start-Sleep -Milliseconds 800
  "[OK] $(Capture (Join-Path $LogDir 'flex-undo.png') -FullScreen)"
}

'Click' {
  Click-Rel $RelX $RelY
  $k = Get-Hkl
  "[OK] clicked rel($RelX,$RelY) -> keyboard=$($k.Keyboard) HKL=$($k.Hkl) langid=$($k.LangId)"
}

'Type'  {
  [void](Focus-Win)
  foreach ($ch in $Text.ToCharArray()) { Tap ([byte][char]([string]$ch).ToUpper()) 70 }
  Start-Sleep -Milliseconds 500
  "[OK] typed '$Text'; keyboard=$((Get-Hkl).Keyboard); mods=$(Get-ModsDown)"
}

'Probe' {
  if ($RelX -ne 0 -or $RelY -ne 0) {
    Click-Rel $RelX $RelY
  }
  $k = Get-Hkl
  "[INFO] field keyboard = $($k.Keyboard)  HKL=$($k.Hkl)"
  if ($k.Keyboard -ne 'KEYMAN') { "[WARN] this field is NOT on the Keyman keyboard - the probe will not produce schwa/eng" }
  $before = Capture (Join-Path $LogDir 'flex-probe-before.png') -FullScreen

  if ($Mode -eq 'deadkey' -or $Mode -eq 'both') {
    Tap 0xBA 90       # ';'  VK_OEM_1
    Tap 0x45 90       # 'e'          -> schwa
    Start-Sleep -Milliseconds 600
    "[OK] sent ';e'  mods=$(Get-ModsDown)"
    [void](Capture (Join-Path $LogDir 'flex-probe-deadkey.png') -FullScreen)
  }

  if ($Mode -eq 'ralt' -or $Mode -eq 'both') {
    # RAlt MUST carry KEYEVENTF_EXTENDEDKEY: Keyman splits left/right Alt on
    # that bit alone (serialkeyeventserver.cpp UpdateLocalModifierState).
    KD 0xA5 -Extended
    Start-Sleep -Milliseconds $AltHoldMs
    "[INFO] RAlt held; mods=$(Get-ModsDown)"
    Tap 0x4E 90       # 'N'          -> eng
    Start-Sleep -Milliseconds $AltHoldMs
    KU 0xA5 -Extended
    Start-Sleep -Milliseconds 700
    "[OK] sent RAlt+N  mods=$(Get-ModsDown)"
  }

  Start-Sleep -Milliseconds 500
  $after = Capture (Join-Path $LogDir 'flex-probe-after.png') -FullScreen
  "[OK] before=$before"
  "[OK] after =$after"
  "[INFO] final mods down: $(Get-ModsDown)"
}

}
