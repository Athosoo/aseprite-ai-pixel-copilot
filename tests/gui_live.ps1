# tests/gui_live.ps1 -- drive the REAL Aseprite with REAL OS input (no --script, so timers and
# the normal event loop are live). Used to reproduce "panel receives no input".
param(
  [string]$Action = "open",   # open | click | keys | shot
  [int]$X = 0, [int]$Y = 0,
  [string]$Text = "",
  [string]$Out = "tests\lua\live.png",
  [int]$Wait = 3500
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
function Get-Ase { Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1 }

if ($Action -eq 'open') {
  Get-Process aseprite -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 800
  Start-Process -FilePath 'D:\PraticleTool\Aseprite\aseprite.exe'
  Start-Sleep -Seconds 5
  $p = Get-Ase
  if (-not $p) { throw 'aseprite did not start' }
  [W]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
  Start-Sleep -Milliseconds 600
  [System.Windows.Forms.SendKeys]::SendWait('^+a')
  Start-Sleep -Milliseconds $Wait
  Write-Output 'sent Ctrl+Shift+A'
}
elseif ($Action -eq 'click') {
  $p = Get-Ase
  if (-not $p) { throw 'aseprite not running' }
  [W]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
  Start-Sleep -Milliseconds 400
  [W]::SetCursorPos($X, $Y) | Out-Null
  Start-Sleep -Milliseconds 200
  [W]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # left down
  Start-Sleep -Milliseconds 80
  [W]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # left up
  Start-Sleep -Milliseconds 900
  Write-Output ("clicked at " + $X + "," + $Y)
}
elseif ($Action -eq 'keys') {
  $p = Get-Ase
  [W]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
  Start-Sleep -Milliseconds 400
  [System.Windows.Forms.SendKeys]::SendWait($Text)
  Start-Sleep -Milliseconds 900
  Write-Output ("sent keys: " + $Text)
}

Start-Sleep -Milliseconds 500
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out (Join-Path (Split-Path $PSScriptRoot -Parent) $Out)
