# Ghostty shell integration for PowerShell: Windows PowerShell 5.1 and
# PowerShell 7. Ghostty loads it after the profile when it starts PowerShell
# (shell-integration = detect or powershell), so it wraps whatever prompt the
# profile set. It can also be dot-sourced from a profile, at its end. Loading
# it again wraps a prompt or line editor set since, and nothing twice.
#
# It reports to the terminal:
#   OSC 133;P and I   around the prompt, so Ghostty knows an idle prompt
#                     (closing it doesn't ask) and can jump between prompts.
#                     P, not A: A's fresh-line would move Ghostty's cursor
#                     without ConPTY's, which keeps its own. I, not B: ConPTY
#                     repaints rows with line feeds, and after B those would
#                     mark output rows as prompt lines.
#   OSC 133;C         when a command line is accepted (needs PSReadLine)
#   OSC 133;D;status  when the command finishes
#   OSC 7             the working directory, for new tabs and splits; empty
#                     (unknown) where it isn't a local drive path
# and, as GHOSTTY_SHELL_FEATURES asks: a bar cursor at the prompt (cursor,
# with PSReadLine, which restores it), the folder or the running command as
# the title (title), and Ghostty's own folder on PATH (path).
#
# It runs with strict mode off, whatever the profile set. Keep this file
# ASCII: Ghostty reads it as text.

