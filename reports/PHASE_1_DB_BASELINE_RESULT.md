# Phase 1 결과

## 1. Migration
- Before: `c91e7a42d4f0`
- After: `f80c2e1a9b77`
- Head: `f80c2e1a9b77`
- Result: PASS — pending 없음, 재실행 안정성 확인

## 2. 변경 파일
- `scripts/db_baseline.py`
- `scripts/__init__.py`
- `migrations/env.py`
- `migrations/versions/f31a57b42c10_normalize_sqlite_audit_event_schema.py`
- `migrations/versions/f80c2e1a9b77_allow_verified_fact_history.py`
- `tests/unit/test_db_baseline.py`
- `alembic.ini`
- `docs/OPERATIONS_RUNBOOK.md`

## 3. DB Backup
- 구현 방식: SQLite online backup API → 임시 파일 integrity check → 원자적 rename
- 결과: PASS
- 최초 DB 백업: `backups/claimlens-dev.before-f31a57b42c10.20260819T081204Z.db`
- 최종 보완 전 백업: `backups/claimlens-dev.before-f80c2e1a9b77.20260819T082029Z.db`
- 데이터 fingerprint: `f712bb160a6605925fa40aad6c72247bbeb7e5fc04405f18ec8e8c5501342aca`
- 전후 전체 행 fingerprint 일치: PASS

## 4. Schema 정합성
- 정상: table, column, compiled type, nullable, server default, FK, unique, index
- 수정: SQLite `audit_logs.event_type`를 현재 ORM enum 길이와 일치시킴
- 수정: versioned `VerifiedFact` 저장을 막던 legacy unique constraint 제거
- 남은 문제: 없음 (`schema_issues=[]`)

## 5. 테스트
- 기존 테스트: 94개 통과
- 신규 테스트: 5개 통과
- 총 결과: 99개 통과, 실패 0개
- 신규 범위: backup 정상/실패 중단, empty→head, c91→head 데이터 보존, downgrade 1→upgrade

## 6. PostgreSQL 사전 호환성 점검
- `d12044c5a901`: PostgreSQL enum 값 추가, SQLite no-op
- `f31a57b42c10`: SQLite batch ALTER 전용, PostgreSQL no-op
- `f80c2e1a9b77`: PostgreSQL/SQLite unique constraint 제거 SQL 생성 확인
- UUID/Boolean/JSON/datetime은 SQLAlchemy dialect type을 사용
- 실제 PostgreSQL runtime 적용은 Docker/Hyper-V 비활성으로 미실행
- PostgreSQL enum downgrade는 이력 보존을 위해 값 제거를 수행하지 않음
- `f80c2e1a9b77` downgrade는 중복 VerifiedFact가 존재하면 unique 복원이 실패할 수 있으므로 운영 데이터에서 실행 전 별도 점검 필요

## 7. 남은 Blocker
- 실제 PostgreSQL upgrade/downgrade runtime 검증은 호스트 `HCS_E_HYPERV_NOT_INSTALLED`로 차단
- 전체 Repository Ruff는 보관용 `archive/`의 기존 POC 코드 때문에 실패하며 앱 범위 Ruff는 통과
- Starlette TestClient의 httpx deprecation warning 존재

## 8. Phase 2 진입 가능 여부
- READY
- 사유: 개발 DB가 단일 최신 head이고 데이터 보존·ORM 정합·백업 실패 차단·회귀 테스트가 검증됨. Policy Seed Import는 수행하지 않음.
