<#
.SYNOPSIS
    Install the build requirements and build Ghostty for Windows.

.DESCRIPTION
    1. Checks the system (Windows 10 1809 or newer, 64-bit).
    2. Looks for a Zig with the same major.minor version as the
       minimum_zig_version in build.zig.zon and at least its patch release,
       in this order: the ZIG environment variable (the full path to
       zig.exe, or its folder), .zig-toolchain\ next to this script, then
       zig on PATH. If none is found, downloads exactly that version from
       ziglang.org into .zig-toolchain\ and verifies its SHA-256. Nothing is
       installed system-wide and PATH is not changed. (zig build unpacks
       Ghostty's dependencies into zig-pkg\ next to this script and caches
       downloads per user in %LOCALAPPDATA%\zig.)
    3. Runs `zig build` for Windows and reports where ghostty.exe is.

    The first build downloads Ghostty's source dependencies, so it needs an
    internet connection and takes several minutes. Later builds are
    incremental.

    Run it with build-windows.cmd, from cmd, from either PowerShell or by
    double-clicking: it runs this script in the Windows PowerShell 5.1 that
    ships with Windows, without changing your execution policy. Arguments
    the script doesn't know go to zig build (see ZigArgs). From a
    PowerShell prompt, quote one that contains a comma or a space
    ('-Dname=a,b'). PowerShell 7 can also run the .ps1 directly, but
    pwsh -File drops the colon from an argument like -Dname=C:\path, quoted
    or not.

    PowerShell accepts unambiguous abbreviations of the options below (-Opt,
    -Pre). Of PowerShell's common parameters, -Debug is rejected (for a
    debug build use -Optimize Debug), -Verbose is passed to zig build as
    --verbose, and the others don't change the build.

.PARAMETER Optimize
    Debug, ReleaseSafe, ReleaseFast (default) or ReleaseSmall.

.PARAMETER Prefix
    Install prefix: ghostty.exe ends up in <Prefix>\bin. A relative path is
    relative to the current directory. Default: zig-out next to this script.
    Don't end a quoted path with a backslash ("C:\out\"): Windows reads \"
    as a literal quote. Write "C:\out" instead.

.PARAMETER Target
    Zig target triple. Default: x86_64-windows-gnu. Give the ABI (-gnu)
    explicitly: the GNU ABI uses the MinGW-w64 libc bundled with Zig, while
    a triple without an ABI, or native, makes Ghostty's build use MSVC,
    which needs Visual Studio and the Windows SDK.

.PARAMETER Run
    Start ghostty.exe after a successful build.

.PARAMETER SetupOnly
    Install the requirements (and clean, with -Clean), then stop without
    building.

.PARAMETER Clean
    Delete .zig-cache, and zig-out when no -Prefix is given, before
    building. A custom -Prefix directory is never deleted, and the
    downloaded dependencies (zig-pkg\) and Zig (.zig-toolchain\) are kept.

.PARAMETER Help
    Show this help. -h, --help, -? and /? work too.

.PARAMETER ZigArgs
    Not written by name: this collects every argument the script doesn't
    recognize, and each is passed to `zig build`: -D options (written
    -Dname=value), steps such as test, or flags such as --summary all.
    --verbose (or -Verbose) turns on zig build's --verbose. Use -Optimize,
    -Target and -Prefix instead of -Doptimize=, -Dtarget= and --prefix.
    A bare -- can't be passed (PowerShell takes it), so neither can
    arguments for `zig build run -- ...`: build, then run
    zig-out\bin\ghostty.exe with the arguments instead.

.EXAMPLE
    .\build-windows.cmd
    Release build into zig-out\bin\ghostty.exe.

.EXAMPLE
    .\build-windows.cmd -Optimize Debug -Run

.EXAMPLE
    .\build-windows.cmd -Dstrip=false
    Keep debug information in a release build (passed to zig build).

.EXAMPLE
    .\build-windows.cmd > build.log 2>&1
    Keep a log of the build.
#>

