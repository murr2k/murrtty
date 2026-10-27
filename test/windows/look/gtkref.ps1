# A reference picture of Ghostty's GTK app at 96 DPI (gtkref.sh in the WSL
# distro that has the Ghostty snap), converted to PNG:
#   .\gtkref.ps1 -Out ref.png [-Extra 'window-show-tab-bar = always'] [-Distro Ubuntu-22.04]
# Nothing opens on the screen and the distro's own configs stay untouched.
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Extra = '',
    [string]$Distro = 'Ubuntu-22.04'
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function ToWsl([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path)
    return '/mnt/' + $full.Substring(0, 1).ToLower() + $full.Substring(2).Replace('\', '/')
}
$font = Join-Path $here '..\..\..\src\apprt\win32\res\AdwaitaSans-Regular.ttf'
$xwd = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetFullPath($Out), '.xwd')
& wsl.exe -d $Distro -- sh (ToWsl (Join-Path $here 'gtkref.sh')) (ToWsl $font) (ToWsl $xwd) $Extra
if ($LASTEXITCODE -ne 0) { throw "gtkref.sh failed ($LASTEXITCODE)" }
& python -I (Join-Path $here 'xwd2png.py') $xwd ([System.IO.Path]::GetFullPath($Out))
