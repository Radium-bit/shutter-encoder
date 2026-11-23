<#
.SYNOPSIS
    启动 Shutter Encoder（仓库版）。
.DESCRIPTION
    自动选择 Java 21 或更高版本运行仓库中的 Shutter Encoder.jar。
    指定 -Build 时，先从 src\shutterencoder 编译到 build\classes，再以源码构建结果启动。
.PARAMETER Build
    从源码编译后启动。编译产物放在 build\classes，运行所需的 Library 与 LUTs 以目录联接方式复用仓库根目录。
.PARAMETER JavaExe
    指定 java.exe 的完整路径；未指定时自动探测。
.EXAMPLE
    .\Start-ShutterEncoder.ps1
    使用官方 Shutter Encoder.jar 启动。
.EXAMPLE
    .\Start-ShutterEncoder.ps1 -Build
    编译 src\shutterencoder 后启动。
#>
[CmdletBinding()]
param(
    [switch]$Build,
    [string]$JavaExe,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AppArgs
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Set-Location $repoRoot

<#
.SYNOPSIS
    读取指定 java.exe 的主版本号。
.PARAMETER Exe
    java.exe 的完整路径。
.OUTPUTS
    主版本号；无法识别时返回 0。
#>
function Get-JavaMajorVersion {
    param([string]$Exe)

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $Exe -version 2>&1
        if (-not $lines) { return 0 }

        $text = ($lines | Out-String)
        $match = [regex]::Match($text, 'version\s+"?([0-9]+)(?:\.([0-9]+))?')
        if (-not $match.Success) { return 0 }

        $major = [int]$match.Groups[1].Value
        if ($major -eq 1 -and $match.Groups[2].Success) {
            $major = [int]$match.Groups[2].Value
        }
        return $major
    } catch {
        return 0
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

# 收集候选 java.exe。优先使用 Shutter Encoder 安装版运行时，因为它自带 FreeSans 与 Montserrat 字体。
$runtimePath = 'C:\Program Files\Shutter Encoder\runtime\bin\java.exe'
$candidates = New-Object System.Collections.Generic.List[string]
if ($JavaExe) { $candidates.Add($JavaExe) }
if ($env:JAVA_EXE) { $candidates.Add($env:JAVA_EXE) }
if ($env:JAVA_HOME) { $candidates.Add((Join-Path $env:JAVA_HOME 'bin\java.exe')) }
$candidates.Add($runtimePath)

$jdkRoot = Join-Path $env:USERPROFILE '.jdks'
if (Test-Path $jdkRoot) {
    Get-ChildItem $jdkRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidates.Add((Join-Path $_.FullName 'bin\java.exe'))
    }
}

$pathJava = Get-Command java.exe -ErrorAction SilentlyContinue
if ($pathJava) { $candidates.Add($pathJava.Source) }

$found = @()
foreach ($candidate in $candidates) {
    if (-not $candidate -or -not (Test-Path $candidate)) { continue }

    $major = Get-JavaMajorVersion $candidate
    if ($major -ge 21) {
        $found += [pscustomobject]@{
            Path = $candidate
            Major = $major
            IsRuntime = ($candidate -eq $runtimePath)
        }
    }
}

# 运行用 Java：显式指定优先；否则优先安装版运行时；最后取最高版本。
if ($JavaExe -or $env:JAVA_EXE) {
    $explicitJava = if ($JavaExe) { $JavaExe } else { $env:JAVA_EXE }
    $java = $found | Where-Object { $_.Path -eq $explicitJava } | Select-Object -First 1
    if (-not $java) {
        Write-Host '指定的 java.exe 不存在或低于 Java 21。' -ForegroundColor Red
        exit 1
    }
} else {
    $java = $found | Where-Object { $_.IsRuntime } | Select-Object -First 1
    if (-not $java) {
        $java = $found | Sort-Object Major -Descending | Select-Object -First 1
    }
}

if (-not $java) {
    Write-Host '未找到可用的 Java 21 或更高版本。' -ForegroundColor Red
    Write-Host '请安装 Java 21+，或设置 JAVA_HOME / JAVA_EXE，或使用 -JavaExe 指定 java.exe。'
    exit 1
}

# 编译用 JDK：必须带 javac，优先版本最高的完整 JDK。
$jdk = $found | Where-Object {
    Test-Path (Join-Path (Split-Path $_.Path) 'javac.exe')
} | Sort-Object Major -Descending | Select-Object -First 1

if ($Build -and -not $jdk) {
    Write-Host '未找到可用的 Java 21 或更高版本 JDK（需要 javac）。' -ForegroundColor Red
    Write-Host '请安装 JDK 21+，或设置 JAVA_HOME / JAVA_EXE，或使用 -JavaExe 指定 java.exe。'
    exit 1
}

Write-Host ("使用 Java {0}: {1}" -f $java.Major, $java.Path)
if ($Build) {
    Write-Host ("编译 JDK: {0}" -f $jdk.Path)
}
Write-Host ("仓库根目录: {0}" -f $repoRoot)

$libraryDir = Join-Path $repoRoot 'Library'
if (-not (Test-Path (Join-Path $libraryDir 'ffmpeg.exe'))) {
    Write-Host '警告: Library\ffmpeg.exe 不存在，转码与媒体分析功能将无法使用。' -ForegroundColor Yellow
    Write-Host '可从已安装的 Shutter Encoder 的 app\Library 目录复制运行库。'
}

if ($Build) {
    $buildRoot = Join-Path $repoRoot 'build'
    $classesDir = Join-Path $buildRoot 'classes'
    $javac = Join-Path (Split-Path $jdk.Path) 'javac.exe'

    Write-Host '正在编译源码...'
    if (Test-Path $classesDir) {
        Remove-Item $classesDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $classesDir -Force | Out-Null

    $sources = @(Get-ChildItem (Join-Path $repoRoot 'src\shutterencoder') -Recurse -Filter *.java |
        ForEach-Object { $_.FullName })
    if ($sources.Count -eq 0) {
        Write-Host '未找到 src\shutterencoder 下的 Java 源文件。' -ForegroundColor Red
        exit 1
    }

    $libs = Join-Path $repoRoot 'src\libs\*'
    $javacArgs = @('-encoding', 'UTF-8', '-nowarn')
    if ($java.Major -lt $jdk.Major) {
        $javacArgs += @('--release', [string]$java.Major)
    }
    $javacArgs += @('-cp', $libs, '-d', $classesDir) + $sources
    & $javac @javacArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host '编译失败，已停止启动。' -ForegroundColor Red
        exit $LASTEXITCODE
    }

    Copy-Item (Join-Path $repoRoot 'src\resources') $classesDir -Recurse -Force
    New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
    Copy-Item (Join-Path $repoRoot 'Languages') (Join-Path $buildRoot 'Languages') -Recurse -Force
    Copy-Item (Join-Path $repoRoot 'fonts') (Join-Path $buildRoot 'fonts') -Recurse -Force

    foreach ($name in @('Library', 'LUTs')) {
        $linkPath = Join-Path $buildRoot $name
        $targetPath = Join-Path $repoRoot $name
        if (-not (Test-Path $linkPath) -and (Test-Path $targetPath)) {
            New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
        }
    }

    $classpath = "$classesDir;$libs"
    Write-Host '编译完成，正在启动...'
    & $java.Path '-Xmx4G' -cp $classpath shutterencoder.ui.main.Main @AppArgs
} else {
    $jar = Join-Path $repoRoot 'Shutter Encoder.jar'
    if (-not (Test-Path $jar)) {
        Write-Host '未找到 Shutter Encoder.jar。' -ForegroundColor Red
        exit 1
    }

    Write-Host '正在启动...'
    & $java.Path '-Xmx4G' -jar $jar @AppArgs
}

exit $LASTEXITCODE
