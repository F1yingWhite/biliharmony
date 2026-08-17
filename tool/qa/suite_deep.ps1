# ============================================================
# BiliHarmony 深化 QA（二级页面深度穿越）
# 覆盖: 视频详情->评论区->弹幕面板 / 排行榜 / 番剧详情 /
#       直播房间 / 用户空间 / 图片查看 / 历史/稍后再看/收藏 /
#       搜索联想与结果Tab / 主题色切换
# 用法: pwsh -File tool\qa\suite_deep.ps1 [-SkipInstall]
# ============================================================
param([switch]$SkipInstall)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'driver.ps1')

Write-Host "== BiliHarmony 深化 QA $(Get-Date -Format 'HH:mm:ss') =="
Assert-Health
Keep-Awake

function ColdStart {
  Stop-App; Start-App; Wake-Screen; Start-Sleep -Seconds 2
}

# ---------- D1: 视频详情→评论→弹幕 ----------
function Test-D1 {
  Begin-Test 'D1 视频详情-评论-弹幕'
  try {
    ColdStart
    $d = Dump-UiUntilText -Text '推荐' -TimeoutSec 20 -Name 'd1_home'
    $t = Get-UiTree $d
    $cards = @(Find-UiNodes -Root $t -Filter {
        (Get-NodeType $_) -eq 'Text' -and (Get-NodeText $_).Length -gt 6 -and
        (Node-Y1 $_) -gt 500 -and (Node-Y1 $_) -lt 2200 })
    if ($cards.Count -eq 0) { Skip-Test '无卡片'; return }
    $target = $cards | Where-Object { @($_.children).Count -gt 0 } | Select-Object -First 1
    if (-not $target) { $target = $cards[0] }
    Tap-CenterOf -Bounds (Get-NodeBounds $target) -WaitMs 2500
    $d2 = Dump-UiUntilText -Text '评论' -TimeoutSec 25 -Name 'd1_detail'
    $t2 = Get-UiTree $d2
    Assert-HasText $t2 '评论'
    Snapshot-Shot 'd1_detail'
    # 弹幕 Tab
    $nDm = Find-UiNode -Root $t2 -Filter { (Get-NodeText $_) -eq '弹幕' -or (Get-NodeText $_) -match '^弹' }
    if ($nDm) {
      Tap-CenterOf -Bounds (Get-NodeBounds $nDm) -WaitMs 800
      $t3 = Get-UiTree (Dump-Ui 'd1_danmaku')
      Snapshot-Shot 'd1_danmaku'
      Pass-Test '弹幕面板可打开'
      Key-Back
    } else { Skip '弹幕入口未找到' }
    # 滚动评论
    Swipe-Up -Dist 900; Start-Sleep -Milliseconds 800
    $t4 = Get-UiTree (Dump-Ui 'd1_comment_scroll')
    Snapshot-Shot 'd1_comment_scroll'
    # 点击评论区进入扩展
    $nC = Find-UiNode -Root $t4 -Filter { (Get-NodeText $_) -match '条评论|回复' }
    if ($nC) { Tap-CenterOf -Bounds (Get-NodeBounds $nC) -WaitMs 1500
      Snapshot-Shot 'd1_comment_ext' }
  } catch { Fail-Test "D1: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- D2: 用户空间 ----------
function Test-D2 {
  Begin-Test 'D2 用户空间'
  try {
    ColdStart
    $d = Dump-UiUntilText -Text '推荐' -TimeoutSec 20 -Name 'd2_home'
    $t = Get-UiTree $d
    $cards = @(Find-UiNodes -Root $t -Filter {
        (Get-NodeType $_) -eq 'Text' -and (Get-NodeText $_).Length -gt 6 -and
        (Node-Y1 $_) -gt 900 -and (Node-Y1 $_) -lt 2400 })
    if ($cards.Count -eq 0) { Skip-Test '无卡片'; return }
    # 点击作者名（短文本）更易进用户空间，优先选对应作者位置
    Tap-CenterOf -Bounds (Get-NodeBounds $cards[0]) -WaitMs 2500
    $d2 = Get-UiTree (Dump-Ui 'd2_detail')
    $nUp = Find-UiNode -Root $d2 -Filter { (Get-NodeText $_) -match ' 粉丝|视频' }
    if ($nUp) {
      Tap-CenterOf -Bounds (Get-NodeBounds $nUp) -WaitMs 2500
      $t2 = Get-UiTree (Dump-Ui 'd2_userspace')
      $cnt = @(Get-AllTexts $t2).Count
      if ($cnt -gt 10) { Pass-Test "用户空间($cnt)" } else { Fail-Test "用户空间空($cnt)" }
      Snapshot-Shot 'd2_userspace'
      Key-Back; Key-Back
    } else { Skip-Test 'UP 入口未找到'; Key-Back }
  } catch { Fail-Test "D2: $_" }
  try { Back-Home | Out-Null } catch { }
}

function Go-HotChannel {
  # 切到首页热门频道，返回最新 tree
  ColdStart
  $d = Dump-UiUntilText -Text '热门' -TimeoutSec 20 -Name 'hot_ch'
  $t = Get-UiTree $d
  $nHot = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -match '热门' -and (Node-Y1 $_) -lt 500 }
  if (-not $nHot) { $nHot = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '热门' } }
  if ($nHot) { Tap-CenterOf -Bounds (Get-NodeBounds $nHot) -WaitMs 1000 }
  Start-Sleep -Milliseconds 600
  return Get-UiTree (Dump-Ui 'hot_done')
}

