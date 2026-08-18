# Human Review

CODEX-10은 자동 판단의 불확실성을 `MANUAL_REVIEW`로 보존하고 배정된 ADJUSTER가 Evidence를 확인한 뒤 승인, 수정, 추가자료 요청 또는 판단불가를 선택하는 workflow다.

```text
MANUAL_REVIEW → REQUESTED → ASSIGNED → IN_PROGRESS
                                      ├─ APPROVED → COMPLETED
                                      ├─ MODIFIED → COMPLETED
                                      ├─ ADDITIONAL_DOCUMENT_REQUIRED
                                      └─ UNDETERMINED → COMPLETED
```

## 권한과 불변식

- SYSTEM_ADMIN은 Review 생성·배정만 수행한다.
- ADJUSTER는 자신에게 배정된 Review만 조회하고 판단한다.
- 일반 USER와 미배정 ADJUSTER는 Expert Action API를 사용할 수 없다.
- 전문가는 보험금액을 직접 입력하지 않는다.
- Fact 변경은 기존 Fact를 삭제하지 않고 `EXPERT_MODIFIED` Fact를 생성한다.
- Review는 이전 결과, 최종 구조화 결과, 변경 사유, reviewer와 시각을 보존한다.
- 재계산은 기존 Calculation Engine을, 근거 생성은 Evidence Builder를 재사용한다.

## 추가자료

추가자료 요청은 서류/Fact 유형, 사유, 사용자 안내와 내부 메모를 분리해 저장한다. Claim은 `DOCUMENT_REQUIRED`로 이동하며 사용자는 기존 private upload → OCR → Fact verification pipeline을 사용한다. 사용자 API에는 내부 메모를 노출하지 않는다.

## API

- `POST /api/reviews`: Review 생성(SYSTEM_ADMIN)
- `GET /api/reviews`: 관리 Queue
- `GET /api/reviews/my`: 배정된 전문가 Queue
- `POST /api/reviews/{id}/assign`: ADJUSTER 배정
- `POST /api/reviews/{id}/accept|approve|modify|request-documents|undetermined|complete`
- `GET /api/claims/{id}/review-status`: 사용자용 상태와 추가자료 요청

중요 Action은 before/final 구조화 결과를 Audit에 남기며 의료문서 원문과 내부 의견을 일반 로그에 기록하지 않는다.
