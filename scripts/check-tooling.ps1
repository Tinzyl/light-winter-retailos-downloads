$ErrorActionPreference = "Continue"

$tools = @("python", "node", "docker", "git", "flutter")

foreach ($tool in $tools) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "[ok] $tool -> $($cmd.Source)"
    } else {
        Write-Host "[missing] $tool"
    }
}

Write-Host ""
Write-Host "Required for backend: python, docker"
Write-Host "Required for client builds: flutter"
Write-Host "Required for repo work: git"
