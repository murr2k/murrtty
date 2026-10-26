@echo off
rem Double-click friendly wrapper for build-windows.ps1: installs the build
rem requirements (Zig) and builds murrtty.exe. Arguments are forwarded, e.g.
rem   build-windows.cmd -Optimize Debug -Run
rem When double-clicked, build-windows.ps1 keeps the window open at the end.
setlocal

rem From a PowerShell 7 prompt, PSModulePath lists PowerShell 7's module
rem folders first and Windows PowerShell 5.1 then can't load its own
rem modules. Cleared (only inside this script), 5.1 rebuilds its default.
set "PSModulePath="

rem Full path, so a powershell.exe in the current directory is never run.
set "PS51=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

rem powershell.exe -File swallows -? and prints nothing, /? would reach zig
rem build as a step name, and a bare -- is an "ambiguous parameter" error.
rem Look for them as whole words anywhere in the arguments. This searches
rem the argument text rather than looping over %1..%9, which would split
rem -Dname=value at the = and choke on quotes and parentheses. The copy is
rem made unquoted and before delayed expansion, so the caller's quotes keep
rem protecting | & < > and ! survives; the dots pad it with spaces at both
rem ends. Known limit: a quoted value containing " -- " or " -? " matches.
set ARGS=. %* .
setlocal EnableDelayedExpansion
set "ACTION=build"
if not "!ARGS: -- =!"=="!ARGS!" set "ACTION=dashdash"
if not "!ARGS: -? =!"=="!ARGS!" set "ACTION=help"
if not "!ARGS: /? =!"=="!ARGS!" set "ACTION=help"
endlocal & set "ACTION=%ACTION%"

if "%ACTION%"=="help" goto help
if "%ACTION%"=="dashdash" goto dashdash

"%PS51%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1" %*
exit /b %ERRORLEVEL%

:help
"%PS51%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1" -Help
exit /b %ERRORLEVEL%

:dashdash
1>&2 echo error: a bare -- can't be passed through to zig build. To give murrtty
1>&2 echo arguments, build first, then run zig-out\bin\murrtty.exe with them.
exit /b 1
