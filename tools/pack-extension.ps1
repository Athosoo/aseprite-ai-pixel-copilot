# 把扩展打成单文件 .aseprite-extension（本质是 zip，见 Aseprite 的
# src/app/extensions_tests.cpp:98 —— zip 内路径就是扩展目录的相对路径，
# package.json 必须落在压缩包根）。
#
# 打包时会把本地桥 bundle 成单文件一起塞进去，所以别人装上就能直接用：
# 只要系统有 Node.js，**不用 clone 仓库、不用 npm install**。
#
#   powershell -ExecutionPolicy Bypass -File tools/pack-extension.ps1
#
# 产出： dist/ai-pixel-copilot-<version>.aseprite-extension
#
# 两个坑：
#   1) Compress-Archive 只认 .zip 后缀，直接给 .aseprite-extension 会报
#      NotSupportedArchiveFileExtension —— 先打成临时 .zip 再改名。
#   2) 它生成的条目路径是正斜杠（实测合规），这点不用担心。
#
# macOS / Linux 上没有这个脚本，手动两步等价：
#   node bridge/scripts/bundle-for-extension.mjs
#   cd extension && zip -r ../dist/ai-pixel-copilot.zip . && \
#     mv ../dist/ai-pixel-copilot.zip ../dist/ai-pixel-copilot.aseprite-extension

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root "extension"
$dist = Join-Path $root "dist"
$stage = Join-Path $src "bridge"          # 扩展包内的桥（构建产物，已 gitignore）

if (-not (Test-Path $src)) { throw "找不到扩展目录：$src" }

# --- 1) bundle 桥（含 ws）+ 收集它运行时要用的文件
Write-Host "[1/3] bundle 本地桥..."
node (Join-Path $root "bridge\scripts\bundle-for-extension.mjs")
if ($LASTEXITCODE -ne 0) { throw "bundle 失败" }

# 保险起见再清一次：个人配置（含 API Key）/ 色值库 / 日志绝不能进发布包
Remove-Item (Join-Path $stage "config.json") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $stage "data") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $stage "bridge.log") -Force -ErrorAction SilentlyContinue

# --- 2) 打包（先 .zip 再改名）
Write-Host "[2/3] 打包..."
$pkg = Get-Content (Join-Path $src "package.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$out = Join-Path $dist ("ai-pixel-copilot-" + $pkg.version + ".aseprite-extension")

New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (Test-Path $out) { Remove-Item $out -Force }

$tmpZip = Join-Path $env:TEMP ("aipc-" + [guid]::NewGuid().ToString("N") + ".zip")
Compress-Archive -Path (Join-Path $src "*") -DestinationPath $tmpZip -Force
Move-Item $tmpZip $out

# --- 3) 报告
Write-Host "[3/3] 完成"
Write-Host ""
Write-Host "已打包: $out"
Write-Host ("大小: " + [math]::Round((Get-Item $out).Length / 1KB, 1) + " KB")
Write-Host ""
Write-Host "安装（任选其一）："
Write-Host "  1) 拖进 Aseprite 窗口"
Write-Host "  2) Edit > Preferences > Extensions > Add Extension"
Write-Host "  3) 双击文件（系统已关联到 Aseprite 时）"
Write-Host ""
Write-Host "装完重启 Aseprite，Ctrl+Shift+A 打开面板。"
Write-Host "首次会弹几个授权框（每个脚本文件一次），勾选不再提示即可。"
Write-Host "前提：系统有 Node.js 18+（node --version 能打印版本）。"
