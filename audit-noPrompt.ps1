<#
.SYNOPSIS
    审计源码中是否重新出现捐献提示、版本检查与遥测采集。
.DESCRIPTION
    上游提交以整体文件上传为主，人工比对容易漏掉被重新引入的弹窗与联网逻辑。
    本脚本用静态扫描给出可核对的清单：命中非预期项时以非零码退出，可直接接入 CI。
    默认只报告；加 -Strict 时把「非预期命中」视为失败。
.PARAMETER Strict
    存在非预期命中时以退出码 1 结束。
.EXAMPLE
    .\audit-noPrompt.ps1
    打印审计结果，仅供参考。
.EXAMPLE
    .\audit-noPrompt.ps1 -Strict
    用于提交前或流水线门禁。
#>
[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Set-Location $repoRoot

$sourceDir = Join-Path $repoRoot 'src\shutterencoder'

<#
.SYNOPSIS
    在源码目录中匹配正则，返回文件与行号。
.PARAMETER Pattern
    .NET 正则表达式。
.OUTPUTS
    形如「相对路径:行号: 内容」的字符串集合。
#>
function Find-InSource {
    param([string]$Pattern)

    $results = @()
    $files = Get-ChildItem $sourceDir -Recurse -Filter *.java
    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
            $lineNumber++
            if ($line -match $Pattern) {
                $relative = $file.FullName.Substring($repoRoot.Length + 1)
                $results += ("{0}:{1}: {2}" -f $relative, $lineNumber, $line.Trim())
            }
        }
    }
    return $results
}

<#
.SYNOPSIS
    输出一组审计结果并统计命中数。
.PARAMETER Title
    检查项名称。
.PARAMETER Pattern
    匹配用正则表达式。
.PARAMETER Expectation
    命中后的判定说明。
.OUTPUTS
    命中条数。
#>
function Test-Rule {
    param([string]$Title, [string]$Pattern, [string]$Expectation)

    $hits = @(Find-InSource $Pattern)
    if ($hits.Count -eq 0) {
        Write-Host ("[通过] {0}" -f $Title) -ForegroundColor Green
        return 0
    }

    Write-Host ("[命中] {0} — {1}" -f $Title, $Expectation) -ForegroundColor Yellow
    foreach ($hit in $hits) {
        Write-Host ("        {0}" -f $hit)
    }
    return $hits.Count
}

Write-Host 'Shutter Encoder noPrompt 审计'
Write-Host '==============================='
Write-Host ''

$violations = 0

Write-Host '必须为零的项（出现即为回归）'
Write-Host '-------------------------------'
$violations += Test-Rule -Title '捐献弹窗类' `
    -Pattern '\bDonate\s*\.|\bDonate\s+\w|new\s+Donate\b|\bshowDonateWindow\b' `
    -Expectation '上游若重新引入捐献弹窗，需要再次移除'
$violations += Test-Rule -Title '机器码/设备指纹采集' `
    -Pattern '\bMachineId\b|baseboard|getMacId|machine-id' `
    -Expectation '设备标识采集属于遥测范畴，必须移除'
$violations += Test-Rule -Title '版本检查方法' `
    -Pattern '\bnewVersion\s*\(' `
    -Expectation '启动版本检查必须保持移除状态'
$violations += Test-Rule -Title '启动计数与捐献账号持久化' `
    -Pattern 'savedDayOfYear|textMailDonate' `
    -Expectation '每日弹窗计数与捐献账号都不应保留'
$violations += Test-Rule -Title '官方更新接口' `
    -Pattern 'shutterencoder\.com/(Stripe|changelog\.txt)|Shutter%20Encoder%20v' `
    -Expectation '官方更新与捐赠校验接口不应被调用'
Write-Host ''

Write-Host '需要人工确认的项（存在属正常，需核对用途）'
Write-Host '-------------------------------------------'
$review = 0
$review += Test-Rule -Title '第三方统计域名' `
    -Pattern 'google-analytics|googletagmanager|mixpanel|amplitude|sentry\.io|segment\.io' `
    -Expectation '出现即视为遥测，须移除'
Write-Host ''

Write-Host '联网点清单（供逐项核对是否为用户主动触发）'
Write-Host '-------------------------------------------'
$network = @(Find-InSource 'https?://' | Where-Object {
    $_ -notmatch 'gnu\.org|opensource\.org|w3\.org|xml\.apache|schemas|xmlns'
})
foreach ($item in $network) {
    Write-Host ("        {0}" -f $item)
}
Write-Host ("        合计 {0} 处" -f $network.Count)
Write-Host ''

Write-Host '版本号机制'
Write-Host '----------'
$versionFile = Join-Path $sourceDir 'ui\main\Main.java'
$versionOk = $false
if (Test-Path $versionFile) {
    $versionText = [System.IO.File]::ReadAllText($versionFile)
    $versionOk = ($versionText -match 'baseVersion') -and
                 ($versionText -match 'build-revision\.txt') -and
                 ($versionText -match 'noPrompt')
}
if ($versionOk) {
    Write-Host '[通过] 版本号仍由 baseVersion + build-revision.txt 组合生成' -ForegroundColor Green
} else {
    Write-Host '[失败] 版本号生成逻辑缺失，需重新应用 noPrompt 版本号改造' -ForegroundColor Red
    $violations++
}
Write-Host ''

Write-Host '构建链路'
Write-Host '--------'
foreach ($required in @('build-noPrompt.ps1', 'installer\ShutterEncoder.nsi')) {
    if (Test-Path (Join-Path $repoRoot $required)) {
        Write-Host ("[通过] {0}" -f $required) -ForegroundColor Green
    } else {
        Write-Host ("[失败] 缺少 {0}" -f $required) -ForegroundColor Red
        $violations++
    }
}
Write-Host ''

Write-Host '==============================='
if ($violations -eq 0) {
    Write-Host '审计通过：未发现捐献提示、版本检查与遥测采集。' -ForegroundColor Green
    exit 0
}

Write-Host ("审计未通过：{0} 项需要处理。" -f $violations) -ForegroundColor Red
if ($Strict) { exit 1 }
exit 0
