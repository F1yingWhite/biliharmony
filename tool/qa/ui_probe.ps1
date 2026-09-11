# ============================================================
# 模拟器 UI 验证辅助（Windows）
# 用法:
#   pwsh -File tool\qa\ui_probe.ps1 -Action dump   -Name home
#   pwsh -File tool\qa\ui_probe.ps1 -Action tap    -Text "我的"
#   pwsh -File tool\qa\ui_probe.ps1 -Action tapxy  -X 1100 -Y 2700
#   pwsh -File tool\qa\ui_probe.ps1 -Action back
#   pwsh -File tool\qa\ui_probe.ps1 -Action find   -Text "YouTube"
#
# 所有 hdc 调用经 cmd 重定向到文件后再读：PowerShell 管道在大输出时会挂起。
# 每步自动 dump 一次布局到 .qa/ui/<Name>.json，便于留证据。
# ============================================================
param(
  [Parameter(Mandatory = $true)][ValidateSet('dump', 'tap', 'tapxy', 'back', 'find', 'start', 'stop', 'nodes')]
  [string]$Action,
  [string]$Text = '',
  [string]$Name = 'ui',
  [int]$X = 0,
  [int]$Y = 0
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$hdc = 'D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$appid = 'com.piliplus.harmony'
$dir = Join-Path $root '.qa\ui'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

function Invoke-Hdc([string[]]$HdcArgs) {
  $script = Join-Path $env:TEMP ("bili_ui_" + [guid]::NewGuid().ToString('N') + '.cmd')
  $body = "@echo off`r`n`"$hdc`" " + ($HdcArgs -join ' ') + "`r`n"
  Set-Content -Path $script -Encoding ASCII -Value $body
  $o = "$script.out"; $e = "$script.err"
  $p = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$script`"" -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $o -RedirectStandardError $e
  $out = Get-Content $o -ErrorAction SilentlyContinue
  $err = Get-Content $e -ErrorAction SilentlyContinue
  Remove-Item $script, $o, $e -Force -ErrorAction SilentlyContinue
  return @{ code = $p.ExitCode; out = $out; err = $err }
}

function Get-Layout([string]$label) {
  $remote = "/data/local/tmp/$label.json"
  $local = Join-Path $dir "$label.json"
  Invoke-Hdc @('shell', 'uitest', 'dumpLayout', '-p', $remote) | Out-Null
  Invoke-Hdc @('file', 'recv', $remote, $local) | Out-Null
  if (-not (Test-Path $local)) { throw "dump 失败: $local 未生成" }
  return $local
}

function Get-Nodes($parsed) {
  # dumpLayout 顶层是 JSON 数组；必须逐元素入栈，否则数组被当成单个节点，
  # 结构查询会静默返回空（字符串匹配不受影响，容易误判脚本可用）。
  $stack = [System.Collections.Generic.Stack[object]]::new()
  if ($parsed -is [System.Array]) { foreach ($item in $parsed) { $stack.Push($item) } }
  else { $stack.Push($parsed) }
  $all = @()
  while ($stack.Count -gt 0) {
    $n = $stack.Pop()
    if ($null -eq $n) { continue }
    $all += $n
    if ($null -ne $n.children) { foreach ($c in $n.children) { $stack.Push($c) } }
  }
  return $all
}

switch ($Action) {
  'stop' { Invoke-Hdc @('shell', 'aa', 'force-stop', $appid) | Out-Null; Write-Host 'stopped' }
  'start' {
    Invoke-Hdc @('shell', 'aa', 'force-stop', $appid) | Out-Null
    Invoke-Hdc @('shell', 'aa', 'start', '-a', 'EntryAbility', '-b', $appid) | Out-Null
    Start-Sleep -Seconds 6
    $f = Get-Layout $Name
    Write-Host "started, dump: $f"
  }
  'back' {
    Invoke-Hdc @('shell', 'uitest', 'uiInput', 'keyEvent', 'Back') | Out-Null
    Start-Sleep -Milliseconds 900
    $f = Get-Layout $Name
    Write-Host "back done, dump: $f"
  }
  'dump' {
    $f = Get-Layout $Name
    Write-Host "dump: $f"
  }
  'tapxy' {
    Invoke-Hdc @('shell', 'uitest', 'uiInput', 'click', "$X", "$Y") | Out-Null
    Start-Sleep -Milliseconds 1200
    $f = Get-Layout $Name
    Write-Host "tapped ($X,$Y), dump: $f"
  }
  'nodes' {
    $f = Get-Layout $Name
    $parsed = Get-Content $f -Raw | ConvertFrom-Json
    $all = Get-Nodes $parsed
    $sel = $all | Where-Object { $null -ne $_.attributes }
    if ($Text -ne '') { $sel = $sel | Where-Object { $_.attributes.text -eq $Text } }
    Write-Host "节点总数=$($all.Count) 命中=$($sel.Count)"
    $sel | ForEach-Object {
      Write-Host ("  text='{0}' type={1} id={2} bounds={3} clickable={4}" -f `
        $_.attributes.text, $_.attributes.type, $_.attributes.id, $_.attributes.bounds, $_.attributes.clickable)
    }
  }
  'tap' {
    $f = Get-Layout 'before-tap'
    $parsed = Get-Content $f -Raw | ConvertFrom-Json
    $all = Get-Nodes $parsed
    $hit = $all | Where-Object { $null -ne $_.attributes -and $_.attributes.text -eq $Text } | Select-Object -First 1
    if ($null -eq $hit) { throw "未找到文本节点: $Text（dump: $f）" }
    $b = $hit.attributes.bounds
    $m = [regex]::Match($b, '\[(\d+),(\d+)\]\[(\d+),(\d+)\]')
    if (-not $m.Success) { throw "无法解析 bounds: $b" }
    $cx = [int](([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2)
    $cy = [int](([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2)
    Write-Host "命中 '$Text' bounds=$b -> tap ($cx,$cy)"
    Invoke-Hdc @('shell', 'uitest', 'uiInput', 'click', "$cx", "$cy") | Out-Null
    Start-Sleep -Milliseconds 1500
    $g = Get-Layout $Name
    Write-Host "dump: $g"
  }
  'find' {
    $f = Get-Layout $Name
    $raw = Get-Content $f -Raw
    if ($raw -like "*$Text*") { Write-Host "FOUND: $Text  ($f)" } else { Write-Host "NOT FOUND: $Text  ($f)"; exit 2 }
  }
}