# Advanced script without positional binding: the options above bind by
# name only, and everything else collects in $ZigArgs for zig build.
[CmdletBinding(PositionalBinding = $false)]
param(
    # Validated below rather than with ValidateSet, so a bad value gets a
    # readable error and the double-click pause.
    [string]$Optimize = 'ReleaseFast',
    [string]$Prefix = '',
    [string]$Target = 'x86_64-windows-gnu',
    [switch]$Run,
    [switch]$SetupOnly,
    [switch]$Clean,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ZigArgs = @()
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
# PowerShell 7.3+: don't let a profile setting turn zig's exit code into an
# exception; exit codes are checked explicitly.
$PSNativeCommandUseErrorActionPreference = $false

# powershell.exe -File (build-windows.cmd) binds zig's --verbose to the
# -Verbose common parameter, so it never reaches $ZigArgs. Hand it to zig
# build, and keep PowerShell's own verbose output quiet.
if ($PSBoundParameters.ContainsKey('Verbose') -and $PSBoundParameters['Verbose'] -and
    $ZigArgs -cnotcontains '--verbose') {
    $ZigArgs = @('--verbose') + @($ZigArgs)
}
$VerbosePreference = 'SilentlyContinue'

# SHA-256 of Zig releases, checked in addition to ziglang.org's index so a
# tampered index alone can't substitute the archive. Add an entry whenever
# minimum_zig_version in build.zig.zon changes.
$PinnedZigSha256 = @{
    '0.17.0/x86_64-windows' = 'b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428'
}

$Root = $PSScriptRoot
$ToolchainDir = Join-Path $Root '.zig-toolchain'
$OwnOptions = @('Optimize', 'Prefix', 'Target', 'Run', 'SetupOnly', 'Clean', 'Help')
$OptimizeModes = @('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note([string]$Message) {
    Write-Host "    $Message" -ForegroundColor Yellow
}

# True when started from Explorer (double-clicking build-windows.cmd, or
# "Run with PowerShell"), where the console window closes when we exit. An
# interactive prompt that Explorer started stays open and doesn't count, and
# a new window opened with start or Start-Process isn't detected.
function Test-LaunchedFromExplorer {
    try {
        $id = $PID
        # This process, then its parent (cmd.exe when run via the wrapper).
        for ($i = 0; $i -lt 2; $i++) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -OperationTimeoutSec 5 -ErrorAction Stop
            if (-not $proc) { return $false }
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)" -OperationTimeoutSec 5 -ErrorAction Stop
            if (-not $parent) { return $false }
            if ($parent.Name -ieq 'explorer.exe') {
                if ($i -gt 0) { return $true }
                # "Run with PowerShell" names this script on the command
                # line; an interactive PowerShell from the Start menu doesn't.
                return ([string]$proc.CommandLine).IndexOf(
                    (Split-Path -Leaf $PSCommandPath), [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
            if ($parent.Name -ine 'cmd.exe') { return $false }
            # Only a `cmd /c` (or /r) closes when we exit; an interactive
            # prompt stays.
            if ([string]$parent.CommandLine -notmatch '\s/[cCrR](?![a-zA-Z_])') { return $false }
            $id = $parent.ProcessId
        }
    } catch { }
    return $false
}

function Exit-Script([int]$Code) {
    if (Test-LaunchedFromExplorer) {
        Write-Host ''
        Read-Host 'Press Enter to close this window' | Out-Null
    }
    exit $Code
}

function Fail([string]$Message, [int]$Code = 1) {
    Write-Host "error: $Message" -ForegroundColor Red
    Write-Host 'For help: build-windows.cmd -Help'
    Exit-Script $Code
}

# Report any unexpected error the same way as Fail, so a double-clicked
# window still stays open long enough to read it.
trap { Fail ("{0} (build-windows.ps1 line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) }

# PowerShell splits a bare -Dname=value after a dot (-Dversion-string=1.2.3
# arrives as '-Dversion-string=1' '.2.3') and, when this script is run
# directly, after the colon of a path or URL (-Dname=C:\x arrives as
# '-Dname=C:' '\x'). Put the pieces back together.
$joined = @()
foreach ($a in $ZigArgs) {
    if ($joined.Count -gt 0 -and $joined[-1] -like '-D*=*' -and
        ($a.StartsWith('.') -or ($joined[-1].EndsWith(':') -and $a -match '^[\\/]'))) {
        $joined[-1] += $a
    } else {
        $joined += $a
    }
}
$ZigArgs = $joined

# Help requests that reach zig build's arguments: cmd-style ones, which
# zig build would take for a step name, and --help when this script runs
# directly (powershell.exe -File binds it to -Help itself).
if (@($ZigArgs | Where-Object { $_ -match '^(/(\?|h|help)|--help)$' }).Count -gt 0) { $Help = $true }

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    Exit-Script 0
}

if ($PSBoundParameters.ContainsKey('Debug')) {
    Fail '-Debug is a PowerShell option here. For a debug build use -Optimize Debug.'
}

$mode = $OptimizeModes | Where-Object { $_ -ieq $Optimize } | Select-Object -First 1
if (-not $mode) {
    Fail ("-Optimize must be one of: " + ($OptimizeModes -join ', ') + " (got '$Optimize').")
}
$Optimize = $mode

if (-not (Test-Path -LiteralPath (Join-Path $Root 'build.zig'))) {
    Fail "build.zig not found next to this script ($Root)."
}

#---------------------------------------------------------------------
# Arguments for zig build

foreach ($a in $ZigArgs) {
    if ($a -match '^-D(optimize|target)=') {
        Fail "Use -Optimize or -Target instead of '$a': the script already passes it."
    }
    # (Through build-windows.cmd, --prefix written with a space binds to
    # -Prefix itself; run directly, it lands here.)
    if ($a -match '^--prefix(=|$)') {
        Fail "Use -Prefix instead of '$a': the script already passes it."
    }
    if ($OptimizeModes -contains $a) {
        Fail "Use -Optimize $a. A bare '$a' would be passed to zig build as a step name."
    }
    # zig build's own short flags are -D..., -f..., -j..., -h and -l (case
    # matters); any other single-dash word is most likely a mistyped
    # script option.
    if ($a -match '^-[^-]' -and $a -cnotmatch '^-(D|f|j)' -and $a -cnotmatch '^-(h|l)$') {
        $name = $a.TrimStart('-')
        $guess = $OwnOptions | Where-Object {
            $_.Length -ge 3 -and $name.Length -ge 3 -and
            $_.Substring(0, 3) -ieq $name.Substring(0, [Math]::Min(3, $name.Length))
        } | Select-Object -First 1
        $hint = if ($guess) { " Did you mean -$($guess)?" } else { '' }
        Fail ("Unknown option '$a'.$hint Script options: -" + ($OwnOptions -join ', -') +
            '. Options for zig build must start with -D, -f, -j or -- (for example --summary).')
    }
}

if ($Prefix.Contains('"')) {
    Fail ('-Prefix contains a double quote: ' + $Prefix + '. A quoted path that ends in a ' +
        'backslash, like "C:\out\", escapes its closing quote. Leave off the trailing backslash.')
}
$defaultPrefix = Join-Path $Root 'zig-out'
if ($Prefix -eq '') { $Prefix = $defaultPrefix }
# Windows PowerShell 5.1 started in a folder whose path contains [ or ]
# begins in $PSHOME instead (the process directory is still right), so
# take a relative prefix from the process directory in that case.
$startDir = [Environment]::CurrentDirectory
if (-not [IO.Path]::IsPathRooted($Prefix) -and -not $Prefix.StartsWith('~') -and
    $PWD.ProviderPath -ieq $PSHOME -and $startDir.IndexOfAny([char[]]'[]') -ge 0) {
    $Prefix = [IO.Path]::Combine($startDir, $Prefix)
}
# Resolve now: the build runs from $Root, so a relative prefix would
# otherwise mean different directories to zig and to this script.
$Prefix = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Prefix)
# A trailing backslash would escape the closing quote Windows PowerShell
# adds around an argument with spaces. Keep it only for a drive root.
$trimmed = $Prefix.TrimEnd('\', '/')
if ($trimmed -and $trimmed -notmatch '^[A-Za-z]:$') { $Prefix = $trimmed }

#---------------------------------------------------------------------
# System checks

Write-Step 'Checking the system'

$osBuild = [Environment]::OSVersion.Version.Build
if ($osBuild -lt 17763) {
    Fail "Windows 10 version 1809 (build 17763) or newer is required for ConPTY; this is build $osBuild."
}

# PROCESSOR_ARCHITEW6432 is set when a 32-bit PowerShell runs on 64-bit Windows.
$arch = $env:PROCESSOR_ARCHITEW6432
if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
switch ($arch) {
    'AMD64' { $zigHost = 'x86_64' }
    'ARM64' { $zigHost = 'aarch64' }
    default { Fail "Unsupported processor architecture '$arch'. A 64-bit (x64 or ARM64) Windows is required." }
}

# Ghostty's build (src/build/Config.zig) switches a Windows target with no
# explicit ABI, including 'native', to MSVC, which needs Visual Studio.
$targetParts = $Target.Split('-')
$targetOs = if ($targetParts.Count -ge 2) { $targetParts[1] } else { 'native' }
if ($targetOs -notmatch '^(windows|native)(\.|$)') {
    Write-Note "-Target $Target is not a Windows target; this port only builds the Windows app."
} elseif ($targetParts.Count -lt 3) {
    Write-Note ("-Target $Target names no ABI, so Ghostty's build uses MSVC, which needs Visual Studio " +
        "and the Windows SDK. Add -gnu (for example $zigHost-windows-gnu) to build with Zig alone.")
} elseif ($targetParts[2] -like 'msvc*') {
    Write-Note "-Target $Target uses the MSVC ABI, which needs Visual Studio and the Windows SDK."
}
if ($arch -eq 'ARM64' -and $osBuild -lt 22000 -and $Target -like 'x86_64-*') {
    Write-Note 'Windows 10 on ARM cannot run x64 programs: this build will only run on an x64 PC or on Windows 11 on ARM.'
}

# Windows PowerShell 5.1 may not offer TLS 1.2 by default.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Note 'git not found: the build works, but the version will read <version>-dev+0000000.'
} elseif (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
    Write-Note 'This is not a git checkout: the version will read <version>-dev+0000000 (pass -Dversion-string=X.Y.Z to set it).'
}

#---------------------------------------------------------------------
# Zig

$zon = Get-Content -Raw -LiteralPath (Join-Path $Root 'build.zig.zon')
if ($zon -notmatch '\.minimum_zig_version\s*=\s*"(\d+)\.(\d+)\.(\d+)"') {
    Fail 'Could not read minimum_zig_version from build.zig.zon.'
}
$zigVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
$zigMajorMinor = "$($Matches[1]).$($Matches[2])"
$zigPatch = [int]$Matches[3]

# Zig breaks compatibility between minor versions, so require the same
# major.minor and at least the required patch release.
function Test-ZigVersion([string]$Exe) {
    # Collect all output before reading the exit code: piping a native
    # command into Select-Object -First stops it early, and Windows
    # PowerShell 5.1 then reports exit code -1 (PowerShell 7 leaves
    # $LASTEXITCODE unset). 'Continue' keeps stderr output from becoming a
    # terminating error.
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe version 2>$null)
        $code = $LASTEXITCODE
    } catch {
        return $false
    }
    if ($code -ne 0 -or $out.Count -eq 0) { return $false }
    if (([string]$out[0]).Trim() -match '^(\d+)\.(\d+)\.(\d+)$') {
        return ("$($Matches[1]).$($Matches[2])" -eq $zigMajorMinor) -and ([int]$Matches[3] -ge $zigPatch)
    }
    return $false
}

