# Data Dictionary

| 테이블 | 용도 | 현재 데이터 |
|---|---|---:|
| `insurance_companies` | 보험회사 Master | 1 |
| `insurance_products` | 보험상품 Master | 3 |
| `product_versions` | 계약일/약관 적용 버전 | 3 |
| `policy_documents` | 공식 약관·요약서·사업방법서 메타데이터 | 4 |
| `policy_pages` | PDF 페이지별 원문 텍스트 | 289 |
| `policy_sections` | 약관 편/장/절 구조 | 0 |
| `policy_articles` | 조문 단위 원문 | 3 |
| `coverages` | 보장담보와 Rule 상태 | 3 |
| `coverage_conditions` | 지급조건/제외조건 후보 | 9 |
| `payment_rules` | 지급방식·지급률·산식 | 2 |
| `payment_formulas` | 세부 산식 정의 | 0 |
| `coverage_limits` | 횟수·한도 | 3 |
| `deductibles` | 자기부담금/공제 | 0 |
| `exclusions` | 면책·보상하지 않는 손해 | 1 |
| `definitions` | 약관 정의 | 0 |
| `policy_tables` | 별표/분류표 | 0 |
| `policy_table_rows` | 별표 행 데이터 | 0 |
| `disease_codes` | KCD 및 질병분류 | 2 |
| `surgery_codes` | 수술분류 | 0 |
| `disability_rates` | 장해지급률 | 0 |
| `source_references` | Rule→원문 Evidence | 7 |
| `crawl_logs` | 수집 로그 | 0 |
| `validation_logs` | 검증·차단·Promotion 상태 로그 | 8 |

## 핵심 상태값

- `VERIFIED_POLICY`: 실제 보험약관 원문 근거가 확인된 Rule
- `OFFICIAL_CROSSCHECKED`: 상품요약서/사업방법서 등 공식 보조자료끼리 교차확인됐지만 POLICY 검증 전
- `AWAITING_POLICY_APPENDIX`: KCD 등 약관 별표 확보 대기
- Validation `BLOCK`: 보험금 계산 금지
- Validation `PASS`: 해당 검증항목 통과. 이것만으로 전체 Rule이 실행 가능하다는 의미는 아님

## 현재 계산 허용 권고

`v_coverage_readiness.executable_base_gate = true`인 담보를 1차 실행 후보로 사용하고, 질병담보는 `has_verified_kcd = true`까지 추가 확인하십시오.
