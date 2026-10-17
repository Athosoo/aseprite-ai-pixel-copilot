Add-Type @"
using System;
using System.Runtime.InteropServices;
public class M2 {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
function Click($x, $y) {
  [M2]::SetCursorPos($x, $y) | Out-Null
  Start-Sleep -Milliseconds 250
  [M2]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 90
  [M2]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 600
}
Write-Output ('foreground before: ' + [M2]::GetForegroundWindow())
Click 626 626    # checkbox "Don't show this specific alert again"
Click 721 695    # Allow to Open Connections
Write-Output 'clicked'
