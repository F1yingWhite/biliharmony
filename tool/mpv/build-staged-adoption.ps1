param(
    [string]$StagingPath = '.qa/mpv-speed-core/production-adoption',
    [string]$DevEcoPath = 'C:\Program Files\Huawei\DevEco Studio'
)
$ErrorActionPreference = 'Stop'
$taskApp = (Resolve-Path -LiteralPath $StagingPath).Path
$taskProposal = Join-Path $taskApp 'preparation.json'
if (-not (Test-Path -LiteralPath $taskProposal)) { throw 'Prepare the dedicated staging app first.' }
$taskState = Get-Content -LiteralPath $taskProposal -Raw | ConvertFrom-Json
if ($taskState.production_adopted -ne $false -or $taskState.scope -ne 'Staged proposal only; no production mutation') {
    throw 'This script only builds an isolated pending-adoption workspace.'
}
$env:NODE_HOME = Join-Path $DevEcoPath 'tools/node'
$env:JAVA_HOME = Join-Path $DevEcoPath 'jbr'
$env:DEVECO_SDK_HOME = Join-Path $DevEcoPath 'sdk'
$env:PATH = $env:NODE_HOME + ';' + (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH
$taskHvigor = Join-Path $DevEcoPath 'tools/hvigor/bin/hvigorw.bat'
Push-Location $taskApp
try {
    $ErrorActionPreference = 'Continue'
    & $taskHvigor assembleHap --mode module -p product=default -p buildMode=debug --no-daemon --no-parallel *> (Join-Path $taskApp 'adoption-app-build.log')
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { throw 'Isolated ARM build failed; inspect adoption-app-build.log.' }
} finally { Pop-Location }
$taskHap = Join-Path $taskApp 'entry/build/default/outputs/default/entry-default-signed.hap'
if (-not (Test-Path -LiteralPath $taskHap)) { throw 'Signed staging HAP is missing.' }
Write-Output ('Signed isolated ARM HAP: ' + $taskHap)
