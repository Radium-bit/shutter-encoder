<#
.SYNOPSIS
    构建 Shutter Encoder noPrompt 版 Windows 安装包。
.DESCRIPTION
    按当前工作树源码编译，打包 fat jar，用 jpackage 生成 Windows 应用镜像
    （含启动器 exe 与精简 Java 运行时），再用 NSIS 生成安装包。
    中间产物放在 build\noPrompt，交付物放在 build\dist。
.PARAMETER SkipInstaller
    只生成应用镜像，不调用 NSIS 生成安装包。
.EXAMPLE
    .\build-noPrompt.ps1
    完整构建并生成安装包。
.EXAMPLE
    .\build-noPrompt.ps1 -SkipInstaller
    只生成可直接运行的应用镜像。
#>
[CmdletBinding()]
param(
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
Set-Location $repoRoot

# 工具路径，可用环境变量覆盖以适配其他构建机
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
    校验构建依赖是否存在，缺失时输出提示并终止。
.PARAMETER Path
    工具或文件的完整路径。
.PARAMETER Hint
    缺失时的处理提示。
#>
function Assert-Tool {
    param([string]$Path, [string]$Hint)

    if (-not (Test-Path $Path)) {
        Write-Host ("缺少构建依赖: {0}" -f $Path) -ForegroundColor Red
        Write-Host $Hint
        exit 1
    }
}

<#
.SYNOPSIS
    读取当前提交号，用于版本后缀与安装包标识。
.OUTPUTS
    短提交号；工作树不在 git 仓库时返回空字符串。
#>
function Get-Revision {
    $rev = & git rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $rev) { return '' }
    return $rev.Trim()
}

<#
.SYNOPSIS
    清空指定目录后重建为空目录。
.PARAMETER Path
    目标目录路径。
#>
function Reset-Directory {
    param([string]$Path)

    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

$javac = Join-Path $jdkHome 'bin\javac.exe'
$jarTool = Join-Path $jdkHome 'bin\jar.exe'
$jpackage = Join-Path $jdkHome 'bin\jpackage.exe'

Assert-Tool $javac '请安装 JDK 21 或更高版本，或用环境变量 SE_JDK_HOME 指向 JDK 根目录。'
Assert-Tool $jarTool '请安装 JDK 21 或更高版本，或用环境变量 SE_JDK_HOME 指向 JDK 根目录。'
Assert-Tool $jpackage '请安装 JDK 21 或更高版本，或用环境变量 SE_JDK_HOME 指向 JDK 根目录。'
if (-not $SkipInstaller) {
    Assert-Tool $nsisExe '请安装 NSIS 3.x，或用环境变量 SE_MAKENSIS 指向 makensis.exe。'
}

$revision = Get-Revision
Write-Host ("构建提交: {0}" -f $(if ($revision) { $revision } else { '(未取得，版本后缀将省略)' }))
if (-not $revision) {
    Write-Host '警告: 未取得 git 提交号。' -ForegroundColor Yellow
}

New-Item -ItemType Directory -Path $distDir -Force | Out-Null
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# 1. 编译源码
Write-Host '正在编译源码...'
Reset-Directory $classesDir
$sources = @(Get-ChildItem (Join-Path $repoRoot 'src\shutterencoder') -Recurse -Filter *.java |
    ForEach-Object { $_.FullName })
if ($sources.Count -eq 0) {
    Write-Host '未找到 src\shutterencoder 下的 Java 源文件。' -ForegroundColor Red
    exit 1
}

& $javac -encoding UTF-8 -nowarn -cp (Join-Path $repoRoot 'src\libs\*') -d $classesDir $sources
if ($LASTEXITCODE -ne 0) {
    Write-Host '源码编译失败。' -ForegroundColor Red
    exit $LASTEXITCODE
}

# 2. 组装 jar 内容：编译产物 + 类路径资源 + 依赖库
Write-Host '正在组装 jar 内容...'
Reset-Directory $stageDir
Copy-Item (Join-Path $classesDir '*') $stageDir -Recurse -Force
Copy-Item (Join-Path $repoRoot 'src\resources') $stageDir -Recurse -Force

# 依赖 jar 逐个解包到独立目录再合并，避免污染仓库工作区
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
            Write-Host ("依赖解包失败: {0}" -f $lib.Name) -ForegroundColor Red
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
    Copy-Item (Join-Path $expanded '*') $stageDir -Recurse -Force
}

