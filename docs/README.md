# 문서 안내

- `PROJECT_BASELINE.md`: 프로젝트 범위, 기준 우선순위, 핵심 불변식과 구현 순서
- `INSURANCE_MASTER.md`: 보험회사·상품·약관·담보·Rule 저장 구조와 안전장치
- `CONTRACT_DOMAIN.md`: 피보험자·실제 보험계약·가입담보와 객체 권한
- `CLAIM_DOMAIN.md`: Claim·Accident Aggregate, 상태전이, 객체 권한과 API
- `DOCUMENT_STORAGE.md`: 의료문서 Upload 보안 Pipeline과 Private Storage
- `OCR_FACT_PIPELINE.md`: OCR, 구조화 Fact 추출과 사용자 검증 Pipeline
- `ASSESSMENT_ENGINE.md`: Policy/Rule Version 해석과 결정론적 담보 지급요건 평가
- `CALCULATION_ENGINE.md`: Decimal 기반 보험금 계산, Snapshot, Versioning과 재계산
- `EVIDENCE_CHAIN.md`: 계산 버전별 약관·Rule·VerifiedFact·원본문서 근거사슬과 결과 UI
- `HUMAN_REVIEW.md`: 전문가 Queue, 배정, 승인·수정·추가자료·판단불가와 Override 감사
- `SECURITY_THREAT_MODEL.md`: 자산·행위자·위협·Severity와 적용된 방어선
- `OPERATIONS_RUNBOOK.md`: 배포 Gate, Health/Metric, Backup/Restore, 장애대응과 Retention 기반
- `RELEASE_CANDIDATE.md`: CODEX-12 통합검증, 결함, 제한사항과 Release 판정
- `OPERATIONAL_COMPLETION.md`: P1 종결, Production adapter, 운영검증과 최종 GAP
- `references/`: 사용자가 제공한 원본 설계 PDF
- `decisions/`: 아키텍처 결정 기록(ADR)

원본 자료는 수정하지 않습니다. 설계 해석이나 기술 선택이 필요하면 `decisions/`에 배경, 선택지, 결정, 결과를 기록합니다.
