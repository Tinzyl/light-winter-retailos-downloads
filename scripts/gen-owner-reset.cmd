@echo off
setlocal

set "DEVICE=%~1"
set "QUANTITY=%~2"
if "%QUANTITY%"=="" set "QUANTITY=1"

set "PROJECT_DIR=%~dp0.."
set "PYTHON=%PROJECT_DIR%\backend\.venv\Scripts\python.exe"

if not exist "%PYTHON%" (
  set "PYTHON=python"
)

if "%DEVICE%"=="" (
  "%PYTHON%" "%PROJECT_DIR%\scripts\generate-owner-reset-vouchers.py" --quantity %QUANTITY%
) else (
  "%PYTHON%" "%PROJECT_DIR%\scripts\generate-owner-reset-vouchers.py" --quantity %QUANTITY% --device %DEVICE%
)
exit /b %ERRORLEVEL%
