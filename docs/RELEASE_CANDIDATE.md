# CODEX-12 Release Candidate 완료보고

> 이 최초 RC 판정 이후 P1 종결 작업이 수행되었습니다. 현재 판정은 `OPERATIONAL_COMPLETION.md`를 참고합니다.

## 1. Executive Summary

### Release Decision

**NOT_RELEASE_READY**

### 근거

- 자동 Golden Path의 계약부터 Evidence/Result까지는 통합 테스트로 검증되며, Evidence 완성 후 Claim 종료 누락은 이번 단계에서 수정했다.
- 전문가 수정 후 Evidence V2 생성과 추가자료 제출 후 Review 재개/종료가 하나의 완성된 E2E로 연결되지 않아 핵심 P1이 남아 있다.
- Production용 Object Storage, Malware, OCR, AI adapter가 아직 없으며 설정 검증은 이를 fail-closed로 거부한다.
- 실제 PostgreSQL/Redis/Object Storage 장애복구, 동시성 및 브라우저 E2E는 로컬 RC 검증 범위에서 수행되지 않았다.

## 2. 전체 Architecture 검증

```text
User → Contract → Claim → Document → OCR → AI → VerifiedFact
→ Policy → Rule → Assessment → Calculation → Evidence → Result
```

상태: 각 경계의 통합 테스트는 존재한다. 자동산정 종료 조건은 모든 최신 담보 Assessment에 현재 Calculation과 완전한 Evidence가 있을 때만 `COMPLETED`가 되도록 보강했다.

## 3. Environment

- Backend: FastAPI modular monolith, PASS
- Frontend: Next.js Web/Admin production build, PASS
- Database: SQLite test suite 및 Alembic 단일 head, PASS; PostgreSQL fresh restore는 미검증
- Redis/Worker: RQ bounded retry 단위 검증, 실제 broker 통합은 미검증
- Object Storage/OCR/AI/Malware: 개발 adapter만 구현, Production adapter 없음

## 4. Migration

| Phase | 결과 |
| --- | --- |
| CODEX-01 | PASS |
| CODEX-02 | PASS |
| CODEX-03 | PASS |
| CODEX-04 | PASS |
| CODEX-05 | PASS |
| CODEX-06 | PASS |
| CODEX-07 | PASS |
| CODEX-08 | PASS |
| CODEX-09 | PASS |
| CODEX-10 | PASS |
| CODEX-11 | 해당 DB 변경 없음 |
| CODEX-12 | 해당 DB 변경 없음 |

Fresh Database: SQLAlchemy test metadata PASS. Docker Desktop daemon이 실행 중이 아니어서 실제 PostgreSQL `upgrade/downgrade/upgrade`는 BLOCKED.

## 5. Golden Happy Path

| 단계 | 결과 |
| --- | --- |
| Register/Login/Consent/Audit | PASS |
| Insured/Contract/ContractCoverage | PASS |
| Claim/Accident/State Machine | PASS |
| Private upload/MIME/Magic/Malware/Hash | PASS |
| OCR queue boundary/OCRResult/AI extraction | PASS |
| ExtractedFact/User verification/VerifiedFact provenance | PASS |
| Exact Policy resolution/Coverage/Rule/Eligibility | PASS |
| Decimal/Integer deterministic calculation | PASS |
| Policy and medical Evidence/Result | PASS |
| Evidence 완성 후 Claim COMPLETED | PASS |

최종 결과: API 통합 구간 PASS. 단일 실제 브라우저 여정은 미구현으로 SKIPPED.

## 6. Manual Review E2E

Assignment → Accept → Context → Approve → Complete 및 권한/Audit는 PASS. Expert Modify는 새 Fact/Assessment/Calculation을 보존하지만 Evidence V2 자동 생성까지 연결되지 않아 FAIL.

## 7. Additional Document E2E

Review의 문서 요청과 Claim `DOCUMENT_REQUIRED` 전환은 구현됨. 추가 Upload/OCR/Verification 이후 기존 Review를 재개하고 새 Assessment/Calculation/Evidence로 종료하는 명시적 orchestration이 없어 FAIL.

## 8. Negative Scenarios

