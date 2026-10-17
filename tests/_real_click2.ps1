param([int]$ImgX, [int]$ImgY, [string]$Out = "tests\lua\real_click2.png")
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class RF2 {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { throw 'aseprite not running' }
$h = $p.MainWindowHandle
if ([RF2]::GetForegroundWindow() -ne $h) {
  $fg = [RF2]::GetForegroundWindow(); $fgPid = 0
  $fgThread = [RF2]::GetWindowThreadProcessId($fg, [ref]$fgPid)
  $myThread = [RF2]::GetCurrentThreadId()
  [RF2]::AttachThreadInput($myThread, $fgThread, $true) | Out-Null
  [RF2]::BringWindowToTop($h) | Out-Null
  [RF2]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Milliseconds 300
  [RF2]::AttachThreadInput($myThread, $fgThread, $false) | Out-Null
  Start-Sleep -Milliseconds 300
}
if ([RF2]::GetForegroundWindow() -ne $h) { Write-Output 'REFUSED: not foreground'; exit 2 }
$r = New-Object RF2+RECT
[RF2]::GetWindowRect($h, [ref]$r) | Out-Null
Write-Output ("rect " + $r.L + "," + $r.T + " size " + ($r.R-$r.L) + "x" + ($r.B-$r.T))
$sx = $r.L + $ImgX
$sy = $r.T + $ImgY
[RF2]::SetCursorPos($sx, $sy) | Out-Null
Start-Sleep -Milliseconds 250
[RF2]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 80
[RF2]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 900
Write-Output ("clicked screen " + $sx + "," + $sy + "  (image " + $ImgX + "," + $ImgY + ")")
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out (Join-Path (Split-Path $PSScriptRoot -Parent) $Out)
