<#
.SYNOPSIS
    Build the Shutter Encoder noPrompt Windows installer.
.DESCRIPTION
    Compiles the current working tree, packages a fat jar, generates a Windows
    app image with jpackage (launcher exe plus trimmed Java runtime), then builds
    the installer with NSIS.
    Intermediate output goes to build\noPrompt; deliverables go to build\dist.
.PARAMETER SkipInstaller
    Generate the app image only, without invoking NSIS.
.EXAMPLE
    .\build-noPrompt.ps1
    Full build including the installer.
.EXAMPLE
    .\build-noPrompt.ps1 -SkipInstaller
    Generate only the runnable app image.
#>
[CmdletBinding()]
param(
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Set-Location $repoRoot

# Tool paths. Override with environment variables on other build machines.
$jdkHome = if ($env:SE_JDK_HOME) { $env:SE_JDK_HOME } else { Join-Path $env:USERPROFILE '.jdks\azul-25.38.109' }
$nsisExe = if ($env:SE_MAKENSIS) { $env:SE_MAKENSIS } else { 'C:\Program Files (x86)\NSIS\makensis.exe' }

$distDir = Join-Path $repoRoot 'build\dist'
$workDir = Join-Path $repoRoot 'build\noPrompt'
$classesDir = Join-Path $workDir 'classes'
$stageDir = Join-Path $workDir 'stage'
$jarPath = Join-Path $workDir 'Shutter Encoder.jar'
$imageDir = Join-Path $workDir 'image'

<#
.SYNOPSIS
    Verify a build dependency exists, print guidance and stop when missing.
.PARAMETER Path
    Full path of the tool or file.
.PARAMETER Hint
    Guidance shown when the dependency is missing.
#>
function Assert-Tool {
    param([string]$Path, [string]$Hint)

    if (-not (Test-Path $Path)) {
        Write-Host ("Missing build dependency: {0}" -f $Path) -ForegroundColor Red
        Write-Host $Hint
        exit 1
    }
}

<#
.SYNOPSIS
    Read the current commit hash used for the version suffix and installer identity.
.OUTPUTS
    Short commit hash, or an empty string when the tree is not a git repository.
#>
function Get-Revision {
    $rev = & git rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $rev) { return '' }
    return $rev.Trim()
}

<#
.SYNOPSIS
    Clear a directory and recreate it empty.
.PARAMETER Path
    Target directory path.
#>
function Reset-Directory {
    param([string]$Path)

    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

$javac = Join-Path $jdkHome 'bin\javac.exe'
$jarTool = Join-Path $jdkHome 'bin\jar.exe'
$jpackage = Join-Path $jdkHome 'bin\jpackage.exe'

$jdkHint = 'Install JDK 21 or newer, or point SE_JDK_HOME at a JDK root.'
Assert-Tool $javac $jdkHint
Assert-Tool $jarTool $jdkHint
Assert-Tool $jpackage $jdkHint
if (-not $SkipInstaller) {
    Assert-Tool $nsisExe 'Install NSIS 3.x, or point SE_MAKENSIS at makensis.exe.'
}

$revision = Get-Revision
Write-Host ("Build commit: {0}" -f $(if ($revision) { $revision } else { '(unavailable, version suffix omitted)' }))
if (-not $revision) {
    Write-Host 'Warning: no git commit hash available.' -ForegroundColor Yellow
}

New-Item -ItemType Directory -Path $distDir -Force | Out-Null
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# 1. Compile sources
Write-Host 'Compiling sources...'
Reset-Directory $classesDir
$sources = @(Get-ChildItem (Join-Path $repoRoot 'src\shutterencoder') -Recurse -Filter *.java |
    ForEach-Object { $_.FullName })
if ($sources.Count -eq 0) {
    Write-Host 'No Java sources found under src\shutterencoder.' -ForegroundColor Red
    exit 1
}

& $javac -encoding UTF-8 -nowarn -cp (Join-Path $repoRoot 'src\libs\*') -d $classesDir $sources
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Source compilation failed.' -ForegroundColor Red
    exit $LASTEXITCODE
}

# 2. Assemble jar content: compiled classes, classpath resources, dependencies
Write-Host 'Assembling jar content...'
Reset-Directory $stageDir
Copy-Item (Join-Path $classesDir '*') $stageDir -Recurse -Force
Copy-Item (Join-Path $repoRoot 'src\resources') $stageDir -Recurse -Force

# Expand each dependency jar into its own directory before merging, so the
# repository working tree is never touched.
$libWorkDir = Join-Path $workDir 'libs-expand'
Reset-Directory $libWorkDir
$libIndex = 0
foreach ($lib in Get-ChildItem (Join-Path $repoRoot 'src\libs') -Filter *.jar) {
    $libIndex++
    $expanded = Join-Path $libWorkDir $libIndex
    New-Item -ItemType Directory -Path $expanded -Force | Out-Null
    Push-Location $expanded
    try {
        & $jarTool --extract --file $lib.FullName
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("Dependency extraction failed: {0}" -f $lib.Name) -ForegroundColor Red
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
    Copy-Item (Join-Path $expanded '*') $stageDir -Recurse -Force
}

# Write the build commit hash so the application can compose its version string.
# The application reads UTF-8, so write BOM-less UTF-8 explicitly to keep the
# first line free of an invisible prefix.
[System.IO.File]::WriteAllText((Join-Path $stageDir 'build-revision.txt'), $revision, (New-Object System.Text.UTF8Encoding($false)))

# Module descriptors shipped by dependency jars collide once merged, and this
# application launches from the classpath without needing modules. Rename them
# the same way the official fat jar does, so jar does not validate as a module.
foreach ($descriptor in @('module-info.class', 'META-INF\versions\9\module-info.class')) {
    $full = Join-Path $stageDir $descriptor
    if (Test-Path $full) {
        Move-Item $full ($full + '.disabled') -Force
        Write-Host ("Disabled module descriptor: {0}" -f $descriptor)
    }
}

# 3. Package the jar
Write-Host 'Packaging jar...'
if (Test-Path $jarPath) { Remove-Item $jarPath -Force }
# Pass -C after all options and point it at the content root, so positional
# arguments are not misread as files to package.
& $jarTool --create --file $jarPath --main-class shutterencoder.ui.main.Main -C $stageDir .
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Jar packaging failed.' -ForegroundColor Red
    exit $LASTEXITCODE
}

