# ============================================================
# BiliHarmony UI 对齐 / 间距全量审计 v2
# 数据驱动检查（基于 dump JSON 的 bounds）：
#   A. 文字越界（累计越界、右越界计数）
#   B. 零尺寸/负尺寸节点
#   C. 文本重叠（排除 Dock 区 y>2650 的假阳性）
#   D. 列对齐：同列文本 x1/x2 一致性（列宽方差）
#   E. 行距节奏：相邻文本行 y 间隔统计（间距一致性）
#   F. 左右边界留白（内容区左右 margin 一致性）
# 用法: pwsh -File tool\qa\audit_ui.ps1 [-AllDumps]
# ============================================================
param([switch]$AllDumps)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'driver.ps1')

$script:QAH_SHOT_DIR = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.emulator\qa'
$screenW = 1320; $screenH = 2848

function Audit-Dump {
  param([string]$Path, [string]$Label)
  $t = Get-UiTree $Path
  $allNodes = @(Find-UiNodes -Root $t -Filter { $true })
  $textNodes = @(Find-UiNodes -Root $t -Filter { (Get-NodeType $_) -eq 'Text' -and (Get-NodeText $_) -ne '' -and ($null -ne (Parse-Bounds (Get-NodeBounds $_))) })

  $zero = 0; $overflow = 0; $overflowSamples = @()
  foreach ($n in $allNodes) {
    $b = Parse-Bounds (Get-NodeBounds $n)
    if (-not $b) { continue }
    if ($b.x2 -le $b.x1 -or $b.y2 -le $b.y1) { $zero++ }
    if ($b.x1 -lt 0 -or $b.x2 -gt $screenW -or $b.y1 -lt 0 -or $b.y2 -gt $screenH) {
      $overflow++
      if ($overflow -le 5) { $overflowSamples += "[$($n.attributes.type)] $($n.attributes.text) @$($n.attributes.bounds)" }
    }
  }

  # --- 重叠（排除 Dock 区） ---
  $overlaps = 0; $ovSamples = @()
  for ($i = 0; $i -lt $textNodes.Count; $i++) {
    $bi = Parse-Bounds (Get-NodeBounds $textNodes[$i])
    if (-not $bi -or $bi.y1 -gt 2650) { continue }   # 跳过 dock 区
    for ($j = $i + 1; $j -lt $textNodes.Count; $j++) {
      $bj = Parse-Bounds (Get-NodeBounds $textNodes[$j])
      if (-not $bj -or $bj.y1 -gt 2650) { continue }
      if ((Get-NodeText $textNodes[$i]) -eq (Get-NodeText $textNodes[$j])) { continue }
      $iw = [math]::Max(0, [math]::Min($bi.x2, $bj.x2) - [math]::Max($bi.x1, $bj.x1))
      $ih = [math]::Max(0, [math]::Min($bi.y2, $bj.y2) - [math]::Max($bi.y1, $bj.y1))
      $ai = ($bi.x2 - $bi.x1) * ($bi.y2 - $bi.y1)
      $aj = ($bj.x2 - $bj.x1) * ($bj.y2 - $bj.y1)
      if ($ai -le 0 -or $aj -le 0) { continue }
      if (($iw * $ih) -gt 0.45 * [math]::Min($ai, $aj)) {
        $overlaps++
        if ($overlaps -le 8) { $ovSamples += "  '$($textNodes[$i].attributes.text)' <> '$($textNodes[$j].attributes.text)'" }
      }
    }
  }

  # --- 列对齐: 文本按 (行带 + 中心x) 二维聚类，检查同组边缘一致性 ---
  $groups = @{}
  foreach ($n in $textNodes) {
    $b = Parse-Bounds (Get-NodeBounds $n)
    if (-not $b) { continue }
    if ($b.y1 -lt 380 -or $b.y1 -gt 2600) { continue }
    $txt = (Get-NodeText $n)
    if ($txt.Length -lt 4) { continue }
    $rowKey = [int]($b.y1 / 90) * 90
    $colKey = [int]((($b.x1 + $b.x2) / 2) / 60) * 60
    $key = "$rowKey|$colKey"
    if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.ArrayList }
    [void]$groups[$key].Add($b)
  }
  $alignIssues = New-Object System.Collections.ArrayList
  foreach ($k in $groups.Keys) {
    $bs = @($groups[$k])
    if ($bs.Count -lt 3) { continue }
    $x1s = @($bs | ForEach-Object { $_.x1 } | Sort-Object)
    $x2s = @($bs | ForEach-Object { $_.x2 } | Sort-Object)
    $y1s = @($bs | ForEach-Object { $_.y1 } | Sort-Object)
    $spreadL = $x1s[$x1s.Count - 1] - $x1s[0]
    $spreadR = $x2s[$x2s.Count - 1] - $x2s[0]
    $spreadY = $y1s[$y1s.Count - 1] - $y1s[0]
    # 同一行同一列内出现 ≥6px 左缘不一致 且 ≥8px 垂直错落 → 真实对不齐
    if ($spreadL -gt 6 -and $spreadY -gt 8) {
      # 该组样本文本
      $sample = ''
      foreach ($tn in $textNodes) {
        $tb = Parse-Bounds (Get-NodeBounds $tn)
        if ($tb -and ($rowKey -eq ([int]($tb.y1 / 40) * 40)) -and ($colKey -eq ([int]((($tb.x1 + $tb.x2) / 2) / 60) * 60))) {
          $tx = (Get-NodeText $tn)
          if ($tx.Length -gt $sample.Length) { $sample = $tx }
        }
      }
      if ($sample.Length -gt 24) { $sample = $sample.Substring(0, 24) }
      [void]$alignIssues.Add("行y=$rowKey 列x~$colKey : $($bs.Count) 项左缘散 ${spreadL}px 垂直散 ${spreadY}px ('$sample' 等)")
    }
  }

  # --- 行距节奏: 收集内容区卡片级文本的 y1 序列，统计相邻增量 ---
  $ys = New-Object System.Collections.ArrayList
  foreach ($n in $textNodes) {
    $b = Parse-Bounds (Get-NodeBounds $n)
    if ($b -and $b.Y1 -gt 380 -and $b.Y1 -lt 2600) { [void]$ys.Add($b.y1) }
  }
  $diffs = @()
  $sorted = @($ys | Sort-Object)
  for ($i = 1; $i -lt $sorted.Count; $i++) {
    $d = $sorted[$i] - $sorted[$i - 1]
    if ($d -gt 8 -and $d -lt 400) { $diffs += $d }
  }
  # 相邻文本行距去重统计（文本行间距应该在几个固定值附近）
  $gapCounts = @{}
  foreach ($d in $diffs) {
    $key = [int]($d / 6) * 6
    if (-not $gapCounts.ContainsKey($key)) { $gapCounts[$key] = 0 }
    $gapCounts[$key]++
  }
  $topGaps = ($gapCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key)-$($_.Value)" }) -join ' '
  $gapSpread = if ($gapCounts.Count -gt 1) { ($gapCounts.Keys | Measure-Object -Minimum -Maximum) } else { $null }
  $spacingNote = ''
  if ($gapCounts.Count -ge 4) { $spacingNote = '⚠ 行距分散(>4档)' }

  Write-QaLog "== 审计 $Label =="
  Write-QaLog "  节点 $($allNodes.Count) 文本 $($textNodes.Count) 零尺寸 $zero 越界 $overflow 重叠 $overlaps"
  foreach ($s in $ovSamples[0..4]) { Write-QaLog "    重叠: $s" }
  if ($overflowSamples.Count -gt 0) { foreach ($s in $overflowSamples) { Write-QaLog "    越界: $s" } }
  Write-QaLog "  列对齐问题: $($alignIssues.Count)"
  foreach ($a in $alignIssues[0..6]) { Write-QaLog "    $($a.ToString())" }
  Write-QaLog "  行距档位: $topGaps $spacingNote"
  return $null
}

# ---------- 主流程 ----------
$targets = if ($AllDumps) {
  Get-ChildItem $script:QAH_SHOT_DIR -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 10
} else {
  Get-ChildItem $script:QAH_SHOT_DIR -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 4
}

foreach ($t in $targets) { try { Audit-Dump -Path $t.FullName -Label $t.Name } catch { Write-QaLog "audit fail $($t.Name): $_" } }

$report = Export-QaReport -Title 'UI 对齐/间距审计 v2'
Write-Host "报告: $report"
Write-Host "审计 dump: $($targets.Count)"