# 프로젝트 기준자료

## 프로젝트 정의

- 프로젝트명(가칭): ClaimLens AI / Baro Project
- 목적: 계약·약관·의료 및 사고 증빙을 근거로 재현 가능한 보험금 예상 산정과 손해사정 검토를 지원
- 1차 범위: 정액형 제3보험
- 기준일: 2026-08-18

## 문서 우선순위

1. 요구사항정의서(SRS)
2. 시스템 아키텍처 설계서
3. ERD 설계서
4. 시스템 기능구조
5. 사용자 흐름도
6. 화면설계서
7. 현재 구현
8. 주석 및 임시 메모

충돌 또는 미정 보험 규칙은 추측하지 않고 명시적인 미결 상태나 전문가 검토로 전환합니다.

## 원본 자료

원본 PDF는 `docs/references/`에 변경 없이 보존합니다.

| 순위 | 문서 | 역할 |
| --- | --- | --- |
| 1 | `01-requirements-definition.pdf` | 범위, Actor, 기능·비기능 요구사항과 인수 기준 |
| 2 | `02-system-architecture.pdf` | 모듈러 모놀리스, 비동기 워커, 보안·데이터·처리 구조 |
| 3 | `03-erd-design.pdf` | 엔터티, 관계, 키, 이력·버전·감사 데이터 구조 |
| 4 | `04-user-flow.pdf` | 사용자·전문가·관리자 업무 흐름과 예외 흐름 |
| 5 | `05-ui-specification.pdf` | 화면 ID, UI 상태, 화면/API 및 요구사항 추적 |
| - | `06-agents-source.pdf` | 저장소 작업 규칙의 원본. 루트 `AGENTS.md`에 반영 |

## 핵심 불변식

```text
Verified Facts
+ Contract Coverage
+ Policy Version
+ Rule Version
= Coverage Assessment
+ Benefit Calculation
+ Evidence
```

- LLM은 보험금 금액을 직접 결정하지 않습니다.
- OCR 결과는 검증된 Fact가 아닙니다.
- 계산은 결정론적 Rule Engine에서만 수행합니다.
- 계산값은 계약, 약관·Rule 버전, 검증 Fact, 원문 위치로 추적할 수 있어야 합니다.
- 과거 계산은 덮어쓰지 않고 재계산 버전을 추가합니다.
- 미확정 약관·Rule 또는 충돌은 `MANUAL_REVIEW`로 처리합니다.

## MVP 업무 범위

포함: 보험계약 등록·증권 OCR, Claim 생성, 의료문서 보안 업로드, Fact 추출·검증, 계약 담보 탐색, Policy/Rule Version 결정, 지급·면책·감액·한도 평가, 정액형 계산, Evidence, 전문가 검토·감사, 보험 마스터·Rule 관리.

후속 범위: 실손보험 정밀 계산, 자동차·책임·산재 보험, 복잡한 후유장해·의료 인과관계 자동판정, 보험회사 지급 시스템 직접 연동, 보험금 청구 자동 제출.

## 핵심 사용자 흐름

```text
로그인 -> 보험계약 등록 -> Claim 생성 -> 문서 업로드
-> OCR/AI 추출 -> 사용자 Fact 확인 -> 약관 버전 결정
-> 가입 담보 후보 탐색 -> Eligibility 평가 -> 결정론적 Calculation
-> Evidence 생성 -> 담보별 결과와 근거 조회
```

예외 흐름은 추가서류 요청, 사용자 확인, 전문가 검토, 처리 실패를 명시적으로 구분합니다.

## 핵심 도메인

- 계정·동의·권한: User, Consent, RBAC
- 계약: Insured, InsuranceContract, ContractCoverage
- 보험 마스터: InsuranceCompany, InsuranceProduct, ProductVersion
- 약관·Rule: Policy, PolicyVersion, PolicyClause, Coverage, BenefitRule, RuleVersion
- 사고·문서: Claim, Accident, MedicalDocument, OCRResult
- Fact: ExtractedFact, VerifiedFact, Diagnosis, Surgery, Hospitalization
- 판단·계산: CoverageAssessment, AssessmentRuleResult, BenefitCalculation
- 설명·통제: Evidence, Review, ReviewAssignment, AuditLog

## 구현 우선순위

1. 저장소·설정·DB·인증·RBAC·감사 기반
2. 보험회사·상품·약관·담보·Rule 마스터
3. 피보험자·계약·계약담보
4. Claim과 상태 머신
5. 안전한 문서 업로드와 저장
6. OCR/AI 어댑터, Fact 추출과 검증
7. 버전 결정, 담보 탐색, Eligibility/Rule Engine
8. 계산 Snapshot·버전·재계산
9. Evidence와 계산 근거 UI
10. 전문가 검토·추가서류·Override 감사

## 기술 스택 결정 전 원칙

- 논리 구조는 모듈러 모놀리스 + 비동기 워커를 유지합니다.
- 외부 OCR, LLM, 저장소는 어댑터 뒤에 둡니다.
- 금액은 정수 원 단위 또는 Decimal로 처리합니다.
- 데이터베이스 변경은 마이그레이션으로 관리합니다.
- 새 기술 스택을 정하면 ADR과 실행·검증 명령을 추가합니다.

