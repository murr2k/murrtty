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

    # Each load that wraps the prompt or the line editor makes a new
    # generation of wrappers, each calling the original it was made over
    # ($global:__GhosttyPromptOriginal<n>), never a shared one. A wrapper the
    # profile adds on top that chains to an older Ghostty wrapper (a venv's
    # or conda's prompt) then reaches that one, not itself again; called from
    # inside a newer Ghostty wrapper, it only passes the call on.
    if ($null -eq $global:__GhosttyWrappers) { $global:__GhosttyWrappers = [hashtable]::new() }
    if ($null -eq $global:__GhosttyGeneration) { $global:__GhosttyGeneration = 0 }

    function global:__GhosttyIsWrapper($block) {
        $null -ne $block -and $global:__GhosttyWrappers.ContainsKey($block)
    }

    # The line editor's wrapper calls its original first, so the editor
    # (PSReadLine, its predictors) still sees the last command's $?. Of
    # nested wrappers, the innermost reports the line; the outermost resets
    # that for the next one.
    $global:__GhosttyReadLineTemplate = @'
$line = & $global:__GhosttyReadLineOriginal__N__
Set-StrictMode -Off
if (-not $global:__GhosttyLineReported) {
    $global:__GhosttyLineReported = $true
    try { __GhosttyLineAccepted $line } catch {}
}
if ([object]::ReferenceEquals($function:PSConsoleHostReadLine, $global:__GhosttyReadLineWrapper__N__)) {
    $global:__GhosttyLineReported = $false
}
$line
'@

    $global:__GhosttyPromptTemplate = @'
$succeeded = $global:?
Set-StrictMode -Off
__GhosttyPrompt $succeeded ([object]::ReferenceEquals($function:prompt, $global:__GhosttyPromptWrapper__N__)) $global:__GhosttyPromptOriginal__N__
'@

    # A command line was accepted (PSReadLine's line editor returned it).
    function global:__GhosttyLineAccepted([string]$line) {
        if (-not $line.Trim()) { return }
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

    # PSReadLine's line editor, wrapped to report each accepted command line.
    # PSReadLine may load after this runs, or be loaded again, so the prompt
    # tries again whenever the editor isn't a Ghostty wrapper.
    function global:__GhosttyHookReadLine {
        if (-not (Test-Path Function:\PSConsoleHostReadLine)) { return }
        if (__GhosttyIsWrapper $function:PSConsoleHostReadLine) { return }
        $n = ++$global:__GhosttyGeneration
        Set-Variable -Scope Global -Name "__GhosttyReadLineOriginal$n" -Value $function:PSConsoleHostReadLine
        $wrapper = [scriptblock]::Create($global:__GhosttyReadLineTemplate.Replace('__N__', "$n"))
        Set-Item -Path Function:\global:PSConsoleHostReadLine -Value $wrapper
        Set-Variable -Scope Global -Name "__GhosttyReadLineWrapper$n" -Value $function:PSConsoleHostReadLine
        $global:__GhosttyWrappers[$function:PSConsoleHostReadLine] = $true
    }

    # The prompt. $succeeded is $? as the wrapper found it; $direct, whether
    # the host called the wrapper itself rather than another wrapper on top.
    function global:__GhosttyPrompt([bool]$succeeded, [bool]$direct, $original) {
        if ($global:__GhosttyInPrompt) {
            if (-not $succeeded) { Write-Error 'ghostty' -ErrorAction Ignore }
            return & $original
        }
        $exitCode = $global:LASTEXITCODE
        $errorAdded = $global:Error.Count -gt 0 -and
            -not [object]::ReferenceEquals($global:Error[0], $global:__GhosttyErrorBefore)
        $esc = [char]27
        $bel = [char]7
        $out = ''

        if ($global:__GhosttyCommandRunning) {
            $global:__GhosttyCommandRunning = $false
            # A native program (or a script's exit) stores a new LASTEXITCODE,
            # even for the same code. Called by the host, $? is the command's
            # own status; behind another wrapper it is that wrapper's, so the
            # error record and LASTEXITCODE decide.
            $before = $global:__GhosttyExitCodeBefore
            $nativeRan = $exitCode -and -not [object]::ReferenceEquals($exitCode, $before)
            $failed = (-not $succeeded) -or (-not $direct -and ($errorAdded -or $nativeRan))
            $status = if (-not $failed) { 0 } elseif ($nativeRan) { $exitCode } else { 1 }
            $out += "$esc]133;D;$status$bel"
        }

        $out += "$esc]7;$(__GhosttyPwdUrl)$bel"
        if ($global:__GhosttyFeatures['title']) { __GhosttySetTitle (__GhosttyTitle) }
        __GhosttyHookReadLine
        $cursor = $global:__GhosttyFeatures['cursor']
        if ($cursor -and (__GhosttyIsWrapper $function:PSConsoleHostReadLine)) {
            $out += if ("$cursor" -eq 'steady') { "$esc[6 q" } else { "$esc[5 q" }
        }
        $global:__GhosttyLineReported = $false

        # The prompt starts here, before the user's prompt runs: one that
        # writes with Write-Host is inside it too.
        [Console]::Write("$out$esc]133;P;k=i$bel")

        # The user's prompt sees the last command's $? and LASTEXITCODE: a
        # failing command just before the call leaves $? false (nothing may
        # run in between).
        $global:__GhosttyInPrompt = $true
        try {
            $global:LASTEXITCODE = $exitCode
            if (-not $succeeded) { Write-Error 'ghostty' -ErrorAction Ignore }
            $userPrompt = & $original
        } finally {
            $global:__GhosttyInPrompt = $false
        }
        $global:LASTEXITCODE = $exitCode
        "$userPrompt$esc]133;I$bel"
    }

    if (-not (__GhosttyIsWrapper $function:prompt)) {
        $n = ++$global:__GhosttyGeneration
        $original = if ($function:prompt) { $function:prompt } else {
            { "PS $($ExecutionContext.SessionState.Path.CurrentLocation)> " }
        }
        Set-Variable -Scope Global -Name "__GhosttyPromptOriginal$n" -Value $original
        $wrapper = [scriptblock]::Create($global:__GhosttyPromptTemplate.Replace('__N__', "$n"))
        Set-Item -Path Function:\global:prompt -Value $wrapper
        Set-Variable -Scope Global -Name "__GhosttyPromptWrapper$n" -Value $function:prompt
        $global:__GhosttyWrappers[$function:prompt] = $true
    }

    __GhosttyHookReadLine
}
