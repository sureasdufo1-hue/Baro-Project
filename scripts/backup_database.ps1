param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference = "Stop"
$parent = Split-Path -Parent $OutputPath
if (-not $parent) { $parent = "." }
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
$resolvedParent = (Resolve-Path -LiteralPath $parent).Path
$name = Split-Path -Leaf $OutputPath
if (-not $name.EndsWith(".dump")) { throw "Backup output must use a .dump extension" }
docker compose exec -T postgres pg_dump -U claimlens -d claimlens -Fc --file=/tmp/claimlens-backup.dump
docker compose cp postgres:/tmp/claimlens-backup.dump (Join-Path $resolvedParent $name)
if ((Get-Item -LiteralPath (Join-Path $resolvedParent $name)).Length -eq 0) { throw "Backup is empty" }
Write-Output "Database backup created: $(Join-Path $resolvedParent $name)"
