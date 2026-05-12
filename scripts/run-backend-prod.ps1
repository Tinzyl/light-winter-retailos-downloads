$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root "backend"
$python = Join-Path $backend ".venv\Scripts\python.exe"

if (!(Test-Path $python)) {
    throw "Backend virtual environment not found. Run scripts\setup-dev.ps1 first."
}

& $python -m uvicorn app.main:app --app-dir $backend --host 0.0.0.0 --port 8000
