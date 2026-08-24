# AI 에이전트 작업 조율 (Agent Coordination)

> 본 저장소는 복수의 AI 에이전트가 동시에 작업한다. 충돌 없이 병렬 진행하기 위한 규약과
> 현재 작업 분배 상태를 기록한다. 작업 시작 전/커밋 전에 이 문서를 확인하고, 자신의
> 진행 작업을 아래 레지스트리에 갱신한다.

## 1. 기본 규약

1. **영역 존중**: 아래 소유 지도에서 다른 에이전트의 진행 영역 파일은 수정하지 않는다.
2. **작게 자주 커밋**: 커밋 단위를 작게 유지해 충돌 면적을 줄인다. 커밋 전 `git status`로
   타인의 파일을 스테이징하지 않았는지 반드시 확인한다(`git add -A` 금지, 경로 지정 add).
3. **공유 계약 변경 시 기록**: `FactType`, API 스키마, compose 환경변수 등 공유 계약을
   변경하면 이 문서의 공유 계약 로그에 한 줄 남긴다.
4. **검증 후 커밋**: 자신의 영역에 대해 ruff/mypy/pytest를 통과시킨 뒤 커밋한다.
5. **재시작 전 상태 확인**: 컨테이너/볼륨 초기화 같은 파괴적 명령은 실행 전 레지스트리의
   진행 중 작업과 충돌하지 않는지 확인한다.

## 2. 소유 지도 (2026-08-24 기준)

| 영역 | 담당 | 비고 |
| --- | --- | --- |
| `compose.yaml`, `local-services/**`, `.env*`, Dockerfile* | 인프라 에이전트(opencode) | MinIO/ClamAV/OCR/Ollama 로컬 스택 |
| `infrastructure/**` 어댑터, `apps/api/app/dependencies.py` | 인프라 에이전트(opencode) | provider 계약 |
| `reports/LOCAL_*`, 런타임 검증 드릴, k6 | 인프라 에이전트(opencode) | |
| `domain/calculation/**`, `domain/fact/**` 확장 | 도메인 에이전트(타 AI) | 실손/의료비·장해 확장 진행 중 |
| `scripts/seed_db_insurance_master.py`, `tests/integration/test_db_insurance_claim_e2e.py` | 도메인 에이전트(타 AI) | |
| `prompts/policy-extraction/**` | 도메인 에이전트(타 AI) | |
| `dbins_poc/**` | 공유 (변경 시 로그 필수) | 시드 SQL |

## 3. 진행 작업 레지스트리

| 에이전트 | 작업 | 상태 | 관련 커밋 |
| --- | --- | --- | --- |
| opencode | 정책 DB 검증 스택 (admin UI, policy_db 라우트, 마이그레이션 3종) | 완료 | `b81446e` |
| opencode | 로컬 런타임 검증(backup/restore, Redis/Worker 드릴, k6 baseline) | 완료 | `22db364` |
| opencode | MinIO + ClamAV 로컬 프로바이더 | 완료 | `27e388b` |
| opencode | 로컬 OCR + Ollama 추출 셈 서비스 | 완료 | `c30dd31` |
| opencode | 실제 업로드 API 경유 E2E (인증 부트스트랩 포함) | 예정 | — |
| 타 AI | FactType 6종 확장(장해/실손/의료비) + 계산 엔진 확장 | 진행 중 (uncommitted) | — |
| 타 AI | DB 마스터 시딩 스크립트 + 청구 E2E 테스트 | 진행 중 (uncommitted) | — |

## 4. 공유 계약 로그

| 날짜 | 계약 | 변경 | 파생 작업 |
| --- | --- | --- | --- |
| 2026-08-24 | `FactType` | 6종 추가(DISABILITY_RATE, DISABILITY_DATE, ACTUAL_LOSS_AMOUNT, COPAYMENT_AMOUNT, NON_BENEFIT_AMOUNT, TREATMENT_COST) | `local-services/extraction` 화이트리스트 동기화 완료(상호 확인) |
| 2026-08-24 | compose 환경변수 | `${VAR:-기본값}` 보간 전환, `S3_SERVER_SIDE_ENCRYPTION` 추가 | `.env.example` 문서화 |

## 5. 미해결 조율 사항

- 타 AI의 장해/실손 확장은 AGENTS.md §1에서 later-phase로 규정한 영역과 겹친다.
  범위 확정(AGENTS.md 개정 여부)은 사용자 판단 필요 — 에이전트는 임의로 개정하지 않는다.
- `dbins_poc/bootstrap_postgresql.sql`은 양쪽이 참조하므로 수정 시 본 문서 로그에 기록한다.
