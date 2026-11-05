<#
.SYNOPSIS
Installs murrtty with its installer, checks the result, installs it again
over a running murrtty, uninstalls it and checks what is left. For a CI
runner: it changes this user's profile (Start menu, HKCU, LOCALAPPDATA).

.DESCRIPTION
Checks, each printed as it passes:
- a silent install exits 0 and puts murrtty, ConPTY, share\ and the
  license files in %LOCALAPPDATA%\Programs\murrtty (no bin\mesa), and the installed
  murrtty reports -Version;
- the Start menu shortcut starts it with --gtk-single-instance=true and
  carries the AppUserModelID murrtty.murrtty; no desktop shortcut (an
  unchecked task);
- "Open in murrtty" on folders, folder backgrounds and drives runs
  +new-window with --working-directory=%V., and Windows splits that
  command line, for a drive root and a folder with a space, into the
  arguments murrtty expects;
- the uninstall entry names the version;
- installing again while murrtty runs closes it (Restart Manager) and
  succeeds, and starts no murrtty;
- installing again as Restart to Update does (silently, /restart=1) closes
  the running murrtty and starts it again;
- uninstalling removes the program, the shortcut, the verbs, the toasts'
  AppUserModelID registration and the uninstall entry, and keeps the
  user's %LOCALAPPDATA%\murrtty.

Windows PowerShell 5.1 and PowerShell 7; keep it ASCII.
#>
param(
    [Parameter(Mandatory = $true)][string]$Setup,
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -and -not $Force) {
    throw 'This installs and uninstalls murrtty for the current user: run it on a CI runner, or pass -Force.'
}

function Ok([string]$What) { Write-Host "    ok: $What" }
function Check([bool]$Cond, [string]$What) {
    if (-not $Cond) { throw "FAILED: $What" }
    Ok $What
}

$appId = '{CF44D64F-C2EA-4A32-A936-08DA32432785}'
$app = Join-Path $env:LOCALAPPDATA 'Programs\murrtty'
$exe = Join-Path $app 'bin\murrtty.exe'
$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'murrtty.lnk'
$desk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'murrtty.lnk'
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\${appId}_is1"
$aumidKey = 'HKCU:\Software\Classes\AppUserModelId\murrtty.murrtty'
$verbs = @('Directory', 'Directory\Background', 'Drive')
$work = Join-Path ([IO.Path]::GetTempPath()) ('murrtty-setup-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

function Install([string]$Log, [string[]]$Extra = @()) {
    # Waits for setup itself, not what it starts: -Wait would wait for the
    # murrtty /restart=1 starts. Its Handle is read at once, or Windows
    # PowerShell 5.1 loses the exit code.
    $p = Start-Process -FilePath $Setup -ArgumentList (@('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$Log`"") + $Extra) -PassThru
    $null = $p.Handle
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log -Tail 40 | Out-Host }
        throw "FAILED: setup exited $($p.ExitCode)"
    }
}

# The murrtty processes running from the installed copy.
function Murrtty-Processes {
    Get-Process -Name murrtty -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -ieq $exe) }
}

# Wait for a started murrtty's window (60 s).
function Wait-Window($Process) {
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited -or $Process.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 250
    }
    return (-not $Process.HasExited -and $Process.MainWindowHandle -ne [IntPtr]::Zero)
}

# murrtty is a GUI program: its standard output only reaches a redirect.
function Run-Murrtty([string[]]$Arguments) {
    $out = Join-Path $work 'out.txt'
    $p = Start-Process -FilePath $exe -ArgumentList $Arguments -RedirectStandardOutput $out -Wait -PassThru -WindowStyle Hidden
    return [pscustomobject]@{ Code = $p.ExitCode; Text = (Get-Content -LiteralPath $out -Raw) }
}

