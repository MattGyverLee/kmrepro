<#
  kmaltgr.ps1 - low-level keyboard logger, built to answer TODO I1.

  THE QUESTION
  ------------
  On an AltGr layout, Windows synthesizes a Ctrl keydown alongside Right Alt.
  Standard behaviour is a LEFT, NON-extended Ctrl, which would seed the LCTRL
  slot in Cache A. But `aiTIP.cpp:467` special-cases exactly
  `TF_MOD_RALT|TF_MOD_LCONTROL`, so Keyman evidently knows the pairing is quirky.

  Why it matters, and why it is now urgent rather than academic: as of
  2026-08-24 we have MEASURED that both Ctrl slots latch, deterministically,
  7/7 per side (`MODIFIERS.md` s2b). The Cameroon keyboards use AltGr on EVERY
  accented character. So if any driver in this path emits that synthetic Ctrl
  with the extended bit set, the seed for a stuck Right Ctrl is not exotic - it
  is every accented keystroke the user types, and the severity of the whole bug
  goes up sharply.

  This script records, for every key event that reaches a WH_KEYBOARD_LL hook:

      vkCode  scanCode  flags & LLKHF_EXTENDED  LLKHF_INJECTED  dwExtraInfo

  and then answers three things directly.

  WHAT IT REPORTS
  ---------------
  1. ALTGR PAIRING. Every Ctrl event that arrives within 50 ms before a Right
     Alt keydown, with its side and its extended bit. This is I1.

  2. KEYMAN'S OWN INJECTIONS. Keyman stamps its synthesized events with
     scanCode `SCAN_FLAG_KEYMAN_KEY_EVENT` = 0xFF (`keyman64.h:132`). Every such
     event is called out. This lets you watch `keybd_shift_reset` re-press a
     modifier in real time, and it settles the open question from
     `MODIFIERS.md` s2b about what the 0xFF scan code actually resolves to -
     `do_keybd_event` collapses `VK_RCONTROL` to a bare `VK_CONTROL` plus
     `KEYEVENTF_EXTENDEDKEY` and passes 0xFF as the scan code, which is not a
     real scan code and leaves Windows nothing to resolve the side from.

  3. ANY EXTENDED CTRL AT ALL, from whatever source, with its origin flags.

  MODES
    -Watch N        passive. Log everything for N seconds, then analyse.
                    Use this with -Manual for the authoritative reading.
    -Manual         prompt for physical keypresses rather than injecting.
                    THIS IS THE ONE THAT ANSWERS I1 PROPERLY - see below.
    -Arms           switch US -> MSKLC -> Keyman and inject RAlt on each.
                    Cheap and automatic, but see the caveat.

  DOES INJECTION TRIGGER THE ALTGR SYNTHESIS? YES - MEASURED
  ----------------------------------------------------------
  The AltGr-to-Ctrl synthesis is performed by the keyboard LAYOUT (a KBDTABLES
  with the KLLF_ALTGR flag), not by the application, so it was not obvious that
  it would fire for a `keybd_event` Right Alt at all. It does: measured
  2026-08-25 on the MSKLC arm, an injected RAlt keydown was preceded 1.4 ms
  earlier by `LCTRL scan=0x21D INJ|ALTDOWN`, non-extended.

  So -Arms is meaningful and not merely a baseline. -Manual is still the
  authoritative reading for I1, because only a physical AltGr exercises the real
  keyboard driver and any vendor Fn-layer remapping sitting in front of it -
  which is precisely the population MODIFIERS.md s3d item 2 is worried about.

  SAFETY
  ------
  This script installs a global low-level keyboard hook and LOGS EVERY KEYSTROKE
  ON THE MACHINE while it runs, including into other applications. Do not run it
  while typing passwords. It writes the log to $LogDir. The hook is removed in
  the finally block.

  The callback deliberately does no I/O and no formatting beyond one preallocated
  string append - it runs inside the same LowLevelHooksTimeout budget (default
  300 ms, `HKCU\Control Panel\Desktop\LowLevelHooksTimeout`) that this whole
  investigation is about. A slow callback would get the hook silently removed by
  Windows, which is the failure this repo already suspects in the field. Both the
  hook and the message pump are therefore in C#, not PowerShell.

  USAGE
    .\kmaltgr.ps1 -Manual                 # the real I1 answer. Press AltGr when asked.
    .\kmaltgr.ps1 -Watch 30               # passive: log whatever happens for 30s
    .\kmaltgr.ps1 -Arms                   # injected RAlt on US / MSKLC / Keyman
