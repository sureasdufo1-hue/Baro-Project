# Claim Domain

CODEX-04는 이후 문서 및 보험금 분석 단계가 사용할 Case 작업공간을 추가합니다.

```text
User -> InsuranceContract -> Claim -> Accident
```

`Claim`은 Aggregate Root이자 Process Container이며 보험금 판정 또는 계산결과가 아닙니다.
`Accident`는 사용자가 입력한 질병·상해 정보이며 문서로 검증된 사실로 취급하지 않습니다.

## State Machine

모든 상태 전이는 `domain/claim/service.py`의 `ClaimStateMachine`을 통과합니다.

```text
DRAFT -> DOCUMENT_REQUIRED
   |             |
   +-> CANCELLED <-+
```

Enum에는 향후 상태도 정의하지만 CODEX-04에서는 후속 Pipeline 전이를 활성화하지 않습니다.
`FAILED`는 시스템 처리 실패이며 보험금 부지급을 뜻하지 않습니다.

## API

- `GET /api/claims`: 현재 사용자의 Claim 목록 및 상태·유형 필터
- `POST /api/claims`: Claim과 1:1 Accident를 한 Transaction에서 생성
- `GET|PATCH /api/claims/{claim_id}`: 소유 Claim 조회 또는 DRAFT 수정
- `GET|PATCH /api/claims/{claim_id}/accident`: 사고정보 조회 또는 DRAFT 수정
- `POST /api/claims/{claim_id}/transitions`: 사고정보 입력 완료
- `POST /api/claims/{claim_id}/cancel`: Row를 유지한 채 `CANCELLED` 전환

서버는 선택한 소유 계약의 피보험자를 Claim에 복사합니다. 모든 객체 Endpoint가 소유권을
확인하며 Master 편집자나 아직 배정되지 않은 손해사정인에게 전체 Claim 접근권한을 주지 않습니다.

## Audit / Privacy

생성·수정·취소·상태전이를 감사하며 민감한 사고 설명은 Audit Payload에 복제하지 않고 변경
여부만 기록합니다.

## 다음 단계 경계

CODEX-05는 `Claim 1 -> N MedicalDocument`를 추가할 수 있습니다. 현재 단계에는 Upload, OCR,
AI, Policy Version 자동추정, 지급판정, 계산, Evidence 또는 가짜 보험금 값이 없습니다.