# 写入构建提交号，供程序启动时拼接版本号。
# 程序按 UTF-8 读取，此处用 .NET 显式写入无 BOM 的 UTF-8，避免首行出现不可见前缀。
[System.IO.File]::WriteAllText((Join-Path $stageDir 'build-revision.txt'), $revision, (New-Object System.Text.UTF8Encoding($false)))

# 依赖 jar 自带的模块描述符在合并后互相冲突，且本程序以类路径方式启动，不需要模块化。
# 与官方 fat jar 的处理一致，把这些描述符改名保留，避免 jar 工具按模块校验。
foreach ($descriptor in @('module-info.class', 'META-INF\versions\9\module-info.class')) {
    $full = Join-Path $stageDir $descriptor
    if (Test-Path $full) {
        Move-Item $full ($full + '.disabled') -Force
        Write-Host ("已禁用模块描述符: {0}" -f $descriptor)
    }
}

# 3. 打包 jar
Write-Host '正在打包 jar...'
if (Test-Path $jarPath) { Remove-Item $jarPath -Force }
# 用 -C 指定内容根目录，并把 -C 放在所有选项之后，避免位置参数被误解析为待打包文件。
& $jarTool --create --file $jarPath --main-class shutterencoder.ui.main.Main -C $stageDir .
if ($LASTEXITCODE -ne 0) {
    Write-Host 'jar 打包失败。' -ForegroundColor Red
    exit $LASTEXITCODE
}

# 4. 准备 jpackage 输入目录：jar + 运行期资源
$inputDir = Join-Path $workDir 'input'
Reset-Directory $inputDir
Copy-Item $jarPath $inputDir
foreach ($name in @('Languages', 'Library', 'LUTs')) {
    Copy-Item (Join-Path $repoRoot $name) (Join-Path $inputDir $name) -Recurse -Force
}

# 5. 生成应用镜像，启动器、cfg 与运行时布局与官方一致。
# jpackage 在 Windows 只接受 ICO，这里用 .NET 把 logo.png 转成多尺寸 ICO。
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
Write-Host ("已生成图标: {0}" -f $iconPath)

Write-Host '正在生成应用镜像...'
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
    Write-Host '应用镜像生成失败。' -ForegroundColor Red
    exit $LASTEXITCODE
}

$appImage = Join-Path $imageDir 'Shutter Encoder'

# 字体由运行时提供，程序按 FreeSans、Montserrat 等字体名查找
$runtimeFonts = Join-Path $appImage 'runtime\lib\fonts'
New-Item -ItemType Directory -Path $runtimeFonts -Force | Out-Null
Copy-Item (Join-Path $repoRoot 'fonts\*') $runtimeFonts -Force

$appVersion = "20.5-noPrompt$(if ($revision) { "-$revision" } else { '' })"
Write-Host ("应用版本: {0}" -f $appVersion)

if ($SkipInstaller) {
    Write-Host ("已跳过安装包生成。应用镜像: {0}" -f $appImage) -ForegroundColor Green
    exit 0
}

# 6. 调用 NSIS 生成安装包
Write-Host '正在生成安装包...'
$nsisScript = Join-Path $repoRoot 'installer\ShutterEncoder.nsi'
& $nsisExe `
    "/DAPP_VERSION=$appVersion" `
    "/DAPP_IMAGE=$appImage" `
    "/DOUTPUT_DIR=$distDir" `
    "/DREPO_ROOT=$repoRoot" `
    $nsisScript
if ($LASTEXITCODE -ne 0) {
    Write-Host '安装包生成失败。' -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ("构建完成，产物目录: {0}" -f $distDir) -ForegroundColor Green
Get-ChildItem $distDir -Filter *.exe | ForEach-Object {
    Write-Host ("  {0}  {1:N1} MB" -f $_.Name, ($_.Length / 1MB))
}
