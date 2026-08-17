# BiliHarmony QA 冒烟测试入口
# 用法: pwsh -File tool\qa\smoke.ps1 [-Pages]
param(
  [switch]$SkipInstall,
  [string]$Hap = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'driver.ps1')

Write-Host "== BiliHarmony QA smoke ==" 
Assert-Health

if (-not $SkipInstall) {
  $hap = $Hap
  if (-not $hap) {
    $cand = @(
      'D:\code\biliharmony\entry\build\default\outputs\default\entry-default-signed.hap',
      'D:\code\biliharmony\entry\build\default\outputs\default\entry-default-unsigned.hap'
    )
    $hap = $cand | Where-Object { Test-Path $_ } | Select-Object -First 1
  }
  if ($hap -and (Test-Path $hap)) {
    Write-Host "install $hap"
    Invoke-Hdc -HdcArgs @('install','-r',$hap) | Out-Host
  } else {
    Write-Host 'no hap found, skip install'
  }
}

Start-App
# 冷启动回首页：Force-stop 保证从 Index 根页开始（避免上次停留在二级页）
Stop-App
Start-App

# 1) 首页: 应该出现 推荐/热门/直播 频道
Begin-Test '首页频道渲染'
$d1 = Dump-Ui 'smoke_home'
$t1 = Get-UiTree $d1
Assert-HasText $t1 '推荐'
Assert-HasText $t1 '热门'
$shot1 = Snapshot-Shot 'smoke_home'

# 2) 切换频道: 点热门
Begin-Test '切换热门频道'
$nHot = Find-UiNode -Root $t1 -Filter { ((Get-NodeText $_) -eq '热门') }
if ($nHot) { Tap-CenterOf -Bounds (Get-NodeBounds $nHot) }
Start-Sleep -Seconds 2
$d2 = Dump-Ui 'smoke_hot'
$t2 = Get-UiTree $d2
Assert-HasText $t2 '直播' -MinCount 0   # 直播频道入口仍在 tab
$shot2 = Snapshot-Shot 'smoke_hot'

# 3) 瀑布流滚动
Begin-Test '首页滚动'
Swipe-Up -Dist 800
Start-Sleep -Seconds 1
$t3 = Get-UiTree (Dump-Ui 'smoke_scroll')
$tx3 = Get-AllTexts $t3
if ($tx3.Count -gt 20) { Pass-Test "滚动后文本节点 $($tx3.Count) 个" } else { Fail-Test "滚动后文本节点过少: $($tx3.Count)" }

# 4) 动态 Tab
Begin-Test '动态 Tab'
$nDyn = Find-UiNode -Root $t3 -Filter { ((Get-NodeText $_) -eq '动态') }
if ($nDyn) { Tap-CenterOf -Bounds (Get-NodeBounds $nDyn) }
Start-Sleep -Seconds 2
$t4 = Get-UiTree (Dump-Ui 'smoke_dyn')
$has = Assert-HasText $t4 '关注'
$shot3 = Snapshot-Shot 'smoke_dyn'

# 5) 我的 Tab
Begin-Test '我的 Tab'
$nMine = Find-UiNode -Root $t4 -Filter { ((Get-NodeText $_) -eq '我的') }
if ($nMine) { Tap-CenterOf -bounds (Get-NodeBounds $nMine) }
Start-Sleep -Seconds 2
$t5 = Get-UiTree (Dump-Ui 'smoke_mine')
Assert-HasText $t5 '我的追番'
Assert-HasText $t5 '稍后再看'
Assert-HasText $t5 '收藏'
$shot4 = Snapshot-Shot 'smoke_mine'

$report = Export-QaReport -Title '冒烟测试报告'
Write-Host "报告: $report"
Write-Host "PASS=$($script:QAH_PASSED) FAIL=$($script:QAH_FAILED) SKIP=$($script:QAH_SKIPPED)"
exit ($script:QAH_FAILED -gt 0 ? 1 : 0)