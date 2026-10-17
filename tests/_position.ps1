param([string]$Out = "tests\lua\positioned.png")
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class POS {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { throw 'aseprite not running' }
$h = $p.MainWindowHandle
[POS]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1900, 1150, 0x0040) | Out-Null
Start-Sleep -Milliseconds 600
$fg = [POS]::GetForegroundWindow(); $fgPid = 0
$fgThread = [POS]::GetWindowThreadProcessId($fg, [ref]$fgPid)
$myThread = [POS]::GetCurrentThreadId()
[POS]::AttachThreadInput($myThread, $fgThread, $true) | Out-Null
[POS]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 250
[POS]::AttachThreadInput($myThread, $fgThread, $false) | Out-Null
Start-Sleep -Milliseconds 500
$r = New-Object POS+RECT
[POS]::GetWindowRect($h, [ref]$r) | Out-Null
Write-Output ("rect now " + $r.L + "," + $r.T + " size " + ($r.R-$r.L) + "x" + ($r.B-$r.T) + "  foreground-match=" + ([POS]::GetForegroundWindow() -eq $h))
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out (Join-Path (Split-Path $PSScriptRoot -Parent) $Out)
