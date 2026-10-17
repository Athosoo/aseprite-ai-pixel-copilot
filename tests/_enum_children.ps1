# tests/_enum_children.ps1 -- list all descendant windows of Aseprite (panel is a child, not top-level)
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WC {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static List<string> Kids(IntPtr parent) {
    var res = new List<string>();
    EnumChildWindows(parent, (h, p) => {
      var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      RECT r, cr; GetWindowRect(h, out r); GetClientRect(h, out cr);
      res.Add(h.ToInt64() + "|" + c + "|vis=" + IsWindowVisible(h) + "|win=" + (r.R-r.L) + "x" + (r.B-r.T) + " at " + r.L + "," + r.T + "|cli=" + (cr.R-cr.L) + "x" + (cr.B-cr.T) + "|t=" + t);
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@
$p = Get-Process aseprite -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { Write-Output 'aseprite not running'; exit }
$main = $p.MainWindowHandle
Write-Output ('main hwnd=' + $main)
$kids = [WC]::Kids($main)
Write-Output ('child count = ' + $kids.Count)
foreach ($k in $kids) { Write-Output ('  ' + $k) }
