$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root "apps\pos_flutter"
$flutter = Get-Command flutter -ErrorAction SilentlyContinue

if (!$flutter) {
    $candidate = Join-Path $env:USERPROFILE "dev-tools\flutter\bin\flutter.bat"
    if (Test-Path $candidate) {
        $flutter = @{ Source = $candidate }
    } else {
        throw "Flutter is not available. Install/repair Flutter, then rerun this script."
    }
}

Push-Location $app
try {
    & $flutter.Source pub get
    & $flutter.Source build apk --release
    Write-Host "APK output: $app\build\app\outputs\flutter-apk\app-release.apk"
} finally {
    Pop-Location
}
