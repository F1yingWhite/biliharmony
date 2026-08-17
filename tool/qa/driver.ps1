# ============================================================
# BiliHarmony QA 驱动层 (PowerShell + hdc + uitest)
#   依赖: DevEco Studio 自带 hdc.exe, 已连接模拟器/真机
#   用法: 由 run_qa.ps1 / suite_all.ps1 导入，. (dot-source) 引入
# ============================================================
$script:QAH_HDC = if ($env:QA_HDC) { $env:QA_HDC } else { 'D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' }
$script:QAH_APPID = 'com.piliplus.harmony'
$script:QAH_SHOT_DIR = $env:QA_SHOT_DIR
if (-not $script:QAH_SHOT_DIR) {
  $script:QAH_SHOT_DIR = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.emulator\qa'
}
New-Item -ItemType Directory -Force -Path $script:QAH_SHOT_DIR | Out-Null

$script:QAH_ARTIFACTS = @()   # 每个测试产生的截图/dump 记录
$script:QAH_FAILED = 0
$script:QAH_PASSED = 0
$script:QAH_SKIPPED = 0
$script:QAH_CURRENT_TEST = ''
$script:QAH_LOG = New-Object System.Collections.Generic.List[string]

function Write-QaLog([string]$m) { $script:QAH_LOG.Add($m) }