function Get-Sha256([string]$Path) {
    # .NET rather than Get-FileHash: in Windows PowerShell 5.1 that is a
    # module function, which fails to load when PSModulePath was inherited
    # from PowerShell 7.
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Save-Url([string]$Url, [string]$Path) {
    # WebClient, not Invoke-WebRequest -OutFile: 5.1 treats -OutFile as a
    # wildcard path, which breaks on folders named with [ ]. The task is
    # polled for progress: a scriptblock DownloadProgressChanged handler
    # runs on a thread with no runspace and kills Windows PowerShell 5.1.
    $wc = New-Object Net.WebClient
    try {
        $task = $wc.DownloadFileTaskAsync($Url, $Path)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $next = 5
        $lastSize = -1
        $lastGrowth = 0.0
        while (-not $task.IsCompleted) {
            Start-Sleep -Milliseconds 250
            $now = $clock.Elapsed.TotalSeconds
            $file = New-Object IO.FileInfo $Path
            $size = if ($file.Exists) { $file.Length } else { 0 }
            if ($size -ne $lastSize) {
                $lastSize = $size
                $lastGrowth = $now
            }
            # The async download has no timeout of its own.
            if ($now - $lastGrowth -ge 120) {
                # Let the cancel close the file, so the caller can delete it.
                $wc.CancelAsync()
                try { $null = $task.Wait(5000) } catch { }
                throw 'the download stalled (no data for 2 minutes)'
            }
            if ($now -ge $next) {
                $next += 5
                if ($size -gt 0) { Write-Host ("    {0:N0} MB downloaded" -f ($size / 1MB)) }
            }
        }
        # Rethrows the real error if the download failed. (Assigned: 5.1
        # writes a $null to the output for this void call.)
        $null = $task.GetAwaiter().GetResult()
    } finally {
        if ($wc.IsBusy) { $wc.CancelAsync() }
        $wc.Dispose()
    }
}

function Install-Zig {
    $key = "$zigVersion/$zigHost-windows"
    $pinned = $PinnedZigSha256[$key]
    $url = $null
    $sha = $null

    Write-Step "Downloading Zig $zigVersion for $zigHost-windows (about 100 MB)"
    try {
        $index = Invoke-RestMethod -UseBasicParsing -Uri 'https://ziglang.org/download/index.json'
        $release = $index.PSObject.Properties[$zigVersion]
        $entry = $null
        if ($release) { $entry = $release.Value.PSObject.Properties["$zigHost-windows"] }
        if ($entry) {
            $url = $entry.Value.tarball
            $sha = $entry.Value.shasum
        } else {
            Write-Note "the ziglang.org index has no $key release"
        }
    } catch {
        Write-Note "could not read the ziglang.org release index: $($_.Exception.Message)"
    }

    if ($pinned) {
        if ($sha -and ($sha.ToLowerInvariant() -ne $pinned)) {
            Fail "The ziglang.org index lists SHA-256 $sha for $key, but this script pins $pinned. Refusing to continue."
        }
        $sha = $pinned
        if (-not $url) { $url = "https://ziglang.org/download/$zigVersion/zig-$zigHost-windows-$zigVersion.zip" }
    } elseif ($sha) {
        Write-Note "no pinned SHA-256 for $key in this script; trusting the hash from the ziglang.org index."
    }
    if (-not $url -or -not $sha) {
        Fail "No download information for Zig $key. Install it yourself and set the ZIG environment variable to the full path of zig.exe."
    }

    New-Item -ItemType Directory -Force -Path $ToolchainDir | Out-Null
    $zip = Join-Path $ToolchainDir "zig-$zigHost-windows-$zigVersion.zip"
    # A short name keeps extracted paths under the classic 260-character
    # limit for as long as possible.
    $staging = Join-Path $ToolchainDir '.tmp'
    try {
        try {
            Save-Url $url $zip
        } catch {
            # WebClient's own message is generic; the cause is innermost.
            $why = $_.Exception.Message
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            if ($inner.Message -ne $why) { $why += " ($($inner.Message))" }
            Fail "Download of $url failed: $why"
        }

        $actual = Get-Sha256 $zip
        if ($actual -ne $sha.ToLowerInvariant()) {
            Fail "SHA-256 mismatch for $url (expected $sha, got $actual). The download was deleted."
        }
        Write-Host "    SHA-256 verified ($actual)"

        # Extract into a staging directory first so an interrupted
        # extraction never leaves a half-populated toolchain behind.
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        try {
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staging)
        } catch {
            $why = $_.Exception.Message
            if ($_.Exception.InnerException) { $why = $_.Exception.InnerException.Message }
            Fail ("Extracting $zip failed: $why`n" +
                'If a path was too long, move the repository to a shorter folder (for example C:\src\ghostty-windows) ' +
                'or enable Win32 long paths.')
        }

        $inner = Get-ChildItem -Directory -LiteralPath $staging | Select-Object -First 1
        if (-not $inner -or -not (Test-Path -LiteralPath (Join-Path $inner.FullName 'zig.exe'))) {
            Fail "Unexpected archive layout in $zip."
        }
        $dest = Join-Path $ToolchainDir $inner.Name
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath $inner.FullName -Destination $dest
    } finally {
        foreach ($p in @($zip, $staging)) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    return (Join-Path $dest 'zig.exe')
}

Write-Step "Looking for Zig $zigVersion"
$zig = $null
$candidates = @()
$zigEnv = $null
if ($env:ZIG) {
    # Accept the folder as well as zig.exe, and a value set with quotes.
    $zigEnv = $env:ZIG.Trim().Trim('"').Trim()
    try {
        if (-not $zigEnv) { throw 'empty' }
        # Relative to the starting directory, as for -Prefix above.
        if (-not [IO.Path]::IsPathRooted($zigEnv) -and $PWD.ProviderPath -ieq $PSHOME -and
            $startDir.IndexOfAny([char[]]'[]') -ge 0) {
            $zigEnv = [IO.Path]::Combine($startDir, $zigEnv)
        }
        if (Test-Path -LiteralPath $zigEnv -PathType Container) { $zigEnv = Join-Path $zigEnv 'zig.exe' }
        $candidates += $zigEnv
    } catch {
        Write-Note "ZIG is set to '$env:ZIG', which is not a usable path; ignoring it."
        $zigEnv = $null
    }
}
$candidates += (Join-Path $ToolchainDir "zig-$zigHost-windows-$zigVersion\zig.exe")
$onPath = Get-Command zig -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($onPath) { $candidates += $onPath.Path }

foreach ($candidate in $candidates) {
    if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-ZigVersion $candidate)) {
        $zig = (Resolve-Path -LiteralPath $candidate).ProviderPath
        break
    }
}

