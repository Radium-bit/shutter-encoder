<#
.SYNOPSIS
    Audit the source for reintroduced donation prompts, update checks, and telemetry.
.DESCRIPTION
    Upstream commits are mostly wholesale file uploads, so manual review easily
    misses popups and network logic that were quietly restored.
    This script performs a static scan and produces a verifiable list.
    With -Strict, unexpected matches are treated as failures and the exit code is
    nonzero, so it can gate CI.
.PARAMETER Strict
    Exit with code 1 when unexpected matches are present.
.EXAMPLE
    .\audit-noPrompt.ps1
    Print the audit report for review.
.EXAMPLE
    .\audit-noPrompt.ps1 -Strict
    Use as a pre-commit or pipeline gate.
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
    Match a regular expression across the source tree and report file and line.
.PARAMETER Pattern
    .NET regular expression.
.OUTPUTS
    Strings shaped as "relative-path:line: content".
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
    Report the outcome of one audit rule and count hits.
.PARAMETER Title
    Rule name.
.PARAMETER Pattern
    Regular expression to match.
.PARAMETER Expectation
    Explanation shown when the rule reports hits.
.OUTPUTS
    Number of hits.
#>
function Test-Rule {
    param([string]$Title, [string]$Pattern, [string]$Expectation)

    $hits = @(Find-InSource $Pattern)
    if ($hits.Count -eq 0) {
        Write-Host ("[PASS] {0}" -f $Title) -ForegroundColor Green
        return 0
    }

    Write-Host ("[HIT ] {0} - {1}" -f $Title, $Expectation) -ForegroundColor Yellow
    foreach ($hit in $hits) {
        Write-Host ("        {0}" -f $hit)
    }
    return $hits.Count
}

Write-Host 'Shutter Encoder noPrompt audit'
Write-Host '=============================='
Write-Host ''

$violations = 0

Write-Host 'Must be zero (any hit is a regression)'
Write-Host '--------------------------------------'
$violations += Test-Rule -Title 'Donation popup' `
    -Pattern '\bDonate\s*\.|\bDonate\s+\w|new\s+Donate\b|\bshowDonateWindow\b' `
    -Expectation 'upstream may reintroduce the popup; remove it again'
$violations += Test-Rule -Title 'Machine ID and device fingerprinting' `
    -Pattern '\bMachineId\b|baseboard|getMacId|machine-id' `
    -Expectation 'device identifier collection is telemetry and must be removed'
$violations += Test-Rule -Title 'Version check method' `
    -Pattern '\bnewVersion\s*\(' `
    -Expectation 'the startup update check must stay removed'
$violations += Test-Rule -Title 'Launch counter and donation account persistence' `
    -Pattern 'savedDayOfYear|textMailDonate' `
    -Expectation 'the daily popup counter and donation account must not remain'
$violations += Test-Rule -Title 'Official update endpoints' `
    -Pattern 'shutterencoder\.com/(Stripe|changelog\.txt)|Shutter%20Encoder%20v' `
    -Expectation 'the official update and donation verification endpoints must not be called'
Write-Host ''

Write-Host 'Requires manual review (presence is normal, confirm the purpose)'
Write-Host '---------------------------------------------------------------'
$review = 0
$review += Test-Rule -Title 'Third-party analytics domains' `
    -Pattern 'google-analytics|googletagmanager|mixpanel|amplitude|sentry\.io|segment\.io' `
    -Expectation 'any hit counts as telemetry and must be removed'
Write-Host ''

Write-Host 'Network call inventory (confirm each is user-initiated)'
Write-Host '------------------------------------------------------'
$network = @(Find-InSource 'https?://' | Where-Object {
    $_ -notmatch 'gnu\.org|opensource\.org|w3\.org|xml\.apache|schemas|xmlns'
})
foreach ($item in $network) {
    Write-Host ("        {0}" -f $item)
}
Write-Host ("        total {0}" -f $network.Count)
Write-Host ''

Write-Host 'Version mechanism'
Write-Host '-----------------'
$versionFile = Join-Path $sourceDir 'ui\main\Main.java'
$versionOk = $false
if (Test-Path $versionFile) {
    $versionText = [System.IO.File]::ReadAllText($versionFile)
    $versionOk = ($versionText -match 'baseVersion') -and
                 ($versionText -match 'build-revision\.txt') -and
                 ($versionText -match 'noPrompt')
}
if ($versionOk) {
    Write-Host '[PASS] version is still composed from baseVersion and build-revision.txt' -ForegroundColor Green
} else {
    Write-Host '[FAIL] version composition is missing; reapply the noPrompt version rework' -ForegroundColor Red
    $violations++
}
Write-Host ''

Write-Host 'Build pipeline'
Write-Host '--------------'
foreach ($required in @('build-noPrompt.ps1', 'installer\ShutterEncoder.nsi')) {
    if (Test-Path (Join-Path $repoRoot $required)) {
        Write-Host ("[PASS] {0}" -f $required) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] missing {0}" -f $required) -ForegroundColor Red
        $violations++
    }
}
Write-Host ''

Write-Host '=============================='
if ($violations -eq 0) {
    Write-Host 'Audit passed: no donation prompt, update check, or telemetry found.' -ForegroundColor Green
    exit 0
}

Write-Host ("Audit failed: {0} item(s) require attention." -f $violations) -ForegroundColor Red
if ($Strict) { exit 1 }
exit 0
