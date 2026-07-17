@echo off
setlocal
cd /d "%~dp0"

rem Always rebuild the active worktree so this launcher never starts stale binaries.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-and-run.ps1" Debug
set EXIT_CODE=%ERRORLEVEL%

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Debug build failed. See the output above.
    pause
)

endlocal & exit /b %EXIT_CODE%