if ($zigEnv) {
    $resolved = Resolve-Path -LiteralPath $zigEnv -ErrorAction SilentlyContinue
    if (-not $resolved -or $resolved.ProviderPath -ne $zig) {
        Write-Note "ZIG is set to '$env:ZIG', but that is not Zig $zigMajorMinor.x (it must be the full path to zig.exe or its folder); ignoring it."
    }
}

if (-not $zig) {
    # The path is Install-Zig's last output; take only that, in case a
    # statement in it ever writes something else to the pipeline.
    $zig = @(Install-Zig)[-1]
    if (-not (Test-ZigVersion $zig)) {
        Fail "The installed Zig at $zig did not report version $zigVersion."
    }
}
Write-Host "    using $zig"

#---------------------------------------------------------------------
# Clean

if ($Clean) {
    $cache = Join-Path $Root '.zig-cache'
    Write-Step "Cleaning $cache"
    if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force }
    # Only the default prefix is ours to delete: a custom one may be a
    # shared directory that holds other files.
    if ($Prefix -ieq $defaultPrefix) {
        Write-Step "Cleaning $Prefix"
        if (Test-Path -LiteralPath $Prefix) { Remove-Item -LiteralPath $Prefix -Recurse -Force }
    } else {
        Write-Note "-Clean leaves the custom prefix $Prefix in place; delete old files there yourself if needed."
    }
}

