# click the Security dialog: tick "don't show again" then Allow
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class SEC {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { throw 'aseprite not running' }
$h = $p.MainWindowHandle
if ([SEC]::GetForegroundWindow() -ne $h) {
  $fg = [SEC]::GetForegroundWindow(); $fgPid = 0
  $ft = [SEC]::GetWindowThreadProcessId($fg, [ref]$fgPid)
  $mt = [SEC]::GetCurrentThreadId()
  [SEC]::AttachThreadInput($mt, $ft, $true) | Out-Null
  [SEC]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Milliseconds 250
  [SEC]::AttachThreadInput($mt, $ft, $false) | Out-Null
}
$r = New-Object SEC+RECT
[SEC]::GetWindowRect($h, [ref]$r) | Out-Null
Write-Output ("rect " + $r.L + "," + $r.T)
function Click($x, $y) {
  [SEC]::SetCursorPos(($r.L + $x), ($r.T + $y)) | Out-Null
  Start-Sleep -Milliseconds 180
  [SEC]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [SEC]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}
Click 630 634     # "Don't show this specific alert again" checkbox
Click 728 703     # Allow to Open Connections
Write-Output 'clicked checkbox + allow'
