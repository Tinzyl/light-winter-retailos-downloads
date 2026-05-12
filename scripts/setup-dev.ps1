$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root "backend"
$venv = Join-Path $backend ".venv"
$python = Get-Command python -ErrorAction Stop

if (!(Test-Path $venv)) {
    & $python.Source -m venv $venv
}

$venvPython = Join-Path $venv "Scripts\python.exe"
& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r (Join-Path $backend "requirements.txt")

Write-Host "Backend environment ready."
Write-Host "Run tests: $venvPython -m pytest backend\tests"
Write-Host "Run API:   $venvPython -m uvicorn app.main:app --app-dir backend --reload"