#>
[CmdletBinding()]
param(
  [int]$Watch = 0,
  [switch]$Manual,
  [switch]$Arms,
  [int]$SwitchTries = 12,
  [string]$LogDir = "$env:TEMP\kmrepro"
)
$ErrorActionPreference = 'Stop'
if (-not $Watch -and -not $Manual -and -not $Arms) { $Manual = $true }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log   = Join-Path $LogDir "altgr-$stamp.txt"
$csv   = Join-Path $LogDir "altgr-$stamp.csv"

function Say([string]$t) {
  $l = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $t
  [Console]::Out.WriteLine($l)
  Add-Content -Path $log -Value $l -Encoding utf8
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[StructLayout(LayoutKind.Sequential)]
public struct KBDLLHOOKSTRUCT {
  public uint vkCode;
  public uint scanCode;
  public uint flags;
  public uint time;
  public UIntPtr dwExtraInfo;
}

[StructLayout(LayoutKind.Sequential)]
public struct KaMsg {
  public IntPtr hwnd; public uint message; public IntPtr wParam, lParam;
  public uint time; public int ptX, ptY;
}

[StructLayout(LayoutKind.Sequential)]
public struct KaRect { public int Left, Top, Right, Bottom; }

[StructLayout(LayoutKind.Sequential)]
public struct KaGuiThreadInfo {
  public int cbSize; public int flags;
  public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
  public KaRect rcCaret;
}

public class KaRec {
  public double T;        // ms since hook start
  public bool   Up;
  public uint   Vk, Scan, Flags;
  public ulong  Extra;
  public string Phase;
}

public static class Ka {
  public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool UnhookWindowsHookEx(IntPtr hhk);
  [DllImport("user32.dll")]
  public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
  [DllImport("kernel32.dll", CharSet=CharSet.Auto)]
  public static extern IntPtr GetModuleHandle(string name);
  [DllImport("user32.dll")]
  public static extern bool PeekMessage(out KaMsg m, IntPtr h, uint a, uint b, uint r);
  [DllImport("user32.dll")]
  public static extern bool TranslateMessage(ref KaMsg m);
  [DllImport("user32.dll")]
  public static extern IntPtr DispatchMessage(ref KaMsg m);

  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint idThread, ref KaGuiThreadInfo gti);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint tid);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);

  const int WH_KEYBOARD_LL = 13;

  static IntPtr hHook = IntPtr.Zero;
  static HookProc keepAlive;          // MUST outlive the hook or the GC eats it
  static Stopwatch sw;
  public static List<KaRec> Events = new List<KaRec>();
  public static string Phase = "init";
  public static bool Installed { get { return hHook != IntPtr.Zero; } }

  // Deliberately minimal. No I/O, no string formatting, no managed allocation
  // beyond one small object. This runs inside LowLevelHooksTimeout.
  static IntPtr Cb(int nCode, IntPtr w, IntPtr l) {
    if (nCode >= 0) {
      KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(KBDLLHOOKSTRUCT));
      uint m = (uint)w.ToInt64();
      KaRec r = new KaRec();
      r.T     = sw.Elapsed.TotalMilliseconds;
      r.Up    = (m == 0x101 || m == 0x105);   // WM_KEYUP / WM_SYSKEYUP
      r.Vk    = k.vkCode;
      r.Scan  = k.scanCode;
      r.Flags = k.flags;
      r.Extra = k.dwExtraInfo.ToUInt64();
      r.Phase = Phase;
      Events.Add(r);
    }
    return CallNextHookEx(hHook, nCode, w, l);
  }

  public static bool Start() {
    sw = Stopwatch.StartNew();
    keepAlive = new HookProc(Cb);
    hHook = SetWindowsHookEx(WH_KEYBOARD_LL, keepAlive, GetModuleHandle(null), 0);
    return hHook != IntPtr.Zero;
  }
  public static void Stop() {
    if (hHook != IntPtr.Zero) { UnhookWindowsHookEx(hHook); hHook = IntPtr.Zero; }
  }
  // A WH_KEYBOARD_LL hook only fires while its installing thread pumps messages.
  public static void Pump(int ms) {
    KaMsg msg;
    Stopwatch t = Stopwatch.StartNew();
    while (t.ElapsedMilliseconds < ms) {
      while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) {
        TranslateMessage(ref msg);
        DispatchMessage(ref msg);
      }
      Thread.Sleep(4);
    }
  }
}
'@

