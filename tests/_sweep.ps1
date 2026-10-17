# tests/_sweep.ps1 -- click a list of targets on the REAL app, screenshot each, report change/no-change
param([string]$Out = "tests\lua\sweep")
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class SW {
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
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { throw 'aseprite not running' }
$h = $p.MainWindowHandle

function Focus {
  if ([SW]::GetForegroundWindow() -ne $h) {
    $fg = [SW]::GetForegroundWindow(); $fgPid = 0
    $ft = [SW]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $mt = [SW]::GetCurrentThreadId()
    [SW]::AttachThreadInput($mt, $ft, $true) | Out-Null
    [SW]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 250
    [SW]::AttachThreadInput($mt, $ft, $false) | Out-Null
  }
}
function Shot($name) {
  $path = Join-Path (Split-Path $PSScriptRoot -Parent) ($Out + "_" + $name + ".png")
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out $path | Out-Null
  return (Get-FileHash $path -Algorithm SHA256).Hash
}
function Click($x, $y) {
  Focus
  $r = New-Object SW+RECT
  [SW]::GetWindowRect($h, [ref]$r) | Out-Null
  [SW]::SetCursorPos(($r.L + $x), ($r.T + $y)) | Out-Null
  Start-Sleep -Milliseconds 180
  [SW]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 70
  [SW]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 750
}

# keep the window stable so image coords stay valid
[SW]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1900, 1150, 0x0040) | Out-Null
Start-Sleep -Milliseconds 600

$targets = @(
  @{ n = 'tb_min';  x = 1493; y = 124 },
  @{ n = 'tb_ctx';  x = 1529; y = 124 },
  @{ n = 'tb_dash'; x = 1565; y = 124 },
  @{ n = 'rail_1';  x = 104;  y = 204 },
  @{ n = 'rail_2';  x = 104;  y = 288 },
  @{ n = 'rail_3';  x = 104;  y = 372 },
  @{ n = 'rail_4';  x = 104;  y = 452 },
  @{ n = 'rail_5';  x = 104;  y = 537 },
  @{ n = 'rail_6';  x = 104;  y = 621 },
  @{ n = 'rail_7';  x = 104;  y = 705 }
)

$prev = Shot 'base'
Write-Output ('base hash ' + $prev.Substring(0,12))
foreach ($t in $targets) {
  [SW]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 1900, 1150, 0x0040) | Out-Null
  Start-Sleep -Milliseconds 200
  Click $t.x $t.y
  $now = Shot $t.n
  $changed = ($now -ne $prev)
  Write-Output ('{0,-10} changed={1}' -f $t.n, $changed)
  $prev = $now
}
