Set-Location (Join-Path $PSScriptRoot '..\bridge')
$o = & node 'test/selftest.mjs' 2>&1 | Out-String
Write-Output ('exit=' + $LASTEXITCODE)
($o -split [char]10) | Where-Object { $_ -match 'FAIL|====|Error|error' } | Select-Object -Last 12
