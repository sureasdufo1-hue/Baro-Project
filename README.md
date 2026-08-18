# ClaimLens AI / Baro Project

보험계약, 약관, 의료·사고 증빙을 구조화하여 담보별 지급요건과 예상 보험금을 검토하고 계산 근거까지 추적할 수 있도록 지원하는 시스템입니다.

현재 구현 범위는 `CODEX-01 Foundation`입니다. 회원·동의·인증·RBAC·감사로그, API/Worker 실행 기반과 사용자·관리자 UI 셸만 제공합니다. 보험상품, 계약, Claim, 문서 업로드, OCR/AI, Rule, 보험금 계산과 Evidence는 아직 구현하지 않았습니다.

## Architecture

```text
Next.js Web/Admin -> FastAPI modular monolith -> PostgreSQL
                              |
                              +-> Redis -> RQ worker
```

논리 도메인은 분리하지만 MVP 배포 구조를 마이크로서비스로 나누지 않습니다. 개발 규칙과 불변식은 [AGENTS.md](AGENTS.md), 기준자료는 [docs/PROJECT_BASELINE.md](docs/PROJECT_BASELINE.md)를 참고하세요.

## 필수 환경

- Docker Desktop 및 Docker Compose
- Python 3.12 이상
- Node.js 24 이상
- pnpm 11

## 환경변수

```powershell
Copy-Item .env.example .env
```

`.env`의 `SESSION_SECRET`을 반드시 변경하세요. 실제 비밀값은 커밋하지 않습니다. Production에서는 `COOKIE_SECURE=true`, 제한된 `CORS_ORIGINS`, 별도 Secret 관리가 필요합니다.

## Docker 개발환경

```powershell
docker compose up --build
```

PostgreSQL(`5432`), Redis(`6379`), FastAPI(`8000`), RQ Worker와 일회성 Alembic migration 서비스가 실행됩니다.

```powershell
Invoke-RestMethod http://localhost:8000/health/live
Invoke-RestMethod http://localhost:8000/health/ready
```

## Backend 로컬 실행

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -e ".[dev]"
alembic upgrade head
uvicorn apps.api.app.main:app --reload
```

기본 로컬 DB는 SQLite입니다. PostgreSQL을 사용하려면 `.env`의 `DATABASE_URL`을 설정합니다. 애플리케이션은 시작 시 Schema를 자동 변경하지 않으며 반드시 Alembic migration을 사용합니다.

Worker 실행:

```powershell
python -m apps.worker.main
```

개발 관리자 Bootstrap은 환경변수를 명시한 뒤 수동으로 실행합니다. Production에서는 실행되지 않습니다.

```powershell
$env:BOOTSTRAP_ADMIN_EMAIL='admin@example.test'
$env:BOOTSTRAP_ADMIN_PASSWORD='replace-with-a-strong-development-password'
python scripts/bootstrap_admin.py
```

## Frontend 실행

```powershell
pnpm install
pnpm dev:web
```

사용자 웹은 `http://localhost:3000`에서 실행됩니다. 별도 터미널에서 관리자를 실행합니다.

```powershell
pnpm dev:admin
```

관리자 웹은 `http://localhost:3001`에서 실행됩니다.

## API

| Method | Path | 설명 |
| --- | --- | --- |
| GET | `/health/live` | Process liveness |
| GET | `/health/ready` | DB readiness |
| POST | `/api/auth/register` | 회원가입 및 버전별 동의 기록 |
| POST | `/api/auth/login` | 로그인과 HttpOnly 세션 쿠키 발급 |
| POST | `/api/auth/logout` | 로그아웃과 감사 기록 |
| GET | `/api/auth/me` | 현재 사용자 |
| GET | `/api/admin/status` | RBAC 검증용 관리자 Endpoint |

모든 응답에는 `X-Request-ID`가 포함됩니다. 오류는 `error.code`, `error.message`, `error.requestId` 구조를 사용합니다.

## Validation

Backend:

```powershell
ruff format --check .
ruff check .
mypy apps domain infrastructure shared
pytest
alembic upgrade head
```

Frontend:

```powershell
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

Docker:

```powershell
docker compose config
```

## Repository 구조

- `apps/web`: 사용자 Landing, 로그인, 회원가입, Dashboard 셸
- `apps/admin`: 관리자 로그인·Layout·빈 Dashboard
- `apps/api`: FastAPI, 인증·RBAC·오류·Request ID·Health
- `apps/worker`: Redis/RQ worker 및 연결 검사용 Job
- `domain/user`: User, Consent와 역할·상태 타입
- `domain/audit`: AuditLog와 Foundation 이벤트
- `infrastructure/database`: SQLAlchemy Session과 Metadata
- `infrastructure/queue`: Redis 연결
- `migrations`: Alembic migration
- `tests`: 단위·통합·보안 테스트
- `docs/decisions`: 기술 결정 기록

나머지 도메인 폴더는 이후 차수를 위한 경계만 표시하며 아직 비즈니스 로직을 포함하지 않습니다.

