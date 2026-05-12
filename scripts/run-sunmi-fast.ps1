param(
    [string]$DeviceId = "VE03P2CF00209"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root "apps\pos_flutter"
$flutter = Join-Path $env:USERPROFILE "dev-tools\flutter\bin\flutter.bat"

if (-not (Test-Path $flutter)) {
    throw "Flutter was not found at $flutter"
}

$env:Path = "$(Split-Path $flutter);$env:Path"
Set-Location $app

Write-Host "Starting Light Winter RetailOS on SUNMI device $DeviceId" -ForegroundColor Cyan
Write-Host "After it launches: press r for hot reload, R for hot restart, q to quit." -ForegroundColor Yellow
& $flutter run -d $DeviceId --debug
