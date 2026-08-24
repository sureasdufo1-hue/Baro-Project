# AI 에이전트 작업 조율 (Agent Coordination)

> 본 저장소는 AI 에이전트가 작업한다. **2026-08-24부터 모든 영역의 담당은 opencode
> 인프라 에이전트로 통합**되었다(사용자 지정). 타 에이전트는 사용자가 별도 지시하는
> 경우에만 투입되며, 그 경우에도 이 문서의 규약을 따른다.

## 1. 기본 규약

1. **단일 담당 원칙**: 모든 영역의 소유·검증·커밋은 opencode 에이전트가 담당한다.
2. **작게 자주 커밋**: 커밋 단위를 작게 유지한다. 커밋 전 `git status`로 의도하지 않은
   파일을 스테이징하지 않았는지 확인한다(`git add -A` 금지, 경로 지정 add).
3. **공유 계약 변경 시 기록**: `FactType`, API 스키마, compose 환경변수 등 공유 계약을
   변경하면 이 문서의 공유 계약 로그에 한 줄 남긴다.
4. **검증 후 커밋**: ruff/mypy/pytest를 통과시킨 뒤 커밋한다.
5. **인계 작업 처리**: 타 에이전트가 남긴 uncommitted 작업은 담당 에이전트가 검증 후
   커밋하거나, 결함이면 상태를 기록하고 보고한다.

## 2. 소유 지도 (2026-08-24 갱신 — 전 영역 통합)

| 영역 | 담당 |
| --- | --- |
| 인프라: `compose.yaml`, `local-services/**`, `.env*`, Dockerfile*, `infrastructure/**` | opencode |
| 도메인: `domain/**`, `apps/**`, `shared/**`, `migrations/**` | opencode |
| 데이터: `dbins_poc/**`, `scripts/**`, 시드/마이그레이션 | opencode |
| 품질: `tests/**`, `reports/**`, `docs/**`, `prompts/**` | opencode |

## 3. 진행 작업 레지스트리

| 작업 | 상태 | 관련 커밋 |
| --- | --- | --- |
| 정책 DB 검증 스택 (admin UI, policy_db 라우트, 마이그레이션 3종) | 완료 | `b81446e` |
| 로컬 런타임 검증(backup/restore, Redis/Worker 드릴, k6 baseline) | 완료 | `22db364` |
| MinIO + ClamAV 로컬 프로바이더 | 완료 | `27e388b` |
| 로컬 OCR + Ollama 추출 셈 서비스 | 완료 | `c30dd31` |
| 다중 에이전트 조율 규약 | 완료 | `a6b8de6` |
| 실제 업로드 API 경유 E2E (인증 부트스트랩 포함) | 예정 | — |
| [이관] FactType 6종 확장(장해/실손/의료비) + 계산 엔진 확장 | 완료 (검증 후 커밋) | `d601e48` |
| [이관] DB 마스터 시딩 스크립트 + 청구 E2E 테스트 | 완료 (검증 후 커밋) | `d601e48` |
| Web 브랜딩/마스코트 이미지 정리 | 진행 중 (uncommitted) | — |

## 4. 공유 계약 로그

| 날짜 | 계약 | 변경 | 파생 작업 |
| --- | --- | --- | --- |
| 2026-08-24 | `FactType` | 6종 추가(DISABILITY_RATE, DISABILITY_DATE, ACTUAL_LOSS_AMOUNT, COPAYMENT_AMOUNT, NON_BENEFIT_AMOUNT, TREATMENT_COST) | `local-services/extraction` 화이트리스트 동기화 완료 |
| 2026-08-24 | compose 환경변수 | `${VAR:-기본값}` 보간 전환, `S3_SERVER_SIDE_ENCRYPTION` 추가 | `.env.example` 문서화 |

## 5. 미해결 사항

- 이관된 장해/실손 확장은 AGENTS.md §1에서 later-phase로 규정한 영역과 겹친다.
  범위 확정(AGENTS.md 개정 여부)은 사용자 판단 필요 — 에이전트는 임의로 개정하지 않는다.
- `dbins_poc/bootstrap_postgresql.sql` 수정 시 본 문서 로그에 기록한다.
