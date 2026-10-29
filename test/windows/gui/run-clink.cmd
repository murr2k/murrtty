@echo off
rem The GUI tests that need Clink: cmd-integration (with its Clink part)
rem and clink-history. They build a Debug murrtty and run on a hidden
rem desktop, so nothing shows on screen. Double-click it; no elevation is
rem needed. Clink comes from GHOSTTY_GUI_CLINK, else the portable Clink
rem beside this checkout (..\tools\clink, as the project folder has it);
rem Zig from ZIG, else ..\tools' Zig, else as run.cmd finds it. Extra
rem arguments go to the harness (--verbose, say).
setlocal
set "ROOT=%~dp0..\..\.."
if not defined GHOSTTY_GUI_CLINK set "GHOSTTY_GUI_CLINK=%ROOT%\..\tools\clink"
if not defined ZIG if exist "%ROOT%\..\tools\zig-x86_64-windows-0.17.0\zig.exe" set "ZIG=%ROOT%\..\tools\zig-x86_64-windows-0.17.0"
if not exist "%GHOSTTY_GUI_CLINK%\clink_x64.exe" (
    echo No clink_x64.exe in %GHOSTTY_GUI_CLINK%: set GHOSTTY_GUI_CLINK to a Clink folder.
    pause
    exit /b 1
)
call "%~dp0run.cmd" cmd-integration clink-history %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo Clink tests passed.) else (echo Clink tests failed, exit %RC%: the run folders above are kept.)
pause
exit /b %RC%
