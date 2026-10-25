# Ghostty shell integration for PowerShell: Windows PowerShell 5.1 and
# PowerShell 7. Ghostty loads it after the profile when it starts PowerShell
# (shell-integration = detect or powershell), so it wraps whatever prompt the
# profile set. It can also be dot-sourced from a profile, at its end.
#
# It reports to the terminal:
#   OSC 133;A and I   around the prompt, so Ghostty knows an idle prompt
#                     (closing it doesn't ask) and can jump between prompts.
#                     I, not B: ConPTY repaints rows with line feeds, and
#                     after B those would mark output rows as prompt lines.
#   OSC 133;C         when a command line is accepted (needs PSReadLine)
#   OSC 133;D;status  when the command finishes
#   OSC 7             the working directory, for new tabs and splits
# and, as GHOSTTY_SHELL_FEATURES asks: a bar cursor at the prompt (cursor),
# the folder or the running command as the title (title), and Ghostty's own
# folder on PATH (path).
#
# Keep this file ASCII: Ghostty reads it as text.

if ($global:__GhosttyIntegration) { return }
$global:__GhosttyIntegration = $true

$global:__GhosttyFeatures = @{}
foreach ($feature in "$env:GHOSTTY_SHELL_FEATURES".Split(',')) {
    if (-not $feature) { continue }
    $parts = $feature.Split(':', 2)
    $global:__GhosttyFeatures[$parts[0]] = if ($parts.Count -gt 1) { $parts[1] } else { $true }
}

if ($global:__GhosttyFeatures.path -and $env:GHOSTTY_BIN_DIR) {
    $paths = "$env:PATH".Split([IO.Path]::PathSeparator)
    if ($paths -notcontains $env:GHOSTTY_BIN_DIR) {
        $env:PATH = "$env:PATH$([IO.Path]::PathSeparator)$env:GHOSTTY_BIN_DIR"
    }
}

$global:__GhosttyCommandRunning = $false
$global:__GhosttyExitCodeBefore = $null

# The working directory as an OSC 7 file URL, or nothing when it isn't a
# local drive path (a registry or environment location, a UNC share).
function global:__GhosttyPwdUrl {
    $location = $ExecutionContext.SessionState.Path.CurrentLocation
    if ($location.Provider.Name -ne 'FileSystem') { return $null }
    $path = $location.ProviderPath
    if ($path -notmatch '^[A-Za-z]:\\') { return $null }
    $url = New-Object System.Text.StringBuilder
    foreach ($byte in [Text.Encoding]::UTF8.GetBytes($path.Replace('\', '/'))) {
        $keep = ($byte -ge 0x30 -and $byte -le 0x39) -or
            ($byte -ge 0x41 -and $byte -le 0x5A) -or
            ($byte -ge 0x61 -and $byte -le 0x7A) -or
            ('-._~/:'.IndexOf([char]$byte) -ge 0)
        if ($keep) { [void]$url.Append([char]$byte) } else { [void]$url.AppendFormat('%{0:X2}', $byte) }
    }
    "file://$env:COMPUTERNAME/$url"
}

# The location for the title: the home folder as ~.
function global:__GhosttyTitle {
    $path = $ExecutionContext.SessionState.Path.CurrentLocation.Path
    if ($HOME -and $path.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) {
        $path = '~' + $path.Substring($HOME.Length)
    }
    $path
}

# PSReadLine's line editor, wrapped to report each accepted command line.
# PSReadLine may load after this runs, so the prompt tries again.
function global:__GhosttyHookReadLine {
    if ($global:__GhosttyOriginalReadLine) { return }
    if (-not (Test-Path Function:\PSConsoleHostReadLine)) { return }
    $global:__GhosttyOriginalReadLine = $function:PSConsoleHostReadLine
    function global:PSConsoleHostReadLine {
        $line = & $global:__GhosttyOriginalReadLine
        if ($line -and $line.Trim()) {
            $global:__GhosttyCommandRunning = $true
            $global:__GhosttyExitCodeBefore = $global:LASTEXITCODE
            $esc = [char]27
            $out = "$esc]133;C$([char]7)"
            # Programs get the default cursor back.
            if ($global:__GhosttyFeatures.cursor) { $out += "$esc[0 q" }
            [Console]::Write($out)
            if ($global:__GhosttyFeatures.title) {
                $Host.UI.RawUI.WindowTitle = $line.Trim().Split("`n")[0]
            }
        }
        $line
    }
}

$global:__GhosttyOriginalPrompt = if ($function:prompt) { $function:prompt } else {
    { "PS $($ExecutionContext.SessionState.Path.CurrentLocation)> " }
}

function global:prompt {
    # First, before anything changes them.
    $succeeded = $global:?
    $exitCode = $global:LASTEXITCODE
    $esc = [char]27
    $bel = [char]7
    $out = ''

    if ($global:__GhosttyCommandRunning) {
        $global:__GhosttyCommandRunning = $false
        # A native program that ran sets LASTEXITCODE; a failed cmdlet only $?.
        $status = if ($succeeded) { 0 }
            elseif ($exitCode -ne $global:__GhosttyExitCodeBefore -and $exitCode) { $exitCode }
            else { 1 }
        $out += "$esc]133;D;$status$bel"
    }

    $url = __GhosttyPwdUrl
    if ($url) { $out += "$esc]7;$url$bel" }
    if ($global:__GhosttyFeatures.title) { $Host.UI.RawUI.WindowTitle = __GhosttyTitle }
    $cursor = $global:__GhosttyFeatures.cursor
    if ($cursor) { $out += if ("$cursor" -eq 'steady') { "$esc[6 q" } else { "$esc[5 q" } }
    __GhosttyHookReadLine

    # The user's prompt sees the last command's $? and LASTEXITCODE: a
    # failing command just before the call leaves $? false (nothing may run
    # in between).
    $global:LASTEXITCODE = $exitCode
    if (-not $succeeded) { Write-Error 'ghostty' -ErrorAction Ignore }
    $userPrompt = & $global:__GhosttyOriginalPrompt
    $global:LASTEXITCODE = $exitCode

    "$out$esc]133;A$bel$userPrompt$esc]133;I$bel"
}

__GhosttyHookReadLine
