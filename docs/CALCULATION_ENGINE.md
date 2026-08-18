# Deterministic Calculation Engine

권위 있는 계산 입력은 PAYABLE/NOT_PAYABLE CoverageAssessment, ContractCoverage Snapshot,
확정 PolicyVersion, ACTIVE Calculation RuleVersion과 VerifiedFact뿐입니다. OCR, ExtractedFact,
LLM 또는 Client 입력은 금액 계산에 직접 사용하지 않습니다.

지원 Strategy는 `FIXED_BENEFIT`와 `HOSPITAL_DAILY`입니다. 지급률, 일수계산 방식, 최대일수,
공제와 반올림은 Versioned Rule Parameter에서 가져옵니다. 계산은 Decimal과 정수 KRW만 사용하며
임의 Formula/eval 실행을 허용하지 않습니다.

BenefitCalculation은 가입금액·지급률·입력 Fact ID·공식·Policy/Rule Version·총액·공제·최종액을
Snapshot으로 보존합니다. Fingerprint가 같은 요청은 기존 결과를 반환하고 입력이 달라진 재계산은
이전 Row를 SUPERSEDED로 표시한 새 Version을 만듭니다. 과거 Snapshot은 수정하지 않습니다.

명시적 NOT_PAYABLE만 정상 0원 결과가 될 수 있습니다. Rule 누락, Version 충돌, 입력 누락 또는
Engine 실패는 0원 성공으로 변환하지 않습니다.
