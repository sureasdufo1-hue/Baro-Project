# DB손해보험 보험약관 DB Seed Package

이 패키지는 현재까지 구축한 DB손해보험 보험약관 POC 데이터에서 생성한 초기 DB 자료입니다.

## 포함 데이터

- 보험회사: 1
- 상품: 3
- 상품 버전: 3
- 공식 문서: 4
- PDF 페이지 원문: 289
- 구조화 조문: 3
- 담보: 3
- 지급조건: 9
- 지급 Rule: 2
- 한도 Rule: 3
- 질병/KCD 레코드: 2
- 원문 Evidence: 7
- Validation Log: 8

## 데이터 상태

- `프로미카 개인용자동차보험 / 자기차량손해`: `VERIFIED_POLICY`
  - 실제 POLICY Evidence 존재
  - 제21조, 제23조, 제24조 연결
- `New간편암건강보험2601` 2개 암담보: `OFFICIAL_CROSSCHECKED`
  - 상품요약서 + 사업방법서 교차확인
  - 실제 보험약관/KCD 별표가 아직 없으므로 Claim 계산에 사용하면 안 됨
- `참좋은오토바이운전자보험1707`: POLICY 원본 메타데이터와 페이지 원문은 수록되어 있으나 담보 Rule은 아직 구조화되지 않음

## 파일

- `schema_postgresql.sql`: PostgreSQL Schema + 조회 View
- `seed_postgresql.sql`: 현재 확보 데이터 INSERT
- `bootstrap_postgresql.sql`: Schema + Seed 일괄 실행
- `dbins_policy_seed.sqlite3`: 로컬 확인용 SQLite DB
- `seed_export.json`: 전체 데이터 JSON Export
- `sources_manifest.json`: 공식 원문 파일/URL/Hash 목록
- `DATA_DICTIONARY.md`: 주요 테이블·상태값 설명

## PostgreSQL 적재

```bash
psql -U <user> -d <database> -f bootstrap_postgresql.sql
```

## 중요 안전조건

`SUMMARY`, `BUSINESS_METHOD`에서 추출한 Rule은 지급판정 근거가 아닙니다. `VERIFIED_POLICY` + 실제 POLICY Evidence를 충족하는 담보만 계산 대상으로 사용하십시오. 질병담보는 KCD/약관상 질병정의 검증까지 추가로 요구하는 것이 권장됩니다.