if ($SetupOnly) {
    Write-Step 'Requirements installed. Not building (-SetupOnly).'
    Exit-Script 0
}

#---------------------------------------------------------------------
# Build

# Only the install step (the default when no step is named) puts
# ghostty.exe into the prefix. Other steps (test, run, uninstall) and the
# flags that print and exit (-l, --fetch, ...) leave it alone, so don't
# check for it or start it after those. Flags that take a separate value
# (Zig 0.17's lib/compiler/Maker.zig, plus the zig driver's cache and lib
# directories) are skipped with their value, so the `all` in
# `--summary all` is not taken for a step.
$valueFlags = @('--search-prefix', '--sysroot', '--libc', '--system', '--libc-runtimes',
    '--glibc-runtimes', '--prefix-lib-dir', '--prefix-exe-dir', '--prefix-include-dir', '--color',
    '--error-style', '--multiline-errors', '--summary', '--maxrss', '--test-timeout', '--debounce',
    '--fork', '--error-limit', '--build-file', '--cache-dir', '--pkg-dir', '--global-cache-dir',
    '--zig-lib-dir', '--debug-target', '--debug-log')
$steps = @()
$exeDir = Join-Path $Prefix 'bin'
for ($i = 0; $i -lt $ZigArgs.Count; $i++) {
    if ($valueFlags -contains $ZigArgs[$i]) {
        if ($ZigArgs[$i] -eq '--prefix-exe-dir' -and $i + 1 -lt $ZigArgs.Count) {
            # Relative to the prefix, like zig's.
            $exeDir = $ZigArgs[$i + 1]
            if (-not [IO.Path]::IsPathRooted($exeDir)) { $exeDir = Join-Path $Prefix $exeDir }
        }
        $i++
        continue
    }
    if ($ZigArgs[$i] -notlike '-*') { $steps += $ZigArgs[$i] }
}
$printsAndExits = @($ZigArgs | Where-Object {
    $_ -cin '-l', '--list-steps', '-h', '--help', '--print-configuration', '--print-configuration-path' -or
    $_ -like '--fetch*' })
