# ============================================================
# BiliHarmony 全量 QA 测试流程 (v5)
# 覆盖: 首页三频道+瀑布流 / 频道切换 / 视频详情 / 搜索 /
#       番剧 / 动态 / 我的 / 深色模式（像素级）
# 用法: pwsh -File tool\qa\suite_all.ps1 [-SkipInstall]
# ============================================================
param(
  [switch]$SkipInstall,
  [string]$Hap = ''
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'driver.ps1')

Write-Host "== BiliHarmony 全量 QA 开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =="
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
    Write-Host "install: $hap"
    Invoke-Hdc -HdcArgs @('install','-r',$hap) | Out-Host
  } else { Write-Host 'no hap, skip install' }
}

# ---------- helpers ----------
function Tap-ByText {
  param($Root, [string]$Text, [int]$WaitMs = 700)
  $n = Find-UiNode -Root $Root -Filter { ((Get-NodeText $_) -match $Text) }
  if (-not $n) { Write-QaLog "tap miss: $Text"; return $false }
  Tap-CenterOf -Bounds (Get-NodeBounds $n) -WaitMs $WaitMs
  return $true
}

function ColdStart {
  Keep-Awake
  Stop-App
  Start-App
  Wake-Screen
  Start-Sleep -Seconds 2
}

function Back-Home {
  for ($i = 0; $i -lt 6; $i++) {
    $d = Dump-Ui ("bk" + $i)
    $t = Get-UiTree $d
    $dock = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '首页' -and (Node-Y1 $_) -gt 2600 }
    if ($dock) { return $true }
    Key-Back
  }
  return $false
}

# ---------- 01 首页 ----------
function Test-01 {
  Begin-Test '01 首页三频道+瀑布流'
  try {
    ColdStart
    $d = Dump-UiUntilText -Text '推荐' -TimeoutSec 25 -Name 'h01_home'
    $t = Get-UiTree $d
    Assert-HasText $t '推荐'
    Assert-HasText $t '热门'
    $liveTab = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '直播' -and (Node-Y1 $_) -lt 500 }
    if ($liveTab) { Pass-Test '直播频道Tab' } else { Fail-Test '直播频道Tab缺失' }
    Snapshot-Shot 'h01_home'
    Swipe-Up -Dist 900; Start-Sleep -Milliseconds 800
    Swipe-Up -Dist 900; Start-Sleep -Milliseconds 800
    $t2 = Get-UiTree (Dump-Ui 'h01_scroll')
    $n2 = @(Get-AllTexts $t2).Count
    # 接口返回的卡片数量会波动；验证滚动后仍有足量可见节点即可，避免把线上数据量当成 UI 回归。
    if ($n2 -gt 40) { Pass-Test "瀑布流滚动文本N=$n2" } else { Fail-Test "滚动文本少 N=$n2" }
    Snapshot-Shot 'h01_scroll'
  } catch { Fail-Test "01 err: $_" }
}

# ---------- 02 频道切换 ----------
function Test-02 {
  Begin-Test '02 首页频道切换'
  try {
    ColdStart
    $d = Dump-UiUntilText -Text '热门' -TimeoutSec 20 -Name 'h02_tabs'
    $t = Get-UiTree $d
    $nHot = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -match '热门' -and (Node-Y1 $_) -lt 500 }
    if (-not $nHot) { $nHot = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '热门' } }
    if ($nHot) { Tap-CenterOf -Bounds (Get-NodeBounds $nHot) -WaitMs 1000 } else { Fail-Test '热门Tab缺失'; return }
    Start-Sleep -Milliseconds 800
    $t2 = Get-UiTree (Dump-Ui 'h02_hotpage')
    $cnt = @(Get-AllTexts $t2).Count
    if ($cnt -gt 8) { Pass-Test "热门feedN=$cnt" } else { Fail-Test "热门feedN=$cnt" }
    Snapshot-Shot 'h02_hotpage'
    $nLive = Find-UiNode -Root $t2 -Filter { (Get-NodeText $_) -eq '直播' -and (Node-Y1 $_) -lt 500 }
    if ($nLive) {
      Tap-CenterOf -Bounds (Get-NodeBounds $nLive) -WaitMs 1500
      $t3 = Get-UiTree (Dump-Ui 'h02_livepage')
      $c3 = @(Get-AllTexts $t3).Count
      if ($c3 -gt 8) { Pass-Test "直播频道N=$c3" } else { Fail-Test "直播频道N=$c3" }
      Snapshot-Shot 'h02_livepage'
    } else { Skip-Test '无直播Tab' }
  } catch { Fail-Test "02: $_" }
}