| Scenario | Expected | Actual | Result |
| --- | --- | --- | --- |
| Missing Fact | ADDITIONAL_INFO_REQUIRED | 동일, Claim DOCUMENT_REQUIRED | PASS |
| Policy Missing/Conflict | MANUAL_REVIEW | 동일, latest fallback 없음 | PASS |
| Rule Missing/Invalid | MANUAL_REVIEW | 동일 | PASS |
| Calculation Rule Missing | 명시적 오류 | CALCULATION_RULE_NOT_FOUND | PASS |
| Calculation Failure | 오류, 0원 금지 | 명시적 DomainError | PASS |
| Evidence Failure | 완료 금지 | EVIDENCE_* 오류 | PASS |
| OCR Failure | bounded retry/FAILED | 구현 및 단위검증 | PASS |
| Invalid AI Output | 저장 금지 | schema reject | PASS |

## 9. Calculation / History / Evidence

- Money: integer KRW와 Decimal rate, binary float 미사용.
- Determinism/Idempotency: fingerprint가 동일하면 동일 Calculation 반환.
- Recalculation: V2 생성, V1 `SUPERSEDED` 및 snapshot 보존.
- Evidence: Calculation → exact RuleVersion → Clause → PolicyVersion 및 VerifiedFact → OCRResult → Document → Page/BBox 검증.
- 실제 다중 프로세스 동시요청 경쟁조건은 미검증.

## 10. Security / Privacy

Contract, Claim, Document, Fact, Assessment, Calculation, Evidence 및 Review IDOR 테스트가 존재한다. Private storage, upload spoof/malware, prompt/rule injection, 쿠키/Origin/body/rate-limit/headers를 검증했다. 로그와 metrics에 의료 Fact 값을 넣지 않는다. Production provider/secret 설정은 fail-closed다.

## 11. Failure / Recovery / Queue

- OCR/AI 실패와 retry exhaustion은 검증됨.
- Redis duplicate delivery는 calculation fingerprint로 일부 흡수되나 OCR job 전체의 broker-level 중복/poison/stuck test는 없음.
- DB/Object backup 및 restore는 Runbook만 존재하고 실제 복구 훈련은 미수행.

## 12. Frontend / Accessibility / Performance

- Web/Admin lint, typecheck, component test와 production build PASS.
- 실제 브라우저 E2E, keyboard/focus/스크린리더, 반응형 viewport 검증 SKIPPED.
- 정량 latency, large Claim, N+1 및 pagination 부하 측정 SKIPPED.

## 13. Defects

### P0

없음.

### P1

| ID | 문제 | 상태 |
| --- | --- | --- |
| RC-001 | 전문가 수정 후 Evidence V2 자동 생성/완결 orchestration 부재 | OPEN |
| RC-002 | 추가자료 제출 후 기존 Review 재개 및 재산정 완료 flow 부재 | OPEN |
| RC-003 | Production storage/malware/OCR/AI adapter 부재 | OPEN |

### P2

| ID | 문제 | 상태 |
| --- | --- | --- |
| RC-004 | 실제 브라우저 E2E와 접근성 자동화 부재 | OPEN |
| RC-005 | PostgreSQL/Redis 기반 동시성·복구·성능 검증 부재 | OPEN |
| RC-006 | 프로세스 로컬 rate limiter | OPEN |
| RC-007 | 영속 세션 폐기/계정 잠금 부재 | OPEN |

## 14. AGENTS.md 최종 준수검사

| Invariant | 결과 |
| --- | --- |
| LLM 보험금 직접계산 없음 | PASS |
| Raw OCR 권위입력 없음 | PASS |
| PolicyVersion 추측/latest fallback 없음 | PASS |
| Rule arbitrary execution 없음 | PASS |
| Decimal/Integer money | PASS |
| Calculation failure ≠ 0원 | PASS |
| Historical Calculation/Evidence 보존 | PASS |
| Object Authorization/Private Document | PASS |
| Sensitive Logging 방지 | PASS |
| Expert Override Audit | PASS |

## 15. Validation Commands

```powershell
ruff format --check .
ruff check .
mypy apps domain infrastructure shared
pytest
pnpm lint
pnpm typecheck
pnpm test
pnpm build
docker compose config --quiet
alembic heads
git diff --check
```

## 16. 최종 Release 판정

### Decision

**NOT_RELEASE_READY**

### P0 Open

0

### P1 Open

3

### Release 전 필수조치

1. Review Modify/Additional Document를 Assessment V2 → Calculation V2 → Evidence V2까지 연결한다.
2. 승인된 Production provider adapter와 비밀/인프라 설정을 준비한다.
3. 실제 PostgreSQL/Redis/Object Storage 환경에서 fresh migration, failure recovery 및 핵심 E2E를 재실행한다.