# ---- flag decoding ---------------------------------------------------------
$LLKHF_EXTENDED           = 0x01
$LLKHF_LOWER_IL_INJECTED  = 0x02
$LLKHF_INJECTED           = 0x10
$LLKHF_ALTDOWN            = 0x20

function Decode-Flags([uint32]$f) {
  $p = @()
  if ($f -band $LLKHF_EXTENDED)          { $p += 'EXT' }
  if ($f -band $LLKHF_INJECTED)          { $p += 'INJ' }
  if ($f -band $LLKHF_LOWER_IL_INJECTED) { $p += 'INJ_LOWIL' }
  if ($f -band $LLKHF_ALTDOWN)           { $p += 'ALTDOWN' }
  if ($p.Count -eq 0) { return '-' }
  return ($p -join '|')
}
$VKNAME = @{
  0x10='SHIFT';   0x11='CONTROL'; 0x12='MENU'
  0xA0='LSHIFT';  0xA1='RSHIFT'
  0xA2='LCTRL';   0xA3='RCTRL'
  0xA4='LALT';    0xA5='RALT'
  0x14='CAPS';    0x90='NUMLOCK'; 0x91='SCROLL'
  0x5B='LWIN';    0x5C='RWIN';    0x5D='APPS'
  0x1B='ESC';     0x20='SPACE';   0x0D='ENTER';  0x08='BACK'
  0xBA='OEM_1(;)'
}
# Two magic values worth naming, both confirmed against the source 2026-08-25.
#
#   scanCode 0x21D  Windows' marker on the LEFT Ctrl it synthesizes alongside a
#                   Right Alt on a KLLF_ALTGR layout. Not a real scan code; it is
#                   0x1D with a flag bit set so the fake can be recognised. Seeing
#                   it is positive proof the AltGr synthesis fired.
#
#   dwExtraInfo     EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT (keyman64.h:134).
#     0x4B4D0000    "KM" in ASCII. Stamped by serialkeyeventserver.cpp:488/495/526
#                   when the serializer REPLAYS a user key event. This is the
#                   machinery at the centre of the whole investigation, and it is
#                   also what k32_lowlevelkeyboardhook.cpp:227 filters its own
#                   events on. Distinct from scanCode 0xFF
#                   (SCAN_FLAG_KEYMAN_KEY_EVENT), which marks keys Keyman
#                   SYNTHESIZES rather than replays - keybd_shift_reset's phantom
#                   modifier presses carry 0xFF, not this.
$SCAN_ALTGR_FAKE_CTRL = 0x21D
$EXTRA_KM_SERIALIZED  = 0x4B4D0000

function Extra-Name([uint64]$e) {
  if ($e -eq 0) { return '' }
  if ($e -eq $EXTRA_KM_SERIALIZED) { return 'KM-SERIALIZED' }
  return ('0x{0:X}' -f $e)
}

