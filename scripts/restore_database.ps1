param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [string]$TargetDatabase = "claimlens_restore_test"
)
$ErrorActionPreference = "Stop"
$backup = (Resolve-Path -LiteralPath $InputPath).Path
if ($TargetDatabase -notmatch '^[a-zA-Z0-9_]+$') { throw "Invalid target database name" }
docker compose exec -T postgres psql -U claimlens -d postgres -c "DROP DATABASE IF EXISTS $TargetDatabase"
docker compose exec -T postgres psql -U claimlens -d postgres -c "CREATE DATABASE $TargetDatabase"
docker compose cp $backup postgres:/tmp/claimlens-restore.dump
docker compose exec -T postgres pg_restore -U claimlens -d $TargetDatabase --exit-on-error /tmp/claimlens-restore.dump
docker compose exec -T postgres psql -U claimlens -d $TargetDatabase -c "SELECT version_num FROM alembic_version"
Write-Output "Restore verification completed in database: $TargetDatabase"
