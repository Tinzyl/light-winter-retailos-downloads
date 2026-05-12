$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$siteDir = Join-Path $projectRoot "deploy\download-site"
$downloadDir = Join-Path $siteDir "downloads"
$apkSource = Join-Path $projectRoot "apps\pos_flutter\build\app\outputs\flutter-apk\app-debug.apk"
$apkTarget = Join-Path $downloadDir "light-winter-retailos-android-sunmi.apk"

if (-not (Test-Path $downloadDir)) {
  New-Item -ItemType Directory -Path $downloadDir | Out-Null
}

if (-not (Test-Path $apkSource)) {
  throw "APK not found at $apkSource. Build the Android APK first."
}

Copy-Item -LiteralPath $apkSource -Destination $apkTarget -Force

$windowsTarget = Join-Path $downloadDir "light-winter-retailos-windows.zip"
if (-not (Test-Path $windowsTarget)) {
  "Windows build not uploaded yet." | Set-Content -Path $windowsTarget -Encoding UTF8
}

Write-Host "Download site prepared:"
Write-Host $siteDir
Write-Host "Android/SUNMI APK:"
Write-Host $apkTarget
