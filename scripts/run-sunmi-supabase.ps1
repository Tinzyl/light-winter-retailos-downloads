$ErrorActionPreference = "Stop"

if (-not $env:LIGHT_WINTER_SUPABASE_URL) {
  throw "Set LIGHT_WINTER_SUPABASE_URL first, for example https://YOUR-PROJECT.supabase.co"
}

if (-not $env:LIGHT_WINTER_SUPABASE_ANON_KEY) {
  throw "Set LIGHT_WINTER_SUPABASE_ANON_KEY first. Use the Supabase anon public key, not service_role."
}

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$flutter = "C:\Users\tinot\dev-tools\flutter\bin\flutter.bat"
$appDir = Join-Path $projectRoot "apps\pos_flutter"

Push-Location $appDir
try {
  & $flutter run -d VE03P2CF00209 --dart-define=LIGHT_WINTER_SUPABASE_URL=$env:LIGHT_WINTER_SUPABASE_URL --dart-define=LIGHT_WINTER_SUPABASE_ANON_KEY=$env:LIGHT_WINTER_SUPABASE_ANON_KEY
} finally {
  Pop-Location
}
