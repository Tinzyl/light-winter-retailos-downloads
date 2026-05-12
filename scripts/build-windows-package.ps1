$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root "apps\pos_flutter"
$out = Join-Path $root "dist"
$flutter = Get-Command flutter -ErrorAction SilentlyContinue

if (!$flutter) {
    $candidate = Join-Path $env:USERPROFILE "dev-tools\flutter\bin\flutter.bat"
    if (Test-Path $candidate) {
        $flutter = @{ Source = $candidate }
    } else {
        throw "Flutter is not available. Install/repair Flutter, then rerun this script."
    }
}

New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $app
try {
    & $flutter.Source config --enable-windows-desktop
    if ($LASTEXITCODE -ne 0) { throw "Flutter config failed with exit code $LASTEXITCODE." }
    & $flutter.Source pub get
    if ($LASTEXITCODE -ne 0) { throw "Flutter pub get failed with exit code $LASTEXITCODE." }
    & $flutter.Source build windows --release
    if ($LASTEXITCODE -ne 0) { throw "Flutter Windows build failed with exit code $LASTEXITCODE. Enable Windows Developer Mode, then rerun this script." }
    $build = Join-Path $app "build\windows\x64\runner\Release"
    if (!(Test-Path $build)) { throw "Windows build output was not found: $build" }
    Compress-Archive -Path (Join-Path $build "*") -DestinationPath (Join-Path $out "LightWinterRetailOS-Windows.zip") -Force
    Write-Host "Windows package: $out\LightWinterRetailOS-Windows.zip"
} finally {
    Pop-Location
}
