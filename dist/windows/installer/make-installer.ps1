<#
.SYNOPSIS
Builds murrtty's per-user installer from a release zip with Inno Setup's
ISCC (WINDOWS_ROADMAP.md 7.4). Prints the installer's path.

.DESCRIPTION
-Zip is a release zip, murrtty-<version>-windows-<x86_64|aarch64>.zip, as
build-windows.cmd -Package makes it; its version and architecture come
from its name. It is unpacked into a temporary folder and murrtty.iss
compiled from it into -OutDir as
murrtty-<version>-windows-<arch>-setup.exe. -Iscc is ISCC.exe
(get-innosetup.ps1 fetches the pinned Inno Setup).

Windows PowerShell 5.1 and PowerShell 7; keep it ASCII.
#>
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [Parameter(Mandatory = $true)][string]$Iscc,
    [string]$OutDir = '.'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$name = [IO.Path]::GetFileNameWithoutExtension($Zip)
$m = [regex]::Match($name, '^murrtty-(\d+\.\d+\.\d+)-windows-(x86_64|aarch64)$')
if (-not $m.Success) { throw "$Zip isn't a release zip (murrtty-X.Y.Z-windows-x86_64.zip or -aarch64.zip)." }
$version = $m.Groups[1].Value
$arch = if ($m.Groups[2].Value -eq 'x86_64') { 'x64' } else { 'arm64' }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = (Resolve-Path -LiteralPath $OutDir).ProviderPath
$work = Join-Path ([IO.Path]::GetTempPath()) ('murrtty-setup-' + [Guid]::NewGuid().ToString('N'))
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $Zip).ProviderPath, $work)
    $source = Join-Path $work $name
    if (-not (Test-Path -LiteralPath (Join-Path $source 'bin\murrtty.exe'))) {
        throw "$Zip has no $name\bin\murrtty.exe."
    }
    & $Iscc /Q "/DVersion=$version" "/DArch=$arch" "/DSource=$source" "/DOutDir=$out" (Join-Path $here 'murrtty.iss') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "ISCC exited $LASTEXITCODE." }
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
$setup = Join-Path $out "$name-setup.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw "ISCC made no $setup." }
$setup
