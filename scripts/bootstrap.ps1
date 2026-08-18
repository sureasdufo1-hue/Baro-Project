param([int]$TimeoutSeconds = 180)
$ErrorActionPreference = "Stop"
docker compose up -d --build
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    try {
        $ready = Invoke-RestMethod http://localhost:8000/health/ready -TimeoutSec 3
        if ($ready.status -eq "ready") { break }
    } catch { Start-Sleep -Seconds 2 }
    if ((Get-Date) -ge $deadline) { throw "ClaimLens bootstrap readiness timeout" }
} while ($true)
docker compose ps
Write-Output "ClaimLens bootstrap completed"
