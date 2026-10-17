param([string]$Clicks, [string]$Out = "tests\lua\sc")
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class SCN {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
Get-Process aseprite -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
Start-Process -FilePath 'D:\PraticleTool\Aseprite\aseprite.exe' -ArgumentList @('--script','D:\PraticleTool\Aseprite-AI\tests\lua\_open_via_command.lua') | Out-Null
Start-Sleep -Seconds 9
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { throw 'not running' }
$h = $p.MainWindowHandle
[SCN]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1900, 1150, 0x0040) | Out-Null
Start-Sleep -Milliseconds 700

$i = 0
foreach ($pair in $Clicks.Split(';')) {
  if ($pair.Trim() -eq '') { continue }
  $xy = $pair.Split(',')
  $cx = [int]$xy[0]; $cy = [int]$xy[1]
  $i++
  if ([SCN]::GetForegroundWindow() -ne $h) {
    $fg = [SCN]::GetForegroundWindow(); $fgPid = 0
    $ft = [SCN]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $mt = [SCN]::GetCurrentThreadId()
    [SCN]::AttachThreadInput($mt, $ft, $true) | Out-Null
    [SCN]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 250
    [SCN]::AttachThreadInput($mt, $ft, $false) | Out-Null
  }
  $r = New-Object SCN+RECT
  [SCN]::GetWindowRect($h, [ref]$r) | Out-Null
  [SCN]::SetCursorPos(($r.L + $cx), ($r.T + $cy)) | Out-Null
  Start-Sleep -Milliseconds 200
  [SCN]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [SCN]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 900
  $mid = Join-Path (Split-Path $PSScriptRoot -Parent) ($Out + "_step" + $i + ".png")
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out $mid | Out-Null
  Write-Output ("step " + $i + " clicked " + $cx + "," + $cy)
}
$final = Join-Path (Split-Path $PSScriptRoot -Parent) ($Out + "_final.png")
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out $final | Out-Null
Write-Output ('final: ' + $final)
