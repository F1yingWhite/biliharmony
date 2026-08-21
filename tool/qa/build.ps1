# ============================================================
# BiliHarmony 一键构建脚本（Windows / DevEco Studio CLI，No-Daemon）
# 用法: pwsh -File tool\qa\build.ps1 [-Install]
# 说明: 直接驱动 hvigor.js（--no-daemon 避免守护进程 spawn EPERM），
#       产物: entry/build/default/outputs/default/entry-default-signed.hap
# ============================================================
param(
  [switch]$Install,          # 构建后自动安装到模拟器
  [string]$ExtraArgs = ''    # 附加 hvigor 参数
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$devEco = 'D:\DevEco Studio'
$env:NODE_HOME = "$devEco\tools\node"
$env:DEVECO_SDK_HOME = "$devEco\sdk"
$env:JAVA_HOME = "$devEco\jbr"
$hvigorHome = Join-Path $root '.hvigor_work'
$env:HVIGOR_USER_HOME = $hvigorHome
$env:PATH = "$env:NODE_HOME;$env:JAVA_HOME\bin;$env:PATH"

$workspaceHvigor = Join-Path $hvigorHome 'project_caches\98e35b12da4d7bd1e6d3e622451bd0f1\workspace\node_modules\@ohos\hvigor\bin\hvigor.js'
if (-not (Test-Path $workspaceHvigor)) {
  throw "hvigor workspace 未就绪: $workspaceHvigor`n请先在 DevEco Studio 完整构建一次生成 cache。"
}

$so = Join-Path $env:TEMP 'bili_build_out.txt'
$se = Join-Path $env:TEMP 'bili_build_err.txt'
# hvigor 通过 -p/--prop 传参；避免参数数组解析问题，这里直接拼命令行
$nodeExe = "$env:NODE_HOME\node.exe"
$cmdLine = "`"$workspaceHvigor`" assembleHap --mode module -p product=default --no-daemon --no-parallel"

Write-Host "== build 开始 $(Get-Date -Format 'HH:mm:ss') =="
$p = Start-Process -FilePath $nodeExe -ArgumentList $cmdLine -WorkingDirectory $root -NoNewWindow -Wait -RedirectStandardOutput $so -RedirectStandardError $se -PassThru
Write-Host "== hvigor exit=$($p.ExitCode) =="
Get-Content $so -Tail 30
$errTail = if (Test-Path $se) { Get-Content $se -Tail 20 } else { '' }
if ($errTail) { Write-Host '-- stderr --'; $errTail }
if ($p.ExitCode -ne 0) { exit $p.ExitCode }

$hap = Get-Item (Join-Path $root 'entry\build\default\outputs\default\entry-default-signed.hap')
Write-Host "产物: $($hap.FullName) $($hap.Length) bytes"

if ($Install) {
  $hdc = "$env:DEVECO_SDK_HOME\default\openharmony\toolchains\hdc.exe"
  Write-Host "install -> emulator"
  & $hdc install -r $hap.FullName
  Write-Host 'done'
}
exit 0
