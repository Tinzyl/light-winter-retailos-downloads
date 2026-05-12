@echo off
setlocal

if "%~1"=="" goto usage
if "%~2"=="" goto usage
if "%~3"=="" goto usage

set "MODE=%~1"
set "VALUE=%~2"
set "DEVICE=%~3"
set "QUANTITY=%~4"
if "%QUANTITY%"=="" set "QUANTITY=1"

set "PROJECT_DIR=%~dp0.."
set "PYTHON=%PROJECT_DIR%\backend\.venv\Scripts\python.exe"

if not exist "%PYTHON%" (
  set "PYTHON=python"
)

"%PYTHON%" "%PROJECT_DIR%\scripts\generate-supabase-license-tokens.py" --mode %MODE% --value %VALUE% --quantity %QUANTITY% --device %DEVICE%
exit /b %ERRORLEVEL%

:usage
echo Usage:
echo   gen-license.cmd days 30 LWR-123456
echo   gen-license.cmd minutes 60 LWR-123456
echo.
echo Output:
echo   Copy the generated SQL into Supabase SQL Editor and run it.
exit /b 1
