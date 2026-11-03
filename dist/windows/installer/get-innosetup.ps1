<#
.SYNOPSIS
Fetches the Inno Setup murrtty's installer is built with, checks it, and
installs it into -Dir. Prints ISCC.exe's path.

.DESCRIPTION
The hosted release job's (windows-port-release.yml) way to its Inno Setup:
a pinned release, 7.1.0 of 2026-08-12, whose download must match the
SHA-256 GitHub lists for the asset and carry a valid Authenticode
signature by Pyrsys B.V. (Inno Setup's publisher); with -Attest also its
GitHub build provenance attestation (gh attestation verify, which needs
GH_TOKEN). It installs silently for the current user into -Dir.

It runs an installer: use it on a CI runner, or where its owner allows it.
Windows PowerShell 5.1 and PowerShell 7; keep it ASCII.
#>
param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [switch]$Attest
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$version = '7.1.0'
$url = 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe'
$sha256 = '0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f'
$signer = 'Pyrsys B.V.'

$work = Join-Path ([IO.Path]::GetTempPath()) ('innosetup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$exe = Join-Path $work "innosetup-$version-x64.exe"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $exe

$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
if ($got -ne $sha256) { throw "Inno Setup $version's SHA-256 is $got, not the pinned $sha256." }
$sig = Get-AuthenticodeSignature -LiteralPath $exe
if ($sig.Status -ne 'Valid') { throw "Inno Setup $version's signature is $($sig.Status): $($sig.StatusMessage)" }
if ($sig.SignerCertificate.Subject -notmatch [regex]::Escape($signer)) {
    throw "Inno Setup $version is signed by '$($sig.SignerCertificate.Subject)', not $signer."
}
Write-Host "Inno Setup ${version}: SHA-256 $got, signed by $signer"
if ($Attest) {
    & gh attestation verify $exe -R jrsoftware/issrc | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup $version's attestation didn't verify (exit $LASTEXITCODE)." }
}

$log = Join-Path $work 'install.log'
$arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER', '/NOICONS',
    "/DIR=`"$Dir`"", "/LOG=`"$log`"")
$p = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru
if ($p.ExitCode -ne 0) {
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 30 | Out-Host }
    throw "Inno Setup's installer exited $($p.ExitCode)."
}
$iscc = Join-Path $Dir 'ISCC.exe'
if (-not (Test-Path -LiteralPath $iscc)) { throw "No ISCC.exe in $Dir after installing Inno Setup." }
$iscc
