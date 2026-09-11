<#
.SYNOPSIS
  ClaimLens (Baro) 1인 손해사정사 로컬 시범운영 원클릭 실행 스크립트
.DESCRIPTION
  SQLite 데이터베이스 초기화, 기본 손해사정사 계정 및 보험 기준정보 시딩,
  FastAPI 백엔드(8000) 및 Admin 프론트엔드(3001) 서버를 구동하고 브라우저를 엽니다.
#>

param(
    [switch]$NoBrowser = $false,
    [int]$ApiPort = 8000,
    [int]$AdminPort = 3001
)

$ErrorActionPreference = "Stop"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  ClaimLens (Baro) 1인 손해사정사 로컬 시범운영 런처" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Root Directory Navigation
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
Set-Location $ProjectRoot

# 2. Environment Variables Setup
$env:APP_ENV = "development"
if (-not $env:BOOTSTRAP_ADJUSTER_EMAIL) { $env:BOOTSTRAP_ADJUSTER_EMAIL = "adjuster@claimlens.local" }
if (-not $env:BOOTSTRAP_ADJUSTER_PASSWORD) { $env:BOOTSTRAP_ADJUSTER_PASSWORD = "Adjuster1234!" }
if (-not $env:BOOTSTRAP_ADMIN_EMAIL) { $env:BOOTSTRAP_ADMIN_EMAIL = "admin@claimlens.local" }
if (-not $env:BOOTSTRAP_ADMIN_PASSWORD) { $env:BOOTSTRAP_ADMIN_PASSWORD = "Admin1234!" }
if (-not $env:DATABASE_URL) { $env:DATABASE_URL = "sqlite:///./claimlens-dev.db" }

# 3. Check Python and Node/pnpm
Write-Host "`n[1/5] 개발 환경 및 도구 확인 중..." -ForegroundColor Yellow
$PythonCmd = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $PythonCmd) {
    throw "Python이 시스템 PATH에 설치되어 있지 않습니다. Python 3.11 이상을 설치해 주세요."
}
Write-Host "  - Python: $PythonCmd" -ForegroundColor Gray

$PnpmCmd = (Get-Command pnpm -ErrorAction SilentlyContinue).Source
if (-not $PnpmCmd) {
    throw "pnpm이 시스템 PATH에 설치되어 있지 않습니다. (corepack enable pnpm)"
}
Write-Host "  - pnpm: $PnpmCmd" -ForegroundColor Gray

# 4. Database Setup & Master Seeding
Write-Host "`n[2/5] 로컬 데이터베이스 및 기본 계정 / 마스터 데이터 준비 중..." -ForegroundColor Yellow
try {
    # Bootstrap user accounts
    python -m scripts.bootstrap_admin
    # Seed insurance master
    python -m scripts.seed_db_insurance_master --upsert
    Write-Host "  - 데이터베이스 및 마스터 시딩 완료" -ForegroundColor Green
} catch {
    Write-Warning "마스터 시딩 중 경고가 발생했으나 기본 DB로 계속 진행합니다: $_"
}

# 5. Start Backend API Server
Write-Host "`n[3/5] FastAPI 백엔드 서버 구동 중 (Port $ApiPort)..." -ForegroundColor Yellow
$ApiJob = Start-Process -FilePath "python" `
    -ArgumentList "-m", "uvicorn", "apps.api.app.main:app", "--port", "$ApiPort", "--host", "127.0.0.1" `
    -PassThru

# Wait for API to be ready
$deadline = (Get-Date).AddSeconds(30)
$apiReady = $false
while ((Get-Date) -lt $deadline) {
    try {
        $res = Invoke-RestMethod -Uri "http://127.0.0.1:$ApiPort/health/live" -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($res.status -eq "live") {
            $apiReady = $true
            break
        }
    } catch {
        Start-Sleep -Milliseconds 800
    }
}

if ($apiReady) {
    Write-Host "  - 백엔드 API 준비 완료: http://localhost:$ApiPort" -ForegroundColor Green
} else {
    Write-Warning "  - 백엔드 응답 대기 시간 초과 (계속 진행합니다)"
}

# 6. Start Frontend Admin Server
Write-Host "`n[4/5] Admin 프론트엔드 서버 구동 중 (Port $AdminPort)..." -ForegroundColor Yellow
$AdminJob = Start-Process -FilePath "pnpm" `
    -ArgumentList "--filter", "@claimlens/admin", "dev", "--port", "$AdminPort" `
    -PassThru

Start-Sleep -Seconds 3

# 7. Print Guide & Open Browser
Write-Host "`n[5/5] 서비스 구동 완료!" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  [로그인 기본 계정 안내]" -ForegroundColor White
Write-Host "    - 손해사정사 ID: adjuster@claimlens.local" -ForegroundColor White
Write-Host "    - 비밀번호:      Adjuster1234!" -ForegroundColor White
Write-Host "    - 관리자 ID:     admin@claimlens.local" -ForegroundColor Gray
Write-Host "    - 비밀번호:      Admin1234!" -ForegroundColor Gray
Write-Host ""
Write-Host "  [주요 화면 바로가기]" -ForegroundColor White
Write-Host "    - ⚡ 사건 원스톱 접수:      http://localhost:$AdminPort/intake" -ForegroundColor Yellow
Write-Host "    - 📋 손해사정 심사 및 보고서: http://localhost:$AdminPort/reviews" -ForegroundColor Yellow
Write-Host "    - ⚙️ 손해사정사 직인/설정:    http://localhost:$AdminPort/settings" -ForegroundColor Yellow
Write-Host "    - 📑 백엔드 API 문서(Swagger): http://localhost:$ApiPort/docs" -ForegroundColor Gray
Write-Host "==================================================================" -ForegroundColor Cyan

if (-not $NoBrowser) {
    Start-Sleep -Seconds 1
    Start-Process "http://localhost:$AdminPort/intake"
}

Write-Host "`n* 서비스를 종료하려면 실행 중인 터미널 창을 닫거나 Ctrl+C를 누르세요." -ForegroundColor Gray
