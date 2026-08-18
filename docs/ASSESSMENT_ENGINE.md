# Deterministic Assessment Engine

CODEX-07은 VerifiedFact와 실제 ContractCoverage만 사용해 Versioned Policy/Rule을 결정론적으로
평가합니다. PolicyVersion이 없거나 중복되면 최신 Version으로 대체하지 않고 MANUAL_REVIEW로
보냅니다. 가입하지 않은 Coverage Master는 평가대상에 추가하지 않습니다.

Rule DSL Schema Version은 `1.0`이며 EQ, NE, GT, GTE, LT, LTE, IN, NOT_IN, BETWEEN, EXISTS,
NOT_EXISTS만 허용합니다. DSL은 Python, JavaScript, SQL, Network/File 접근을 실행할 수 없습니다.

평가 순서는 Eligibility → Exclusion → Reduction → Limit입니다. Missing Fact는 False와 구분되어
ADDITIONAL_INFO_REQUIRED가 되며 Rule/Version 충돌이나 Invalid Rule은 MANUAL_REVIEW가 됩니다.
NOT_PAYABLE은 명시적 Rule 실패 또는 면책 Trigger에만 사용합니다.

CoverageAssessment와 AssessmentRuleResult는 적용 PolicyVersion, RuleVersion, 최소 입력 Snapshot과
조건 Trace를 보존합니다. 재평가는 기존 Row를 덮어쓰지 않습니다. 금액 계산과 CALCULATION Rule
실행은 CODEX-08의 책임입니다.
