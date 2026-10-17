# tests/_open_panel.ps1 -- start Aseprite, then click File > Scripts > AI Pixel Copilot.
# Guard: never click unless the foreground window IS Aseprite (SetForegroundWindow is often
# refused by Windows, and clicking blind lands on whatever is on top).
param([string]$Out = "tests\lua\live_panel.png")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W4 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
function SafeClick($x, $y, $aseHwnd) {
  if ([W4]::GetForegroundWindow() -ne $aseHwnd) { throw ("abort: foreground is not aseprite (" + [W4]::GetForegroundWindow() + " vs " + $aseHwnd + ")") }
  [W4]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 120
  [W4]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [W4]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 420
}
Get-Process aseprite -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
Start-Process -FilePath 'D:\PraticleTool\Aseprite\aseprite.exe'
Start-Sleep -Seconds 5
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { throw 'aseprite did not start' }
$h = $p.MainWindowHandle
[W4]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 700
Write-Output ("foreground=" + [W4]::GetForegroundWindow() + " aseprite=" + $h)
$r = New-Object W4+RECT
[W4]::GetWindowRect($h, [ref]$r) | Out-Null
$dx = $r.L; $dy = $r.T
Write-Output ("rect L=" + $r.L + " T=" + $r.T)
# image coords -> screen coords
SafeClick ([int](37 + $dx)) ([int](35 + $dy)) $h     # File
SafeClick ([int](123 + $dx)) ([int](251 + $dy)) $h   # Scripts
SafeClick ([int](126 + $dx)) ([int](310 + $dy)) $h   # AI Pixel Copilot (AI console)
Start-Sleep -Seconds 3
Write-Output ("foreground after open=" + [W4]::GetForegroundWindow())
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out (Join-Path (Split-Path $PSScriptRoot -Parent) $Out)