function Vk-Name([uint32]$v) {
  if ($VKNAME.ContainsKey([int]$v)) { return $VKNAME[[int]$v] }
  if ($v -ge 0x41 -and $v -le 0x5A) { return ([char]$v).ToString() }
  if ($v -ge 0x30 -and $v -le 0x39) { return ([char]$v).ToString() }
  return ('vk0x{0:X2}' -f $v)
}
$CTRL_VKS = @(0x11,0xA2,0xA3)
$RALT_VKS = @(0xA5)

# ---- focus-thread HKL (the only trustworthy reading) -----------------------
function Get-FocusHkl {
  $g = New-Object KaGuiThreadInfo
  $g.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($g)
  if (-not [Ka]::GetGUIThreadInfo(0, [ref]$g)) { return $null }
  $h = $g.hwndFocus; if ($h -eq [IntPtr]::Zero) { $h = $g.hwndActive }
  if ($h -eq [IntPtr]::Zero) { return $null }
  $p = 0
  $tid = [Ka]::GetWindowThreadProcessId($h, [ref]$p)
  # Mask off the sign extension. The `L` suffix is NOT optional: PowerShell parses
  # the literal 0xFFFFFFFF as Int32 -1, so `-band 0xFFFFFFFF` is an identity op and
  # silently does nothing. Only shows up on layouts whose HKL is negative - the US
  # arm (0x04090409) printed correctly for weeks while MSKLC printed 16 hex digits.
  $hkl = ([Ka]::GetKeyboardLayout($tid).ToInt64()) -band 0xFFFFFFFFL
  $lang = $hkl -band 0xFFFF; $high = ($hkl -shr 16) -band 0xFFFF
  $arm = 'unknown-0x{0:X4}' -f $lang
  if ($lang -eq 0x0409 -and $high -eq 0x0409) { $arm = 'US' }
  elseif ($lang -eq 0x0436)                   { $arm = 'MSKLC' }
  elseif ($lang -eq 0x2000)                   { $arm = 'Keyman' }
  return [pscustomobject]@{ Hkl=$hkl; LangId=$lang; Arm=$arm; Tid=$tid }
}

function Kd([int]$v, [switch]$E) { $f=0;  if($E){$f=$f -bor 1}; [Ka]::keybd_event([byte]$v,[byte][Ka]::MapVirtualKey($v,0),$f,[UIntPtr]::Zero) }
function Ku([int]$v, [switch]$E) { $f=2;  if($E){$f=$f -bor 1}; [Ka]::keybd_event([byte]$v,[byte][Ka]::MapVirtualKey($v,0),$f,[UIntPtr]::Zero) }

