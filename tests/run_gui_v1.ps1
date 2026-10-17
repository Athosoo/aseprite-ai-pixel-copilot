# tests/run_gui_v1.ps1 -- launch Aseprite in GUI, render one workbench state, screenshot it
# usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_gui_v1.ps1 -Mode console -Out tests\lua\gui_v1_console.png
#
# The installed extension is parked during the run: its main.lua reads __project.lua via
# io.open at startup, which pops a native permission modal on this machine (empty
# [script_access]) and the screenshot would capture the modal instead of the panel.
param(
  [Parameter(Mandatory=$true)][string]$Mode,
  [Parameter(Mandatory=$true)][string]$Out,
  [int]$Settle = 5
)
$ErrorActionPreference = 'Stop'
$ROOT   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ASE    = 'D:\PraticleTool\Aseprite\aseprite.exe'
$probe  = Join-Path $ROOT ("tests\lua\v1wb_" + $Mode + ".lua")
$ext    = Join-Path $env:APPDATA 'Aseprite\extensions\ai-pixel-copilot'
$parked = Join-Path $env:APPDATA 'Aseprite\_extensions_parked_v1probe'
$outFull = Join-Path $ROOT $Out

if (-not (Test-Path $probe)) { throw "probe not found: $probe" }

$parkedNow = $false
try {
  Get-Process aseprite -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 1500
  if ((Test-Path $ext) -and -not (Test-Path $parked)) {
    Move-Item -LiteralPath $ext -Destination $parked
    $parkedNow = $true
    Write-Output 'parked installed extension'
  }
  $log = Join-Path $ROOT ("tests\lua\" + $Mode + ".stdout.log")
  if (Test-Path $log) { Move-Item -LiteralPath $log -Destination ($log + '.old') -Force }
  if (Test-Path ($log + '.err')) { Move-Item -LiteralPath ($log + '.err') -Destination ($log + '.err.old') -Force }
  Start-Process -FilePath $ASE -ArgumentList @('--script', $probe) -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') | Out-Null
  Start-Sleep -Seconds $Settle
  $alive = (Get-Process aseprite -ErrorAction SilentlyContinue | Measure-Object).Count
  Write-Output ("aseprite alive: " + $alive)
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ROOT 'tests\shot_window.ps1') -Out $outFull
  Write-Output ("probe log: " + $log)
  if (Test-Path $outFull) { Write-Output ("screenshot: " + (Get-Item $outFull).Length + " bytes -> " + $outFull) }
  else { Write-Output 'NO SCREENSHOT' }
}
finally {
  Get-Process aseprite -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 400
  if ($parkedNow -and (Test-Path $parked)) {
    Move-Item -LiteralPath $parked -Destination $ext
    Write-Output 'restored installed extension'
  }
}