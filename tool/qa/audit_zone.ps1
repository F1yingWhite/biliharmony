# ============================================================
# BiliHarmony UI 间距/对齐专项审计
# 检查页面结构性对齐：
#   Z1. Dock 三图标等距（对称中心）
#   Z2. 列表行 x 对齐（同屏文本行的左缘聚类一致性，容差 8px）
#   Z3. 卡片列 margin 一致性（最左/最右文本 x1/x2 与屏幕边距）
# 用法: pwsh -File tool\qa\audit_zone.ps1 [-DumpFile xxx.json]
# ============================================================
param([string]$DumpFile = '')
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'driver.ps1')
$script:QAH_SHOT_DIR = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.emulator\qa'
$screenW = 1320; $screenH = 2848

function Audit-Zone {
  param([string]$Path, [string]$Label)
  $t = Get-UiTree $Path
  $texts = @(Find-UiNodes -Root $t -Filter { (Get-NodeType $_) -eq 'Text' -and (Get-NodeText $_) -ne '' })
  Write-QaLog "== 间距/对齐审计 $Label =="

  # Z1 Dock 三栏
  $dock = @(Find-UiNodes -Root $t -Filter { (Get-NodeText $_) -in @('首页','动态','我的') -and (Node-Y1 $_) -gt 2600 })
  if ($dock.Count -eq 3) {
    $cxs = @()
    foreach ($n in $dock) { $b = Parse-Bounds (Get-NodeBounds $n); $cxs += [int](($b.x1 + $b.x2) / 2) }
    $d0 = $cxs[1] - $cxs[0]
    $d1 = $cxs[2] - $cxs[1]
    if ([Math]::Abs($d0 - $d1) -le 8) { Write-QaLog "  Dock 三栏等距 ✓ ($($cxs -join ',') 间距 $d0/$d1)" }
    else { Write-QaLog "  Dock 三栏不等距 ✗ ($($cxs -join ',') 间距 $d0/$d1)" }
  } else { Write-QaLog "  Dock 未找到完整三栏($($dock.Count))" }

  # Z2 行首列对齐: 采样 y 中部、文本长度≥6 的行, 按 y 分带检查 x1 聚合
  $bands = @{}
  foreach ($n in $texts) {
    $b = Parse-Bounds (Get-NodeBounds $n)
    if (-not $b) { continue }
    if ($b.y1 -lt 400 -or $b.y1 -gt 2600) { continue }
    $tx = (Get-NodeText $n)
    if ($tx.Length -lt 6) { continue }
    $rk = [int]($b.y1 / 120) * 120
    $key = "$rk"
    if (-not $bands.ContainsKey($key)) { $bands[$key] = New-Object System.Collections.ArrayList }
    [void]$bands[$key].Add($b.x1)
  }
  $misalign = New-Object System.Collections.ArrayList
  foreach ($k in $bands.Keys) {
    $xs = @($bands[$k] | Sort-Object -Unique)
    if ($xs.Count -lt 3) { continue }
    for ($i = 1; $i -lt $xs.Count; $i++) {
      if (($xs[$i] - $xs[$i-1]) -gt 40) {  # 同一 y 带内出现 2 个明显间距的起始列
        # 只关心 3 个以上样本且多数集中在同一列
        continue
      }
    }
    $mode = $xs | Group-Object | Sort-Object Count -Descending | Select-Object -First 1
    $off = @($xs | Where-Object { $_ -ne $mode.Name -and $_ -lt ([int]$mode.Name + 20) })
    if ($off.Count -gt 0 -and $xs.Count -ge 4) {
      $dev = ($xs | ForEach-Object { [Math]::Abs($_ - [int]$mode.Name) } | Measure-Object -Average).Average
      if ($dev -gt 6) { [void]$misalign.Add("y=$k 左缘 $($xs -join ',') 偏差均值 $([int]$dev)px") }
    }
  }
  if ($misalign.Count -eq 0) { Write-QaLog "  行首对齐 ✓" }
  else { foreach ($m in $misalign) { Write-QaLog "  行首对齐 ✗ $m" } }

  # Z3 内容左/右边缘（卡片回贴边留白）
  $edges = @()
  foreach ($n in $texts) {
    $b = Parse-Bounds (Get-NodeBounds $n)
    if (-not $b -or $b.y1 -lt 400 -or $b.y1 -gt 2600) { continue }
    if ((Get-NodeText $n).Length -lt 8) { continue }
    $edges += $b.x1
  }
  if ($edges.Count -gt 0) {
    $sorted = @($edges | Sort-Object)
    $minEdge = $sorted | Select-Object -First 1
    $maxEdge = $sorted | Select-Object -Last 1
    $marginL = $minEdge
    $marginR = $screenW - $maxEdge
    Write-QaLog "  内容边缘: 最左 $minEdge 最右 $maxEdge (左右留白 $marginL/$marginR)"
  }
}

# ---------- 主 ----------
if ($DumpFile) {
  Audit-Zone -Path $DumpFile -Label (Split-Path $DumpFile -Leaf)
} else {
  Get-ChildItem $script:QAH_SHOT_DIR -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 8 | ForEach-Object {
    try { Audit-Zone -Path $_.FullName -Label $_.Name } catch { Write-QaLog "fail $($_.Name): $_" }
  }
}
$report = Export-QaReport -Title 'UI 间距/对齐审计'
Write-Host $report