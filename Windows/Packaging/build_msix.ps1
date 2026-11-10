<#
.SYNOPSIS
  Packs a `dotnet publish` folder into an MSIX for the Microsoft Store.

.DESCRIPTION
  Copies the publish output, the icons and the manifest into a layout folder,
  indexes the icons with makepri, and packs the layout with makeappx. The
  result is unsigned: Partner Center signs Store packages itself. For a local
  test install, pass -CertificatePath to sign it with a test certificate whose
  subject equals the manifest's Publisher.

  The tools come from the newest installed Windows 10/11 SDK (present on
  GitHub's windows-latest), or from -ToolsDir, e.g. the bin\<version>\x64
  folder of the Microsoft.Windows.SDK.BuildTools NuGet package.

.EXAMPLE
  ./Windows/Packaging/build_msix.ps1 -PublishDir publish/win-x64 -Version 1.1.0 -Arch x64 -Output dist/Pauselet-1.1.0-windows-x64.msix
#>
param(
    [Parameter(Mandatory)] [string] $PublishDir,
    # The app version, e.g. 1.1.0 or 1.2.0-rc1. The package gets a.b.c.0.
    [Parameter(Mandatory)] [string] $Version,
    [ValidateSet('x64', 'arm64')] [string] $Arch = 'x64',
    [Parameter(Mandatory)] [string] $Output,
    [string] $ToolsDir,
    [string] $CertificatePath,
    [string] $CertificatePassword
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Invoke-Tool([string] $exe, [string[]] $arguments) {
    & $exe @arguments
    if ($LASTEXITCODE) { throw "$(Split-Path -Leaf $exe) failed with exit code $LASTEXITCODE" }
}

if (-not $ToolsDir) {
    $bin = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
        Where-Object Name -like '10.*' |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1
    if (-not $bin) { throw 'No Windows SDK found; pass -ToolsDir.' }
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $ToolsDir = Join-Path $bin.FullName $hostArch
}
$makeappx = Join-Path $ToolsDir 'makeappx.exe'
$makepri = Join-Path $ToolsDir 'makepri.exe'

# a.b.c.0: the Store owns the fourth part, and a prerelease suffix is dropped.
$numeric = ($Version -split '-')[0]
if ($numeric -notmatch '^\d+\.\d+\.\d+$') { throw "Version '$Version' is not a.b.c" }
$packageVersion = "$numeric.0"

$work = Join-Path ([IO.Path]::GetTempPath()) "pauselet-msix-$([guid]::NewGuid().ToString('N'))"
$layout = Join-Path $work 'layout'
$resources = Join-Path $work 'resources'
New-Item -ItemType Directory -Force $layout, $resources | Out-Null
try {
    Copy-Item -Recurse (Join-Path $PublishDir '*') $layout
    # Kept to one line per call: Windows PowerShell 5.1 cannot continue a
    # method chain onto the next line.
    $manifest = [IO.File]::ReadAllText((Join-Path $here 'AppxManifest.xml'))
    $manifest = $manifest.Replace('$VERSION$', $packageVersion).Replace('$ARCH$', $Arch)
    [IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding $false))

    # Index only the icons, from a folder of their own, so resources.pri does
    # not list the hundreds of runtime files beside them.
    Copy-Item -Recurse (Join-Path $here 'Images') (Join-Path $resources 'Images')
    Copy-Item -Recurse (Join-Path $here 'Images') (Join-Path $layout 'Images')
    Copy-Item (Join-Path $layout 'AppxManifest.xml') $resources
    $config = Join-Path $work 'priconfig.xml'
    Invoke-Tool $makepri @('createconfig', '/cf', $config, '/dq', 'en-AU', '/pv', '10.0.0', '/o')
    # The default config splits each scale into its own resources.scale-N.pri,
    # which only suits a bundle of resource packages. This is one flat
    # package, so every icon stays in the one resources.pri.
    [xml] $pri = Get-Content -Raw $config
    $packaging = $pri.resources.packaging
    if ($packaging) { [void] $pri.resources.RemoveChild($packaging) }
    $pri.Save($config)
    Invoke-Tool $makepri @('new', '/pr', $resources, '/cf', $config,
        '/mn', (Join-Path $resources 'AppxManifest.xml'),
        '/of', (Join-Path $layout 'resources.pri'), '/o')

    $outDir = Split-Path -Parent $Output
    if ($outDir) { New-Item -ItemType Directory -Force $outDir | Out-Null }
    Invoke-Tool $makeappx @('pack', '/d', $layout, '/p', $Output, '/o')

    if ($CertificatePath) {
        $signtool = Join-Path $ToolsDir 'signtool.exe'
        $sign = @('sign', '/fd', 'SHA256', '/f', $CertificatePath)
        if ($CertificatePassword) { $sign += @('/p', $CertificatePassword) }
        Invoke-Tool $signtool ($sign + @($Output))
    }
    Write-Host "Packed $Output ($packageVersion, $Arch)"
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