Add-Type -Namespace MurrttyTest -Name Native -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
static extern IntPtr CommandLineToArgvW(string cmdLine, out int argc);
[DllImport("kernel32.dll")]
static extern IntPtr LocalFree(IntPtr mem);
public static string[] Split(string cmdLine) {
    int argc;
    IntPtr argv = CommandLineToArgvW(cmdLine, out argc);
    if (argv == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
    try {
        var args = new string[argc];
        for (int i = 0; i < argc; i++) args[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
        return args;
    } finally { LocalFree(argv); }
}
'@

# What murrtty would have before an uninstall: its user files and the
# toasts' registration (written at its first notification).
$data = Join-Path $env:LOCALAPPDATA 'murrtty'
New-Item -ItemType Directory -Force -Path $data | Out-Null
$marker = Join-Path $data 'installer-test-marker.txt'
Set-Content -LiteralPath $marker -Value 'kept'

Write-Host "==> Installing $Setup"
Install (Join-Path $work 'install.log')
foreach ($rel in @('bin\murrtty.exe', 'bin\conpty.dll', 'bin\OpenConsole.exe',
        'share\ghostty\themes', 'LICENSE.txt', 'THIRD-PARTY-NOTICES.txt', 'unins000.exe')) {
    Check (Test-Path -LiteralPath (Join-Path $app $rel)) "installed $rel"
}
# murrtty's software OpenGL (Mesa) retired with OpenGL (roadmap 7.8, step 7).
Check (-not (Test-Path -LiteralPath (Join-Path $app 'bin\mesa'))) 'no bin\mesa (OpenGL retired)'
$v = Run-Murrtty @('+version')
Check ($v.Code -eq 0 -and $v.Text -match [regex]::Escape("murrtty $Version")) "the installed murrtty reports $Version"

Check (Test-Path -LiteralPath $lnk) 'the Start menu shortcut'
$shell = New-Object -ComObject WScript.Shell
$s = $shell.CreateShortcut($lnk)
Check ($s.TargetPath -ieq $exe) "the shortcut starts $exe"
Check ($s.Arguments -eq '--gtk-single-instance=true') 'the shortcut passes --gtk-single-instance=true'
$item = (New-Object -ComObject Shell.Application).Namespace((Split-Path -Parent $lnk)).ParseName('murrtty.lnk')
$aumid = $item.ExtendedProperty('System.AppUserModel.ID')
Check ($aumid -eq 'murrtty.murrtty') "the shortcut's AppUserModelID is murrtty.murrtty (got '$aumid')"
Check (-not (Test-Path -LiteralPath $desk)) 'no desktop shortcut (an unchecked task)'

$want = "`"$exe`" +new-window `"--working-directory=%V.`""
foreach ($k in $verbs) {
    $key = "HKCU:\Software\Classes\$k\shell\murrtty"
    Check ((Get-Item -LiteralPath $key).GetValue('') -eq 'Open in murrtty') "$k's verb is named Open in murrtty"
    Check ((Get-Item -LiteralPath "$key\command").GetValue('') -eq $want) "$k's verb runs $want"
}
foreach ($dir in @('C:\', 'C:\Program Files')) {
    $argv = [MurrttyTest.Native]::Split($want.Replace('%V', $dir))
    Check ($argv.Count -eq 3 -and $argv[0] -eq $exe -and $argv[1] -eq '+new-window' -and $argv[2] -eq "--working-directory=$dir.") `
        "the verb's command line for $dir splits into its 3 arguments ($($argv -join ' | '))"
}
$un = Get-Item -LiteralPath $uninstallKey
Check ($un.GetValue('DisplayVersion') -eq $Version) "the uninstall entry names $Version"

Write-Host '==> Installing again over a running murrtty'
New-Item -Path $aumidKey -Force | Out-Null
Set-ItemProperty -LiteralPath $aumidKey -Name DisplayName -Value 'murrtty'
$env:MURRTTY_D3D = 'warp'
$running = Start-Process -FilePath $exe -ArgumentList @('--gtk-single-instance=false') -PassThru
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $running.Refresh()
    if ($running.HasExited -or $running.MainWindowHandle -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 250
}
Check (-not $running.HasExited -and $running.MainWindowHandle -ne [IntPtr]::Zero) 'murrtty runs, with a window'
Install (Join-Path $work 'reinstall.log')
Check ($running.WaitForExit(30000)) 'the running murrtty was closed by setup'
Start-Sleep -Seconds 3
Check (@(Murrtty-Processes).Count -eq 0) 'a silent install starts no murrtty (install on quit)'
$v = Run-Murrtty @('+version')
Check ($v.Code -eq 0 -and $v.Text -match [regex]::Escape("murrtty $Version")) 'murrtty runs after the reinstall'

Write-Host '==> Installing again as Restart to Update does'
$running = Start-Process -FilePath $exe -ArgumentList @('--gtk-single-instance=false') -PassThru
Check (Wait-Window $running) 'murrtty runs, with a window'
Install (Join-Path $work 'restart.log') @('/SP-', '/restart=1')
Check ($running.WaitForExit(30000)) 'the running murrtty was closed by setup'
$deadline = (Get-Date).AddSeconds(60)
$again = @()
while ((Get-Date) -lt $deadline) {
    $again = @(Murrtty-Processes | Where-Object { $_.Id -ne $running.Id })
    if ($again.Count -gt 0) { break }
    Start-Sleep -Milliseconds 250
}
Check ($again.Count -gt 0) 'setup started murrtty again (/restart=1)'
$again | Stop-Process -Force
# Its pseudoconsole hosts too, before the uninstall removes their folder.
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $left = @(Get-Process -Name murrtty, OpenConsole -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($app, [StringComparison]::OrdinalIgnoreCase) })
    if ($left.Count -eq 0) { break }
    $left | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 250
}

Write-Host '==> Uninstalling'
$p = Start-Process -FilePath (Join-Path $app 'unins000.exe') -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
Check ($p.ExitCode -eq 0) 'the uninstaller exits 0'
# The uninstaller runs from a copy of itself in TEMP, which may outlive
# the process waited for.
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline -and ((Test-Path -LiteralPath $uninstallKey) -or (Test-Path -LiteralPath $exe))) {
    Start-Sleep -Milliseconds 500
}
Check (-not (Test-Path -LiteralPath $exe)) 'murrtty.exe removed'
Check (-not (Test-Path -LiteralPath (Join-Path $app 'share'))) 'share\ removed'
Check (-not (Test-Path -LiteralPath $lnk)) 'the Start menu shortcut removed'
foreach ($k in $verbs) {
    Check (-not (Test-Path -LiteralPath "HKCU:\Software\Classes\$k\shell\murrtty")) "$k's verb removed"
}
Check (-not (Test-Path -LiteralPath $aumidKey)) "the toasts' AppUserModelID registration removed"
Check (-not (Test-Path -LiteralPath $uninstallKey)) 'the uninstall entry removed'
Check (Test-Path -LiteralPath $marker) "the user's %LOCALAPPDATA%\murrtty kept"
Remove-Item -LiteralPath $marker -Force
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'All installer checks passed.'
