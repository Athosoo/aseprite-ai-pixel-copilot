# 把扩展安装到 Aseprite 的用户扩展目录。
#
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# 安装时会做两件事：
#   1) 复制 extension/ 到 %APPDATA%\Aseprite\extensions\ai-pixel-copilot
#   2) 把【本仓库的绝对路径】写进扩展目录的 __project.lua ——
#      扩展启动时读它来定位 bridge/src/server.mjs。
#      所以源码里不写死任何人的路径，仓库 clone 到哪都能用。
#
# 安装后需要【重启 Aseprite】扩展才会加载（扩展的 init() 只在启动时跑一次；
# 菜单里的 "Rescan Scripts Folder" 只重扫脚本目录，不会重载扩展）。

$ErrorActionPreference = "Stop"

$src = Join-Path $PSScriptRoot "extension"
$dstRoot = Join-Path $env:APPDATA "Aseprite\extensions"
$dst = Join-Path $dstRoot "ai-pixel-copilot"

if (-not (Test-Path $src)) { throw "找不到扩展目录：$src" }

New-Item -ItemType Directory -Force -Path $dstRoot | Out-Null

# 先清掉旧目录，避免残留文件
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
New-Item -ItemType Directory -Force -Path $dst | Out-Null

Copy-Item -Recurse -Force (Join-Path $src "*") $dst

# 删掉复制过来的 bundle（tools/pack-extension.ps1 的产物）。
# 扩展启动时优先用 <扩展目录>\bridge\dist\bridge.mjs，它在的话就轮不到仓库源码 ——
# 于是"改了 bridge/src 却没重新打包"会静默跑到旧代码上。源码安装就该跑源码。
$staleBundle = Join-Path $dst "bridge"
if (Test-Path $staleBundle) { Remove-Item -Recurse -Force $staleBundle }

# 记录项目根（扩展据此找 bridge）。
# 用 WriteAllText 而不是 Set-Content：PowerShell 5 的 -Encoding utf8 会写 BOM，
# 而 Lua 读出来开头会多出 \239\187\191，路径就废了。
$projDir = (Resolve-Path $PSScriptRoot).Path
[System.IO.File]::WriteAllText((Join-Path $dst "__project.lua"), $projDir, (New-Object System.Text.UTF8Encoding $false))

Write-Host "已安装到: $dst"
Write-Host "项目根已记录: $projDir"
Write-Host ""
Get-ChildItem -Recurse -File $dst | ForEach-Object {
  Write-Host ("  " + $_.FullName.Substring($dst.Length + 1))
}

# 桥的依赖检查：没有 node_modules 的话桥起不来
$nm = Join-Path $PSScriptRoot "bridge\node_modules"
if (-not (Test-Path $nm)) {
  Write-Host ""
  Write-Host "!! bridge 依赖还没装，先执行：" -ForegroundColor Yellow
  Write-Host "     cd `"$PSScriptRoot\bridge`" ; npm install" -ForegroundColor Yellow
}

$cfg = Join-Path $PSScriptRoot "bridge\config.json"
$cfgEx = Join-Path $PSScriptRoot "bridge\config.example.json"
if ((-not (Test-Path $cfg)) -and (Test-Path $cfgEx)) {
  Copy-Item $cfgEx $cfg
  Write-Host ""
  Write-Host "已从 config.example.json 生成 bridge\config.json（记得填 llm.apiKey）" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "接下来："
Write-Host "  1) 填 API Key: 编辑 $PSScriptRoot\bridge\config.json 的 llm.apiKey"
Write-Host "     （也可以在面板里敲 menu -> 设置 来填）"
Write-Host "  2) 重启 Aseprite（会提示是否恢复上次会话，按需选择）"
Write-Host "  3) 菜单 File > Scripts > 'AI Pixel Copilot (AI console)'，或按 Ctrl+Shift+A"
Write-Host "     首次会弹几次授权框（每个文件一次），勾选不再提示即可"
Write-Host ""
Write-Host "快捷键（装完重启生效）："
Write-Host "  Ctrl+Shift+A  AI 控制台面板"
Write-Host "  Ctrl+Shift+M  命令表（也可以直接在输入框里敲 菜单 / menu）"
Write-Host "  Ctrl+Shift+P  贴边小面板"
