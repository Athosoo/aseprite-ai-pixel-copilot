# tests/verify-v1.0.ps1 -- v1.0 acceptance batch (explicit list, ASCII-only)
# usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\verify-v1.0.ps1
$ErrorActionPreference = 'Continue'
$ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ASE  = 'D:\PraticleTool\Aseprite\aseprite.exe'
$env:ASE_PROJ = $ROOT

function Parse-Nums([string]$out) {
  # 1) node:test style:  "<i> pass 12" / "<i> fail 0"
  $mp = [regex]::Match($out, '(?<![A-Za-z])pass\s+(\d+)')
  $mf = [regex]::Match($out, '(?<![A-Za-z])fail\s+(\d+)')
  if ($mp.Success) { $f = 0; if ($mf.Success) { $f = [int]$mf.Groups[1].Value }; return @([int]$mp.Groups[1].Value, $f) }
  # 2) english style:  "103 passed, 0 failed"
  $me = [regex]::Match($out, '(\d+)\s+passed,\s+(\d+)\s+failed')
  if ($me.Success) { return @([int]$me.Groups[1].Value, [int]$me.Groups[2].Value) }
  # 3) framed style:  "==== name: 97 <cjk>, 0 <cjk> ===="
  $lines = $out -split [char]10
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -match '====.*\d.*====') {
      $ints = [regex]::Matches($lines[$i], '\d+')
      if ($ints.Count -ge 2) { return @([int]$ints[0].Value, [int]$ints[1].Value) }
    }
  }
  return $null
}

$luaTests = @(
  'tests\lua\ops_test.lua','tests\lua\artop_test.lua','tests\lua\workspace_test.lua',
  'tests\lua\settings_test.lua','tests\lua\sizelib_test.lua','tests\lua\versions_test.lua',
  'tests\lua\path_test.lua','tests\lua\artlib_test.lua','tests\lua\menu_test.lua',
  'tests\lua\panel_test.lua','tests\lua\ws_test.lua',
  'tests\lua\kernel_test.lua','tests\lua\kit_test.lua','tests\lua\e2e_pack_test.lua',
  'tests\lua\panel_contract_test.lua','tests\lua\workbench_click_test.lua',
  'tests\lua\integration_wiring_test.lua'
)

$rows = @(); $sumP = 0; $sumF = 0
foreach ($rel in $luaTests) {
  $full = Join-Path $ROOT $rel
  if (-not (Test-Path $full)) { $rows += [pscustomobject]@{ suite=$rel; pass='-'; fail='-'; note='absent' }; continue }
  $out = & $ASE -b --script $full 2>&1 | Out-String
  $n = Parse-Nums $out
  if ($null -eq $n) { $rows += [pscustomobject]@{ suite=$rel; pass=0; fail=1; note='no-summary' }; $sumF += 1; continue }
  $sumP += $n[0]; $sumF += $n[1]
  $rows += [pscustomobject]@{ suite=$rel; pass=$n[0]; fail=$n[1]; note='' }
}

$bridgeTests = @(
  'test/selftest.mjs','test/memory_test.mjs','test/styles_test.mjs','test/tools_test.mjs',
  'test/history_test.mjs','test/conversations_test.mjs','test/gaps_test.mjs',
  'test/registry_test.mjs','test/packs_test.mjs','test/evolution_test.mjs'
)
$bP = 0; $bF = 0
$bRows = @()
Push-Location (Join-Path $ROOT 'bridge')
foreach ($rel in $bridgeTests) {
  if (-not (Test-Path (Join-Path (Get-Location) $rel))) { $bRows += [pscustomobject]@{ suite=$rel; pass='-'; fail='-'; note='absent' }; continue }
  $out = node $rel 2>&1 | Out-String
  $code = $LASTEXITCODE
  $n = Parse-Nums $out
  if ($null -eq $n) {
    if ($code -eq 0) { $bRows += [pscustomobject]@{ suite=$rel; pass=1; fail=0; note='exit0' }; $bP += 1 }
    else { $bRows += [pscustomobject]@{ suite=$rel; pass=0; fail=1; note=('exit' + $code) }; $bF += 1 }
  } else {
    $bP += $n[0]; $bF += $n[1]
    $bRows += [pscustomobject]@{ suite=$rel; pass=$n[0]; fail=$n[1]; note='' }
  }
}
Pop-Location

Write-Output '======== LUA ========'
($rows | Format-Table -AutoSize | Out-String -Width 160) | Write-Output
Write-Output '======== BRIDGE ========'
($bRows | Format-Table -AutoSize | Out-String -Width 160) | Write-Output

$outDir = Join-Path $ROOT 'tests\verify'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
[pscustomobject]@{ when=(Get-Date).ToString('s'); luaPass=$sumP; luaFail=$sumF; bridgePass=$bP; bridgeFail=$bF; lua=$rows; bridge=$bRows } |
  ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outDir 'report.json')

Write-Output ('==== TOTAL lua ' + $sumP + ' pass / ' + $sumF + ' fail  |  bridge ' + $bP + ' pass / ' + $bF + ' fail ====')