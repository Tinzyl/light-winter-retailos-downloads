$ErrorActionPreference = "Stop"

param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("days", "minutes")]
  [string]$Mode,

  [Parameter(Mandatory=$true)]
  [int]$Value,

  [int]$Quantity = 1,

  [string]$Device = ""
)

$python = "python"
$script = Join-Path $PSScriptRoot "generate-supabase-license-tokens.py"
& $python $script --mode $Mode --value $Value --quantity $Quantity --device $Device
