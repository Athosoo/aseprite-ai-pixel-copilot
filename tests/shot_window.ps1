# 只截取 Aseprite 窗口，且【只在确认它位于前台时才截图】——
# 否则会拍到同一屏幕位置上其它程序的内容（隐私问题）。
#
# 用法： powershell -NoProfile -ExecutionPolicy Bypass -File tests/shot_window.ps1 -Out shot.png

param([string]$Out = "shot.png", [string]$ProcessName = "aseprite",
      [string]$Method = "printwindow")   # printwindow（默认，不抢前台）| foreground

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
  public const uint SWP_NOMOVE = 0x0002, SWP_NOSIZE = 0x0001, SWP_SHOWWINDOW = 0x0040;
}
"@

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Error "no visible $ProcessName window"; exit 1 }
$h = $proc.MainWindowHandle

if ($Method -eq "printwindow") {
  $r0 = New-Object Win32+RECT
  [void][Win32]::GetWindowRect($h, [ref]$r0)
  $w0 = $r0.Right - $r0.Left; $h0 = $r0.Bottom - $r0.Top
  if ($w0 -le 0 -or $h0 -le 0) { Write-Error "bad window rect"; exit 1 }
  $bmp0 = New-Object System.Drawing.Bitmap $w0, $h0
  $g0 = [System.Drawing.Graphics]::FromImage($bmp0)
  $hdc = $g0.GetHdc()
  $ok = [Win32]::PrintWindow($h, $hdc, 2)   # 2 = PW_RENDERFULLCONTENT
  $g0.ReleaseHdc($hdc)
  $g0.Dispose()
  $bmp0.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp0.Dispose()
  Write-Output "saved $Out (printwindow ok=$ok) ${w0}x${h0}"
  exit 0
}

# 置前：先恢复（如果最小化）、再 topmost、再 SetForegroundWindow
if ([Win32]::IsIconic($h)) { [void][Win32]::ShowWindow($h, 9) }   # SW_RESTORE
[void][Win32]::SetWindowPos($h, [Win32]::HWND_TOPMOST, 0, 0, 0, 0,
    ([Win32]::SWP_NOMOVE -bor [Win32]::SWP_NOSIZE -bor [Win32]::SWP_SHOWWINDOW))
[void][Win32]::SetForegroundWindow($h)

# 等它真的到前台，最多试 3 秒
$front = $false
for ($i = 0; $i -lt 12; $i++) {
  Start-Sleep -Milliseconds 250
  if ([Win32]::GetForegroundWindow() -eq $h) { $front = $true; break }
  [void][Win32]::SetForegroundWindow($h)
}

if (-not $front) {
  # 没抢到前台就【不截图】，避免拍到别的程序
  [void][Win32]::SetWindowPos($h, [Win32]::HWND_NOTOPMOST, 0, 0, 0, 0,
      ([Win32]::SWP_NOMOVE -bor [Win32]::SWP_NOSIZE))
  Write-Error "Aseprite is not in the foreground; refusing to capture (would grab whatever is on top). Close other focused windows and retry."
  exit 2
}

$r = New-Object Win32+RECT
[void][Win32]::GetWindowRect($h, [ref]$r)
$w = $r.Right - $r.Left
$hgt = $r.Bottom - $r.Top
if ($w -le 0 -or $hgt -le 0) { Write-Error "bad window rect"; exit 1 }

$bmp = New-Object System.Drawing.Bitmap $w, $hgt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $hgt))
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

[void][Win32]::SetWindowPos($h, [Win32]::HWND_NOTOPMOST, 0, 0, 0, 0,
    ([Win32]::SWP_NOMOVE -bor [Win32]::SWP_NOSIZE))

Write-Output "saved $Out  ${w}x${hgt}"
