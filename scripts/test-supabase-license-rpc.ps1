$ErrorActionPreference = "Stop"

param(
  [Parameter(Mandatory=$true)]
  [string]$Device,

  [Parameter(Mandatory=$true)]
  [string]$Token
)

if (-not $env:LIGHT_WINTER_SUPABASE_URL) {
  throw "Set LIGHT_WINTER_SUPABASE_URL first."
}

if (-not $env:LIGHT_WINTER_SUPABASE_ANON_KEY) {
  throw "Set LIGHT_WINTER_SUPABASE_ANON_KEY first."
}

$base = $env:LIGHT_WINTER_SUPABASE_URL.TrimEnd("/")
if ($base.EndsWith("/rest/v1")) {
  $base = $base.Substring(0, $base.Length - "/rest/v1".Length)
}

$headers = @{
  "apikey" = $env:LIGHT_WINTER_SUPABASE_ANON_KEY
  "authorization" = "Bearer $($env:LIGHT_WINTER_SUPABASE_ANON_KEY)"
  "content-type" = "application/json"
}

$body = @{
  p_device_uid = $Device
  p_token = ($Token.ToUpper() -replace "[^A-Z0-9]", "")
  p_platform = "sunmi_android"
} | ConvertTo-Json

Invoke-RestMethod -Method Post -Uri "$base/rest/v1/rpc/lwr_activate_device_license" -Headers $headers -Body $body | ConvertTo-Json -Depth 10
