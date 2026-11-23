<#
.SYNOPSIS
    Launch Shutter Encoder from this repository.
.DESCRIPTION
    Selects Java 21 or newer automatically and runs the repository's Shutter Encoder.jar.
    With -Build, compiles src\shutterencoder into build\classes first and launches the
    result instead.
.PARAMETER Build
    Compile before launching. Output goes to build\classes; Library and LUTs are reused
    from the repository root through directory junctions.
.PARAMETER JavaExe
    Full path to java.exe. Probed automatically when omitted.
.EXAMPLE
    .\Start-ShutterEncoder.ps1
    Launch using the official Shutter Encoder.jar.
.EXAMPLE
    .\Start-ShutterEncoder.ps1 -Build
    Compile src\shutterencoder and launch the result.
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
    Read the major version of the given java.exe.
.PARAMETER Exe
    Full path to java.exe.
.OUTPUTS
    Major version, or 0 when it cannot be determined.
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

# Collect candidate java.exe files. The installed Shutter Encoder runtime is
# preferred because it ships the FreeSans and Montserrat fonts.
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

# Java used to run: an explicit choice wins, then the installed runtime, then the
# highest available major version.
if ($JavaExe -or $env:JAVA_EXE) {
    $explicitJava = if ($JavaExe) { $JavaExe } else { $env:JAVA_EXE }
    $java = $found | Where-Object { $_.Path -eq $explicitJava } | Select-Object -First 1
    if (-not $java) {
        Write-Host 'The specified java.exe does not exist or is older than Java 21.' -ForegroundColor Red
        exit 1
    }
} else {
    $java = $found | Where-Object { $_.IsRuntime } | Select-Object -First 1
    if (-not $java) {
        $java = $found | Sort-Object Major -Descending | Select-Object -First 1
    }
}

if (-not $java) {
    Write-Host 'No usable Java 21 or newer found.' -ForegroundColor Red
    Write-Host 'Install Java 21+, set JAVA_HOME or JAVA_EXE, or pass -JavaExe with a java.exe path.'
    exit 1
}

# JDK used for compilation: must include javac, highest complete JDK preferred.
$jdk = $found | Where-Object {
    Test-Path (Join-Path (Split-Path $_.Path) 'javac.exe')
} | Sort-Object Major -Descending | Select-Object -First 1

if ($Build -and -not $jdk) {
    Write-Host 'No usable JDK 21 or newer found (javac required).' -ForegroundColor Red
    Write-Host 'Install JDK 21+, set JAVA_HOME or JAVA_EXE, or pass -JavaExe with a java.exe path.'
    exit 1
}

Write-Host ("Using Java {0}: {1}" -f $java.Major, $java.Path)
if ($Build) {
    Write-Host ("Compile JDK: {0}" -f $jdk.Path)
}
Write-Host ("Repository root: {0}" -f $repoRoot)

$libraryDir = Join-Path $repoRoot 'Library'
if (-not (Test-Path (Join-Path $libraryDir 'ffmpeg.exe'))) {
    Write-Host 'Warning: Library\ffmpeg.exe is missing; transcoding and media analysis will not work.' -ForegroundColor Yellow
    Write-Host 'Copy the runtime libraries from the app\Library directory of an installed Shutter Encoder.'
}

if ($Build) {
    $buildRoot = Join-Path $repoRoot 'build'
    $classesDir = Join-Path $buildRoot 'classes'
    $javac = Join-Path (Split-Path $jdk.Path) 'javac.exe'

    Write-Host 'Compiling sources...'
    if (Test-Path $classesDir) {
        Remove-Item $classesDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $classesDir -Force | Out-Null

    $sources = @(Get-ChildItem (Join-Path $repoRoot 'src\shutterencoder') -Recurse -Filter *.java |
        ForEach-Object { $_.FullName })
    if ($sources.Count -eq 0) {
        Write-Host 'No Java sources found under src\shutterencoder.' -ForegroundColor Red
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
        Write-Host 'Compilation failed; launch aborted.' -ForegroundColor Red
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
    Write-Host 'Compilation complete, launching...'
    & $java.Path '-Xmx4G' -cp $classpath shutterencoder.ui.main.Main @AppArgs
} else {
    $jar = Join-Path $repoRoot 'Shutter Encoder.jar'
    if (-not (Test-Path $jar)) {
        Write-Host 'Shutter Encoder.jar not found.' -ForegroundColor Red
        exit 1
    }

    Write-Host 'Launching...'
    & $java.Path '-Xmx4G' -jar $jar @AppArgs
}

exit $LASTEXITCODE
