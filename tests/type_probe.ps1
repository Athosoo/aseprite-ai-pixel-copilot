# 把键盘事件真的发进 Aseprite（用于验证只有真实按键才暴露的输入 bug）。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/type_probe.ps1 -Keys "{BACKSPACE}{BACKSPACE}"
#
# 安全约束：**只在确认 Aseprite 位于前台时才发键** —— 否则按键会打到别的程序上
# （SendKeys 是发给当前前台窗口的，发错窗口可能删掉用户别处的文字）。

param([string]$Keys = "{BACKSPACE}", [string]$ProcessName = "aseprite")

Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class KeyWin32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  // fAttach 用 int 而不是 bool：PowerShell 传 $true 给 bool 形参会抛
  // MethodArgumentConversionInvalidCastArgument（实测），传 1/0 稳妥。
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, int fAttach);
}
"@

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Error "no visible $ProcessName window"; exit 1 }
$h = $proc.MainWindowHandle

if ([KeyWin32]::IsIconic($h)) { [void][KeyWin32]::ShowWindow($h, 9) }   # SW_RESTORE

# PowerShell 是从 bash 里后台起的，属于"后台进程"，Windows 会拒绝它直接
# SetForegroundWindow（只允许前台进程抢前台）。标准绕法：把自己的线程临时
# attach 到当前前台线程上，抢完再 detach。
#
# 注意：P/Invoke 返回的 IntPtr 为 0 时，PowerShell 会把它当成 $null 输出，
# 所以不能用 `-ne [IntPtr]::Zero` 判空（$null 不等于 IntPtr.Zero，判断会通过然后炸）。
# 先看类型、再取 ToInt64() 才稳。
$fg = [KeyWin32]::GetForegroundWindow()
$fgThread = 0
if (($fg -is [IntPtr]) -and ($fg.ToInt64() -ne 0)) {
  $fgThread = [KeyWin32]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
}
$myThread = [KeyWin32]::GetCurrentThreadId()

if ($fgThread -ne 0) { [void][KeyWin32]::AttachThreadInput($myThread, $fgThread, 1) }
[void][KeyWin32]::SetForegroundWindow($h)
if ($fgThread -ne 0) { [void][KeyWin32]::AttachThreadInput($myThread, $fgThread, 0) }

$front = $false
for ($i = 0; $i -lt 12; $i++) {
  Start-Sleep -Milliseconds 250
  if ([KeyWin32]::GetForegroundWindow() -eq $h) { $front = $true; break }
  if ($fgThread -ne 0) { [void][KeyWin32]::AttachThreadInput($myThread, $fgThread, 1) }
  [void][KeyWin32]::SetForegroundWindow($h)
  if ($fgThread -ne 0) { [void][KeyWin32]::AttachThreadInput($myThread, $fgThread, 0) }
}

if (-not $front) {
  Write-Error "Aseprite is not in the foreground; refusing to send keys (would type into whatever is focused)."
  exit 2
}

Start-Sleep -Milliseconds 400      # 让窗口先把焦点交给面板里的输入点
[System.Windows.Forms.SendKeys]::SendWait($Keys)
Write-Output "sent: $Keys"
