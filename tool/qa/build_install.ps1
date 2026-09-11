# ============================================================
# BiliHarmony 构建 + 安装到模拟器（Windows / DevEco CLI）
# 用法: pwsh -File tool\qa\build_install.ps1 [-SkipBuild] [-Clean]
#
# 与 build.ps1 的区别：
#   - 用 DevEco 自带 hvigorw.bat，不依赖 .hvigor_work 缓存路径；
#   - 本机未生成签名材料（~/.ohos/config 不存在），assembleHap 会在 @SignHap
#     阶段以非 0 退出。未签名 HAP 在此之前的 @PackageHap 已经产出，且模拟器
#     可以安装未签名包，因此这里把 SignHap 的失败视为"环境未配签名"而非构建失败，
#     改为校验产物是否为本轮新产出（mtime）。
#   - 输出统一重定向到文件后再读，避免 PowerShell 管道在大输出时挂起。
# ============================================================
param(
  [switch]$SkipBuild,
  [switch]$Clean
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$devEco = 'D:\DevEco Studio'
$env:NODE_HOME = "$devEco\tools\node"
$env:DEVECO_SDK_HOME = "$devEco\sdk"
$env:JAVA_HOME = "$devEco\jbr"
$env:PATH = "$env:NODE_HOME;$env:JAVA_HOME\bin;$env:PATH"

$hap = Join-Path $root 'entry\build\default\outputs\default\entry-default-unsigned.hap'
$hdc = "$env:DEVECO_SDK_HOME\default\openharmony\toolchains\hdc.exe"

if (-not $SkipBuild) {
  $out = Join-Path $env:TEMP 'bili_bi_out.txt'
  $err = Join-Path $env:TEMP 'bili_bi_err.txt'
  $tasks = if ($Clean) { 'clean assembleHap' } else { 'assembleHap' }
  Write-Host "== 构建开始 $(Get-Date -Format 'HH:mm:ss') (tasks=$tasks) =="
  $started = Get-Date
  $p = Start-Process -FilePath "$devEco\tools\hvigor\bin\hvigorw.bat" `
    -ArgumentList "$tasks --mode module -p product=default --no-daemon --no-parallel" `
    -WorkingDirectory $root -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $out -RedirectStandardError $err
  Write-Host "== hvigor exit=$($p.ExitCode) =="

  $log = Get-Content $out -ErrorAction SilentlyContinue
  $errors = $log | Select-String -Pattern 'ERROR' -SimpleMatch
  if ($errors) { Write-Host '-- hvigor ERROR 行 --'; $errors | Select-Object -Last 12 | ForEach-Object { Write-Host $_ } }

  # ArkTS 编译错误必须直接失败；只有 SignHap 允许降级。
  if ($log | Select-String -Pattern 'Failed :entry:default@CompileArkTS') {
    throw 'ArkTS 编译失败，见上方 ERROR。'
  }
  if ($log | Select-String -Pattern 'BUILD FAILED' -Quiet) {
    if (-not ($log | Select-String -Pattern 'Failed :entry:default@SignHap')) {
      throw '构建失败，且不是签名问题。'
    }
    Write-Host '注意: @SignHap 失败（本机无签名材料），按未签名包继续。'
  }

  $fresh = (Get-Item $hap).LastWriteTime -ge $started.AddSeconds(-2)
  if (-not $fresh) { throw "HAP 不是本轮产出（mtime=$((Get-Item $hap).LastWriteTime)），不肯安装旧包。" }
}
Write-Host "产物: $hap $((Get-Item $hap).Length) bytes  $((Get-Item $hap).LastWriteTime)"

Write-Host '== 安装到设备 =='
$iout = Join-Path $env:TEMP 'bili_hdc_install.txt'
$ierr = Join-Path $env:TEMP 'bili_hdc_install_err.txt'
$ip = Start-Process -FilePath $hdc -ArgumentList "install -r `"$hap`"" `
  -NoNewWindow -Wait -PassThru -RedirectStandardOutput $iout -RedirectStandardError $ierr
Get-Content $iout -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
$ie = Get-Content $ierr -ErrorAction SilentlyContinue
if ($ie) { Write-Host '-- hdc stderr --'; $ie | ForEach-Object { Write-Host $_ } }
if ($ip.ExitCode -ne 0) { throw "安装失败 exit=$($ip.ExitCode)" }
Write-Host "== 完成 $(Get-Date -Format 'HH:mm:ss') =="
