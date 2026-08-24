# 로컬 런타임 검증 결과

> `OPERATIONAL_COMPLETION.md`의 Runtime Verification Pending 항목 중 로컬에서 수행 가능한 항목의 실행 결과.
> 실행 환경: Windows (Docker Engine 29.5.3), compose 프로파일 기본 개발 구성.

## 1. Fresh Bootstrap 및 Migration

- `docker compose up --build -d`: 전 서비스 healthy (postgres, policy-postgres, redis, api, web, admin, worker), `migrate` Exit(0)
- Alembic head: `f80c2e1a9b77` — 마이그레이션 3건(`d12044c5a901`, `f31a57b42c10`, `f80c2e1a9b77`) 신규 적용 확인
- 정책 DB 시드: `bootstrap_postgresql.sql` 재적용 시 `human_verified` BOOLEAN 리터럴 오류(정수 `0`) 발견 → `FALSE`로 수정 후 정상 적용
  - product_versions 3건, policy_documents 4건, payment_rules 2건 (`human_verified = false`)
- `/api/health/db` → `connected:true, schema:ok, seed_loaded:true, missing_tables:[]`

판정: **PASS**

## 2. Backup → 별도 DB Restore 훈련

- `scripts/backup_database.ps1` → `backups/claimlens-drill-20260824-114627.dump` 생성 (pg_dump custom format)
- `scripts/restore_database.ps1` → 동일 인스턴스 내 별도 DB `claimlens_restore_test` 복원
- `alembic_version` = `f80c2e1a9b77` 일치
- 테이블 수 원본 33 = 복구본 33, 주요 테이블 row 수 일치
- 훈련 후 테스트 DB 삭제

판정: **PASS** (실제 장애 상황의 cross-instance 복원은 staging에서 재수행 필요)

## 3. Redis 재시작 / Worker 종료 복구 드릴

- Redis `docker compose restart` → 5초 내 healthy. Worker는 bounded retry로 재접속 생존
  - 로그 근거: `could not connect to Redis instance ... retrying` 이후 정상 복귀
- Worker `docker compose kill`(SIGKILL) → 재기동 5초, 신규 worker가 `document-ocr`, `document-ai-extraction`, `foundation` 큐 리스닝 확인
- 드릴 중 API `/health/ready` 지속 응답

판정: **PASS**

## 4. k6 성능 Baseline

- 도구: k6 v2.2.0 (winget 설치), 스크립트: `tests/performance/api-smoke.js` (5 VUs / 30s, threshold 없음 — SLO 미승인)
- 대상: `http://localhost:8000` (`/health/live`, `/health/ready`)
- 요약(2회 실행):

| 지표 | Run 1 | Run 2 |
| --- | --- | --- |
| 총 요청 | 11,828 | 9,442 |
| 처리량 | 394 req/s | 314 req/s |
| checks 성공률 | 100% | 100% |
| avg | 12.56ms | 15.76ms |
| p(50) | 11.79ms | 14.12ms |
| p(90) | 18.18ms | — |
| p(95) | 20.35ms | 30.09ms |
| p(99) | — | 43.25ms |
| max | 81.97ms | 137.09ms |

판정: **BASELINE_RECORDED** (SLO 미확정 상태이므로 판단 기준 없음. 향후 SLO 승인 후 threshold 추가 필요)

## 남은 항목 (staging 필요)

- S3 / ClamAV / HTTP OCR / HTTP AI provider 연결 인증 — 실제 자격 증명과 엔드포인트 필요
- Cross-instance PostgreSQL 복원 및 실장비 성능 측정
- 프로덕션 provider 보안·계약 검증 및 침투 테스트
