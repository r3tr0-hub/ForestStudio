@echo off
setlocal
cd /d "%~dp0"
echo Forest Studio WPF - build v0.4.1
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    echo ERROR: Windows PowerShell 5.1 was not found.
    pause
    exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build_WPF.ps1"
set "BUILD_RC=%ERRORLEVEL%"
echo.
if not "%BUILD_RC%"=="0" (
    echo ERROR: Compilation failed. Send the entire output.
) else (
    echo SUCCESS: You can start Forest_Studio_v0_4.ms in 3ds Max 2024.
)
pause
exit /b %BUILD_RC%