# Options with which the install step builds no ghostty.exe: the embedding
# library alone (-Dapp-runtime=none), no exe, or libghostty-vt alone
# (emit-exe then defaults to false).
$noExe = @($ZigArgs | Where-Object {
    $_ -match '^-D(app-runtime=none|emit-exe=false)$' -or
    ($_ -match '^-Demit-lib-vt(=true)?$' -and -not ($ZigArgs -cmatch '^-Demit-exe(=true)?$')) })
$installs = ($steps.Count -eq 0 -or $steps -ccontains 'install') -and $printsAndExits.Count -eq 0 -and
    $noExe.Count -eq 0

$zigArgs = @('build', "-Dtarget=$Target", "-Doptimize=$Optimize", '--prefix', $Prefix) + $ZigArgs
$shown = ($zigArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
Write-Step "zig $shown"
if (-not (Test-Path -LiteralPath (Join-Path $Root '.zig-cache'))) {
    Write-Host '    The first build downloads dependencies and takes several minutes.'
}

$timer = [Diagnostics.Stopwatch]::StartNew()
Push-Location -LiteralPath $Root
# With 'Stop', Windows PowerShell 5.1 turns each line zig writes to stderr
# into a terminating error whenever the caller redirects this script's
# output (`*> build.log`). The exit code decides success instead.
$ErrorActionPreference = 'Continue'
try {
    & $zig @zigArgs
    $code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = 'Stop'
    Pop-Location
}
$timer.Stop()

if ($code -ne 0) {
    Fail "zig build failed with exit code $code. The first error above is the cause." $code
}

if (-not $installs) {
    Write-Step ("zig build finished in {0:mm\:ss}" -f $timer.Elapsed)
    if ($Run) { Write-Note "-Run ignored: this build doesn't install ghostty.exe." }
    Exit-Script 0
}

$exe = Join-Path $exeDir 'ghostty.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    Fail "The build succeeded but $exe was not produced."
}
$sizeMb = [Math]::Round((Get-Item -LiteralPath $exe).Length / 1MB, 1)
Write-Step ("Built {0} ({1} MB) in {2:mm\:ss}" -f $exe, $sizeMb, $timer.Elapsed)

if ($Run) {
    if ($arch -eq 'ARM64' -and $osBuild -lt 22000 -and $Target -like 'x86_64-*') {
        Write-Note 'Not starting Ghostty: Windows 10 on ARM cannot run x64 programs.'
    } else {
        Write-Step 'Starting Ghostty'
        Start-Process -FilePath $exe
    }
}

Exit-Script 0
