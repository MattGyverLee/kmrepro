<#
  kmshot.ps1 - screen capture + positional click helper for the Keyman repro rig.
  Used where UI Automation cannot read the target (FieldWorks RootSite views).

  Commands:
    Capture  -Process <name> [-Out <png>] [-Full]
    Click    -X <n> -Y <n>                    (absolute screen coords)
    ClickIn  -Process <name> -RelX <n> -RelY <n>   (coords relative to window)
    Rect     -Process <name>
#>
[CmdletBinding()]
param(
  [Parameter(Position=0)][ValidateSet('Capture','Click','ClickIn','Rect')][string]$Command = 'Capture',
  [string]$Process = 'FieldWorks',
  [string]$Out,
  [int]$X = 0, [int]$Y = 0,
  [int]$RelX = 0, [int]$RelY = 0,
  [switch]$Full,
  [string]$LogDir = "$env:TEMP\kmrepro"
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -Namespace Sh -Name N -MemberDefinition @'
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
'@
[void][Sh.N]::SetProcessDPIAware()

function Get-Win([string]$n) {
  $p = Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { throw "process '$n' has no window" }
  return $p.MainWindowHandle
}

switch ($Command) {

'Rect' {
  $h = Get-Win $Process; $r = New-Object Sh.N+RECT
  [void][Sh.N]::GetWindowRect($h, [ref]$r)
  "{0}: hwnd=0x{1:X}  L={2} T={3} R={4} B={5}  W={6} H={7}" -f $Process, $h.ToInt64(), $r.L, $r.T, $r.R, $r.B, ($r.R-$r.L), ($r.B-$r.T)
}

'Capture' {
  $h = Get-Win $Process
  if ([Sh.N]::IsIconic($h)) { [void][Sh.N]::ShowWindow($h, 9) ; Start-Sleep -Milliseconds 500 }  # SW_RESTORE
  [void][Sh.N]::SetForegroundWindow($h)
  Start-Sleep -Milliseconds 500
  $r = New-Object Sh.N+RECT
  [void][Sh.N]::GetWindowRect($h, [ref]$r)
  if ($Full) {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $r.L = $b.Left; $r.T = $b.Top; $r.R = $b.Right; $r.B = $b.Bottom
  }
  $w = $r.R - $r.L; $ht = $r.B - $r.T
  if ($w -le 0 -or $ht -le 0) { throw "bad window rect" }
  if (-not $Out) { $Out = Join-Path $LogDir ("shot-{0}.png" -f $Process) }
  $bmp = New-Object System.Drawing.Bitmap $w, $ht
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $ht))
  $g.Dispose()
  $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  "[OK] captured {0} ({1}x{2}) origin=({3},{4}) -> {5}" -f $Process, $w, $ht, $r.L, $r.T, $Out
}

'Click' {
  [void][Sh.N]::SetCursorPos($X, $Y)
  Start-Sleep -Milliseconds 150
  [Sh.N]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # LEFTDOWN
  Start-Sleep -Milliseconds 60
  [Sh.N]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # LEFTUP
  Start-Sleep -Milliseconds 300
  "[OK] clicked screen ($X,$Y)"
}

'ClickIn' {
  $h = Get-Win $Process
  [void][Sh.N]::SetForegroundWindow($h)
  Start-Sleep -Milliseconds 350
  $r = New-Object Sh.N+RECT
  [void][Sh.N]::GetWindowRect($h, [ref]$r)
  $ax = $r.L + $RelX; $ay = $r.T + $RelY
  [void][Sh.N]::SetCursorPos($ax, $ay)
  Start-Sleep -Milliseconds 150
  [Sh.N]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [Sh.N]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 400
  "[OK] clicked {0} rel=({1},{2}) abs=({3},{4})" -f $Process, $RelX, $RelY, $ax, $ay
}

}
