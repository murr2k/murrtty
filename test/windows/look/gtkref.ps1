# A reference picture of Ghostty's GTK app at 96 DPI (gtkref.sh in the WSL
# distro that has the Ghostty snap), converted to PNG:
#   .\gtkref.ps1 -Out ref.png [-Extra 'window-show-tab-bar = always', 'gtk-tabs-inverted = true']
#                [-Actions 'xdotool mousemove 662 28 click 1'] [-Distro Ubuntu-22.04]
# Each -Extra string is a line of Ghostty config, each -Actions string a
# command run in the display before the picture (xdotool's, to open a
# menu); they reach the distro in files beside the picture, so no quoting
# is lost on the way. Nothing opens on the screen and the distro's own
# configs stay untouched.
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string[]]$Extra = @(),
    [string[]]$Actions = @(),
    [string]$Distro = 'Ubuntu-22.04'
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function ToWsl([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path)
    return '/mnt/' + $full.Substring(0, 1).ToLower() + $full.Substring(2).Replace('\', '/')
}
function WriteLines([string]$path, [string[]]$lines) {
    [System.IO.File]::WriteAllText($path, (($lines | ForEach-Object { "$_`n" }) -join ''), (New-Object System.Text.UTF8Encoding $false))
}
$font = Join-Path $here '..\..\..\src\apprt\win32\res\AdwaitaSans-Regular.ttf'
$full = [System.IO.Path]::GetFullPath($Out)
$xwd = [System.IO.Path]::ChangeExtension($full, '.xwd')
$conf = [System.IO.Path]::ChangeExtension($full, '.extra.conf')
$acts = [System.IO.Path]::ChangeExtension($full, '.actions.sh')
WriteLines $conf $Extra
WriteLines $acts $Actions
& wsl.exe -d $Distro -- sh (ToWsl (Join-Path $here 'gtkref.sh')) (ToWsl $font) (ToWsl $xwd) (ToWsl $conf) (ToWsl $acts)
if ($LASTEXITCODE -ne 0) { throw "gtkref.sh failed ($LASTEXITCODE)" }
& python -I (Join-Path $here 'xwd2png.py') $xwd $full
