# tests/_real_click.ps1 -- force foreground properly, then click for real (guard-protected)
param([int]$X, [int]$Y, [string]$Out = "tests\lua\real_click.png")
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class RF {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
}
"@
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { throw 'aseprite not running' }
$h = $p.MainWindowHandle
if ([RF]::GetForegroundWindow() -ne $h) {
  $fg = [RF]::GetForegroundWindow()
  $fgPid = 0
  $fgThread = [RF]::GetWindowThreadProcessId($fg, [ref]$fgPid)
  $myThread = [RF]::GetCurrentThreadId()
  [RF]::AttachThreadInput($myThread, $fgThread, $true) | Out-Null
  [RF]::ShowWindow($h, 9) | Out-Null      # SW_RESTORE
  [RF]::BringWindowToTop($h) | Out-Null
  [RF]::SetForegroundWindow($h) | Out-Null
  Start-Sleep -Milliseconds 300
  [RF]::AttachThreadInput($myThread, $fgThread, $false) | Out-Null
  Start-Sleep -Milliseconds 400
}
$fgNow = [RF]::GetForegroundWindow()
Write-Output ("foreground=" + $fgNow + " aseprite=" + $h + " match=" + ($fgNow -eq $h))
if ($fgNow -ne $h) { Write-Output 'REFUSED: foreground still not aseprite, not clicking'; exit 2 }
[RF]::SetCursorPos($X, $Y) | Out-Null
Start-Sleep -Milliseconds 200
[RF]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 70
[RF]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 900
Write-Output ("clicked " + $X + "," + $Y + " for real")
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out (Join-Path (Split-Path $PSScriptRoot -Parent) $Out)
