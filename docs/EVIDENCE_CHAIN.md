# Evidence Chain

CODEX-09는 보험금 예상액을 계약, 가입담보, 고정된 약관·규칙 버전, 검증 사실과 원본문서 위치까지 추적하는 근거사슬로 확장한다.

```text
BenefitCalculation
├─ ContractCoverage snapshot
├─ CoverageAssessment → PolicyVersion
├─ RuleVersion → BenefitRuleClause → PolicyClause
└─ VerifiedFact → ExtractedFact → OCRResult → MedicalDocument → Page/BBox
```

## 생성과 검증

`build_for_calculation`은 `calculation_input.verified_fact_ids`에 기록된 Fact만 연결한다. Rule과 명시적으로 연결된 Clause만 사용하며 Assessment와 다른 PolicyVersion의 Clause, 다른 Claim의 Fact·Document는 거부한다. BBox가 없으면 생성하지 않는다.

계산 버전마다 Evidence를 별도로 만든다. V2는 V1 Evidence를 수정하지 않는다. 필수 Clause 또는 Fact provenance가 빠지면 `EVIDENCE_*` 오류가 발생하며 결과 API는 `RESULT_INCOMPLETE`로 표시한다.

## Decision Trace와 설명

Trace는 별도 판단 엔진이 아니다. Policy resolution snapshot, CoverageAssessment, AssessmentRuleResult와 BenefitCalculation을 순서대로 조합한 읽기 전용 projection이다. 설명은 저장된 구조화 값만 표시하며 LLM을 사용하지 않는다.

## API와 화면

- `POST /api/calculations/{id}/evidence`: 근거사슬 생성·검증
- `GET /api/calculations/{id}/evidence`: 전체 근거
- `GET /api/calculations/{id}/policy-evidence`: Rule-linked 약관 근거
- `GET /api/calculations/{id}/fact-evidence`: 계산 입력 Fact 근거
- `GET /api/calculations/{id}/trace`: Decision Trace
- `GET /api/claims/{id}/result`: Current Calculation 기반 예상 합계
- `/claims/{claimId}/result`: SCR-060
- `/claims/{claimId}/calculations/{calculationId}`: SCR-061
- `/claims/{claimId}/calculations/{calculationId}/policy`: SCR-062

모든 API는 Claim 소유권을 확인한다. 화면 금액은 현재 계약이 아니라 Calculation snapshot을 사용하고, `FAILED`와 Evidence 미완성을 정상 0원과 구분한다.
