@echo off
rem The on-screen checks, run before each release with the owner at the
rem screen: murrtty's windows over a backdrop, a toast, a tray icon, a
rem taskbar button and the touch keyboard each show for a few seconds.
rem Double-click it; no elevation is needed (an elevated run is a machine
rem setup of its own). The display's captures are compared with this
rem machine's golden samples, in GHOSTTY_GUI_GOLDEN (by default
rem %LOCALAPPDATA%\murrtty-gui-golden), a folder per machine setup: one
rem with no golden yet is recorded to be looked over, and one that differs
rem fails, its capture and a diff kept in the run folder. After deciding a
rem change is meant, set GHOSTTY_GUI_GOLDEN_UPDATE=1 and run it again to
rem record them all anew. Zig from ZIG, else ..\tools' Zig, else as run.cmd
rem finds it. Extra arguments go to the harness (--verbose, say).
setlocal
set "ROOT=%~dp0..\..\.."
if not defined ZIG if exist "%ROOT%\..\tools\zig-x86_64-windows-0.17.0\zig.exe" set "ZIG=%ROOT%\..\tools\zig-x86_64-windows-0.17.0"
if not defined GHOSTTY_GUI_GOLDEN set "GHOSTTY_GUI_GOLDEN=%LOCALAPPDATA%\murrtty-gui-golden"
set "GHOSTTY_GUI_ONSCREEN=1"
set "GHOSTTY_GUI_SPIKE=1"
rem PowerShell in murrtty would strip colors with it (an agent's shell sets it).
set "NO_COLOR="
call "%~dp0run.cmd" pixels transparency blur-display overlay-host taskbar-shown notify-shown tray-shown osk-shown %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo On-screen checks passed; goldens in %GHOSTTY_GUI_GOLDEN%.) else (echo On-screen checks failed, exit %RC%: the run folders above keep the captures and golden-diff-*.bmp.)
pause
exit /b %RC%