try {
  Say '================= kmaltgr: low-level keyboard logger (TODO I1) ================='
  Say  '[PRIVACY] a global keyboard hook is now active. EVERY keystroke on this machine'
  Say  '          is being logged while this runs. Do not type passwords.'
  Say ("log = {0}" -f $log)
  Say ''

  if (-not [Ka]::Start()) {
    Say '[FAIL] SetWindowsHookEx(WH_KEYBOARD_LL) failed. Nothing can be measured.'
    exit 1
  }
  Say 'hook installed.'
  $k = Get-FocusHkl
  if ($k) { Say ("focus keyboard: {0} (HKL=0x{1:X8} langid=0x{2:X4})" -f $k.Arm,$k.Hkl,$k.LangId) }
  Say ''

  # ---- ARMS: injected RAlt on each keyboard -------------------------------
  if ($Arms) {
    Say '---- injected RAlt across the three arms ----'
    Say  '    Caveat in the header: the AltGr->Ctrl synthesis is a LAYOUT behaviour and may'
    Say  '    not fire for injected input. A null here does not answer I1.'
    foreach ($want in @('US','MSKLC','Keyman')) {
      # Win+Space until the focus thread reports the arm we want.
      for ($i=1; $i -le $SwitchTries; $i++) {
        $k = Get-FocusHkl
        if ($k -and $k.Arm -eq $want) { break }
        [Ka]::Phase = "switch->$want"
        Kd 0x5B -E; Start-Sleep -Milliseconds 140
        Kd 0x20; Start-Sleep -Milliseconds 40; Ku 0x20; Start-Sleep -Milliseconds 140
        Ku 0x5B -E; Start-Sleep -Milliseconds 450
        [Ka]::Pump(200)
      }
      $k = Get-FocusHkl
      if (-not $k -or $k.Arm -ne $want) { Say ("  [SKIP] could not reach {0}" -f $want); continue }
      Say ("  arm {0} confirmed (HKL=0x{1:X8})" -f $want,$k.Hkl)

      [Ka]::Phase = "inject-RAlt-$want"
      Start-Sleep -Milliseconds 250; [Ka]::Pump(250)
      Kd 0xA5 -E; Start-Sleep -Milliseconds 120; [Ka]::Pump(150)
      Ku 0xA5 -E; Start-Sleep -Milliseconds 120; [Ka]::Pump(300)
      [Ka]::Phase = 'idle'
      Start-Sleep -Milliseconds 200; [Ka]::Pump(200)
    }
    Say ''
  }

  # ---- MANUAL: physical keypresses ----------------------------------------
  if ($Manual) {
    $k = Get-FocusHkl
    Say '---- MANUAL PHASE - this is the one that answers I1 ----'
    Say ("    current focus keyboard: {0}" -f $(if($k){$k.Arm}else{'<unknown>'}))
    Say  '    Put focus in Notepad with the Keyman Cameroon keyboard active, then:'
    Say  ''
    Say  '      1. press and release the PHYSICAL AltGr key (right-hand Alt), a few times'
    Say  '      2. type an accented character the normal way, e.g.  ; e   then  AltGr+N'
    Say  '      3. if this keyboard HAS a physical Right Ctrl, tap it once for comparison'
    Say  ''
    Say  '    Recording for 30 seconds. Everything you type is logged.'
    [Ka]::Phase = 'manual'
    for ($sec = 30; $sec -gt 0; $sec -= 5) {
      [Ka]::Pump(5000)
      $n = [Ka]::Events.Count
      Say ("    {0,2}s left  ({1} events captured)" -f $sec,$n)
    }
    [Ka]::Phase = 'idle'
    [Ka]::Pump(300)
    Say ''
  }

  # ---- WATCH: passive ------------------------------------------------------
  if ($Watch -gt 0) {
    Say ("---- passive watch, {0}s ----" -f $Watch)
    [Ka]::Phase = 'watch'
    for ($sec = $Watch; $sec -gt 0; $sec -= 5) {
      $chunk = [math]::Min(5, $sec)
      [Ka]::Pump($chunk * 1000)
      Say ("    {0,3}s left  ({1} events)" -f $sec,[Ka]::Events.Count)
    }
    [Ka]::Phase = 'idle'
    [Ka]::Pump(300)
    Say ''
  }

  # ---- dump ----------------------------------------------------------------
  $ev = @([Ka]::Events)
  Say ("captured {0} key events" -f $ev.Count)
  Say ''
  if ($ev.Count -eq 0) {
    Say '[NOTHING CAPTURED] no key events reached the hook. Either nothing was pressed, or'
    Say '                   the hook was removed by Windows. Re-run and press some keys.'
    return
  }

  Say 'EVENT LOG'
  Say ('  {0,9}  {1,-4} {2,-10} {3,-7} {4,-20} {5,-15} {6}' -f 'ms','dir','vk','scan','flags','extra','phase')
  foreach ($r in $ev) {
    $sc = '0x{0:X2}' -f $r.Scan
    if ($r.Scan -eq $SCAN_ALTGR_FAKE_CTRL) { $sc = '0x21D*' }
    elseif ($r.Scan -eq 0xFF)              { $sc = '0xFF*' }
    Say ('  {0,9:F1}  {1,-4} {2,-10} {3,-7} {4,-20} {5,-15} {6}' -f `
          $r.T, $(if($r.Up){'UP'}else{'DN'}), (Vk-Name $r.Vk), $sc, (Decode-Flags $r.Flags), (Extra-Name $r.Extra), $r.Phase)
  }
  Say  '    * 0x21D = Windows'' synthetic AltGr Ctrl;  0xFF = SCAN_FLAG_KEYMAN_KEY_EVENT'
  Say  '      KM-SERIALIZED = EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT, the serializer replaying a real key'
  Say ''

  $rows = foreach ($r in $ev) {
    [pscustomobject]@{
      Ms=[math]::Round($r.T,1); Dir=$(if($r.Up){'UP'}else{'DN'}); Vk=('0x{0:X2}' -f $r.Vk)
      VkName=(Vk-Name $r.Vk); Scan=('0x{0:X2}' -f $r.Scan); Flags=('0x{0:X2}' -f $r.Flags)
      Decoded=(Decode-Flags $r.Flags); Extended=[bool]($r.Flags -band $LLKHF_EXTENDED)
      Injected=[bool]($r.Flags -band $LLKHF_INJECTED); Extra=('0x{0:X}' -f $r.Extra); Phase=$r.Phase
    }
  }
  $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

  # ---- ANALYSIS 1: the I1 question ----------------------------------------
  Say '=================== ANALYSIS 1: AltGr / Ctrl pairing (I1) ==================='
  $raltDowns = @($ev | Where-Object { (-not $_.Up) -and ($_.Vk -in $RALT_VKS) })
  if ($raltDowns.Count -eq 0) {
    Say '  No Right Alt keydown was seen at all, so I1 cannot be answered from this run.'
    Say '  Re-run with -Manual and press the PHYSICAL AltGr key.'
  } else {
    Say ("  {0} Right Alt keydown(s) seen." -f $raltDowns.Count)
    $found = 0
    foreach ($ra in $raltDowns) {
      # A synthesized AltGr Ctrl arrives immediately BEFORE the RAlt down.
      $partners = @($ev | Where-Object {
        (-not $_.Up) -and ($_.Vk -in $CTRL_VKS) -and ($_.T -le $ra.T) -and (($ra.T - $_.T) -le 50)
      })
      if ($partners.Count -eq 0) {
        Say ('  RAlt DN at {0,9:F1} ms [{1}] - NO Ctrl within the preceding 50 ms' -f $ra.T,$ra.Phase)
      } else {
        foreach ($c in $partners) {
          $found++
          $ext = [bool]($c.Flags -band $LLKHF_EXTENDED)
          Say ('  RAlt DN at {0,9:F1} ms [{1}] <- Ctrl {2} scan=0x{3:X2} {4} EXTENDED={5} ({6:F1} ms before)' -f `
                $ra.T,$ra.Phase,(Vk-Name $c.Vk),$c.Scan,(Decode-Flags $c.Flags),$ext,($ra.T - $c.T))
        }
      }
    }
    Say ''
    if ($found -eq 0) {
      Say  '  [NO PAIRING OBSERVED] no Ctrl accompanied any Right Alt keydown in this run.'
      Say  '  If these were INJECTED RAlt events, that is expected-ish and answers nothing:'
      Say  '  the AltGr->Ctrl synthesis is a layout behaviour and may not fire for'
      Say  '  synthesized input. Re-run with -Manual and a real finger on AltGr before'
      Say  '  concluding anything about I1.'
    } else {
      $extPartners = @()
      foreach ($ra in $raltDowns) {
        $extPartners += @($ev | Where-Object {
          (-not $_.Up) -and ($_.Vk -in $CTRL_VKS) -and ($_.T -le $ra.T) -and (($ra.T - $_.T) -le 50) -and
          (($_.Flags -band $LLKHF_EXTENDED) -ne 0)
        })
      }
      $fake = @($ev | Where-Object { $_.Scan -eq $SCAN_ALTGR_FAKE_CTRL })
      if ($fake.Count -gt 0) {
        Say ('  {0} of the Ctrl events carried scanCode 0x21D, which is Windows'' own marker for' -f $fake.Count)
        Say  '  the synthetic AltGr Ctrl. That is positive confirmation the synthesis fired,'
        Say  '  rather than an unrelated Ctrl happening to land nearby.'
        Say ''
      }
      if ($extPartners.Count -gt 0) {
        Say ('  [I1 ANSWERED - YES, AND THIS IS BAD] {0} of the AltGr-paired Ctrl events carried' -f $extPartners.Count)
        Say  '  the EXTENDED bit, i.e. Windows resolves them to RIGHT Ctrl.'
        Say  '  Combined with the 2026-08-24 result that RCTRL latches 7/7, the seed for a stuck'
        Say  '  Right Ctrl is then EVERY ACCENTED KEYSTROKE on the Cameroon keyboards, not an'
        Say  '  exotic event. Raise the severity in MODIFIERS.md s3d and TRIGGER.md.'
      } else {
        Say  '  [I1 ANSWERED - NO, on this machine] every AltGr-paired Ctrl was NON-extended,'
        Say  '  i.e. LEFT Ctrl, which is the standard Windows behaviour. On this hardware the'
        Say  '  AltGr path seeds LCTRL, not RCTRL.'
        Say  '  That does NOT clear the field hardware: I1 asks about affected machines, and'
        Say  '  a vendor Fn-layer driver remapping Right Ctrl is exactly the population at'
        Say  '  risk (MODIFIERS.md s3d item 2). Record this as a negative on THIS machine.'
        Say  '  Note also: an LCTRL seed is still a stuck Ctrl. It latches 7/7 too. It is just'
        Say  '  clearable by the user, because every keyboard has a physical Left Ctrl.'
      }
    }
  }
  Say ''

  # ---- ANALYSIS 2: Keyman's own injections --------------------------------
  Say '============ ANALYSIS 2: Keyman-injected events (scan 0xFF) ============'
  $kmEv = @($ev | Where-Object { $_.Scan -eq 0xFF })
  if ($kmEv.Count -eq 0) {
    Say '  None seen. Keyman emits scanCode 0xFF (SCAN_FLAG_KEYMAN_KEY_EVENT, keyman64.h:132)'
    Say '  on everything it synthesizes, so either Keyman injected nothing or its keyboard'
    Say '  was not active. Type through a Keyman keyboard while this runs to capture them.'
  } else {
    Say ("  {0} event(s) carry Keyman's 0xFF scan code:" -f $kmEv.Count)
    foreach ($r in $kmEv) {
      Say ('    {0,9:F1} ms  {1,-4} {2,-10} scan=0x{3:X2} {4,-20} extra=0x{5:X} [{6}]' -f `
            $r.T,$(if($r.Up){'UP'}else{'DN'}),(Vk-Name $r.Vk),$r.Scan,(Decode-Flags $r.Flags),$r.Extra,$r.Phase)
    }
    Say ''
    # This settles the open s2b question about what 0xFF resolves to.
    $kmCtrl = @($kmEv | Where-Object { $_.Vk -in $CTRL_VKS })
    if ($kmCtrl.Count -gt 0) {
      Say  '  Keyman emitted Ctrl with its 0xFF scan code. do_keybd_event collapses both'
      Say  '  VK_LCONTROL and VK_RCONTROL to a bare VK_CONTROL and distinguishes the side ONLY'
      Say  '  by KEYEVENTF_EXTENDEDKEY, while passing 0xFF - not a real scan code - so the'
      Say  '  EXTENDED column above is the whole of what Windows has to go on:'
      foreach ($r in $kmCtrl) {
        Say ('    {0,-10} EXTENDED={1}' -f (Vk-Name $r.Vk),[bool]($r.Flags -band $LLKHF_EXTENDED))
      }
    }
    $unmatched = @()
    foreach ($d in @($kmEv | Where-Object { -not $_.Up })) {
      $u = @($kmEv | Where-Object { $_.Up -and $_.Vk -eq $d.Vk -and $_.T -gt $d.T })
      if ($u.Count -eq 0) { $unmatched += $d }
    }
    if ($unmatched.Count -gt 0) {
      Say ''
      Say ('  [UNMATCHED KEYDOWN] {0} Keyman-injected KEYDOWN(s) with no later KEYUP:' -f $unmatched.Count)
      foreach ($r in $unmatched) { Say ('    {0,9:F1} ms  {1}' -f $r.T,(Vk-Name $r.Vk)) }
      Say  '  That is keybd_shift_reset re-pressing a cached modifier, caught in the act'
      Say  '  (keybd_shift.cpp:161-176). This is the bug, observed at the wire level.'
    }
  }
  Say ''

  # ---- ANALYSIS 2b: the serializer replaying real keys --------------------
  $ser = @($ev | Where-Object { $_.Extra -eq $EXTRA_KM_SERIALIZED })
  if ($ser.Count -gt 0) {
    Say ('  {0} event(s) carry EXTRAINFO_FLAG_SERIALIZED_USER_KEY_EVENT (0x4B4D0000):' -f $ser.Count)
    foreach ($r in $ser) {
      Say ('    {0,9:F1} ms  {1,-4} {2,-10} scan=0x{3:X2} {4}' -f `
            $r.T,$(if($r.Up){'UP'}else{'DN'}),(Vk-Name $r.Vk),$r.Scan,(Decode-Flags $r.Flags))
    }
    Say  '  That is serialkeyeventserver.cpp REPLAYING a real user keystroke - the serializer'
    Say  '  swallowing the original and re-emitting it. Note these carry the ORIGINAL scan'
    Say  '  code, not 0xFF: replayed user keys and Keyman-synthesized keys are different'
    Say  '  paths with different markers, and only the latter is keybd_shift_reset.'
    Say ''
  }

  # ---- ANALYSIS 3: any extended Ctrl at all -------------------------------
  Say '============ ANALYSIS 3: every extended Ctrl seen, any source ============'
  $extCtrl = @($ev | Where-Object { ($_.Vk -in $CTRL_VKS) -and (($_.Flags -band $LLKHF_EXTENDED) -ne 0) })
  if ($extCtrl.Count -eq 0) {
    Say '  None. No E0-prefixed Ctrl reached the hook from any source during this run.'
  } else {
    Say ("  {0} extended Ctrl event(s):" -f $extCtrl.Count)
    foreach ($r in $extCtrl) {
      $src = 'physical-or-driver'
      if ($r.Scan -eq 0xFF)                        { $src = 'KEYMAN (scan 0xFF)' }
      elseif ($r.Flags -band $LLKHF_INJECTED)      { $src = 'injected (this harness or another app)' }
      Say ('    {0,9:F1} ms  {1,-4} {2,-10} scan=0x{3:X2} {4,-20} {5}' -f `
            $r.T,$(if($r.Up){'UP'}else{'DN'}),(Vk-Name $r.Vk),$r.Scan,(Decode-Flags $r.Flags),$src)
    }
    $physExt = @($extCtrl | Where-Object { ($_.Scan -ne 0xFF) -and (($_.Flags -band $LLKHF_INJECTED) -eq 0) })
    if ($physExt.Count -gt 0) {
      Say ''
      Say ('  {0} of them were NOT injected and NOT Keyman - i.e. a real E0 1D from hardware' -f $physExt.Count)
      Say  '  or a driver. That is the seed class MODIFIERS.md s3d item 2 is about.'
    }
  }
  Say ''
  Say ("  csv : {0}" -f $csv)
  Say ("  log : {0}" -f $log)
  Say '==============================================================================='
}
finally {
  [Ka]::Stop()
  Say 'hook removed.'
}
