$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$flutter = "C:\Users\tinot\dev-tools\flutter\bin\flutter.bat"
$appDir = Join-Path $projectRoot "apps\pos_flutter"
$apiUrl = if ($env:LIGHT_WINTER_API_URL) { $env:LIGHT_WINTER_API_URL } else { "https://lightwinter.duckdns.org" }

Push-Location $appDir
try {
  & $flutter pub get
  & $flutter build apk --release --dart-define=LIGHT_WINTER_API_URL=$apiUrl
  Write-Host "Release APK:"
  Write-Host (Join-Path $appDir "build\app\outputs\flutter-apk\app-release.apk")
} finally {
  Pop-Location
}
