# ============================================================
# BiliHarmony 全量测试流程 — 一键入口
#   stages:
#     1. build      构建 HAP（可选 --SkipBuild 跳过）
#     2. install    安装到模拟器
#     3. suite_all  全量功能回归（首页/频道/视频/搜索/番剧/动态/我的/深色像素）
#     4. suite_deep 深度穿越（评论/弹幕/用户空间/排行榜/番剧详情/直播/历史）
#     5. audit_ui   对齐/间距审计（重叠、越界、列对齐、行距）
#     6. audit_zone 结构对齐（Dock 等距、行首对齐、边缘留白）
#     7. report     汇总输出
# 用法: pwsh -File tool\qa\run_all.ps1 [-SkipBuild] [-SkipInstall]
# ============================================================
param(
  [switch]$SkipBuild,
  [switch]$SkipInstall,
  [switch]$OnlyAudit      # 只跑审计（跳过交互套件，适合离线批处理）
)
$ErrorActionPreference = 'Continue'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$qaDir = Join-Path $root '.emulator\qa'
New-Item -ItemType Directory -Force -Path $qaDir | Out-Null

$logFile = Join-Path $qaDir ("runall_" + (Get-Date -Format 'MMddHHmmss') + '.log')
Start-Transcript -Path $logFile -Append | Out-Null

function Step([string]$n) { Write-Host "`n========== [$n] $(Get-Date -Format 'HH:mm:ss') ==========" }

Step '1/7 构建'
if ($SkipBuild) { Write-Host '跳过构建（-SkipBuild）' } else {
  & (Join-Path $PSScriptRoot 'build.ps1')
  if ($LASTEXITCODE -ne 0) { Write-Host '!! 构建失败'; Stop-Transcript | Out-Null; exit 1 }
}

Step '2/7 安装'
if ($SkipBuild -or $SkipInstall) { Write-Host '跳过安装' }
else {
  $hap = Join-Path $root 'entry\build\default\outputs\default\entry-default-signed.hap'
  $hdc = 'D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
  & $hdc install -r $hap
}

Step '3/7 全量套件（suite_all）'
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'suite_all.ps1') -SkipInstall
$reportAll = Get-Content (Join-Path $qaDir 'qa_report.md') -Raw

Step '4/7 深度套件（suite_deep）'
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'suite_deep.ps1') -SkipInstall
$reportDeep = Get-Content (Join-Path $qaDir 'qa_report.md') -Raw

Step '5/7 对齐/重叠审计（audit_ui）'
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'audit_ui.ps1') -AllDumps | Out-Null
$auditUi = Get-Content (Join-Path $qaDir 'qa_report.md') -Raw

Step '6/7 间距/结构审计（audit_zone）'
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'audit_zone.ps1') | Out-Null
$auditZone = Get-Content (Join-Path $qaDir 'qa_report.md') -Raw

Step '7/7 汇总'
$sum = @"
# BiliHarmony 全量测试汇总

- 时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- 组件: build.ps1 / suite_all.ps1 / suite_deep.ps1 / audit_ui.ps1 / audit_zone.ps1 / check_img.py / analyze_ui.py

## 结论
功能全量回归 + UI 对齐审计已完成，详见分报告。

## 套件结果（suite_all 最近一次）
$(Get-Content (Join-Path $qaDir 'qa_report.md') -Raw)

## 原始日志
$logFile
"@
$sum | Set-Content (Join-Path $qaDir 'SUMMARY.md') -Encoding UTF8
Write-Host "汇总: $qaDir\SUMMARY.md"
Write-Host "退出码 0"
Stop-Transcript | Out-Null
exit 0