function Invoke-Hdc {
  # 带重试的 hdc 调用。沙箱禁止“管道捕获原生程序 stdout”，
  # 因此用 Start-Process -NoNewWindow 输出重定向到临时文件再读回。
  # 注意：hdc 偶发 ResourceUnavailable/拒绝访问，重试兜底。
  param([Parameter(Mandatory)][string[]]$HdcArgs,
        [int]$Retries = 3,
        [int]$WaitMs = 400)
  $last = $null
  for ($i = 0; $i -lt $Retries; $i++) {
    $so = Join-Path $env:TEMP ("hdc_" + [guid]::NewGuid().ToString('N') + '.txt')
    $se = $so -replace '\.txt$', '.err'
    $p = Start-Process -FilePath $script:QAH_HDC -ArgumentList ($HdcArgs | ForEach-Object { $_ }) `
      -NoNewWindow -Wait -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
    $outTxt = ''
    if (Test-Path $so) { $outTxt = [string](Get-Content $so -Raw -ErrorAction SilentlyContinue) }
    $errTxt = ''
    if (Test-Path $se) { $errTxt = [string](Get-Content $se -Raw -ErrorAction SilentlyContinue) }
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    $all = ($outTxt + ' ' + $errTxt).Trim()
    if ($all -eq '') { $last = '(empty output)'; Start-Sleep -Milliseconds $WaitMs; continue }
    # 成功也可能输出 "No Error"，因此失败信号用小写匹配（区分大小写）
    if ($all -cmatch 'error|fail|denied|invalid|not found|no such|usage:|exception') {
      $last = $all; Start-Sleep -Milliseconds $WaitMs; continue
    }
    return $all
  }
  throw "hdc failed: $($HdcArgs -join ' ') -> $last"
}

# 不关心输出、不重试的 hdc 调用（快路径：点击/输入等注入类）
function Invoke-Hdc-Fire {
  param([Parameter(Mandatory)][string[]]$HdcArgs)
  try { Invoke-Hdc -HdcArgs $HdcArgs -Retries 1 -WaitMs 50 | Out-Null } catch { }
}

function Assert-Health {
  $t = Invoke-Hdc -HdcArgs @('list','targets')
  if ($t -notmatch '5555|localhost|127\.0\.0\.1|emulator') { throw "no device: $t" }
  Write-QaLog "device OK: $t"
}

function Start-App {
  Invoke-Hdc -HdcArgs @('shell','aa','start','-a','EntryAbility','-b',$script:QAH_APPID) | Out-Null
  Start-Sleep -Seconds 3
}

function Stop-App {
  Invoke-Hdc -HdcArgs @('shell','aa','force-stop',$script:QAH_APPID) | Out-Null
  Start-Sleep -Milliseconds 600
}

function ColdStartCore {
  Stop-App
  Start-App
  Start-Sleep -Seconds 2
}

function Wake-Screen {
  try { Invoke-Hdc -HdcArgs @('shell','power-shell','wakeup') | Out-Null } catch { }
  Start-Sleep -Milliseconds 400
}

function Keep-Awake {
  try { Invoke-Hdc -HdcArgs @('shell','power-shell','timeout','-o','7200000') | Out-Null } catch { }
}

function Snapshot-Shot {
  # 截屏并拉回本机, 返回本地文件路径
  param([string]$Name)
  $out = Invoke-Hdc -HdcArgs @('shell','snapshot_display','-f',"/data/local/tmp/$Name.jpeg")
  if ($out -notmatch 'success') { Write-QaLog "shot warn: $out" }
  Start-Sleep -Milliseconds 500
  $local = Join-Path $script:QAH_SHOT_DIR "$Name.jpeg"
  Invoke-Hdc -HdcArgs @('file','recv',"/data/local/tmp/$Name.jpeg",$local) | Out-Null
  $script:QAH_ARTIFACTS += $local
  $local
}

function Dump-Ui {
  # dumpLayout 并拉回本机, 返回 JSON 绝对路径
  param([string]$Name = ('t_' + (Get-Date -Format 'HHmmssfff')))
  $r = $null
  try { $r = Invoke-Hdc -HdcArgs @('shell','uitest','dumpLayout','-p',"/data/local/tmp/$Name.json") } catch { }
  if ($r -notmatch 'DumpLayout saved') { Write-QaLog "dump warn: $r" }
  Start-Sleep -Milliseconds 250
  $local = Join-Path $script:QAH_SHOT_DIR "$Name.json"
  Invoke-Hdc -HdcArgs @('file','recv',"/data/local/tmp/$Name.json",$local) | Out-Null
  $local
}

function Get-UiTree {
  param([Parameter(Mandatory)][string]$JsonPath)
  if (-not (Test-Path $JsonPath)) { throw "dump json missing: $JsonPath" }
  Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

# 轮询 dump 直到出现指定文本（或超时），返回最终 JsonPath；找不到抛异常
function Dump-UiUntilText {
  param([string]$Text, [int]$TimeoutSec = 20, [string]$Name = ('wait_' + (Get-Date -Format 'HHmmssfff')))
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $lastPath = $null
  while ((Get-Date) -lt $deadline) {
    $lastPath = Dump-Ui $Name
    $t = Get-UiTree $lastPath
    $nodes = Find-UiNodes -Root $t -Filter { ((Get-NodeText $_) -match $Text) }
    if (@($nodes).Count -gt 0) { return $lastPath }
    Start-Sleep -Milliseconds 700
  }
  throw "wait text 超时: '$Text' (last=$lastPath)"
}

# 轮询 dump 直到文本节点数量达到阈值（用于等待列表加载/滚动完成）
function Dump-UiUntilRich {
  param([int]$MinTexts = 20, [int]$TimeoutSec = 15, [string]$Name = ('rich_' + (Get-Date -Format 'HHmmssfff')))
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $lastPath = $null
  $lastCount = 0
  while ((Get-Date) -lt $deadline) {
    $lastPath = Dump-Ui $Name
    $t = Get-UiTree $lastPath
    $lastCount = @(Get-AllTexts $t).Count
    if ($lastCount -ge $MinTexts) { return $lastPath }
    Start-Sleep -Milliseconds 600
  }
  Write-QaLog "timeout rich: texts=$lastCount"
  return $lastPath
}

function Push-Artifact { param([string]$Path) $script:QAH_ARTIFACTS += $Path }

function Begin-Test { param([string]$TestName) $script:QAH_CURRENT_TEST = $TestName; Write-QaLog "==> 测试: $TestName" }

function Pass-Test([string]$Detail = '') { $script:QAH_PASSED++; Write-QaLog "PASS  $($script:QAH_CURRENT_TEST) $Detail" }
function Fail-Test([string]$Detail = '') { $script:QAH_FAILED++; Write-QaLog "FAIL  $($script:QAH_CURRENT_TEST) $Detail" }
function Skip-Test([string]$Detail = '') { $script:QAH_SKIPPED++; Write-QaLog "SKIP  $($script:QAH_CURRENT_TEST) $Detail" }

# --- UI 树断言工具 ---
function Get-NodeText { param($n) if ($n.attributes) { $n.attributes.text } else { '' } }
function Get-NodeType { param($n) if ($n.attributes) { $n.attributes.type } else { '' } }
function Get-NodeBounds { param($n) if ($n.attributes) { $n.attributes.bounds } else { '' } }
function Get-NodeAttr { param($n, [string]$k) if ($n.attributes) { $n.attributes.$k } else { '' } }

function Find-UiNodes {
  param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][scriptblock]$Filter)
  $res = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push($Root)
  while ($stack.Count -gt 0) {
    $n = $stack.Pop()
    # 手工把当前节点写进 $_，供 filter 内部引用
    $_ = $n
    if (& $Filter) { [void]$res.Add($n) }
    if ($null -ne $n.children) { foreach ($c in $n.children) { $stack.Push($c) } }
  }
  return $res.ToArray()   # 数组元素进入管道，调用方 @(...) 正确计数
}

function Find-UiNode { param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][scriptblock]$Filter)
  $nodes = Find-UiNodes -Root $Root -Filter $Filter
  if (@($nodes).Count -gt 0) { return $nodes[0] }
  return $null
}

function Filter-Text { param($n) ((Get-NodeText $n) -match $Text) }
function Filter-Type { param($n) ((Get-NodeType $n) -eq $Type) }

# 返回树中所有文本（含 truncated）
function Get-AllTexts {
  param([Parameter(Mandatory)]$Root)
  $txt = New-Object System.Collections.ArrayList
  $nodes = Find-UiNodes -Root $Root -Filter { ($(Get-NodeText $_)) -ne '' }
  foreach ($n in $nodes) { [void]$txt.Add((Get-NodeText $n).Trim()) }
  return $txt.ToArray()
}

function Assert-HasText {
  param($Root, [string]$Text, [int]$MinCount = 1)
  $nodes = Find-UiNodes -Root $Root -Filter { ((Get-NodeText $_) -match $Text) }
  $found = @($nodes).Count
  if ($found -ge $MinCount) { Pass-Test "存在文本 '$Text' (x$found)"; return $true }
  Fail-Test "缺少文本 '$Text' (found=$found)"
  return $false
}

function Assert-NoText {
  param($Root, [string]$Text)
  $nodes = Find-UiNodes -Root $Root -Filter { ((Get-NodeText $_) -match $Text) }
  if (@($nodes).Count -eq 0) { Pass-Test "无异常文本 '$Text'"; return $true }
  Fail-Test "异常出现文本 '$Text'"
  return $false
}

function Parse-Bounds {
  param([string]$Bounds)
  if ($Bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
    return @{ x1=[int]$Matches[1]; y1=[int]$Matches[2]; x2=[int]$Matches[3]; y2=[int]$Matches[4] }
  }
  return $null
}

# ---- 节点几何快捷函数（供 filter scriptblock 使用） ----
function Node-X1 { param($n) $b = Parse-Bounds (Get-NodeBounds $n); if ($b) { return $b.x1 }; return -1 }
function Node-X2 { param($n) $b = Parse-Bounds (Get-NodeBounds $n); if ($b) { return $b.x2 }; return -1 }
function Node-Y1 { param($n) $b = Parse-Bounds (Get-NodeBounds $n); if ($b) { return $b.y1 }; return -1 }
function Node-Y2 { param($n) $b = Parse-Bounds (Get-NodeBounds $n); if ($b) { return $b.y2 }; return -1 }

function Tap-CenterOf {
  param([string]$Bounds, [int]$WaitMs = 350)
  $b = Parse-Bounds $Bounds
  if (-not $b) { throw "bad bounds: $Bounds" }
  $x = [int](($b.x1 + $b.x2) / 2)
  $y = [int](($b.y1 + $b.y2) / 2)
  Invoke-Hdc -HdcArgs @('shell','uitest','uiInput','click',"$x","$y") | Out-Null
  Start-Sleep -Milliseconds $WaitMs
}

function Tap-FirstText {
  param($Root, [string]$Text, [int]$ExtraX = 0, [int]$ExtraY = 0)
  $n = Find-UiNode -Root $Root -Filter { ((Get-NodeText $_) -match $Text) }
  if (-not $n) { throw "tap target text 不存在: '$Text'" }
  Tap-CenterOf -Bounds (Get-NodeBounds $n) -WaitMs 500
}

function Swipe-Up { param([int]$Dist = 500)
  $y1 = 2000; $y2 = 2000 - $Dist
  Invoke-Hdc -HdcArgs @('shell','uitest','uiInput','swipe','660',"$y1",'660',"$y2",'400') | Out-Null
  Start-Sleep -Milliseconds 400
}

function Swipe-Down { param([int]$Dist = 500)
  $y1 = 2000 - $Dist; $y2 = 2200
  Invoke-Hdc -HdcArgs @('shell','uitest','uiInput','swipe','660',"$y1",'660',"$y2",'400') | Out-Null
  Start-Sleep -Milliseconds 400
}

function Key-Back {
  Invoke-Hdc -HdcArgs @('shell','uitest','uiInput','keyEvent','Back') | Out-Null
  Start-Sleep -Milliseconds 400
}

function Extract-Pages {
  # 扫描 dump: 找出页面内所有可点击文本, 返回每行: text|bounds
  param([Parameter(Mandatory)]$Root)
  $lines = New-Object System.Collections.Generic.List[string]
  $nodes = Find-UiNodes -Root $Root -Filter { ($(Get-NodeText $_) -ne '') -or ($(Get-NodeType $_) -eq 'Button' -and $(Get-NodeText $_) -ne '') }
  foreach ($n in $nodes) { [void]$lines.Add("$(Get-NodeText $n)|$(Get-NodeBounds $n)") }
  return ,$lines
}

function Export-QaReport {
  param([string]$Title = 'QA 全量回归报告')
  $md = New-Object System.Collections.Generic.List[string]
  $md.Add("# $Title")
  $md.Add("")
  $md.Add("- 时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
  $md.Add("- 通过: $($script:QAH_PASSED) / 失败: $($script:QAH_FAILED) / 跳过: $($script:QAH_SKIPPED)")
  $md.Add("")
  $md.Add("## 明细")
  $md.Add("")
  foreach ($l in $script:QAH_LOG) { $md.Add("- $l") }
  $out = Join-Path $script:QAH_SHOT_DIR 'qa_report.md'
  $md | Set-Content -Path $out -Encoding UTF8
  $out
}