# 4. Prepare the jpackage input directory: jar plus runtime resources
$inputDir = Join-Path $workDir 'input'
Reset-Directory $inputDir
Copy-Item $jarPath $inputDir
foreach ($name in @('Languages', 'Library', 'LUTs')) {
    Copy-Item (Join-Path $repoRoot $name) (Join-Path $inputDir $name) -Recurse -Force
}

# 5. Generate the app image so launcher, cfg and runtime layout match the
# official build. jpackage accepts only ICO on Windows, so convert logo.png
# into a multi-size ICO with .NET.
$iconPath = Join-Path $workDir 'app.ico'
$logoPath = Join-Path $repoRoot 'logo.png'
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Image]::FromFile($logoPath)
$sizes = @(16, 24, 32, 48, 64, 128, 256)
$pngStreams = @()
foreach ($size in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($source, 0, 0, $size, $size)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $pngStreams += , $ms.ToArray()
    $ms.Dispose()
}
$source.Dispose()

$icoStream = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($icoStream)
$writer.Write([UInt16]0)
$writer.Write([UInt16]1)
$writer.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $size = $sizes[$i]
    $dimension = if ($size -ge 256) { 0 } else { $size }
    $writer.Write([Byte]$dimension)
    $writer.Write([Byte]$dimension)
    $writer.Write([Byte]0)
    $writer.Write([Byte]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]32)
    $writer.Write([UInt32]$pngStreams[$i].Length)
    $writer.Write([UInt32]$offset)
    $offset += $pngStreams[$i].Length
}
foreach ($data in $pngStreams) { $writer.Write($data) }
$writer.Flush()
[System.IO.File]::WriteAllBytes($iconPath, $icoStream.ToArray())
$writer.Dispose()
$icoStream.Dispose()
Write-Host ("Generated icon: {0}" -f $iconPath)

Write-Host 'Generating app image...'
Reset-Directory $imageDir
& $jpackage `
    --type app-image `
    --name 'Shutter Encoder' `
    --app-version 20.5 `
    --input $inputDir `
    --main-jar 'Shutter Encoder.jar' `
    --main-class shutterencoder.ui.main.Main `
    --icon $iconPath `
    --java-options '-Xmx4G' `
    --java-options '-Djavax.accessibility.assistive_technologies' `
    --java-options '-Djavax.accessibility.screen_magnifier_present=false' `
    --add-modules java.base,java.datatransfer,java.xml,java.prefs,java.desktop,java.logging,java.security.sasl,jdk.crypto.ec `
    --dest $imageDir
if ($LASTEXITCODE -ne 0) {
    Write-Host 'App image generation failed.' -ForegroundColor Red
    exit $LASTEXITCODE
}

$appImage = Join-Path $imageDir 'Shutter Encoder'

# Fonts are served by the runtime; the application looks them up by family name
# such as FreeSans and Montserrat.
$runtimeFonts = Join-Path $appImage 'runtime\lib\fonts'
New-Item -ItemType Directory -Path $runtimeFonts -Force | Out-Null
Copy-Item (Join-Path $repoRoot 'fonts\*') $runtimeFonts -Force

# GPL section 4 requires the license text to accompany binary distribution.
# The upstream installer omits it, so ship it explicitly next to the app.
Copy-Item (Join-Path $repoRoot 'LICENSE.txt') $appImage -Force
Write-Host 'Included LICENSE.txt in the app image.'

$appVersion = "20.5-noPrompt$(if ($revision) { "-$revision" } else { '' })"
Write-Host ("Application version: {0}" -f $appVersion)

if ($SkipInstaller) {
    Write-Host ("Installer skipped. App image: {0}" -f $appImage) -ForegroundColor Green
    exit 0
}

# 6. Build the installer with NSIS
Write-Host 'Building installer...'
$nsisScript = Join-Path $repoRoot 'installer\ShutterEncoder.nsi'
& $nsisExe `
    "/DAPP_VERSION=$appVersion" `
    "/DAPP_IMAGE=$appImage" `
    "/DOUTPUT_DIR=$distDir" `
    "/DREPO_ROOT=$repoRoot" `
    $nsisScript
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Installer build failed.' -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ("Build complete. Output directory: {0}" -f $distDir) -ForegroundColor Green
Get-ChildItem $distDir -Filter *.exe | ForEach-Object {
    Write-Host ("  {0}  {1:N1} MB" -f $_.Name, ($_.Length / 1MB))
}
