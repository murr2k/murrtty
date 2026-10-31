<#
.SYNOPSIS
Packs an unpacked murrtty release into an MSIX package (WINDOWS_ROADMAP.md
7.4, MSIX).

.DESCRIPTION
-Source is the release zip's folder (bin\, share\, LICENSE.txt,
THIRD-PARTY-NOTICES.txt). It is staged with AppxManifest.xml (its @...@
values filled) and Assets\ from this folder, then packed with the Windows
SDK's makeappx, which validates the manifest. The package is written to
-OutDir as murrtty-<version>-windows-x86_64.msix, and its path is the last
line of output.

With -Unsigned the publisher carries Microsoft's OID for unsigned packages,
so Windows 11 installs it for testing with Add-AppxPackage -AllowUnsigned
(as administrator). The Store signs what it publishes and assigns the
package name and publisher: pass those with -Name and -Publisher.

Windows PowerShell 5.1 and PowerShell 7; keep it ASCII.
#>
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutDir = '.',
    [string]$Name = 'murrtty.preview',
    [string]$Publisher = 'CN=murrtty',
    [string]$PublisherDisplayName = 'Murray Kopit',
    [switch]$Unsigned
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "-Version must be X.Y.Z, not '$Version'." }
# MSIX versions have four parts, and the Store wants the fourth to be 0.
$packageVersion = "$Version.0"
if ($Unsigned) { $Publisher = "$Publisher, OID.2.25.311729368913984317654407730594956997722=1" }

if (-not (Test-Path -LiteralPath (Join-Path $Source 'bin\murrtty.exe'))) {
    throw "$Source has no bin\murrtty.exe: pass the unpacked release folder."
}

$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$makeappx = @(Get-ChildItem -LiteralPath $kits -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\makeappx\.exe$' } |
    Sort-Object FullName -Descending)
if ($makeappx.Count -eq 0) { throw "makeappx.exe not found under ${kits}: the Windows SDK is needed." }
Write-Host "makeappx: $($makeappx[0].FullName)"

$stage = Join-Path ([IO.Path]::GetTempPath()) ('murrtty-msix-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    Copy-Item -Path (Join-Path $Source '*') -Destination $stage -Recurse
    Copy-Item -LiteralPath (Join-Path $here 'Assets') -Destination $stage -Recurse

    $xml = [IO.File]::ReadAllText((Join-Path $here 'AppxManifest.xml'))
    $xml = $xml.Replace('@NAME@', [Security.SecurityElement]::Escape($Name))
    $xml = $xml.Replace('@PUBLISHER@', [Security.SecurityElement]::Escape($Publisher))
    $xml = $xml.Replace('@PUBLISHER_DISPLAY@', [Security.SecurityElement]::Escape($PublisherDisplayName))
    $xml = $xml.Replace('@VERSION@', $packageVersion)
    if ($xml -match '@[A-Z_]+@') { throw "AppxManifest.xml has an unfilled value: $($Matches[0])" }
    [IO.File]::WriteAllText((Join-Path $stage 'AppxManifest.xml'), $xml, (New-Object Text.UTF8Encoding $false))

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $out = Join-Path (Resolve-Path -LiteralPath $OutDir).Path "murrtty-$Version-windows-x86_64.msix"
    & $makeappx[0].FullName pack /d $stage /p $out /o | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "makeappx failed with exit code $LASTEXITCODE." }
    $out
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
