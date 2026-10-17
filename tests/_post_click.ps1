param([int]$X, [int]$Y, [string]$Out = "tests\lua\post_click.png")
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PM {
  [DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
"@
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { throw 'aseprite not running' }
$h = $p.MainWindowHandle
$lp = [IntPtr](($Y -shl 16) -bor ($X -band 0xFFFF))
[PM]::PostMessage($h, 0x0200, [IntPtr]::Zero, $lp) | Out-Null      # WM_MOUSEMOVE
Start-Sleep -Milliseconds 250
[PM]::PostMessage($h, 0x0201, [IntPtr]1, $lp) | Out-Null            # WM_LBUTTONDOWN
Start-Sleep -Milliseconds 90
[PM]::PostMessage($h, 0x0202, [IntPtr]::Zero, $lp) | Out-Null       # WM_LBUTTONUP
Start-Sleep -Milliseconds 900
Write-Output ("posted click at " + $X + "," + $Y + " to hwnd " + $h)
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out (Join-Path (Split-Path $PSScriptRoot -Parent) $Out)