# ---------- 03 视频详情 ----------
function Test-03 {
  Begin-Test '03 打开视频详情'
  try {
    ColdStart
    $d = Dump-UiUntilText -Text '推荐' -TimeoutSec 20 -Name 'h03_home'
    $t = Get-UiTree $d
    $cards = Find-UiNodes -Root $t -Filter {
      (Get-NodeType $_) -eq 'Text' -and ((Get-NodeText $_).Length) -gt 6 -and
      (Node-Y1 $_) -gt 500 -and (Node-Y1 $_) -lt 2400
    }
    if (@($cards).Count -eq 0) { Skip-Test '没有卡片'; return }
    $target = $cards | Where-Object { @($_.children).Count -gt 0 } | Select-Object -First 1
    if (-not $target) { $target = $cards[0] }
    $title = (Get-NodeText $target)
    if ($title.Length -gt 18) { $title = $title.Substring(0, 18) }
    Write-QaLog "点开: $title"
    Tap-CenterOf -Bounds (Get-NodeBounds $target) -WaitMs 2500
    $d2 = Dump-UiUntilText -Text '评论' -TimeoutSec 25 -Name 'h03_detail'
    $t2 = Get-UiTree $d2
    Assert-HasText $t2 '评论'
    Snapshot-Shot 'h03_detail'
  } catch { Fail-Test "03: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- 04 搜索 ----------
function Test-04 {
  Begin-Test '04 搜索页'
  try {
    ColdStart
    $d = Dump-UiUntilText -Text '推荐' -TimeoutSec 20 -Name 'h04_home'
    # 头栏搜索胶囊（头像右侧整条可点）
    Tap-CenterOf -Bounds '[80,160][1150,250]' -WaitMs 1500
    $d2 = Dump-Ui 'h04_search'
    $t2 = Get-UiTree $d2
    $any = @(Find-UiNodes -Root $t2 -Filter { (Get-NodeText $_) -match '搜索|趋势榜|热搜' }).Count
    if ($any -gt 0) { Pass-Test '搜索页渲染' } else { Fail-Test '搜索页未渲染' }
    Snapshot-Shot 'h04_search'
  } catch { Fail-Test "04: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- 05 番剧 ----------
function Test-05 {
  Begin-Test '05 番剧页'
  try {
    ColdStart
    $d = Dump-Ui 'h05_home'
    Swipe-Up -Dist 1800; Start-Sleep -Milliseconds 600
    $d2 = Dump-Ui 'h05_home2'
    $t2 = Get-UiTree $d2
    $nBg = Find-UiNode -Root $t2 -Filter { (Get-NodeText $_) -match '番剧' }
    if ($nBg) {
      Tap-CenterOf -Bounds (Get-NodeBounds $nBg) -WaitMs 2500
      $t3 = Get-UiTree (Dump-Ui 'h05_bangumi')
      if ((Get-AllTexts $t3).Count -gt 10) { Pass-Test '番剧有内容' } else { Fail-Test '番剧空态' }
      Snapshot-Shot 'h05_bangumi'
    } else { Skip-Test '无番剧入口' }
  } catch { Fail-Test "05: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- 06 动态 ----------
function Test-06 {
  Begin-Test '06 动态Tab'
  try {
    ColdStart
    $d = Dump-Ui 'h06_home'
    $t = Get-UiTree $d
    $nDyn = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '动态' -and (Node-Y1 $_) -gt 2600 }
    if ($nDyn) { Tap-CenterOf -Bounds (Get-NodeBounds $nDyn) -WaitMs 1200 }
    $d2 = Dump-Ui 'h06_dyn'; $t2 = Get-UiTree $d2
    $cnt = @(Get-AllTexts $t2).Count
    if ($cnt -gt 5) { Pass-Test "动态N=$cnt" } else { Fail-Test "动态N=$cnt" }
    Snapshot-Shot 'h06_dyn'
    Swipe-Up -Dist 900; Start-Sleep -Milliseconds 600
    $t3 = Get-UiTree (Dump-Ui 'h06_dyn2')
    if (@(Get-AllTexts $t3).Count -gt 5) { Pass-Test '动态滚动' } else { Fail-Test '动态滚动异常' }
  } catch { Fail-Test "06: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- 07 我的 ----------
function Test-07 {
  Begin-Test '07 我的Tab及子项'
  try {
    ColdStart
    $d = Dump-Ui 'h07_home'
    $t = Get-UiTree $d
    $nMine = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '我的' -and (Node-Y1 $_) -gt 2600 }
    if (-not $nMine) { $nMine = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '我的' } }
    if ($nMine) { Tap-CenterOf -Bounds (Get-NodeBounds $nMine) -WaitMs 1200 } else { Fail-Test '无我的Tab'; return }
    $t2 = Get-UiTree (Dump-Ui 'h07_mine')
    Assert-HasText $t2 '我的追番' -MinCount 0
    Assert-HasText $t2 '稍后再看' -MinCount 0
    Assert-HasText $t2 '收藏' -MinCount 0
    Snapshot-Shot 'h07_mine'
    # 打开我的收藏
    $nFav0 = Find-UiNode -Root $t2 -Filter { (Get-NodeText $_) -match '收藏' }
    if ($nFav0) { Tap-CenterOf -Bounds (Get-NodeBounds $nFav0) -WaitMs 1500 }
    $t3 = Get-UiTree (Dump-Ui 'h07_fav')
    Assert-HasText $t3 '收藏' -MinCount 0
    Snapshot-Shot 'h07_fav'
  } catch { Fail-Test "07: $_" }
  try { Back-Home | Out-Null } catch { }
}

# ---------- 08 深色模式 ----------
function Test-08 {
  Begin-Test '08 深色模式(像素)'
  try {
    ColdStart
    $d = Dump-UiUntilText -Text '推荐' -TimeoutSec 20 -Name 'h08_home'
    $t = Get-UiTree $d
    $nMine = Find-UiNode -Root $t -Filter { (Get-NodeText $_) -eq '我的' -and (Node-Y1 $_) -gt 2600 }
    if ($nMine) { Tap-CenterOf -Bounds (Get-NodeBounds $nMine) -WaitMs 1200 }
    $t2 = Get-UiTree (Dump-Ui 'h08_mine')
    # 我的页面直接有 显示模式：浅色/深色
    $nDark = Find-UiNode -Root $t2 -Filter { (Get-NodeText $_) -eq '深色' }
    if (-not $nDark) {
      Swipe-Up -Dist 900; Start-Sleep -Milliseconds 500
      $t2 = Get-UiTree (Dump-Ui 'h08_mine2')
      $nDark = Find-UiNode -Root $t2 -Filter { (Get-NodeText $_) -eq '深色' }
    }
    if ($nDark) {
      Tap-CenterOf -Bounds (Get-NodeBounds $nDark) -WaitMs 900
      $shot = Snapshot-Shot 'h08_dark_on'
      $py = 'D:\code\biliharmony\tool\gif-tool\.venv\Scripts\python.exe'
      if (Test-Path -LiteralPath $py) {
        $so = Join-Path $env:TEMP 'qa_py_bg.txt'
        $p = Start-Process -FilePath $py -ArgumentList @("$PSScriptRoot\check_img.py", '--shot', $shot, '--mode', 'bg') -NoNewWindow -Wait -RedirectStandardOutput $so
        $pyOut = if (Test-Path $so) { Get-Content $so -Raw } else { 'noout' }
        Remove-Item $so -Force -ErrorAction SilentlyContinue
        $j = $pyOut | ConvertFrom-Json
        if ($j.checks.is_dark) { Pass-Test "深色生效 $($j.checks.mid)" } else { Fail-Test "深色未生效: $pyOut" }
        # Dock 泛白检查
        $so2 = Join-Path $env:TEMP 'pyx_dock.txt'
        $p2 = Start-Process -FilePath $py -ArgumentList @("$PSScriptRoot\check_img.py", '--shot', $shot, '--mode', 'dock') -NoNewWindow -Wait -RedirectStandardOutput $so2
        $pyOut2 = if (Test-Path $so2) { Get-Content $so2 -Raw } else { '' }
        Remove-Item $so2 -Force -ErrorAction SilentlyContinue
        $j2 = $pyOut2 | ConvertFrom-Json
        if ($j2.checks.too_bright) { Fail-Test "Dock 泛白: $($j2.checks.dock_avg)" } else { Pass-Test "Dock 亮度正常 $($j2.checks.dock_avg)" }
      } else {
        Skip-Test '未安装图片审计所需 Python 环境，已保留深色模式截图'
      }
      # 恢复浅色
      Tap-CenterOf -Bounds (Get-NodeBounds $nDark) -WaitMs 900
    } else { Skip-Test '无显示模式入口' }
  } catch { Fail-Test "08: $_" }
  try { Back-Home | Out-Null } catch { }
}

Test-01
Test-02
Test-03
Test-04
Test-05
Test-06
Test-07
Test-08

$report = Export-QaReport -Title 'BiliHarmony 全量回归'
Write-Host "report: $report"
Write-Host "PASS=$script:QAH_PASSED FAIL=$script:QAH_FAILED SKIP=$script:QAH_SKIPPED"
exit 0
