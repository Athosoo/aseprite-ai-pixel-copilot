# tests/_enum_windows.ps1 -- launch Aseprite (panel auto-opens via DIAG timer) and list its windows
param([string]$Out = "tests\lua\live_auto.png")
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WE {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static List<string> List(uint target) {
    var res = new List<string>();
    EnumWindows((h, p) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == target) {
        var sb = new StringBuilder(256); GetWindowTextW(h, sb, 256);
        RECT r; GetWindowRect(h, out r);
        res.Add(h.ToInt64() + "|" + IsWindowVisible(h) + "|" + (r.R-r.L) + "x" + (r.B-r.T) + "|" + sb.ToString());
      }
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@
Get-Process aseprite -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 900
Start-Process -FilePath 'D:\PraticleTool\Aseprite\aseprite.exe'
Start-Sleep -Seconds 9
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { throw 'aseprite did not start' }
Write-Output ('pid=' + $p.Id)
foreach ($w in [WE]::List([uint32]$p.Id)) { Write-Output ('  hwnd|visible|size|title = ' + $w) }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'shot_window.ps1') -Out (Join-Path (Split-Path $PSScriptRoot -Parent) $Out)
