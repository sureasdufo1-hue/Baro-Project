# CODEX-DB-01 결과

## 1. 작업 판정

`PARTIAL_SUCCESS` — 애플리케이션 구현과 SQLite Seed 검증은 완료했으며 PostgreSQL Runtime만 환경 제한으로 미검증이다.

## 2. PostgreSQL 초기화 결과

격리된 `policy-postgres` 서비스와 `bootstrap_postgresql.sql` 자동 초기화 구성을 추가했다. Docker Desktop Linux 엔진이 실행되지 않아 실제 컨테이너 적재는 `NOT_VERIFIED`이다.

## 3. SQLite/PostgreSQL 비교

SQLite 무결성 및 패키지 SHA-256은 PASS. PostgreSQL 비교는 Runtime 미실행으로 `NOT_VERIFIED`이다.

## 4. ORM/Repository 연결

기존 UUID 운영 도메인 스키마와 Seed 정수형 Read Model을 충돌시키지 않고, 공통 설정과 Engine을 사용하는 SQLAlchemy Core 읽기 전용 Repository로 연결했다.

## 5. Read API

회사, 상품, Version, 문서, Coverage, Rule, Disease Code, Validation, Evidence API를 연결했다.

## 6. Version Resolver

`RESOLVED`, `NOT_FOUND`, `AMBIGUOUS`, `HUMAN_REVIEW_REQUIRED`를 fail-closed 방식으로 반환한다.

## 7. Promotion Gate

`VERIFIED_POLICY`, POLICY Evidence, 계산식, 질병담보 KCD/정의, Validation BLOCK 여부를 DB에서 검사한다.

## 8. 자동차 Claim 테스트

자기차량손해 5,000,000 - 200,000 = 4,800,000원, Evidence 포함, PASS.

## 9. 31201 암 담보 차단 테스트

`OFFICIAL_CROSSCHECKED` 상태를 유지하며 `HUMAN_REVIEW_REQUIRED`, 금액 null로 차단했다.

## 10. Evidence 조회

문서 종류, 파일명, 페이지, 조문 번호/제목, 원문, Source URL, 로컬 경로를 반환한다.

## 11. 관리자 Summary

회사 1, 상품 3, Version 3, 문서 4, Coverage 3, VERIFIED_POLICY 1, OFFICIAL_CROSSCHECKED 2, 사람 검토 필요 2.

## 12. 테스트 결과

86 passed, 0 failed. Ruff와 mypy 통과.

## 13. PostgreSQL Runtime 상태

`NOT_VERIFIED`: Docker Desktop Linux engine pipe가 존재하지 않았다.

## 14. 남은 Blocker

Docker Desktop 실행 후 `docker compose up -d policy-postgres`로 실제 적재 및 SQLite/PostgreSQL 건수 비교가 필요하다.

## 15. CODEX-DB-02 준비상태

`YES`. 실제 31201 POLICY가 들어오면 동일 Repository와 Promotion Gate에서 검증할 수 있다.