& {
    Set-StrictMode -Off

    $global:__GhosttyFeatures = @{}
    foreach ($feature in "$env:GHOSTTY_SHELL_FEATURES".Split(',')) {
        if (-not $feature) { continue }
        $parts = $feature.Split(':', 2)
        $global:__GhosttyFeatures[$parts[0]] = if ($parts.Count -gt 1) { $parts[1] } else { $true }
    }

    if ($global:__GhosttyFeatures['path'] -and $env:GHOSTTY_BIN_DIR) {
        $paths = "$env:PATH".Split([IO.Path]::PathSeparator)
        if ($paths -notcontains $env:GHOSTTY_BIN_DIR) {
            $env:PATH = "$env:PATH$([IO.Path]::PathSeparator)$env:GHOSTTY_BIN_DIR"
        }
    }

    if ($null -eq $global:__GhosttyCommandRunning) { $global:__GhosttyCommandRunning = $false }

    # This computer in OSC 7 URLs: its name when that is a DNS label (Ghostty
    # takes reports from this computer only), else localhost.
    $global:__GhosttyHost = if ("$env:COMPUTERNAME" -match '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$') {
        $env:COMPUTERNAME
    } else { 'localhost' }

    # The working directory as an OSC 7 file URL, or nothing when it isn't a
    # local drive path (a registry or environment location, a UNC share).
    function global:__GhosttyPwdUrl {
        $location = $ExecutionContext.SessionState.Path.CurrentLocation
        if ($location.Provider.Name -ne 'FileSystem') { return '' }
        $path = $location.ProviderPath
        if ($path -notmatch '^[A-Za-z]:\\') { return '' }
        $url = New-Object System.Text.StringBuilder
        foreach ($byte in [Text.Encoding]::UTF8.GetBytes($path.Replace('\', '/'))) {
            $keep = ($byte -ge 0x30 -and $byte -le 0x39) -or
                ($byte -ge 0x41 -and $byte -le 0x5A) -or
                ($byte -ge 0x61 -and $byte -le 0x7A) -or
                ('-._~/:'.IndexOf([char]$byte) -ge 0)
            if ($keep) { [void]$url.Append([char]$byte) } else { [void]$url.AppendFormat('%{0:X2}', $byte) }
        }
        "file://$global:__GhosttyHost/$url"
    }

    # The location for the title: the home folder as ~.
    function global:__GhosttyTitle {
        $path = $ExecutionContext.SessionState.Path.CurrentLocation.Path
        if ($HOME -and $path.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase) -and
            ($path.Length -eq $HOME.Length -or $path[$HOME.Length] -eq [char]92)) {
            $path = '~' + $path.Substring($HOME.Length)
        }
        $path
    }

    # The console refuses titles over 1023 characters; a title never stops a
    # command or a prompt, whatever $ErrorActionPreference says.
    function global:__GhosttySetTitle([string]$title) {
        if ($title.Length -gt 1023) { $title = $title.Substring(0, 1023) }
        try { $Host.UI.RawUI.WindowTitle = $title } catch {}
    }

    # PSReadLine's line editor, wrapped to report each accepted command line.
    # PSReadLine may load after this runs, or be loaded again, so the prompt
    # tries again whenever the editor isn't this wrapper.
    function global:__GhosttyHookReadLine {
        if (-not (Test-Path Function:\PSConsoleHostReadLine)) { return }
        if ($global:__GhosttyReadLine -and
            [object]::ReferenceEquals($function:PSConsoleHostReadLine, $global:__GhosttyReadLine)) { return }
        $global:__GhosttyOriginalReadLine = $function:PSConsoleHostReadLine
        function global:PSConsoleHostReadLine {
            Set-StrictMode -Off
            $line = & $global:__GhosttyOriginalReadLine
            try {
                if ($line -and $line.Trim()) {
                    $global:__GhosttyCommandRunning = $true
                    $global:__GhosttyExitCodeBefore = $global:LASTEXITCODE
                    $global:__GhosttyErrorBefore = if ($global:Error.Count) { $global:Error[0] } else { $null }
                    $esc = [char]27
                    $out = "$esc]133;C$([char]7)"
                    # Programs get the default cursor back.
                    if ($global:__GhosttyFeatures['cursor']) { $out += "$esc[0 q" }
                    [Console]::Write($out)
                    if ($global:__GhosttyFeatures['title']) { __GhosttySetTitle $line.Trim().Split("`n")[0] }
                }
            } catch {}
            $line
        }
        $global:__GhosttyReadLine = $function:PSConsoleHostReadLine
    }

    # The prompt, wrapped unless it already is this wrapper.
    if (-not ($global:__GhosttyPrompt -and [object]::ReferenceEquals($function:prompt, $global:__GhosttyPrompt))) {
        $global:__GhosttyOriginalPrompt = if ($function:prompt) { $function:prompt } else {
            { "PS $($ExecutionContext.SessionState.Path.CurrentLocation)> " }
        }

        function global:prompt {
            # First, before anything changes it.
            $succeeded = $global:?
            Set-StrictMode -Off
            $exitCode = $global:LASTEXITCODE
            $errorAdded = $global:Error.Count -gt 0 -and
                -not [object]::ReferenceEquals($global:Error[0], $global:__GhosttyErrorBefore)
            $esc = [char]27
            $bel = [char]7
            $out = ''

            if ($global:__GhosttyCommandRunning) {
                $global:__GhosttyCommandRunning = $false
                # $? is false after a failed cmdlet or native program, unless
                # another prompt wrapper ran first; a native program sets
                # LASTEXITCODE, a cmdlet adds an error record.
                $before = $global:__GhosttyExitCodeBefore
                $failed = (-not $succeeded) -or $errorAdded -or ($exitCode -and $exitCode -ne $before)
                $status = if (-not $failed) { 0 }
                    elseif ($exitCode -and ($exitCode -ne $before -or -not $errorAdded)) { $exitCode }
                    else { 1 }
                $out += "$esc]133;D;$status$bel"
            }

            $out += "$esc]7;$(__GhosttyPwdUrl)$bel"
            if ($global:__GhosttyFeatures['title']) { __GhosttySetTitle (__GhosttyTitle) }
            __GhosttyHookReadLine
            $cursor = $global:__GhosttyFeatures['cursor']
            if ($cursor -and $global:__GhosttyReadLine -and
                [object]::ReferenceEquals($function:PSConsoleHostReadLine, $global:__GhosttyReadLine)) {
                $out += if ("$cursor" -eq 'steady') { "$esc[6 q" } else { "$esc[5 q" }
            }

            # The prompt starts here, before the user's prompt runs: one that
            # writes with Write-Host is inside it too.
            [Console]::Write("$out$esc]133;P;k=i$bel")

            # The user's prompt sees the last command's $? and LASTEXITCODE: a
            # failing command just before the call leaves $? false (nothing
            # may run in between).
            $global:LASTEXITCODE = $exitCode
            if (-not $succeeded) { Write-Error 'ghostty' -ErrorAction Ignore }
            $userPrompt = & $global:__GhosttyOriginalPrompt
            $global:LASTEXITCODE = $exitCode

            "$userPrompt$esc]133;I$bel"
        }
        $global:__GhosttyPrompt = $function:prompt
    }

    __GhosttyHookReadLine
}
