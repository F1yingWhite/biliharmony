# ============================================================
# BiliHarmony 全量 UI 测试流程 — 跨平台 PowerShell 入口
# 实际逻辑在 run_all.py（Python 3），Windows/macOS/Linux 均可运行。
# 用法: pwsh -File tool\qa\run_all_cross.ps1 [-SkipBuild] [-SkipInstall] [-OnlyAudit]
# ============================================================
param(
  [switch]$SkipBuild,
  [switch]$SkipInstall,
  [switch]$OnlyAudit
)
$ErrorActionPreference = 'Stop'
$py = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py) { throw '未找到 python3/python，请先安装 Python 3。' }
$argsList = @()
if ($SkipBuild) { $argsList += '--skip-build' }
if ($SkipInstall) { $argsList += '--skip-install' }
if ($OnlyAudit) { $argsList += '--only-audit' }
& $py.Source (Join-Path $PSScriptRoot 'run_all.py') @argsList
exit $LASTEXITCODE
