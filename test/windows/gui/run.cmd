@echo off
rem Build a Debug ghostty.exe and the GUI test harness, then run the GUI
rem tests. They run on a hidden desktop, so nothing appears on screen; the
rem pixel check briefly adds a taskbar button. Arguments go to the harness:
rem   test\windows\gui\run.cmd --list
rem   test\windows\gui\run.cmd --verbose tabs clipboard
rem Zig comes from ZIG (zig.exe or its folder), the builder's
rem .zig-toolchain, or PATH.
setlocal
set "ROOT=%~dp0..\..\.."
pushd "%ROOT%" || exit /b 1

set "ZIGEXE="
if defined ZIG if exist "%ZIG%\zig.exe" set "ZIGEXE=%ZIG%\zig.exe"
if defined ZIG if not defined ZIGEXE if exist "%ZIG%" set "ZIGEXE=%ZIG%"
if not defined ZIGEXE for /d %%D in (".zig-toolchain\zig-*") do if exist "%%D\zig.exe" set "ZIGEXE=%%~fD\zig.exe"
if not defined ZIGEXE set "ZIGEXE=zig"

"%ZIGEXE%" build -Dtarget=x86_64-windows-gnu || goto failed
"%ZIGEXE%" build --build-file test\windows\gui\build.zig || goto failed
"test\windows\gui\zig-out\bin\ghostty-gui-test.exe" --ghostty "%CD%\zig-out\bin\ghostty.exe" %*
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%

:failed
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
