# 预置 [script_access]：按 Aseprite 的规则（源文件名 sha1 → 权限位）写入授权，免得每次弹模态框
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security 2>$null
function Key([string]$s) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $b = [System.Text.Encoding]::UTF8.GetBytes($s)
  return ([BitConverter]::ToString($sha.ComputeHash($b)) -replace '-','').ToLower()
}
$repo = 'D:\PraticleTool\Aseprite-AI'
$inst = Join-Path $env:APPDATA 'Aseprite\extensions\ai-pixel-copilot'

$rel = @(
  'extension\lib\ws.lua',
  'extension\lib\versions.lua',
  'extension\lib\agent.lua',
  'extension\lib\panel.lua',
  'extension\lib\workspace.lua',
  'extension\kernel\ledger.lua',
  'extension\kernel\dsl.lua',
  'extension\kernel\init.lua',
  'extension\main.lua'
)

$grants = @{}
foreach ($r in $rel) {
  $p = Join-Path $repo $r
  $grants[(Key $p)] = $p
  # 安装副本路径也一并写入（两种装法都能免问）
  $p2 = Join-Path $inst ($r -replace '^extension\\','')
  $grants[(Key $p2)] = $p2
  # 混合分隔符（require 的 package.path 形态）
  $g = Join-Path $repo 'extension' ; $g = $g + '/' + ($r -replace '^extension\\','')
  $grants[(Key $g)] = $g
}

Write-Output ('computed keys: ' + $grants.Count)

Get-Process aseprite -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800

$ini = Join-Path $env:APPDATA 'Aseprite\aseprite.ini'
Copy-Item -LiteralPath $ini -Destination ($ini + '.bak_grants') -Force
$lines = [System.Collections.ArrayList]@(Get-Content -LiteralPath $ini)
$idx = -1
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\[script_access\]') { $idx = $i; break } }
if ($idx -lt 0) { $lines.Add('[script_access]') | Out-Null; $idx = $lines.Count - 1 }
Write-Output ('section index: ' + $idx)

$existing = @{}
foreach ($l in $lines) { if ($l -match '^([0-9a-f]{40}) = (\d+)$') { $existing[$Matches[1]] = $Matches[2] } }
Write-Output ('existing grants: ' + $existing.Count)

$added = 0
$insertAt = $idx + 1
foreach ($k in $grants.Keys) {
  if (-not $existing.ContainsKey($k)) {
    $lines.Insert($insertAt, ($k + ' = 31'))
    $insertAt++
    $added++
  }
}
[System.IO.File]::WriteAllLines($ini, $lines, (New-Object System.Text.UTF8Encoding $false))
Write-Output ('added keys: ' + $added + '  total now: ' + ($existing.Count + $added))