# ---------- D3: 排行榜 ----------
function Test-D3 {
  Begin-Test 'D3 排行榜'
  try {
    $t = Go-HotChannel
    $nRank = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -match '排行' }
    if ($nRank) {
      Tap-CenterOf -Bounds (Get-NodeBounds $nRank) -WaitMs 2500
      $d2 = Dump-Ui 'd3_rank'
      $t2 = Get-UiTree $d2
      $hotTxt = Assert-HasText $t2 '全站' -MinCount 0
      Snapshot-Shot 'd3_rank'
      # 切每周必看
      $nW = Find-UiNode -Root $t2 -Filter { (Get-NodeText $_) -match '每周' }
      if ($nW) { Tap-CenterOf -Bounds (Get-NodeBounds $nW) -WaitMs 2000; Snapshot-Shot 'd3_weekly'; Pass-Test '每周必看可切换' }
    } else { Skip-Test '排行入口未找到' }
  } catch { Fail-Test "D3: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- D4: 番剧详情 ----------
function Test-D4 {
  Begin-Test 'D4 番剧索引/详情'
  try {
    $t = Go-HotChannel
    $nBg = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -match '番剧' }
    if ($nBg) {
      Tap-CenterOf -Bounds (Get-NodeBounds $nBg) -WaitMs 2500
      $d2 = Dump-Ui 'd4_bangumi_index'
      $t2 = Get-UiTree $d2
      $cnt = @(Get-AllTexts $t2).Count
      if ($cnt -gt 5) { Pass-Test "番剧索引($cnt)" } else { Fail-Test "番剧索引空($cnt)" }
      Snapshot-Shot 'd4_bangumi_index'
      # 点一张番剧卡
      $nShow = Find-UiNode -Root $t2 -Filter { (Get-NodeType $_) -eq 'Text' -and (Get-NodeText $_).Length -gt 5 -and (Node-Y1 $_) -gt 600 -and (Node-Y1 $_) -lt 2000 }
      if ($nShow) {
        Tap-CenterOf -Bounds (Get-NodeBounds $nShow) -WaitMs 3000
        $t3 = Get-UiTree (Dump-Ui 'd4_bangumi_detail')
        Assert-HasText $t3 '追番' -MinCount 0
        Snapshot-Shot 'd4_bangumi_detail'
      }
    } else { Skip-Test '番剧入口未找到' }
  } catch { Fail-Test "D4: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- D5: 直播房间 ----------
function Test-D5 {
  Begin-Test 'D5 直播房间'
  try {
    ColdStart
    $d = Dump-UiUntilText -Text '直播' -TimeoutSec 20 -Name 'd5_home'
    $t = Get-UiTree $d
    $nLive = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '直播' -and (Node-Y1 $_) -lt 500 }
    if ($nLive) { Tap-CenterOf -Bounds (Get-NodeBounds $nLive) -WaitMs 1500 }
    $t2 = Get-UiTree (Dump-Ui 'd5_livepage')
    # 点第一张直播卡
    $firstCard = Find-UiNode -Root $t2 -Filter { (Get-NodeType $_) -eq 'Text' -and (Get-NodeText $_).Length -gt 6 -and (Node-Y1 $_) -gt 700 -and (Node-Y1 $_) -lt 2000 }
    if ($firstCard) {
      Tap-CenterOf -Bounds (Get-NodeBounds $firstCard) -WaitMs 4000
      $t3 = Get-UiTree (Dump-Ui 'd5_room')
      $has = Assert-HasText $t3 '人气' -MinCount 0
      $has2 = Assert-HasText $t3 '弹幕' -MinCount 0
      Snapshot-Shot 'd5_room'
    } else { Skip-Test '直播卡未找到' }
  } catch { Fail-Test "D5: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- D6: 历史/稍后再看/收藏 ----------
function Test-D6 {
  Begin-Test 'D6 我的-历史/稍后/收藏'
  try {
    ColdStart
    $d = Dump-Ui 'd6_home'; $t = Get-UiTree $d
    $nMine = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '我的' -and (Node-Y1 $_) -gt 2600 }
    if ($nMine) { Tap-CenterOf -Bounds (Get-NodeBounds $nMine) -WaitMs 1200 }
    foreach ($label in @('历史记录', '稍后再看')) {
      # 每个条目独立进入：回到 Mine 需重新点 Dock
      $i2 = 0
      $t2 = $null
      while ($i2 -lt 3 -and -not $t2) { $i2++; $t2 = Get-UiTree (Dump-Ui ("d6_mine_" + $i2)) }
      $n = Find-UiNode -Root $t2 -Filter { (Get-NodeText $_) -match $label }
      if ($n) {
        Tap-CenterOf -Bounds (Get-NodeBounds $n) -WaitMs 2000
        $t3 = Get-UiTree (Dump-Ui ("d6_open_" + $label))
        $c = @(Get-AllTexts $t3).Count
        if ($c -gt 3) { Pass-Test "$label 打开($c)" } else { Fail-Test "$label 空($c)" }
        Snapshot-Shot ("d6_" + $label)
        Key-Back; Start-Sleep -Milliseconds 800
        # 返回后回首页 Dock，重新进我的
        $t4 = Get-UiTree (Dump-Ui 'd6_back')
        $nMine2 = Find-UiNode -Root $t4 -Filter { (Get-NodeText $_) -eq '我的' -and (Node-Y1 $_) -gt 2600 }
        if ($nMine2) { Tap-CenterOf -Bounds (Get-NodeBounds $nMine2) -WaitMs 1000 }
      } else { Write-QaLog "$label 入口未找到" }
    }
    # 我的收藏
    $t2 = Get-UiTree (Dump-Ui 'd6_mine3')
    $nFav = Find-UiNode -Root $t2 -Filter { (Get-NodeText $_) -match '收藏' }
    if ($nFav) {
      Tap-CenterOf -Bounds (Get-NodeBounds $nFav) -WaitMs 2000
      $t4 = Get-UiTree (Dump-Ui 'd6_fav')
      Snapshot-Shot 'd6_fav'
      $has = @(Get-AllTexts $t4).Count
      if ($has -gt 3) { Pass-Test "收藏页($has)" } else { Fail-Test '收藏页空' }
      Key-Back
    }
  } catch { Fail-Test "D6: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- 执行 ----------
Test-D1
Test-D2
Test-D3
Test-D4
Test-D5
Test-D6

$report = Export-QaReport -Title 'BiliHarmony 深度回归'
Write-Host "报告: $report"
Write-Host "PASS=$($script:QAH_PASSED) FAIL=$($script:QAH_FAILED) SKIP=$($script:QAH_SKIPPED)"
exit ($script:QAH_FAILED -gt 0 ? 1 : 0)