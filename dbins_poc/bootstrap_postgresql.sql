-- PostgreSQL 16 target schema for the POC
CREATE TABLE insurance_companies (
  id BIGSERIAL PRIMARY KEY, canonical_name VARCHAR(200) NOT NULL UNIQUE,
  company_type VARCHAR(20) NOT NULL, official_domain TEXT
);
CREATE TABLE insurance_products (
  id BIGSERIAL PRIMARY KEY, company_id BIGINT NOT NULL REFERENCES insurance_companies(id),
  raw_product_name TEXT NOT NULL, normalized_product_name TEXT, product_code VARCHAR(100),
  category VARCHAR(100), subcategory VARCHAR(100), source_type VARCHAR(20) NOT NULL DEFAULT 'LIVE'
);
CREATE TABLE product_versions (
  id BIGSERIAL PRIMARY KEY, product_id BIGINT NOT NULL REFERENCES insurance_products(id),
  version_name VARCHAR(100) NOT NULL, sale_status VARCHAR(30) NOT NULL,
  sale_start_date DATE, sale_end_date DATE, effective_from DATE, effective_to DATE,
  CONSTRAINT uq_product_version UNIQUE(product_id,version_name)
);
CREATE TABLE policy_documents (
  id BIGSERIAL PRIMARY KEY, version_id BIGINT NOT NULL REFERENCES product_versions(id),
  document_type VARCHAR(30) NOT NULL, file_name TEXT NOT NULL, local_path TEXT NOT NULL,
  source_url TEXT NOT NULL, sha256 CHAR(64) NOT NULL UNIQUE, page_count INTEGER,
  text_layer BOOLEAN, source_type VARCHAR(20) NOT NULL DEFAULT 'LIVE'
);
CREATE TABLE policy_pages (
  id BIGSERIAL PRIMARY KEY, document_id BIGINT NOT NULL REFERENCES policy_documents(id) ON DELETE CASCADE,
  page_number INTEGER NOT NULL, raw_text TEXT NOT NULL,
  UNIQUE(document_id,page_number)
);
CREATE TABLE coverages (
  id BIGSERIAL PRIMARY KEY, version_id BIGINT NOT NULL REFERENCES product_versions(id),
  coverage_name TEXT NOT NULL, coverage_type VARCHAR(50), rule_status VARCHAR(30) NOT NULL,
  trigger_text TEXT, payment_type VARCHAR(50), payment_formula TEXT, confidence_score NUMERIC(4,3)
);
CREATE TABLE exclusions (
  id BIGSERIAL PRIMARY KEY, coverage_id BIGINT NOT NULL REFERENCES coverages(id) ON DELETE CASCADE,
  exclusion_type VARCHAR(100), exclusion_text TEXT NOT NULL
);
CREATE TABLE source_references (
  id BIGSERIAL PRIMARY KEY, coverage_id BIGINT NOT NULL REFERENCES coverages(id) ON DELETE CASCADE,
  document_id BIGINT NOT NULL REFERENCES policy_documents(id), page_number INTEGER NOT NULL,
  article_no VARCHAR(100), source_text TEXT NOT NULL, reference_type VARCHAR(30) NOT NULL
);
CREATE INDEX idx_products_name ON insurance_products USING gin (to_tsvector('simple', coalesce(normalized_product_name,'')));
CREATE INDEX idx_pages_text ON policy_pages USING gin (to_tsvector('simple', raw_text));

CREATE TABLE policy_sections (
  id BIGSERIAL PRIMARY KEY, document_id BIGINT NOT NULL REFERENCES policy_documents(id) ON DELETE CASCADE,
  parent_id BIGINT REFERENCES policy_sections(id), section_type VARCHAR(30) NOT NULL,
  section_no VARCHAR(100), title TEXT, start_page INTEGER, end_page INTEGER
);
CREATE TABLE policy_articles (
  id BIGSERIAL PRIMARY KEY, document_id BIGINT NOT NULL REFERENCES policy_documents(id) ON DELETE CASCADE,
  section_id BIGINT REFERENCES policy_sections(id), article_no VARCHAR(100), title TEXT,
  paragraph_no VARCHAR(50), item_no VARCHAR(50), raw_text TEXT NOT NULL, page_number INTEGER NOT NULL
);
CREATE TABLE coverage_conditions (
  id BIGSERIAL PRIMARY KEY, coverage_id BIGINT NOT NULL REFERENCES coverages(id) ON DELETE CASCADE,
  condition_type VARCHAR(50), condition_operator VARCHAR(50), condition_value JSONB, raw_text TEXT
);
CREATE TABLE payment_rules (
  id BIGSERIAL PRIMARY KEY, coverage_id BIGINT NOT NULL REFERENCES coverages(id) ON DELETE CASCADE,
  payment_type VARCHAR(50) NOT NULL, base_amount NUMERIC, payment_rate NUMERIC,
  formula JSONB, raw_text TEXT, confidence_score NUMERIC(4,3), human_verified BOOLEAN DEFAULT FALSE
);
CREATE TABLE payment_formulas (
  id BIGSERIAL PRIMARY KEY, payment_rule_id BIGINT NOT NULL REFERENCES payment_rules(id) ON DELETE CASCADE,
  expression TEXT NOT NULL, variables JSONB, rounding_rule TEXT
);
CREATE TABLE coverage_limits (
  id BIGSERIAL PRIMARY KEY, coverage_id BIGINT NOT NULL REFERENCES coverages(id) ON DELETE CASCADE,
  limit_type VARCHAR(50), amount NUMERIC, currency CHAR(3) DEFAULT 'KRW', period_rule TEXT, raw_text TEXT
);
CREATE TABLE deductibles (
  id BIGSERIAL PRIMARY KEY, coverage_id BIGINT NOT NULL REFERENCES coverages(id) ON DELETE CASCADE,
  deductible_type VARCHAR(50), amount NUMERIC, rate NUMERIC, formula JSONB, raw_text TEXT
);
CREATE TABLE definitions (
  id BIGSERIAL PRIMARY KEY, version_id BIGINT NOT NULL REFERENCES product_versions(id) ON DELETE CASCADE,
  term TEXT NOT NULL, definition TEXT NOT NULL, document_id BIGINT REFERENCES policy_documents(id), page_number INTEGER
);
CREATE TABLE policy_tables (
  id BIGSERIAL PRIMARY KEY, document_id BIGINT NOT NULL REFERENCES policy_documents(id) ON DELETE CASCADE,
  title TEXT, table_type VARCHAR(50), page_number INTEGER, raw_text TEXT
);
CREATE TABLE policy_table_rows (
  id BIGSERIAL PRIMARY KEY, table_id BIGINT NOT NULL REFERENCES policy_tables(id) ON DELETE CASCADE,
  row_no INTEGER NOT NULL, cells JSONB NOT NULL
);
CREATE TABLE disease_codes (
  id BIGSERIAL PRIMARY KEY, coverage_id BIGINT REFERENCES coverages(id) ON DELETE CASCADE,
  disease_group TEXT, kcd_code_from VARCHAR(20), kcd_code_to VARCHAR(20), included_codes JSONB, excluded_codes JSONB, raw_text TEXT
);
CREATE TABLE surgery_codes (
  id BIGSERIAL PRIMARY KEY, coverage_id BIGINT REFERENCES coverages(id) ON DELETE CASCADE,
  surgery_name TEXT, surgery_category TEXT, surgery_grade VARCHAR(50), surgery_code VARCHAR(50), payment_rate NUMERIC, raw_text TEXT
);
CREATE TABLE disability_rates (
  id BIGSERIAL PRIMARY KEY, coverage_id BIGINT REFERENCES coverages(id) ON DELETE CASCADE,
  body_part TEXT, disability_description TEXT, disability_rate NUMERIC(6,5), evaluation_rule TEXT, raw_text TEXT
);
CREATE TABLE crawl_logs (
  id BIGSERIAL PRIMARY KEY, company_id BIGINT REFERENCES insurance_companies(id), source_url TEXT,
  started_at TIMESTAMPTZ, finished_at TIMESTAMPTZ, status VARCHAR(30), http_status INTEGER,
  items_found INTEGER DEFAULT 0, documents_found INTEGER DEFAULT 0, error TEXT
);
CREATE TABLE validation_logs (
  id BIGSERIAL PRIMARY KEY, entity_type VARCHAR(50) NOT NULL, entity_id BIGINT NOT NULL,
  rule_code VARCHAR(100) NOT NULL, status VARCHAR(30) NOT NULL, message TEXT, created_at TIMESTAMPTZ DEFAULT now()
);


-- Phase 2: distinguish summary-derived rule candidates from policy-verified rules.
ALTER TABLE disease_codes
  ADD COLUMN IF NOT EXISTS source_status VARCHAR(30) NOT NULL DEFAULT 'NOT_EXTRACTED';

CREATE INDEX IF NOT EXISTS idx_coverage_conditions_coverage
  ON coverage_conditions(coverage_id);
CREATE INDEX IF NOT EXISTS idx_payment_rules_coverage
  ON payment_rules(coverage_id);
CREATE INDEX IF NOT EXISTS idx_coverage_limits_coverage
  ON coverage_limits(coverage_id);
CREATE INDEX IF NOT EXISTS idx_disease_codes_coverage
  ON disease_codes(coverage_id);



-- Convenience views for application/query layer
CREATE OR REPLACE VIEW v_policy_catalog AS
SELECT
  c.id AS company_id,
  c.canonical_name AS company_name,
  p.id AS product_id,
  p.product_code,
  p.raw_product_name,
  p.normalized_product_name,
  p.category,
  p.subcategory,
  v.id AS version_id,
  v.version_name,
  v.sale_status,
  v.sale_start_date,
  v.sale_end_date,
  v.effective_from,
  v.effective_to,
  d.id AS document_id,
  d.document_type,
  d.file_name,
  d.source_url,
  d.sha256,
  d.page_count,
  d.source_type
FROM insurance_companies c
JOIN insurance_products p ON p.company_id = c.id
JOIN product_versions v ON v.product_id = p.id
LEFT JOIN policy_documents d ON d.version_id = v.id;

CREATE OR REPLACE VIEW v_coverage_readiness AS
SELECT
  cv.id AS coverage_id,
  p.product_code,
  p.raw_product_name,
  v.version_name,
  cv.coverage_name,
  cv.coverage_type,
  cv.rule_status,
  cv.confidence_score,
  EXISTS (
    SELECT 1 FROM source_references sr
    JOIN policy_documents pd ON pd.id = sr.document_id
    WHERE sr.coverage_id = cv.id AND pd.document_type = 'POLICY'
  ) AS has_policy_evidence,
  EXISTS (
    SELECT 1 FROM disease_codes dc
    WHERE dc.coverage_id = cv.id
      AND COALESCE(dc.source_status,'') IN ('VERIFIED_POLICY','VERIFIED_POLICY_APPENDIX')
  ) AS has_verified_kcd,
  CASE
    WHEN cv.rule_status = 'VERIFIED_POLICY'
     AND EXISTS (
       SELECT 1 FROM source_references sr
       JOIN policy_documents pd ON pd.id = sr.document_id
       WHERE sr.coverage_id = cv.id AND pd.document_type = 'POLICY'
     )
    THEN TRUE ELSE FALSE
  END AS executable_base_gate
FROM coverages cv
JOIN product_versions v ON v.id = cv.version_id
JOIN insurance_products p ON p.id = v.product_id;

CREATE OR REPLACE VIEW v_rule_candidates AS
SELECT
  cv.id AS coverage_id,
  p.product_code,
  p.raw_product_name,
  v.version_name,
  cv.coverage_name,
  cv.rule_status,
  pr.payment_type,
  pr.payment_rate,
  pr.formula,
  pr.confidence_score AS payment_confidence,
  pr.human_verified,
  cv.trigger_text
FROM coverages cv
JOIN product_versions v ON v.id = cv.version_id
JOIN insurance_products p ON p.id = v.product_id
LEFT JOIN payment_rules pr ON pr.coverage_id = cv.id;


BEGIN;
INSERT INTO insurance_companies (id, canonical_name, company_type, official_domain) VALUES (1, 'DB손해보험', 'NON_LIFE', 'idbins.com') ON CONFLICT DO NOTHING;
INSERT INTO insurance_products (id, company_id, raw_product_name, normalized_product_name, product_code, category, subcategory, source_type) VALUES (1, 1, '프로미카 개인용자동차보험', '프로미카 개인용자동차보험', 'PROMY-AUTO', '자동차보험', '개인용', 'LIVE') ON CONFLICT DO NOTHING;
INSERT INTO insurance_products (id, company_id, raw_product_name, normalized_product_name, product_code, category, subcategory, source_type) VALUES (2, 1, '무배당 프로미라이프 New간편암건강보험2601', '무배당 프로미라이프 New간편암건강보험2601', '31201', '장기보험', '건강', 'LIVE') ON CONFLICT DO NOTHING;
INSERT INTO insurance_products (id, company_id, raw_product_name, normalized_product_name, product_code, category, subcategory, source_type) VALUES (3, 1, '무배당 프로미라이프 참좋은오토바이운전자보험1707', '무배당 프로미라이프 참좋은오토바이운전자보험1707', '30944', '장기보험', '운전자', 'LIVE') ON CONFLICT DO NOTHING;
INSERT INTO product_versions (id, product_id, version_name, sale_status, sale_start_date, sale_end_date, effective_from, effective_to) VALUES (1, 1, '2024-02-22', 'CURRENT', '2024-02-22', NULL, '2024-02-22', NULL) ON CONFLICT DO NOTHING;
INSERT INTO product_versions (id, product_id, version_name, sale_status, sale_start_date, sale_end_date, effective_from, effective_to) VALUES (2, 2, '2601', 'CURRENT', '2026-04-01', NULL, '2026-04-01', NULL) ON CONFLICT DO NOTHING;
INSERT INTO product_versions (id, product_id, version_name, sale_status, sale_start_date, sale_end_date, effective_from, effective_to) VALUES (3, 3, '1707', 'ARCHIVED', '2017-07-10', NULL, '2017-07-10', NULL) ON CONFLICT DO NOTHING;
INSERT INTO policy_documents (id, version_id, document_type, file_name, local_path, source_url, sha256, page_count, text_layer, source_type) VALUES (1, 1, 'POLICY', 'promica_auto_2024-02-22.pdf', 'storage/policies/db_insurance/promica_auto_2024-02-22.pdf', 'https://www.idbins.com/cYakgwanDown.do?FilePath=InsProduct%2F2024-02-22_%ED%94%84%EB%A1%9C%EB%AF%B8%EC%B9%B4%EA%B0%9C%EC%9D%B8%EC%9A%A9%EC%9E%90%EB%8F%99%EC%B0%A8%EB%B3%B4%ED%97%98%EC%95%BD%EA%B4%80.pdf', 'cb7e818b0d8988ae3e4229748f9b04a4eb3e61cd62dc420aba11f58c9a6b1aa9', 107, TRUE, 'LIVE') ON CONFLICT DO NOTHING;
INSERT INTO policy_documents (id, version_id, document_type, file_name, local_path, source_url, sha256, page_count, text_layer, source_type) VALUES (2, 2, 'SUMMARY', 'new_cancer_health_2601_summary.pdf', 'storage/policies/db_insurance/new_cancer_health_2601_summary.pdf', 'https://www.idbins.com/cYakgwanDown.do?FilePath=InsProduct%2F%EC%9A%94%EC%95%BD_31201%2800%29_20260401.pdf', 'fbf8147065b5c73cebfb85d7f81692aa7cec810c14f644c63d13ca0b79521f03', 9, TRUE, 'LIVE') ON CONFLICT DO NOTHING;
INSERT INTO policy_documents (id, version_id, document_type, file_name, local_path, source_url, sha256, page_count, text_layer, source_type) VALUES (3, 2, 'BUSINESS_METHOD', 'new_cancer_health_2601_business_method.pdf', 'storage/policies/db_insurance/new_cancer_health_2601_business_method.pdf', 'https://www.idbins.com/cYakgwanDown.do?FilePath=InsProduct%2F%EC%82%AC%EB%B0%A9_31201%2800%29_20260401.pdf', '54be41332d5810fbdbe5451b57d52a9754e29764f318d7411764bf3f4c61921d', 17, TRUE, 'LIVE') ON CONFLICT DO NOTHING;
INSERT INTO policy_documents (id, version_id, document_type, file_name, local_path, source_url, sha256, page_count, text_layer, source_type) VALUES (4, 3, 'POLICY', 'archived_motorcycle_driver_1707_policy.pdf', 'storage/policies/db_insurance/archived_motorcycle_driver_1707_policy.pdf', 'https://www.idbins.com/cYakgwanDown.do?FilePath=InsProduct%2F30944_20170710_%EC%95%BD%EA%B4%80_%EB%AC%B4%EB%B0%B0%EB%8B%B9+%ED%94%84%EB%A1%9C%EB%AF%B8%EB%9D%BC%EC%9D%B4%ED%94%84+%EC%B0%B8%EC%A2%8B%EC%9D%80%EC%98%A4%ED%86%A0%EB%B0%94%EC%9D%B4%EC%9A%B4%EC%A0%84%EC%9E%90%EB%B3%B4%ED%97%981707.pdf', '02e47b507f0709bd2d9bf808862d01342c256c28b27b26a7c2d8edb6951081a9', 156, TRUE, 'LIVE') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (1, 1, 1, '៳ᱲᲦ
ᚪᲥᱤᲱᢌᶊᩛὑ
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (2, 1, 2, '목차
유의사항
주요 내용 요약
보험약관 안내문
피보험자는 보험금을 청구할 수 있는 사람입니다.
그 중에서 보험증권에 기재된 피보험자를 기명피보험자라고 합니다.
(피보험자의 정의  ☞                  )
보험기간은 보험회사가 보상책임을 지는 기간입니다. 
일반적으로 보험시작일 24시부터 보험만료일 24시까지 입니다.
(보험기간의 정의  ☞                  )
보통약관의 보장종목은 총 5가지 입니다.
1) 대인배상 : 다른 사람을 다치거나 죽게 하였을 때
2) 대물배상 : 다른 사람의 차량(재물)에 손해를 입혔을 때 
3) 자기신체사고 : 고객님이 상해를 입었을 때
4) 자기차량손해 : 고객님의 차량이 손해를 입었을 때
5) 무보험자동차에 의한 상해 : 고객님이 무보험자동차에 의해 상해를 입었을 때
환경을 생각하는 대표적인 녹색특약을 소개해 드립니다.
•Ever Green : 이메일 등으로 증권을 받으면 보험료를 할인해드립니다.
                          (종이절감으로 나무를 보호하고 CO2를 줄입니다.)
•주행거리특약 : 연간 15,000km 이하 운행 시 보험료를 할인해 드립니다.
                          (운행량 절감으로 배기가스 배출량이 감소됩니다.)
고객님의 선택에 따라 추가적인 보장이 가능합니다.
갑작스런 고장 시 당황하지 마시고 프로미카 서비스를 이용해 보세요!
(긴급견인, 비상급유 등 10가지 서비스)
37p
58p
24~28p
164p
165~171p
30p
피보험자
보험기간
보통약관
기본보장
특별약관
선택보장
1
2
3
4
자기신체사고의 
보장확대 특별약관
자기차량손해의
보장확대 특별약관
다른자동차의
운전 중 위험부담
130~134p
기타 특별약관
152~164p
긴급출동
5
102~120p
120~129p
DB손해보험 고객상담센터
약관을 보다 쉽고 편리하게 찾아보는 방법
증권의 내용을 약관에서 확인하세요
증권을 확인하셨나요? 아래 증권(샘플)에 표시된 부분과 관련하여, 
우측 페이지를 참고 하셔서 약관에서 해당내용을 찾아 보시기 바랍니다.
(또는 담당 PA , 모집인에게 연락하세요!)
1588-0100
1
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (3, 1, 3, '프로미카 개인용 자동차보험
CONTENTS
쉽게 이해하는 약관 요약서
약관을 쉽게 이용할 수 있는 가이드북
주요 보장종목 안내
23
•상대방이 다쳤을 때
24
•상대방 차량이 부셔졌을 때
25
•고객님이 상해를 입은 경우
26
•고객님 차량에 손해가 생긴 경우
27
•가해 차량이 무보험인 경우
28
•이런 경우 보험금이 지급되지 않습니다.
29
•긴급출동서비스 안내
30
•운전가능자에 따라 보험료가 달라집니다.
31
•자주 묻는 질문을 확인하세요!(Q&A)
32
•약관을 읽기 전 주요 보험용어를 확인하세요!
33
계약 내용 확인 사항 등 
18
사고 시  대처방법
19
보험 만기 시 유의할 사항
20
보험료할증에 대해 유의할 사항
21
보험약관 안내문
목차
유의사항
주요 내용 요약
증권에 표기된 특별약관을 확인하세요.
※ 증권은 용지크기의 제한으로 인해, 일부 축약된 약어로 표현됩니다.    
      아래에서 주요 특별약관의 약관 상 정식명칭을 확인하세요.
고객님이 유의하실 사항
약관의 주요 내용 요약
1. 보험약관이란? 
12
2. 한 눈에 보는 약관의 구성
12
3. QR코드를 통한 편리한 정보 이용
12
4. 약관의 핵심 체크항목 쉽게 찾기 (보통약관 기준)
13
5. 약관을 쉽게 이용할 수 있는 꿀팁
15
6. 기타 문의사항
15
증권상 특별약관 명칭
증권상 특별약관 명칭
가족 및 형제자매
운전한정
가족사랑
가족운전자 한정
가족한정외 1인 추가
부상회복지원금
교통안전교육 실버우대
기계장치
지정운전자 1인 한정
기명피보험자 1인 한정
기명피보험자 및
기명 1인 한정
다른자동차 운전
대중교통사고 위로
레저용품 손해
부부운전자 한정
부부 한정 외 1인
블랙박스
성형 및 치아보철지원금
만 21세 이상 한정
만 22세 이상 한정
만 24세 이상 한정
만 26세 이상 한정
만 28세 이상 한정
만 30세 이상 한정
만 35세 이상 한정
만 43세 이상 한정
만 48세 이상 한정
승용차요일제
여성안심용품 지원
외제차 운반 비용
원격지 차량 운반
유상운송 위험
임시교통비
자동차상해
자동차상해(Family)
보행중상해(Family)
탑승중상해(Family)
전손시 취득세 비용
주말 교통사고 위로
주행거리(선할인)
주행거리(후할인)
주행거리
(후할인_OBD)
지정대리 청구권
차량가액 초과 수리
차량 신가 보상
타차 차량 손해
프로미카 SOS
프로미카SOS
(잠금제외)
프로미카오토케어
프로미하트
EverGreen
특별약관 명칭(정식)
특별약관 명칭(정식)
가족 및 형제자매 운전자 한정운전 
특별약관
가족사고 위로금 보장 특별약관
가족운전자 한정운전 특별약관
가족외 1인운전자 추가담보 추가
특별약관
부상회복지원금 특별약관
교통안전교육 실버우대 특별약관
기계장치에 관한 자기차량손해 특별약관
지정운전자 1인 한정운전 특별약관
기명피보험자 1인 한정운전 특별약관
기명피보험자 및 기명1인 운전자 
한정운전 특별약관
다른자동차 운전담보 특별약관
대중교통자동차 탑승 중 사고 특별약관
레저용품 손해담보 특별약관
부부 운전자 한정운전 특별약관
부부 외 1인 운전자 추가담보 
추가특별약관
차량용 블랙박스에 관한 특별약관
성형 및 치아보철 지원금 특별약관
운전자연령 만 21/22/24/26/28
/30/35/43/48세 이상 한정운전 
특별약관
승용차요일제 특별약관
여성 자기신체사고 안심용품 지원 특별약관
외제차 운반비용 담보 특별약관
원격지 차량운반비용 담보 특별약관
유상운송 위험담보 특별약관
임시교통비 담보 특별약관
자동차상해 특별약관
자동차상해 Family 통합보장 특별약관
차량 전손 시 취득세비용담보 특별약관
주말䞱휴일 교통사고 위로금 특별약관
주행거리 선할인 특별약관
주행거리 후할인 특별약관
OBD 주행거리 후할인 특별약관
지정대리청구에 관한 특별약관
차량가액 초과수리비 특별약관
차량 신차가액 보상담보 특별약관
다른자동차 차량손해 특별약관
프로미카 SOS서비스 특별약관
프로미카 SOS서비스 특별약관
잠금장치 해제 서비스 제외 추가특별약관
프로미카 오토케어서비스 특별약관
프로미하트 (서민우대 보험료 할인) 
특별약관
Ever Green(전자매체 활용 약관ㆍ증권 
발송) 특별약관
3
2
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (4, 1, 4, '보험약관 안내문
목차
유의사항
주요 내용 요약
보통약관
제21조(보상하는 손해) 
47
제22조(피보험자) 
47
제23조(보상하지 않는 손해) 
47
제24조(지급보험금의 계산) 
48
제3절  자기차량손해
제25조(보험금을 청구할 수 있는 경우) 
50
제26조(청구 절차 및 유의 사항) 
50
제27조(제출 서류) 
51
제28조(가지급금의 지급) 
52
제29조(손해배상을 청구할 수 있는 경우) 
52
제30조(청구 절차 및 유의 사항) 
52
제31조(제출 서류) 
53
제32조(가지급금의 지급) 
53
제33조(보험금의 분담) 
54
제34조(보험회사의 대위) 
55
제35조(보험회사의 불성실행위로 인한 손해배상 책임) 
55
제36조(합의 등의 협조䞱대행) 
55
제37조(공탁금의 대출) 
56
제3편  보험금 또는 손해배상의 청구
제12조(보상하는 손해) 
43
제13조(피보험자) 
43
제14조(보상하지 않는 손해) 
44
제15조(보험금의 종류와 한도) 
44
제16조(지급보험금의 계산) 
44
제17조(보상하는 손해) 
45
제18조(피보험자) 
45
제19조(보상하지 않는 손해) 
46
제20조(지급보험금의 계산) 
46
제6조(보상하는 손해) 
40
제7조(피보험자) 
40
제8조(보상하지 않는 손해) 
40
제9조(피보험자 개별적용) 
41
제10조(지급보험금의 계산) 
42
제11조(음주운전 또는 무면허운전, 마약ㆍ약물운전 등 관련 사고부담금) 
43
제1절  자기신체사고
제2절  무보험자동차에 의한 상해
제2절  대인배상 ,,와 대물배상
제3절  배상책임에서 공통으로 적용할 사항
제3조 (보상하는 손해) 
39
제4조 (피보험자)   
39
제5조 (보상하지 않는 손해)  
40
제2편  프로미카 개인용 자동차보험에서 보상하는 내용
제1절  대인배상Ō
제1장  배상책임
제2장  배상책임 이외의 보장종목
제1장  피보험자의 보험금 청구
제2장  손해배상청구권자의 직접 청구
제3장  보험금의 분담 등
보통약관
제1조 (용어의 정의)  
35
제2조 (프로미카 개인용 자동차보험의 구성) 
38
제1편  용어의 정의 및 프로미카 개인용 자동차보험의 구성
5
4
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (5, 1, 5, '제38조(보험계약의 성립) 
56
제39조(약관 교부 및 설명의무 등) 
56
제40조(설명서 교부 및 보험안내자료 등의 효력) 
57
제41조(청약의 철회) 
57
제42조(보험 기간) 
58
제43조(사고발생지역) 
59
특별약관
䣧  운전자 연령 만 21/22/24/26/28/30/35/43/48세 이상 한정운전 특별약관 
92
䣨  가족운전자 한정운전 특별약관 
93
   ①  가족 외 1인 운전자 추가담보 추가특별약관 
94
䣩  가족 및 형제자매 운전자 한정운전 특별약관 
94
䣪  부부 운전자 한정운전 특별약관 
95
   ①  부부 외 1인 운전자 추가담보 추가특별약관 
95
䣫  부부 및 자녀 운전자 한정운전 특별약관 
96 
䣬  기명피보험자 1인 한정운전 특별약관 
96
䣭  기명피보험자 1인 및 자녀 운전자 한정운전 특별약관 
97
䣮  지정운전자 1인 한정운전 특별약관 
98
䣯  기명피보험자 및 기명 1인 운전자 한정운전 특별약관 
99
䣰  임직원 운전자 한정운전 특별약관 
99
Ⅰ. 운전가능자에 대한 제한
１. 운전자 한정운전 특별약관
보험약관 안내문
목차
유의사항
주요 내용 요약
보통약관
<별표1>  대인배상, 무보험자동차에 의한 상해 지급기준 
66
<별표2>  대물배상 지급기준 
74
<별표3>  자기신체사고 지급기준 
76
<별표4>  과실상계 등 
77
<별표5>  동승자 유형별 감액비율표 
78
<부표>     보험금을 지급할 때의 적립이율 
78
[붙임] 상해의 구분과 책임보험금의 한도금액 
79
[붙임] 후유장애의 구분과 책임보험금의 한도금액 
87
보험금지급기준
제44조(계약 전 알릴 의무) 
59
제45조(계약 후 알릴 의무) 
59
제46조(사고발생 시 의무) 
59
제47조(보험계약 내용의 변경) 
60
제48조(피보험자동차의 양도) 
60
제49조(피보험자동차의 교체) 
61
제50조(보험계약의 취소) 
61
제51조(보험계약의 효력 상실) 
61
제52조(보험계약자의 보험계약 해지䞱해제) 
61
제52조의 2(위법계약의 해지) 
62
제53조(보험회사의 보험계약 해지) 
62
제54조(보험료의 환급 등) 
63
제55조(약관의 해석) 
64
제56조(보험회사의 개인정보이용 및 보험계약 정보의 제공) 
64
제57조(피보험자동차 등에 대한 조사) 
65
제58조(예금보험기금에 의한 보험금 등의 지급보장) 
65
제59조(보험사기행위 금지) 
65
제60조(분쟁의 조정) 
65
제61조(관할법원) 
65
제62조(준용규정) 
65
제2장  보험계약자 등의 의무
제3장  보험계약의 변동 및 보험료의 환급
제4장  그 밖의 사항
제4편  일반사항
제1장  보험계약의 성립
7
6
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (6, 1, 6, '䣧  법률비용지원금 특별약관 
137
   ①  벌금 제외 추가특별약관 
140
   ②  변호사 선임비용 제외 추가특별약관 
140
䣧  프로미카 SOS서비스 특별약관 
141
   ①  잠금장치 해제 서비스 제외 추가특별약관 
143
䣨  프로미카 오토케어 서비스 특별약관 
143
   ①  잠금장치 해제 서비스 제외 추가특별약관 
147
䣩  전기자동차 SOS 서비스 특별약관 
147
   ①  잠금장치 해제 서비스 제외 추가특별약관 
149
V. 사고처리 시 필요한 비용
Ⅵ. 긴급출동 서비스
Ⅶ. 보험료 납입
䣧  보험료 분할납입 특별약관 
150
䣨  보험료 자동납입 특별약관 
151
䣩  신용카드 이용 보험료납입 특별약관 
152
䣪  보험료정산약정에 관한 특별약관 
152
보험약관 안내문
목차
유의사항
주요 내용 요약
특별약관
䣧  자동차상해 Family 통합보장 특별약관 
102
䣨  자동차상해 특별약관 
105
䣩  부상회복지원금 특별약관 
106
䣪  병실료차액지원금 특별약관 
108
䣫  보행 중 상해 특별약관 
108
䣬  대중교통자동차 탑승 중 사고 특별약관 
110
䣭  주말䞱휴일 교통사고 위로금 특별약관 
111
䣮  성형 및 치아보철 지원금 특별약관 
113
䣯  가족사고 위로금 보장 특별약관 
114
䣰  여성 자기신체사고 안심용품 지원 특별약관 
115
䣱  어린이 교통상해 특별약관 
116
[12]  교통상해 입원 지원금 특별약관 
119
䣧  차량 신차가액 보상담보 특별약관 
121
䣨  차량 전손 시 취득세 비용 담보 특별약관 
122
䣩  차량가액 초과수리비 특별약관 
122
䣪  원격지 차량운반비용 담보 특별약관 
122
䣫  렌트비용 담보 특별약관 
123
   ①  고장수리 시 렌터카 운전담보 추가특별약관 
124
䣬  임시교통비 담보 특별약관 
125
䣭  레저용품 손해 담보 특별약관 
126
䣮  외제차 운반비용 담보 특별약관 
127
䣯  차량단독사고 보장 특별약관 
128
䣰  전기자동차  사고 시 배터리 교체비용 특별약관 
127
䣱  지진손해 보상 특별약관 
129
   ①  지진손해 시 렌트비용 담보 추가특별약관 
129
   ②  지진으로 인한 차량 전손 시 취득세비용 담보 추가특별약관 
130
Ⅱ. 자기신체사고의 보상 확대
Ⅲ. 자기차량손해의 보상 확대
䣧  다른 자동차 운전담보 특별약관 
131
   ①  자녀운전자 담보 추가특별약관 
132
䣨  다른 자동차 차량손해  특별약관 
133
   ①  자녀운전자 담보 추가특별약관 
134
䣩  무보험자동차에 의한 차량손해 특별약관 
135
Ⅳ. 무보험자동차에 의한 손해 관련
Ⅷ. 기타
䣧  유상운송 위험담보 특별약관 
153
䣨  의무보험 일시담보 특별약관 
153
䣩  기계장치에 관한 자기차량손해 특별약관 
154
䣪  시험용 자동차 위험담보 특별약관 
154
䣧  대리운전자 사고 보상 특별약관 
100
䣨  임시운전자 담보 특별약관 
101
2. 운전자 범위 확대 특별약관
8
9
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (7, 1, 7, '䣫  프로미하트(서민우대 보험료 할인) 특별약관 
154
䣬  지정대리청구에 관한 특별약관 
155
䣭  차량용 블랙박스에 관한 특별약관 
156
䣮  교통안전교육 실버우대 특별약관 
157
䣯  외제차 충돌 시 대물 보장확대 특별약관 
158
䣰  일시수입 차량에 관한 특별약관 
159
[11]  대물배상 가입금액 확장담보 특별약관 
159
[12]  Baby in Car(만11세 이하 자녀할인) 특별약관 
159
[13]  보험대차 운전 중 사고보상 특별약관 
160
[14]  차선이탈 경고장치에 관한 특별약관  
161
[15]  품질인증부품 사용 특별약관  
162
[16]  전방충돌 경고장치에 관한 특별약관  
163
[17]  장애인 전용보험 전환 특별약관  
164
[18]  반려동물 교통사고 위로금 특별약관 
165 
특별약관
同 Guide Book은 보험약관의 개념 및 구성 등을 간략하게 소개하고, 소비자 입장에서 
약관 주요내용 등을 쉽게 찾고 이해할 수 있는 방법을 안내하는 것을 목적으로 합니다.
약관을 쉽게 이용할 수 있는
가   이   드   북
Ⅸ. 녹색상품
䣧  Ever Green(전자매체 활용 약관ㆍ증권 발송) 특별약관 
167
䣨  주행거리 후할인 특별약관 
168
䣩  주행거리 선할인 특별약관 
170
䣪  OBD 주행거리 후할인 특별약관 
173
䣫  승용차요일제 특별약관 
175
䣬  친환경부품 사용 특별약관 
177
䣭  이동통신단말장치 활용 안전운전 UBI 특별약관 
178
䣮  전기자동차 특별약관 
179
䣯  주행거리 환급금 갱신 대체납입 특별약관 
180
䣰  커넥티드카 할인 특별약관 
181
䣱  커넥티드카 안전운전 UBI 특별약관 
182
법조문
자동차보험 약관 법조문  
185
10
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (8, 1, 8, '약관을 쉽게 이용할 수 있는
가이드북
약관을 쉽게 이용할 수 있는
가이드북
1. 보험약관이란?
2. 한 눈에 보는 약관의 구성
보험약관은 가입하신 보험계약의 내용 및 조건 등을 미리 정하여 놓은 계약조항으로 보험계약자와 
보험회사의 권리 및 의무를 규정하고 있습니다. 
특히, 청약철회, 계약취소, 보험금 지급 및 지급제한 사항 등 약관의 중요사항에 대한 설명이 들어 
있으니 반드시 확인하셔야 합니다.
약관 이용 가이드북
시각화된 약관 요약서
보험약관
(보통약관 및 특별약관)
약관을 쉽게 잘 이용할 수 있도록 약관의 구성, 쉽게 찾는 방법 
등의 내용을 담고 있는 지침서
약관을 쉽게 이해할 수 있도록 계약 주요내용 및 유의사항 등을 
시각적 방법을 이용하여 간단 요약한 약관
• 보통약관 : 자동차보험의 공통 사항을 정한 기본약관
• 특별약관 : 보통약관에 정한 사항 외 선택 가입한 보장내용  
     등 필요한 사항을 정한 약관
3. QR코드를 통한 편리한 정보 이용
QR(Quick Response) 코드란? 
스마트폰으로 해당 QR 코드를 스캔하면 상세내용 등을 손쉽게 안내받을 수 있습니다.
약관해설 영상
보험금 지급절차
전국 지점
4. 약관의 핵심 체크항목 쉽게 찾기 (보통약관 기준)
보험약관 핵심사항 등과 관련된 해당 조문, 쪽수 및 영상자료 등을 안내드리오니, 보험회사로부터 
약관을 수령한 후, 해당 내용을 반드시 확인䞱숙지하시기 바랍니다.
① 보상하는 손해
※ 본인이 가입한 특약을 
     확인하여 가입특약별 
     보상하는 손해도 
     반드시 확인할 필요
대인배상Ⅰ
대인Ⅱ䞱 대물배상
자기신체사고
무보험자동차에 의한 상해
자기차량손해
p. 39
p. 40
p. 43
p. 45
p. 47
제3조
제6조
제12조
제17조
제21조
② 보상하지 않는 손해
※ 본인이 가입한 특약을 
     확인하여 가입특약별 
     보상하지 않는 손해도 
     반드시 확인할 필요
대인배상Ⅰ
대인Ⅱ䞱 대물배상
자기신체사고
무보험자동차에 의한 상해
자기차량손해
p. 39
p. 40
p. 43
p. 45
p. 47
제5조
제8조
제14조
제19조
제23조
③ 청약 철회
제41조(청약 철회)
p. 57
13
12
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (9, 1, 9, '약관을 쉽게 이용할 수 있는
가이드북
5. 약관을 쉽게 이용할 수 있는 꿀팁
아래 5가지 꿀팁을 활용하시면 약관을 보다 쉽고 편리하게 이용할 수 있습니다.
① 시각화된 ''약관요약서''를 활용하시면 계약 일반사항, 가입시 
 
유의사항, 민원사례 등 약관을 보다 쉽게 이해하실 수 
 
있습니다.
② 약관 내용 중 어려운 보험용어는 용어의 정의, 약관본문 내 
 
용어설명 및 예시 등을 참고하시면 약관 이해에 도움이 
 
됩니다.
③  스마트폰으로 QR코드를 인식하면 약관해설 동영상, 
 
보험금 지급절차, 전국 지점 등을 쉽게 안내 받을 수 
 
있습니다.
④ ''관련법규'' 항목을 활용하시면 약관에서 인용한 법률 조항 
 
및 규정을 자세히 알 수 있습니다.
⑤  약관조항 등이 음영䞱컬러화 되거나 진하게 된 경우 보험금 지급 등 약관 주요 내용이므로 주의 
 
깊게 읽기 바랍니다. 
䨞  약관요약서  p. 12
䨞  제1조(용어의 정의)  p. 35
䨞  QR코드  p. 12
䨞  관련법규  p. 180
6. 기타 문의사항
※ 기타 문의사항은 당사 홈페이지(www.idbins.com), 고객 콜센터(1588-0100)로 문의 가능
※  보험상품 거래단계별 필요한 금융꿀팁 또는 핵심정보 등은 금융감독원 금융소비자정보 포탈
 
(FINE, fine.fss.or.kr)에서 확인 가능
약관을 쉽게 이용할 수 있는
가이드북
④ 계약 전 알릴 의무
⑤ 계약 후 알릴 의무
⑥ 사고발생 시 의무
⑦ 보험계약의 취소
⑧ 보험계약자의 보험계약 
     해지䞱해제
⑨ 보험회사의 보험계약 
     해지
제44조(계약 전 알릴 의무)
제45조(계약 후 알릴 의무)
제46조(사고발생 시 의무)
제50조(보험계약의 취소)
제52조(보험계약자의 보험
            계약 해지䞱해제)
제53조(보험회사의 보험계약 해지)
p. 59
p. 59
p. 59
p. 61
p. 61
p. 62
15
14
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (10, 1, 10, '가입대상
법정승차정원 10인승 이하의 개인소유 자가용승용차
다만, 인가된 자동차학원 또는 자동차학원 대표자 소유의 자동차로서 
운전교습, 도로주행교육 및 시험에 사용되는 승용자동차는 제외
쉽게 이해하는
약관 요약서
이 요약서는 그림, 도표, 삽화 등 시각화된 자료를 바탕으로 자동차보험 상품 및 약관의 핵심내용을 
알기 쉽게 작성한 것입니다. 보다 자세한 사항은 상품설명서 및 약관을 반드시 확인하시기 바랍니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (11, 1, 11, '고객님 사고 시 
이렇게 대처하세요!
1. 즉시 차량을 멈춰주세요!
      아무리 사소한 사고라도 일단 정차 후 사고확인을 꼼꼼히 해주세요.
2. 부상자 구호를 해주세요.
      부상 상태를 확인하고 병원으로 후송해 주세요. 
     (필요 시 응급처치를 하고 119신고를 해주세요.)
3. 사고 정황증거를 확보해주세요.
      사진촬영 및 목격자를 확보해 주세요.(연락처, 명함 등) 
사고차량 위치 등을 도로상에 표시해주세요.(스프레이 등)
4. 교통질서를 회복해 주세요.
     부상자 구호 및 정황증거 등 필요조치를 완료하셨으면 가까운 
     도로 가장자리 등 안전한 곳으로 차량을 옮겨주세요.
5. 경찰서에 신고해 주세요.
     사람이 다쳤을 때는 반드시 신고해 주세요.
1. 사고접수 및 보상담당자 지정
     사고상담 및 안내를 해드리고, 보상서비스 담당자를 지정해드립니다.
    (필요 시 보험가입사실증명원을 발급해 드리며, 제출대행을 해드립니다.)
2. 사고조사 및 피해상황 확인
     피해자 또는 고객님을 만나 사고원인, 과실비율 등을 확인합니다.
     치료과정 및 수리과정을 확인하고 합의금 등 손해액을 산정합니다.
3. 보험금 결정 및 지급
     피해자와 합의하여 치료비, 수리비 등을 지급합니다. 
     (보험금 지급 후 보상처리 사항을 안내해 드립니다.)
필요조치를 다 하셨나요? DB손해보험으로 사고를 통보해 주세요!
보험가입자의 성명, 차량번호, 운전자의 성명
사고일자, 장소, 사고내용 및 손해 사항 입원병원 등을 알려주세요.
1588
 -0100
보험약관 안내문
목차
유의사항
주요 내용 요약
자동차보험 가입을 감사드립니다.
아래 내용을 꼭 확인해 주세요!
계약 시 청약서, 상품설명서 및 보험료 영수증을 받으셨나요? 
다음의 항목을 체크하면서 확인해보세요.
보장내용 및 한도
항 목
청약서, 상품설명서, 보험료 영수증 수령
자동차를 운전할 수 있는 사람의 범위(나이, 가족여부 등)
보상 받을 수 있는 사고(가입하신 보장 내용)
분할보험료 납입 시 납입횟수와 납입기일
보험가입자의 성명, 주소, 연락처
차량번호, 차명, 배기량 및 추가 장착 부속품 기재여부
자필서명 여부
확 인
보험증권을 꼭 
확인하세요!
가입 후 15일이 지나서도 
보험증권을 받지 못하셨다면 
담당 모집인 또는 고객상담센터
1588-0100로 연락주세요. 
바로 재발송 해드리겠습니다!
※ 종이절감으로 환경보호 및 보험료를 할인받는 Ever Green(전자매체 활용 약관ㆍ증권 발송) 특약을 
     가입하셨다면, 증권/약관 등 계약관련 서류는  전자매체(E-mail, 모바일 메시지 등)를 통해 드립니다.
보험기간 중 아래의 내용이 달라질 경우에는 바로 연락주시기 바랍니다.
01 이사를 하셨나요? (주소지 변경)
고객님에게 발송되는 각종 안내문을 위해 주소를 꼭 알려주세요.
02 새 차를 사셨거나, 차량을 바꾸셨나요?
교체(대체)된 새로운 자동차로 계약변경을 완료하셔야 교체된 
자동차의 사고를 보상받을 수 있습니다.
03 운전을 하시는 분의 연령이나, 범위가 달라지셨나요?
운전 가능한 최소운전자의 연령 또는 범위가 달라진 경우에는 운전 가능한 
연령/범위 한정특약으로 변경하셔야 보상 받을 수 있습니다.
04 네비게이션 등 새로운 부속품의 구입
자동차보험은 증권에 기재된 자동차의 가격에 한정하여 자기차량 손해를 
보상합니다. 새로 추가된 부속품 등이 있다면 꼭 확인하세요.
19
18
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (12, 1, 12, '보험 만기 시 
유의하실 사항입니다
보험계약 만기일을 안내해 드립니다
DB손해보험에서는 자동차손해배상보장법 제6조 제1항190쪽)의 규정에 근거하여, 자동차보험(의
무보험 포함)을 가입한 차량의 보험계약이 만기(종료)될 경우 만기일 이전 2회에 걸쳐 고객님에게 
만기 사실을 일반우편 또는 LMS(문자)로 안내해드립니다.
구분
1차 안내
2차 안내
안내 시기
만기일 75일~30일 전
만기일 30일~10일 전
안내 방법
우편 발송 또는 LMS(문자)
우편 발송
안내 내용
만기일자
만기일자
만기일 안내는...
• 보험기간이 2개월 미만의 단기계약은 생략될 수 있습니다. 
• 종이를 절약하여 환경을 보호하는 Ever Green(전자매체 활용 약관䞱증권 발송) 특약을 가입하신 
 
경우 만기안내 역시 전자매체(E-mail, 모바일 메시지 등)로 안내 드립니다.(E-mail 주소를 확인
 
하세요)
※ 따라서, 사고발생 시 우량할인 · 불량할증요율 및 사고건수별 상대도의 적용으로 보험료가 할증될 
 
수 있으며 특히, 물적사고 할증기준금액 이하인 사고로 할인할증 등급의 변동이 없더라도 사고건수
 
별 상대도의 적용으로 보험료가 할증될 수 있습니다. 
의무보험은 반드시 가입하셔야 합니다
의무보험을 가입하지 않으면 과태료가 부과됩니다.
<의무보험이란?>
자동차사고 발생 시 손해배상을 보장하는 제도로 피해자를 보호하기 위하여 의무적으로 가입해야
하는 강제보험을 말합니다.
의무보험을 가입하지 않거나, 보험가입지연 등으로 의무보험 미가입 기간이 발생할 경우, 
고객님은 과태료 처분을 받게 됩니다. 꼭 유의하세요!
① 우량할인 · 불량할증요율 : 사고발생 내용(부상급수 및 물적사고 손해액)에 따라 할증점수를 
 
부과하여 변동되는 요율입니다. 
②  사고건수별 상대도 : 기본보험료의 요소로서 사고발생 내용과 별개로 직전 3년간 사고유무 및 
 
사고건수에 따라 적용하는 요율입니다. (※ 직전 3년간 무사고인 경우 할인 혜택 적용)
구분
대인배상 ,
대물배상
지연기간별 과태료
10일 미가입
1만원
5천원
10일 초과 1일당
4천원
2천원
최고액
60만원
30만원
대인배상Ō
대물배상(2천만원)
+
보험료! 이런 경우에 할증될 수 있습니다
사고발생 시 다음의 요인으로 인해 갱신보험료가 할증될 수 있습니다. 
보험료 할증요소
① 우량할인ㆍ불량할증요율 변동
② 사고건수별 상대도
=
x
21
20
보험료 할증에 대해
유의하실 사항입니다!
보험약관 안내문
목차
유의사항
주요 내용 요약
21
보험료 50만원을 납입하던 고객이 직전 3년간 무사고였다가 지급보험금 100만원의 물
적사고 발생 시 할증은 다음과 같습니다. (사고건수별 상대도로 인한 할인적용 10%로 
가정함)
1) 물적사고 할증기준금액 200만원 가입한 경우, 사고건수별 상대도만 변경 적용됨
2) 물적사고 할증기준금액 50만원 가입한 경우, 사고건수별 상대도와 우량할인 䞱 불량
 
할증요율도 모두 변경 적용됨
보험료 할증 예시
물적사고 할증기준금액별
1) 200만원
변동없음
    - 직전 3년 무사고 할인 혜택 미적용 :  +10%
    - 사고건수 상대도로 인한 할증 적용 : +10%*
약 60.5만원
우량할인ㆍ불량할증요율
사고건수별 상대도
우량할인ㆍ불량할증요율
* 실제 적용할증율은 등급과 계층에 따라 개인별로 상이합니다
2) 50만원
+ 5%*
약 63.5만원
구      분
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (13, 1, 13, '주요 보장종목을 
확인하세요!
자동차보험은 보통약관의 기본보장 내용과 고객님이 선택 가입하는 
특별약관으로 구성되어 있습니다. 
상대방이 다쳤을 때
고객님이 다쳤을 때
무보험 차량에 의해
다쳤을 때
타인에 대한
배상
고객님의
보상
사람이
다친경우
차량이나 
물건의 손해
상대방 차량등의 손해
고객님의 차량 손해
대인배상 ,
대인배상 ,,
자기신체사고
운전자 한정운전 특별약관
자기차량손해 확장 특별약관
자기신체사고 확장 특별약관
기타(주행거리 특별약관 등)
무보험자동차에 의한 상해
대물배상
자기차량손해
보
통
약
관
특
별
약
관
※ 특별약관은 보통약관에서 정하는 기본적인 보상내용 등을 보충, 변경, 제한 또는 추가하는 것으
로서 선택하여 가입할 수 있습니다.(단, 일부 특별약관은 가입 시 자동적용 될 수 있습니다.)
23
보험약관 안내문
목차
유의사항
주요 내용 요약
23
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (14, 1, 14, '상대방이 다쳤을 때
대인배상 ,,,
자동차손해배상보장법에 의해 자동차소유자라면 누구나 가입해야 하는 
법적 의무(강제) 보험입니다.
보험가입 시 정한 금액(예 : 무한)을 한도로 “대인배상Ō”을 초과하는 손해를 보상하여 드립니다. 
(반드시, 대인배상Ō과 같이 가입해야 합니다.) 
※ 보장 내용은 위 대인배상Ō과 같습니다.
자동차사고로 다른 사람을 다치게 하거나 죽게한 경우, 
고객님이 법률상 손해배상책임을 짐으로써 입은 손해를 보상하여 드립니다.
대인배상 , 과 대인배상ō로 나뉩니다.
대인배상,
대인배상ō
법률비용지원금
특별약관
중과실 사고 사망/사고 등 자동차 사고시 발생하는 
형사적 책임에 대하여 실제비용을 보장해 드립니다.
▶  형사합의금 / 변호사선임비용 / 벌금
선택 특약으로 더 나은 보장을 경험하세요!
보험약관 안내문
목차
유의사항
주요 내용 요약
구분
보장내용 및 지급한도
사망
부상
후유장애
보장 내용
지급한도
사망자 1인당 실제손해액
(장례비, 위자료, 상실수익액) 지급
부상등급별 실제손해액
(치료비, 위자료, 휴업손해) 지급
장애등급별 실제손해액
(위자료, 상실수익액, 간호비)지급 
최대 1억 5천만원 ~ 최저 2천만원
1급(3천만원) ~ 14급(50만원) 
1급(1억 5천만원) ~ 14급(1천만원) 
39~43p
136~139p
상대방 차량이 부서졌을 때
대물배상
자동차사고로 다른 사람의 차량 및 재물에 손해가 생긴 경우, 
법률상 손해배상책임을 짐으로써 입은 손해를 보상해 드립니다.
외제차 충돌 시 
대물보장 확대
특별약관
고액대물사고 위험의 대부분을 차지하는 외제차와의 
충돌 위험에 대해서 대물배상 가입금액을 확대하여
드립니다. 합리적인 보험료로 충분한 위험보장이 
가능합니다.
▶ 대물가입금액 2억/3억/5억/7억에서 가입가능
     • 외제차 사고시 대물가입금액 최대 10억까지 확대
외제차량과의 충돌 위험을 현명하게 대비하는 방법!
선택 특약으로 더 나은 보장을 경험하세요!
40~43p
157~158p
보험가입금액은 2 / 3 / 5 / 7천만원 또는 1 / 2 / 3 / 5 / 7 / 10억원 중 선택 가능합니다.
대물배상은 자동차손해배상보장법에 따라 2천만원까지는 의무보험 입니다.
가입금액
구분
보장내용 및 지급한도
대물배상
보장 내용
지급한도
수리비용, 교환가액, 렌트비(대차료), 휴차료 
영업손실, 자동차시세하락손해(격락손해)를 
보상
1사고당 가입금액 한도
※ 수리비,  교환가액 등 지급기준 확인 
74p
25
24
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (15, 1, 15, '고객님이 상해를 입은 경우
자기신체사고
그 밖의 자기신체사고 확장 고보장 특별약관을 확인하세요.
가입하신 자동차의 사고로 고객님 또는 고객님의 가족이 상해를 입은 경우 
그로 인한 손해를 보상하여 드립니다.
자기신체사고는 상대방이 없는 단독사고(공제액 없음) 인지 또는 상대방이 있는
쌍방사고(공제액 존재) 인지에 따라 보장내용이 달라집니다.
구분
사고 유형별 보장내용 및 지급한도
단독
사고
쌍방
사고
보장 내용
지급한도
사망 : 보험증권에 기재된 가입금액 정액 지급 
부상 : 상해급수(1~14급)한도 내 실제치료비 
장애 : 장애급수(1~14급)별 가입금액 정액 지급
사망은 가입금액한도, 부상후유장애는 급별 가입금액 
한도 내 실제손해액에서 공제액(상대방 대인배상으로 
받을 수 있는 금액 등)제외 후 지급
1인당 한도적용
Family 통합보장
특별약관
고객님은 물론, 고객님의 부모님, 배우자, 자녀, 배우자의 부모님의 
교통상해 사고 시 실제 손해 기준으로 폭넓게 보장합니다.
주) 실제손해액은 약관상 “대인배상 지급기준” 등에 의하여 산출된 금액을 말합니다.
구분
고객님車 사고타차량 탑승중 사고보행중 사고
보장강화
(Family)
○
○
○
자기신체
사고
○
X
X
선택 특약으로 더 나은 보장을 경험하세요!
보험약관 안내문
목차
유의사항
주요 내용 요약
43~45p
102~105p
105~120p
고객님 차량에 손해가 
생긴 경우 자기차량손해
자동차 사고로 가입하신 자동차에 직접손해가 발생한 경우, 
그 손해를 보상하여 드립니다.
보장내용
•타차량 또는 타물체와의 충돌, 접촉, 침수, 화재, 폭발 등으로 인한 손해
•가입하신 자동차의 전부도난(부분도난 제외)으로 인한 손해
보험금 지급
고객님의 차량에 생긴 직접손해액에서 고객님이 부담하실 자기부담금을 공제한 금액을 약관상 
한도 내에서 보험금으로 지급해 드립니다.
고객님이 부담하실 금액 (자기부담금)
손해액의 20%를 부담(단, 최저~최고 한도 내에서 납부)
<예시> 물적사고할증기준 200만원, 자기차량손해액의 20% 가입시 
              최저/최고부담금 한도 : 20만원 ~ 50만원
가입 자동차에 생긴 손해액
-
=
고객님이 부담하실 금액
보험금
손해액
손해액의 20%
최저/최고 한도 해당 여부
최종 자기부담금
100만원
500만원
100만 X 20% = 20만원
500만 X 20% = 100만원
20만원~50만원 사이에 위치
50만원보다 큼
50만원(최고한도)
20만원
사고 시 교통비, 렌트비 등을 지원해주고, 차량전손 시 신규 차량 구입비용을 보상해주는 
등 유용한 자기차량손해 확장 고보장 특별약관을 확인하세요.
선택 특약으로 더 나은 보장을 경험하세요!
47~49p
120~129p
27
26
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (16, 1, 16, '고객님이 무보험자동차나 뺑소니 차량에 의해 상해를 입은 경우에 그 손해를 
보상하여 드립니다.(차량 탑승 여부와 무관함)
가해차량이 무보험인 경우
무보험자동차에 의한 상해
보장내용 및 한도
•가입금액(한도)은 2억/5억 中 선택하여 가입할 수 있습니다.
•사망/부상/후유장애에 대하여 배상의무자(가해자)의 과실에 해당하는 금액을 대인배상 
    지급기준에 따라 보상합니다.
무보험자동차란?
다른자동차 
운전 담보 
특별약관
다른자동차 운전 중 사고발생 시 대인, 대물, 자손에 대하여 
보통약관에 따라 보상하여 드리는 특약입니다.(차량손해 제외)
<다른자동차 운전이 가능한 사람(피보험자)>
① 기명피보험자        ② 기명피보험자의 배우자
③ 지정 1인(지정1인 한정운전 특약 가입 시)
다른자동차 운전담보 특별약관은 무보험자동차에 의한 상해 담보 가입 시 
자동가입 됩니다.
만약, 운전하던 해당 다른자동차의 차량손해를 보장 받고 싶으시다면, 
다른자동차 차량손해 특별약관을 선택, 가입하시기 바랍니다.
다른자동차를 운전하시는 경우에는?
보험약관 안내문
목차
유의사항
주요 내용 요약
자동차 보험이 없거나
뺑소니(사고 후 도주)차량인 경우 등
※ 무보험자동차의 정의  ☞
45~47p
35p
130~132p
132~134p
이런 경우 보험금이 
지급되지 않습니다
자동차보험은 각 보장종목 또는 특별약관별로 보상하지 않는 
손해를 규정하고 있습니다. 아래에서 공통적으로 보상하지 않는 주요 내용을 
확인하시기 바랍니다. (보다 자세한 내용은 약관을 꼭 참고하세요.)
※  위 내용은 보상하지 않는 손해의 공통사항으로서 담보 별 보상하지 않는 손해의 내용은 반드시 약관의 해당 
      부분을 참고하시기 바랍니다 .
1. 운전가능자가 아닌 경우
• 증권에 기재된 운전가능 연령/범위에 해당하지 않는 사람이 운전한 
경우, 보장되지 않습니다.
   (단, 법률상 강제 되는  대인배상Ō은 보상됨)
2. 고의로 사고를 일으킨 경우
3. 자동차를 이용한 영업행위(유상운송)
• 돈을 받고 승객을 태우거나, 물건을 실어다 주는 행위 또는 돈을 받고 
차량을 빌려주는 등의 영업행위 중 사고는 보상되지 않습니다.
   (실제 출䞱퇴근을 목적으로 출䞱퇴근 시간대(오전7시~9 시 및 
오후 6시~8시)에 카풀(승용차 함께 타기)운행 중 사고가 발생한 경우
에는 돈을 받고 승객을 태운 경우에도 보상이 가능합니다.)
4. 시험용 또는 경기용 운행
• 자동차를 시험용으로 운행하거나, 경기용으로  사용하는 
경우 보상되지 않습니다.
5. 음주/무면허/마약ㆍ약물운전, 사고발생 시의 조치의무 
     위반 행위
• 대인/대물의 경우 약관에서 정한 바에 따른 사고부담금을 
납입하면 보상 가능합니다.(사고부담금 확인  ☞                        )
43p
29
28
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (17, 1, 17, '긴급출동서비스 안내
자동차보험 대표 브랜드 프로미카의 신속한 긴급출동서비스를 통해, 
긴급상황 시 안전운행 하세요!
긴급견인
비상급유
잠금해제
배터리충전
타이어교체
펑크수리
브레이크
파워오일
휴즈교환
긴급구난
부동액보충
※ 유의사항
• 긴급출동서비스는 보험기간 1년을 기준으로 총 6회 사용 가능합니다. 
(단, 보험기간이 1년 보다 작은 경우 3회만 가능합니다.)
• 긴급출동, 비상급유 등 약관에 따른 사용한도에 제한이 있는 경우에는 초과 시 고객님의 
부담금이 발생합니다.  
예)긴급견인 10km 초과시 1km 당 부담금 발생 / 비상급유 무상지급(2회) 초과시 주유실비 부담금 발생
• 긴급출동서비스는 서비스 제공시점 자동차의 상태(화물 등) 또는 사고발생지역(섬 또는 
산간 등)에 따라 서비스 제공이 불가능할 수 있습니다. 
프로미카
오토케어 
서비스
오토케어(AutoCare) 서비스
① 차량점검     ② 차량 실내 살균/탈취     ③ 수리차량 운반 
④ 차량등록대행 예약      ⑤ 차량검사대행 예약
10가지 SOS 긴급출동서비스는 물론, 차량관리에 필요한 5가지 
오토케어 서비스를 제공하는 고보장 서비스 상품
차량관리를 원하신다면! 오토케어서비스
보험약관 안내문
목차
유의사항
주요 내용 요약
140~149p
142~146p
1일
1회한
운전가능자에 따라 
보험료가 달라집니다. 
가입하신 자동차를 운전할 수 있는 사람을 꼭 확인하세요. 
운전가능 연령/ 범위에 따라서 보험료가 할인되거나 늘어날 수 있습니다.
※ 단, 운전가능자 이외의 사람이 운전할 경우 대인배상Ⅰ을 제외한 담보는 보상받을 수 없으므로 유의하세요.
운전자범위한정 특약별 운전가능자
•고객님이 가입한 운전자범위한정 특약에 따라 운전가능자가 달라집니다.
운전자연령한정 특약별 운전가능자
•나이를 지정하여 그 이상만 운전하도록 약정하면 보험료 할인이 가능합니다.
○
X
○
○
본인
운전자
특약
기명피보험자 1인
기명1인 + 지정1인
부부
부부 + 지정1인
가족
가족 + 형제자매
가족 + 지정1인
지정 1인
누구나운전
○
○
○
○
○
○
○
○
○
○
○
○
○
○
○
○
○
○
○
○
○
○
○
X
X
X
X
X
X
X
X
X
X
X
X
X
X
X
X
X
X
X
X
X
X
X
배우자
배우자부모
형제/자매
지정1인
부모/자녀
(며느리•사위)
○
○
○
X
내가 운전시 
만 26세 
이상
동생 운전시 
만 22세 
이상
부모님이 운전시 
만 48세 
이상
27세
23세
50세49세
31
30
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (18, 1, 18, '자주 묻는 질문을 
확인하세요!
보험약관 안내문
목차
유의사항
주요 내용 요약
약관을 읽기 전 
주요 보험용어를 확인하세요!
자동차보험에 대해서 자주 묻는 질문을 통해 궁금한 사항을 알아봅니다. 
보다 자세한 내용은 약관을 참고하시거나 담당자에게 문의하시기 바랍니다.
용    어
계부모, 계자녀
공제(共濟)계약
기명피보험자
납입최고
보통약관
보험가액
보험가입금액 
보험료, 보험금
사실혼
상해등급
양부모, 양자녀
정부보장사업
정차, 주차
자기부담금
특별약관
후유장애 등급
 내          용
계부(어머니가 재혼하여 생긴 아버지)와 계모(아버지가 재혼하여 생긴 어머니) 
계자녀(재혼한 경우, 배우자가 재혼을 하면서 데리고 온 자녀)
공제조합이 각자 조합원으로부터 받은 출자금을 자본으로 조합원의 자동차사고 시에 
공제금을 지급하여 돕는 공제사업에 의한 계약을 말합니다. (예 : 전국개인택시공제조합)
보험가입자동차의 소유, 사용, 관리 책임이 있는 사람으로서 보험증권에 기재된 사람
보험계약자 등에게 미납보험료를 낼 것을 독촉하는 법률상 통지
자동차보험의 주요 담보에 대한 보장내용과 보험계약의 성립부터 소멸까지의 보험계약의 
일반사항 등을 정한 내용
가. 보험계약을 체결하는 경우 보험계약 체결 당시 보험개발원이 정한 최근의 자동차보험 
차량기준가액표(적용요령 포함)에 정한 가액을 말합니다.
나. 보험계약 체결 후 사고가 발생한 경우 보험사고 발생 당시 보험개발원이 정한 최근의 
자동차보험 차량기준가액표(적용요령 포함)에 정한 가액을 말합니다.
보험금을 지급하는 사고가 발생한 경우, 보험회사가 지급하는 보험금의 한도액(보상한도액)
보험료 : 보험계약 내용에 따라 계약자가 납입하는 금액
보험금 : 보험회사가 피보험자 또는 보험금청구권자에게 지급하는 약관상 보상액
혼인신고를 하지 않았기 때문에 법률상의 부부는 아니지만, 사실상 부부의 관계에 있는 상태
자동차손해배상보장법 시행령 별표1에서 정한 상해의 구분과 보험금 등을 정한 등급
양부모,양자녀 : 입양에 의해 부모 또는 자녀의 자격을 얻은사람
자동차손해배상보장법에 따라 정부에서 보유불명(뺑소니) 자동차 또는 무보험자동차로 
인해 사고를 당한 피해자를 보호하기 위해 운영하는 사회보장제도
정차 : 차가 5분을 초과하지 않고 정지하는 것으로서 주차 외의 정지상태 
주차 : 차가 계속 정지하여 있거나 운전자가 그 차로부터 떠나서 즉시 운전할 수 없는 상태
보험금 지급 시, 피보험자가 부담하는 일정 금액
자동차보험 가입 시 선택하여 가입함으로써 보통약관에서 보장하는 내용에 추가로 보상 
또는 비용, 서비스 등을 제공받을 수 있는 내용(보장의 축소, 제한 등의 특별약관도 있음)
자동차손해배상보장법 시행령 별표 2에서 정한 후유장애의 구분과 보험금 등을 정한 등급
1. 무면허 또는 음주운전, 마약ㆍ약물운전, 사고발생 시의 조치의무 위반 
시 보상 가능한가요?
단, 대인Ⅰ은 한도 내 지급보험금 전액, 대인Ⅱ 1억원, 대물 의무보험 지급보험금 전액, 대
물 의무보험초과 5천만원의 사고부담금을 고객님이 부담하셔야 합니다.
2. 운전자 연령/범위를 위반할 경우 보상이 안되나요?
운전자 한정특약에 따라 정한 연령 및 범위 이외의 사람이 운전할 경우 보상되지 않습니다. 
다만, 대인배상 , 은 운전자 한정특약에도 불구하고 보상 가능하니 참고하시기 바랍니다.
3. 상해급수란 무엇인가요?
자동차 사고 시 상해정도에 따라 자동차손해배상보장법 시행령에서 정한 상해급수가 책정
됩니다. 자기신체사고의 치료비 보상한도 등을 정할 때 해당급수를 활용하게 됩니다.
4. 렌터카의 자기차량손해도 보상이 가능한가요?
다른자동차 차량손해 특별약관을 가입하신 경우에는 렌터카의 차량손해도 보상이 가능합
니다. 단, 대여하신 렌터카가 7일 이하인 경우에만 보상이 가능하다는 사실 꼭 확인하세요!
5. 가입 시 차량가액은 어떻게 적용되나요?
보험개발원에서 분기마다 정하는 차량기준가액표에 따라 적용하게 됩니다. 사고 시 자기
차량손해의 차량가격(보험가액)은 사고시점 기준 최근의 차량기준가액표에 따라 결정되
는 것도 알아두세요!
구         분
무  면  허
○
○
○
○
X
○
○
○
○
○
○
○
○
○
○
○
○
○
X
○
X
○
○
○
음        주
사고발생 시의 조치의무 위반
마약ㆍ약물운전 
대인
배상Ō
대인
배상ō
대물
배상
자기신체
사고
자기차량
손해
무보험
상해
33
32
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (19, 1, 19, '보통약관 본문에 등장하는 항목체계의 표기법과 읽는 법을 참고하세요!
피보험자동차를 소유, 사용 관리하는 동안에 생긴 사고에 대한
구체적인 보상내용 및 자동차보험 계약의 성립에서
소멸까지 보험계약자와 보험회사간의 권리와 의무사항이
명시되어 있는 자동차보험 약관의 본문 내용입니다.
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
제1조 (용어의 정의) 
이 약관에서 사용하는 용어의 뜻은 다음과 같습니다.
제1편 용어의 정의 및 프로미카 개인용자동차보험의 구성
01) “요율(料率)”은 “요금의 정도나 비율”을 나타내는 것으로서 보험료 계산 시 가입조건에 따라 적용되는 보험료 수준 등을 
   말합니다.  
02) “향정신성의약품”에 대한 해석은 “마약류관리에 관한 법률”에서 규정하고 있는 내용을 따릅니다. (법령 참고 → 184쪽) 
03) “대인배상Ⅱ나 공제계약 없이 대인배상Ⅰ만 가입한 자동차”도 무보험자동차에 의한 상해 담보에서는 무보험자동차에 
   해당합니다.
   “공제계약”이란 공제조합이 각자 조합원으로부터 받은 출자금을 자본으로 조합원의 자동차사고 시에 공제금을 지급하
   여 돕는 “공제사업”에 의한 계약을 말합니다. 
   <예시> 개인택시의 경우 “전국개인택시공제조합”에 의한 공제계약
 1. 가지급금
 3. 마약 또는 
   약물 등
 4.  무면허운전
   (조종)
 5.  무보험자동차
 2.  단기요율지식01)
자동차사고로 인해 소요되는 비용을 충당하기 위하여, 보험회사가 피보험자에 대한 보상책
임이나 피해자에 대한 손해배상책임을 확정하기 전에 그 비용의 일부를 피보험자 또는 피
해자에게 미리 지급하는 것을 말합니다.
도로교통법 제45조183쪽)에서 정한 ‘마약, 대마, 향정신성의약품지식02), 그 밖의 행정자치부
령이 정하는 것’을 말합니다.
도로교통법 또는 건설기계관리법의 운전(조종)면허에 관한 규정을 위반하는 무면허 또는 
무자격운전(조종)을 말하며, 운전(조종)면허의 효력이 정지된 상황이거나 운전(조종)이 
금지된 상황에서 운전(조종)하는 것을 포함합니다.
무보험자동차 : 피보험자동차가 아니면서 피보험자를 죽게 하거나 다치게 한 자동차로서 
다음 중 어느 하나에 해당하는 것을 말합니다. 이 경우 자동차란 자동차관리법에 의한 자동
차, 건설기계관리법에 의한 건설기계, 군수품관리법에 의한 차량, 도로교통법에 의한 원동
기장치자전거 및 개인형이동장치, 농업기계화촉진법에 의한 농업기계를 말하며, 피보험자
가 소유한 자동차를 제외합니다.
 가. 자동차보험 대인배상Ⅱ나 공제계약이 없는 자동차 지식03)
 나. 자동차보험 대인배상Ⅱ나 공제계약에서 보상하지 않는 경우에 해당하는 자동차
 다. 이 약관에서 보상될 수 있는 금액보다 보상한도가 낮은 자동차보험의 대인배상Ⅱ나 
   공제계약이 적용되는 자동차. 다만, 피보험자를 죽게 하거나 다치게 한 자동차가 2대 
   이상이고 각각의 자동차에 적용되는 자동차보험의 대인배상Ⅱ 또는 공제계약에서 보
   상되는 금액의 합계액이 이 약관에서 보상될 수 있는 금액보다 낮은 경우에 해당하는 
   그 각각의 자동차
 라. 피보험자를 죽게 하거나 다치게 한 자동차가 명확히 밝혀지지 않은 경우 그 자동차
   (「도로교통법」에 의한 개인형이동장치는 제외)
보험기간이 1년 미만인 보험계약에 적용되는 보험요율을 말합니다.
용    어
용  어  의     정  의
 6.  부분품, 
   부속품, 
   부속기계장치
 가. 부분품 : 엔진, 변속기(트랜스미션) 등 자동차가 공장에서 출고될 때 원형 그대로 부
   착되어 자동차의 조성부분이 되는 재료를 말합니다.
 나. 부속품 : 자동차에 정착(*1) 또는 장비(*2)되어 있는 물품을 말하며, 자동차 실내에서만 
   사용하는 것을 목적으로 해서 자동차에 고정되어 있는 내비게이션이나 고속도로통행
   료단말기(*3)를 포함합니다. 다만 다음의 물품을 제외합니다.
35
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (20, 1, 20, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
(*1) 정착 : 
   볼트, 너트 등으로 고정되어 있어서 공구 등을 사용하지 않으면 쉽게 분리할 수 
   없는 상태
(*2) 장비 :  
   자동차의 기능을 충분히 발휘하기 위해 갖추어 두고 있는 상태 또는 법령에 따
   라 자동차에 갖추어 두고 있는 상태
(*3) 고속도로통행료단말기 : 
   고속도로 통행료 등의 지급을 위해 고속도로 요금소와 통행료 등에 관한 정보
   를 주고받는 송수신장치(예 : 하이패스 단말기)
 6.  부분품, 
   부속품, 
   부속기계장치
 7.  운전(조종)지식05) 
  (1) 연료, 보디커버, 세차용품
  (2) 법령지식04)에 의해 자동차에 정착하거나 장비하는 것이 금지되어 있는 물건
  (3) 통상 장식품으로 보는 물건
  (4) 부속기계장치
 다. 부속기계장치 : 의료방역차, 검사측정차, 전원차, 방송중계차 등 자동차등록증상 그 
   용도가 특정한 자동차에 정착되거나 장비되어 있는 정밀기계장치를 말합니다.
도로교통법상 도로(도로교통법 제44조䞱제45조䞱제54조 제1항䞱제148조 및 제148조의
2183쪽)의 경우에는 도로 외의 곳을 포함)에서 자동차 또는 건설기계를 그 본래의 사용방법
에 따라 사용하는 것을 말합니다.
 8.  운행 
 9.  음주운전(조종)
사람 또는 물건의 운송 여부와 관계없이지식06) 자동차를 그 용법에 따라 사용하거나 관리하
는 것을 말합니다.(자동차손해배상보장법 제2조 제2호190쪽))
도로교통법에 정한 술에 취한 상태에서 운전(조종)하거나 음주측정에 불응하는 행위를 말
합니다.
 10. 의무보험
자동차손해배상보장법 제5조190쪽)에 따라 자동차보유자가 의무적으로 가입하는 보험을 말
합니다. 
용    어
용  어  의     정  의
 16. 휴대품, 
   인명보호장구 
   및 소지품
   지식11)
 가. 휴대품 : 통상적으로 몸에 지니고 있는 물품으로 현금, 유가증권, 만년필, 소모품, 손
   목시계, 귀금속, 장신구, 그 밖에 이와 유사한 물품을 말합니다.
 나.  인명보호장구 : 외부충격으로부터 탑승자의 신체를 보호하는 특수기능이 포함된 것
   으로 「도로교통법 시행규칙」 제32조에서 정하는 승차용 안전모 또는 전용의류(*1)를 
   말합니다.
 다. 소지품 : 휴대품을 제외한 물품으로 정착(*2)되어 있지 않고 휴대할 수 있는 물품을 말
   합니다.(*3)
 12.  자동차 
   취급업자 
 13.  피보험자 
 14. 피보험자동차
 15. 피보험자의 
   부모, 배우자, 
   자녀
자동차정비업, 대리운전업, 주차장업, 급유업, 세차업, 자동차판매업, 자동차탁송업 등 자
동차를 취급하는 것을 업으로 하는 자(이들의 피용자지식07) 및 이들이 법인인 경우에는 그 
이사와 감사를 포함)를 말합니다.
보험회사에 보상을 청구할 수 있는 자로서 다음 중 어느 하나에 해당하는 자를 말하며, 구체
적인 피보험자의 범위는 각각의 보장종목에서 정하는 바에 따릅니다.
 가. 기명피보험자 : 피보험자동차를 소유ㆍ사용ㆍ관리하는 자 중에서 보험계약자가 지정
   하여 보험증권의 기명피보험자란에 기재되어 있는 피보험자를 말합니다.
 나. 친족피보험자 : 기명피보험자와 같이 살거나 살림을 같이 하는 친족지식08)으로서 피보
   험자동차를 사용하거나 관리하고 있는 자를 말합니다.
 다. 승낙피보험자 : 기명피보험자의 승낙을 받아 피보험자동차를 사용하거나 관리하고 있
   는 자를 말합니다.
 라. 사용피보험자 : 기명피보험자의 사용자 또는 계약에 따라 기명피보험자의 사용자에 
   준하는 지위를 얻은 자. 다만, 기명피보험자가 피보험자동차를 사용자지식09)의 업무에 
   사용하고 있는 때에 한정합니다.
 마. 운전피보험자 : 다른 피보험자(기명피보험자, 친족피보험자, 승낙피보험자, 사용피보
   험자를 말함)를 위하여 피보험자동차를 운전 중인 자(운전보조자지식10)를 포함)를 말
   합니다.
보험증권에 기재된 자동차를 말합니다.
 가. 피보험자의 부모 : 피보험자의 부모, 양부모를 말합니다.
 나. 피보험자의 배우자 : 법률상의 배우자 또는 사실혼관계에 있는 배우자를 말합니다. 
 다. 피보험자의 자녀 : 법률상의 혼인관계에서 출생한 자녀, 사실혼관계에서 출생한 자녀, 
   양자 또는 양녀를 말합니다.
 11. 자동차보유자  
자동차의 소유자나 자동차를 사용할 권리가 있는 자로서 자기를 위하여 자동차를 운행하는 
자를 말합니다(자동차손해배상보장법 제2조 제3호190쪽))
용    어
용  어  의     정  의
04) ‘법령에 의해 자동차에 정착하거나 장비하는 것이 금지되어 있는 물건’에서 ‘법령’이란 자동차관리법 제3장 제29조를 말
   하며, ‘금지되어 있는 물건’이란 자동차운행에 있어 본인 및 다른 차량의 운행에 지장을 주는 것으로 예를 들어 기준밝기
   를 초과한 램프등, 번호판 가림장치 등을 말합니다. 
05) “운전”은 도로교통법상 도로로 정의되는 공간에서 차마(차량)을 그 본래의 사용방법에 따라 사용하는 것(조종을 포함)
   을 말하는 것이며, “운행”은 자동차손해배상법에서 정의되는 행위로 장소와 관계없이 자동차를 그 용법에 따라 사용, 관
   리하는 것을 말합니다. 운행은 운전보다 넓은 개념에 해당합니다.
06) 자동차에 사람이 탑승하거나 혹은 물건을 싣고 가지 않더라도 자동차의 용법에 따라 사용하거나 관리하는 것은 약관에서 
   “운행”으로 보고 있습니다. 
07) “피용자(被傭者)”란  직업의 종류와 관계없이 사업이나 사업장에 노동력 등을 제공하는 사람을 말합니다. 단, 사용자와 
   피용자의 관계는 “유효한 고용관계”에 국한되는 것이 아니라 사실상 어떤 사람이 다른 사람을 위하여 그 지휘, 감독 아래 
   그 의사에 따라 사업을 집행하는 관계에 있을 때에도 성립될 수 있습니다. 
08) 통상 “같이 산다”는 것은 동일 가옥에 거주하고 있는 것을 말합니다. 또한 “살림을 같이 한다”는 것은 생계를 같이 하거나 
   혹은 부양관계에 있는 것을 의미합니다. “친족”은 민법에서 규정한 바에 따라 8촌 이내의 혈족(자기와 혈연으로 이어진 
   자. 즉, 부모, 형제 등), 4촌 이내의 인척(혈족의 배우자, 배우자의 혈족 등)을 말합니다. 
09) “사용자”란 통상의 사업주 또는 사업경영 담당자 등을 말합니다. 
10) “운전보조자”란 업무로서 운전자의 운전행위에 참여하여 그 지배 하에서 운전행위를 도와주는 자로서, 통상 조수나 차장 
   등이 이에 속합니다. 업무와 관련 없는 선의의 보조행위(예 : 길 가던 행인의 선의의 보조행위 등)는 이에 속하지 않습니
   다. 
11) 약관에서 정의하는 “휴대품”은 “통상 몸에 착용하거나 지니는 물품” 중에서 위 ‘가. 휴대품’에서 열거하여 명시한 물품만
   을 말합니다. 따라서, 해당 규정에 따르는 “휴대품”을 제외한 휴대가능한 물품은 약관에서 열거한 바에 따라 “소지품”으
   로 규정됩니다.
(*1) 예 : 바이크 전용 슈트, 에어백 등(라이더자켓ㆍ팬츠ㆍ부츠 등 이와 유사한 일반
   의류는 제외)
(*2) ‘정착’ : 볼트, 너트 등으로 고정되어 있어서 공구 등을 사용하지 않으면 쉽게 분
   리할 수 없는 상태
37
36
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (21, 1, 21, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
④ 자동차보험료는 보험회사가 금융감독원에 신고한 후 사용하는 ‘자동차보험요율서’에서 정한 방법에 의하여 계
  산합니다.
다. 대물배상
자동차사고로 다른 사람의 재물을 없애거나 훼손한 경우에 보상
보장종목
보상하는 내용
가. 대인배상Ⅰ
나. 대인배상Ⅱ
자동차사고로 다른 사람을 죽게 하거나 다치게 한 경우에 자동차손해배상보장법에
서 정한 한도지식12)에서 보상
자동차사고로 다른 사람을 죽게 하거나 다치게 한 경우, 그 손해가 대인배상Ⅰ에서 
지급하는 금액을 초과하는 경우에 그 초과손해를 보상
 2. 배상책임 이외의 보장종목 : 자동차사고로 인하여 피보험자가 입은 손해를 보상
보장종목
보상하는 내용
가. 자기신체사고
나. 무보험자동차에 
  의한 상해
피보험자가 상해를 입은 경우에 보상
무보험자동차에 의해 피보험자가 상해를 입은 경우에 보상
보장종목
보상하는 내용
다. 자기차량손해
피보험자동차에 생긴 손해를 보상
12) 자동차손해배상보장법 시행령 제3조에서 정하는 금액을 말합니다. (법령 세부내용 참고 ⇨ 192쪽)
제2조 (프로미카 개인용 자동차보험의 구성) 
① 보험회사가 판매하는 프로미카 개인용자동차보험은 대인배상Ⅰ, 대인배상Ⅱ, 대물배상, 자기신체사고, 무보험
  자동차에 의한 상해, 자기차량손해의 6가지 보장종목과 특별약관으로 구성되어 있습니다.
② 보험계약자는 다음과 같은 방법에 따라 자동차보험에 가입합니다.
 1. 의무보험 : 자동차손해배상보장법 제5조190쪽)에 따라 보험에 가입할 의무가 있는 자동차보유자는 대인배상Ⅰ
   과 대물배상(자동차손해배상보장법에서 정한 보상한도에 한정함)을 반드시 가입해야 합니다.
 2.  임의보험 : 의무보험에 가입하는 보험계약자는 의무보험에 해당하지 않는 보장종목을 선택하여 가입할 수 있
   습니다.
③  각 보장종목별 보상 내용은 다음과 같으며 상세한 내용은 제2편 프로미카 개인용 자동차보험에서 보상하는 내
  용에 규정되어 있습니다.
 1.  배상책임 : 자동차사고로 인하여 피보험자가 손해배상책임을 짐으로써 입은 손해를 보상
제1절 대인배상Ⅰ
제2편 프로미카 개인용 자동차보험에서 보상하는 내용
제3조 (보상하는 손해) 
대인배상Ⅰ에서 보험회사는 피보험자가 피보험자동차의 운행으로 인하여 다른 사람을 죽거나 다치게 하여 자동차
손해배상보장법 제3조190쪽)에 의한 손해배상책임을 짐으로써 입은 손해를 보상합니다. 
제4조 (피보험자) 
대인배상Ⅰ에서 피보험자란 다음 중 어느 하나에 해당하는 자를 말하며, 다음에서 정하는 자 외에도 자동차손해배
상보장법상 자동차보유자에 해당하는 자가 있는 경우에는 그 자를 대인배상Ⅰ의 피보험자로 봅니다.
 1.  기명피보험자
제1장 배상책임
 19. 보험가액 
 20. 마약ㆍ약물운전
 18.  사고발생 시의 
   조치의무 위반 
가. 보험계약을 체결하는 경우 보험계약 체결 당시 보험개발원이 정한 최근의 자동차보험 
  차량기준가액표(적용요령 포함)에 정한 가액을 말합니다.
나. 보험계약 체결 후 사고가 발생한 경우 보험사고 발생 당시 보험개발원이 정한 최근의 자
  동차보험 차량기준가액표(적용요령 포함)에 정한 가액을 말합니다.
마약 또는 약물 등의 영향으로 인하여 정상적인 운전을 하지 못할 우려가 있는 상태에서 운
전하는 행위를 말합니다.
「도로교통법」에서 정한 사고발생 시의 조치를 하지 않은 경우를 말합니다. 다만, 주䞱정차된 
차만 손괴한 것이 분명한 경우에 피해자에게 인적사항을 제공하지 아니한 경우는 제외합니
다.
용    어
용  어  의     정  의
 17. 상해
피보험자의 신체에 이상이 있는 점을 뒷받침할 수 있는 의학적 소견이 있는 경우만을 말합
니다.
13) 특별요율 : 예를 들어 에어백, 도난방지장치, 위험물적재에 따른 특별요율이 있습니다. 
14) 우량할인ㆍ불량할증요율 : 사고발생 내용(인적사고의 상해정도, 물적사고의 손해액 크기)에 따라 점수를 부과하여 적용
   하는 요율입니다. 
특별요율
우량할인·불량할증요율
사고건수요율
자동차의 구조나 운행실태가 같은 종류의 차량과 다른 경우 적용하는 요율
사고발생 실적에 따라 적용하는 요율
직전 3년간 사고유무 및 사고건수에 따라 적용하는 요율
기본보험료
특약요율
가입자특성요율
차량의 종류, 배기량, 용도, 보험가입금액, 성별, 연령 등에 따라 미리 정해
놓은 기본적인 보험료
운전자의 연령범위를 제한하는 특약, 가족으로 운전자를 한정하는 특약 등 
가입 시에 적용하는 요율
보험가입기간이나 법규위반경력에 따라 적용하는 요율
구        분
내                   용
(*3) ‘소지품’의 예 : 휴대전화기, 노트북, 캠코더, 카메라, 음성재생기(CD 플레이어, 
   MP3 플레이어, 카세트테이프 플레이어 등), 녹음기, 전자수첩, 전자사전, 휴대
   용라디오, 핸드백, 서류가방, 골프채 등
 16. 휴대품, 
   인명보호장구 
   및 소지품
④ 자동차보험료는 보험회사가 금융감독원에 신고한 후 사용하는 ‘자동차보험요율서’에서 정한 방법에 의하여 계
  산합니다.
<예시> 
=
X
X
X
X
납입할
보험료
기본
보험료
특약 
요율
가입자특성요율
(보험가입경력요율 ±
교통법규위반경력요율)
특별 
요율
지식13)
우량할인ㆍ
불량할증
요율 지식14)
X
사고
건수
요율
38
39
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (22, 1, 22, '제2절 대인배상Ⅱ와 대물배상
제6조 (보상하는 손해) 
① 대인배상Ⅱ에서 보험회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차의 
  사고로 인하여 다른 사람을 죽게 하거나 다치게 하여 법률상 손해배상책임을 짐으로써 입은 손해(대인배상Ⅰ에
  서 보상하는 손해를 초과하는 손해에 한정함)를 보상합니다.
②  대물배상에서 보험회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차의 사
  고로 인하여 다른 사람의 재물을 없애거나 훼손하여 법률상 손해배상책임을 짐으로써 입은 손해를 보상합니다. 
제7조 (피보험자) 
대인배상Ⅱ와 대물배상에서 피보험자란 다음 중 어느 하나에 해당하는 자를 말합니다. 
 1.  기명피보험자
 2.  친족피보험자
 3.  승낙피보험자. 다만, 자동차 취급업자가 업무상 위탁지식16)받은 피보험자동차를 사용하거나 관리하는 경우에
   는 피보험자로 보지 않습니다.
 4.  사용피보험자
 5.  운전피보험자. 다만, 자동차 취급업자가 업무상 위탁받은 피보험자동차를 사용하거나 관리하는 경우에는 피
   보험자로 보지 않습니다.
제8조 (보상하지 않는 손해)  
①  다음 중 어느 하나에 해당하는 손해는 대인배상Ⅱ와 대물배상에서 보상하지 않습니다.
 1. 보험계약자 또는 기명피보험자의 고의로 인한 손해
 2.  기명피보험자 이외의 피보험자의 고의로 인한 손해
 3.  전쟁, 혁명, 내란, 사변, 폭동, 소요지식17) 또는 이와 유사한 사태로 인한 손해
 4.  지진, 분화, 태풍, 홍수, 해일 등 천재지변으로 인한 손해
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
15) 
※ 단, 손해배상금 지급 및 구상청구는 대인배상Ⅰ(책임) 보험금 한도 금액 범위 내로 합니다.
④ 구상금 지급
② 손해배상금 지급
① 손해배상금 청구
③ 구상청구
회    사
피해자
피보험자
<예시>
16) “업무상 위탁”이란 취급업자가 업무를 위해서 피보험자동차의 사용 및 관리 책임을 맡는 것을 말합니다. 
17) “사변”은 전쟁에까지 이르지는 않았으나 경찰의 힘으로는 막을 수 없어 병력(무력)을 사용하게 되는 난리 등을 말합니
   다. “폭동”은 다수인이 집단적으로 행동하면서 폭행, 협박 또는 손괴행위를 하여 한 지역의 평온, 안녕 또는 질서 등을 저
   해하는 것을 말합니다. “소요”는 폭동과 유사한 행위이나 보다 소규모의 행위를 말합니다. 
 5.  핵연료물질의 직접 또는 간접적인 영향으로 인한 손해
 6.  영리를 목적으로 요금이나 대가를 받고 피보험자동차를 반복적으로 사용하거나 빌려 준 때에 생긴 손해. 다
   만, 다음 각목의 어느 하나에 해당하는 경우에는 보상합니다.
  가. 임대차계약(계약기간이 30일을 초과하는 경우에 한함)에 따라 임차인이 피보험자동차를 전속적으로 사용
    하는 경우 (다만, 임차인이 피보험자동차를 영리를 목적으로 요금이나 대가를 받고 반복적으로 사용하는 경
    우에는 보상하지 않습니다.)
    나. 피보험자와 동승자가 「여객자동차운수사업법」에 따른 토요일, 일요일 및 공휴일을 제외한 날의 출䞱퇴근 시
    간대(오전 7시부터 오전 9시까지 및 오후 6시부터 오후 8시까지를 말합니다.)에 실제의 출䞱퇴근 용도로 자
    택과 직장 사이를 이동하면서 승용차 함께 타기를 실시한 경우
 7.  피보험자가 제3자와 손해배상에 관한 계약을 맺고 있을 때 그 계약으로 인하여 늘어난 손해지식18)
 8. 피보험자동차를 시험용, 경기용 또는 경기를 위해 연습용으로 사용하던 중 생긴 손해. 다만, 운전면허시험을 
   위한 도로주행시험용으로 사용하던 중 생긴 손해는 보상합니다.
② 다음 중 어느 하나에 해당하는 사람이 죽거나 다친 경우에는 대인배상Ⅱ에서 보상하지 않습니다.
 1.  피보험자 또는 그 부모, 배우자 및 자녀
 2.  배상책임이 있는 피보험자의 피용자로서 산업재해보상보험법지식19)에 의한 재해보상을 받을 수 있는 사람. 다
   만, 그 사람이 입은 손해가 산업재해보상보험법에 의한 보상범위를 넘는 경우 그 초과손해를 보상합니다.
 3.  피보험자동차가 피보험자의 사용자의 업무에 사용되는 경우 그 사용자의 업무에 종사 중인 다른 피용자로서, 
   산업재해보상보험법에 의한 재해보상을 받을 수 있는 사람. 다만, 그 사람이 입은 손해가 산업재해보상보험법
   에 의한 보상범위를 넘는 경우 그 초과손해를 보상합니다.지식20)
③  다음 중 어느 하나에 해당하는 손해는 대물배상에서 보상하지 않습니다.
 1.  피보험자 또는 그 부모, 배우자나 자녀가 소유ㆍ사용ㆍ관리하는 재물에 생긴 손해
 2.  피보험자가 사용자의 업무에 종사하고 있을 때 피보험자의 사용자가 소유ㆍ사용ㆍ관리하는 재물에 생긴 손해
 3.  피보험자동차에 싣고 있거나 운송중인 물품에 생긴 손해
 4.  다른 사람의 서화, 골동품, 조각물, 그 밖에 미술품과 탑승자와 통행인의 의류나 휴대품에 생긴 손해. 그러나 
   탑승자의 신체를 보호할 인명보호장구에 한하여 피해자 1인당 200만원의 한도에서 실제 손해를 보상합니다.
 5.  탑승자와 통행인의 분실 또는 도난으로 인한 소지품에 생긴 손해. 그러나 훼손된 소지품에 한정하여 피해자 
   1인당 200만원의 한도에서 실제 손해를 보상합니다.
④  제①항 제2호와 관련해서 보험회사가 제9조(피보험자 개별적용) 제①항에 따라 피해자에게 손해배상을 하는 
  경우, 보험회사는 손해배상금을 지급한 날부터 3년 이내에 고의로 사고를 일으킨 피보험자에게 그 금액을 청구
  합니다.
18) <예시> 피보험자인 관광버스 회사가 탑승객에 대하여 “일정액”을 동일하게 보상한다는 별도의 약정을 한 경우
   → 해당 관광버스와 탑승객 사이의 약정(계약)에 따른 손해배상책임과 상관없이 보험회사는 자동차보험약관에 따르는 
     지급액만을 부담하게 됨
19) ‘산업재해보상보험법’이란 사업장에서 발생한 근로자의 산업 재해 등 근로자의 업무 상의 재해를 신속하고 공정하게 보
   상하며, 재해근로자의 재활 및 사회복귀를 촉진하기 위하여 이에 필요한 보험시설을 설치䞱운영하고, 재해예방과 그 밖에 
   근로자의 복지 증진을 위한 사업을 시행하여 근로자 보호에 이바지하는 것을 목적으로 시행된 법입니다.
20) 업무 중 등의 사고 시 “피용자”는 업무상의 재해로 인정될 경우 산업재해보상보험에 따라 보상받을 수 있습니다. 그경우
   에는 만약, 해당 피용자가 입은 손해가 산업재해보상보험법에 따른 보상부분을 넘는 경우, 그 초과손해분에 한정하여 보
   상한다는 내용입니다.
제3절 배상책임에서 공통으로 적용할 사항
제9조 (피보험자 개별적용) 
① 이 장의 규정은 각각의 피보험자마다 개별적으로 적용지식21)합니다. 다만 제8조(보상하지 않는 손해) 제①항 제
  1호, 제6호, 제8호를 제외합니다.
 2.  친족피보험자
 3.  승낙피보험자
 4.  사용피보험자
 5.  운전피보험자
제5조 (보상하지 않는 손해) 
보험계약자 또는 피보험자의 고의로 인한 손해는 대인배상Ⅰ에서 보상하지 않습니다. 다만, 자동차손해배상보장법 
제10조190쪽)에 따라 피해자가 보험회사에 직접청구를 한 경우, 보험회사는 자동차손해배상보장법령에서 정한 금액
을 한도로 피해자에게 손해배상금을 지급한 다음 지급한 날부터 3년 이내에 고의로 사고를 일으킨 보험계약자나 피
보험자에게 그 금액을 청구합니다. 지식15)
40
41
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (23, 1, 23, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
42
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
지급보험금
‘보험금지급기준에 의해 산출한 금액’ 
또는 ‘법원의 확정판결 등(*1)에 따라 
피보험자가 배상하여야 할 금액’지식22 )
비용지식23)
공제액
=
+
-
③ 제①항의 ‘비용’은 다음 중 어느 하나에 해당하는 금액을 말합니다.
 1. 손해의 방지와 경감을 위하여 지출한 비용(긴급조치비용을 포함)
 2.  다른 사람으로부터 손해배상을 받을 수 있는 권리의 보전과 행사를 위하여 지출한 필요한 비용 또는 유익한 
   비용지식24)
 3.  그 밖에 보험회사의 동의를 받아 지출한 비용
④ 제①항의 ‘공제액’은 다음의 금액을 말합니다. 
 1. 대인배상Ⅱ : 대인배상Ⅰ에서 지급되는 금액 또는 피보험자동차가 대인배상Ⅰ에 가입되지 않은 경우에는 대
   인배상Ⅰ에서 지급될 수 있는 금액
 2.  대물배상 : 사고차량을 고칠 때에 엔진, 변속기(트랜스미션), 모터, 구동용배터리 등 부분품을 교체한 경우 교
   체된 기존 부분품의 감가상각에 해당하는 금액
제11조 (음주운전, 무면허운전, 마약ㆍ약물운전 또는 사고발생 시의 조치의무 위반 관련 사고부담금)  
①  피보험자 본인이 음주운전이나 무면허운전 또는 마약ㆍ약물운전을 하는 동안에 생긴 사고 또는 사고발생 시의 
  조치의무를 위반한 경우 또는 기명피보험자의 명시적·묵시적지식25) 승인하에서 피보험자동차의 운전자가 음주
  운전이나 무면허운전 또는 마약ㆍ약물운전을 하는 동안에 생긴 사고 또는 사고발생 시의 조치의무를 위반한 경
  우로 인하여 보험회사가 대인배상 I, 대인배상 Ⅱ 또는 대물배상에서 보험금을 지급하는 경우, 피보험자는 다음
  에서 정하는 사고부담금을 보험회사에 납입하여야 합니다.
 1. 대인배상Ⅰ : 대인배상Ⅰ한도 내 지급보험금
 2. 대인배상Ⅱ : 1사고당 1억원
 3.  대물배상
  가. 자동차손해배상보장법 제5조 제2항의 규정에 따라 자동차보유자가 의무적으로 가입하여야 하는 대물배상 
    보험가입금액 이하 손해 :  지급보험금
  나. 자동차손해배상보장법 제5조 제2항의 규정에 따라 자동차보유자가 의무적으로 가입하여야 하는 대물배상 
    보험가입금액 초과 손해 : 1사고당 5,000만원
②  피보험자는 지체 없이 음주운전, 무면허운전, 마약ㆍ약물운전 또는 사고 발생 시의 조치의무 위반 사고부담금을 
  보험회사에 납입하여야 합니다. 다만, 피보험자가 경제적인 사유 등으로 이 사고부담금을 미납하였을 때 보험회
  사는 피해자에게 이 사고부담금을 포함하여 손해배상금을 우선 지급하고 피보험자에게 이 사고부담금의 지급
  을 청구할 수 있습니다.
(*1) “법원의 확정판결 등”이란 법원의 확정판결 또는 법원의 확정판결과 동일한 효력을 갖는 조정결정, 중재판정 
   등을 말합니다.
② 소송(민사조정, 중재를 포함)이 제기되었을 경우에는 대한민국 법원의 확정판결 등(*1)에 따라 피보험자가 손해
  배상청구권자에게 배상해야 할 금액(지연배상금을 포함)을 제①항의 ‘보험금지급기준에 의해 산출한 금액’으
  로 봅니다.
② 제①항에 따라 제10조(지급보험금의 계산)에서 정하는 보험금의 한도가 증액되지는 않습니다.
제10조 (지급보험금의 계산) 
① 대인배상Ⅰ, 대인배상Ⅱ, 대물배상에서 보험회사는 이 약관의 ‘보험금지급기준에 의해 산출한 금액’과 ‘비용’을 
  합한 금액에서 ‘공제액’을 공제한 후 보험금으로 지급하되 다음의 금액을 한도로 합니다. 다만, 비용은 다음의 
  금액과 관계없이 보상하여 드립니다.
 1.  대인배상Ⅰ : 자동차손해배상보장법령에서 정한 기준에 따라 산출한 금액
 2.  대인배상Ⅱ, 대물배상 : 보험증권에 기재된 보험가입금액
제12조 (보상하는 손해)  
자기신체사고에서 보험회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 다음 중 어느 하나
의 사고로 인하여 상해를 입은 때 그로 인한 손해를 보상하여 드립니다.
 1.  피보험자동차의 운행으로 인한 사고
 2.  피보험자동차의 운행 중 발생한 다음의 사고. 다만, 피보험자가 피보험자동차에 탑승 중일 때에 한정합니다.
  가. 날아오거나 떨어지는 물체와 충돌
    나. 화재 또는 폭발
    다. 피보험자동차의 낙하
제13조 (피보험자)  
자기신체사고에서 피보험자는 다음과 같습니다.
 1.  제7조(피보험자)의 대인배상Ⅱ에 해당하는 피보험자
제1절 자기신체사고
제2장 배상책임 이외의 보장종목
22) “법원의 확정판결 등에 따라 피보험자가 배상하여야 할 금액”은 소송 등으로 인하여 피보험자의 손해배상책임 금액이 법
   원에 의하여 결정된 경우를 말합니다. 이 경우, 회사는 자동차보험약관에 의한 지급금액 대신 법원의 확정 판결 등에 따
   라 피보험자가 배상해야할 금액을 보험가입금액 한도 내 지급합니다.
23) “비용”은 가입금액 등과 상관없이 지급해드리지만, “비용” 역시 “보험금”의 항목이기 때문에 약관상 지급보험금의 계산
   식에 포함되어 있습니다. 다만, 계산한 비용이 약관에서 정한 보험가입금액 등을 초과하더라도 초과한 비용에 대해서는 
   지급합니다. 
24) 사고 발생 시 보험회사는 지급한 금액의 한도 내에서 피보험자가 다른 사람으로부터 손해배상을 받을 수 있는 권리(손해
   배상청구권)를 취득합니다. 이 경우, 계약자 및 피보험자는 약관 제46조(사고발생 시 의무)에 따르는 의무사항으로서 그 
   권리(손해배상청구권)의 보전과 행사에 필요한 절차를 밟아야하며, 이 때에 필요하거나 유익한 비용을 말합니다.
   <예시> 사고 증거(블랙박스 영상 등)의 확보, 소송의 제기 등에 소요되는 비용 등
21) 하나의 자동차사고에서 피해자에게 배상책임을 지는 피보험자가 여러명 존재할 경우, 각각의 피보험자마다 손해배상의 
   발생책임 또는 보상하지 않는 손해의 판단 및 적용여부 등을 “개별적”으로 가려서 보상책임의 유무를 결정하는 것을 말
   합니다.
   <예시> A(기명피보험자)는 친구 B(승낙피보험자)에게 차를 빌려주어 운전하게 하였고, 친구 B가 고의로 사고를 내서 
       C(피해자)를 사상케 한 경우 
→ B의 C에 대한 배상책임은 “고의”사고로 보상불가, 
  A(차주로서 운행자책임을 짐)의 C에 대한 배상책임은 보상
손해배상 청구
고의에 의한
가해행위 (X)
손해배상 청구(O)
자동차를 대여
A (기명피보험자)
C (피해자)
B (승낙피보험자)
25) 법률상 추상적인 개념으로서 사안 별로 법률적 판단에 따라야 하는 내용입니다. 다만, 통상적인 의미는 다음과 같습니다.
    ① “명시적 승인”이란 내용이나 뜻을 분명하게 나타내어 해당 행위에 대해 승인하는 것을 말합니다. 
   ② “묵시적 승인”이란 직접적인 말 또는 행동이 아니라 간접적으로 해당 행위에 대해 승인하는 것을 말합니다.
42
43
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (24, 1, 24, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
지급보험금
실제손해액
비용
공제액
=
+
-
 2.  제1호의 피보험자의 부모, 배우자 및 자녀지식26) 
제14조 (보상하지 않는 손해)  
다음 중 어느 하나에 해당하는 손해는 자기신체사고에서 보상하지 않습니다. 
 1.  피보험자의 고의로 그 본인이 상해를 입은 때. 이 경우 그 피보험자에 대한 보험금만 지급하지 않습니다.지식27)  
 2.  상해가 보험금을 받을 자의 고의로 생긴 때에는 그 사람이 받을 수 있는 금액
 3.  피보험자동차 또는 피보험자동차 이외의 자동차를 시험용, 경기용 또는 경기를 위해 연습용으로 사용하던 중 
   생긴 손해. 다만, 운전면허시험을 위한 도로주행시험용으로 사용하던 중 생긴 손해는 보상합니다.
 4.  전쟁, 혁명, 내란, 사변, 폭동, 소요지식17) 및 이와 유사한 사태로 인한 손해
 5.  지진, 분화 등 천재지변으로 인한 손해
 6.  핵연료물질의 직접 또는 간접적인 영향으로 인한 손해
 7.  영리를 목적으로 요금이나 대가를 받고 피보험자동차를 반복적으로 사용하거나 빌려 준 때에 생긴 손해. 다
   만, 다음 각목의 어느 하나에 해당하는 경우에는 보상합니다.
  가. 임대차계약(계약기간이 30일을 초과하는 경우에 한함)에 따라 임차인이 피보험자동차를 전속적으로 사용
    하는 경우 (다만, 임차인이 피보험자동차를 영리를 목적으로 요금이나 대가를 받고 반복적으로 사용하는 경
    우에는 보상하지 않습니다.)
  나. 피보험자와 동승자가 「여객자동차운수사업법」에 따른 토요일, 일요일 및 공휴일을 제외한 날의 출䞱퇴근 시
    간대(오전 7시부터 오전 9시까지 및 오후 6시부터 오후 8시까지를 말합니다.)에 실제의 출䞱퇴근 용도로 자
    택과 직장 사이를 이동하면서 승용차 함께 타기를 실시한 경우
제15조 (보험금의 종류와 한도)  
보험회사가 자기신체사고에서 지급하는 보험금의 종류와 한도는 다음과 같습니다.
 1.  사망
   피보험자가 상해를 입은 직접적인 결과로 사망했을 때에는, 보험증권에 기재된 사망보험가입금액을 한도로 
   합니다.
  2.  부상
   피보험자가 상해를 입은 직접적인 결과로 의사의 치료가 필요한 때에는, ‘<별표 3> 자기신체사고 지급기준’의 
   ‘1. 상해구분 및 급별 보험가입금액표’76쪽) 상의 보험가입금액을 한도로 합니다.
  3.  후유장애
   피보험자가 상해를 입은 직접적인 결과로 치료를 받은 후에도 신체에 장애가 남은 때에는 ‘<별표 3> 자기신체
   사고 지급기준’의 ‘2. 후유장애구분 및 급별 보험가입금액표’77쪽)에 따라, 보험증권에 기재된 후유장애 보험가
   입금액에 해당하는 각 장애등급별 보험금액을 한도로 합니다.
제16조 (지급보험금의 계산)  
①  자기신체사고의 사망, 부상, 후유장애의 지급보험금은 다음과 같이 계산합니다. 다만, ‘비용’은 ‘공제액’이 발생
  하지 않는 경우에는 지급하지 않습니다.지식28) 
26) • 피보험자의 부모 : 피보험자의 부모, 양부모
   • 피보험자의 배우자 : 법률상의 배우자 또는 사실혼관계에 있는 배우자
   • 피보험자의 자녀 : 법률상의 혼인관계에서 출생한 자녀, 사실혼관계에서 출생한 자녀, 양자 또는 양녀
27) 예를 들어 피보험자동차에 피보험자 여러 명이 동승 중 사고가 발생한 경우, 고의로 사고를 일으킨 피보험자의 신체손해
   는 면책되나, 다른 피보험자의 신체손해에 대해서는 보험금이 지급될 수 있습니다.
 1.  위 ‘비용’은 다음의 금액을 말합니다. 이 비용은 보험가입금액과 관계없이 보상하여 드립니다.
  가. 손해의 방지와 경감을 위하여 지출한 비용
  나. 다른 사람으로부터 손해배상을 받을 수 있는 권리의 보전과 행사를 위하여 지출한 비용
 2. 실제손해액은 ‘<별표 1~5> 보험금 지급기준’에 따라 산출한 금액 또는 소송이 제기된 경우 확정판결금액으로
   서 과실상계지식29) 및 보상한도를 적용하기 전의 금액을 말합니다.
 3.  ‘공제액’은 다음의 금액을 말합니다. 
  가. 자동차보험(공제계약 포함) 대인배상Ⅰ(정부보장사업지식30) 포함) 및 대인배상Ⅱ에 따라 보상받을 수 있는 
    금액
  나. 무보험자동차에 의한 상해에 따라 지급될 수 있는 금액. 다만, 무보험자동차에 의한 상해 보험금의 청구를 
    포기한 경우에는 공제하지 않습니다.
  다. 배상의무자 이외의 제 3자로부터 보상받은 금액
 4.  제3호의 ‘공제액’이 발생하지 않는 경우지식28)에는 사망의 경우 보험증권에 기재된 사망보험가입금액, 부상의 
   경우 실제 소요된 치료비(성형수술비 포함), 후유장애의 경우 보험증권에 기재된 후유장애 보험가입금액에 
   해당하는 각 장애등급별 보험금액을 각각 지급합니다.
②  보험회사가 사망보험금을 지급할 경우에 이미 후유장애로 지급한 보험금이 있을 때에는 사망보험금에서 이를 
  공제한 금액을 지급합니다. 다만, 보험계약자인 기명피보험자가 본인의 사망보험금 수익자를 지정하거나 변경
  하고 그 사실을 보험회사에 서면으로 통지한 경우에는 그 수익자에게 보험금을 지급합니다.
제2절 무보험자동차에 의한 상해
제17조 (보상하는 손해)  
무보험자동차에 의한 상해에서 보험회사는 피보험자가 무보험자동차로 인하여 생긴 사고로 상해를 입은 때 그로 
인한 손해에 대하여 배상의무자(*1)가 있는 경우에 이 약관에서 정하는 바에 따라 보상하여 드립니다.
제18조 (피보험자)  
무보험자동차에 의한 상해에서 피보험자는 다음과 같습니다.
 1. 기명피보험자 및 기명피보험자의 배우자(피보험자동차에 탑승 중이었는지 상관없음)
 2. ‘기명피보험자 또는 그 배우자’의 부모 및 자녀(피보험자동차에 탑승 중이었는지 상관없음)
 3.  피보험자동차에 탑승 중인 경우로 기명피보험자의 승낙을 받아 피보험자동차를 사용 또는 관리중인 자. 
   다만 자동차 취급업자가 업무상 위탁받은 피보험자동차를 사용하거나 관리하는 경우에는 피보험자로 보지 않
   습니다.
 4.  제1호부터 제3호까지 규정하는 피보험자를 위하여 피보험자동차를 운전 중인 자. 
(*1) “배상의무자”란 무보험자동차로 인하여 생긴 사고로 피보험자를 죽게 하거나 다치게 함으로써 피보험자에게 
   입힌 손해에 대하여 법률상 손해배상책임을 지는 사람을 말합니다.
28) “자기신체사고”는 사고의 보험금지급 방식은 2가지로 나뉩니다
   ① “공제액”이 있는 경우  :  보험금 지급기준 등에 따라 “실제손해액”으로 산정하여 한도 내 지급
   ② “공제액”이 없는 경우  :  사망/부상/후유장애에 대해 약관에서 정한 바에 따르는 금액을 한도 내  지급 (실제손해액 
                  아님)
     <예시> “공제액이 없는 경우” : 약관에 기재된 공제액이 없는 경우로 피보험자의 단독 사고 등을 말합니다. 
   따라서, 실제 지출된 금액인 “비용”은 “공제액”이 있는 사고 시에만 지급됩니다. “공제액”이 없는 사고의 경우에는 약관
   에서 정한 금액을 보험가입금액 한도 내에서 지급하기 때문에 비용이 발생하더라도 지급보험금에 포함되지 않는다는 점
   을 참고하시기 바랍니다.
29) “과실상계”는 손해가 발생하였을 때, 피해자의  과실이 손해의 발생 또는 손해의 확대에 기여한 경우 손해의 공평분담을 
   위하여 손해배상액을 산정할 때 피해자의 과실을 참작하는 것을 말합니다.
30) “정부보장사업(자동차손해배상 보장사업)”이란 뺑소니 또는 무보험사고의 피해자를 구제하기 위하여, 정부가 피해자의 
   청구에 응해서 자동차손해배상보장법상 책임보험과 동일한 한도액까지 보장하는 제도를 말합니다.
44
45
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (25, 1, 25, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
 1.  위 ‘지급보험금’은 피보험자 1인당 보험증권에 기재된 보험가입금액을 한도로 합니다.
 2.  위 ‘ 비용’은 다음의 금액을 말합니다. 이 비용은 보험가입금액과 관계없이 보상하여 드립니다. 
  가. 손해의 방지와 경감을 위하여 지출한 비용
  나. 다른 사람으로부터 손해배상을 받을 수 있는 권리의 보전과 행사를 위하여 지출한 비용
 3. 위 ‘공제액’은 다음의 금액을 말합니다. 
  가. 대인배상Ⅰ(책임공제지식03) 및 정부보장사업지식30)을 포함)에 따라 지급될 수 있는 금액
  나. 배상의무자가 가입한 대인배상Ⅱ 또는 공제계약에 따라 지급될 수 있는 금액 
  다. 피보험자가 탑승 중이었던 자동차가 가입한 대인배상Ⅱ 또는 공제계약지식31)에 따라 지급될 수 있는 금액 
  라. 피보험자가 배상의무자로부터 이미 지급받은 손해배상액 
  마. 배상의무자가 아닌 제3자가 부담할 금액으로 피보험자가 이미 지급받은 금액
지급보험금
보험금지급기준에 의해
산출한 금액
비용
공제액
=
+
-
제20조 (지급보험금의 계산)  
무보험자동차에 의한 상해의 지급보험금은 다음과 같이 계산하며, 보험회사는 이 약관의 ‘보험금지급기준에 의해 
산출한 금액’과 ‘비용’을 합한 액수에서 ‘공제액’을 공제한 후 보험금으로 지급합니다. (다만, 「도로교통법」에 의한 
개인형이동장치로 인한 손해는 자동차손해배상보장법시행령 제3조에서 정하는 금액을 한도로 합니다.)
제3절 자기차량손해
제21조 (보상하는 손해)  
① 자기차량손해에서 보험회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 발생한 사고로 인하
  여 피보험자동차에 직접적으로 생긴 손해를 보험증권에 기재된 보험가입금액을 한도로 보상하되 다음 각 호의 
  기준에 따릅니다. 
 1. 보험가입금액이 보험가액보다 많은 경우에는 보험가액을 한도로 보상합니다.
 2.  피보험자동차에 통상 붙어있거나 장치되어 있는 부속품과 부속기계장치는 피보험자동차의 일부로 봅니다. 그
   러나 통상 붙어 있거나 장치되어 있는 것이 아닌 것은 보험증권에 기재된 것에 한정합니다.
 3.  피보험자동차의 일방과실사고의 경우에는 실제 수리를 원칙으로 합니다.
 4.  경미한 손상(*1)의 경우 보험개발원이 정한 경미손상 수리기준에 따라 복원수리하거나 품질인증부품(*2)으로 
   교환수리하는 데 소요되는 비용을 한도로 보상합니다.
제22조 (피보험자)  
자기차량손해에서 피보험자는 보험증권에 기재된 기명피보험자입니다.
제23조 (보상하지 않는 손해)  
다음 중 어느 하나에 해당하는 손해는 자기차량손해에서 보상하지 않습니다.
 1.  보험계약자 또는 피보험자의 고의로 인한 손해
 2.  전쟁, 혁명, 내란, 사변, 폭동, 소요지식17) 및 이와 유사한 사태로 인한 손해
 3.  지진, 분화 등 천재지변으로 인한 손해
 4.  핵연료물질의 직접 또는 간접적인 영향으로 인한 손해
 5.  영리를 목적으로 요금이나 대가를 받고 피보험자동차를 반복적으로 사용하거나 빌려 준 때에 생긴 손해. 다
   만, 다음 각목의 어느 하나에 해당하는 경우에는 보상합니다.
② 제①항의 ‘사고’는 다음 중 어느 하나에 해당하는 사고를 말합니다. 
 1.  타차량(*1)과의 충돌 또는 접촉으로 인한 손해
 2.  피보험자동차 전부의 도난으로 인한 손해(단, 전부도난이 아닌 경우에는 보상하지 않습니다)
(*1) ‘경미한 손상’이란 외장부품 중 자동차의 기능과 안전성을 고려할 때 부품교체 없이 복원이 가능한 손상을 말합
   니다.
   예시) 외장부품의 코팅, 색상 등의 손상에 대한 도색, 판금으로 복원이 가능한 경우 등
(*2) ‘품질인증부품’이란 「자동차관리법」 제30조의5에 따라 인증된 부품을 말합니다.
   다만, 자동차 취급업자가 업무상 위탁받은 피보험자동차를 사용하거나 관리하는 경우에는 피보험자로 보지 
   않습니다.
제19조 (보상하지 않는 손해)  
다음 중 어느 하나에 해당하는 손해는 무보험자동차에 의한 상해에서 보상하지 않습니다. 
 1.  보험계약자의 고의로 인한 손해
 2.  피보험자의 고의로 그 본인이 상해를 입은 때. 이 경우 해당 피보험자에 대한 보험금만 지급하지 않습니다. 
 3.  상해가 보험금을 받을 자의 고의로 생긴 때는 그 사람이 받을 수 있는 금액
 4.  전쟁, 혁명, 내란, 사변, 폭동, 소요지식17) 및 이와 유사한 사태로 인한 손해
 5.  지진, 분화, 태풍, 홍수, 해일 등 천재지변으로 인한 손해
 6.  핵연료물질의 직접 또는 간접적인 영향으로 인한 손해
 7.  영리를 목적으로 요금이나 대가를 받고 피보험자동차를 반복적으로 사용하거나 빌려 준 때에 생긴 손해. 다
   만, 다음 각목의 어느 하나에 해당하는 경우에는 보상합니다.
  가. 임대차계약(계약기간이 30일을 초과하는 경우에 한함)에 따라 임차인이 피보험자동차를 전속적으로 사용
    하는 경우 (다만, 임차인이 피보험자동차를 영리를 목적으로 요금이나 대가를 받고 반복적으로 사용하는 경
    우에는 보상하지 않습니다.)
  나. 피보험자와 동승자가 「여객자동차운수사업법」에 따른 토요일, 일요일 및 공휴일을 제외한 날의 출䞱퇴근 시
    간대(오전 7시부터 오전 9시까지 및 오후 6시부터 오후 8시까지를 말합니다.)에 실제의 출䞱퇴근 용도로 자
    택과 직장 사이를 이동하면서 승용차 함께 타기를 실시한 경우
 8.  피보험자동차 또는 피보험자동차 이외의 자동차를 시험용, 경기용 또는 경기를 위해 연습용으로 사용하던 중 
   생긴 손해. 다만, 운전면허시험을 위한 도로주행시험용으로 사용하던 중 생긴 손해는 보상합니다.
 9.  피보험자가 피보험자동차가 아닌 자동차를 영리를 목적으로 요금이나 대가를 받고 운전하던 중 생긴 사고로 
   인한 손해
 10.  다음 중 어느 하나에 해당하는 사람이 배상의무자(*1) 일 경우에는 보상하지 않습니다. 다만, 이들이 무보험자
   동차를 운전하지 않은 경우로, 이들 이외에 다른 배상의무자(*1) 가 있는 경우에는 보상합니다.
  가. 상해를 입은 피보험자의 부모, 배우자, 자녀
  나. 피보험자가 사용자의 업무에 종사하고 있을 때 피보험자의 사용자 또는 피보험자의 사용자의 업무에 종사 
    중인 다른 피용자
(*1) “배상의무자”란 무보험자동차로 인하여 생긴 사고로 피보험자를 죽게 하거나 다치게 함으로써 피보험자에게 
    입힌 손해에 대하여 법률상 손해배상책임을 지는 사람을 말합니다. 
(*1) ‘타차량’이란 피보험자동차 이외의 자동차로서 그 자동차의 등록번호(차량번호 또는 차대번호를 말함)와 사고
   발생시의 운전자 또는 소유자의 신분이 확인된 경우만을 말합니다. 이 경우, ‘자동차’란 자동차관리법에 따른 
   자동차, 건설기계관리법에 따른 건설기계, 군수품관리법에 따른 차량, 도로교통법에 따른 원동기장치자전거 
   및 농업기계화촉진법에 따른 농업기계를 말합니다.
31) ‘공제계약’이란 공제조합이 각자 조합원으로부터  받은 출자금을 자본으로 조합원의 자동차 사고 시에 공제금을 지급하
   여 돕는 ‘공제사업’에 의한 계약을 말합니다.
   예) 개인택시의 경우 ‘전국개인택시공제조합’에 의 한 공제계약
46
47
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (26, 1, 26, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
제24조 (지급보험금의 계산)  
①  자기차량손해의 지급보험금은 다음과 같이 계산하며, 보험회사는 ‘피보험자동차에 생긴 손해액’과 ‘비용’을 합
  한 액수에서 보험증권에 기재된 ‘자기부담금’을 공제한 후 보험금으로 지급합니다.
지급보험금
피보험자동차에
생긴 손해액
비용
보험증권에 기재된
자기부담금
=
+
-
32) “잔존물”이란 보험사고 처리 후 남아있는 피보험자동차 등 보험목적물(보험에 가입한 대상)을 말합니다.
33) “감가상각”이란 “일정기간이 지나면 상실되는 물건의 가치감소분”을 빼는 것을 말합니다. 
(*1) ‘임차인’이 법인인 경우에는 그 이사, 감사 또는 피고용자(피고용자가 피보험자동차를 법인의 업무에 사용하
   고 있는 때에 한정함)를 포함합니다.
 1.  위 ‘피보험자동차에 생긴 손해액’은 다음과 같이 결정합니다. 
  가. 보험증권에 기재된 보험가입금액을 한도로 보상하며, 보험가입금액이 보험사고 발생 당시 보험개발원의 자
    동차보험 차량기준가액표(적용요령에서 정한 기준 포함)에 정한 가액보다 많은 경우에는 보험사고 발생 당
    시 가액을 한도로 보상합니다.
  나. 피보험자동차의 손상을 고칠 수 있는 경우에는, 사고가 생기기 바로 전의 상태로 만드는데 드는 수리비. 
    단, 잔존물지식32)이 있는 경우에는 그 값을 공제합니다.
  다. 피보험자동차를 고칠 때에 부득이 새 부분품(*1)을 쓴 경우에는, 그 부분품의 값과 그 부착 비용을 합한 금액. 
    다만, 엔진, 미션 등 중요한 부분(*2)을 새 부분품으로 교환한 경우 그 교환된 기존 부분품의 감가상각지식33)에 
    해당하는 금액을 공제합니다.
  라. 피보험자동차가 제힘으로 움직일 수 없는 경우에는, 이를 고칠 수 있는 가까운 정비공장이나 보험회사가 지
    정하는 곳까지 운반하는데 든 비용 또는 그 곳까지 운반하는데 든 임시수리비용 중에서 정당하다고 인정되
    는 부분은 보상하여 드립니다.
 2. 위 ‘비용’은 다음의 금액을 말합니다. 이 비용은 보험가입금액과 관계없이 보상하여 드립니다.
  가. 손해의 방지와 경감을 위하여 지출한 비용
  나. 다른 사람으로부터 손해배상을 받을 수 있는 권리의 보전과 행사를 위하여 지출한 비용 
 3. 위 ‘자기부담금’은 피보험자동차에 전부손해(*3)가 생긴 경우 또는 보험회사가 보상해야 할 금액이 전액 이상
    인 경우에는 공제하지 않습니다.
 4. 대물배상 책임이 발생하는 사고 시 사고 당사자간 과실이 모두 있는 경우 상대방에게 손해배상금 또는 상대방
   이 가입한 보험회사에서 대물배상 보험금을 지급받기 전에 자기차량손해 담보로 보험금을 지급받고자 하는 
   경우에는 자기차량손해 담보에서 정한 자기부담금을 피보험자가 확정적으로 부담하는 조건으로 자기차량손
   해 보험금을 먼저 지급하여 드리며, 자기부담금을 부담한 피보험자는 상대방 또는 상대방이 가입한 보험회사
   에게 이 금액을 청구할 수 없습니다. 이 경우 자기차량손해 보험금을 지급한 보험회사는 지급한 보험금 범위
   에서 상대방 또는 상대방이 가입한 보험회사에 대하여 가지는 피보험자의 권리를 취득합니다. 다만, 상대방 
   손해배상책임액이 보험회사가 구상한 금액보다 큰 경우에 피보험자는 상대방 또는 상대방이 가입한 보험회사
   에 그 차액을 청구할 수 있습니다.
 5. 자기차량손해 보험금을 지급한 보험회사가 상대방 또는 상대방이 가입한 보험회사로부터 구상금을 받은 경우 
   (1) 피보험자가 이미 부담한 자기부담금과 (2) 실제 손해액에서 당해 구상금을 제외한 금액을 전제로 산정된 
   자기부담금과의 차액을 피보험자에게 지급하여 드립니다. (이 경우에도 피보험자가 최종적으로 부담하는 자
   기부담금은 최소 자기부담금 이상으로 합니다.)
② 보험회사는 피보험자동차에 생긴 손해에 대하여 보험회사가 필요하다고 인정하는 경우에는, 피보험자의 동의
  를 받아 수리하거나 대용품을 주는 것으로 보험금 지급을 대신할 수 있습니다. 
③  보험회사가 보상한 손해가 전부손해이거나 보험회사가 보상한 금액이 보험가입금액 전액 이상인 경우에는 자
  기차량손해의 보험계약은 사고 발생 시에 종료됩니다. 
④  보험회사가 피보험자동차의 전부손해에 대하여 보험금 전액을 지급한 경우에는 피해물을 인수합니다. 이 경우 
  보험가입금액이 보험가액보다 적을 때에는 보험가입금액의 보험가액에 대한 비율에 따라 피해물을 인수합니
  다. 그러나, 보험회사가 피해물을 인수하지 않는다는 뜻을 표시하고 보험금을 지급하는 경우에는 피해물에 대한 
  피보험자의 권리가 보험회사에 이전되지 않습니다.
(*1) ‘부분품’이란 보통약관 제1조(용어의 정의) 제6호의 가목의 엔진, 변속기(트랜스미션) 등 자동차가 공장에서 
   출고될 때 원형 그대로 부착되어 자동차의 조성부분이 되는 재료를 말합니다.
   다만, 피보험자가 원하는 경우 「자동차관리법」 제30조의5에 따른 품질인증부품을 사용할 수 있으며, 피보험자
   동차의 단독사고(가해자불명사고 포함) 또는 일방과실사고로 보통약관 「자기차량손해」 또는 「차량단독사고 보
   장 특별약관」에 따라서 보험금이 지급되는 경우 「품질인증부품 사용 특별약관」에 따라 수리비의 일정액을 피보
   험자에게 지급하여 드립니다.
(*2) ‘중요한 부분’이란 엔진, 미션, 캐빈, 적재함, 바디 및 전기차(하이브리드 자동차 포함)의 모터, 감속기, 구동용 
   배터리 등 중요한 부분품을 말합니다.
(*3) ‘전부손해’란 피보험자동차가 완전히 파손, 멸실 또는 오손되어 수리할 수 없는 상태이거나, 피보험자동차에 
   생긴 손해액과 보험회사가 부담하기로 한 비용의 합산액이 보험가액 이상인 경우를 말합니다.
  가. 임대차계약(계약기간이 30일을 초과하는 경우에 한함)에 따라 임차인이 피보험자동차를 전속적으로 사용
    하는 경우 (다만, 임차인이 피보험자동차를 영리를 목적으로 요금이나 대가를 받고 반복적으로 사용하는 경
    우에는 보상하지 않습니다.)
  나. 피보험자와 동승자가 「여객자동차운수사업법」에 따른 토요일, 일요일 및 공휴일을 제외한 날의 출䞱퇴근 시
    간대(오전 7시부터 오전 9시까지 및 오후 6시부터 오후 8시까지를 말합니다.)에 실제의 출䞱퇴근 용도로 자
    택과 직장 사이를 이동하면서 승용차 함께 타기를 실시한 경우
 6.  사기 또는 횡령으로 인한 손해
 7.  국가나 공공단체의 공권력 행사에 의한 압류, 징발, 몰수, 파괴 등으로 인한 손해. 그러나 소방이나 피난에 필
   요한 조치로 손해가 발생한 경우에는 그 손해를 보상합니다.
 8.  피보험자동차에 생긴 흠, 마멸, 부식, 녹, 그 밖에 자연소모로 인한 손해
 9.  피보험자동차의 일부 부분품, 부속품, 부속기계장치만의 도난으로 인한 손해
 10.  동파로 인한 손해 또는 우연한 외래의 사고에 직접 관련이 없는 전기적, 기계적 손해
 11.  피보험자동차를 시험용, 경기용 또는 경기를 위해 연습용으로 사용하던 중 생긴 손해. 다만, 운전면허시험을 
   위한 도로주행시험용으로 사용하던 중 생긴 손해는 보상합니다.
 12.  피보험자동차를 운송하거나 싣고 내릴 때에 생긴 손해
 13.  피보험자동차가 주정차 중일 때 피보험자동차의 타이어나 튜브에만 생긴 손해. 다만, 다음 중 어느 하나에 해
   당하는 손해는 보상합니다(타이어나 튜브의 물리적 변형이 없는 단순 오손의 경우는 제외). 
  가. 다른 자동차가 충돌하거나 접촉하여 입은 손해
  나. 화재, 산사태로 입은 손해
  다. 가해자가 확정된 사고(*1)로 인한 손해
(*1) ‘가해자가 확정된 사고’란 피보험자동차에 장착되어 있는 타이어나 튜브를 훼손하거나 파손한 사고로, 경찰관
   서를 통하여 가해자(기명피보험자 및 기명피보험자의 부모, 배우자, 자녀는 제외)의 신원이 확인된 사고를 말
   합니다.
 14.  다음 각목의 어느 하나에 해당하는 자가 무면허운전, 음주운전 또는 마약ㆍ약물운전을 했을 때 생긴 손해
  가. 보험계약자, 기명피보험자 
  나. 30일을 초과하는 기간을 정한 임대차계약에 의해 피보험자동차를 빌린 임차인(*1).
  다. 기명피보험자와 같이 살거나 생계를 같이 하는 친족
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
48
49
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (27, 1, 27, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
⑥  대인배상Ⅰ, 대인배상Ⅱ, 자기신체사고, 무보험자동차에 의한 상해에서 보험회사는 피보험자 또는 손해배상청
  구권자의 청구가 있거나 그 밖의 원인으로 보험사고가 발생한 사실을 알았을 때에는 피해자 또는 손해배상청구
  권자를 진료하는 의료기관에 그 진료에 따른 자동차보험 진료수가지식36)의 지급의사 유무 및 지급한도 등을 통지
  합니다.
제27조 (제출 서류)  
피보험자는 보장종목별로 다음의 서류 등을 구비하여 보험금을 청구해야 합니다. 
36) “자동차보험 진료수가”란 교통사고 환자에 대한 적절한 진료를 보장하고 보험회사 등, 의료기관 및 교통사고환자 간의 
   진료비에 관한 분쟁을 방지하기 위하여 자동차손해배상보장법에 따라 국토교통부에서 정하여 고시하는 진료비 기준금
   액을 말합니다.
34) “7일 이내”란 보험금액이 최종 확정된 날(0시 기준)로부터 계산하여 주말 및 법정공휴일을 포함하여 7일째 되는 날을 
   말합니다(단, 7일째 되는 날이 주말 또는 법정공휴일인 경우에는 그 다음날인 평일로 함) 
35) “연 단위 복리”란 이자 계산시 원금에 대한 이자를 원금에 가산시킨 후 이 합계액을 새로운 원금으로 계산하는 이자계산 
   방법입니다.
    <예시> 원금 : 100원 / 이자율 : 연 10％ 
        - 1년 후 : 100원 + (100원 X 10%) = 110원
        - 2년 후 : 110원 + (110원 X 10%) = 121원 
               :                   :
보험금 청구시 필요 서류 등
자기차량
손해
대인배상
대물배상
1.   보험금 청구서
2. 손해액을 증명하는 서류(진단서 등)
4. 사고가 발생한 때와 장소 및 사고사실이 
  신고된 관할 경찰관서의 교통사고사실
  확인원 등
○
○
○
○
○
○
○
○
○
○
○
3.   손해배상의 이행사실을 증명하는 서류
○
○
무보험
자동차에  
의한 상해
자기신체
사고
○
5. 배상의무자의 주소, 성명 또는 명칭, 
  차량번호
○
6. 배상의무자의 대인배상Ⅱ 또는 
  공제계약의 유무 및 내용
○
9. 그 밖에 보험회사가 꼭 필요하여 
  요청하는 서류 등(수리개시 전 자동차
  점검ㆍ정비견적서, 사진 등. 이 경우 
  수리 개시 전 자동차점검ㆍ정비
  견적서의 발급 등에 관한 사항은 보험
  회사에 구두 또는 서면으로 위임할 수 
  있으며, 보험회사는 수리 개시 전 
○
○
○
○
○
8. 전손보험금을 
  청구할 경우
○
○
○
○
전손사고 후 
이전매각시 이전서류
전손사고 후 폐차시 
폐차인수증명서
○
도난으로 인한 
전손사고시 
말소 사실증명서
7. 피보험자가 입은 손해를 보상할 
  대인배상Ⅱ 또는 공제계약, 배상의무자 
  또는 제3자로부터 이미  지급받은 손해
  배상금이 있을 때에는 그 금액
○
제25조 (보험금을 청구할 수 있는 경우)  
피보험자는 다음에서 정하는 바에 따라 보험금을 청구할 수 있습니다.
제3편 보험금 또는 손해배상의 청구
제26조 (청구 절차 및 유의 사항)  
①  보험회사는 보험금 청구에 관한 서류를 받았을 때에는 지체 없이 지급할 보험금액을 정하고 그 정하여진 날부터 
  7일 이내지식34)에 지급합니다.
② 보험회사가 정당한 사유 없이 보험금액을 정하는 것을 지연하였거나 제①항에서 정한 지급기일 내에 보험금을 
  지급하지 않았을 때, 지급할 보험금이 있는 경우에는 그 다음날부터 지급일까지의 기간에 대하여 <부표> 보험
  금을 지급할 때의 적립이율 78쪽)에 따라 연 단위 복리지식35)로 계산한 금액을 보험금에 더하여 지급합니다. 다만, 
  피보험자에게 책임이 있는 사유로 지급이 지연될 때에는 그 해당기간에 대한 이자를 더하여 드리지 않습니다.
③  보험회사가 보험금 청구에 관한 서류를 받은 때부터 30일 이내에 피보험자에게 보험금을 지급하는 것을 거절하 
  는 이유 또는 그 지급을 연기하는 이유(추가 조사가 필요한 때에는 확인이 필요한 사항과 확인이 종료되는 시기
  를 포함)를 서면(전자우편 등 서면에 갈음할 수 있는 통신수단을 포함)으로 통지하지 않는 경우, 정당한 사유 없
  이 보험금액을 정하는 것을 지연한 것으로 봅니다.
④  보험회사는 손해배상청구권자가 손해배상을 받기 전에는 보험금의 전부 또는 일부를 피보험자에게 지급하지 
  않으며, 피보험자가 손해배상청구권자에게 지급한 손해배상액을 초과하여 피보험자에게 지급하지 않습니다.
⑤  피보험자의 보험금 청구가 손해배상청구권자의 직접청구와 경합할 때에는 보험회사가 손해배상청구권자에게 
  우선하여 보험금을 지급합니다.
1. 대인배상Ⅰ,
  대인배상Ⅱ,
  대물배상
2. 자기신체사고
3. 무보험자동차에 
  의한 상해
4.  자기차량손해
대한민국 법원에 의한 판결의 확정, 재판상의 화해, 중재 또는 서면에 의한 합의로 손해
배상액이 확정된 때
피보험자가 피보험자동차를 소유, 사용, 관리하는 동안에 생긴 피보험자동차의 사고로 
인하여 상해를 입은 때
피보험자가 무보험자동차에 의해 생긴 사고로 상해를 입은 때
사고가 발생한 때. 다만, 피보험자동차를 도난당한 경우에는 도난사실을 경찰관서에 
신고한 후 30일이 지나야 보험금을 청구할 수 있습니다. 만약, 경찰관서에 신고한 후 
30일이 지나 보험금을 청구했으나 피보험자동차가 회수되었을 경우에는, 보험금의 지
급 및 피보험자동차의 반환여부는 피보험자의 의사에 따릅니다.
보장종목
보험금을 청구할 수 있는 경우
제1장 피보험자의 보험금 청구
50
51
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (28, 1, 28, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
4. 그 밖에 보험회사가 꼭 필요하여 요청하는 서류 등(수리개시 
  전 자동차점검ㆍ 정비견적서, 사진 등. 이 경우 수리개시 전 
  자동차점검ㆍ 정비견적서의 발급 등에 관한 사항은 보험회사에 
  구두 또는 서면으로 위임할 수 있으며, 보험회사는 수리개시 전 
  자동차점검ㆍ 정비견적서를 발급한 자동차 정비업자에게 이에 
  대한 검토의견서를 수리개시 전에 회신하게 됩니다.)
○
○
손해배상청구권자가 직접 청구하는 경우 필요 서류 등
대물배상
대인배상ⅠㆍⅡ
1. 교통사고 발생사실을 확인할 수 있는 서류
2. 손해배상청구서
○
○
○
○
3. 손해액을 증명하는 서류
○
○
제32조 (가지급금의 지급)  
①  손해배상청구권자가 가지급금을 청구한 경우 보험회사는 자동차손해배상보장법 또는 교통사고처리특례법 등
  에 의해 이 약관에 따라 지급할 금액의 한도에서 가지급금(자동차보험 진료수가는 전액, 진료수가 이외의 손해
  배상금은 이 약관에 따라 지급할 금액의 50%)을 지급합니다. 
37) “가지급금”이란 보험회사가 피보험자에 대한 보상책임이나 피해자에 대한 손해배상책임을 확정하기 전에 자동차보험 
   약관에 따라 산출한 지급금액의 일부를 피보험자 또는 피해자에게 미리 지급하는 금액을 말합니다.
38) “객관적으로 명백할 경우”란 약관의 각 보종종목별 “보상하지 않는 손해”에 해당하거나, 상대방의 일방과실인 경우(신
   호위반, 중앙선침범, 후미추돌 등) 등 회사의 보험금 지급책임이 발생하지 않는 경우를 말합니다.
39) 피보험자는 사고 시 손해배상청구권자(손해배상을 청구할 권리를 가진 자)에 대하여 배상책임의 유무(有無) 또는 배상
   책임의 범위 등을 주장할 수 있습니다. 이와 마찬가지로 손해배상청구권자가 직접 보험회사에 손해배상금을 청구한 경
   우, 보험회사도 피보험자와 동일하게 손해배상청구권자의 손해배상청구에 대하여 대응(대항)할 수 있다는 의미입니다.
제29조 (손해배상을 청구할 수 있는 경우)  
피보험자가 법률상의 손해배상책임을 지는 사고가 생긴 경우, 손해배상청구권자는 보험회사에 직접 손해배상금을 
청구할 수 있습니다. 다만 보험회사는 피보험자가 그 사고에 관하여 가지는 항변으로 손해배상청구권자에게 대항
할 수 있습니다.지식39)
제30조 (청구 절차 및 유의 사항)  
① 보험회사가 손해배상청구권자의 청구를 받았을 때에는 지체 없이 피보험자에게 통지합니다. 이 경우 피보험자
  는 보험회사의 요청에 따라 증거확보, 권리보전 등에 협력해야 하며, 만일 피보험자가 정당한 이유 없이 협력하
  지 않은 경우 그로 인하여 늘어난 손해는 보상하지 않습니다.
②  보험회사가 손해배상청구권자에게 지급하는 손해배상금은 이 약관에 따라 보험회사가 피보험자에게 지급책임
  을 지는 금액을 한도로 합니다.
③  보험회사가 손해배상청구권자에게 손해배상금을 직접 지급할 때에는 그 금액의 한도에서 피보험자에게 보험금
  을 지급하는 것으로 합니다.
④  보험회사는 손해배상청구에 관한 서류 등을 받았을 때에는 지체 없이 지급할 손해배상액을 정하고 그 정하여진 
  날부터 7일 이내에 지급합니다. 
⑤ 보험회사가 정당한 사유 없이 손해배상금을 정하는 것을 지연하였거나 제④항에서 정하는 지급기일 내에 손해
  배상금을 지급하지 않았을 때,지식40) 지급할 손해배상금이 있는 경우에는 그 다음날부터 지급일까지의 기간에 대
  하여 <부표> 보험금을 지급할 때의 적립이율 78쪽)에 따라 연 단위 복리지식35)로 계산한 금액을 손해배상금에 더하
  여 지급합니다. 그러나 손해배상청구권자에게 책임이 있는 사유로 지급이 지연될 때에는 그 해당기간에 대한 이
  자를 더하여 드리지 않습니다.
⑥  보험회사가 손해배상 청구에 관한 서류를 받은 때부터 30일 이내에 손해배상청구권자에게 손해배상금을 지급
  하는 것을 거절하는 이유 또는 그 지급을 연기하는 이유(추가 조사가 필요한 때에는 확인이 필요한 사항과 확인
  이 종료되는 시기를 포함)를 서면(전자우편 등 서면에 갈음지식41)할 수 있는 통신수단을 포함)으로 통지하지 않
  는 경우, 정당한 사유 없이 손해배상액을 정하는 것을 지연한 것으로 봅니다.
⑦ 보험회사는 손해배상청구권자의 요청이 있을 때는 손해배상액을 일정기간으로 정하여 정기금지식42)으로 지급할 
  수 있습니다. 이 경우 각 정기금의 지급기일의 다음날부터 다 지급하는 날까지의 기간에 대하여 보험개발원이 
  공시한 정기예금이율에 따라 연 단위 복리로 계산한 금액을 손해배상금에 더하여 드립니다.
제31조 (제출 서류)  
손해배상청구권자는 보장종목별로 다음의 서류 등을 구비하여 보험회사에 손해배상을 청구해야 합니다. 
제2장 손해배상청구권자의 직접청구
제28조 (가지급금의 지급)  
①  피보험자가 가지급금지식37)을 청구한 경우 보험회사는 이 약관에 따라 지급할 금액의 한도에서 가지급금(자동
  차보험 진료수가는 전액, 진료수가 이외의 보험금은 이 약관에 따라 지급할 금액의 50%)을 지급합니다.
②  보험회사는 가지급금 청구에 관한 서류를 받았을 때에는 지체 없이 지급할 가지급액을 정하고 그 정하여진 날부
  터 7일 이내에 지급합니다.
③  보험회사가 정당한 사유 없이 가지급액을 정하는 것을 지연하거나 제②항에서 정하는 지급기일 내에 가지급금
  을 지급하지 않았을 때, 지급할 가지급금이 있는 경우에는 그 다음날부터 지급일까지의 기간에 대하여 보험개발
  원이 공시한 보험계약대출이율을 연 단위 복리지식35)로 계산한 금액을 가지급금에 더하여 드립니다.
④  보험회사가 가지급금 청구에 관한 서류를 받은 때부터 10일 이내에 피보험자에게 가지급금을 지급하는 것을 거
  절하는 이유 또는 그 지급을 연기하는 이유(추가 조사가 필요한 때에는 확인이 필요한 사항과 확인이 종료되는 
  시기를 포함)를 서면(전자우편 등 서면에 갈음할 수 있는 통신수단을 포함)으로 통지하지 않는 경우, 정당한 사
  유 없이 가지급액을 정하는 것을 지연한 것으로 봅니다.
⑤  보험회사는 이 약관상 보험회사의 보험금 지급책임이 발생하지 않는 것이 객관적으로 명백할 경우지식38)에 가지
  급금을 지급하지 않을 수 있습니다.
⑥  피보험자에게 지급한 가지급금은 장래 지급될 보험금에서 공제되나, 최종적인 보험금의 결정에는 영향을 주지 
  않습니다. 
⑦  피보험자가 가지급금을 청구할 때는 보험금을 청구하는 경우와 동일하게 제27조(제출 서류)에서 정하는 서류 
  등을 보험회사에 제출해야 합니다.
보험금 청구시 필요 서류 등
자기차량
손해
대인배상
대물배상
무보험
자동차에  
의한 상해
자기신체
사고
○
○
○
○
○
  자동차점검ㆍ 정비견적서를 발급한 
  자동차 정비업자에게 이에 대한 검토
  의견서를 수리개시 전에 회신하게 
  됩니다.)
40) ‘보험회사가 정당한 사유 없이 손해배상금을 정하는 것을 지연하였거나 제④항에서 정하는 지급기일 내에 손해배상금을 
   지급하지 않았을 때’에서 ‘정당한 사유’란 추가적인 사고조사가 필요한 경우, 보험금 청구권자 또는 손해배상금 청구권자
   가 보험회사로 제출해야 할 서류의 일부 또는 전부의 누락으로 보험사고의 조사가 제대로 이루어 지기 어려운 경우 등에 
   의한 것을 말합니다.
41) “갈음”이란 “다른 것으로 바꾸어 대신함”이라는 우리말로서 서면을 대신할 수 있는 통신수단을 포함한다는 의미입니다.
42) “정기금”이란 손해배상액 등을 “일시금”으로 한 번에 지급받지 않고 기간을 정하여 나누어 받는 것을 말합니다.
52
53
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (29, 1, 29, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
 3. 제1호 또는 제2호에도 불구하고 자동차 취급업자가 가입한 보험계약에서 보험금이 지급될 수 있는 경우에는 
   그 보험금을 초과하는 손해를 보상합니다.
제34조 (보험회사의 대위)지식45)
①  보험회사가 피보험자 또는 손해배상청구권자에게 보험금 또는 손해배상금을 지급한 경우에는 지급한 보험금 
  또는 손해배상금의 범위에서 제3자에 대한 피보험자의 권리를 취득합니다. 다만, 보험회사가 보상한 금액이 피
  보험자의 손해의 일부를 보상한 경우에는 피보험자의 권리를 침해하지 않는 범위지식46)에서 그 권리를 취득합니
  다.
②  보험회사는 다음의 권리는 취득하지 않습니다. 
 1.  자기신체사고의 경우 제3자에 대한 피보험자의 권리.지식47) 다만, 보험금을 ‘별표 1. 대인배상, 무보험자동차
   에 의한 상해 지급기준’66쪽)에 의해 지급할 때는 피보험자의 권리를 취득합니다.
 2.  자기차량손해의 경우 피보험자동차를 정당한 권리에 따라 사용하거나 관리하던 자에 대한 피보험자의 권리. 
   다만, 다음의 경우에는 피보험자의 권리를 취득합니다.
  가. 고의로 사고를 낸 경우, 무면허운전이나 음주운전을 하던 중에 사고를 낸 경우, 또는 마약 또는 약물 등의 영향
    으로 정상적인 운전을 하지 못할 우려가 있는 상태에서 운전을 하던 중에 사고를 낸 경우
  나. 자동차 취급업자가 업무로 위탁지식48)받은 피보험자동차를 사용하거나 관리하는 동안에 사고를 낸 경우
 3.  피보험자가 생계를 같이하는 가족에 대하여 갖는 권리. 다만, 손해가 그 가족의 고의로 인하여 발생한 경우에는 
   피보험자의 권리를 취득합니다.
③  피보험자는 보험회사가 제①항 또는 제②항에 따라 취득한 권리의 행사 및 보전에 관하여 필요한 조치를 취해야 
  하며, 또한 보험회사가 요구하는 자료를 제출해야 합니다.
제35조 (보험회사의 불성실행위로 인한 손해배상책임) 
①  보험회사는 이 보험계약과 관련하여 임직원, 보험설계사, 보험대리점에게 책임이 있는 사유로 인하여 보험계약
  자 및 피보험자에게 발생된 손해에 대하여 관계 법률 등에서 정한 바에 따라 손해배상책임을 집니다.
②  보험회사가 보험금의 지급여부나 지급금액에 관하여 보험계약자 또는 피보험자의 곤궁, 경솔 또는 무경험지식49)
 
 을 이용해서 현저하게 공정을 잃은 합의를 한 경우에도 손해를 배상할 책임을 집니다.
제36조(합의 등의 협조ㆍ대행) 
①  보험회사는 피보험자의 협조 요청이 있는 경우 피보험자의 법률상 손해배상책임을 확정하기 위하여 피보험자
  가 손해배상청구권자와 행하는 합의ㆍ절충ㆍ중재 또는 소송(확인의 소를 포함)에 대하여 협조하거나, 피보험
  자를 위하여 이러한 절차를 대행합니다.
45) “대위(代位)”란 보험회사가 피보험자의 법률적 지위를 대신하여 피보험자가 가진 권리를 얻거나 행사하는 일을 말합니
   다. 
46) 제3자의 과실로 인하여 발생한 전체 손해액에서 보험회사가 지급한 일부 보험금 또는 손해배상금을 공제한 금액만큼은 
   여전히 피보험자가 제3자에게 청구할 수 있는 권리로 남게 됩니다. 
   이 경우, 보험회사는 “피보험자의 권리를 침해하지 않는 범위” 즉, “피보험자가 제3자에게 청구할 수 있는 금액”을 초과
   하는 부분에 대하여만 피보험자를 대신(대위)하여 제3자에게 직접청구할 수 있습니다.
   <예시> 
   ○  총손해액 : 1억 / 과실 : 피보험자 70%, 제3자 30%   
   ○  보험금지급 : 5천만원
     ① 보험금지급 후 남은 손해액 = 총손해액 – 보험금 = 1억 – 5천만원 = 5천만원
     ② 피보험자가 제3자에게 청구할 수 있는 금액  = 제3자의 과실 = 3천만원
     ⇨ 보험회사가 대위권을 행사할 수 있는 금액 = ① - ② = 5천만원 – 3천만원(피보험자의 권리) = 2천만원
47) “제3자에 대한 피보험자의 권리”는 예를 들어 손해가 피보험자가 아닌 제3자의 행위로 인하여 생긴 경우에 피보험자가 
   해당 제3자에게 가지는 손해배상청구권 등의 권리를 말하는 것입니다. 이 경우, 피보험자에게 자기신체사고 보험금을 지
   급한 보험회사는 피보험자 대신 제3자에 대한 손해배상청구권 등의 권리를 취득하여 행사합니다.
48) “위탁” ⇨ 제7조(피보험자)의 “프로미카 보험지식”의 설명 참고
49) 보험계약자 및 피보험자의 경제적 어려움 등(곤궁), 경솔함, 그리고 보험지식 및 정보가 부족함 등(무경험)을 이용하여 
   불공정한 합의를 하면 안 된다는 점을 나타낸 것으로, 공정한 보험금 합의에 대하여 명시한 내용입니다.
43) <중복 시 보험금의 분담 예시>
   ○  피보험자동차 손해액 : 100만원  ○ 계약 A : 보험가입금액 100만원  ○ 계약 B : 보험가입금액  50만원
     - 각 계약별 보상책임액    A : 100만원, B : 50만원
     - 사고로 계약 A, B가 부담할 전체 손해액 : 100만원
     - 계약 A, B의 부담금액
        A : 100만원 X 100만원/(100만원+50만원) = 666,667원
        B : 100만원 X 50만원/(100만원+50만원) = 333,333원
44) <배상책임에 따른 분담 예시>
   ○  피보험자 A 배상책임 비율 : 30%   
   ○  피보험자 B 배상책임 비율 : 70%
   ○  전체 대인배상책임 손해액 : 100만원
     ⇒ 각 피보험자별 배상책임    A : 30만원 B : 70만원
②  보험회사는 가지급금 청구에 관한 서류 등을 받았을 때에는 지체 없이 지급할 가지급액을 정하고 그 정하여진 
  날부터 7일 이내에 지급합니다.
③  보험회사가 정당한 사유 없이 가지급액을 정하는 것을 지연하거나 제②항에 정한 지급기일 내에 가지급금을 지
  급하지 않았을 때에는, 지급할 가지급금이 있는 경우 그 다음날부터 지급일까지의 기간에 대하여 보험개발원이 
  공시한 보험계약대출이율에 따라 연 단위 복리지식35)로 계산한 금액을 가지급금에 더하여 드립니다.
④  보험회사가 가지급금 청구에 관한 서류를 받은 때부터 10일 이내에 손해배상청구권자에게 가지급금을 지급하
  는 것을 거절하는 이유 또는 그 지급을 연기하는 이유(추가 조사가 필요한 때에는 확인이 필요한 사항과 확인이 
  종료되는 시기를 포함)를 서면(전자우편 등 서면에 갈음할 수 있는 통신수단을 포함)으로 통지하지 않는 경우, 
  정당한 사유 없이 가지급액을 정하는 것을 지연한 것으로 봅니다.
⑤  보험회사는 자동차손해배상보장법 등 관련 법령상 피보험자의 손해배상책임이 발생하지 않거나 이 약관상 보
  험회사의 보험금 지급책임이 발생하지 않는 것이 객관적으로 명백할 경우에는 가지급금을 지급하지 않을 수 있
  습니다. 
⑥  손해배상청구권자에게 지급한 가지급금은 장래 지급될 손해배상액에서 공제되나, 최종적인 손해배상액의 결정
  에는 영향을 주지 않습니다.
⑦  손해배상청구권자가 가지급금을 청구할 때는 손해배상을 청구하는 경우와 동일하게 제31조(제출 서류)에 정
  한 서류 등을 보험회사에 제출해야 합니다.
제33조 (보험금의 분담)  
대인배상ⅠㆍⅡ, 대물배상, 무보험자동차에 의한 상해, 자기신체사고, 자기차량손해에서는 다음과 같이 보험금을 
분담합니다.
 1. 이 보험계약과 보상책임의 전부 또는 일부가 중복되는 다른 보험계약(공제계약을 포함)이 있는 경우 : 다른 보
   험계약이 없는 것으로 가정하여 각각의 보험회사에 가입된 자동차 보험계약에 의해 산출한 보상책임액의 합
   계액이 손해액보다 많을 때에는 다음의 산식에 따라 산출한 보험금지식43)을 지급합니다.
제3장 보험금의 분담 등
손해액    X
이 보험계약에 의해 산출한 보상책임액
다른 보험계약이 없는 것으로 하여 각 보험계약에 의해 산출한 보상책임액의 합계액
 2. 이 보험계약의 대인배상Ⅰ, 대인배상Ⅱ, 대물배상에서 동일한 사고로 인하여 이 보험계약에서 배상책임이 있는 
   피보험자가 둘 이상 있는 경우에는 제10조(지급보험금의 계산)에 의한 보상한도와 범위에 따른 보험금을 각 
   피보험자의 배상책임의 비율에 따라 분담지식44)하여 지급합니다.
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
54
55
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (30, 1, 30, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
   것으로 봅니다.
 2.  전화를 이용하여 모집하는 경우 : 
   전화를 이용하여 청약내용, 보험료납입, 보험기간, 계약 전 알릴의무, 약관의 중요한 내용 등 계약 체결을 위하
   여 필요한 사항을 질문하거나 설명하는 방법. 이 경우 보험계약자의 답변과 확인내용을 음성 녹음함으로써 약
   관의 중요한 내용을 설명한 것으로 봅니다.
③  보험회사는 다음 각 호의 방법 중 계약자가 원하는 방법을 확인하여 지체 없이 약관 및 계약자 보관용 청약서를 
  제공하여 드립니다. 만약, 회사가 전자우편 및 전자적 의사표시로 제공한 경우 계약자 또는 그 대리인이 약관 및 
  계약자 보관용 청약서 등을 수신하였을 때에는 해당 문서를 드린 것으로 봅니다.
   1.  서면교부
   2.  우편 또는 전자우편
   3.  휴대전화 문자메시지 또는 이에 준하는 전자적 의사표시
④  다음 중 어느 하나에 해당하는 경우 보험계약자는 계약체결일부터 3개월 이내에 계약을 취소할 수 있습니다. 
  다만, 의무보험은 제외합니다.
 1.  보험계약자가 청약을 했을 때 보험회사가 보험계약자에게 약관 및 보험계약자 보관용 청약서(청약서 부본)를 
   드리지 않은 경우 
 2.  보험계약자가 청약을 했을 때 보험회사가 청약 시 보험계약자에게 약관의 중요한 내용을 설명하지 않은 경우
 3.  보험계약자가 보험계약을 체결할 때 청약서에 자필서명(*2)을 하지 않은 경우
⑤  제④항에 따라 계약이 취소된 경우 보험회사는 이미 받은 보험료를 보험계약자에게 돌려 드리며, 보험료를 받은 
  기간에 대하여 보험개발원이 공시한 보험계약대출이율에 따라 연 단위 복리로 계산한 금액을 더하여 지급합니
  다.
50)  “공탁금”이란 법령의 규정에 따라 금전䞱유가증권䞱그 밖의 물품을 공탁소에 맡기는 금액을 말합니다. 공탁을 하는 경우
   로는 채무를 갚으려고 하나 채권자가 이를 거부하거나 혹은 채권자를 알 수 없는 경우, 상대방에 대한 손해배상을 담보하
   기 위하여 하는 경우 등이 있습니다.
51) “회수청구권”이란 공탁금을 대출해준 보험회사가 갖는 권리로 공탁금(이자를 포함)에 대한 회수 권리를 말합니다.
52) “부본”이란 원본과 동일한 내용의 문서를 말합니다.
제40조 (설명서 교부 및 보험안내자료 등의 효력)
①  회사는 일반금융소비자에게 청약을 권유하거나 일반금융소비자가 설명을 요청하는 경우 보험상품에 관한 중요
  한 사항을 계약자가 이해할 수 있도록 설명하고 계약자가 이해하였음을 서명, 기명날인 또는 녹취 등을 통해 확
  인받아야 하며, 설명서를 제공하여야 합니다.
②  설명서, 약관, 청약서 부본 및 증권의 제공 사실에 관하여 계약자와 회사간에 다툼이 있는 경우에는 회사가 이를 
  증명하여야 합니다.
③  보험회사가 보험모집과정에서 제작ㆍ사용한 보험안내자료(서류ㆍ사진ㆍ도화 등 모든 안내자료를 포함)의 내용
  이 보험약관의 내용과 다른 경우에는 보험계약자에게 유리한 내용으로 보험계약이 성립된 것으로 봅니다.지식53)
제41조 (청약의 철회)
①  일반금융소비자(*1)는 보험증권을 받은 날부터 15일과 청약을 한 날부터 30일 중 먼저 도래하는 기간 내에 보
  험계약의 청약을 철회할 수 있습니다.
②  제①항에서 보험회사가 보험계약자에게 보험증권을 드린 것에 관해 다툼이 있으면 보험회사가 이를 증명합니
  다.
③ 제①항에도 불구하고 다음 중 어느 하나에 해당하는 경우에는 보험계약의 청약을 철회할 수 없습니다.
 1.  전문금융소비자(*1)가 보험계약의 청약을 한 경우
53) 보험모집과정에서 사용된 보험안내자료의 내용이 보험약관의 내용과 다른 경우에는 다음과 같이 적용하므로, 보험계약
   자의 불이익이 없도록 합니다.
    ① 그 다른 내용이 약관에 비해 보험계약자에게 유리한 경우 : 유리한 내용으로 보험계약이 체결된 것으로 적용
    ② 그 다른 내용이 약관에 비해 보험계약자에게 불리한 경우 : 약관에 따라 보험계약이 체결된 것으로 적용
(*1) ‘통신판매 보험계약’이란 보험회사가 전화ㆍ우편ㆍ컴퓨터통신 등 통신수단을 이용하여 모집하는 보험계약을 
   말합니다. 
(*2) “자필서명”에는 날인(도장을 찍음) 또는 전자서명법 제2조 제2호 193쪽)의 규정에 의한 방식을 포함합니다.
②  보험회사는 피보험자에 대하여 보상책임을 지는 한도(동일한 사고로 이미 지급한 보험금이나 가지급금이 있는 
  경우에는 그 금액을 공제한 금액. 이하 같음) 내에서 제①항의 절차에 협조하거나 대행합니다.
③  보험회사가 제①항의 절차에 협조하거나 대행하는 경우에는 피보험자는 보험회사의 요청에 따라 협력해야 합
  니다. 피보험자가 정당한 이유 없이 협력하지 않는 경우 그로 인하여 늘어난 손해는 보상하지 않습니다. 
④  보험회사는 다음의 경우에는 제①항의 절차를 대행하지 않습니다. 
 1. 피보험자가 손해배상청구권자에 대하여 부담하는 법률상의 손해배상책임액이 보험증권에 기재된 보험가입
   금액을 명백하게 초과하는 때
 2.  피보험자가 정당한 이유 없이 협력하지 않는 때
제37조 (공탁금의 대출) 
보험회사가 제36조(합의 등의 협조ㆍ대행) 제①항의 절차를 대행하는 경우에는, 피보험자에 대하여 보상책임을 
지는 한도에서 가압류나 가집행을 면하기 위한 공탁금지식50)을 피보험자에게 대출할 수 있으며 이에 소요되는 비용
을 보상합니다. 이 경우 대출금의 이자는 공탁금에 붙여지는 것과 같은 이율로 정하며, 피보험자는 공탁금(이자를 
포함)의 회수청구권지식51)을 보험회사에 양도해야 합니다.
제38조 (보험계약의 성립)  
①  이 보험계약은 보험계약자가 청약을 하고 보험회사가 승낙을 하면 성립합니다.
②  보험계약자가 청약을 할 때 ‘제1회 보험료(보험료를 분납하기로 약정한 경우)’ 또는 ‘보험료 전액(보험료를 일
  시에 지급하기로 약정한 경우)’(이하 ‘제1회 보험료 등’이라 함)을 지급하였을 때, 보험회사가 이를 받은 날부
  터 15일 이내에 승낙 또는 거절의 통지를 발송하지 않으면 승낙한 것으로 봅니다.
③  보험회사가 청약을 승낙했을 때에는 지체 없이 보험증권을 보험계약자에게 드립니다. 그러나 보험계약자가 
  제1회 보험료 등을 지급하지 않은 경우에는 보험증권을 드리지 않습니다. 
④  보험계약이 성립되면 보험회사는 제42조(보험기간)에 따라 보험기간의 첫 날부터 보상책임을 집니다. 다만, 보
  험계약자로부터 제1회 보험료 등을 받은 경우에는, 그 이후 승낙 전에 발생한 사고에 대해서도 청약을 거절할 
  사유가 없는 한 보상합니다.
제39조 (약관 교부 및 설명의무 등)  
①  보험회사는 보험계약자가 청약을 한 경우 보험계약자에게 약관 및 보험계약자 보관용 청약서(청약서 
  부본지식52))를 드리고 약관의 중요한 내용을 설명하여 드립니다. 
②  통신판매 보험계약(*1)에서 보험회사는 보험계약자의 동의를 받아 다음 중 어느 하나의 방법으로 약관을 발급하
  고 중요한 내용을 설명하여 드립니다.
 1.  사이버몰(컴퓨터를 이용하여 보험거래를 할 수 있도록 설정된 가상의 영업장)을 이용하여 모집하는 경우 : 
   사이버몰에서 약관 및 그 설명문(약관의 중요한 내용을 알 수 있도록 설명한 문서)을 읽거나 내려 받게 하는 
   방법. 이 경우 보험계약자가 이를 읽거나 내려 받은 것을 확인한 때에는 약관을 드리고 중요한 내용을 설명한 
제4편 일반사항
제1장 보험계약의 성립
56
57
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (31, 1, 31, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
55) “공동불법행위”란 여러 사람이 공동으로 불법행위를 하여 타인에게 손해를 가하는 행위를 말하는 것으로서, 이 경우 불
   법행위를 한 사람들은 “연대채무자”가 됩니다.
   “연대채무자”란 동일한 손해배상의 책임에 대하여 발생한 여러 명의 채무자를 말하는 것으로, 그 중 한 사람이 손해배상
   의 전부를 감당하면 모든 채무자의 채무가 소멸하게 됩니다.
   “상호간의 구상권”이란 연대채무자 중 한 사람이 채무를 이행한 경우에는, 대신하여 변제한 다른 연대채무자의 부담부분
   에 대하여 상환을 청구할 수 있는 권리를 말합니다.
(*1) ‘자동차보험에 처음 가입하는 자동차’란 자동차 판매업자 또는 그 밖의 양도인 등으로부터 매수인 또는 양수인
   에게 인도된 날부터 10일 이내에 처음으로 그 매수인 또는 양수인을 기명피보험자로 하는 자동차보험에 가입
   하는 신차 또는 중고차를 말합니다. 다만, 피보험자동차의 양도인이 맺은 보험계약을 양수인이 승계한 후 그 
   보험기간이 종료되어 이 보험계약을 맺은 경우를 제외합니다.
제43조 (사고발생지역)  
보험회사는 대한민국(북한지역을 포함) 안에서 생긴 사고에 대하여 보험계약자가 가입한 보장종목에 따라 보상해 
드립니다.
제44조 (계약 전 알릴 의무)  
①  보험계약자는 청약을 할 때 다음의 사항에 관해서 알고 있는 사실을 보험회사에 알려야 하며, 제3호의 경우에는 
  기명피보험자의 동의가 필요합니다.
 1.  피보험자동차의 검사에 관한 사항
 2.  피보험자동차의 용도, 차량종류, 등록번호(이에 준하는 번호도 포함하며 이하 같음), 차명, 연식, 적재정량, 
   구조 등 피보험자동차에 관한 사항
 3.  기명피보험자의 성명, 연령 등에 관한 사항
 4.  그 밖에 보험청약서에 기재된 사항 중에서 보험료의 계산에 영향을 미치는 사항
②  보험회사는 이 보험계약을 맺은 후 보험계약자가 계약 전 알릴 의무를 위반한 사실이 확인되었을 때에는 추가보
  험료를 더 내도록 청구하거나, 제53조(보험회사의 보험계약 해지) 제①항 제1호, 제4호에 따라 해지할 수 있습
  니다.
제45조 (계약 후 알릴 의무)  
①  보험계약자는 보험계약을 맺은 후 다음의 사실이 생긴 것을 알았을 때에는 지체 없이 보험회사에 그 사실을 알
  리고 승인을 받아야 합니다. 이 경우 그 사실에 따라 보험료가 변경되는 경우 보험회사는 보험료를 더 받거나 돌
  려주고 계약을 승인하거나, 제53조(보험회사의 보험계약 해지) 제①항 제2호, 제4호에 따라 해지할 수 있습니
  다.
 1.  용도, 차량종류, 등록번호, 적재정량, 구조 등 피보험자동차에 관한 사항이 변경된 사실
 2.  피보험자동차에 화약류, 고압가스, 폭발물, 인화물 등 위험물을 싣게 된 사실
 3.  그 밖에 위험이 뚜렷이 증가하는 사실이나 적용할 보험료에 차이가 발생한 사실
②  보험계약자는 보험증권에 기재된 주소 또는 연락처가 변경된 때에는 지체 없이 보험회사에 알려야 합니다. 보험
  계약자가 이를 알리지 않으면 보험회사가 알고 있는 최근의 주소로 알리게 되므로 불이익을 당할 수 있습니다.
제46조 (사고발생 시 의무)  
①  보험계약자 또는 피보험자는 사고가 생긴 것을 알았을 때에는 다음의 사항을 이행해야 합니다.
 1.  지체 없이 손해의 방지와 경감에 힘쓰고, 다른 사람으로부터 손해배상을 받을 수 있는 권리가 있는 경우에는 
   그 권리(공동불법행위에서 연대채무자 상호간의 구상권지식55)을 포함하며 이하 같음)의 보전과 행사에 필요한 
   절차를 밟아야 합니다.
 2.  다음 사항을 보험회사에 지체 없이 알려야 합니다. 
  가. 사고가 발생한 때, 곳, 상황(출䞱퇴근 시 승용차 함께 타기 등) 및 손해의 정도
  나. 피해자 및 가해자의 성명, 주소, 전화번호
  다. 사고에 대한 증인이 있을 때에는 그의 성명, 주소, 전화번호
  라. 손해배상의 청구를 받은 때에는 그 내용 
제2장 보험계약자 등의 의무
④  청약철회는 계약자가 전화로 신청하거나, 철회의사를 표시하기 위한 서면, 전자우편, 휴대전화 문자메시지 또
  는 이에 준하는 전자적 의사표시(이하 ‘서면 등’이라 합니다)를 발송한 때 효력이 발생합니다. 계약자는 서면 등
  을 발송한 때에 그 발송 사실을 회사에 지체없이 알려야 합니다.
⑤  보험회사는 보험계약자의 청약 철회를 접수한 날부터 3영업일 이내에 받은 보험료를 보험계약자에게 돌려 드립
  니다.
⑥  청약을 철회할 당시에 이미 보험사고가 발생했으나 보험계약자가 보험사고가 발생한 사실을 알지 못한 경우에
  는 청약 철회의 효력은 발생하지 않습니다.
⑦  보험회사가 제⑤항의 보험료 반환기일을 지키지 못하는 경우, 반환기일의 다음날부터 반환하는 날까지의 기간
  은 보험개발원이 공시한 보험계약대출이율에 따라 연 단위 복리로 계산한 금액을 더하여 돌려 드립니다. 다만, 
  계약자가 제1회 보험료를 신용카드로 납입한 계약의 청약을 철회하는 경우에 회사는 청약의 철회를 접수한 날
  부터 3영업일 이내에 해당 신용카드회사로 하여금 대금청구를 하지 않도록 해야 하며, 이 경우 회사는 보험료를 
  반환한 것으로 봅니다.
제42조 (보험기간)  
보험회사가 피보험자에 대해 보상책임을 지는 보험기간지식54)은 다음과 같습니다.
구 분
보험기간
1. 원칙
2. 예외 :
 자동차보험에 처음 가입하는 
 자동차(*1) 및 의무보험
보험증권에 기재된   보험기간의 첫날 24시부터 마지막 날 24시까지. 다만, 의
무보험(책임공제를 포함)의 경우 전(前) 계약의 보험기간과 중복되는 경우에
는 전 계약의 보험기간이 끝나는 시점부터 시작합니다.
보험료를 받은 때부터 마지막 날 24시까지. 다만, 보험증권에 기재된 보험기간 
이전에 보험료를 받았을 경우에는 그 보험기간의 첫날 0시부터 시작합니다.
54) 보험기간의 예시는 아래와 같습니다. 
   <예시> 보험기간 첫날(시기) : 2015. 1. 1 / 보험기간 마지막날(종기) : 2016. 1. 1
2015. 1. 1
2016. 1. 1
00:00
00:00
24:00
365일
24:00
(*1) ‘일반금융소비자’라 함은 전문금융소비자가 아닌 계약자를 말합니다.
(*2) ‘전문금융소비자’라 함은 보험계약에 관한 전문성, 자산규모 등에 비추어 보험계약에 따른 위험감수능력이 있
   는 자로서, 국가, 지방자치단체, 한국은행, 금융회사, 주권상장법인 등을 포함하며 금융소비자 보호에 관한 법률 
   제2조(정의) 제9호180쪽)에서 정하는 전문금융소비자를 말합니다.
 2.  자동차손해배상보장법에 따른 의무보험(다만, 일반금융소비자가 동종의 다른 의무보험에 가입한 경우는 제
   외)
 3.  보험기간이 90일 이내인 보험계약
58
59
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (32, 1, 32, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
  험계약도 승계된 것으로 봅니다. 다만, 보험기간이 종료되거나 자동차의 명의를 변경하는 경우에는 법정상속인
  을 보험계약자 또는 기명피보험자로 하는 새로운 보험계약을 맺어야 합니다.
제49조 (피보험자동차의 교체)    
①  보험계약자 또는 기명피보험자가 보험기간 중에 기존의 피보험자동차를 폐차 또는 양도한 다음 그 자동차와 동
  일한 차량종류의 다른 자동차로 교체한 경우에는, 보험계약자가 이 보험계약을 교체된 자동차에 승계시키고자 
  한다는 뜻을 서면 등으로 보험회사에 통지하여 보험회사가 승인한 때부터 이 보험계약이 교체된 자동차에 적용
  됩니다. 이 경우 기존의 피보험자동차에 대한 보험계약의 효력은 보험회사가 승인할 때에 상실됩니다. 
②  보험회사가 서면 등의 방법으로 통지를 받은 날부터 10일 이내에 제①항에 의한 승인 여부를 보험계약자에게 
  통지하지 않으면, 그 10일이 되는 날의 다음날 0시에 승인한 것으로 봅니다.
③  제①항에서 규정하는 ‘동일한 차량종류의 다른 자동차로 교체한 경우’란 개인소유 자가용 승용자동차 간에 교체
  한 경우를 말합니다. 
④  보험회사가 제①항의 승인을 하는 경우에는 교체된 자동차에 적용하는 보험요율에 따라 보험료의 차이가 나는 
  경우 보험계약자에게 남는 보험료를 돌려드리거나 추가보험료를 청구할 수 있습니다. 이 경우 기존의 피보험자
  동차를 말소등록한 날 또는 소유권을 이전등록한 날부터 승계를 승인한 날의 전날까지의 기간에 해당하는 보험
  료를 일할로 계산하여 보험계약자에게 돌려드립니다.
⑤  보험회사가 제①항의 승인을 거절한 경우 교체된 자동차를 사용하다가 발생한 사고는 보험금을 지급하지 않습
  니다.
<예시> 일할계산의 사례
기납입보험료 총액    X
해당기간
365(윤년 : 366)
제50조 (보험계약의 취소)  
보험회사가 보험계약자 또는 피보험자의 사기에 의해 보험계약을 체결한 점을 증명한 경우, 보험회사는 보험기간
이 시작된 날부터 6개월 이내(사기 사실을 안 날부터는 1개월 이내)에 계약을 취소할 수 있습니다.
제51조 (보험계약의 효력 상실)  
보험회사가 파산선고를 받은 날부터 보험계약자가 보험계약을 해지하지 않고 3개월이 경과하는 경우에는 보험계
약이 효력을 상실합니다.
제52조 (보험계약자의 보험계약 해지ㆍ해제)지식59)  
①  보험계약자는 언제든지 임의로 보험계약의 일부 또는 전부를 해지할 수 있습니다. 다만, 의무보험은 다음 중 어
  느 하나에 해당하는 경우에만 해지할 수 있습니다.
 1.  피보험자동차가 자동차손해배상보장법 제5조 제4항190쪽)에 정한 자동차(의무보험 가입대상에서 제외되거나 
   도로가 아닌 장소에서만 운행하는 자동차)로 변경된 경우
 2.  피보험자동차를 양도한 경우. 다만, 제48조(피보험자동차의 양도) 또는 제49조(피보험자동차의 교체)에 따
   라 보험계약이 양수인 또는 교체된 자동차에 승계된 경우에는 의무보험에 대한 보험계약을 해지할 수 없습니
   다.
 3.  피보험자동차의 말소등록으로 운행을 중지한 경우. 다만, 제49조 (피보험자동차의 교체)에 따라 보험계약이 
   교체된 자동차에 승계된 경우에는 의무보험에 대한 보험계약을 해지할 수 없습니다.
 4.  천재지변, 교통사고, 화재, 도난 등의 사유로 인하여 피보험자동차를 더 이상 운행할 수 없게 된 경우. 다만, 
   제49조(피보험자동차의 교체)에 따라 보험계약이 교체된 자동차에 승계된 경우에는 의무보험에 대한 보험계
   약을 해지할 수 없습니다.
56) “양수인”은 타인의 권리, 재산 등을 넘겨받는 사람을 말합니다. 반대로 “양도인”은 권리, 재산 등을 타인에게 넘겨주는 
   사람을 말합니다. 
57) “피보험자”란 기명피보험자 및 기명피보험자 이외의 피보험자를 포함합니다.
58) 보험회사가 보험계약자가 통지한 사항에 대하여 “승인”하지 않은 경우, 피보험자동차가 양도된 이후부터 승인되기 전까
   지 발생된 사고에 대해서는 보험금을 지급하지 않습니다.
59) “해지”란 계속적인 계약관계를 해당시점부터 장래에 대하여 소멸시키는 것을 말합니다. 
   “해제”는 계약의 효력을 소급하여 과거부터 소멸시키는 것으로, 계약의 효력이 소멸시점부터 없었던 것과 같은 법률효과
   를 발생시킨다는 점에서 해지와 구별됩니다.
 3.  손해배상의 청구를 받은 경우에는 미리 보험회사의 동의 없이 그 전부 또는 일부를 합의해서는 안 됩니다. 
   그러나 피해자의 응급치료, 호송 그 밖의 긴급조치는 보험회사의 동의가 필요하지 않습니다.
 4.  손해배상청구의 소송을 제기하려고 할 때 또는 제기 당한 때에는 지체 없이 보험회사에 알려야 합니다.
 5.  피보험자동차를 도난당했을 때에는 지체 없이 그 사실을 경찰관서에 신고해야 합니다.
 6.  보험회사가 사고를 증명하는 서류 등 꼭 필요하다고 인정하는 자료를 요구한 경우에는 지체 없이 이를 제출해
   야 하며, 또한 보험회사가 사고에 관해 조사하는 데 협력해야 합니다.
②  보험회사는 보험계약자 또는 피보험자가 정당한 이유 없이 제①항에서 정한 사항을 이행하지 않은 경우 그로 인
  하여 늘어난 손해액이나 회복할 수 있었을 금액을 보험금에서 공제하거나 지급하지 않습니다.
제47조 (보험계약 내용의 변경)  
①  보험계약자는 의무보험을 제외하고는 보험회사의 승낙을 받아 다음에 정한 사항을 변경할 수 있습니다. 이 경우 
  승낙을 서면 등으로 알리거나 보험증권의 뒷면에 기재하여 드립니다.
 1.  보험계약자. 다만, 보험계약자가 이 보험계약의 권리ㆍ의무를 피보험자동차의 양수인지식56)에게 이전함에 따
   라 보험계약자가 변경되는 경우에는 제48조(피보험자동차의 양도)에 따릅니다.
 2.  보험가입금액, 특별약관 등 그 밖의 계약의 내용
②  보험회사는 제①항에 따라 계약내용의 변경으로 보험료가 변경된 경우 보험계약자에게 보험료를 돌려드리거나 
  추가보험료를 청구할 수 있습니다. 
③  보험계약 체결 후 보험계약자가 사망한 경우 이 보험계약에 의한 보험계약자의 권리ㆍ의무는 사망시점에서의 
  법정상속인에게 이전합니다.
제48조 (피보험자동차의 양도)   
①  보험계약자 또는 기명피보험자가 보험기간 중에 피보험자동차를 양도한 경우에는 이 보험계약으로 인하여 생
  긴 보험계약자 및 피보험자지식57)의 권리와 의무는 피보험자동차의 양수인지식56)에게 승계되지 않습니다. 그러나 
  보험계약자가 이 권리와 의무를 양수인에게 이전하고자 한다는 뜻을 서면 등으로 보험회사에 통지하여 보험회
  사가 승인한 경우에는 그 승인한 때부터 양수인에게 이 보험계약을 적용합니다.
②  보험회사가 제①항에 의한 보험계약자의 통지를 받은 날부터 10일 이내에 승인지식58) 여부를 보험계약자에게 통
  지하지 않으면, 그 10일이 되는 날의 다음날 0시에 승인한 것으로 봅니다.
③  제①항에서 규정하는 피보험자동차의 양도에는 소유권을 유보한 매매계약에 따라 자동차를 ‘산 사람’ 또는 대차
  계약에 따라 자동차를 ‘빌린 사람’이 그 자동차를 피보험자동차로 하고, 자신을 보험계약자 또는 기명피보험자
  로 하는 보험계약이 존속하는 동안에 그 자동차를 ‘판 사람’ 또는 ‘빌려준 사람’에게 돌려주는 경우도 포함합니
  다. 이 경우 ‘판 사람’ 또는 ‘빌려준 사람’은 양수인으로 봅니다.
④  보험회사가 제①항의 승인을 하는 경우에는 피보험자동차의 양수인에게 적용되는 보험요율에 따라 보험료의 
  차이가 나는 경우 피보험자동차가 양도되기 전의 보험계약자에게 남는 보험료를 돌려드리거나, 피보험자동차
  의 양도 후의 보험계약자에게 추가보험료를 청구합니다.
⑤  보험회사가 제①항의 승인을 거절한 경우 피보험자동차가 양도된 후에 발생한 사고는 보험금을 지급하지 않습
  니다.
⑥  보험계약자 또는 기명피보험자가 보험기간 중에 사망하여 법정상속인이 피보험자동차를 상속하는 경우 이 보
제3장 보험계약의 변동 및 보험료의 환급
60
61
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (33, 1, 33, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
  가. 보험계약을 맺은 때에 보험회사가 보험계약자가 알려야 할 사실을 알고 있었거나 과실로 알지 못하였을 때
  나. 보험계약자가 보험금을 지급할 사고가 발생하기 전에 보험청약서의 기재사항에 대하여 서면으로 변경을 신
    청하여 보험회사가 이를 승인했을 때
  다. 보험회사가 보험계약을 맺은 날부터 보험계약을 해지하지 않고 6개월이 경과한 때
  라. 보험을 모집한 자(이하 “보험설계사 등”이라 합니다)가 보험계약자 또는 피보험자에게 계약 전 알릴 의무를 
    이행할 기회를 부여하지 않았거나 보험계약자 또는 피보험자가 사실대로 알리는 것을 방해한 경우, 또는 보
    험계약자 또는 피보험자에 대해 사실대로 알리지 않게 하였거나 부실하게 알리도록 권유했을 때. 다만, 보험
    설계사 등의 행위가 없었다 하더라도 보험계약자 또는 피보험자가 사실대로 알리지 않거나 부실하게 알린 
    것으로 인정되는 경우에는 회사는 보험계약을 해지할 수 있습니다.
  마. 보험계약자가 알려야 할 사항이 보험회사가 위험을 측정하는 데 관련이 없을 때 또는 적용할 보험료에 차액
    이 생기지 않은 때
 2.  보험계약자가 보험계약을 맺은 후에 제45조(계약 후 알릴 의무) 제①항에 정한 사실이 생긴 것을 알았음에도 
   불구하고 지체 없이 알리지 않거나 사실과 다르게 알린 경우. 다만, 보험계약자가 알려야 할 사실이 뚜렷하게 
   위험을 증가시킨 것이 아닌 때에는 보험회사가 보험계약을 해지할 수 없습니다. 
 3.  보험계약자가 정당한 이유 없이 법령에 정한 자동차검사를 받지 않은 경우
 4.  보험회사가 제44조(계약 전 알릴 의무) 제②항, 제45조(계약 후 알릴 의무) 제①항, 제48조(피보험자동차의 
   양도) 제④항, 제49조(피보험자동차의 교체) 제④항에 따라 추가보험료를 청구한 날부터 14일 이내지식63)에 
   보험계약자가 그 보험료를 내지 않은 경우. 다만, 다음 중 어느 하나에 해당하는 경우 보험회사는 보험계약을 
   해지할 수 없습니다.
  가. 보험회사가 제44조(계약 전 알릴의무) 제①항에서 규정하는 계약 전 알릴 의무 위반 사실을 안 날부터 1개
    월이 지난 경우
  나. 보험회사가 보험계약자로부터 제45조(계약 후 알릴 의무) 제①항에서 정하는 사실을 통지받은 후 1개월이 
    지난 경우
 5.  보험금의 청구에 관하여 보험계약자, 피보험자, 보험금을 수령하는 자 또는 이들의 법정대리인의 사기행위가 
   발생한 경우.
②  보험회사는 보험계약자가 계약 전 알릴 의무 또는 계약 후 알릴 의무를 이행하지 않아서 제①항 제1호 또는 제2
  호에 따라 보험계약을 해지한 때에는 해지 이전에 생긴 사고도 보상하지 않으며, 이 경우 보험회사는 지급한 보
  험금의 반환을 청구할 수 있습니다. 다만, 계약 전 알릴 의무 또는 계약 후 알릴 의무를 위반한 사실이 사고의 발
  생에 영향을 주지 않았음이 증명된 때에는 보험회사는 보상합니다.
③  보험회사는 보험계약자가 다른 보험의 가입내역을 알리지 않거나 사실과 다르게 알렸다는 이유로 계약을 해지
  하거나 보험금 지급을 거절하지 않습니다.
제54조 (보험료의 환급 등)  
①  보험기간이 시작되기 전에 보험료가 변경된 때에는 변경 전 보험료와 변경 후 보험료의 차액을 더 받거나 돌려
  드립니다.
②  보험회사의 고의ㆍ과실지식62)로 보험료가 적정하지 않게 산정되어 보험계약자가 적정보험료를 초과하여 납입한 
  경우, 보험회사는 이를 안 날 또는 보험계약자가 반환을 청구한 날부터 3일 이내에 적정보험료를 초과하는 금액 
  및 이에 대한 이자(납입한 날부터 반환하는 날까지의 기간에 대해 보험개발원이 공시한 보험계약대출이율에 따
  라 연 단위 복리지식35)로 계산한 금액)를 돌려드립니다. 다만, 보험회사에게 고의ㆍ과실이 없을 경우에는 적정보
  험료를 초과한 금액만 돌려드립니다.
③  보험회사는 보험계약이 취소되거나 해지지식59)된 때, 또는 그 효력이 상실된 때에는 다음과 같이 보험료를 돌려
60) 동일한 차량에 대해서 자동차보험 의무보험이나 또는 공제계약(예 : 택시공제 등)을 보험기간이 같거나 보험기간 중 일
   부가 중복되도록 체결한 경우, 의무보험의 중복가입으로 해지할 수 있다는 내용입니다.
61) “타인을 위한 보험계약”이란 타인의 이익을 위하여 보험계약을 체결한 경우로서 예를 들어 A(계약자)가 자신의 친구
   B(기명피보험자)를 위해서 자동차보험을 체결해준 경우 등에 해당합니다.  이 경우 보험계약자는 다음 중 하나에 해당할 
   경우에만 약관에 따라 해지 또는 해제를 할 수 있습니다. 
    ① 타인(기명피보험자)의 동의를 받은 경우
    ② 보험증권을 가지고 있는 경우
62) 고의와 중대한 과실에 대한 정의는 사안의 내용마다 해석되야 합니다. 다만, 통상의 의미는 다음과 같습니다.
   “고의” 
   과실과 달리 자기의 행위가 일정한 결과를 발생시킬 것을 인식하고 또 이 결과의 발생을 용인하는 것을 말합니다.
   “중대한 과실”
   “과실”은 민법상 선량한 관리자의 주의가 부족한 것을 말하며, 주의의무(注意義務) 위반의 정도가 경미한 경우를 말합니
   다. 반면, 주의의무 위반의 정도가 일반인의 상식으로는 이해할 수 없을 정도로 현저하게 큰 경우를 “중대한 과실”로 규
   정하고 있습니다.
63) 제4호에서 언급한 “제44조 제②항, 제45조 제①항, 제48조 제④항, 제49조 제④항”은 계약 전/후 알릴의무 위반 또는 
   피보험자동차의 양도/교체로 인한 “추가보험료의 납입 또는 환급”에 대한 내용입니다. 즉, 추가보험료가 발생된 경우 보
   험계약자는 회사의 청구에 따라 청구한 날부터 14일 이내에 보험료를 납입해야 한다는 점을 말하고 있습니다.
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
 5.  이 보험계약을 맺은 후에 피보험자동차에 대하여 이 보험계약과 보험기간의 일부 또는 전부가 중복되는 의무
   보험이 포함된 다른 보험계약(공제계약을 포함)을 맺은 경우지식60)
 6.  보험회사가 파산선고를 받은 경우
 7.  자동차손해배상보장법 제5조의 2190쪽)에서 정하는 ‘보험 등의 가입의무 면제’ 사유에 해당하는 경우
 8. 자동차해체재활용업자가 해당 자동차䞱자동차등록증䞱등록번호판 및 봉인을 인수하고 그 사실을 증명하는 서
   류를 발급한 경우 
②  이 보험계약이 의무보험만 체결된 경우로서, 이 보험계약을 맺기 전에 피보험자동차에 대하여 의무보험이 포함
  된 다른 보험계약(공제계약을 포함하며 이하 같음)이 유효하게 맺어져 있는 경우에는, 보험계약자는 그 다른 보
  험계약이 종료하기 전에 이 보험계약을 해제할 수 있습니다. 만일, 그 다른 보험계약이 종료된 후에는 그 종료일 
  다음날부터 보험기간이 개시되는 의무보험이 포함된 새로운 보험계약을 맺은 경우에만 이 보험계약을 해제할 
  수 있습니다.
③  타인을 위한 보험계약에서 보험계약자는 기명피보험자의 동의를 받거나 보험증권을 소지한 경우에만 제①항 
  또는 제②항에 따라 보험계약을 해지하거나 또는 해제할 수 있습니다.지식61)
제52조의 2 (위법계약의 해지)   
①  계약자는 금융소비자 보호에 관한 법률 제47조 및 관련규정이 정하는 바에 따라 계약체결에 대한 회사의 법위
  반사항이 있는 경우 계약체결일부터 5년 이내의 범위에서 계약자가 위반사항을 안 날부터 1년 이내에 계약해지
  요구서에 증빙서류를 첨부하여 위법계약의 해지를 요구할 수 있습니다. 다만, 자동차손해배상 보장법에 따른 의
  무보험에 대해 해지 요구를 할 때에는 동종의 다른 의무보험에 가입되어 있는 경우에만 해지할 수 있습니다.
②  회사는 해지요구를 받은 날부터 10일 이내에 수락여부를 계약자에 통지하여야 하며, 거절할 때에는 거절 사유
  를 함께 통지하여야 합니다.
③  계약자는 회사가 정당한 사유 없이 제①항의 요구를 따르지 않는 경우 해당 계약을 해지할 수 있습니다.
④  제①항 및 제③항에 따라 계약이 해지된 경우 회사는 제54조(보험료의 환급 등) 제③항 제1호에 따른 보험료를 
  계약자에게 지급합니다.
⑤  계약자는 제①항에 따른 제척기간에도 불구하고 민법 등 관계 법령에서 정하는 바에 따라 법률상의 권리를 행사
  할 수 있습니다. 
제53조 (보험회사의 보험계약 해지)   
①  보험회사는 다음 중 어느 하나에 해당하는 경우가 발생했을 때, 그 사실을 안 날부터 1개월 이내에 보험계약을 
  해지할 수 있습니다. 다만, 제1호ㆍ제2호ㆍ제4호ㆍ제5호에 의한 계약해지는 의무보험에 적용하지 않습니다.
 1.  보험계약자가 보험계약을 맺을 때 고의 또는 중대한 과실지식62)로 제44조(계약 전 알릴 의무) 제①항의 사항
   에 관하여 알고 있는 사실을 알리지 않거나 사실과 다르게 알린 경우. 다만, 다음 중 어느 하나에 해당하는 경
   우 보험회사는 보험계약을 해지할 수 없습니다.
62
63
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (34, 1, 34, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
제57조 (피보험자동차 등에 대한 조사)  
보험회사는 피보험자동차 등에 관하여 필요한 조사를 하거나 보험계약자 또는 피보험자에게 필요한 설명 또는 증
명을 요구할 수 있습니다. 이 경우 보험계약자, 피보험자 또는 이들의 대리인은 이러한 조사 또는 요구에 협력해야 
합니다.
제58조 (예금보험기금에 의한 보험금 등의 지급보장)  
보험회사가 파산 등으로 인하여 보험금 등을 지급하지 못할 경우에는 예금자보호법에서 정하는 바지식65)에 따라 그 
지급을 보장합니다.
제59조 (보험사기행위 금지)  
보험계약자, 피보험자, 피해자 등이 보험사기행위를 행한 경우 관련 법령에 따라 형사처벌 등을 받을 수 있습니다.
제60조 (분쟁의 조정)  
①  이 보험계약의 내용 또는 보험금의 지급 등에 관하여 보험회사와 보험계약자, 피보험자, 손해배상청구권자, 그 
  밖에 이해관계에 있는 자 사이에 분쟁이 있을 경우에는 금융감독원에 설치된 금융분쟁조정위원회의 조정을 받
  을 수 있으며, 분쟁조정 과정에서 계약자는 관계 법령이 정하는 바에 따라 회사가 기록 및 유지ㆍ관리하는 자료
  의 열람(사본의 제공 또는 청취를 포함한다)을 요구할 수 있습니다.
②  회사는 일반금융소비자인 계약자가 조정을 통하여 주장하는 권리나 이익의 가액이 금융소비자 보호에 관한 법
  률 제42조에서 정하는 일정 금액 이내인 분쟁사건에 대하여 조정절차가 개시된 경우에는 관계 법령이 정하는 
  경우를 제외하고는 소를 제기하지 않습니다.
제61조(관할법원) 
이 보험계약에 관한 소송 및 민사조정은 보험회사의 본점 또는 지점 소재지 중 보험계약자 또는 피보험자가 선택하
는 대한민국 내의 법원을 합의에 따른 관할법원으로 합니다.
제62조(준용규정)  
이 계약은 대한민국 법에 따라 규율되고 해석되며, 약관에서 정하지 않은 사항은 금융소비자 보호에 관한 법률, 상
법, 민법 등 관계 법령을 따릅니다다.지식66)
64) “일단위로 계산한 보험료”란 효력이 상실되거나 해지된 경우, 해당 날로부터 보험 만료일까지 남은 기간에 대한 보험료
   를 말하는 것입니다. 
   <예시> 보험기간 1년, 해지일로부터 보험 만료일까지 남은기간 100일인 경우 
       ⇒ 1년 보험료 X 100/365일 = 일단위로 계산한 보험료
65) 예금자보호법에 따라 예금보험공사가 보호하되, 보호한도는 본 보험회사에 있는 보험계약자의 모든 예금보호대상 금융
   상품의 해약환급금(또는 만기 시 보험금이나 사고보험금)에 기타지급금을 합하여 1인당 “최고 5천만원”이며, 5천만원
   을 초과하는 나머지 금액은 보호되지 않습니다.(개인 계약자에 한함)
66) 약관은 보험계약자와 보험회사간의 계약관계를 나타내는 것으로, 약관에서 정하지 않은 것은 상법, 민법 등 대한민국의 
   관련 법령에 따라 판단하여 적용한다는 것을 말합니다.
제55조 (약관의 해석)  
①  보험회사는 신의성실의 원칙에 따라 공정하게 약관을 해석해야 하며 보험계약자에 따라 다르게 해석하지 않습
  니다.
②  보험회사는 약관의 뜻이 명백하지 않은 경우에는 보험계약자에게 유리하게 해석합니다.
③  보험회사는 보상하지 않는 손해 등 보험계약자나 피보험자에게 불리하거나 부담을 주는 내용은 확대하여 해석
  하지 않습니다.
제56조 (보험회사의 개인정보이용 및 보험계약 정보의 제공)  
①  보험회사는 제27조(제출서류) 제5호, 제6호의 배상의무자의 개인정보와 제46조(사고발생 시 의무) 제2호 
  나목, 다목의 피해자, 가해자 및 증인의 개인정보를 보험사고의 처리를 위한 목적으로만 이용할 수 있습니다.
②  보험회사는 보험계약에 의한 의무의 이행 및 관리를 위한 판단자료로 활용하기 위하여 개인정보보호법 제15조, 
  제17조, 제22조부터 제24조까지의 규정179쪽), 신용정보의 이용 및 보호에 관한 법률 제32조, 같은 법 시행령 
  제28조187쪽)에서 정하는 절차에 따라 보험계약자와 피보험자의 동의를 받아 다음의 사항을 다른 보험회사 및 보
  험관계단체에 제공할 수 있습니다.
 1.  기명피보험자의 성명, 주민등록번호 및 주소와 피보험자동차의 차량번호, 형식, 연식
 2.  계약일시, 보험종목, 보장종목, 보험가입금액, 자기부담금 및 보험료 할인ㆍ할증에 관한 사항, 특별약관의 
   가입사항, 계약해지 시 그 내용 및 사유
 3.  사고일시 또는 일자, 사고내용 및 각종 보험금의 지급내용 및 사유 
제4장 그 밖의 사항
  드립니다.
 1.  보험계약자 또는 피보험자의 책임 없는 사유에 의하는 경우 : 제39조(약관 교부 및 설명의무 등) 제④항에 의
   해 계약이 취소된 때에는 보험회사에 납입한 보험료의 전액, 효력 상실되거나 해지(제52조의2에 따른 위법계
   약 해지를 포함한다)된 경우에는 경과하지 않은 기간에 대하여 일단위로 계산한 보험료지식64)
 2.  보험계약자 또는 피보험자에게 책임이 있는 사유에 의하는 경우 : 
   이미 경과한 기간에 대하여 단기요율로 계산한 보험료를 뺀 잔액
 3.  보험계약이 해지(제52조의2에 따른 위법계약 해지를 포함한다)된 경우, 계약을 해지하기 전에 보험회사가 
   보상하여야 하는 사고가 발생한 때에는 보험료를 환급하지 않습니다.
④  제③항에서 ‘보험계약자 또는 피보험자에게 책임이 있는 사유’란 다음의 경우를 말합니다.
 1.  보험계약자 또는 피보험자가 임의 해지하는 경우(의무보험의 해지는 제외)
 2.  보험회사가 제50조(보험계약의 취소) 또는 제53조(보험회사의 보험계약 해지)에 따라 보험계약을 취소하거
   나 해지하는 경우
 3.  보험료 미납으로 인한 보험계약의 효력 상실
⑤  보험계약이 해제지식59)된 경우에는 보험료 전액을 환급합니다.
⑥  이 약관에 따라 보험회사가 보험계약자가 낸 보험료의 전부 또는 일부를 돌려드리는 경우에는 보험료를 반환할 
  의무가 생긴 날부터 3일 이내에 드립니다.
⑦  보험회사가 제⑥항의 반환기일이 지난 후 보험료를 돌려드리는 경우에는 반환기일의 다음 날부터 돌려드리는 
  날까지의 기간은 보험개발원이 공시한 보험계약대출이율에 따라 연 단위 복리지식35)로 계산한 금액을 더하여 돌
  려드립니다. 다만, 이 약관에서 이자의 계산에 관해 달리 정하는 경우에는 그에 따릅니다.
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
64
65
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (35, 1, 35, '<별표1> 대인배상, 무보험자동차에 의한 상해 지급기준
가. 사망  
각 보장종목별 보험가입금액 한도 내에서 다음의 금액을 지급함.
※ 지급기준에 등장하는 “연령(나이)”은 사고발생일을 기준으로 한 만 연령(나이)을 의미합니다.
보험금지급기준
1. 장례비
2.  위자료
가. 지급액 : 5,000,000원
나. 청구권자의 범위 및 청구권자별 지급기준 : 민법상 상속규정에 따름
가. 사망자 본인 및 유족의 위자료
 (1) 사망 당시 피해자의 나이가 65세 미만인 경우 : 80,000,000원
 (2) 사망 당시 피해자의 나이가 65세 이상인 경우 : 50,000,000원
나. 청구권자의 범위 및 청구권자별 지급기준 : 민법상 상속규정에 따름
항     목
지     급     기     준
(월평균현실소득액－생활비) × (사망일부터 보험금지급일까지의 월수   + 
보험금지급일부터 취업가능연한까지 월수에 해당하는 호프만 계수)지식68)
산  식
3. 상실수익액
가. 산정방법 : 사망한 본인의 월평균 현실소득액(제세액공제)에서 본인의 생활비(월평균현실소득액에 생활
  비율을 곱한 금액)를 공제한 금액에 취업가능월수에 해당하는 호프만 계수지식67)를 곱하여 산정 (단, 사망
  일부터 취업가능연한까지 월수에 해당하는 호프만계수의 총합은 240을 한도로 함)
※ 아래의 내용은 상실수익액 계산 방법으로서 해당 사고시점에 적용되는 계산식이 변경되었을 경우 해당 계산식에 따라 계
  산됩니다. 
67) ▣ 호프만 계수
     상실수익액을 지급받을 경우, 장래에 대하여 받지 못하는 수익액을 미리 받는 것이므로, 해당 금액의 원금에서 단리
     에 의한 중간이자를 공제하고 계산하는 방법을 말합니다. 
68) ▣ 호프만 계수의 계산 (월미만 일자의 처리)
      월미만 일자는 모두 합산하여 30일을 초과할 경우에만 호프만 계수 산출 시 1개월을 가산합니다.
     (30일 이하는 미반영)
     <예시>
      ①  사망일 2023. 1. 1  ② 생년월일 : 1992. 5. 20   ③ 보험금지급일 2023. 7. 20  
     ④  취업가능연한 : 2057. 5. 19 (생년월일 + 65세)
       - 사망일부터 보험금지급일까지의 월수(③ - ①) : 2023. 7. 20 - 2023. 1. 1 = 6개월 19일
       - 보험금 지급일부터 취업가능연한까지 월수(④ - ③) : 2057. 5. 19 – 2023. 7. 20 = 405개월 29일
      ⇨ 최종월수 : 
       ‘6개월’ + ‘(405개월 + 19일 + 29일)의 호프만 계수’ = ‘6개월’ + ‘406개월의 호프만 계수’ 
          = ‘6개월’ + 237.3245 = 243.3245
   ▣ 상실 수익액 구하기
       월현실소득액 X (1-1/3) X 호프만 계수
     <예시>
       ○  월현실소득액 : 300만원
       ○  호프만 계수 : 240  ⇨ 300만원 X (1-1/3) X 240 = 480,000,000원
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
    ① 급여소득자(*1) : 사고발생 직전 또는 사망 직전 과거 3개월로 하되, 계절적 요인 등에 따라 급여의 
      차등이 있는 경우와 상여금, 체력단련비, 연월차휴가보상금 등 매월 수령하는 금액이 아닌 것은 과
      거 1년간으로 함.
    ②  급여소득자 이외의 자 : 사고발생 직전 과거 1년간으로 하며, 기간이 1년 미만인 경우에는 계절적인 
      요인 등을 감안하여 타당한 기간으로 함.
  (나) 산정방법
    1) 현실소득액을 증명할 수 있는 자
      세법에 따른 관계증빙서(*2)에 따라 소득을 산정할 수 있는 자에 한하여 다음과 같이 산정한 금액으
      로 함.
     가) 급여소득자
        피해자가 근로의 대가로서 받은 보수(*3)액에서 제세액을 공제한 금액. 그러나 피해자가 사망 직
        전에 보수액의 인상이 확정된 경우에는 인상된 금액에서 제세액을 공제한 금액
나. 현실소득액의 산정방법
 (1)유직자
  (가) 산정대상기간
3. 상실수익액
항     목
지     급     기     준
(*1) ‘급여소득자’라 함은 소득세법 제20조186쪽)에서 규정한 근로소득을 얻고 있
   는 자로서 일용근로자 이외의 자를 말함.
(*2) ‘세법에 따른 관계증빙서’라 함은 사고발생 전에 신고하거나 납부하여 발행
   된 관계증빙서를 말함. 다만, 신규취업자, 신규사업개시자 또는 사망 직전에 
   보수액의 인상이 확정된 경우에 한하여 세법 규정에 따라 정상적으로 신고하
   거나 납부(신고 또는 납부가 지체된 경우는 제외함)하여 발행된 관계증빙서
   를 포함함.
(*3) ‘근로의 대가로 받은 보수’라 함은 본봉, 수당, 성과급, 상여금, 체력단련비, 
   연월차휴가보상금 등을 말하며, 실비변상적인 성격을 가진 대가는 제외함.
     나) 사업소득자(*1) 
      ① 세법에 따른 관계증빙서에 따라 증명된 수입액에서 그 수입을 위하여 필요한 제경비 및 제세액
        을 공제하고 본인의 기여율을 감안하여 산정한 금액
{연간수입액  －  주요경비지식69)  －  (연간수입액  ×  기준경비율) － 제세공과금}  
×  노무기여율  ×  투자비율
산  식
69) 주요경비, 기준경비율 및 단순경비율은 아래의 내용을 말합니다.
   1) 주요경비(매입비용, 인건비, 임차료)
      - 매입비용 : 재화의 매입(식자재구입 비용 등), 외주가공비, 운송업의 운반비 등
       - 인건비 : 종업원의 임금, 퇴직급여 등
       - 임차료 : 사업용 고정자산(건물, 기계 등)에 대한 임차료
   2) 기준경비율 및 단순경비율
       - 기준경비율  : 장부를 기재하지 않는 사업자의 직전년도 수입금액의 합계액이 소득세법령에서 정한 기준 금액 이상
      인 경우 등에 적용하는 경비율을 말합니다.
       - 단순경비율 : 장부를 기재하지 않는 사업자의 직전년도 수입금액의 합계액이 소득세법령에서 정한 기준금액 미만
      인 경우 등에 적용하는 경비율을 말합니다. 
(주) 1. 제경비가 세법에 따른 관계증빙서에 따라 증명되는 경우에는 위 기준경비율지식69) 또는 
     단순경비율지식69)을 적용하지 않고 그 증명된 경비를 공제함.
   2. 소득세법 등에 의해 단순경비율 적용대상자는 기준경비율 대신 그 비율을 적용함.
   3.  투자비율은 증명이 불가능할 때에는 ‘1/동업자수’로 함.
   4.  노무기여율은 85/100를 한도로 타당한 율을 적용함.
      ②  본인이 없더라도 사업의 계속성이 유지될 수 있는경우에는 위 ①의 산식에 따르지 않고 일용근
        로자 임금(*2)을 인정함.
      ③  위 ①에 따라 산정한 금액이 일용근로자 임금에 미달한 경우에는 일용근로자 임금을 인정함.
66
67
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (36, 1, 36, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
(*1) 이 보험계약에서 사업소득자라 함은 소득세법 제19조186쪽)에서 규정한 소득
   을 얻고 있는 자를 말함.
(*2) 이 보험계약에서 일용근로자 임금이라 함은 통계법 제15조193쪽)에 의한 통계
   작성지정기관(대한건설협회, 중소기업중앙회)이 통계법 제17조에 따라 조
   사ㆍ공표한 노임 중 공사부문은 보통인부, 제조부문은 단순노무종사원의 임
   금을 적용하여 아래와 같이 산정함.
(*1) 기술직 종사자가 ‘관련 서류를 통해 객관적으로 증명한 경우’라 함은 자
   격증, 노무비 지급확인서 등의 입증 서류를 보험회사로 제출한 것을 말함.
(공사부문 보통인부임금  +  제조부문 단순노무종사원임금) / 2
※ 월 임금 산출 시 25일을 기준으로 산정
산  식
     다) 그 밖의 유직자(이자소득자, 배당소득자 제외)
        세법상의 관계증빙서에 따라 증명된 소득액에서 제세액을 공제한 금액. 다만, 부동산임대소득
        자의 경우에는 일용근로자 임금을 인정하며, 이 기준에서 정한 여타의 증명되는 소득이 있는 경
        우에는 그 소득과 일용근로자 임금 중 많은 금액을 인정함.
     라) 위 가), 나), 다)에 해당하는 자로서 기술직 종사자는 통계법 제15조193쪽)에 의한 통계작성지정
        기관(공사부문 : 대한건설협회, 제조부문 : 중소기업중앙회)이 통계법 제17조에 따라 조사ㆍ공
        표한 노임에 의한 해당직종 임금이 많은 경우에는 그 금액을 인정함. 다만, 사고 발생 직전 1년 
        이내 해당 직종에 종사하고 있었음을 관련 서류를 통해 객관적으로 증명한 경우(*1)에 한함.
    2) 현실소득액을 증명하기 곤란한 자
      세법에 따른 관계증빙서에 따라 소득을 산정할 수 없는 자는 다음과 같이 산정한 금액으로 함.
     가) 급여소득자
        일용근로자 임금
     나) 사업소득자
        일용근로자 임금
     다) 그 밖의 유직자
        일용근로자 임금
     라) 위 가), 나), 다)에 해당하는 자로서 기술직 종사자는 통계법 제15조193쪽)에 의한 통계작성지정
        기관(공사부문 : 대한건설협회, 제조부문 : 중소기업중앙회)이 통계법 제17조에 따라 조사, 공
        표한 노임에 의한 해당직종 임금이 많은 경우에는 그 금액을 인정함. 다만, 사고발생 직전 1년 이
        내 해당 직종에 종사하고 있었음을 관련 서류를 통해 객관적으로 증명한 경우에 한함.    
    3) 미성년자로서 현실소득액이 일용근로자 임금에 미달한 자 : 19세에 이르기까지는 현실소득액, 19
      세 이후는 일용근로자 임금
 (2) 가사종사자 : 일용근로자 임금
 (3) 무직자(학생포함) : 일용근로자 임금
 (4) 현역병 등 군 복무해당자(복무예정자 포함) : 일용근로자 임금
 (5) 소득이 두 가지 이상인 자
  (가) 세법에 따른 관계증빙서에 따라 증명된 소득이 두 가지 이상 있는 경우에는 그 합산액을 인정함.
  (나) 세법에 따른 관계증빙서에 따라 증명된 소득과 증명 곤란한 소득이 있는 때 혹은 증명이 곤란한 소득
     이 두 가지 이상 있는 경우에 이 기준에 따라 인정하는 소득 중 많은 금액을 인정함.
 (6) 외국인
  (가) 유직자
    ①  국내에서 소득을 얻고 있는 자로서 그 증명이 가능한자 : 위 ‘1)’의 현실소득액의 증명이 가능한 자
      의 현실소득액 산정방법으로 산정한 금액
    ②  위 ‘①’이외의 자 : 일용근로자 임금
  (나) 무직자(학생 및 미성년자 포함) : 일용근로자 임금
3. 상실수익액
항     목
지     급     기     준
다.  생활비율 : 1/3
라.  취업가능월수
 (1)  취업가능연한을 65세로 하여 취업가능월수를 산정함. 다만, 법령, 단체협약 또는 그 밖의 별도의 정년
    에 관한 규정이 있으면 이에 의하여 취업가능월수를 산정하며, 피해자가 「농업ㆍ농촌 및 식품산업 기
    본법」 제3조제2호에 따른 농업인이나 「수산업ㆍ어촌 발전기본법」 제3조제3호에 따른 어업인일 경우
    (피해자가 객관적 자료를 통해 증명한 경우에 한함)에는 취업가능연한을 70세로 하여 취업가능월수
    를 산정함.
 (2) 피해자가 사망 당시(후유장애를 입은 경우에는 노동능력상실일) 62세 이상인 경우에는 다음의 「62세 
    이상 피해자의 취업가능월수」에 의하되, 사망일 또는 노동능력상실일부터 정년에 이르기까지는 월현
    실소득액을, 그 이후부터 취업가능월수까지는 일용근로자 임금을 인정함.
3. 상실수익액
항     목
지     급     기     준
 (3) 취업가능연한이 사회통념상 65세 미만인 직종에 종사하는 자인 경우 해당 직종에 타당한 취업가능연
    한 이후 65세에 이르기까지의 현실소득액은 사망 또는 노동능력 상실 당시의 일용근로자 임금을 인정
    함.
 (4) 취업시기는 19세 로 함.
 (5) 외국인
  (가) 적법한 일시체류자(*1)인 경우 생활 본거지인 본국의 소득기준을 적용함. 다만 적법한 일시체류자가 
     국내에서 취업활동을 한 경우 아래 (다)를 적용함.
  (나) 적법한 취업활동자(*2)인 경우 외국인 근로자의 적법한 체류기간 동안은 국내의 소득기준을 적용하
     고, 적법한 체류기간 종료 후에는 본국의 소득기준을 적용함. 다만, 사고 당시 남은 적법한 체류기간
     이 3년 미만인 경우 사고일부터 3년간 국내의 소득기준을 적용함.
  (다) 그 밖의 경우 사고일부터 3년은 국내의 소득기준을, 그 후부터는 본국의 소득기준을 적용함.
피해자의 나이
62세부터 67세 미만
67세부터 76세 미만
76세 이상
취업가능 월수
36월
24월
12월
<62세 이상 피해자의 취업가능월수>
(*1) ‘적법한 일시체류자’라 함은 국내 입국허가를 득하였으나 취업활동의 허가를 얻지 
   못한 자를 말합니다.
(*2) ‘적법한 취업활동자’라 함은 국내 취업활동 허가를 얻은 자를 말합니다.
i = 5/12%,  n = 취업가능월수
 1       1                  1
        +                            +     …………  +
 1＋ i        1＋2 i                 1＋n i
산  식
마. 호프만 계수 : 법정이율 월 5/12%, 단리에 따른 중간이자를 공제하고 계산하는 방법
항     목
지     급     기     준
나. 부상  
각 보장종목별 보험가입금액 한도 내에서 다음의 금액을 지급하되, 대인배상Ⅰ은 자동차손해배상보장법 시행령 [별표 1]에서 정한 
상해급별 보상한도 내에서 지급함.
가. 구조수색비 : 사회통념상으로 보아 필요 타당한 실비
나. 치료관계비 : 의사의 진단 기간에서 치료에 소요되는 다음의 비용(외국에서 치료를 받은 경우에는 국내의
  료기관에서의 치료에 소요되는 비용 상당액. 다만, 국내의료기관에서 치료가 불가능하여 외국에서 치료
1. 적극손해
68
69
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (37, 1, 37, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
2. 위자료 
가. 청구권자의 범위 : 피해자 본인
나. 지급기준 : 책임보험 상해구분에 따라 다음과 같이 급별로 인정함.
다. 과실상계 후 후유장애 상실수익액과 가정간호비가 후유장애 보험금 보상한도를 초과하는 경우에는 부상 
  보험금 한도 내에서 부상 위자료를 지급함.
급별
급별
급별
1
2
3
4
5
6
7
8
9
10
11
12
13
14
인정액
인정액
인정액
200
176
152
128
75
50
40
30
25
20
20
15
15
15
(단위 : 만 원)
항     목
지     급     기     준
  를 받는 경우에는 그에 소요되는 타당한 비용)으로 하되, 관련법규에서 환자의 진료비로 인정하는 선택진
  료비를 포함함.
 (1) 입원료
  (가) 입원료는 대중적인 일반병실(이하‘기준병실’이라 함)의 입원료를 지급함. 다만, 의사가 치료상 부득
     이 기준병실보다 입원료가 비싼 병실(이하‘상급병실’이라 함)에 입원하여야 한다고 판단하여 상급
     병실에 입원하였을 때에는 그 병실의 입원료를 지급함.
  (나) 기준병실이 없어 부득이하게 병원급 이상 의료기관의 상급병실에 입원하였을 때에는 7일의 범위에
     서는 그 병실의 입원료를 지급함. 입원일수가 7일을 초과한 때에는 그 초과한 기간은 기준병실의 입
     원료와 상급병실의 입원료와의 차액은 지급하지 아니함.
  (다) 피보험자나 피해자의 희망으로 상급병실에 입원하였을 때는 기준병실의 입원료와 상급병실의 입원
     료와의 차액은 지급하지 아니함.
 (2) 응급치료, 호송, 진찰, 전원, 퇴원, 투약, 수술(성형수술 포함), 처치, 의지, 의치, 안경, 보청기 등에 소
    요되는 필요타당한 실비
 (3)  치아보철비: 금주조관보철(백금관보철 포함) 또는 임플란트(실제 시술한 경우로 1치당 1회에 한함)
    에 소요되는 비용. 다만, 치아보철물이 외상으로 인하여 손상 또는 파괴되어 사용할 수 없게 된 경우에
    는 원상회복에 소요되는 비용
다만, ‘자동차손해배상보장법시행령’ <별표1>에서 정한 상해급별 구분 중 12급 내지 14급에 해당하는 교통
사고환자가 상해를 입은 날로부터 4주를 경과한 후에도 의학적 소견에 따른 향후치료를 요하는 경우에는 의
료법에 따른 진단서상 향후 치료에 대한 소견 범위에 기재된 치료기간 내 치료에 소요되는 비용으로 함.
1. 적극손해
항     목
지     급     기     준
3. 휴업손해
3. 휴업손해
나. 휴업일수의 산정
 (1) 휴업일수의 산정 : 피해자의 상해정도를 감안, 치료 기간의 범위에서 인정함.
 (2)  사고당시 피해자의 나이가 취업가능연한을 초과한 경우, 휴업일수를 산정하지 아니함. 다만, 위 가.에 
    따라 관계 서류를 통해 증명한 경우에는 그러하지 아니함.
 (3)  취업가능연한 : 65세를 기준으로 함. 다만, 법령, 단체협약 또는 그 밖의 별도의 정년에 관한 규정이 있
    으면 이에 의하며, 피해자가 「농업ㆍ농촌 및 식품산업 기본법」 제3조제2호에 따른 농업인이나 「수산
    업ㆍ어촌 발전기본법」 제3조제3호에 따른 어업인일 경우(피해자가 객관적 자료를 통해 증명한 경우
    에 한함)에는 취업가능연한을 70세로 함.
다. 수입감소액의 산정
1일 수입감소액 × 휴업일수 ×
산  식
85
100
 (3)  무직자
  (가) 무직자는 수입의 감소가 없는 것으로 함.
  (나) 유아, 연소자, 학생, 연금생활자, 그 밖의 금리나 임대료에 의한 생활자는 수입의 감소가 없는 것으로 
     함.
 (4)  소득이 두 가지 이상의 자
    사망한 경우 현실소득액의 산정방법과 동일
 (5)  외국인
    사망한 경우 현실소득액의 산정방법과 동일
(*1) ‘가사종사자라’ 함은 사고당시 2인 이상으로 구성된 세대에서 경제활동을 하지 않
   고 가사활동에 종사하는 자로서 주민등록 관계 서류와 세법상 관계서류 등을 통해 
   해당 사실을 증명한 사람을 말함.
(*1) ‘객관적인 증빙자료’라 함은 진단서, 진료기록, 입원기록, 가족관계증명서 등 보험
   회사가 상해등급과 신분관계를 판단할 수 있는 서류를 말함.
4. 간병비
가. 청구권자의 범위 : 피해자 본인
나. 인정 대상
 (1) 책임보험 상해구분상 1䟩5급에 해당하는 자 중 객관적인 증빙자료(*1)를 제출한 경우 인정함.
 (2)  동일한 사고로 부모 중 1인이 사망 또는 상해등급 1䟩5급의 상해를 입은 7세 미만의 자 중 객관적인 증
    빙자료를 제출한 경우 인정함.
 (3)  의료법 제4조의 2에 따른 비용을 보험회사가 부담하는 경우에는 비용 및 기간에 관계없이 인정하지 않
    음.
가. 산정방법 : 부상으로 인하여 휴업함으로써 수입의 감소가 있었음을 관계 서류를 통해 증명할 수 있는 경
  우(*1)에 한하여 휴업기간 중 피해자의 실제 수입감소액의 85% 해당액을 지급함.
 (1)  유직자
  (가) 사망한 경우 현실소득액의 산정방법에 따라 산정한 금액을 기준으로 하여 수입감소액을 산정함.
  (나) 실제의 수입감소액이 위 (가)의 기준으로 산정한 금액에 미달하는 경우에는 실제의 수입감소액으로 
     함.
 (2)  가사종사자(*1)
  (가) 일용근로자 임금을 수입감소액으로 함.
(*1) ‘관계 서류를 통해 증명할 수 있는 경우’라 함은 세법상 관계 서류 또는 기타 객관
   적으로 인정되는 자료 등을 통해 증명한 경우를 말함.
다. 지급기준
 (1) 위 인정대상 (1)에 해당하는 자는 책임보험 상해구분에 따라서 다음과 같이 상해등급별 인정일수를 한
    도로 하여 실제 입원기간을 인정함.
 (2)  위 인정대상 (2)에 해당하는 자는 최대 60일을 한도로 하여 실제 입원기간을 인정함.
 (3)  간병인원은 1일 1인 이내에 한하며, 1일 일용근로자 임금을 기준으로 지급함.
 (4)  위 (1)과 (2)의 간병비가 피해자 1인에게 중복될 때에는 양자 중 많은 금액을 지급함.
5. 그 밖의
     손해배상금
위 ‘1.’ 내지 ‘3.’ 외에 그 밖의 손해배상금으로 다음의 금액을 지급함.
가. 입원하는 경우
  입원기간 중 한 끼당 4,030원(병원에서 환자의 식사를 제공하지 않거나 환자의 요청에 따라 병원에서 제
  공하는 식사를 이용하지 않는 경우에 한함)
나. 통원하는 경우
  실제 통원한 일수에 대하여 1일 8,000원
상해등급
1급䟩2급
3급䟩4급
5급
인정일수
60일
30일
15일
70
71
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (38, 1, 38, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
다. 후유장애 상실수익액을 지급하는 경우에는 후유장애 위자료를 지급함. 다만, 부상 위자료 해당액이 더 
  많은 경우에는 그 금액을 후유장애 위자료로 지급함.
노동능력상실률
노동능력상실률
45% 이상  50% 미만
35% 이상  45% 미만
27% 이상  35% 미만
20% 이상  27% 미만
14% 이상  20% 미만
   9% 이상  14% 미만
   5% 이상  9% 미만
   0% 초과  5%미만
인정액
인정액
400
240
200
160
120
100
80
50
(단위 : %, 만 원)
2. 상실수익액
가. 산정방법 : 피해자가 노동능력을 상실한 경우 피해자의 월평균 현실소득액에 노동능력상실률과 노동능력
  상실기간에 해당하는 호프만 계수지식68)를 곱하여 산정함. (단, 노동능력상실일부터 취업가능연한까지 월
  수에 해당하는 호프만계수의 총합은 240을 한도로 함) 
다. 후유장애  
각 보장종목별 보험가입금액 한도 내에서 다음의 금액을 지급하되, 대인배상Ⅰ은 자동차손해배상보장법 시행령 [별표 2]에서 정한 
후유장애급별 보상한도 내에서 지급함.
항     목
지     급     기     준
가. 청구권자의 범위 : 피해자 본인
나. 지급기준 : 노동능력상실률에 따라 (1)항 또는 (2)항에 의해 산정한 금액을 피해자 본인에게 지급함.
 (1) 노동능력상실률이 50% 이상인 경우
  (가) 후유장애 판정 당시(*1)  피해자의 나이가 65세 미만인 경우 : 
     45,000,000원×노동능력상실률×85%
  (나) 후유장애 판정 당시(*1) 피해자의 나이가 65세 이상인 경우 : 
     40,000,000원× 노동능력상실률×85%
     (다) 상기 (가), (나)에도 불구하고 피해자가 이 약관에 따른 가정간호비 지급 대상인 경우에는 아래 기준
     을 적용함.
    ① 후유장애 판정 당시(*1) 피해자의 나이가 65세 미만인 경우 : 
      80,000,000원 × 노동능력상실률 × 85%
    ②  후유장애 판정 당시(*1) 피해자의 나이가 65세 이상인 경우 : 
      50,000,000원 × 노동능력상실률 × 85%
  (*1) 후유장애 판정에 대한 다툼이 있을 경우 최초 후유장애 판정 시점의 피해자 연령을 기준으로 후유
      장애 위자료를 산정합니다.
 (2) 노동능력상실률이 50% 미만인 경우
1. 위자료 
2. 상실수익액
항     목
지     급     기     준
 (5)  소득이 두 가지 이상인 자
    사망한 경우 현실소득액의 산정방법과 동일
 (6)  외국인
    사망한 경우 현실소득액의 산정방법과 동일
다. 노동능력상실률
  맥브라이드 식 후유장애 평가방법지식70)에 따라 일반의 옥내 또는 옥외 근로자를 기준으로 실질적으로 부
  상 치료 진단을 실시한 의사 또는 해당과목 전문의가 진단ㆍ판정한 타당한 노동능력상실률을 적용하며, 
  그 판정과 관련하여 다툼이 있을 경우 보험금 청구권자와 보험회사가 협의하여 정한 제3의 전문의료기관
  의 전문의에게 판정을 의뢰할 수 있음.
라. 노동능력상실기간
  사망한 경우 취업가능 월수와 동일
마. 호프만 계수
  사망의 경우와 동일
나. 현실소득액의 산정방법
 (1)  유직자
  (가) 산정대상기간
    ①  급여소득자 : 사고발생 직전 또는 노동능력 상실 직전 과거 3개월로 하되, 계절적 요인 등에 따라 급
      여의 변동이 있는 경우와 상여금, 체력단련비, 연월차휴가보상금 등 매월 수령하는 금액이 아닌 것
      은 과거 1년간으로 함.
    ②  급여소득자 이외의 자 : 사고발생 직전 과거 1년간으로 하며, 그 기간이 1년 미만인 경우에는 계절
      적인 요인 등을 감안하여 타당한 기간으로 함.
  (나) 산정방법
     사망한 경우 현실소득액의 산정방법과 동일
 (2)  가사종사자
    사망한 경우 현실소득액의 산정방법과 동일
 (3)  무직자(학생포함)
    사망한 경우 현실소득액의 산정방법과 동일
 (4) 현역병 등 군 복무해당자
    사망한 경우 현실소득액의 산정방법과 동일
3. 가정간호비 
가. 인정 대상
  치료가 종결되어 더 이상의 치료효과를 기대할 수 없게 된 때에 1인 이상의 해당 전문의로부터 노동능력
  상실률 100%의 후유장애 판정을 받은 자로서 다음 요건에 해당하는 ‘식물인간상태의 환자 또는 척수손
  상으로 인한 사지완전마비 환자’로 생명유지에 필요한 일상생활의 처리동작을 할 때 항상 다른 사람의 개
  호가 필요한 자지식71)
 (1)  식물인간상태의 환자
    뇌손상으로 다음 항목에 모두 해당되는 상태에 있는 자
  (가) 스스로는 이동이 불가능하다.
  (나) 자력으로는 식사가 불가능하다.
  (다) 대소변을 가릴 수 없는 상태이다.
  (라) 안구는 겨우 물건을 쫓아가는 수가 있으나, 알아보지는 못한다.
  (마) 소리를 내도 뜻이 있는 말은 못한다.
  (바) ‘눈을 떠라’, ‘손으로 물건을 쥐어라’하는 정도의 간단한 명령에는 가까스로 응할 수 있어도 그 이상
     의 의사소통은 불가능하다.
 (2)  척수손상으로 인한 사지완전마비 환자
    척수손상으로 인해 양팔과 양다리가 모두 마비된 환자로서 다음 항목에 모두 해당되는 자
  (가) 생존에 필요한 일상생활의 동작(식사, 배설, 보행 등)을 자력으로 할 수 없다.
  (나) 침대에서 몸을 일으켜 의자로 옮기거나 집안에서 걷기 등의 자력이동이 불가능하다.
  (다) 욕창을 방지하기 위해 수시로 체위를 변경시켜야 하는 등 다른 사람의 상시 개호를 필요로 한다.
나. 지급기준
  가정간호 인원은 1일 1인 이내에 한하며, 가정간호비는 일용근로자 임금을 기준으로 보험금수령권자의 
  선택에 따라 일시금 또는 퇴원일부터 향후 생존기간에 한하여 매월 정기금으로 지급함.
70) 미국 오클라호마 의과대학 정형외과 교수였던 맥브라이드(Earl D. McBride)가 1936년에 만든 노동능력상실평가방법
   으로, 직업과 장애부위의 관련표로 신체의 장애를 백분율(%)로 평가하는 방법(예 : 식물인간의 경우 100% 장애율)입
   니다. 280여종의 직종별 계수 및 각종 신체부위 등이 연관되어 수천가지 이상의 상실율 평가를 가능하도록 구성되어 있
   습니다.
71) “개호”란 사전적으로 “(다른 사람의) 곁에서 돌보아 줌”을 의미하는 용어로서, 신체장애나 질병 등으로 인해 중증의 후
   유장애(노동능력상실률 100%)가 남아 스스로 일상생활을 꾸려 나가지 못하고 남의 도움이 필요한 상태의 사람을 말합
   니다.
월평균현실소득액  ×  노동능력상실률  × (노동능력상실일로부터 보험금지급일까지의 월수 
+  보험금지급일로부터 취업가능연한까지의 월수에 해당하는 호프만 계수)
산  식
72
73
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (39, 1, 39, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
72) “교환가액”이란 사고 직전의 피해물과 같은 종류의 대용품 가액(예 : 같은 종류의 차량)과 이를 교환하는데 소요되는 필
   요 타당한 비용을 말합니다. 
73) “대차료”란 차를 대여(貸與)하는 비용 즉, 렌트비용 등을 말하는 것으로서 약관상 인정기준액에 따라 지급하여 드립니다.
2.교환가액지식72)
  (나) 여객자동차 운수사업법 제84조 제2항188쪽)에 의한 차량충당연한을 적용받는 승용자동차나 승합자
     동차
  (다) 화물자동차 운수사업법 제57조 제1항194쪽)에 의한 차량충당연한을 적용받는 화물자동차
가. 지급대상
  피해물이 다음 중 어느 하나에 해당하는 경우
 (1) 수리비용이 피해물의 사고 직전 가액을 초과하여 수리하지 않고 폐차하는 경우
 (2) 원상회복이 불가능한 경우
나. 인정기준액
 (1) 사고 직전 피해물의 가액 상당액
 (2) 사고 직전 피해물의 가액에 상당하는 동종의 대용품을 취득할 때 실제로 소요된 필요 타당한 비용
(*1) ‘경미한 손상’이라 함은 외장부품 중 자동차의 기능과 안전성을 고려할 때 부품교
   체 없이 복원이 가능한 손상을 말합니다.
(*2) ‘품질인증부품’이란 「자동차관리법」제30조의5에 따라 인증된 부품
(*3) 보험개발원의 차량기준가액표 에서 정하는 내용연수를 말합니다.
1. 수리비용
항     목
지     급     기     준
<별표 2> 대물배상 지급기준
가. 지급대상
  원상회복이 가능하여 수리하는 경우
나. 인정기준액
 (1) 수리비
    사고 직전의 상태로 원상회복하는데 소요되는 필요 타당한 비용으로서 실제 수리비용 
    다만, 경미한 손상(*1)의 경우 보험개발원이 정한 경미손상 수리기준에 따라 복원수리하거나 품질인증
    부품(*2)으로 교환수리하는 데 소요되는 비용을 한도로 함
 (2)  열처리 도장료
    수리 시 열처리 도장을 한 경우 차량연식에 관계없이 열처리 도장료 전액
 (3) 한도
   수리비 및 열처리 도장료의 합계액은 피해물의 사고 직전 가액의 120%를 한도로 함. 다만, 피해물이 다
   음 중 어느 하나에 해당하는 경우에는 130%를 한도로 함
  (가) 내용연수(*3)가 지난 경우
항     목
지     급     기     준
(*1) “동급”이라 함은 배기량, 연식이 유사한 차량을 말합니다.
   다만, 배기량, 연식만을 고려할 경우 차량성능을 반영하기 어려운 자동차(예 : 하
   이브리드 차량, 다운사이징엔진 장착 차량)에 대해서는 차량크기(길이, 너비, 높
   이)를 고려합니다.
(*2) “통상의 요금”이라 함은 자동차 대여시장에서 소비자가 자동차대여사업자로부
   터 자동차를 빌릴 때 소요되는 합리적인 시장가격을 말합니다.
(*3) “규모”라 함은 「자동차관리법시행규칙」 별표1 자동차의 종류 중 규모별 세부기
   준(경형, 소형, 중형, 대형)에 따른 자동차의 규모를 말합니다.
  (나) 대여자동차가 없는 차종(*1)은 보험개발원이 산정한 사업용 해당차종(사업용 해당차종의 구분이 곤
     란할 때에는 사용방법이 유사한 차종으로 하며, 이하 같음) 휴차료 일람표 범위에서 실임차료. 다만, 
     5톤 이하 또는 밴형 화물자동차 및 대형 이륜자동차(260cc 초과)의 경우 중형승용차급 중 최저요금 
     한도로 대차 가능
(*1) “대여자동차가 없는 차종”이라 함은 「여객자동차운수사업법」 제30조에 따라 
   자동차대여사업에 사용할 수 있는 자동차 외의 차종을 말합니다.
 (2) 대차를 하지 않는 경우
  (가) 동급의 대여자동차가 있는 경우 : 해당 차량과 동급의 최저요금 대여자동차 대여 시 소요되는 통상의 
     요금의 35% 상당액
  (나) 「여객자동차운수사업법」에 따른 운행연한 초과로 동급의 대여자동차를 구할 수 없는 경우 :  위 (1)-
     (가) 단서에 따라 대차를 하는 경우 소요되는 대차료의 35% 상당액
     (다) 대여자동차가 없는 경우 : 사업용 해당차종 휴차료 일람표 금액의 35% 상당액
다. 인정기간
 (1)  수리 가능한 경우
    수리를 위해 자동차정비업자에게 인도하여 수리가 완료될 때까지 소요된 기간으로 하되, 25일(실제 
    정비작업시간이 160시간을 초과하는 경우에는 30일)을  한도로 함. 
        다만, 부당한 수리지연이나 출고지연 등의 사유로 인해 통상의 수리기간(*1)을 초과하는 기간은 인정
    하지 않음.
(*1) “통상의 수리기간”이라 함은 보험개발원이 과거 3년간 렌트기간과 작업시간 등
   과의 상관관계를 합리적으로 분석하여 산출한 수리기간(범위)을 말합니다.
 (2) 수리 불가능한 경우 : 10일
3. 대차료지식73)
3. 대차료지식73)
가. 대상
  비사업용자동차(건설기계 포함)가 파손 또는 오손되어 가동하지 못하는 기간 동안에 다른 자동차를 대신 
  사용할 필요가 있는 경우
나. 인정기준액
 (1)  대차를 하는 경우
  (가) 대여자동차는 「여객자동차운수사업법」에 따라 등록한 대여사업자에게서 차량만을 빌릴 때를 기준
     으로 동급(*1)의 대여자동차 중 최저요금의 대여자동차를 빌리는데 소요되는 통상의 요금(*2).
     다만, 피해차량이 사고시점을 기준으로 「여객자동차운수사업법」에 따른 운행연한 초과로 동급의 대
     여자동차를 구할 수 없는 경우에는 피해차량과 동일한 규모(*3)의 대여자동차 중 최저요금의 대여자
     동차를 기준으로 함
가. 지급대상
  사업용자동차(건설기계 포함)가 파손 또는 오손되어 사용하지 못하는 기간 동안에 발생하는 타당한 영업
  손해
나. 인정기준액
 (1)  증명자료가 있는 경우
    1일 영업수입에서 운행경비를 공제한 금액에 휴차 기간을 곱한 금액
 (2)  증명자료가 없는 경우
    보험개발원이 산정한 사업용 해당 차종 휴차료 일람표 금액에 휴차 기간을 곱한 금액
다. 인정기간
 (1)  수리 가능한 경우
  (가) 수리를 위해 자동차정비업자에게 인도하여 수리가 완료될 때까지의 기간으로 하되, 30일을 한도로 
     함.
  (나) 여객자동차운수사업법 시행규칙에 의하여 개인택시운송사업 면허를 받은 자가 부상으로 자동차의 
     수리가 완료된 후에도 자동차를 운행할 수 없는 경우에는 사고일부터 30일을 초과하지 않는 범위에
     서 운행하지 못한 기간으로 함.
4. 휴차료 
74
75
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (40, 1, 40, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
 (2)  수리 불가능한 경우 : 10일 
1. 상해구분 및 급별 보험가입금액표
주) 상해등급은 자동차손해배상보장법 시행령 별표1 79쪽)에서 정한 상해구분에 의함
상해등급
보험가입금액
1,500만원 
3,000만원
5,000만원 
1 급
2 급
3 급
4 급
5 급
6 급
7 급
8 급
9 급
10 급
11 급
12 급
13 급
14 급
1,500만원
800만원
750만원
700만원
500만원
400만원
250만원
180만원
140만원
120만원
120만원
120만원
80만원
50만원
3,000만원
1,600만원
1,500만원
1,400만원
1,000만원
800만원
500만원
360만원
280만원
240만원
200만원
180만원
130만원
80만원
5,000만원
2,700만원
2,500만원
2,300만원
1,650만원
1,300만원
800만원
600만원
450만원
400만원
300만원
200만원
150만원
100만원
<별표 3> 자기신체사고 지급기준
항     목
지     급     기     준
4. 휴차료 
5. 영업손실
가. 지급대상
 소득세법령에 정한 사업자의 사업장 또는 그 시설물을 파괴하여 휴업함으로써 상실된 이익
나. 인정기준액
 (1)  증명자료가 있는 경우
     소득을 인정할 수 있는 세법에 따른 관계증빙서에 의하여 산정한 금액
 (2)  증명자료가 없는 경우
    일용근로자 임금
다. 인정기간
 (1)  원상복구에 소요되는 기간으로 함. 그러나 합의지연 또는 부당한 복구지연으로 연장되는 기간은 휴업
    기간에 넣지 아니함.
 (2) 영업손실의 인정기간은 30일을 한도로 함.
6. 자동차 시세    
     하락 손해
7. 견인비용
사고로 인한 자동차(출고 후 5년 이하인 자동차에 한함)의 수리비용이 사고 직전 자동차가액의 20%를 초과
하는 경우 출고 후 1년 이하인 자동차는 수리비용의 20%를 지급하고, 출고 후 1년 초과 2년 이하인 자동차
는 수리비용의 15%를 지급하며, 출고 후 2년 초과 5년 이하인 자동차는 수리비용의 10%를 지급함.
가. 지급대상
 피해물이 자력 이동이 불가능하여 이를 정비 가능한 곳까지 운반할 필요가 있는 경우
나. 인정기준액
 피해물을 고칠 수 있는 정비공장 등까지 운반하거나 그곳까지 운반하기 위한 임시수리에 소요되는 비용 중 
 필요 타당한 비용
2. 후유장애구분 및 급별 보험가입금액표
주) 장애등급은 자동차손해배상보장법 시행령 별표2 87쪽)에서 정한 후유장애구분에 의함
장애등급
보험가입금액
1,500만원 
3,000만원
5,000만원 
1억원 
1 급
2 급
3 급
4 급
5 급
6 급
7 급
8 급
9 급
10 급
11 급
12 급
13 급
14 급
1,500만원
1,350만원
1,200만원
1,050만원
900만원
750만원
600만원
450만원
360만원
270만원
210만원
150만원
90만원
60만원
3,000만원
2,700만원
2,400만원
2,100만원
1,800만원
1,500만원
1,200만원
900만원
720만원
540만원
420만원
300만원
180만원
120만원
5,000만원
4,500만원
4,000만원
3,500만원
3,000만원
2,500만원
2,000만원
1,500만원
1,200만원
900만원
700만원
500만원
300만원
200만원
1억원
9,000만원
8,000만원
7,000만원
6,000만원
5,000만원
4,000만원
3,000만원
2,400만원
1,800만원
1,400만원
1,000만원
600만원
400만원
항     목
지     급     기     준
1. 과실상계
가. 과실상계의 방법
 (1) 이 기준의 대인배상Ⅰ,  대인배상Ⅱ,  대물배상에 의하여 산출한 금액에 대하여 피해자 측의 과실비율
    에 따라 상계하며, 무보험자동차에 의한 상해의 경우에는 피보험자의 과실비율에 따라 상계함.
 (2)  대인배상Ⅰ에서 사망보험금은 위 ''(1)''에 의하여 상계한 후의 금액이 2,000만원에 미달하면 2,000
    만원을 보상하며, 부상보험금의 경우 위 ''(1)''에 의하여 상계한 후의 금액이 치료관계비와 간병비의 합
    산액에 미달하면 대인배상Ⅰ 한도 내에서 치료관계비(입원환자 식대를 포함)와 간병비를 보상함.
 (3) 대인배상Ⅱ 또는 무보험자동차에 의한 상해에서 사망보험금, 부상보험금 및 후유장애보 험금을 합산
    한 금액을 기준으로 위 ''(1)''에 의하여 상계한 후의 금액이 치료관계비와 간병비의 합산액에 미달하면 
    치료관계비(입원환자 식대를 포함하며, 대인배상Ⅰ에서 지급될 수 있는 금액을 공제)와 간병비를 보
    상함. 다만, 차량운전자(*1)가 ‘자동차손해배상보장법 시행령’ <별표1>에서 정한 상해급별 구분 중 12
    급 내지 14급의 상해를 입은 경우 위 ''(1)''에 의하여 상계하기 전의 치료관계비가 대인배상Ⅰ 한도를 
    초과할 경우 보험회사는 과실상계 없이 우선 보상한 후, 그 초과액에 대하여 피해자 측의 과실비율에 
    해당하는 금액을 청구할 수 있음
<별표 4> 과실상계 등
나. 과실비율의 적용기준
  별도로 정한 자동차사고 과실비율의 인정기준을 참고하여 산정하고, 사고유형이 그 기준에 없거나 그 기
  준에 의한 과실비율의 적용이 곤란할 때에는 판결례를 참작하여 적용함. 그러나 소송이 제기되었을 경우
  에는 확정판결에 의한 과실비율을 적용함.
(*1) “차량운전자”에서 차량이라 함은 「자동차관리법」 제3조에 의한 자동차(이륜자동
   차 제외), 군수품관리법에 의한 차량, 건설기계관리법의 적용을 받는 건설기계를 
   말하며, 차량운전자에는 피해자 측 과실비율을 적용받는 자를 포함합니다.
2. 손익상계
3. 동승자에
     대한 감액
보험사고로 인하여 다른 이익을 받을 경우 이를 상계하여 보험금을 지급함.
피보험자동차에 동승한 자는 <별표 5>의 동승자 유형별 감액비율표에 따라 감액함.
76
77
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (41, 1, 41, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
1. 기준요소
2. 수정요소
동승의 유형 및 운행목적
동승의 유형 및 운행목적
감액비율
감액비율
동승자의 강요 및 무단 동승
상호 의논합의 동승
음주운전자의 차량 동승
운전자의 권유 동승
동승자의 요청 동승
운전자의 강요 동승
100%
20%
40%
10%
30%
0%
※ 다만, 피보험자와 동승자가 「여객자동차운수사업법」에 따른 토요일, 일요일 및 공휴일을 제외한 날의 출䞱퇴근 시간대(오전 7
  시부터 오전 9시까지 및 오후 6시부터 오후 8시까지를 말합니다.)에 실제의 출䞱퇴근 용도로 자택과 직장 사이를 이동하면서 승
  용차 함께 타기를 실시한 경우에는 위 동승자 감액비율을 적용하지 않습니다.
수정요소
수정비율
동승자의 동승과정에 과실이 있는 경우
＋10䟩20%
<별표 5> 동승자 유형별 감액비율표
기     간
지 급 이 자
지급기일의 다음 날부터 30일 이내 기간
지급기일의 31일 이후부터 60일 이내 기간
지급기일의 61일 이후부터 90일 이내 기간
지급기일의 91일 이후 기간
보험계약대출이율
보험계약대출이율 + 가산이율(4.0%)
보험계약대출이율 + 가산이율(6.0%)
보험계약대출이율 + 가산이율(8.0%)
주) 보험계약대출이율은 보험개발원이 공시하는 보험계약대출이율을 적용합니다.
<부표> 보험금을 지급할 때의 적립이율
4. 기왕증 
가. 기왕증(*1)으로 인한 손해는 보상하지 아니함. 다만, 당해 자동차사고로 인하여 기왕증이 악화된 경우에
  는 기왕증이 손해에 관여한 정도(기왕증 관여도)를 반영하여 보상함.
나.  기왕증은 해당과목 전문의가 판정한 비율에 따라 공제함. 다만, 그 판정에 다툼이 있을 경우 보험금 청구
  권자와 보험회사가 협의하여 정한 제3의 전문의료기관의 전문의에게 판정을 의뢰할 수 있음.
(*1) ‘기왕증’이라 함은 당해 자동차사고가 있기 전에 이미 가지고 있던 증상으로 특이
   체질 및 병적 소인 등을 포함하는 것을 말합니다.
항     목
지     급     기     준
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
1. 상해 구분별 한도금액
(붙임) 자동차손해배상보장법 시행령 [별표1]
(자동차손해배상보장법 시행령 제3조 제1항 제2호 관련)
1급
2급
1천
500만원
3천만원
 1.  수술 여부와 상관없이 뇌손상으로 신경학적 증상이 고도인 상해(신경학적 증상이 48시간 이상 지
   속되는 경우에 적용한다)
 2.  양안 안구 파열로 안구 적출술 또는 안구내용 제거술과 의안 삽입술을 시행한 상해
 3.  심장 파열로 수술을 시행한 상해
 4.  흉부 대동맥 손상 또는 이에 준하는 대혈관 손상으로 수술 또는 스탠트그라프트 삽입술을 시행한 상
   해
 5.  척주(등골뼈) 손상으로 완전 사지마비 또는 완전 하반신마비를 동반한 상해
 6.  척수 손상을 동반한 불안정성 방출성 척추 골절
 7.  척수 손상을 동반한 척추 신연손상 또는 전위성(회전성) 골절
 8.  상완신경총 완전 손상으로 수술을 시행한 상해
 9.  위팔 부위 완전 절단(팔꿈치관절 부위 분리절단을 포함한다) 소실로 재접합술을 시행한 상해
 10.  불안정성 골반뼈 골절로 수술을 시행한 상해
 11.  비구 골절 또는 비구 골절 탈구로 수술을 시행한 상해
 12.  넓적다리 부위 완전 절단(무릎관절 부위 분리절단을 포함한다) 소실로 재접합술을 시행한 상해
 13.  골의 분절 소실로 유리생골 이식술을 시행한 상해(근육, 근막 또는 피부 등 연부 조직을 포함한 경우
   에 해당한다)
 14.  화상ㆍ좌창ㆍ괴사창 등 연부 조직의 심한 손상이 몸표면의 9퍼센트 이상인 상해
 15.  그 밖에 1급에 해당한다고 인정되는 상해
상해의 구분과 책임보험금의 한도금액
상해
급별  
한도금액 
상 해 내 용 
3급
1천
200만원
 1.  뇌손상으로 신경학적 증상이 고도인 상해(신경학적 증상이 48시간 미만 지속되는 경우로 수술을 
   시행한 경우에 적용한다)
 2.  뇌손상으로 신경학적 증상이 중등도인 상해(신경학적 증상이 48시간 이상 지속되는 경우로 수술을 
   시행하지 않은 경우에 적용한다)
 3.  단안 안구 적출술 또는 안구 내용 제거술과 의안 삽입술을 시행한 상해
 4.  흉부 대동맥 손상 또는 이에 준하는 대혈관 손상으로 수술을 시행하지 않은 상해
 5.  절제술을 제외한 개흉 또는 흉강경 수술을 시행한 상해(진단적 목적으로 시행한 경우에는 4급에 해
   당한다)
 6.  요도 파열로 요도 성형술 또는 요도 내시경을 이용한 요도 절개술을 시행한 상해
 1.  뇌손상으로 신경학적 증상이 중등도인 상해(신경학적 증상이 48시간 이상 지속되는 경우로 수술을 
   시행한 경우에 적용한다)
 2.  흉부 기관, 기관지 파열, 폐 손상 또는 식도 손상으로 절제술을 시행한 상해
 3.  내부 장기 손상으로 장기의 일부분이라도 적출 수술을 시행한 상해
 4.  신장 파열로 수술한 상해
 5.  척주 손상으로 불완전 사지마비를 동반한 상해
 6.  신경 손상 없는 불안정성 방출성 척추 골절로 수술적 고정술을 시행한 상해 또는 목뼈 골절(치돌기 
   골절을 포함한다) 또는 탈구로 목뼈고정기(할로베스트)나 수술적 고정술을 시행한 상해
 7.  상완 신경총 상부간부 또는 하부간부의 완전 손상으로 수술을 시행한 상해
 8.  아래팔 완전 절단(손목관절 부위 분리절단을 포함한다) 소실로 재접합술을 시행한 상해
 9.  엉덩관절의 골절성 탈구로 수술을 시행한 상해(비구 골절을 동반하지 않은 경우에 적용한다)
 10.  넓적다리뼈머리 골절로 수술을 시행한 상해
 11.  넓적다리뼈 윗목부 분쇄 골절, 돌기 아랫부분 분쇄 골절, 관절융기 분쇄 골절, 정강이뼈(경골) 관절
   융기 분쇄 골절 또는 정강이뼈 먼쪽 관절내   분쇄 골절
 12.  무릎관절의 골절 및 탈구로 수술을 시행한 상해
 13.  종아리 완전 절단(발목관절 부위 분리절단을 포함한다) 소실로 재접합술을 시행한 상해
 14.  팔다리 연부 조직에 손상이 심하여 유리 피판술을 시행한 상해
 15.  그 밖에 2급에 해당한다고 인정되는 상해
78
79
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (42, 1, 42, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
4급
1천만원
상해
급별  
한도금액 
상 해 내 용 
3급
1천
200만원
 7.  내부 장기 손상(장간막 파열을 포함한다)으로 장기 적출 없이 재건수술 또는 지혈수술 등을 시행한 
   상해
 8.  척주 손상으로 불완전 하반신마비를 동반한 상해
 9.  어깨관절 골절 및 탈구로 수술을 시행한 상해
 10.  위팔 부위 완전 절단(팔꿈치관절 부위 분리절단을 포함한다) 소실로 재접합술을 시행하지 않은 상
   해
 11.  팔꿈치관절 골절 및 탈구로 수술을 시행한 상해
 12.  손목 부위 완전 절단 소실로 재접합술을 시행한 상해
 13.  넓적다리뼈 또는 정강이뼈 골절(넓적다리뼈머리 골절은 제외한다)
 14.  넓적다리 부위 완전 절단(무릎관절 부위 분리절단을 포함한다) 소실로 재접합술을 시행하지 않은 
   상해
 15.  무릎관절의 전방 및 후방 십자인대의 파열
 16.  발목관절 골절 및 탈구로 수술을 시행한 상해
 17.  발목관절의 손상으로 발목뼈의 완전탈구가 동반된 상해
 18.  발목 완전 절단 소실로 재접합술을 시행한 상해
 19.  그 밖에 3급에 해당한다고 인정되는 상해
5급
900만원
 1.  뇌손상으로 신경학적 증상이 중등도에 해당하는 상해(신경학적 증상이 48시간 미만 지속되는 경우
   로 수술을 시행한 경우에 적용한다)
 2.  안와 골절에 의한 겹보임[복시(複視)]으로 안와 골절 재건술과 사시 수술을 시행한 상해
 1.  뇌손상으로 신경학적 증상이 고도인 상해(신경학적 증상이 48시간 미만 지속되는 경우로 수술을 
   시행하지 않은 경우에 적용한다)
 2.  각막 이식술을 시행한 상해
 3.  후안부 안내 수술을 시행한 상해(유리체 출혈, 망막박리 등으로 수술을 시행한 경우에 적용한다)
 4.  흉부 손상 또는 복합 손상으로 인공호흡기를 시행한 상해(기관절개술을 시행한 경우도 포함한다)
 5.  진단적 목적으로 복부 또는 흉부 수술을 시행한 상해(복강경 또는 흉강경 수술도 포함한다)
 6.  상완신경총 완전 손상으로 수술을 시행하지 않은 상해
 7.  상완신경총 불완전 손상(2개 이상의 주요 말초신경 장애를 보이는 손상에 적용한다)으로 수술을 시
   행한 상해
 8.  위팔뼈목 골절
 9.  위팔뼈 몸통 분쇄성 골절
 10.  위팔뼈 위관절융기 또는 위팔뼈 먼쪽 부위 관절내 골절(경과 골절, 과간 골절, 내과 골절, 작은 머리 
   골절에 적용한다)로 수술을 시행한 상해
 11.  노뼈 먼쪽 부위 골절과 자뼈머리 탈구가 동반된 상해(갈레아찌 골절을 말한다)
 12.  자뼈 몸쪽 부위 골절과 노뼈머리 탈구가 동반된 상해(몬테지아 골절을 말한다)
 13.  아래팔 완전 절단(손목관절 부위 분리절단을 포함한다) 소실로 재접합술을 시행하지 않은 상해
 14.  노손목관절 골절 및 탈구(손목뼈간 관절 탈구, 먼쪽 노자관절 탈구를 포함한다)로 수술을 시행한 상
   해
 15.  손목뼈 골절 및 탈구가 동반된 상해
 16.  무지 또는 다발성 손가락의 완전 절단 소실로 재접합술을 시행한 상해
 17.  불안정성 골반뼈 골절로 수술하지 않은 상해
 18.  골반고리가 안정적인 골반뼈 골절(엉치뼈 골절 및 꼬리뼈 골절을 포함한다)로 수술을 시행한 상해
 19.  골반뼈 관절의 분리로 수술을 시행한 상해
 20.  비구 골절 또는 비구 골절 탈구로 수술을 시행하지 않은 상해
 21.  무릎관절 탈구로 수술을 시행한 상해
 22.  종아리 완전 절단(발목관절 부위 분리절단을 포함한다) 소실로 재접합술을 시행하지 않은 상해
 23.  목말뼈 또는 발꿈치뼈 골절
 24.  무족지 또는 다발성 발가락의 완전 절단 소실로 재접합술을 시행한 상해
 25.  팔다리의 연부 조직에 손상이 심하여 유경 피판술 또는 원거리 피판술을 시행한 상해
 26.  화상, 좌창, 괴사창 등으로 연부 조직의 손상이 몸표면의 약 4.5퍼센트 이상인 상해
 27.  그 밖에 4급에 해당한다고 인정되는 상해
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
5급
900만원
 3.  복강내 출혈 또는 장기 파열 등으로 중재적 방사선학적 시술을 통하여 지혈술을 시행하거나 경피적
   배액술 등을 시행하여 보존적으로 치료한 상해
 4.  안정성 추체 골절
 5.  상완 신경총 상부 몸통 또는 하부 몸통의 완전 손상으로 수술하지 않은 상해
 6.  위팔뼈 몸통 골절
 7.  노뼈머리 또는 자뼈 갈고리돌기 골절로 수술을 시행한 상해
 8.  노뼈와 자뼈의 몸통 골절이 동반된 상해
 9.  노뼈 붓돌기 골절
 10.  노뼈 먼쪽부위 관절내 골절
 11.  손목 손배뼈 골절
 12.  수근부 완전 절단 소실로 재접합술을 시행하지 않은 상해
 13.  무지를 제외한 단일 손가락의 완전 절단 소실로 재접합술을 시행한 상해
 14.  엉덩관절의 골절성 탈구로 수술을 시행하지 않은 상해(비구 골절을 동반하지 않은 경우에 해당한
   다)
 15.  엉덩관절 탈구로 수술을 시행한 상해
 16.  넓적다리뼈머리 골절로 수술을 시행하지 않은 상해
 17.  넓적다리뼈 또는 몸쪽 정강이뼈의  견열골절 
 18.  무릎관절의 골절 및 탈구로 수술을 시행하지 않은 상해
 19.  무릎관절의 전방 또는 후방 십자인대의 파열
 20.  무릎뼈 골절
 21.  발목관절의 양과 골절 또는 삼과 골절(내과, 외과, 후과를 말한다)
 22.  발목관절 탈구로 수술을 시행한 상해
 23.  그 밖의 발목뼈 골절(목말뼈 및 발꿈치뼈는 제외한다)
 24.  발목발허리(리스프랑)관절 손상
 25.  3개 이상의 발허리뼈 골절로 수술을 시행한 상해
 26.  발목 완전 절단 소실로 재접합술을 시행하지 않은 상해
 27.  무족지를 제외한 단일 발가락의 완전 절단 소실로 재접합술을 시행한 상해
 28.  아킬레스건, 무릎인대, 넓적다리  사두건 또는 넓적다리 이두건 파열로 수술을 시행한 상해
 29.  팔다리 근육 또는 힘줄 파열로 6개 이상의 근육 또는 힘줄 봉합술을 시행한 상해
 30. 다발성 팔다리의 주요 혈관 손상으로 봉합술 또는 이식술을 시행한 상해
 31.  팔다리의 주요 말초 신경 손상으로 수술을 시행한 상해
 32.  23치 이상의 치과보철을 필요로 하는 상해
 33.  그 밖에 5급에 해당한다고 인정되는 상해
6급
700만원
 1.  뇌손상으로 신경학증상이 경도인 상해(수술을 시행한 경우에 적용한다)
 2.  뇌손상으로 신경학적 증상이 중등도에 해당하는 상해(신경학적 증상이 48시간 미만 지속되는 경우
   로 수술을 시행하지 않은 경우에 적용한다)
 3.  전안부 안내 수술을 시행한 상해(외상성 백내장, 녹내장 등으로 수술을 시행한 경우에 적용한다)
 4.  심장 타박
 5.  폐타박상(일측 폐의 50퍼센트 이상 면적을 흉부 CT 등에서 확인한 경우에 한정한다)
 6.  요도 파열로 유치 카테타, 부지 삽입술을 시행한 상해
 7.  혈흉(혈액가슴증) 또는 기흉(공기가슴증)이 발생하여 폐쇄식 흉관 삽관수술을 시행한 상해
 8.  어깨관절의 회전근개 파열로 수술을 시행한 상해
 9.  외상성 상부관절와순 파열로 수술을 시행한 상해
 10.  어깨관절 탈구로 수술을 시행한 상해
 11.  어깨관절의 골절 및 탈구로 수술을 시행하지 않은 상해
 12.  위팔뼈 대결절 견열 골절
 13.  위팔뼈 먼쪽 부위 견열골절(외상과   골절, 내상과 골절 등에 해당한다)
 14.  팔꿈치관절 골절 및 탈구로 수술을 시행하지 않은 상해
 15.  팔꿈치관절 탈구로 수술을 시행한 상해
 16.  팔꿈치관절 내측 또는 외측 측부 인대 파열로 수술을 시행한 상해
 17.  노뼈 몸통 또는 먼쪽 부위 관절외 골절
 18.  노뼈목 골절
 19.  자뼈 팔꿈치머리 부위 골절
상해
급별  
한도금액 
상 해 내 용 
80
81
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (43, 1, 43, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
6급
700만원
 20.  자뼈 몸통 골절(몸쪽 부위 골절은 제외한다)
 21.  다발성 손목손허리뼈 관절 탈구 또는 다발성 골절탈구
 22.  무지 또는 다발성 손가락의 완전 절단 소실로 재접합술을 시행하지 않은 상해
 23.  무릎관절 탈구로 수술을 시행하지 않은 상해
 24.  무릎관절 내측 또는 외측 측부인대 파열로 수술을 시행한 상해
 25.  반월상(반달모양) 연골 파열로 수술을 시행한 상해
 26.  발목관절 골절 및 탈구로 수술을 시행하지 않은 상해
 27.  발목관절 내측 또는 외측 측부인대의 파열 또는 골절을 동반하지 않은 먼쪽 정강이뼈ㆍ종아리뼈 분
   리
 28.  2개 이하의 발허리뼈 골절로 수술을 시행한 상해
 29.  무족지 또는 다발성 발가락의 완전 절단 소실로 재접합술을 시행하지 않은 상해
 30. 팔다리 근육 또는 힘줄 파열로 3개 이상 5개 이하의 근육 또는 힘줄 봉합술을 시행한 상해 
 31.  19치 이상 22치 이하의 치과보철을 필요로 하는 상해
 32.  그 밖에 6급에 해당한다고 인정되는 상해
7급
500만원
 1.  다발성 얼굴 머리뼈 골절 또는 뇌신경 손상과 동반된 얼굴 머리뼈 골절
 2.  겹보임을 동반한 마비 또는 제한 사시로 사시수술을 시행한 상해
 3.  안와 골절로 재건술을 시행한 상해
 4.  골다공증성 척추 압박골절
 5.  쇄골(빗장뼈) 골절
 6.  어깨뼈(어깨뼈가시, 어깨뼈몸통, 가슴우리 탈구, 어깨뼈목, 봉우리돌기 및 부리돌기 포함) 골절
 7.  견봉 쇄골인대 및 오구 쇄골인대 완전 파열
 8.  상완신경총 불완전 손상으로 수술을 시행하지 않은 상해
 9.  노뼈머리 또는 자뼈 갈고리돌기 골절로 수술을 시행하지 않은 상해
 10.  자뼈 붓돌기 기저부 골절
 11.  삼각섬유연골 복합체 손상
 12.  노손목관절 탈구(손목뼈간관절 탈구, 먼쪽 노자관절 탈구를 포함한다)로 수술을 시행한 상해
 13.  노손목관절 골절 및 탈구(손목뼈간관절 탈구, 먼쪽 노자관절 탈구를 포함한다)로 수술을 시행하지 
   않은 상해
 14.  손배뼈 외 손목뼈 골절
 15.  손목 부위 손배뼈ㆍ반달뼈 사이 인대 파열
 16.  손목손허리뼈 관절의 탈구 또는 골절탈구
 17.  다발성 손허리뼈 골절
 18.  손허리손가락관절의 골절 및 탈구
 19.  무지를 제외한 단일 손가락의 완전 절단 소실로 재접합술을 시행하지 않은 상해
 20.  골반뼈 관절의 분리로 수술을 시행하지 않은 상해
 21.  엉덩관절 탈구로 수술을 시행하지 않은 상해
 22.  종아리뼈 몸통 골절 또는 뼈머리  골절
 23.  발목관절 탈구로 수술을 시행하지 않은 상해
 24.  발목관절 내과, 외과 또는 후과 골절
 25.  무족지를 제외한 단일 발가락의 완전 절단 소실로 재접합술을 시행하지 않은 상해
 26.  16치 이상 18치 이하의 치과보철을 필요로 하는 상해
 27.  그 밖에 7급에 해당한다고 인정되는 상해
상해
급별 
한도금액 
상 해 내 용 
8급
300만원
 1.  뇌손상으로 신경학적 증상이 경도인 상해(수술을 시행하지 않은 경우에 적용한다)
 2.  위턱뼈, 아래턱뼈, 이틀뼈 등의 얼굴 머리뼈 골절
 3.  외상성 시신경병증
 4.  외상성 안검하수로 수술을 시행한 상해
 5.  복합 고막 파열
 6.  혈흉 또는 기흉이 발생하여 폐쇄식 흉관 삽관수술을 시행하지 않은 상해
 7.  3개 이상의 다발성 갈비뼈 골절
 8.  각종 돌기 골절(극돌기, 횡돌기) 또는 후궁 골절
 9.  어깨관절 탈구로 수술을 시행하지 않은 상해
 10.  위팔뼈 위관절융기 또는 위팔뼈 먼쪽 부위 관절내 골절(경과 골절, 과간 골절. 내과 골절, 작은 머리 
8급
300만원
   골절 등을 말한다)로 수술을 시행하지 않은   상해
 11.  팔꿈치관절 탈구로 수술을 시행하지 않은 상해
 12.  손허리뼈 골절
 13.  손가락뼈의 몸쪽 손가락뼈 사이  또는 먼쪽 손가락뼈 사이 골절 탈구
 14.  다발성 손가락뼈 골절
 15.  무지 손허리손가락관절 측부인대 파열
 16.  골반고리이 안정적인 골반뼈  골절(엉치뼈 골절 및 꼬리뼈 골절을 포함한다)로 수술을 시행하지 않
   은 상해
 17.  무릎관절 십자인대 부분 파열로 수술을 시행하지 않은 상해
 18.  3개 이상의 발허리뼈 골절로 수술을 시행하지 않은 상해
 19.  손발가락뼈 골절 및 탈구로 수술을 시행한 상해
 20. 팔다리의 근육 또는 힘줄 파열로 하나 또는 두개의 근육 또는 힘줄 봉합술을 시행한 상해
 21.  팔다리의 주요 말초 신경 손상으로 수술을 시행하지 않은 상해
 22.  팔다리의 감각 신경 손상으로 수술을 시행한 상해
 23.  팔다리의 다발성 주요 혈관손상으로 봉합술 혹은 이식술을 시행한 상해
 24.  팔다리의 연부 조직 손상으로 피부 이식술이나 국소 피판술을 시행한 상해
 25.  13치 이상 15치 이하의 치과보철을 필요로 하는 상해
 26.  그 밖에 8급에 해당한다고 인정되는 상해
9급
240만원
 1.  얼굴 부위의 코뼈 골절로 수술을 시행한 상해
 2.  2개 이하의 단순 갈비뼈 골절
 3.  고환 손상으로 수술을 시행한 상해
 4.  음경 손상으로 수술을 시행한 상해
 5.  복장뼈(흉골) 골절
 6.  추간판 탈출증
 7.  흉쇄관절 탈구
 8.  팔꿈치관절 내측 또는 외측 측부 인대 파열로 수술을 시행하지 않은 상해
 9.  노손목관절 탈구(손목뼈간관절 탈구, 먼쪽 노자관절 탈구를 포함한다)로 수술을 시행하지 않은 상해
 10.  손가락뼈 골절로 수술을 시행한 상해
 11.  손가락관절 탈구
 12.  무릎관절 측부인대 부분 파열로 수술을 시행하지 않은 상해
 13.  2개 이하의 발허리뼈 골절로 수술을 시행하지 않은 상해
 14.  발가락뼈 골절 또는 발가락관절  탈구로 수술을 시행한 상해
 15.  그 밖에 견열골절 등 제불완전골절
 16.  아킬레스건, 무릎인대, 넓적다리  사두건 또는 넓적다리 이두건 파열로 수술을 시행하지 않은 상해
 17.  손가락ㆍ발가락 폄근힘줄 1개의   파열로 건 봉합술을 시행한 상해
 18.  팔다리의 주요 혈관손상으로 봉합술 혹은 이식술을 시행한 상해
 19.  11치 이상 12치 이하의 치과보철을 필요로 하는 상해
 20.  그 밖에 9급에 해당한다고 인정되는 상해
10급
11급
200만원
160만원
 1.  3cm 이상 얼굴 부위 찢김상처(열상)
 2.  안검과 누소관 찢김상처로 봉합술과 누소관 재건술을 시행한 상해
 3.  각막, 공막 등의 찢김상처로 일차 봉합술만 시행한 상해
 4.  4. 어깨관절부위의 회전근개 파열로 수술을 시행하지 않은 상해
 5.  외상성 상부관절와순 파열 중 수술을 시행하지 않은 상해
 6.  손발가락관절 골절 및 탈구로 수술을 시행하지 않은 상해
 7.  다리 3대 관절의 혈관절증
 8.  연부조직 또는 피부 결손으로 수술을 시행하지 않은 상해
 9.  9치 이상 10치 이하의 치과보철을 필요로 하는 상해
 10.  그 밖에 10급에 해당한다고 인정되는 상해
 1.  뇌진탕
 2.  얼굴 부위의 코뼈 골절로 수술을 시행하지 않는 상해
 3.  수지골 골절 또는 수지관절 탈구로  수술을 시행하지 않은 상해
상해
급별 
한도금액 
상 해 내 용 
82
83
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (44, 1, 44, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
11급
160만원
 4.  족지골 골절 또는 족지관절 탈구로 수술을 시행하지 않은 상해
 5.  6치 이상 8치 이하의 치과보철을 필요로 하는 상해
 6.  그 밖에 11급에 해당한다고 인정되는 상해
12급
13급
14급
120만원
80만원
50만원
 1.  외상 후 급성 스트레스 장애
 2.  3cm 얼굴 부위 찢김상처
 3.  척추 염좌
 4.  팔다리 관절의 근육 또는 힘줄의 단순 염좌 
 5.  팔다리의 찢김상처으로 창상 봉합술을 시행한 상해(길이에 관계없이 적용한다)
 6.  팔다리 감각 신경 손상으로 수술을 시행하지 않은 상해
 7.  4치 이상 5치 이하의 치과보철을 필요로 하는 상해
 8.  그 밖에 12급에 해당한다고 인정되는 상해
 1.  결막의 찢김상처으로 일차 봉합술을 시행한 상해 
 2.  단순 고막 파열
 3.  흉부 타박상으로 갈비뼈 골절 없이 흉부의 동통을 동반한 상해
 4.  2치 이상 3치 이하의 치과보철을 필요로 하는 상해
 5.  그 밖에 13급에 해당한다고 인정되는 상해
 1.  방광, 요도, 고환, 음경, 신장, 간, 지라 등 내부장기 손상(장간막파열을 포함한다)으로 수술을 시행
   하지 않은 상해
 2.  손발가락 관절 염좌
 3.  팔다리의 단순 타박
 4.  1치 이하의 치과보철을 필요로 하는 상해
 5.  그 밖에 14급에 해당한다고 인정되는 상해
상해
급별  
한도금액 
상 해 내 용 
2. 영역별 세부지침
공통
머리
가. 2급부터 11급까지의 상해 내용 중 2가지 이상의 상해가 중복된 경우에는 가장 높은 등급에 해당하
  는 상해부터 하위 3등급(예 : 상해내용이 2급에 해당하는 경우에는 5급까지) 사이의 상해가 중복된 
  경우에만 가장 높은 상해 내용의 등급보다 한 등급 높은 금액으로 배상한다.(이하“병급”이라 한다)
나. 일반 외상과 치과보철을 필요로 하는 상해가 중복된 경우에는 각각의 상해 등급별 금액을 배상하되, 
  그 합산액이 1급의 금액을 초과하지 아니하는 범위에서 배상한다.
다. 1개의 상해에서 2개 이상의 상향 또는 하향 조정의 요인이 있을 때 등급 상향 또는 하향 조정은 1회
  만 큰 폭의 조정을 적용한다. 다만, 상향 조정 요인과 하향 조정 요인이 여러 개가 함께 있을 때는 큰 
  폭의 상향 또는 큰 폭의 하향 조정 요인을 각각 선택하여 함께 반영한다.
라. 재해 발생 시 만 13세 미만인 사람은 소아로 인정한다.
마. 연부 조직에 손상이 심하여 유리피판술, 유경 피판술, 원거리 피판술, 국소피판술이나 피부이식술을 
  시행할 경우, 안면부는 1등급 상위등급을 적용하고 손 부위, 발 부위에 국한된 손상에 대하여는 한 
  등급 아래의 등급을 적용한다.
가. “뇌손상”이란 국소성 뇌손상인 외상성 머리뼈안의 출혈(경막상ㆍ하 출혈, 뇌실 내 및 뇌실질 내 출
  혈, 거미막하 출혈 등을 말한다) 또는 경막하 수활액낭종, 거미막 낭종, 머리뼈 골절(머리뼈 기저부 
  골절을 포함한다) 등과 미만성 축삭손상을 포함한 뇌타박상을 말한다.
나. 4급 이하(4급에서 14급까지를 말한다)에서 의식 외에 뇌신경 손상이나 국소성 신경학적 이상 소견
  이 있는 경우 한 등급을 상향 조정할 수 있다.
다. 신경학적 증상은 글라스고우 혼수척도(Glasgow coma scale)로 구분하며, 고도는 8점 이하, 중등
  도는 9점 이상 12점 이하, 경도는 13점 이상 15점 이하를 말한다.
라. 글라스고우 혼수척도는 진정치료 전에 평가하는 것을 원칙으로 한다.
마. 글라스고우 혼수척도 평가 시 의식이 있는 상태에서 기관지 삽관이 필요한 경우는 제외한다.
바. 의무기록 상 의식상태가 혼수(coma)와 반혼수(semicoma)는 고도, 혼미(stupor)는 중등도, 기
  면(drowsy)은 경도로 본다.
영   역 
내           용
영   역 
내           용
흉ㆍ복부
척추
심장타박(6급)의   경우, ①심전도에서 Tachyarrythmia 또는 ST변화 또는 부정맥, ②심초음파에서 심
장막액증가소견이 있거나 심장벽운동저하, ③심장효소치증가(CPK-MB, and Troponin T) 세가지   요
구 충족 시 인정한다.
가. 완전 마비는 근력등급 3 이하인 경우이며, 불완전 마비는 근력등급 4인 경우로 정한다.
나. 척추관 협착증이나 추간판 탈출증이 외상으로 증상이 발생한 경우나 악화된 경우는 9급으로 본다.
다. 척주 손상으로 인하여 신경근증 이나 감각이상을 호소하는 경우는 9급으로 본다.
라. 마미증후군은 척수손상으로 본다.
가. 2급부터 11급까지의 내용 중 팔다리 골절에서 별도로 상해 등급이 규정되지 않은 경우, 보존적 치료
  를 시행한 골절은 해당 등급에서 2급 낮은 등급을 적용하며, 도수 정복 및 경피적 핀고정술을 시행한 
  경우에는 해당 등급에서 1급 낮은 등급을 적용한다.
나. 2급부터 11급까지의 상해 내용 중 개방성 골절 또는 탈구에서 거스틸로 2형 이상(개방창의 길이가 
  1cm 이상인 경우를 말한다)의 개방성 골절 또는 탈구에서만 1등급 상위 등급을 적용한다.
다. 2급부터 11급까지의 상해 내용 중 “수술적 치료를 시행하지 않은”이라고 명확하게 기록되지 되지 
  않은 각 등급 손상 내용은 수술적 치료를 시행한 경우를 말하며, 보존적 치료를 시행한 경우가 따로 
  명시되지 않은 경우는 두 등급 하향 조정함을 원칙으로 한다.  
라. 양측 또는 단측을 별도로 규정한 경우에는 병합하지 않으나, 별도 규정이 없는 양측 손상인 경우에는 
  병합한다. 
마. 골절에 주요 말초신경의 손상 동반 시 해당 골절보다 1등급 상위 등급을 적용한다.
바. 재접합술을 시행한 절단소실의 경우 해당부위의 절단보다 2급 높은 등급을 적용한다.
사.  아절단은 완전 절단에 준한다.
아.  관절 분리절단의 경우는 상위부 절단으로 본다.  
자.  골절 치료로 인공관절 치환술 시행할 경우 해당부위의 골절과 동일한 등급으로 본다.
차.  팔다리 근육 또는 힘줄의 부분 파열로 보존적으로 치료한 경우 근육 또는 힘줄의 단순 염좌(12급)로 
  본다.  
카.  팔다리 관절의 인공관절 치환 후 재치환 시 해당 부위 골절보다 1등급 높은 등급을 적용한다.
타.  보존적으로 치료한 팔다리  주요관절 골절 및 탈구는 해당관절의 골절 및 탈구보다 3등급 낮은 등급
  을 적용한다.
파.  수술을 시행한 팔다리 주요 관절 탈구는 해당 관절의 보존적으로 치료한 탈구보다 2등급 높은 등급
  을 적용한다.
하.  동일 관절 혹은 동일 골의 손상은 병합하지 않으며 상위 등급을 적용한다
거. 분쇄 골절을 형성하는 골절선은 선상(선모양) 골절이 아닌 골절선으로 판단한다.  
너. 손발가락 절단 시 절단부위에 따른 차이는 두지 않는다.
더. "근육(근), 힘줄(건), 인대 파열"이란 완전 파열을 말하며, 부분 파열은 수술을 시행한 경우에 완전 
  파열로 본다.
러.  팔다리뼈 골절 중 상해등급에서 별도로 명시하지 않은 팔다리뼈 골절(견열골절을 포함한다)은 제불
  완전골절로 본다. 다만, 개방정복(피부와 근육 절개 후 골절된 뼈를 바로잡는 시술을 말한다)을 시행
  한 경우는 해당 부위 골절 항에 적용한다.
머.  팔다리뼈 골절 시 시행한 외고정술도 수술을 한 것으로 간주한다.
버.  소아의 경우, 성인의 동일 부위 골절보다 1급 낮게 적용한다. 다만, 성장판 손상이 동반된 경우와 연
  부조직 손상은 성인과 동일한 등급을 적용한다.
서.  주요 동맥 또는 정맥 파열로 봉합술을 시행한 상해의 경우, 주요 동맥 또는 정맥이란 수술을 통한 혈
  행의 확보가 의학적으로 필요한 경우를 말하며, “다발성 혈관 손상”이란 2개 부위 이상의 주요 동맥 
  또는 정맥의 손상을 말한다.
팔ㆍ다리
공통
가. 상부관절순 파열은 외상성 파열만 인정한다.
나. 회전근개 파열 개수에 따른 차등을 두지 않는다. 
다. 6급의 어깨관절 탈구에서 재발성 탈구를 초래할 수 있는 해부학적 병변이 동시 확인된 경우는 수술 
  여부에 상관없이 6급을 적용한다.
팔
머리
사.  두피 타박상, 찢김상처(열창)은 14급에 준용한다.
아.  만성 경막하 혈종으로 수술을 시행한 경우에는 6급 2호를 적용한다.
자.  외상후 급성 스트레스 장애는 다른 진단이 전혀 없이 단독 부상 및 질병으로 외상 후 1개월 이내 발병
  된 경우에 적용한다.
84
85
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (45, 1, 45, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
라. 견봉 쇄골간 관절 탈구, 관절낭 또는 견봉 쇄골간 인대 파열은 견봉 쇄골인대 및 오구 쇄골인대의 완
  전 파열에 포함되고, 견봉 쇄골인대 및 오구 쇄골인대의 완전 파열로 수술한 경우 7급을 적용하며, 
  부분 파열로 보존적 치료를 시행한 경우 9급을 적용하고, 단순 염좌의 경우 12급을 적용한다.
팔
가. 양측 두덩뼈가지(치골지) 골절, 두덩뼈(치골) 위아래 가지 골절 등에서는 병급하지 않는다.
나. 엉치뼈 골절, 꼬리뼈 골절은 골반뼈 골절로 본다.
다. 무릎관절 십자인대 파열은 전후방 십자인대의 동시 파열이 별도로 규정되어 있으므로 병급하지 않
  으나 내외측 측부인대 동시 파열, 십자인대와 측부인대 파열, 반월상 연골판 파열 등은 병급한다.
라. 후경골건 및 전경골건 파열은 발목관절 측부인대 파열로 수술을 시행한 경우의 등급으로 본다.
마. 넓적다리뼈 또는 정강이뼈ㆍ종아리뼈의 견열성 골절의 경우, 동일 관절의 인대 손상에 대해서 수술
  적 치료를 시행한 경우는 인대 손상 등급으로 본다.
바. 정강이뼈 후과의 단독 골절 시 발목관절 내과 또는 외과의 골절로 본다. 
사.  엉덩관절이란 넓적다리뼈머리와 골반뼈의 비구를 포함하며, “골절 탈구”란 골절과 동시에 관절의 
  탈구가 발생한 상태를 말한다.
아.  불안정성 골반 골절은 골반고리를 이루는 골간의 골절 탈구를 포함한다.  
자.  “다리의 3대 관절”이란 엉덩관절, 무릎관절, 발목관절을 말한다.
차.  무릎관절의 전방 또는 후방 십자인대의 파열은 완전파열(또는 이에 준하는 파열)로 인대 복원수술
  을 시행한 파열에 적용한다.  
카.  골반고리가 안정적인 골반뼈의 수술을 시행한 골절은 두덩뼈  골절로 수술한 경우 등을 포함한다.
다리
영   역 
내           용
팔ㆍ다리
자동차손해배상보장법 시행령 [별표2]
(자동차손해배상보장법 시행령 제3조 제1항 제3호 관련)
1급
2급
3급
4급
5급
1억
5천만원
1억
3,500만원
1억
2천만원
1억
5백만원
9천만원
 1.  두 눈이 실명된 사람
 2.  말하는 기능과 음식물을 씹는 기능을 완전히 잃은 사람
 3.  신경계통의 기능 또는 정신기능에 뚜렷한 장애가 남아 항상 보호를 받아야 하는 사람
 4.  흉복부 장기의 기능에 뚜렷한 장애가 남아 항상 보호를 받아야 하는 사람
 5.  반신불수가 된 사람
 6.  두 팔을 팔꿈치관절 이상의 부위에서 잃은 사람
 7.  두 팔을 완전히 사용하지 못하게 된 사람
 8.  두 다리를 무릎관절 이상의 부위에서 잃은 사람
 9.  두 다리를 완전히 사용하지 못하게 된 사람
   1. 한쪽 눈이 실명되고 다른 쪽 눈의 시력이 0.02 이하로 된 사람
 2.  두 눈의 시력이 각각 0.02 이하로 된 사람
 3.  두 팔을 손목관절 이상의 부위에서 잃은 사람
 4.  두 다리를 발목관절 이상의 부위에서 잃은 사람
 5.  신경계통의 기능 또는 정신기능에 뚜렷한 장애가 남아 수시로 보호를 받아야 하는 사람
 6.  흉복부 장기의 기능에 뚜렷한 장애가 남아 수시로 보호를 받아야 하는 사람
 1.  한쪽 눈이 실명되고 다른 쪽 눈의 시력이 0.06 이하로 된 사람
 2.  말하는 기능이나 음식물을 씹는 기능을 완전히 잃은 사람
 3.  신경계통의 기능 또는 정신기능에 뚜렷한 장애가 남아 일생 동안 노무에 종사할 수 없는 사람
 4.  흉복부 장기의 기능에 뚜렷한 장애가 남아 일생 동안 노무에 종사할 수 없는 사람
 5.  두 손의 손가락을 모두 잃은 사람
 1.  두 눈의 시력이 0.06 이하로 된 사람
 2.  말하는 기능과 음식물을 씹는 기능에 뚜렷한 장애가 남은 사람
 3.  고막이 전부 결손되거나 그 외의 원인으로 인하여 두 귀의 청력을 완전히 잃은 사람
 4.  한쪽 팔을 팔꿈치관절 이상의 부위에서 잃은 사람
 5.  한쪽 다리를 무릎관절 이상의 부위에서 잃은 사람
 6.  두 손의 손가락을 모두 제대로 못쓰게 된 사람
 7.  두 발을 발목발허리(리스프랑)관절  이상의 부위에서 잃은 사람
 1.  한쪽 눈이 실명되고 다른 쪽 눈의 시력이 0.1 이하로 된 사람
 2.  한쪽 팔을 손목관절 이상의 부위에서 잃은 사람
 3.  한쪽 다리를 발목관절 이상의 부위에서 잃은 사람
 4.  한쪽 팔을 완전히 사용하지 못하게 된 사람
 5.  한쪽 다리를 완전히 사용하지 못하게 된 사람
 6.  두 발의 발가락을 모두 잃은 사람
 7.  신경계통의 기능 또는 정신기능에 뚜렷한 장애가 남아 특별히 손쉬운 노무 외에는 종사할 수 없는 
   사람
 8.  흉복부 장기의 기능에 뚜렷한 장애가 남아 특별히 손쉬운 노무 외에는 종사할 수 없는 사람
후유장애의 구분과 책임보험금의 한도금액
장애
급별 
한도금액 
신체장애  내용 
6급
7천
500만원
 1.  두 눈의 시력이 0.1 이하로 된 사람
 2.  말하는 기능이나 음식물을 씹는 기능에 뚜렷한 장애가 남은 사람
 3.  고막이 대부분 결손되거나 그 외의 원인으로 인하여 두 귀의 청력이 귀에 입을 대고 말하지 아니하
   면 큰 말소리를 알아듣지 못하게 된 사람
 4.  한 귀가 전혀 들리지 아니하게 되고 다른 귀의 청력이 40센티미터 이상의 거리에서는 보통의 말소
   리를 알아듣지 못하게 된 사람
 5.  척주(등골뼈)에 뚜렷한 기형이나 뚜렷한 운동장애가 남은 사람
 6.  한쪽 팔의 3대 관절 중 2개 관절을 못쓰게 된 사람
 7.  한쪽 다리의 3대 관절 중 2개 관절을 못쓰게 된 사람
86
87
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (46, 1, 46, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
6급
7급
8급
7천
500만원
6천만원
4천
500만원
 8.  한쪽 손의 5개 손가락을 잃거나 한쪽 손의 엄지손가락과 둘째손가락을 포함하여 4개의 손가락을 잃
   은 사람
 1.  한쪽 눈이 실명되고 다른 쪽 눈의 시력이 0.6 이하로 된 사람
 2.  두 귀의 청력이 모두 40센티미터 이상의 거리에서는 보통의 말소리를 알아듣지 못하게 된 사람
 3.  한쪽 귀가 전혀 들리지 않게 되고 다른 쪽 귀의 청력이 1미터 이상의 거리에서는 보통의 말소리를 알
   아듣지 못하게 된 사람
 4.  신경계통의 기능 또는 정신기능에 장애가 남아 손쉬운 노무 외에는 종사하지 못
   하는 사람
 5.  흉복부 장기의 기능에 장애가 남아 손쉬운 노무 외에는 종사하지 못하는 사람
 6.  한쪽 손의 엄지손가락과 둘째손가락을 잃은 사람 또는 한쪽 손의 엄지 손가락이나 둘째손가락을 포
   함하여 3개 이상의 손가락을 잃은 사람
 7.  한쪽 손의 5개의 손가락 또는 한쪽 손의 엄지손가락과 둘째손가락을 포함하여 4개의 손가락을 제대
   로 못쓰게 된 사람
 8.  한쪽 발을 발목발허리관절 이상의 부위에서 잃은 사람
 9.  한쪽 팔에 가관절(假關節 : 부러진 뼈가 완전히 아물지 못하여 그 부분이 마치 관절처럼 움직이는 상
   태를 말한다. 이하 같다)이 남아 뚜렷한 운동장애가 남은 사람
 10.  한쪽 다리에 가관절이 남아 뚜렷한 운동장애가 남은 사람
 11.  두 발의 발가락을 모두 제대로 못쓰게 된 사람
 12.  외모에 뚜렷한 흉터가 남은 사람
 13.  양쪽의 고환을 잃은 사람
 1.  한쪽 눈이 시력이 0.02 이하로 된 사람
 2.  척추에 운동장애가 남은 사람
 3.  한쪽 손의 엄지손가락을 포함하여 2개의 손가락을 잃은 사람
 4.  한쪽 손의 엄지손가락과 둘째손가락을 제대로 못쓰게 된 사람 또는 한쪽 손의 엄지손가락이나 둘째
   손가락을 포함하여 3개 이상의 손가락을 제대로 못쓰게 된 사람
 5.  한쪽 다리가 5센티미터 이상 짧아진 사람
 6.  한쪽 팔의 3대 관절 중 1개 관절을 제대로 못쓰게 된 사람
 7.  한쪽 다리의 3대 관절 중 1개 관절을 제대로 못쓰게 된 사람
 8.  한쪽 팔에 가관절이 남은 사람
 9.  한쪽 다리에 가관절이 남은 사람
 10.  한쪽 발의 발가락을 모두 잃은 사람
 11.  비장 또는 한쪽의 신장을 잃은 사람
9급
3천
800만원
 1.  두 눈의 시력이 각각 0.6 이하로 된 사람
 2.  한쪽 눈의 시력이 0.06 이하로 된 사람
 3.  두 눈에 반맹증ㆍ시야협착 또는 시야결손이 남은 사람
 4.  두 눈의 눈꺼풀에 뚜렷한 결손이 남은 사람
 5.  코가 결손되어 그 기능에 뚜렷한 장애가 남은 사람
 6.  말하는 기능과 음식물을 씹는 기능에 장애가 남은 사람
 7.  두 귀의 청력이 모두 1미터 이상의 거리에서는 보통의 말소리를 알아듣지 못하게 된 사람
 8.  한쪽 귀의 청력이 귀에 입을 대고 말하지 아니하면 큰 말소리를 알아듣지 못하고 다른 쪽 귀의 청력
   이 1미터 이상의 거리에서는 보통의 말소리를 알아듣지 못하게 된 사람
 9.  한쪽 귀의 청력을 완전히 잃은 사람
 10.  한쪽 손의 엄지손가락을 잃은 사람 또는 둘째손가락을 포함하여 2개의 손가락을 
   잃은 사람 또는 엄지손가락과 둘째손가락 외의 3개의 손가락을 잃은 사람
 11.  한쪽 손의 엄지손가락을 포함하여 2개의 손가락을 제대로 못쓰게 된 사람
 12.  한쪽 발의 엄지발가락을 포함하여 2개 이상의 발가락을 잃은 사람
 13.  한쪽 발의 발가락을 모두 제대로 못쓰게 된 사람
 14.  생식기에 뚜렷한 장애가 남은 사람
 15.  신경계통의 기능 또는 정신기능에 장애가 남아 노무가 상당한 정도로 제한된 사람
 16.  흉복부 장기의 기능에 장애가 남아 노무가 상당한 정도로 제한된 사람
장애
급별  
한도금액 
신체장애  내용 
10급
11급
2천
700만원
2천
300만원
  1.  한쪽 눈이 시력이 0.1 이하로 된 사람
 2.  말하는 기능이나 음식물을 씹는 기능에 장애가 남은 사람
 3.  14개 이상의 치아에 대하여 치과보철을 한 사람
 4.  한쪽 귀의 청력이 귀에 입을 대고 말하지 아니하면 큰 말소리를 알아듣지 못하게 된 사람
 5.  두 귀의 청력이 모두 1미터 이상의 거리에서 보통의 말소리를 듣는 데 지장이 있는 사람
 6.  한쪽 손의 둘째손가락을 잃은 사람 또는 엄지손가락과 둘째 손가락 외의 2개의 손가락을 잃은 사람
 7.  한쪽 손의 엄지손가락을 제대로 못쓰게 된 사람 또는 한쪽 손의 둘째손가락을 포함하여 2개의 손가
   락을 제대로 못쓰게 된 사람 또는 한 쪽 손의 엄지손가락과 둘째손가락 외의 3개의 손가락을 제대로 
   못쓰게 된 사람
 8.  한쪽 다리가 3센티미터 이상 짧아진 사람
 9.  한쪽 발의 엄지발가락 또는 그 외의 4개의 발가락을 잃은 사람
 10.  한쪽 팔의 3대 관절 중 1개 관절의 기능에 뚜렷한 장애가 남은 사람
 11.  한쪽 다리의 3대 관절 중 1개 관절의 기능에 뚜렷한 장애가 남은 사람
 1.  두 눈이 모두 근접반사 기능에 뚜렷한 장애가 남거나 뚜렷한 운동장애가 남은 사람
 2.  두 눈의 눈꺼풀에 뚜렷한 장애가 남은 사람
 3.  한쪽 눈의 눈꺼풀에 결손이 남은 사람
 4.  한쪽 귀의 청력이 40센티미터 이상의 거리에서는 보통의 말소리를 알아듣지 못하게 된 사람
 5.  두 귀의 청력이 모두 1미터 이상의 거리에서는 작은 말소리를 알아듣지 못하게 된 사람
 6.  척주에 기형이 남은 사람
 7.  한쪽 손의 가운데손가락 또는 넷째손가락을 잃은 사람
 8.  한쪽 손의 둘째손가락을 제대로 못쓰게 된 사람 또는 한쪽 손의 엄지손가락과 둘째손가락 외의 2개
   의 손가락을 제대로 못쓰게 된 사람
 9.  한쪽 발의 엄지발가락을 포함하여 2개 이상의 발가락을 제대로 못쓰게 된 사람
 10.  흉복부 장기의 기능에 장애가 남은 사람
 11.  10개 이상의 치아에 대하여 치과보철을 한 사람
장애
급별  
한도금액 
신체장애  내용 
12급
13급
1천
900만원
1천
500만원
 1.  한쪽 눈의 근접반사 기능에 뚜렷한 장애가 있거나 뚜렷한 운동장애가 남은 사람
 2.  한쪽 눈의 눈꺼풀에 뚜렷한 운동장애가 남은 사람
 3.  7개 이상의 치아에 대하여 치과보철을 한 사람
 4.  한쪽 귀의 귓바퀴가 대부분 결손된 사람
 5.  쇄골(빗장뼈), 복장뼈(흉골), 갈비뼈, 어깨뼈 또는 골반뼈에 뚜렷한 기형이 남은 사람
 6.  한쪽 팔의 3대 관절 중 1개 관절의 기능에 장애가 남은 사람
 7.  한쪽 다리의 3대 관절 중 1개 관절의 기능에 장애가 남은 사람
 8.  장관골에 기형이 남은 사람
 9.  한쪽 손의 가운데손가락이나 넷째손가락을 제대로 못쓰게 된 사람
 10.  한쪽 발의 둘째발가락을 잃은 사람 또는 한쪽 발의 둘째발가락을 포함하여 2개의 발가락을 잃은 사
   람 또는 한쪽 발의 가운데 발가락 이하의 3개의 발가락을 잃은 사람
 11.  한쪽 발의 엄지발가락 또는 그 외의 4개의 발가락을 제대로 못쓰게 된 사람
 12.  국부에 뚜렷한 신경증상이 남은 사람
 13.  외모에 흉터가 남은 사람
  1.  한쪽 눈의 시력이 0.6 이하로 된 사람
 2.  한쪽 눈에 반맹증, 시야협착 또는 시야결손이 남은 사람
 3.  두 눈의 눈꺼풀의 일부에 결손이 남거나 속눈썹에 결손이 남은 사람
 4.  5개 이상의 치아에 대하여 치과보철을 한 사람
 5.  한쪽 손의 새끼손가락을 잃은 사람
 6.  한쪽 손의 엄지손가락 마디뼈의 일부를 잃은 사람
 7.  한쪽 손의 둘째손가락 마디뼈의 일부를 잃은 사람
 8.  한쪽 손의 둘째손가락의 끝관절을 굽히고 펼 수 없게 된 사람
 9.  한쪽 다리가 1센티미터 이상 짧아진 사람
 10.  한쪽 발의 가운데발가락 이하의 발가락 1개 또는 2개를 잃은 사람
 11.  한쪽 발의 둘째발가락을 제대로 못쓰게 된 사람 또는 한쪽 발이 둘째발가락을 포함하여 2개의 발가
   락을 제대로 못쓰게 된 사람 또는 한쪽 발의 가운데 발가락 이하의 발가락 3개를 제대로 못쓰게 된 
   사람
88
89
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (47, 1, 47, '자동차보험의 구성
보상하는 내용
보험금, 손해배상 청구
일반사항
보험금지급기준
붙임
비 고
 1. 신체장애가 둘 이상 있는 경우에는 중한 신체장애에 해당하는 장애등급보다 한 등급 높은 금액으로 배상한다.
 2.  시력의 측정은 국제식 시력표로 하며, 굴절 이상이 있는 사람에 대하여는 원칙적으로 교정시력을 측정한다.
 3.  "손가락을 잃은 것"이란 엄지손가락은 가락뼈사이관절, 그 밖의 손가락은 몸쪽가락뼈사이관절 이상을 잃은 경우를 말한다.
 4.  "손가락을 제대로 못쓰게 된 것"이란 손가락 끝부분의 2분의 1 이상을 잃거나 손허리손가락관절(중수지관절) 또는 몸쪽가락뼈
   사이관절(엄지손가락의 경우에는 가락뼈사이관절을 말한다)에 뚜렷한 운동장애가 남은 경우를 말한다.
 5.  “발가락을 잃은 것”이란 발가락의 전부를 잃은 경우를 말한다.
 6. . "발가락을 제대로 못쓰게 된 것"이란 엄지발가락은 끝관절의 2분의 1 이상을, 그 밖의 발가락은 끝관절 이상을 잃거나 발허리발
   가락관절(중족지관절) 또는 몸쪽가락뼈사이관절(엄지발가락의 경우에는 가락뼈사이관절을 말한다)에 뚜렷한 운동장애가 남은 
   경우를 말한다.
 7.  "흉터가 남은 것"이란 성형수술을 한 후에도 맨눈으로 식별이 가능한 흔적이 있는 상태를 말한다.
 8.  “항상 보호를 받아야 하는 것”이란 일상생활에서 기본적인 음식섭취, 배뇨 등을 다른 사람에게 의존하여야 하는 것을 말한다.
 9. “수시로 보호를 받아야 하는 것”이란 일상생활에서 기본적인 음식섭취, 배뇨 등은 가능하나, 그 외의 일은 다른 사람에게 의존하
   여야 하는 것을 말한다.
 10.  “항상보호 또는 수시보호를 받아야 하는 기간”은 의사가 판정하는 노동능력상실기간을 기준으로 하여 타당한 기간으로 정한다.
 11.  “제대로 못 쓰게 된 것”이란 정상기능의 4분의 3 이상을 상실한 경우를 말하고, “뚜렷한 장애가 남은 것”이란 정상기능의 2분의 
   1 이상을 상실한 경우를 말하며, “장애가 남은 것”이란 정상기능의 4분의 1 이상을 상실한 경우를 말한다.
 12.  “신경계통의 기능 또는 정신기능에 뚜렷한 장애가 남아 특별히 손쉬운 노무 외에는 종사할 수 없는 것”이란 신경계통의 기능 또
   는 정신기능의 뚜렷한 장애로 노동능력이 일반인의 4분의 1 정도만 남아 평생 동안 특별히 쉬운 일 외에는 노동을 할 수 없는 사
   람을 말한다.
 13.  “신경계통의 기능 또는 정신기능에 장애가 남아 노무가 상당한 정도로 제한된 것”이란 노동능력이 어느 정도 남아 있으나 신경계
   통의 기능 또는 정신기능의 장애로 종사할 수 있는 직종의 범위가 상당한 정도로 제한된 경우로서 다음 각 목의 어느 하나에 해당
   하는 경우를 말한다.
  가.  신체적 능력은 정상이지만 뇌손상에 따른 정신적 결손증상이 인정되는 경우
  나.  전간(癲癎) 발작과 현기증이 나타날 가능성이 의학적ㆍ타각적(他覺的) 소견으로 증명되는 사람
  다.  팔다리에 경도(輕度)의 단마비(單痲痺)가 인정되는 사람
 14.  “흉복부 장기의 기능에 뚜렷한 장애가 남아 특별히 손쉬운 노무 외에는 종사할 수 없는 것”이란 흉복부 장기의 장애로 노동능력
   이 일반인의 4분의 1 정도만 남은 경우를 말한다.
 15.  “흉복부 장기의 기능에 장애가 남아 손쉬운 노무 외에는 종사할 수 없는 것”이란 중등도(中等度)의 흉복부 장기의 장애로 노동능
   력이 일반인의 2분의 1 정도만 남은 경우를 말한다.
 16.  “흉복부 장기의 기능에 장애가 남아 노무가 상당한 정도로 제한된 것”이란 중등도의 흉복부 장기의 장애로 취업가능한 직종의 범
   위가 상당한 정도로 제한된 경우를 말한다.
장애
급별  
한도금액 
신체장애  내용 
14급
1천만원
  1.  한쪽 눈의 눈꺼풀의 일부에 결손이 있거나 속눈썹에 결손이 남은 사람
 2.  3개 이상의 치아에 대하여 치과보철을 한 사람
 3.  한쪽 귀의 청력이 1미터 이상의 거리에서는 보통의 말소리를 알아듣지 못하게 된 사람
 4.  팔의 노출된 면에 손바닥 크기의 흉터가 남은 사람
 5.  다리의 노출된 면에 손바닥 크기의 흉터가 남은 사람
 6.  한쪽 손의 새끼손가락을 제대로 못쓰게 된 사람
 7.  한쪽 손의 엄지손가락과 둘째손가락 외의 손가락 마디뼈의 일부를 잃은 사람
 8.  한 손의 엄지손가락과 둘째손가락 외의 손가락 끝 관절을 제대로 못쓰게 된 사람
 9.  한 발의 가운데발가락 이하의 발가락 1개 또는 2개를 제대로 못쓰게 된 사람
 10.  국부에 신경증상이 남은 사람
보통약관에 보상내용을 확대(추가)하시거나 제한(축소)하실 때
고객님이 선택 가입할 수 있는 특별약관 본문내용 입니다.
(※ 특별약관은 증권에 명기된 것에 한정하여 적용됩니다.)
90
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (48, 1, 48, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
Ⅰ. 운전가능자에 대한 제한
1. 운전자 한정운전 특별약관
1. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)를 운전할 자를 
만 21/22/24/26/28/30/35/43/48세 이상으로 한정하는 경우에는 이 특별약관이 정하는 바에 따라 보상합니다.
2. 보상하지 않는 손해  
① 회사는 이 특별약관에 따라 만 21/22/24/26/28/30/35/43/48세 미만의 자(*1)가 피보험자동차를 운전하던 
  중에 발생된 사고는 보상하지 않습니다.
②  위 ‘①’에도 불구하고 다음 중 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.  
1⃞  운전자연령 만 21/22/24/26/28/30/35/43/48세 이상 한정운전 특별약관
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
(*1) ‘만 21/22/24/26/28/30/35/43/48세 미만의 자’란 주민등록상의 생년월일을 기준으로 사고일 현재 
   만 21/22/24/26/28/30/35/43/48세 미만의 사람을 말합니다.
구분
예외적용
1) 보험계약자 또는 피보험자에게 이 
  특별약관의 내용을 알려 주었다는 
  사실을 회사가 증명할 수 없는 경우
2) 피보험자동차를 도난당했을 때, 그 
  도난당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경우
3) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅱ, 대물배상, 자기신체사고, 무보험자동차에 의
한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 Family 
통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 가입금
액 확장담보 특별약관을 보상함
보통약관 대인배상Ⅰ·Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
※  피보험자동차를 운전할 수 있는 사람의 범위를 제한하는 특약으로 기명피보험자와의 관계(가족 또는 
  부부 등의 관계)를 기준으로 하는 운전자 한정운전 특별약관과 운전자의 연령을 기준으로 하는 운전자 
  연령한정 특별약관으로 구성되어 있습니다.
  이 특별약관에 가입할 경우, 일정 부분의 보험료를 절감하는 효과가 있으나 운전가능자 이외의 자가 
  운전 시에 발생하는 사고에 대해서는 대인배상Ⅰ(책임보험)을 제외한 담보는 보상 받을 수 없으므로 
  주의하셔야 합니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
2. 보상하지 않는 손해  
① 회사는 이 특별약관에 따라 기명피보험자와 그 가족 이외의 자가 피보험자동차를 운전하던 중에 발생한 사고는 
  보상하지 않습니다.
②  위 ‘①’에도 불구하고 다음 중 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.  
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관에 따릅니다.
4. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용받지 않
습니다.
(*1) ‘가족’이란 다음 중 어느 하나에 해당하는 사람을 말합니다.지식74)
   (1) 기명피보험자의 부모, 양부모, 계부모 
   (2) 기명피보험자의 배우자의 부모, 양부모, 계부모
   (3) 법률상의 배우자 또는 사실혼 관계의 배우자 
   (4) 법률상의 혼인 관계 또는 사실혼 관계에서 출생한 자녀, 양자녀
   (5) 법률상의 혼인 관계로 인한 계자녀 
   (6) 기명피보험자의 며느리(계자녀의 배우자 포함) 또는 사위(계자녀의 배우자 포함)
구분
예외적용
1) 피보험자동차를 도난당했을 때, 그 
  도난당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경
  우
2) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅰ·Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
74) “가족”의 정의에서 양부모, 양자녀, 사실혼, 계부모, 계자녀는 통상 다음과 같습니다. 
   ◦ “양부모”, “양자녀” : 입양에 의해 부모 또는 자녀의 자격을 얻은 사람
   ◦ “사실혼” : 혼인신고를 하지 않았기 때문에 법률상의 부부는 아니지만, 사실상 부부의 관계에 있는 상태
   ◦ “계부모” : 계부(어머니가 재혼하여 생긴 아버지)와 계모(아버지가 재혼하여 생긴 어머니)
   ◦ “계자녀” : 재혼한 경우, 배우자가 재혼을 하면서 데리고 온 자녀
4. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용받지 않
습니다.
1. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)를 운전할 자를 
보험증권에 기재된 피보험자(이하 “기명피보험자”라 함)와 그 가족(*1)으로 한정하는 경우에는 이 특별약관이 정하
는 바에 따라 보상합니다. 
2⃞  가족운전자 한정운전 특별약관
92
93
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (49, 1, 49, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
1. 적용대상  
이 추가특별약관은 가족운전자 한정운전 특별약관에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용  
회사는 가족운전자 한정운전 특별약관 ‘2.’에도 불구하고 보험증권에 기재된 추가운전자 1인이 피보험자동차를 운
전하던 중에 발생한 사고는 그 추가운전자를 가족운전자 한정운전 특별약관 ‘1.’에서 정한 운전가능자로 보아 보상
하여 드립니다. 
3. 준용규정  
이 추가특별약관에서 정하지 않은 사항은 보통약관 및 가족운전자 한정운전 특별약관을 따릅니다.
2⃞-①  가족 외 1인 운전자 추가담보 추가특별약관
(*1) 이 특별약관에서 ‘가족 및 형제자매’는 다음 중 어느 하나에 해당하는 사람을 말합니다.
   (1) 기명피보험자의 부모, 양부모, 계부모
   (2) 기명피보험자의 배우자의 부모, 양부모, 계부모
   (3) 법률상의 배우자 또는 사실혼 관계의 배우자 
   (4) 법률상의 혼인 관계 또는 사실혼 관계에서 출생한 자녀, 양자녀
   (5) 법률상의 혼인 관계로 인한 계자녀
   (6) 기명피보험자의 며느리(계자녀의 배우자 포함) 또는 사위(계자녀의 배우자 포함)
   (7) 기명피보험자의 법률상의 형제, 자매 및 기명피보험자의 부모의 양자, 양녀로 인한 형제, 자매
구분
예외적용
1) 피보험자동차를 도난당했을 때, 그 
  도난당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경
  우
2) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅰ·Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
1. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)를 운전할 자를 
보험증권에 기재된 피보험자(이하 “기명피보험자”라 함)와 그 가족 및 형제자매(*1)로 한정하는 경우에는 이 특별
약관이 정하는 바에 따라 보상합니다. 
3⃞  가족 및 형제자매 운전자 한정운전 특별약관
2. 보상하지 않는 손해  
① 회사는 이 특별약관에 따라 기명피보험자와 그 가족 및 형제자매 이외의 자가 피보험자동차를 운전하던 중에 발
  생한 사고는 보상하지 않습니다.
②  위 ‘①’에도 불구하고 다음 중 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.  
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
2. 보상하지 않는 손해  
① 회사는 이 특별약관에 따라 기명피보험자와 그 배우자 이외의 자가 피보험자동차를 운전하던 중에 발생한 사고
  는 보상하지 않습니다.
②  위 ‘①’에도 불구하고 다음 중 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.                     
1. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)를 운전할 자를 
보험증권에 기재된 피보험자(이하 “기명피보험자”라 함)와 기명피보험자의 배우자(*1)로 한정하는 경우에는 이 특
별약관이 정하는 바에 따라 보상합니다.
䣪  부부 운전자 한정운전 특별약관
(*1) ‘기명피보험자의 배우자’는 기명피보험자의 법률상의 배우자 또는 사실혼 관계에 있는 배우자를 말합니다.
구분
예외적용
1) 피보험자동차를 도난당했을 때, 그 
  도난당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경
  우
2) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅰ·Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
4. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용받지 않
습니다.
1. 적용대상  
이 추가특별약관은 부부 운전자 한정운전 특별약관에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용  
회사는 부부 운전자 한정운전 특별약관 ‘2.’에도 불구하고 보험증권에 기재된 추가운전자 1인이 피보험자동차를 운
전하던 중에 발생한 사고는 그 추가운전자를 부부 운전자 한정운전 특별약관 ‘1.’에서 정한 운전가능자로 보아 보상
하여 드립니다.  
䣪-①  부부 외 1인 운전자 추가담보 추가특별약관
4. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용받지 않
습니다.
94
95
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (50, 1, 50, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
3. 준용규정  
이 추가특별약관에서 정하지 않은 사항은 보통약관 및 부부 운전자 한정운전 특별약관을 따릅니다.
1. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)를 운전할 자를 
보험증권에 기재된 피보험자(이하 “기명피보험자”라 함)와 기명피보험자의 배우자(*1) 및 자녀(*2)로 한정하는 경우
에는 이 특별약관이 정하는 바에 따라 보상합니다.
䣫  부부 및 자녀 운전자 한정운전 특별약관
(*1) ‘기명피보험자의 배우자’는 기명피보험자의 법률상의 배우자 또는 사실혼 관계에 있는 배우자를 말합니다.
(*2) ‘기명피보험자의 자녀’는 다음 중 어느 하나에 해당하는 사람을 말합니다.
        (1) 법률상의 혼인 관계 또는 사실혼 관계에서 출생한 자녀, 양자녀
        (2) 법률상의 혼인 관계로 인한 계자녀
        (3) 기명피보험자의 며느리(계자녀의 배우자 포함) 또는 사위(계자녀의 배우자 포함)
2. 보상하지 않는 손해  
① 회사는 이 특별약관에 따라 기명피보험자와 그 배우자 및 자녀 이외의 자가 피보험자동차를 운전하던 중에 발생
  한 사고는 보상하지 않습니다.
②  위 ‘①’에도 불구하고 다음 중 어느 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.
구분
예외적용
1) 피보험자동차를 도난당했을 때, 그 
  도난당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경
  우
2) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅰ·Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
4. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용받지 않
습니다.
1. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)를 운전할 자를 
보험증권에 기재된 피보험자(이하 “기명피보험자”라 함) 1인으로 한정하는 경우에는 이 특별약관이 정하는 바에 
따라 보상합니다. 
䣬  기명피보험자 1인 한정운전 특별약관
(*1) ‘기명피보험자의 자녀’는 다음 중 어느 하나에 해당하는 사람을 말합니다.
        (1) 법률상의 혼인 관계 또는 사실혼 관계에서 출생한 자녀, 양자녀
        (2) 법률상의 혼인 관계로 인한 계자녀
        (3) 기명피보험자의 며느리(계자녀의 배우자 포함) 또는 사위(계자녀의 배우자 포함)
2. 보상하지 않는 손해  
① 회사는 이 특별약관에 따라 기명피보험자와 그  자녀 이외의 자가 피보험자동차를 운전하던 중에 발생한 사고는 
  보상하지 않습니다.
② 위 ‘①’에도 불구하고 다음 중 어느 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.
구분
예외적용
1) 피보험자동차를 도난당했을 때, 그 
  도난당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경
  우
보통약관 대인배상Ⅰ·Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
2. 보상하지 않는 손해  
① 회사는 이 특별약관에 따라 기명피보험자 이외의 자가 피보험자동차를 운전하던 중에 발생한 사고는 보상하지 
  않습니다.
②  위 ‘①’에도 불구하고 다음 중 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.  
구분
예외적용
1) 피보험자동차를 도난당했을 때, 그 
  도난당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경
  우
2) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅰ·Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
4. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용받지 않
습니다.
1. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)를 운전할 자를 
보험증권에 기재된 피보험자(이하 “기명피보험자”라 함)와 기명피보험자의 자녀(*1)로 한정하는 경우에는 이 특별
약관이 정하는 바에 따라 보상합니다.  
䣭  기명피보험자 1인 및 자녀 운전자 한정운전 특별약관
96
97
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (51, 1, 51, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
4. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용받지 않
습니다.
2) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
구분
예외적용
1) 피보험자동차를 도난당했을 때, 그 
  도난당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경
  우
보통약관 대인배상Ⅰ·Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
1. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)를 운전할 자를 
보험증권에 기재된 운전자(이하 “지정운전자”라 함) 1인으로 한정하는 경우에는 이 특별약관이 정하는 바에 따라 
보상합니다.  
2. 보상하지 않는 손해  
① 회사는 이 특별약관에 따라 지정운전자 이외의 자가 피보험자동차를 운전하던 중에 발생한 사고는 보상하지 않
  습니다.
②  위 ‘①’에도 불구하고 다음 중 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.  
䣮  지정운전자 1인 한정운전 특별약관
구분
예외적용
2) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
4. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용받지 않
습니다.
1. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)를 운전할 자를 
보험증권에 기재된 피보험자(이하 ‘기명피보험자’라 함)와 기명피보험자가 지정한 기명 1인 운전자로 한정하는 경
우에는 이 특별약관이 정하는 바에 따라 보상합니다.  
2. 보상하지 않는 손해  
① 회사는 이 특별약관에 따라 기명피보험자와 추가 지정된 기명 1인 운전자 이외의 자가 피보험자동차를 운전하
  던 중에 발생한 사고는 보상하지 않습니다.
②  위 ‘①’에도 불구하고 다음 중 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.  
䣯  기명피보험자 및 기명 1인 운전자 한정운전 특별약관
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
4. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용받지 않
습니다.
구분
예외적용
1) 피보험자동차를 도난당했을 때, 그 
  도난당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경
  우
2) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅰ·Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
1. 보상하는 손해  
보험회사(이하 “회사”라 함)는 보험증권에 기재된 피보험자(이하 “기명피보험자”라 함)가 보험증권에 기재된 자
동차(이하 “피보험자동차”라 함)에 대하여 운전할 자를 기명피보험자가 사업자등록을 한 사업장 소속의 임직원(*1)
으로 한정하는 경우에는 이 특별약관이 정하는 바에 따라 보상합니다 . 
2. 보상하지 않는 손해  
①  회사는 이 특별약관에서 정하는 임직원 이외의 자가 피보험자동차를 운전하던 중에 발생된 사고에 대하여는 보
  험금을 지급하지 않습니다.
䣰  임직원 운전자 한정운전 특별약관
(*1) 이 특별약관에서 임직원이라 함은 다음 중 하나에 해당하는 사람을 말합니다.
   [1] 기명피보험자
   [2] 기명피보험자와 근로계약을 체결한 직원(계약직 직원 포함. 단, 계약직 직원의 경우 피보험자와 체결한 근
     로계약기간에 한정)
   [3] 기명피보험자와 계약관계에 있는 자로서 기명피보험자의 업무를 위하여 피보험자동차를 운행하는 자
   [4] 기명피보험자의 운전자 채용을 위한 면접에 응시한 지원자
98
99
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (52, 1, 52, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
구분
예외적용
1) 피보험자동차를 도난 당했을 때, 그 
  도난 당했을 때부터 발견될 때까지 
  발생한 피보험자동차의 사고의 경
  우
2) 관련법규에 의해 사업자등록을 한 
  자동차 취급업자가 업무상 위탁받
  은 피보험자동차를 사용하거나 관
  리하던 중 발생된 피보험자동차의 
  사고로 피보험자가 배상책임을 부
  담하는 경우
보통약관 대인배상Ⅰ䞱Ⅱ, 대물배상, 자기신체사고, 무보험자동차
에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 
가입금액 확장담보 특별약관을 보상함
보통약관 대인배상Ⅱ, 대물배상을 보상함. 다만, 자동차 취급업자가 
가입한 보험계약 등에서 보험금이 지급될 수 있는 경우에는 그 보험
금을 초과하는 손해만을 보상하고, 대물배상의 경우 자동차손해배상
보장법 제5조, 같은 법 시행령 제3조에서 정하는 금액을 한도로 함
3. 보험계약자 및 피보험자의 의무  
① 회사는 피보험자동차를 운전한 자가 이 특별약관에서 정한 임직원임을 확인하는데 필요한 재직증명서, 근로계
  약서, 기명피보험자의 사업자등록증 등의 서류를 보험계약자 및 피보험자에게 요청할 수 있으며, 이 경우 보험
  계약자 및 피보험자는 운전자가 임직원임을 증명하는 서류를 회사에 제출해야 합니다.
②  회사는 보험계약자 및 피보험자가 위 ‘①’의 규정을 위반하여 입증서류를 회사에 제출하지 않는 경우 보험금을 
  지급하지 않을 수 있습니다.
4. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관에 따릅니다.
5. 기타  
이 특별약관은 대인배상Ⅰ에는 적용되지 않으므로, 대인배상Ⅰ은 이 특별약관에 따른 운전자 한정을 적용하지 않
습니다.
2. 운전자 범위 확대 특별약관
1. 가입대상  
이 특별약관은 보통약관의 대인배상Ⅰ·Ⅱ, 대물배상(또는 대물배상 가입금액 확장담보 특별약관)을 모두 가입한 
경우에만 가입할 수 있습니다. 
2. 보상내용  
① 보험회사(이하 “회사”라 함)는 이 특별약관에 따라 대리운전자(*1)가 기명피보험자 또는 피보험자동차를 사용
  할 정당한 권리가 있는 자의 요청에 의해 피보험자동차를 운전하던 중(주차 또는 정차 중은 제외함) 발생한 사
  고에 대하여 해당 대리운전자를 보통약관의 피보험자로 보아 보상하여 드립니다. 
② 위 ‘①’ 에도 불구하고 피보험자동차에 운전자 한정운전 특별약관이 가입되어 있는 경우 대리운전자는 대물배상
  (자동차손해배상보장법 제5조 및 동법시행령 제3조의 금액한도 내) 및 대인배상Ⅱ의 피보험자로 보지 않으며 
  운전자 한정운전 특별약관이 가입되지 않은 경우 대리운전자는 대인배상Ⅱ의 피보험자로 보지 않습니다.
③  위 ‘①’의 사고 시 피보험자동차를 운전한 대리운전자가 보험증권에 기재된 운전가능범위 외일지라도 그 사고로 
  인한 손해를 보상하여 드립니다. 단, 운전자 한정운전 특별약관의 예외적용에 따라서 보험금이 지급될 수 있는 
  경우에는 그 보험금을 초과하는 손해만 보상하여 드립니다.
1⃞  대리운전자 사고 보상 특별약관
②  위 ‘①’에도 불구하고 다음 중 하나에 해당하는 경우에는 예외적용에 따라 보상하여 드립니다.     
(*1) ‘대리운전자’란 대리운전업무 종사자로써 소속업체를 위하여 사업자등록증상 명시된 대리운전업무를 수행하
   기 위해 운전하는 자(전속 및 비전속 모두 포함)를 말합니다. (단, 자동차정비업, 주차장업, 급유업, 세차업, 
   자동차판매업(자동차판매사원을 포함), 자동차탁송업 등 자동차를 취급하는 것을 업으로 하는 자는 제외)
④ 위 ‘①’의 사고로 발생한 손해에 대하여 자동차취급업자 종합보험 또는 대리운전업자보험 등의 다른 보험계약에
  서 보험금이 지급될 수 있는 경우에는 회사가 보상해야 할 금액이 그 다른 보험계약에서 지급될 수 있는 금액을 
  초과할 때에 한정하여 그 초과액만을 이 특별약관에 따라 보상합니다.
3. 보상하지 않는 손해  
회사는 보통약관 제5조/8조/14조/19조/23조(이상 ‘보상하지 않는 손해’)에서 정하는 사항은 보상하지 않고, 또
한 기명피보험자 또는 피보험자동차를 사용할 정당한 권리가 있는 자의 요청한 목적에 반하여 통상적인 경로를 현
저히 이탈하여 피보험자동차를 운전하던 중 발생한 사고로 인한 손해도 보상하지 않습니다.
4. 준용규정  
이 특별약관에서 정하지 않는 사항은 보통약관을 따릅니다.
1. 가입대상  
이 특별약관은 운전자 한정운전 특별약관에 가입한 경우에만 가입할 수 있습니다.
2. 보상내용  
① 보험회사(이하 ‘회사’라 함)는 운전자 한정운전 특별약관 ‘2.’에도 불구하고 운전자 한정운전 특별약관 ‘1.’에서 
  정한 운전가능자(피보험자동차를 운전할 수 있는 운전면허증 소지자만을 말함)가 탑승한 상태에서 임시운전
  자(*1)가 피보험자동차를 운전하던 중에 발생한 사고는 임시운전자를 운전가능자로 보아 이 특별약관에 따라 보
  상하여 드립니다.
②  회사가 보상해야 할 손해에 대하여 피보험자 또는 임시운전자에게 적용되는 다른 자동차 운전담보 특별약관 등 
  다른 자동차의 보험계약에 따라 보험금이 지급될 수 있는 경우에는 회사가 보상해야 할 금액이 피보험자 또는 
  임시운전자에게 적용되는 다른 자동차보험계약에 따라 지급될 수 있는 금액을 초과하는 때에 한정하여 그 초과
  액만을 보상합니다.
2⃞  임시운전자 담보 특별약관
(*1) ‘임시운전자’란 운전자 한정운전 특별약관 ‘1.’에서 정한 운전가능자를 대신하여 피보험자동차를 임시로 
   대리 운전하는 사람을 말합니다. 단, 다음의 사람은 제외합니다. 
   (1) 기명피보험자 또는 기명피보험자의 법률상의 배우자(사실혼 관계 배우자 포함)
   (2) 기명피보험자의 부모, 양부모, 계부모
   (3) 기명피보험자의 배우자의 부모, 양부모, 계부모
   (4) 기명피보험자의 법률상의 혼인 관계 또는 사실혼 관계에서 출생한 자녀, 양자녀
   (5) 기명피보험자의 법률상의 혼인 관계로 인한 계자녀 
   (6) 기명피보험자의 며느리(계자녀의 배우자 포함)  또는 사위(계자녀의 배우자 포함)
   (7) 기명피보험자 또는 그 배우자와 동거 중인 자 
   (8) 기명피보험자의 사용자지식75) 및 그 사용자의 피용자지식75). 다만, 기명피보험자가 피보험자동차를 사용자
     의 업무에 사용하고 있는 때만을 말함
   (9) 기명피보험자의 피용자
   (10) 자동차취급업자(다만, 이들이 피보험자동차를 업무로서 위탁 받아 사용 또는 관리하는 경우만을 말하
      며, 음주운전 대리업자는 자동차취급업자에서 제외)
   (11) 피보험자동차를 임시적으로 운전하지 않고 통상적으로 운전하는 자
75) 보통약관 36쪽 프로미카 보험지식 ‘07)’  및 보통약관 37쪽 프로미카 보험지식 ‘09)’  참조
100
101
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (53, 1, 53, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
Ⅱ. 자기신체사고의 보상 확대
1. 가입대상 등  
이 특별약관은 보통약관 대인배상Ⅰ·Ⅱ, 대물배상(또는 대물배상 가입금액 확장담보 특별약관), 무보험자동차에 
의한 상해를 모두 가입한 경우에만 가입 가능하며, 가입 시 보통약관 자기신체사고를 이 특별약관으로 대체하여 적
용합니다.
2. 보상내용  
보험회사(이하 ‘회사’라 함)는 피보험자가 다음 중 하나의 자동차(*1) 사고로 상해를 입어 그 직접적인 결과로 죽거
나 다친 경우의 손해를 보상하여 드립니다. 
 1) 보통약관 자기신체사고 제12조(보상하는 손해)의 사고
 2) 위 ‘1)’ 이외의 그 밖의 자동차 사고(*2) (탑승 여부와 관계없음)  
1⃞  자동차상해 Family 통합보장 특별약관
※ 이 특약들을 가입함으로써 사고 발생 시 보통약관에서 보장되는 내용 이외에 해당 특별약관에서 보장
  하는 내용을 추가적으로 보상을 받을 수 있습니다.
※  이 특별약관은 보통약관 자기신체사고 또는 자동차상해 특별약관, 보행 중 상해 특별약관과 중복하여 
  가입할 수 없습니다.
(*1) 자동차
피보험자동차 및 피보험자동차 이외의 자동차(자동차관리법에 의한 자동차, 군수품관리법에 의한 차량, 건설기계 관
리법에 의한 건설기계, 농업기계화촉진법에 의한 농업기계, 도로교통법에 의한 원동기장치자전거를 말함)
(*2) 그 밖의 자동차 사고
피보험자동차 이외의 자동차에 탑승 중이거나 보행 중 등일 때의 자동차의 운행으로 인한 사고를 말합니다. 
단, 다음 중 하나에 해당하는 경우는 제외합니다.
(1) 피보험자가 피보험자동차가 아닌 자동차를 운전하는 경우
(2) 피보험자를 죽게 하거나 다치게 한 자동차 또는 피보험자가 탑승 중인 자동차가 다음의 사람이 소유하거나 통상 
  사용하는 자동차인 경우
 ㉠  기명피보험자와 그 부모, 배우자, 자녀
 ㉡ 기명피보험자의 배우자의 부모(동거 중인 경우만을 말함)
(3) 다음의 사람이 배상의무자일 경우. 다만, 이들이 운전하지 않은 경우로, 이들 이외에 다른 배상의무자가 있는 경
  우에는 보상합니다. 
3. 보상하지 않는 손해  
회사는 보통약관 제5조/8조/14조/19조/23조(이상 ‘보상하지 않는 손해’)에서 정하는 사항은 보상하지 않고, 또
한 다음과 같은 손해도 보상하지 않습니다.  
 1) 임시 대리운전자가 피보험자동차를 계속적, 반복적으로 운전하던 중 발생한 사고로 인한 손해   
 2) 운전자 한정운전 특별약관 ‘1.’에서 정한 운전가능자(피보험자동차를 운전할 수 있는 운전면허증 소지자만을 
   말함)가 피보험자동차에 탑승하지 않은 상태에서 임시운전자가 피보험자동차를 운전하던 중 발생한 사고로 
   인한 손해
4. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관 및 운전자 한정운전 특별약관에 따릅니다.
 ㉠ 상해를 입은 피보험자의 부모, 배우자, 자녀
 ㉡ 피보험자가 사용자의 업무에 종사하고 있을 때 피보험자의 사용자 또는 피보험자의 사용자의 업무에 종사 중
   인 다른 피용자
(4) 자동차 취급업자인 피보험자가 업무상 수탁 받은 자동차에 탑승 중 사고 또는 수탁 받은 자동차에 의해 그 본인
  이 상해를 입은 때.
(5) 건설기계관리법에 의한 건설기계 또는 농업기계화촉진법에 의한 농기계의 탑승 중 사고. 다만, 자동차손해배상
  보장법시행령 제2조192쪽)에서 정하는 덤프트럭, 콘크리트믹서트럭 등의 의무가입 대상인 건설기계의 탑승 중 사
  고는 보상합니다.
(6) 기차䞱전동차䞱모노레일과 같이 궤도에 따라 운행되는 차량에 탑승(운전 또는 차량 및 그 부속 장치 등에 매달려 
  있는 상태 포함) 중인 경우
(7) 피보험자가 탑승 중이었던 자동차 또는 피보험자에게 상해를 입힌 자동차가 명확하게 밝혀지지 않은 경우. 
  다만, 경찰서에서 발급된 교통사고사실확인원에 의하여 확인된 경우는 보상합니다.
3. 피보험자  
①  피보험자의 범위는 보상하는 사고유형별로 다음과 같습니다. 
 1)  보통약관 자기신체사고 제12조(보상하는 손해)의 사고일 때
  ㉮  보통약관 제7조(피보험자)의 대인배상Ⅱ에 해당하는 피보험자
  ㉯  위 ‘㉮’의 피보험자의 부모, 배우자 및 자녀(보통약관 제1조 제15호)
 2)  보통약관 제12조 이외의 그 밖의 자동차 사고(*2)일 때
  ㉮ 기명피보험자 또는 그 부모, 배우자, 자녀(배우자의 자녀 포함)
  ㉯ 기명피보험자의 배우자의 부모
②  위 ‘①’에도 불구하고 피보험자동차를 업무상 위탁 받은 자동차취급업자(보통약관 제1조 제12호)는 피보험자
  로 보지 않습니다.
4. 보상하지 않는 손해  
①  회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전
  가능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다.
②  위 ‘①’ 외에도 회사는 다음 중 어느 하나에 해당하는 손해는 보상하지 않습니다.
 1)  피보험자의 사용자 또는 소속 법인이 소유하는 자동차에 탑승 중 생긴 사고로 인한 손해. 단, 사용자 또는 소속 
   법인의 업무에 종사하고 있을 때에 한정합니다.
 2)  피보험자가 다른 자동차의 사용에 대하여 정당한 권리를 가지고 있는 자의 승낙을 받지 않고 다른 자동차에 
   탑승 중 생긴 사고로 인한 손해
 3)  피보험자가 정규 승차용 구조 장치가 아닌 장소(이륜차는 승차용 안전모를 착용하지 않은 경우를 포함)에 
   탑승 중 생긴 손해   
5. 지급보험금의 계산  
①  회사가 이 특별약관에 따라 지급하는 보험금은 보험증권에 기재된 보험가입금액을 한도로 하며, 다음과 같이 계
  산됩니다.
 1) 실제손해액은 ‘<별표1~5> 보험금 지급기준’에 따라 산출한 금액으로서 과실상계 및 보상한도를 적용하기 전
   의 금액을 말합니다.
 2)  위 ‘비용’은 다음의 금액을 말합니다. 이 비용은 보험가입금액과 관계없이 보상하여 드립니다. 
   ㉮ 손해의 방지와 경감을 위하여 지출한 비용(긴급조치 비용을 포함) 
   ㉯ 남으로부터 손해배상을 받을 수 있는 권리의 보전과 행사를 위하여 지출한 필요하거나 유익한 비용
 3) 위 ‘공제(控除)액’은 다음의 금액을 말합니다. 
   ㉮ 자동차보험(공제계약지식76) 포함) 대인배상Ⅰ(정부보장사업지식77) 포함) 및 대인배상Ⅱ에 의해 보상받을 수 
    있는 금액
   ㉯ 무보험자동차에 의한 상해에 따라 지급될 수 있는 금액. 다만, 무보험자동차에 의한 상해 보험금의 청구를 
    포기한 경우에는 공제하지 않습니다.
지급보험금
실제손해액
비용
공제액
=
+
-
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
102
103
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (54, 1, 54, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
②  위 ‘①’에도 불구하고 배상의무자 또는 피보험자가 탑승 중이었던 자동차가 가입한 자동차보험(공제계약을 포
  함)의 대인배상Ⅰ과 대인배상Ⅱ에 의한 손해배상을 받을 수 있는 금액 또는 자기신체사고(또는 자동차상해 특
  별약관)로 보상받을 수 있는 금액을 포함하여 피보험자가 회사에 청구할 수 있습니다.
③ 위 ‘②’의 경우, 이 약관에 따라 지급하는 보험금은 보험증권에 기재된 보험가입금액을 한도로 이 약관에 따라 
  산출한 금액과 배상의무자 또는 피보험자가 탑승 중이었던 자동차가 가입한 자동차보험(공제계약을 포함)의 
  대인배상Ⅰ과 대인배상Ⅱ의 보험금 지급기준 또는 자기신체사고(또는 자동차상해 특별약관)에 따라 보상받을 
  수 있는 금액을 합한 액수로 합니다. 
④ 회사가 사망보험금을 지급할 경우에 이미 후유장애로 지급한 보험금이 있을 때에는 사망보험금에서 이를 공제
  한 금액을 지급합니다. 
⑤ 사망보험금의 경우, 보험계약자인 기명피보험자가 본인의 사망보험금 수익자를 지정하거나 변경하고 그 사실
  을 회사에 서면으로 통지한 경우에는 그 수익자에게 보험금을 지급합니다.
6. 보험금의 분담 등  
①  자동차상해 Family 통합보장 특별약관과 보상책임의 전부 또는 일부가 중복되는 다른 보험계약이 있는 경우에
  는 다음에 따라 적용합니다.
구    분
내         용
1)  피보험자동차의 사고
2)  위 ‘1)’ 외의 자동차사고
보통약관 제33조(보험금의 분담) 제1호 부터 제3호까지의 규정에 따라 지급
다른 보험계약에 의해서 보험금이 지급될 수 있는 경우에는 회사가 보상할 금
액이 다른 보험계약에 따라 지급될 수 있는 금액을 초과하는 때에 한정하여 그 
초과액만을 보상
(*1) ‘배상의무자’란 피보험자를 죽게 하거나 다치게 함으로써 피보험자에게 입힌 손해에 대하여 법률상 손해배상
   책임을 지는 사람을 말합니다. 
76) 보통약관 35쪽 프로미카 보험지식 ‘03)’ 참조
77) 보통약관 45쪽 프로미카 보험지식 ‘30)’ 참조
78) 보통약관 55쪽 프로미카 보험지식 ‘45)’, ‘46)’ 참조
②  회사는 위 ‘①의 2)’의 경우에도 불구하고 다른 보험계약에 의해서 지급될 수 있는 금액을 포함하여 우선 지급할 
  수 있으며, 그 경우 아래 ‘7.’에 따라 해당 보험금에 대한 피보험자의 권리를 취득합니다.
7. 대위  
회사는 피보험자에게 보험금을 지급한 경우, 지급한 보험금 한도 내에서 제3자에 대한 피보험자의 권리를 취득합니
다. 다만, 회사가 보상한 금액이 피보험자의 손해의 일부를 보상한 경우에는 피보험자의 권리를 침해하지 않는 범위
에서 그 권리를 취득지식78)합니다.
8. 보험금청구 시 제출서류  
보험금을 청구할 때에는 보험금 청구서와 손해액을 증명하는 서류(진단서 등), 그 밖에 보험회사가 꼭 필요하다고 
인정하는 서류 또는 증거를 제출하여야 합니다.
9. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
   ㉰ 배상의무자(*1) 또는 배상의무자 이외의 제 3자로부터 보상받은 금액
1. 자기신체사고의 대체  
보험회사(이하 ‘회사’라 함)는 이 특별약관에 따라 보통약관의 자기신체사고를 이 특별약관으로 대체하여 적용합
니다.
2. 보상내용  
회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차의 사고(보통약관 자기신체
사고 제12조에서 정하는 사고, 이하 같음)로 인하여 상해를 입었을 때의 손해를 보상하여 드립니다.
3. 피보험자  
피보험자의 범위는 다음과 같습니다.
 1)  보통약관 제7조(피보험자)의 대인배상Ⅱ에 해당하는 피보험자
 2)  위 ‘1)’의 피보험자의 부모, 배우자 및 자녀(보통약관 제1조 제15호)
4. 보상하지 않는 손해  
회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전가
능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다.
5. 지급보험금의 계산  
①  회사가 이 특별약관에 따라 지급하는 보험금은 보험증권에 기재된 보험가입금액을 한도로 하며, 다음과 같이 계
  산됩니다.
 1) 실제손해액은 ‘<별표1~5> 보험금 지급기준’에 따라 산출한 금액으로써 과실상계 및 보상한도를 적용하기 전
   의 금액을 말합니다.
 2)  위 ‘비용’은 다음의 금액을 말합니다. 이 비용은 보험가입금액과 관계없이 보상하여 드립니다. 
  가.  손해의 방지와 경감을 위하여 지출한 비용(긴급조치비용을 포함) 
  나.  남으로부터 손해배상을 받을 수 있는 권리의 보전과 행사를 위하여 지출한 필요하거나 유익한 비용
 3) 위 ‘공제(控除)액’은 다음의 금액을 말합니다. 
  ㉮ 자동차보험(공제계약지식79) 포함) 대인배상Ⅰ(정부보장사업지식80) 포함) 및 대인배상Ⅱ에 의해 보상받을 수 
    있는 금액
   ㉯ 무보험자동차에 의한 상해에 따라 지급될 수 있는 금액. 다만, 무보험자동차에 의한 상해 보험금의 청구를 
    포기한 경우에는 공제하지 않습니다.
   ㉰ 배상의무자 또는 배상의무자 이외의 제 3자로부터 보상받은 금액
②  위 ‘①’에도 불구하고 배상의무자가 가입한 자동차보험(공제계약을 포함)의 대인배상Ⅰ과 대인배상Ⅱ에 의한 
  손해배상을 받을 수 있는 금액을 포함하여 피보험자가 회사에 청구할 수 있습니다.
③ 위 ‘②’의 경우, 이 약관에 따라 지급하는 보험금은 보험증권에 기재된 보험가입금액을 한도로 이 약관에 따라 
  산출한 금액과 배상의무자가 가입한 자동차보험(공제계약을 포함)의 대인배상Ⅰ과 대인배상Ⅱ의 보험금지급
  기준에 따라 보상받을 수 있는 금액을 합한 액수로 합니다. 
④ 회사가 사망보험금을 지급할 경우에 이미 후유장애로 지급한 보험금이 있을 때에는 사망보험금에서 이를 공제
2⃞  자동차상해 특별약관
※  이 특별약관은 보통약관의 자기신체사고 또는 자동차상해 Family 통합보장 특별약관과 중복하여 가
  입할 수 없습니다.
지급보험금
실제손해액
비용
공제액
=
+
-
79) 보통약관 35쪽 프로미카 보험지식 ‘03)’ 참조
80) 보통약관 45쪽 프로미카 보험지식 ‘30)’ 참조
104
105
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (55, 1, 55, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
  한 금액을 지급합니다. 
⑤ 사망보험금의 경우, 보험계약자인 기명피보험자가 본인의 사망보험금 수익자를 지정하거나 변경하고 그 사실
  을 회사에 서면으로 통지한 경우에는 그 수익자에게 보험금을 지급합니다.
6. 대위  
회사는 피보험자에게 보험금을 지급한 경우, 지급한 보험금 한도 내에서 제3자에 대한 피보험자의 권리를 취득합니
다. 다만, 회사가 보상한 금액이 피보험자의 손해의 일부를 보상한 경우에는 피보험자의 권리를 침해하지 않는 범위
에서 그 권리를 취득지식81)합니다.
7. 보험금청구 시 제출서류  
보험금을 청구할 때에는 보험금 청구서와 손해액을 증명하는 서류(진단서 등), 그 밖에 보험회사가 꼭 필요하다고 
인정하는 서류 또는 증거를 제출하여야 합니다.
8. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
3⃞  부상회복지원금 특별약관
1. 가입대상  
이 특별약관은 보통약관의 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관에 가입
한 경우에만 가입할 수 있습니다.
2. 보상내용  
①  건강회복지원금
   보험회사(이하 “회사”라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차
의 사고(보통약관 자기신체사고 제12조에서 정하는 사고, 이하 같음)로 인하여 상해를 입었을 때, 아래 <별표> 
상해구분 및 급별 건강회복지원금을 보험기간 중 매 사고 시 마다 보험금으로 지급합니다.
81) 보통약관 55쪽 프로미카 보험지식 ‘45)’, ‘46)’ 참조
3. 피보험자  
이 특별약관에서의 피보험자는 보통약관 제13조, 자동차상해 특별약관 ‘3.’, 자동차상해 Family 통합보장 특별약
관 ‘3.의 1)’(이상 “피보험자”)에서 열거하는 사람을 말합니다.
4. 보상하지 않는 손해  
회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전가
능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다.
5. 준용규정  
이 특별약관에 정하지 않은 사항은 보통약관을 따릅니다.
②  교통 골절사고 보험금
   보험회사(이하 “회사”라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차
의 사고(보통약관 자기신체사고 제12조에서 정하는 사고, 이하 같음)로 인하여 상해 11급 이상에 해당하는 골
절 진단을 받은 경우 상해등급별 골절진단명을 기준으로 다음과 같이 보험금을 지급합니다. 단, 골절사고 중 치
아파절은 보상에서 제외하며, 골절 진단이 둘 이상 있는 경우에는 가장 높은 상해등급의 보험금을 지급합니다.
③  교통사고 상해수술비
   보험회사(이하 “회사”라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차
의 사고(보통약관 자기신체사고 제12조에서 정하는 사고, 이하 같음)로 인하여 상해 11급 이상에 해당하는 부
상을 입어 수술(흉터로 인한 성형수술은 제외)을 받은 경우에는 다음과 같이 보험금을 지급합니다. 단, 동일한 
자동차사고를 직접적인 원인으로 두 종류 이상의 수술을 받거나 같은 종류의 수술을 2회 이상 받은 경우에는 하
나의 교통사고 상해수술비만 지급합니다.
보험금 종류
상해등급
지급금액
중상해 골절 보험금
일반상해 골절 보험금
1~4급
1인당 300만원
5~11급
1인당 100만원
(주) 상해등급은 자동차손해배상보장법 시행령 별표1에서 정한 상해구분에 의함
보험금 종류
상해등급
지급금액
교통사고 상해수술비
1~11급
1사고당 100만원
(주) 상해등급은 자동차손해배상보장법 시행령 별표1에서 정한 상해구분에 의함
④  교통사고 흉터치료비
   보험회사(이하 “회사”라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차
의 사고(보통약관 자기신체사고 제12조에서 정하는 사고, 이하 같음)로 인하여 상해 11급 이상에 해당하는 부
상을 입어 안면부, 상지, 하지에 흉터가 발생하여 수술이 필요한 경우 다음과 같이 보험금을 지급하여 드립니다. 
(상해등급은 자동차손해배상보장법 시행령 별표1에서 정한 상해구분에 의함)
(*1) ‘안면부’란 이마를 포함하여 목까지의 얼굴 부분을 말합니다.
(*2) ‘상지’란 견관절(어깨관절) 이하의 팔 부분을 말합니다.
(*3)  ‘하지’란 고관절(엉덩관절)이하 대퇴부(넓적다리), 하퇴부(종아리 부위), 족부(발부위)를 의미하며, 둔부(엉덩
이), 서혜부(아랫배와 접한 넓적다리 주변), 복부(배) 등은 제외합니다.
(주) 상해등급은 자동차손해배상보장법 시행령 별표1 79쪽)에서 정한 상해구분에 의함
<별표〉 상해구분 및 급별 건강회복지원금
상해등급
상해등급
건강회복지원금
건강회복지원금
1급
2 䟩 3급
4 䟩 5급
6 䟩 7급
8䟩 9급
10 䟩 11급
12 䟩 14급
1,000만원
   500만원
300만원
100만원
50만원
10만원
5만원
보험금 종류
지급금액
지급한도
안면부(*1), 상지(*2), 하지(*3)
흉터 치료비
1cm당 10만원
(1인당)
1인당 
1,000만원
106
107
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (56, 1, 56, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
82) 보통약관 40쪽 프로미카 보험지식 ‘16)’ 참조
83) 보통약관 40쪽 프로미카 보험지식 ‘17)’ 참조
84) 보통약관 36쪽 프로미카 보험지식 ‘07)’  및 보통약관 37쪽 프로미카 보험지식 ‘09)’  참조
3. 피보험자  
이 특별약관에서 피보험자란 다음의 사람을 말합니다.
 1) 기명피보험자 또는 그 배우자
 2)  위 ‘1)’의 부모 또는 자녀
4. 보상하지 않는 손해  
①  회사는 다음과 같은 손해는 보상하지 않습니다.
 1)  피보험자의 고의로 그 본인이 상해를 입은 때
 2)  자동차정비업, 주차장업, 급유업, 세차업, 자동차판매업, 자동차탁송업, 대리운전업 등 자동차를 취급하는 것
   을 업으로 하는 피보험자가 업무로서 수탁지식82) 받은 자동차의 사용 또는 관리 중 발생한 수탁 받은 자동차에 
   의한 보행 중 사고로 그 본인이 상해를 입은 때
 3)  전쟁, 혁명, 내란, 사변, 폭동, 소요지식83) 및 이와 유사한 사태로 피보험자가 상해를 입은 때
 4)  지진, 분화, 홍수, 해일 등 천재지변으로 인하여 피보험자가 상해를 입은 때
 5)  핵연료 물질의 직접 또는 간접적인 영향으로 인하여 피보험자가 상해를 입은 때
②  회사는 보행 중 사고로 인한 손해는 다음의 자가 배상의무자(*1)인 때에는 보상하지 않습니다. 다만, 다음의 자 
  이외에 다른 배상의무자가 있는 경우에는 보상합니다.
 1)  상해를 입은 피보험자의 부모, 배우자, 자녀
 2)  피보험자가 사용자지식84)의 업무에 종사하고 있을 때 피보험자의 사용자 또는 피보험자의 사용자의 업무에 종
   사 중인 다른 피용인지식84)
③  위 ‘②’의 단서규정(‘다만’ 이하를 말함)에도 불구하고 회사는 피보험자에게 상해를 입힌 타인자동차를 ‘②의 
  1)’에서 규정한 자가 운전한 경우에는 보상하지 않습니다.
④  상해가 보험금을 받을 자의 고의에 따라 생긴 때에는 회사는 그 사람이 받을 수 있는 금액은 보상하지 않습니다.
   이하 동일)로서 피보험자를 죽게 하거나 다치게 한 자동차를 말하며, 다음 중 어느 하나에 해당하는 자동차는 
   이 특별약관의 타인자동차로 보지 않습니다. 
   (1) 기명피보험자와 그 부모, 배우자, 자녀가 소유하거나 통상 사용하는 자동차
   (2) 기명피보험자의 배우자의 부모로서 기명피보험자 또는 그 배우자와 동거 중인 자가 소유하거나 통상 사용
     하는 자동차
   다만, 위 규정에도 불구하고 다음의 경우에 해당하는 자동차는 타인자동차로 봅니다.
   (1) 피보험자에게 상해를 입힌 자동차가 명확히 밝혀지지 않은 경우에 그 자동차
   (2) 기명피보험자가 자동차를 대체한 경우, 그 사실이 생긴 때부터 회사가 보통약관 제49조(피보험자동차의 
     교체)에서 승인을 한 때까지의 대체자동차
5. 보상한도 및 지급보험금의 계산  
①  회사가 이 약관에 따라 지급하는 보험금은 보험증권에 기재된 보험가입금액을 한도로 합니다.
②  회사가 지급하는 보험금은 보통약관 <별표 1> 대인배상, 무보험자동차에 의한 상해 지급기준66쪽)에 따라 산출한 
  금액과 이 특별약관 ‘6.’에서 정한 금액을 합친 금액에서 다음의 금액을 공제한 액수로 합니다.
 1)  대인배상Ⅰ(공제계약 및 정부보장사업을 포함)의 보험금지급기준에 의해 보상될 수 있는 금액
 2)  배상의무자가 피보험자에게 법률상 손해배상책임을 짐으로써 입은 손해를 보상받을 수 있는 자동차보험(공
(*1) ‘배상의무자’란 피보험자를 죽게 하거나 다치게 함으로써 피보험자에게 입힌 손해에 대하여 법률상 손해배상
   책임을 지는 사람을 말합니다.
1. 가입대상  
이 특별약관은 보통약관의 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관에 가입
한 경우에만 가입할 수 있습니다. 
2. 보상내용  
①  보험회사(이하 “회사”라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차
의 사고(보통약관 자기신체사고 제12조에서 정하는 사고, 이하 같음)로 상해를 입어 입원하면서 상급병실(*1)에 
입원하는 경우에는 상급병실과 기준병실과의 차액을 최대 30일까지 500만원 한도 내에서 병실료차액지원금
을 지급합니다.
②  위 ‘①’에서 다른 보험계약에 따라 병실료 차액이 지급될 수 있는 경우에는 그 병실료 차액이 다른 보험계약에서 
  지급될 수 있는 금액을 초과하는 때에 한정하여 그 초과액만을 지급합니다.
3. 피보험자  
이 특별약관에서 피보험자는 기명피보험자 또는 기명피보험자의 배우자를 말합니다.
4. 보상하지 않는 손해  
회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전가
능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
4⃞  병실료차액지원금 특별약관
(*1)  ‘상급병실’이란 기준병실보다 입원료가 비싼 병실(특실 포함)을 말하며, 병원급 이상의 의료기관에 한해 인정
합니다.
1. 가입대상  
이 특별약관은 보통약관의 무보험자동차에 의한 상해에 가입한 경우에만 가입할 수 있으며, 자동차상해 Family 통
합보장 특별약관과는 중복 가입할 수 없습니다. 
2. 보상내용  
①  보험회사(이하 “회사”라 함)는 피보험자가 보행 중 등(*1)의 상태에서 타인자동차(*2)의 운행으로 인한 사고(이
  하 “보행 중 사고”라 함)로 인하여 상해를 입었을 때에 이 특별약관에서 정하는 바에 따라 보험금을 지급합니다.
②  회사가 보상할 손해가 이 특별약관 ‘3.’의 기명피보험자 이외의 피보험자에게 발생한 경우, 상해를 입은 그 피보
  험자 본인을 기명피보험자로 하는 자동차 보험계약(이하 “자기명의계약”이라 함)이 있고, 그 보험계약에 따라 
  보험금(자기명의계약의 기명피보험자 본인에 대한 보험금만을 말함)이 지급될 수 있는 경우에는  회사가 지급
  할 보험금은 자기명의계약에 따라 지급될 수 있는 금액을 초과하는 때에 한정하여 그 초과액만을 보험금으로 지
  급합니다.
5⃞  보행 중 상해 특별약관
(*1) ‘보행 중 등’이란 교통승용구(자동차관리법에 의한 자동차, 군수품관리법에 의한 차량, 도로교통법에 의한 원
   동기장치자전거, 건설기계관리법에 의한 건설기계, 농업기계화촉진법에 의한 농업기계, 기차ㆍ전동차ㆍ모노
   레일 등 궤도에 따라 운행되는 차량을 말함)를 운전하거나 탑승하던 중(자동차 및 그 부속장치 등에 매달려 
   있는 상태 등을 포함)이 아닌 상태를 말합니다.
(*2) ‘타인자동차’란 피보험자동차 이외의 자동차(자동차관리법에 의한 자동차, 군수품관리법에 의한 차량, 도로교
   통법에 의한 원동기장치자전거, 건설기계관리법에 의한 건설기계, 농업기계화촉진법에 의한 농업기계를 말함. 
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
108
109
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (57, 1, 57, '85) 보통약관 55쪽 프로미카 보험지식 ‘45)’, ‘46)’ 참조
   제계약을 포함)의 대인배상Ⅱ가 있을 때에는 이러한 대인배상Ⅱ의 보험금지급기준에 따라 보상될 수 있는 금
   액
 3)  보통약관의 무보험자동차에 의한 상해에 따라 지급될 수 있는 금액. 그러나, 무보험자동차에 의한 상해 보험
   금의 청구를 포기한 경우에는 공제하지 않습니다.
 4)  피보험자가 배상의무자로부터 이미 지급받은 금액
 5)  배상의무자가 아닌 제3자가 부담하여야 할 금액으로서 피보험자가 이미 지급받은 금액
 6)  피보험자가 산업재해보상보험법에 의해 보상받을 수 있는 금액
③  위 ‘②’에도 불구하고 배상의무자가 가입한 자동차보험(공제계약을 포함)의 대인배상Ⅰ 및 대인배상Ⅱ에 의한 
  손해배상을 받을 수 있는 금액을 포함하여 피보험자가 회사에 청구하는 경우, 이 특별약관에 따라 지급하는 보
  험금은 보험증권에 기재된 보험가입금액을 한도로 ‘②’에 따라 산출된 금액과 배상의무자가 가입한 자동차보험
  (공제계약을 포함)의 대인배상Ⅰ 및 대인배상Ⅱ의 보험금 지급기준에 따라 보상받을 수 있는 금액을 합산한 액
  수로 합니다.
④  회사가 사망보험금을 지급할 경우에 이미 후유장애로 지급한 보험금이 있을 때에는 사망보험금에서 이를 공제
  한 금액을 지급합니다. 
6. 비용  
회사는 보험계약자 또는 피보험자가 이 특별약관의 규정에 의한 손해의 방지와 경감을 위하여 지출한 비용 및 배상
의무자로부터 손해배상을 받을 수 있는 권리의 보전과 행사를 위하여 지출한 필요하거나 유익한 비용을 보상합니다.
7. 대위  
회사는 피보험자에게 보험금을 지급한 경우에는 그 보험금의 한도 내에서 배상의무자에 대한 피보험자의 권리를 
취득합니다. 다만, 회사가 보상한 금액이 피보험자의 손해의 일부를 보상한 경우에는 피보험자의 권리를 침해하지 
않는 범위에서 그 권리를 취득지식85)합니다.
8. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 가입대상  
이 특별약관은 보통약관의 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관에 가입
한 경우에만 가입할 수 있습니다. 
2. 보상내용  
①  보험회사(이하 “회사”라 함)는 피보험자가 다음의 사고로 상해를 입어 그 직접적인 결과로 사망한 경우에는 
  1인당 1억원을 대중교통자동차 탑승 중 사고보험금으로 지급합니다.
 1)  운행 중인 대중교통자동차에 직접 운전을 하고 있지 않는 상태로 탑승 중(*1)(비정상적이거나 위험한 방법으
   로 탑승하고 있는 경우는 제외함)에 발생한 대중교통자동차(*2)의 사고
 2)  대중교통자동차에 승ㆍ하차(대중교통자동차 또는 그 부속장치에 매달려 있는 상태를 제외함)하던 중 발생한 
   대중교통자동차의 사고
6⃞  대중교통자동차 탑승 중 사고 특별약관
(*1) ‘탑승 중’이란 대중교통자동차 객실 내의 좌석 및 손잡이 등이 있는 입석과 통로에 올라타는 행위를 말하는 것
   으로서, 이외의 장소에 탑승하거나 또는 좌석 위에 올라타 서 있는 경우, 손잡이 등 부속장치에 매달려 있는 경
   우 등 비정상적이거나 위험한 방법으로 탑승하고 있는 경우는 제외합니다.
86) 보통약관 40쪽 프로미카 보험지식 ‘17)’ 참조
②  위 ‘①’에서 지급되는 보험금은 피보험자의 상속인에게 지급됩니다. 다만, 보험계약자인 기명피보험자가 본인
  의 사망보험금 수익자를 보통약관 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별
  약관에서 지정하거나 변경하고 그 사실을 보험회사에 서면으로 통지한 경우에는 그 수익자에게 보험금을 지급
  합니다. 
3. 피보험자  
①  이 특별약관에서 피보험자란 다음의 사람을 말합니다.
 1)  기명피보험자 또는 그 배우자
 2)  위 ‘1)’의 부모 또는 자녀
②  위 ‘①’의 자가 운전자, 승무원(이들의 운전보조자를 포함)등 해당 대중교통자동차에 탑승하는 것을 업무로 하
  는 자로서 업무상 대중교통자동차에 탑승한 때에는 피보험자로 보지 않습니다.
4. 보상하지 않는 손해  
회사는 다음의 사고로 피보험자가 사망한 경우에는 보상하지 않습니다.
 1)  피보험자 및 보험계약자 또는 보험금을 받을 자의 고의로 인한 사고
 2)  전쟁, 혁명, 내란, 사변, 폭동, 소요지식86) 및 이와 유사한 사태로 인한 사고
 3)  지진, 분화, 태풍, 홍수, 해일 등 천재지변에 의한 사고
 4)  핵연료 물질의 직접 또는 간접적인 영향으로 인한 사고
 5)  피보험자가 시험용(운전면허시험을 위한 도로주행시험용은 제외), 경기용 또는 경기를 위해 연습용으로 사용 
   중인 대중교통자동차에 탑승 중 발생한 사고
 6) 대중교통자동차의 설치, 수리, 점검, 정비, 청소작업 등 업무를 수행하는 동안 발생한 사고
 7) 대중교통자동차를 운반하던 중 발생한 사고
5. 보험금청구  
①  보험금 청구권자는 피보험자가 사망한 경우에 보험금을 청구할 수 있습니다.
②  위 ‘①’의 경우, 다음의 서류 또는 증거를 제출하여야 합니다.
 1) 보험금청구서 및 피보험자가 교통사고로 사망한 사실을 증명할 수 있는 서류
 2)  그 밖에 보험회사가 꼭 필요하다고 인정하는 서류 또는 증거 
6. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 가입대상  
이 특별약관은 보통약관의 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관에 가입
한 경우에만 가입할 수 있습니다.  
2. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 주말 및 휴일(*1) 동안 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생
7⃞  주말ㆍ휴일 교통사고 위로금 특별약관
(*2) ‘대중교통자동차’란 다음 중 하나에 해당하는 것을 말합니다.
   (1) 여객자동차운수사업법 시행령 제3조189쪽)의 시내버스, 농어촌버스, 마을버스, 시외버스 및 고속버스(전세
     버스 제외)
   (2) 여객자동차운수사업법 시행령 제3조의 일반택시, 개인택시(렌터카 제외)
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
110
111
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (58, 1, 58, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
(*1) ‘주말 및 휴일’이란 아래의 기간을 말합니다. 
   (1) 주말 : 금요일 18:00 ~ 월요일 06:00
   (2) 휴일 : 법정 공휴일(국가에서 정한 임시공휴일 포함), 근로자의 날 전 날 18:00 ~ 다음 날 06:00
보험금 종류
지급 조건
보상 한도
부상위로금
후유장애위로금
피보험자가 피보험자동차의 사고로 자동차손해배상보장법 
시행령에서 정한 상해등급 7급 이상(1~7급)의 상해를 입은 
경우
피보험자가 피보험자동차의 사고로 인한 상해를 입은 직접
적인 결과로 치료를 받은 후에도 신체에 후유장애(장애등급
은 자동차손해배상보장법시행령 별표2에서 정한 후유장애
구분에 의함)를 입은 경우
1인당 50만원 지급
<별표> 후유장애구분 및 
급별 보험가입금액에 
따라 지급
사망위로금
피보험자가 피보험자동차의 사고로 인한 상해를 입은 
직접적인 결과로 사망한 경우
1인당 5천만원 지급
   다만, 사망위로금을 지급할 경우에 이미 후유장애위로금으로 지급한 보험금이 있을 때에는 이를 공제한 금액
   을 지급합니다. 
 2)  위 ‘1)’에서 지급되는 사망위로금은 피보험자의 상속인에게 지급됩니다. 다만, 보험계약자인 기명피보험자가 
   본인의 사망보험금 수익자를 보통약관 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보
   장 특별약관에서 지정하거나 변경하고 그 사실을 보험회사에 서면으로 통지한 경우에는 그 수익자에게 보험
   금을 지급합니다.
<별표> 후유장애 구분 및 급별 보험가입금액
장애등급
장애등급
보험가입금액
보험가입금액
1급
2급
3급
4급
5급
6급
7급
8급
9급
10급
11급
12급
13급
14급
5,000만원
4,500만원
4,000만원
3,500만원
3,000만원
2,500만원
2,000만원
1,500만원
1,125만원
940만원
750만원
625만원
500만원
315만원
3. 피보험자  
이 특별약관에서 피보험자란 다음의 사람을 말합니다.
 1)  기명피보험자 또는 그 배우자
 2)  위 ‘1)’의 부모 또는 자녀
4. 보상하지 않는 손해  
회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전가
능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
긴 피보험자동차의 사고(보통약관 자기신체사고 제12조에서 정하는 사고, 이하 같음)로 인하여 상해를 입었을 때, 
다음에서 정하는 바에 따라 보험금을 지급합니다. 
 1)  회사가 이 특별약관에 따라 사고마다 지급하는 보험금의 종류와 한도는 다음과 같습니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
1. 가입대상  
이 특별약관은 보통약관 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관에 가입한 
경우에만 가입할 수 있습니다.
2. 보상내용  
보험회사(이하 “회사”라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차의 사
고(보통약관 자기신체사고 제12조에서 정하는 사고, 이하 같음)로 인하여 상해를 입었을 때에 다음에서 정하는 바
에 따라 보험금을 지급합니다. 
 1)  성형 및 치아보철 위로금
   피보험자가 피보험자동차의 사고로 인한 상해로 성형수술 또는 치아보철이 필요한 경우 <별표>에 따라 성형 
   및 치아보철 위로금을 지급합니다.
8⃞  성형 및 치아보철 지원금 특별약관
   다만, 사고당 성형 및 치아보철 위로금의 합계가 1천만원을 초과하는 경우에는 1천만원을 지급합니다.
 2)  Refresh 지원금
     피보험자가 피보험자동차의 사고로 인하여 1만원 이상의 치료비가 드는 상해를 입은 경우에는 근육통증, 근
   육피로 등을 해소하기 위해 필요한 비용으로 1인당 10만원의 Refresh 지원금을 지급합니다.
3. 피보험자  
이 특별약관에서 피보험자란 다음의 사람을 말합니다.
 1) 기명피보험자
 2) 기명피보험자의 가족(*1)
보험금 종류
지급 금액
안면부(*1), 상지(*2), 하지(*3) 성형위로금
치아보철위로금
1cm당 10만원
치아 1대당 20만원
<별표〉 
(*1) ‘안면부’란 이마를 포함하며 목까지의 얼굴 부분을 말합니다.
(*2) ‘상지’란 견관절 이하의 팔 부분을 말합니다.
(*3) ‘하지’란 고관절 이하 대퇴부, 하퇴부, 족부를 의미하며, 둔부, 서혜부, 복부 등은 제외합니다.
(*1) ‘‘기명피보험자의 가족’이란 다음의 사람을 말합니다.
   (1) 기명피보험자의 부모, 양부모, 계부모
   (2) 기명피보험자의 배우자의 부모, 양부모, 계부모 
   (3) 법률상의 배우자(사실혼 관계 포함) 
   (4) 법률상의 혼인 관계 또는 사실혼 관계에서 출생한 자녀, 양자녀
   (5) 법률상의 혼인 관계로 인한 계자녀
   (6) 기명피보험자의 며느리(계자녀의 배우자 포함) 또는 사위(계자녀의 배우자 포함)
4. 보상하지 않는 손해  
회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전가
능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
112
113
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (59, 1, 59, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
(*1) ‘주말 및 휴일’이란 아래의 기간을 말합니다. 
   (1) 주말 : 금요일 18:00 ~ 월요일 06:00
   (2) 휴일 : 법정 공휴일(국가에서 정한 임시공휴일 포함), 근로자의 날 전 날 18:00 ~ 다음 날 06:00
1. 가입대상  
이 특별약관은 보통약관의 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관에 가입
한 경우에만 가입할 수 있습니다.  
2. 보상내용  
① 보험회사(이하 “회사”라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차
  의 사고(보통약관 자기신체사고 제12조에서 정하는 사고, 이하 같음)로 인하여 사망 또는 후유장애를 입
  거나, 1~7급의 상해를 입은 경우에는 다음 <별표>에 따라 가족사고 특별위로금 및 부상위로금을 지급합니다. 
  다만, 후유장애로 이미 가족사고 특별위로금을 지급한 후 피보험자가 사망한 경우에는 이를 공제한 금액을 지급
  합니다. 
②  회사는 피보험자가 주말 및 휴일(*1) 동안 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차의 
  사고로 인하여 상해를 입은 직접적인 결과로 사망한 경우에 1인당 3천만원을 주말 또는 휴일사고 추가보험금으
  로 지급합니다. 
9⃞  가족사고 위로금 보장 특별약관
보상내용
지급 금액
가족사고 특별위로금
부상위로금
사망
후유장애(1~3급)
상해(1~7급)
1인당 5천만원
1인당 3천만원
1인당 100만원
<별표〉
주) 상해등급은 자동차손해배장보장법시행령 별표1 79쪽)을, 후유장애등급은 동법령 별표2 87쪽)를 따름
③ 회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차의 사고로 인하여 보통약
  관 제12조(보상하는 손해) 또는 자동차상해 특별약관 ‘2.’, 자동차상해 Family 통합보장 특별약관 ‘2.의 1)’에 
  의한 사망보험금이 지급되는 경우로, 다음 중 하나에 해당하는 경우에 한정하여 1인당 1천만원을 안전벨트착용 
  추가보험금으로 지급합니다.
 1) 사망한 피보험자가 운전석에서 안전벨트를 착용했음이 증명된 경우
 2) 사망한 피보험자가 운전석의 옆 좌석에서 안전벨트(유아용 안전장구를 포함)를 착용했음이 증명된 경우
④  위 ‘①’부터 ‘③’까지의 규정으로 지급되는 사망보험금은 피보험자의 상속인에게 지급됩니다. 다만, 보험계약
  자인 기명피보험자가 본인의 사망보험금 수익자를 보통약관 자기신체사고 또는 자동차상해 특별약관, 자동차
  상해 Family 통합보장 특별약관에서 지정하거나 변경하고 그 사실을 보험회사에 서면으로 통지한 경우에는 그 
  수익자에게 보험금을 지급합니다. 
3. 피보험자  
이 특별약관에서 피보험자란 다음의 사람을 말합니다.
 1) 기명피보험자
 2) 기명피보험자의 가족(*1)
(*1) ‘기명피보험자의 가족’이란 다음 중 하나에 해당하는 사람을 말합니다.
   (1) 기명피보험자의 부모, 양부모, 계부모
   (2) 기명피보험자의 배우자의 부모, 양부모, 계부모
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
4. 보상하지 않는 손해  
회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전가
능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 가입대상  
여성 안심용품 지원 특별약관은 보통약관 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 
특별약관에 가입한 경우에만 가입할 수 있습니다.  
2. 보상내용  
①  보험회사(이하 ‘회사’라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차의 
  사고(보통약관 자기신체사고 제12조에서 정하는 사고, 이하 같음)로 인하여 상해를 입어 보통약관 자기신체사
  고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관의 보험금이 지급되는 경우 사고당 회사가 
  정한 1개의 안심용품지식87)을 지급하여 드립니다.
②  위 ‘①’의 안심용품이 지급되는 경우, 안심용품 중에서 생산 중단 등으로 공급이 이루어 질 수 없는 경우에는 그 
  용품에 상응하는 금액에 해당하는 유사용품으로 대체하여 지급하여 드립니다. 다만, 피보험자가 원하는 경우에 
  한정하여 안심용품에 상응하는 금액에 해당하는 현금을 지급하여 드립니다.
3. 피보험자  
이 특별약관에서 피보험자란 다음의 사람을 말합니다.
 1)  여성(*1)인 기명피보험자
 2)  기명피보험자의 가족(*2) 중 여성
[10]  여성 자기신체사고 안심용품 지원 특별약관
87) “안심용품”이란 여성운전자의 안전운행을 돕기 위한 1세트(5종 물품)로 구성되어 있습니다. 사고 시 해당 물품 1세트를 
   제공해 드립니다. 
     ① 휴대용 소화기
     ② 휴대용 LED 후레시
   ③  휴대용 구급키트
   ④  LED 안전 삼각대
   ⑤  차량 유리 발수코팅 스프레이
   ※ 제공 물품은 시기별로 다를 수 있습니다.
(*1) ‘여성’이란 주민등록번호를 기준으로 판단하여 여성인 경우를 의미합니다.
(*2) ‘기명피보험자의 가족’이란 다음의 사람을 말합니다.
   (1) 기명피보험자의 부모, 양부모, 계부모
   (2) 기명피보험자의 배우자의 부모, 양부모, 계부모
   (3) 법률상의 배우자(사실혼 관계 포함) 
   (4) 법률상의 혼인관계 또는 사실혼 관계에서 출생한 자녀(양자녀, 계자녀 포함)
   (5) 기명피보험자의 며느리(계자녀의 배우자 포함) 또는 사위(계자녀의 배우자 포함)
   (3) 법률상의 배우자(사실혼 관계 포함) 
   (4) 법률상의 혼인 관계 또는 사실혼 관계에서 출생한 자녀, 양자녀
   (5) 법률상의 혼인 관계로 인한 계자녀
   (6) 기명피보험자의 며느리(계자녀의 배우자 포함) 또는 사위(계자녀의 배우자 포함)
114
115
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (60, 1, 60, '4. 보상하지 않는 손해  
회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 다음과 같은 손해도 보상하
지 않습니다.
 1) 보험증권에 기재된 운전가능범위 외의 자가 운전하던 중 사고가 발생한 때
 2) 피보험자가 사망한 때
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 가입대상  
이 특별약관은 보통약관의 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관에 가입
한 경우만 가입할 수 있습니다.
2. 피보험자  
이 특별약관에서의 피보험자는 기명피보험자의 만 12세 이하 자녀 또는 손자녀(외손자녀 포함)(*1)중 보험증권에 
기재된 자를 말합니다. 보험기간 중 피보험자 연령이 만 13세로 변경되는 경우에는 피보험자로 선정할 수 없습니
다.
3. 보상내용  
① 교통사고 보험금
  보험회사(이하 “회사”라 함)는 피보험자가 다른사람 소유의 자동차(*1)와의 접촉 또는 다른사람 소유의 자동차
  에 탑승 중 사고 또는 피보험자동차에 탑승 중 사고(이하 “교통사고”라 함)를 직접적인 결과로 상해를 입었을 
  때, 다음에서 정하는 바에 따라 보험금을 지급합니다.
䣱  어린이 교통상해 특별약관
※  이 특별약관은 건강회복지원금, 대중교통자동차 탑승 중 사고 특별약관, 주말·휴일 교통사고 위로금 
  특별약관, 성형 및 치아보철 지원금 특별약관, 가족사랑 특별약관과 중복하여 가입할 수 없습니다.
(*1) ‘자녀’란 기명피보험자의 법률상 혼인관계에서 출생한 자녀, 사실혼 관계에서 출생한 자녀, 양자 또는 양녀를
   말합니다.
   ‘손자녀(외손자녀)’란 기명피보험자의 자녀의 법률상 혼인관계에서 출생한 자녀 또는 사실혼 관계에서 출생한 
   자녀, 양자 또는 양녀를 말합니다.
보험금 종류
지급 조건
보상 한도
교통사고 
부상위로금
피보험자가 교통사고로 자동차손해배상보장법시행령 별표
1 에서 정한 상해등급 1~14급의 상해를 입은 경우
<별표> 상해 구분 및 급별 
보험가입금액에 따라 지급
교통사고 
사망위로금
피보험자가 교통사고로 상해를 입은 직접적인 결과로 사망
한 경우
1인당 5천만원 지급
교통사고 
후유장애위로금
피보험자가 교통사고로 상해를 입은 직접적인 결과로 치료
를 받은 후에도 자동차손해배상보장법시행령 별표2에서 정
한 1~14등급의 후유장애를 입은 경우
<별표> 후유장애 구분 및 
급별 보험가입금액에 
따라 지급
  단, 피보험자가 상해 또는 후유장애를 입어 치료 중 사망한 경우 교통사고 부상위로금 또는 후유장애 위로금과 
  사망위로금 중 큰 금액을 지급하여 드립니다
(*1) ‘다른사람 소유의 자동차’란 피보험자동차 이외의 자동차(이 특약에서 자동차란 자동차관리법에 의한 자동차
   (세그웨이, 전동휠, 전동퀵보드 및 이와 유사한 형태의 원동기를 단 차는 제외합니다.), 군수품관리법에 의한 
   차량, 건설기계관리법에 의한 건설기계, 농업기계화촉진법에 의한 농업기계를 말함. 이하 동일)로서 피보험자
   를 죽게 하거나 다치게 한 자동차를 말하며, 다음 중 어느 하나에 해당하는 자동차는 이 특별약관의 다른사람 
   소유의 자동차로 보지 않습니다.
   (1) 기명피보험자와 그 부모, 배우자, 자녀가 소유하거나 통상 사용하는 자동차
   (2) 기명피보험자의 배우자의 부모로서 기명피보험자 또는 그 배우자와 동거 중인 자가 소유하거나 통상 사용
     하는 자동차
   다만, 위 규정에도 불구하고 피보험자에게 상해를 입힌 자동차가 명확히 밝혀지지 않은 경우 그 자동차는 경찰
   서에서 발급된 교통사고사실확인원에 의하여 확인된 건에 한해 다른사람 소유의 자동차로 봅니다.
<별표> 후유장애/상해 구분 및 급별 보험가입금액
장애/상해등급
후유장애
1급
2급
3급
4급
5급
6급
7급
1억원
9,000만원
8,000만원
7,000만원
6,000만원
5,000만원
4,000만원
상해
2,000만원
1,000만원
800만원
600만원
400만원
200만원
100만원
장애/상해등급
후유장애
8급
9급
10급
11급
12급
13급
14급
3,000만원
2,400만원
1,800만원
1,400만원
1,000만원
600만원
400만원
상해
80만원
60만원
40만원
20만원
10만원
10만원
10만원
② 스쿨존 사고 보험금
  회사는 피보험자가 스쿨존(*1)에서 다른사람 소유의 자동차(*2)와의 접촉 또는 다른사람 소유의 자동차에 탑승 중 
  사고 또는 피보험자동차에 탑승 중 사고(이하 “교통사고”라 함)를 직접적인 결과로 상해를 입었을 때, 다음에서 
  정하는 바에 따라 보험금을 지급합니다.
보험금 종류
지급 조건
보상 한도
스쿨존 사고 
부상위로금
스쿨존 사고  
후유장애위로금
피보험자가 스쿨존에서 교통사고로 자동차손해배상보장법
시행령 별표1 에서 정한 상해등급 1~14급의 상해를 입은 
경우
피보험자가 스쿨존에서 교통사고로 상해를 입은 직접적인 
결과로 치료를 받은 후에도 자동차손해배상보장법시행령 
별표2에서 정한 1~14등급의 후유장애를 입은 경우
<별표> 상해 구분 및 급별 
보험가입금액에 따라 지급
<별표> 후유장애 구분 및 
급별 보험가입금액에 
따라 지급
스쿨존 사고  
사망위로금
피보험자가 스쿨존에서 교통사고로 상해를 입은 직접적인 
결과로 사망한 경우
1인당 2천만원 지급
  단, 피보험자가 상해 또는 후유장애를 입어 치료 중 사망한 경우 스쿨존 사고 부상위로금 또는 후유장애 위로금
  과 사망위로금 중 큰 금액을 지급하여 드립니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
116
117
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (61, 1, 61, '<별표> 후유장애/상해 구분 및 급별 보험가입금액
후유장애/상해등급
후유장애
1급
2급
3급
4급
5급
6급
7급
5천만원
4,500만원
4,000만원
3,500만원
3,000만원
2,500만원
2,000만원
상해
1천만원
500만원
400만원
300만원
200만원
100만원
50만원
후유장애/상해등급
후유장애
8급
9급
10급
11급
12급
13급
14급
1,500만원
1,200만원
900만원
700만원
500만원
300만원
200만원
상해
40만원
30만원
20만원
10만원
5만원
5만원
5만원
(*1) ‘스쿨존’이란 도로교통법 제12조 제1항의 규정에 의거 유치원 및 초등학교 주변도로 중 일정구간(출입문을 중
   심으로 반경 300m 이내의 도로)내에서 어린이보호구역으로 지정된 곳을 말합니다.
(*2) ‘다른사람 소유의 자동차’란 피보험자동차 이외의 자동차(이 특약에서 자동차란 자동차관리법에 의한 자동차
   (세그웨이, 전동휠, 전동퀵보드 및 이와 유사한 형태의 원동기를 단 차는 제외합니다.), 군수품관리법에 의한 
   차량, 건설기계관리법에 의한 건설기계, 농업기계화촉진법에 의한 농업기계를 말함. 이하 동일)로서 피보험자
   를 죽게 하거나 다치게 한 자동차를 말하며, 다음 중 어느 하나에 해당하는 자동차는 이 특별약관의 다른사람 
   소유의 자동차로 보지 않습니다.
   (1) 기명피보험자와 그 부모, 배우자, 자녀가 소유하거나 통상 사용하는 자동차
   (2) 기명피보험자의 배우자의 부모로서 기명피보험자 또는 그 배우자와 동거 중인 자가 소유하거나 통상 사용
     하는 자동차
   다만, 위 규정에도 불구하고 피보험자에게 상해를 입힌 자동차가 명확히 밝혀지지 않은 경우 그 자동차는 경찰
   서에서 발급된 교통사고사실확인원에 의하여 확인된 건에 한해 다른사람 소유의 자동차로 봅니다.
③ 교통 골절사고 보험금
  회사는 피보험자가 보험기간 중 교통사고로 골절진단을 받은 경우 자동차손해배상보장법시행령 [별표1]에서 
  분류하는 상해등급별 골절진단명을 기준으로 다음과 같이 보험금을 지급하여 드립니다.
  단, 골절사고 중 치아파절은 보상에서 제외하며, 골절진단이 둘 이상 있는 경우에는 가장 높은 상해등급의 보험
  금을 지급합니다.
④ 교통사고 흉터치료비
  회사는 피보험자가 보험기간 중 교통사고로 안면부, 상지, 하지에 흉터가 발생하여 수술이 필요한 경우 다음과 
  같이 보험금을 지급하여 드립니다.
보험금 종류
지급금액
중상해 골절 보험금
일반상해 골절 보험금
1~4급
5~11급
1인당 300만원
1인당 100만원
상해등급
보험금 종류
지급한도
안면부(*1), 상지(*2), 하지(*3) 흉터 치료비
1Cm당 10만원(1인당)
1,000만원(1인당)
지급 금액
(*1) ‘안면부’란 이마를 포함하여 목까지의 얼굴 부분을 말합니다.
(*2) ‘상지’란 견관절(어깨관절) 이하의 팔 부분을 말합니다.
(*3) ‘하지’란 고관절(엉덩관절) 이하 대퇴부(넓적다리), 하퇴부(종아리 부위), 족부(발부위)를 의미하며, 둔부(엉
   덩이), 서혜부(아랫배와 접한 넓적다리 주변), 복부(배) 등은 제외합니다.
4. 보상하지 않는 손해 
회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않습니다. 
5. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다
[12]  교통상해 입원 지원금 특별약관
1. 가입대상  
이 특별약관은 보통약관의 자기신체사고 또는 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관에 가입
한 경우에만 가입할 수 있습니다.
2. 피보험자  
이 특별약관에서 피보험자는 보험증권에서 기재된 해당 특별약관의 피보험자를 말하며, 피보험자는 아래의 범위에
서 선정할 수 있습니다.
 1) 기명피보험자 및 기명피보험자의 배우자(사실혼 관계 포함)
 2) 기명피보험자 또는 그 배우자(사실혼 관계 포함)의 부모(양부모, 계부모 포함) 및 자녀(양자녀, 계자녀 포함)
 3) 기명피보험자의 며느리(계자녀의 배우자 포함) 또는 사위(계자녀의 배우자 포함)
 4) 기명피보험자의 법률상의 형제, 자매 및 기명피보험자의 부모의 양자, 양녀로 인한 형제, 자매
 5) 보험증권에 기재된 운전자 한정운전 특별약관의 지정운전자 또는 추가운전자 1인
3. 보상내용  
①  교통사고 간병서비스 이용 지원금
  보험회사(이하 “회사”라 함)는 피보험자가 자동차에 탑승 중(*1) 또는 보행 중(*2) 발생한 자동차 사고(*3)의 직접
  적인 결과로 ‘자동차손해배상보장법 시행령 제3조 제①항 제2호 관련 1. 상해 구분별 한도금액’의 상해 7급 이
  상에 해당하는 상해를 입어 입원하는 경우, 아래 <별표> 간병서비스 이용 지원금에서 정하는 바에 따라 보험금
  을 지급합니다.
※  이 특별약관은 다른 자동차보험의 해당 특별약관과 피보험자를 중복하여 가입할 수 없습니다. 또한, 
  병실료차액 지원금 특별약관과 중복하여 가입할 수 없습니다.
<별표> 간병서비스 이용 지원금
간병서비스 이용 지원금
1~3급
4~6급
500만원
250만원
상해등급
7급
100만원
간병서비스 이용 지원금
상해등급
(*1) ‘자동차에 탑승 중’이라 함은 피보험자가 자동차관리법에 의한 자동차(이륜자동차및 전동킥보드 등 개인형 이
   동장치는 제외합니다)에 탑승 중(운전 중 포함)인 상태를 말합니다.
(*2) ‘보행 중’이라 함은 피보험자가 교통승용구(자동차관리법에 의한 자동차, 군수품관리법에 의한 차량, 건설기
   계관리법에 의한 건설기계, 농업기계화 촉진법에 의한 농업기계, 기차䞱전동차䞱모노레일 등 궤도에 따라 운행
   되는 차량을 말합니다.) 및 엘리베이터䞱에스컬레이터에 탑승하지 않은 상태를 말합니다.
(*3) ‘자동차 사고’라 함은 다음의 경우를 말합니다.
   ①  피보험자가 자동차에 탑승 중 또는 보행 중 자동차관리법에 의한 자동차(전동킥보드 등 개인형 이동장치
     는 제외합니다), 군수품관리법에 의한 차량, 건설기계관리법에 의한 건설기계, 농업기계화 촉진법에 의한 
     농업기계와 충돌한 사고
   ②  피보험자가 자동차에 탑승 중 발생한 다음의 사고
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
118
119
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (62, 1, 62, '② 교통사고 입원 일당
  회사는 피보험자가 자동차에 탑승 중 또는 보행 중 발생한 자동차 사고의 직접적인 결과로 ‘자동차손해배상보장
  법 시행령 제3조 제①항 제2호 관련 1. 상해 구분별 한도금액’의 상해 7급 이상에 해당하는 상해를 입어 입원하
  는 경우, 아래 <별표> 교통사고 입원 일당 지급 한도일에서 정하는 기간을 한도로 입원 1일당 3만원의 보험금을 
  지급합니다.
③  병실료차액지원금
  회사는 피보험자가 자동차에 탑승 중 또는 보행 중 발생한 자동차 사고의 직접적인 결과로 ‘자동차손해배상보
  장법 시행령 제3조 제①항 제2호 관련 1. 상해 구분별 한도금액’의 상해 7급 이상에 해당하는 상해를 입어 입원
  하면서 상급병실(*1)에 입원하는 경우, 상급병실과 기준병실과의 차액에 대하여 입원 첫 날부터 입원 1일당 
  10만원 한도로 최대 300만원까지 병실료차액지원금을 지급합니다. 다만, 자기신체사고, 자동차상해 특별약관, 
  자동차상해 Family 통합보장 특별약관이나 다른 자동차보험(공제포함)의 대인배상Ⅰ과 대인배상Ⅱ의 보험금 
  지급기준에 따라 상급병실료가 지급될 수 있는 경우에는 이를 초과하는 때에 한정하여 그 초과액만을 지급합니
  다.
    가.  피보험자가 탑승 중인 자동차에 날아오거나 떨어지는 물체와 충돌
    나.  피보험자가 탑승 중인 자동차의 화재 또는 폭발
    다.  피보험자가 탑승 중인 자동차의 낙하
<별표> 교통사고 입원 일당 지급 한도일
지급 한도일
1~3급
4~6급
100일
60일
상해등급
7급
20일
지급 한도일
상해등급
(*1)  ‘상급병실’이란 기준병실보다 입원료가 비싼 병실(특실 포함)을 말하며, 병원급 이상의 의료기관에 한해 인정
합니다.
4. 보상하지 않는 손해 
회사는 보통약관 제14조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않습니다. 또한, 보험증권에 기재된 운
전가능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다. 
5. 보험계약자 및 피보험자의 의무 
회사는 피보험자의 입원 사실을 확인하는데 필요한 서류의 제출 및 보험사고 사실 관계 확인을 보험계약자 및 피보
험자에게 요청할 수 있으며, 이 경우 보험계약자 및 피보험자는 이에 적극 협조하여야 합니다.
6. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관에 따릅니다.
Ⅲ. 자기차량손해의 보상 확대
1. 가입대상 
이 특별약관은 신차(*1)로서 보통약관의 자기차량손해에 가입한 경우에만 가입할 수 있습니다.
1⃞  차량 신차가액 보상담보 특별약관
※  이 특약들을 가입함으로써 자기차량손해와 관련된 사고 발생 시 보통약관에서 보장되는 내용 이외에 
  해당 특별약관에서 보장하는 내용을 추가적으로 보상을 받을 수 있습니다.
(*1) ‘신차’란 최초차량등록일지식88)을 기준으로 6개월 이내의 차량을 말합니다.
88) “최초차량등록일”이란 자동차관리법 제8조190쪽)에 따라 신규로 등록한 일자를 말합니다. 다만, 말소 등록된 자동차를 신
   규로 등록한 경우에는 말소등록 이전에 최초로 신규 등록한 일자를 말합니다.
2. 보상내용 
① 보험회사는 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별약관에 의한 보험금이 지급되는 사
  고로 인하여 보험증권에 기재된 자기차량손해 보험가입금액의 70%이상 손해(수리비에 한정하며 간접손해는 
  제외함)가 발생했을 때에는 전부손해로 보아 다음의 <별표>에서 정하는 바에 따라 차량 신차가액 보상금과 차
  량전손 시 취득세비용 보험금을 지급합니다. 
② 위 ‘①’에서 보험증권에 기재된 보험가입금액은 피보험자동차의 최초 등록 당시의 보험개발원에서 정한 차량기
  준가액표에 따른 차량기준가액을 말합니다. 다만, 차량기준가액이 없는 경우에는 피보험자동차의 구입당시 차
  량가액으로 합니다.
3. 피보험자 
이 특별약관에서 피보험자란 기명피보험자를 말합니다.
4. 신차가액의 변경 
①  피보험자가 보통약관 제49조(피보험자동차의 교체)에 따라 피보험자동차를 교체하는 경우에 보험증권에 기재
  된 보험가입금액은 교체된 자동차의 보험가입금액으로 변경합니다. 다만, 교체된 차량이 신차가 아닌 경우에는 
  이 특별약관에 의한 보험계약의 효력은 교체하는 시점부터 없어집니다.
②  회사는 위 ‘①’의 경우에는 그 정하는 바에 따라 보험료를 돌려드리거나 추가보험료를 청구할 수 있습니다. 
③  보험계약자 또는 피보험자가 위 ‘②’의 추가보험료의 납입을 청구 받은 때에는 지체 없이 이를 회사에 납입해야 
  합니다.
보험금 종류
보상 내용 및 지급 금액
차량 신차가액 보상금
보험증권에 기재된 자기차량손해 보험가입금액을 기준으로 보통약관 자기차량손
해 및 차량단독사고 보장 특별약관에 의한 보험금을 공제한 금액을 지급
<별표〉 
차량전손 시 
취득세비용 보험금
보험증권에 기재된 자기차량손해 보험가입금액의 7%에 해당하는 금액 한도에서 
실제로 소요된 자동차 취득세를 지급(단, 차량가액 초과수리비 특별약관에 따라 
보험금이 지급되는 경우에는 지급되지 않음) 
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
120
121
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (63, 1, 63, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
1. 가입대상 
이 특별약관은 보통약관의 자기차량손해에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
① 보험회사는 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별약관에 의한 보험금이 지급되는 경
  우로 한 번의 사고로 생긴 손해가 전부손해(보통약관 제24조 ‘전부손해’ 규정을 따름)일 때, 차량전손 시 취득
  세비용 보험금을 지급합니다. 다만, 차량가액 초과수리비 특별약관에 따라 보험금이 지급되는 경우에는 지급하
  지 않습니다.
② 위 ‘①’의 차량전손 시 취득세비용 보험금은 보험증권에 기재된 자기차량손해 보험가입금액의 7%에 해당하는 
  금액 한도에서 실제로 소요된 자동차 취득세를 말합니다.
3. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
2⃞  차량전손 시 취득세비용 담보 특별약관
1. 가입대상 
이 특별약관은 보통약관 자기차량손해에 가입하면서 보험가입금액을 보험책임개시일의 보험가액(보통약관 제21
조의 ‘보험가액’ 규정을 따름)과 동일하게 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
보험회사는 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별약관에 의한 보험금이 지급되는 사고로 
인하여 피보험자동차를 실제로 수리하는 경우에는 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별
약관의 규정에도 불구하고 사고발생 당시 보험가액의 120%를 한도로 보상합니다.
3. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
3⃞  차량가액 초과수리비 특별약관
5. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 가입대상 
이 특별약관은 보통약관의 자기차량손해에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
① 보험회사(이하 “회사”라 함)는 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별약관에 의한 보
  험금이 지급되는 경우로, 피보험자동차가 주행이 불가능한 때에는 다음의 비용을 사고당 20만원의 한도 내에서 
  원격지 차량운반비용 보험금으로 보상합니다.
 1) 수리를 위하여 피보험자동차를 기명피보험자의 거주지(보험증권에 기재된 주소지를 말함) 근처의 정비공장
   이나 회사가 인정하는 장소 또는 사고발생지 근처의 정비공장 등까지 운반하는데 드는 필요 타당한 비용
 2)  수리종료 후 피보험자동차를 기명피보험자 거주지 근처의 회사가 인정하는 장소까지 견인차 등에 의해 운반
   하는데 드는 필요 타당한 비용
② ‘①’의 비용은 보험계약자 또는 피보험자로부터 영수증 등을 제출받아 회사가 그 지출목적, 금액, 그 밖에 구체
  적 내용을 인정한 것에 한정됩니다.
3. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
4⃞  원격지 차량운반비용 담보 특별약관
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
1. 가입대상  
이 특별약관은 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)가 보통약관의 자기차량손해에 가입한 경우
에만 가입할 수 있습니다.
[1] 렌트비용담보
2. 렌트비용의 보상  
① 보험회사(이하 “회사”라 함)는 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별약관에 의한 보
  험금이 지급되는 경우로 피보험자동차를 사용할 수 없게 된 때에는 피보험자동차의 대체교통수단으로 피보험
  자동차와 동종의 국내산 자동차를 렌트하는데 드는 통상의 비용(이하 “렌트비용”이라 함)을 다음 ‘②’에서 정하
  는 바에 따라 보상하여 드립니다.
② 회사가 사고마다 보상하는 렌트비용은 다음의 렌트비용 인정기간에 렌트비용 인정기준액을 곱한 금액을 지급
  합니다.
 1)  렌트비용 인정기간
䣫  렌트비용 담보 특별약관
※  이 특별약관은 임시교통비 담보 특별약관과 중복하여 가입할 수 없습니다.
구분
인정기간
㉮ 수리 가능 시
㉯ 수리 불가능 시
㉰ 도난 시
30일을 한도로 실제 수리에 걸리는 기간(단, 외국산 자동차로서 부품조달에 필
요한 기간과 부당한 수리지연으로 연장되는 기간은 인정기간에 넣지 않음)
10일
경찰관서에 신고한 날부터 30일 한도(단, 30일 이내에 도난자동차를 찾은 때에
는 도난자동차를 발견한 날까지 만으로 함)
 2)  렌트비용 인정기준액
구분
인정기준액
㉮ 렌트를 하는 경우
㉯ 렌트를 하지 않는 경우
<별표> ‘1일당 차량종류별 렌트비용 한도금액’ 안에서 실제로 든 비용(단, 회사
가 동종의 국내산 자동차를 제공했을 때 대여비용은 회사가 전액 부담함)
피보험자동차와 동종의 국내산 자동차를 기준으로 산정한 렌트비용의 30%에 
상응하는 금액(단, 1일 지급한도는 <별표> ‘1일당 차량종류별 렌트비용 한도금
액’의 30%로 한정함)
[2] 렌터카 손해담보
3. 렌터카 손해의 보상  
①  회사는 위 ‘2.’에 따라 렌트를 한 때에 한정하여 렌트한 자동차(이하 “렌터카”라 함)를 피보험자가 사용, 관리하
  는 동안에 발생한 렌터카의 사고로 인하여 생긴 손해에 대하여 렌터카를 보통약관의 대인배상Ⅱ, 대물배상, 자
차량 종류
소형
(1,600cc이하)
중형
(1,600cc 초과 
2,000cc 이하)
대형
(2,000cc 초과 
2,800cc 이하)
대형
(2,800cc 초과)
다인승
(법정승차정원 
7~10인승)
1일 렌트비용 
한도금액
76,000원
112,000원
216,000원
349,000원
137,000원
<별표> 1일당 차량종류별 렌트비용 한도금액 
122
123
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (64, 1, 64, '담보
피보험자
[1] 렌트비용담보
[2] 렌터카 손해담보
 
 
              기명피보험자
보통약관 제7조/13조/18조/22조 및 자동차상해 특별약관 제3조, 자동차상해 
Family 통합보장 특별약관 제3조(이상 “피보험자”)에서 규정하는 자
5. 보험계약의 종료 
보통약관 제24조(지급보험금의 계산) 제③항에도 불구하고 렌터카 손해담보에 의한 보험계약은 피보험자동차의 
사고가 발생한 날부터 10일이 되는 날의 24시에 끝납니다. 
6. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 
1. 가입대상 
이 추가특별약관은 렌트비용 담보 특별약관에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
①  보험회사(이하 “회사”라 함)는 피보험자동차의 정비기간(*1) 동안 피보험자동차를 사용할 수 없는 이유로 피보
  험자가 자동차대여사업자로부터 대여 받은 렌터카(*2)를 사용, 관리하는 동안에 발생한 렌터카의 사고로 인하여 
  생긴 손해에 대하여 이 특별약관을 적용합니다. 
    이 특별약관 적용 시 회사는 피보험자가 운전한 그 렌터카를 보통약관의 대인배상Ⅱ, 대물배상, 자기신체사고, 
  무보험자동차에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관, 차
  량단독사고 보장 특별약관, 대물배상 가입금액 확장담보 특별약관 규정의 피보험자동차로 보아 보상하여 드립
  니다.
②  회사가 보상할 위 ‘①’의 손해에 대하여 렌터카에 적용되는 자동차보험계약 또는 공제계약에 따라 보험금이 지
  급될 수 있는 경우에는 회사가 보상할 금액이 그 렌터카의 자동차보험계약 또는 공제계약에 따라 지급될 수 있
  는 금액을 초과하는 때에 한정하여 그 초과액만을 보상합니다.
5⃞-①  고장수리 시 렌터카 운전담보 추가특별약관
  기신체사고, 무보험자동차에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 Family 통합보장 
  특별약관, 차량단독사고보장 특별약관, 대물배상 가입금액 확장담보 특별약관 규정의 피보험자동차로 보아 이 
  특별약관에서 정하는 바에 따라 보상하여 드립니다.
②  위 ‘①’의 렌터카의 사고는 ‘2.의 1)’의 렌트비용 인정기간 중의 사고로 대여사업자로부터 렌터카를 인도받은 
  때부터 렌트비용 인정기간 마지막 날의 24시를 한도로 렌터카를 반납할 때까지의 사고만으로 합니다. 
    다만, 렌트비용 인정기간 만료일이 보험증권에 기재된 보험기간 만료일 이후인 경우에는 보험기간 만료일까지
  의 사고만으로 합니다.
③  회사가 보상할 위 ‘①’의 손해 중 렌터카의 차량손해는 보통약관의 자기차량손해 규정에도 불구하고 피보험자동
  차의 보험가액과 렌터카의 사고가 발생한 곳과 때의 렌터카 가액 중 낮은 가액을 한도로 사고 직전의 상태로 
  고치는데 드는 수리비 및 교환가액만을 보상합니다.
④  회사가 보상할 ‘①’부터 ‘③’까지의 손해에 대하여 렌터카에 적용되는 자동차보험계약 또는 공제계약에 따라 보
  험금이 지급될 수 있는 경우에는 ‘①’부터 ‘③’까지의 규정에 따른 금액에서 렌터카에 적용되는 자동차보험계약 
  또는 공제계약에 따라 지급될 수 있는 금액을 공제한 금액만으로 합니다.
4. 피보험자  
피보험자는 각 담보별로 다음과 같습니다.
(*1) ‘피보험자동차의 정비기간’이란 렌트비용 담보 특별약관 ‘2.’에 따라 렌트를 한 경우 이외의 정비기간으로서 
   피보험자동차를 사용할 수 없는 기간을 말합니다.
3. 피보험자 
이 추가특별약관에서 피보험자란 기명피보험자 또는 기명피보험자의 배우자를 말합니다. 
4. 보상하지 않는 손해 
회사는 보통약관 제5조/8조/14조/19조/23조(이상 ‘보상하지 않는 손해’)에서 정하는 사항은 보상하지 않고, 또
한 보험증권에 기재된 운전가능범위 외의 자가 렌터카를 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다. 
5. 렌터카 차량손해 보상한도 
① 회사가 렌터카 차량보험금을 지급할 때에는, 보통약관 제24조(지급보험금의 계산) 제①항 제3호에도 불구하
  고 한 번의 사고로 생긴 손해가 전부손해(보통약관 제24조 ‘전부손해’ 규정을 따름)일 경우에도 보험증권에 기
  재된 자기부담금을 공제하고 지급합니다.
②  회사가 렌터카 차량보험금을 지급할 때에는, 보통약관 자기차량손해 규정에도 불구하고 피보험자동차의 보험
  가액과 렌터카의 사고가 발생한 곳과 때의 렌터카 가액 중 낮은 가액을 한도로 사고 직전의 상태로 고치는데 드
  는 수리비 및 교환가액지식89)만을 보상합니다.
6. 보험계약의 종료 
이 추가특별약관은 보통약관 제24조(지급보험금의 계산) 제③항을 적용하지 않습니다.
7. 준용규정 
이 추가특별약관에서 정하지 않은 사항은 보통약관 및 렌트비용 담보 특별약관을 따릅니다.
89) 보통약관 74쪽 프로미카 보험지식 ‘72)’ 참조
1. 가입대상  
이 특별약관은 보통약관의 자기차량손해에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용  
① 보험회사(이하 “회사”라 함)는 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별약관에 의한 보
  험금이 지급되는 경우로 피보험자동차를 사용할 수 없게 된 때에는 피보험자에게 생긴 손해를 임시교통비 보험
  금으로 보상합니다.
②  회사가 사고마다 보상하는 위 ‘①’의 임시교통비 보험금은 보험증권에 기재된 1일 보험금에 <별표>의 임시교통
  비 인정기간을 곱하여 산출한 금액으로 합니다.
6⃞  임시교통비 담보 특별약관
※ 이 특별약관은 렌트비용 담보 특별약관과 중복 가입할 수 없습니다.
㉰ 도난 시
경찰관서에 신고한 날부터 30일 한도(단, 30일 이내에 도난자동차를 찾은 때에는 
도난자동차를 찾은 때까지로 함)
구분
인정기간
㉮ 수리 가능 시
㉯ 수리 불가능 시
30일을 한도로 실제 수리에 걸리는 기간(단, 외국산 자동차로서 부품조달에 필요
한 기간과 부당한 수리지연으로 연장되는 기간은 제외)
10일
<별표> 임시교통비 인정기간
(*2) ‘렌터카’란 여객자동차 운수사업법 제28조188쪽)에 따라 등록한 자동차대여사업자가 운행하는 대여사업용 자동
   차를 말합니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
124
125
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (65, 1, 65, '3. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 가입대상 
이 특별약관은 보통약관 자기차량손해에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
① 보험회사(이하 “회사”라 함)는 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별약관에 의한 보
  험금이 지급되는 사고(피보험자동차 전부 또는 일부(레저용품 포함)의 도난으로 인한 손해는 제외)로 인하여 
  피보험자동차에 실려있는 레저용품(*1)이 파손, 멸실 또는 오손되어 생긴 레저용품의 직접적인 손해(이하 “레저
  용품손해”라 함)에 대하여 사고당 보험증권에 기재된 이 특별약관의 가입금액을 한도로 보상합니다. 
② 위 ‘①’의 레저용품손해 보험금은 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별약관의 사고로 
  인해 피보험자동차의 손해액(피보험자동차의 수리비만을 말하며, 이 특별약관에서 담보하는 레저용품의 손해
  액은 포함하지 않음)이 200만원을 초과하거나, 전부손해(보통약관 제24조 ‘전부손해’ 규정에 따름)가 발생한 
  경우만을 말합니다.
7⃞  레저용품손해 담보 특별약관
(*1) ‘레저용품’이란 등산 및 여행장비, 스키장비, 인라인스케이트, 자전거, 캐리어, 골프채, 낚시용구 등 여가생활
   을 위해 주로 사용하는 물품을 말합니다.
   단, 다음의 물건은 포함하지 않습니다.
   (1) 피보험자동차의 부속품, 부속기계장치 및 연료
   (2) 통화, 유가증권, 인지, 예금증서, 우표, 신용카드, 쿠폰, 항공권, 패스포트, 그 밖에 이와 유사한 물건
   (3) 귀금속, 서화, 골동품, 미술품, 그 밖에 이와 유사한 물건
   (4) 원고, 교본, 설계서, 도안, 증서, 장부, 그 밖에 이와 유사한 물건
   (5) 동물, 식물 등의 생물
   (6) 상품, 견본품 및 사업상 예탁 받은 물건
   (7) 의치, 의족, 안경, 콘택트렌즈 등 신체보조장구
3. 피보험자 
이 특별약관의 피보험자는 레저용품의 소유자를 말합니다. 다만, 피보험자동차를 정당하게 사용할 권리가 있는 자
의 승낙을 받지 않고 피보험자동차에 탑승 중인 자는 포함하지 않습니다. 
4. 손해액의 결정 
①  회사가 보상해야 할 손해액은 그 손해가 발생한 때와 장소의 레저용품가액(이하 “레저용품가액”이라 함)을 기
  준으로 계산한 손해액에서 보험증권에 기재된 자기부담금을 뺀 금액으로 합니다.
②  레저용품의 손상을 고칠 수 있는 경우에는 사고가 생기기 바로 전의 상태로 고치는데 드는 수리비를 손해액으로 
  합니다. 이 경우에 잔존물이 있을 때에는 그 값을 공제합니다.
③  레저용품을 고칠 때에 부득이 부품을 새것으로 쓴 경우에는 그 부품의 값과 그 부착 비용을 합친 금액을 수리비
  로 합니다. 그러나, 부품을 새것으로 교환하여 레저용품의 값이 증가할 때에는 증가된 금액을 공제합니다. 
5. 보험금의 청구 
피보험자는 사고가 발생하여 회사에 보험금을 청구할 때, 반드시 기명피보험자를 경유하여 청구해야 합니다.
6. 회사의 피해물 인수 
회사가 레저용품의 전부손해로 레저용품가액으로 보험금을 지급하였을 때에는 피해물(레저용품)을 인수합니다. 
그러나 회사가 피해물을 인수하지 않겠다는 뜻을 표시하고 보험금을 지급했을 때에는 피해물에 대한 피보험자의 
권리는 회사에 이전되지 않습니다.
7. 현물보상 
회사는 레저용품에 생긴 손해에 대하여 회사가 필요할 경우, 피보험자의 동의를 받아 보험금지급 대신 레저용품을 
수리하거나, 대용품을 지급할 수 있습니다.
8. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
(*1)‘외제차’란 외국 자동차 제조회사에 의해 대한민국이 아닌 곳에서 제조되어 수입, 판매되는 자동차로서 자동차
   관리법 제2조190쪽)에 의한 자동차를 말하며, 다음의 자동차는 제외합니다.
   (1) 외국에 본점 소재지를 둔 외국 자동차 제조회사(해당 회사의 대한민국 내 자회사, 법인 포함)가 대한민국 
     내에서 제조(또는 조립) 완료한 자동차
   (2) 국내에 본점 소재지를 둔 국내 자동차 제조회사(해당 회사의 외국소재 자회사, 법인 포함)가 대한민국이 
     아닌 곳에서 제조(또는 조립) 완료한 자동차
   (3) 위 ‘(1)’의 외국 자동차 제조회사와 ‘(2)’의 국내 자동차 제조회사가 기술제휴(공동설계, 공동판매)하여 
     제조(또는 조립)한 자동차
1. 가입대상  
이 특별약관은 보험증권에 기재된 자동차(이하 “피보험자동차”라 함)가 외제차(*1)로서 보통약관 대인배상Ⅰ, 대인
배상Ⅱ, 대물배상(또는 대물배상 가입금액 확장담보 특별약관), 자기신체사고(또는 자동차상해 특별약관, 자동차
상해 Family 통합보장 특별약관) 또는 자기차량손해를 모두 가입한 경우에만 가입 할 수 있습니다.
8⃞  외제차 운반비용 담보 특별약관
※  이 특별약관은 원격지 차량운반비용 담보 특별약관과 중복 가입할 수 없습니다.
2. 보상내용  
① 보험회사(이하 “회사”라 함)는 보통약관 제21조(보상하는 손해) 또는 차량단독사고 보장 특별약관에 의한 보
  험금이 지급되는 경우로, 피보험자동차가 주행이 불가능한 때에는 다음의 비용을 사고당 50만원의 한도 내에서 
  외제차 운반비용 보험금으로 보상합니다.
 1)  수리를 위하여 기명피보험자의 거주지(보험증권에 기재된 주소지를 말함) 근처의 정비공장이나 회사가 인정
   하는 장소 또는 사고발생지 근처의 정비공장 등까지 운반하는데 드는 필요 타당한 비용
 2)  수리종료 후 피보험자동차를 기명피보험자 거주지 근처의 회사가 인정하는 장소까지 견인차 등에 의해 운반
   하는데 드는 필요 타당한 비용
② 위 ‘①’의 비용은 보험계약자 또는 피보험자로부터 영수증 등을 제출받아 회사가 그 지출목적, 금액, 그 밖에 구
  체적 내용을 인정한 것에 한정됩니다.
3. 피보험자  
이 특별약관에서 피보험자란 기명피보험자를 말합니다.
4. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
䣯  차량단독사고 보장 특별약관
1. 가입대상 
이 특별약관은 보통약관 자기차량손해에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
①  보험회사(이하 “회사”라 함)는 보통약관 제21조 제②항에도 불구하고 피보험자가 피보험자동차를 소유ㆍ사
  용ㆍ관리하는 동안 발생한 사고로 인하여 피보험자동차에 직접적으로 생긴 손해를 보험증권에 기재된 보험가
  입금액을 한도로 보상하되 다음의 기준에 따릅니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
126
127
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (66, 1, 66, '(*1) ‘경미한 손상’이란 외장부품 중 자동차의 기능과 안전성을 고려할 때 부품교체 없이 복원이 가능한 손상을 말
   합니다.
(*2) ‘품질인증부품’이란 「자동차관리법」 제30조의5에 따라 인증된 부품을 말합니다.
(*3) ‘물체’란 구체적인 형체를 지니고 있어 충돌이나 접촉에 의해 자동차 외부에 직접적인 손상을 줄 수 있는 것을 
   말합니다. 단, 엔진 내부나 연료탱크 등에 이물질을 삽입하는 경우와 보통약관 제21조(보상하는 손해)에서 규
   정한 ‘타차량’은 물체로 보지 않습니다.
(*4) ‘침수’란 흐르거나 고여 있는 물, 역류하는 물, 범람하는 물, 해수 등에 피보험자동차가 빠지거나 잠기는 것을 
   말하며, 차량 도어(Door)나 선루프(Sun roof) 등을 개방해 놓았을 때 빗물이 들어간 것은 침수로 보지 않습
   니다.
3. 보상하지 않는 손해 
회사는 보통약관 제23조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전가
능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다. 
4. 지급보험금의 계산 
이 특별약관에 의한 지급보험금은 보통약관 제24조(지급보험금의 계산) 규정을 따릅니다.
5. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
(*1)  ‘전기자동차’란 사용연료의 종류가 전기인 자동차로서 「환경친화적자동차의 개발 및 보급촉진에 관한 법률」 
제2조 제3호 및 제6호에 해당하는 자동차를 말합니다.(제2조 제4호 태양광자동차 및 제2조 제5호 하이브리드 
자동차는 제외)
䣰  전기자동차  사고 시 배터리 교체비용 특별약관
1. 적용대상 
이 특별약관은 피보험자동차가 최초차량등록일을 기준으로 5년 이내의 법정승차정원 10인승 이하 전기자동차(*1)
인 경우로서, 보통약관 자기차량손해를 가입한 경우에 한정하여 가입할 수 있습니다.
 1) 피보험자동차의 단독사고(가해자 불명사고를 포함합니다) 또는 일방과실사고의 경우에는 실제 수리를 원칙
   으로 합니다.
 2) 경미한 손상(*1)의 경우 보험개발원이 정한 경미손상 수리기준에 따라 복원수리하거나 품질인증부품(*2)으로 
   교환수리하는 데 소요되는 비용을 한도로 보상합니다.
②  위 ‘①’의 ‘사고’는 다음 중 어느 하나에 해당하는 사고를 말합니다.
 1)  타물체(*3)와의 충돌, 접촉, 추락, 전복 또는 차량의 침수(*4)로 인한 손해
 2)  화재, 폭발, 낙뢰, 날아온 물체, 떨어지는 물체에 의한 손해 또는 풍력에 의해 차체에 생긴 손해
2. 보상내용 
①  보험회사(이하 ‘회사’라 함)는 보통약관 자기차량손해(차량단독사고보장 특별약관을 포함)에서 규정한 사고로 
  피보험자동차의 구동 배터리가 파손되어 수리 또는 부분교체를 통한 활용이 불가능하여 부득이 구동 배터리(*1) 
  전부를 ‘새 배터리’로 교체하는 경우 적용됩니다.
②  회사는 위 ‘①’에 따라 보상하는 경우, 보통약관 제24조 제1항 제1호 나목 및 다목에도 불구하고, 그 교체된 배
  터리의 잔존물 및 감가상각에 해당하는 금액을 피보험자동차의 손해액 산정 시 공제하지 않습니다.
(*1) ‘구동 배터리’란 전기자동차에 장착되어 구동모터에 전기를 공급해주는 배터리를 말합니다. (전기자동차에 장
   착된 보조배터리 제외)
3. 대위 
회사는 보통약관 제34조에도 불구하고, 피보험자동차가 대기환경보전법 제58조 제3항 및 제5항의 적용대상에 해
당할 경우, 피보험자동차의 전부손해 사고로 인한 잔존물 취득 시 구동 배터리는 취득하지 않을 수 있습니다.
4. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
(*1) ‘지진’이란 기상청의 국가기상종합정보의 지진䞱화산 발표정보상의 자연지진을 말하며, 지진규모는 국제기준
   (국지규모: Richter scale) 4.0 이상을 적용합니다.
䣱  지진손해 보상 특별약관
1. 가입대상 
이 특별약관은 보통약관 자기차량손해 및 차량단독사고 보장 특별약관에 가입하는 경우에만 가입할 수 있습니다.
2. 보상내용 
보험회사(이하 “회사”라 함)는 보통약관 ‘제23조(보상하지 않는 손해)의 3’에도 불구하고 피보험자가 피보험자동
차를 소유, 사용, 관리하는 동안 지진(*1)으로 인하여 피보험자동차에 직접적으로 생긴 손해를 보험증권에 기재된 보
험가입금액을 한도로 보상합니다.
3. 보상하지 않는 손해 
회사는 이 특별약관에서 보상하는 ‘지진’으로 인한 손해를 제외한 보통약관 제23조(보상하지 않는 손해)에서 정하
는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전가능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해도 
보상하지 않습니다.
4. 지급보험금의 계산 
이 특별약관에 의한 지급보험금은 보통약관 제24조(지급보험금의 계산) 규정에 따릅니다.
5. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
䣱 - ① 지진손해 시 렌트비용 담보 추가특별약관
1. 가입대상 
이 추가특별약관은 지진손해 보상 특별약관에 가입한 경우에만 가입할 수 있습니다.
2. 렌트비용의 보상 
① 보험회사(이하 “회사”라 함)는 지진손해 보상 특별약관에 의한 보험금이 지급되는 경우로 피보험자동차를 사
  용할 수 없게 된 때에는 피보험자동차의 대체교통수단으로 피보험자동차와 동종의 국내산 자동차를 렌트하는
  데 드는 통상의 비용(이하 “렌트비용”이라 함)을 다음 ‘②’에서 정하는 바에 따라 보상하여 드립니다.
② 회사가 사고마다 보상하는 렌트비용은 다음의 렌트비용 인정기간에 렌트비용 인정기준을 곱한 금액을 지급합
  니다.
 1) 렌트비용 인정기간
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
128
129
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (67, 1, 67, '䣱 - ② 지진으로 인한 차량 전손 시 취득세비용 담보 추가특별약관
1. 가입대상 
이 추가특별약관은 지진손해 보상 특별약관에 가입한 경우에만 가입할 수 있습니다.
2. 보상내용 
① 보험회사(이하 “회사”라 함)는 지진손해 보상 특별약관 의한 보험금이 지급되는 경우로 한번의 사고로 생긴 손
  해가 전부손해(보통약관 제24조 ‘전부손해’ 규정을 따름)일 때, 차량전손 시 취득세비용 보험금을 지급합니다. 
  다만, 차량가액 초과수리비 특별약관에 따라 보험금이 지급되는 경우에는 지급하지 않습니다.
② 위 ‘①’의 차량전손 시 취득세비용 보험금은 보험증권에 기재된 자기차량손해 보험가입금액의 7%에 해당하는 
  금액한도에서 실제로 소요된 자동차 취득세를 말합니다. 
3. 준용규정 
이 추가특별약관에서 정하지 않은 사항은 보통약관 및 지진손해 보상 특별약관을 따릅니다.
 2)  렌트비용 인정기준액
구분
인정기준액
㉮ 렌트를 하는 경우
㉯ 렌트를 하지 않는 경우
<별표> ‘1일당 차량종류별 렌트비용 한도금액’ 안에서 실제로 든 비용(단, 회사
가 동종의 국내산 자동차를 제공했을 때 대여비용은 회사가 전액 부담함)
피보험자동차와 동종의 국내산 자동차를 기준으로 산정한 렌트비용의 30%에 
상응하는 금액(단, 1일 지급한도는 <별표> ‘1일당 차량종류별 렌트비용 한도금
액’의 30%로 한정함)
구분
인정기간
㉮ 수리 가능 시
㉯ 수리 불가능 시
30일을 한도로 실제 수리에 걸리는 기간(단, 외국산 자동차로서 부품조달에 필
요한 기간과 부당한 수리지연으로 연장되는 기간은 인정기간에 넣지 않음)
10일
차량 종류
소형
(1,600cc이하)
중형
(1,600cc 초과 
2,000cc 이하)
대형
(2,000cc 초과 
2,800cc 이하)
대형
(2,800cc 초과)
다인승
(법정승차정원 
7~10인승)
1일 렌트비용 
한도금액
76,000원
112,000원
216,000원
349,000원
137,000원
<별표> 1일당 차량종류별 렌트비용 한도금액 
3. 준용규정 
이 추가특별약관에서 정하지 않은 사항은 보통약관 및 지진손해 보상 특별약관을 따릅니다.
Ⅳ. 무보험자동차에 의한 손해관련
1. 적용대상 
이 특별약관은 보통약관의 무보험자동차에 의한 상해에 가입 시 자동으로 적용됩니다. 
2. 보상내용 
① 보험회사(이하 “회사”라 함)는 피보험자가 다른 자동차(*1)를 운전하던 중(주차 또는 정차 중을 제외함. 이하 같
  음) 생긴 대인 또는 대물사고로 인하여 법률상 손해배상책임을 짐으로써 손해를 입은 때 또는 피보험자가 상해
  를 입었을 때에는 피보험자가 운전한 다른 자동차를 보통약관 대인배상Ⅱ, 대물배상, 자기신체사고, 자동차상
  해 특별약관, 자동차상해 Family 통합보장 특별약관, 대물배상 가입금액 확장담보 특별약관 규정의 피보험자동
  차로 보아 보통약관에서 규정하는 바에 따라 보상하여 드립니다.
②  회사는 피보험자가 다른 자동차를 운전하던 중 생긴 사고로 다른 자동차의 소유자가 상해를 입었을 때에는 이 
  보험계약의 보통약관 자기신체사고 및 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관의 피보험
  자로 보아 보통약관에서 규정한 바에 따라 보상하여 드립니다.
③  회사가 보상할 ‘①’ 또는 ‘②’의 손해에 대하여 다른 자동차에 적용되는 보험계약에 따라 보험금이 지급될 수 있
  는 경우에는 회사가 보상할 금액이 다른 자동차의 보험계약에 따라 지급될 수 있는 금액을 초과하는 때에 한정
  하여 그 초과액만을 보상합니다.
1⃞  다른 자동차 운전담보 특별약관
※  이 특약들을 가입함으로써 피보험자가 피보험자동차 이외의 다른 자동차를 운전하던 중에 생긴 사고
  에 대해 보상받을 수 있습니다.
(*1) 이 특별약관에서 ‘다른 자동차’란 피보험자동차와 동일한 차량종류{승용자동차(다인승 승용자동차를 포함), 
   경ㆍ3종 승합자동차 및 경ㆍ4종 화물자동차지식90) 간에는 동일한 차량종류로 봄}으로서 다음 중 어느 하나에 
   해당하는 자가용자동차를 말합니다.
   (1) 기명피보험자(지정운전자 1인 한정운전 특별약관에 의해 증권에 기재된 지정운전자 포함)와 그 부모, 배
     우자 또는 자녀가 소유하거나 통상적으로 사용하는 자동차가 아닌 것
   (2) 기명피보험자가 자동차를 대체한 경우, 그 사실이 생긴 때부터 회사가 보통 약관 제49조(피보험자동차의 
     교체)의 승인을 한 때까지의 대체자동차
3. 피보험자 
①  이 특별약관에서 피보험자란 다음의 사람을 말합니다. 
 1)  기명피보험자 또는 기명피보험자의 배우자
 2)  지정운전자1인 한정운전 특별약관에 의해 보험증권에 기재된 지정운전자
90)
차량종류
세부내용
다인승 승용차
경승합자동차
법정승차정원 7인 이상 10인 이하의 승용자동차
배기량 1,000cc 미만이고, 법정승차정원이 10인 이하인 승합자동차
3종 승합자동차
경화물 자동차
4종 화물자동차
법정승차정원 11인 이상 16인 이하의 승합자동차
배기량 1,000cc 미만의 화물자동차
적재정량 1톤 이하인 화물자동차
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
130
131
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (68, 1, 68, '②  위 ‘①’에도 불구하고 운전자를 한정하는 특별약관에 따라 위 ‘①’의 피보험자가 운전가능범위에 포함되지 않는 
  경우에는 피보험자로 보지 않습니다. 
4. 보상하지 않는 손해 
회사는 보통약관 제8조/14조/19조(이상 “보상하지 않는 손해”)에서 정하는 사항은 보상하지 않고, 또한 다음과 
같은 손해도 보상하지 않습니다.
 1)  피보험자가 사용자의 업무에 종사하고 있을 때 그 사용자가 소유하는 자동차를 운전하던 중 생긴 사고로 인한 
   손해
 2)  피보험자가 소속한 법인이 소유하는 자동차를 운전하던 중 생긴 사고로 인한 손해
 3)  피보험자가 자동차정비업, 주차장업, 급유업, 세차업, 자동차판매업, 대리운전업 등 자동차 취급업무상 수탁 
   받은 자동차를 운전하던 중 생긴 사고로 인한 손해
 4)  피보험자가 요금 또는 대가를 지급하거나 받고 다른 자동차를 운전하던 중 생긴 사고로 인한 손해
 5)  피보험자가 다른 자동차의 사용에 대하여 정당한 권리를 가지고 있는 자의 승낙을 받지 않고 다른 자동차를 
   운전하던 중 생긴 사고로 인한 손해
 6)  피보험자가 다른 자동차의 소유자에 대하여 법률상의 손해배상책임을 짐으로써 입은 손해
 7)  피보험자가 다른 자동차를 시험용(다만, 운전면허시험을 위한 도로주행시험용은 제외) 또는 경기용이나 경기
   를 위한 연습용으로 사용하던 중 생긴 사고로 인한 손해
 8)  보험증권에 기재된 운전가능범위 외의 자지식91)가 다른 자동차를 운전하던 중 생긴 사고로 인한 손해
5. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
91) “운전가능범위 외의 자”란 ‘Ⅰ. 운전자 한정운전 특별약관’에서 규정하는 운전할 자의 연령 또는 범위에 속하지 않는 사
   람을 말합니다.
1. 가입대상 
이 추가특별약관은 보통약관 무보험자동차에 의한 상해를 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
① 보상내용은 다른 자동차 운전담보 특별약관 ‘2.의 ①, ②’와 같습니다. 
②  위 ‘①’에도 불구하고, 위 ‘①’의 손해가 아래의 보험계약에 따라 보험금이 지급될 수 있는 경우에는 회사가 보상
  할 금액이 다음 중 하나에 따라 지급될 수 있는 금액을 초과하는 때에 한정하여 그 초과액만을 보상합니다. 
 1.  다른 자동차에 적용되는 보험계약
 2.  다른 자동차를 운전한 자녀(*1)가 소유하는 자동차에 적용되는 보험계약
 3.  다른 자동차를 운전한 자녀의 배우자(사실혼 관계 포함)가 소유하는 자동차에 적용되는 보험계약
1⃞-①  자녀운전자 담보 추가특별약관
3. 피보험자 
①  이 추가특별약관에서 피보험자는 다음에 열거하는 사람을 말합니다. 
 1)  기명피보험자 또는 기명피보험자의 배우자
 2)  기명피보험자의 자녀
 3)  위 ‘2)’의 법률상 배우자 (사실혼 관계 제외)
(*1) 이 추가특별약관에서 자녀라 함은 법률상의 혼인관계에서 출생한 자녀, 사실혼관계에서 출생한 자녀, 양자 또
   는 양녀, 계자녀를 말합니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
1. 가입대상 
이 특별약관은 보통약관의 무보험자동차에 의한 상해에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
① 보험회사(이하 “회사”라 함)는 피보험자가 다른 자동차(*1)를 운전(주차 또는 정차 중을 제외함. 이하 같음)하
  는 동안 생긴 사고로 인하여 피보험자가 운전한 다른 자동차에 직접적인 손해가 발생하여 다른 자동차의 소유자
  에게 법률상 손해배상책임을 짐으로써 손해를 입었을 때에는 피보험자가 운전한 다른 자동차를 보통약관의 자
  기차량손해 및 차량단독사고 보장 특별약관 규정의 피보험자동차로 보아 보통약관 및 해당 특별약관에서 규정
  하는 바에 따라 보상하여 드립니다. 
② 다른 자동차가 사업용자동차 중 대여자동차이면서 위 ‘2. 보상내용 제①항’에서 정하는 사고가 발생한 경우에는 
  보통약관 <별표2> 대물배상 지급기준의 ‘4.휴차료’에 따른 대여사업자의 타당한 영업손해를 보상합니다.
③  위 ‘①’과 ‘②’의 손해에 대하여 다른 자동차에 적용되는 보험계약에 따라 보험금이 지급될 수 있는 경우에는 회
  사가 보상할 금액이 다른 자동차의 보험계약에 따라 지급될 수 있는 금액을 초과하는 때에 한정하여 그 초과액
  만을 보상합니다.
2⃞  다른 자동차 차량손해 특별약관
(*1) 이 특별약관에서 ‘다른 자동차’란 다음의 자동차를 말합니다.
   [1] 피보험자동차와 동일한 차량종류[승용자동차(다인승 승용자동차를 포함), 경ㆍ3종 승합자동차 및 경ㆍ4
     종 화물자동차지식92) 간에는 동일한 차량종류로 봅니다]으로서 다음 중 어느 하나에 해당하는 자가용자동
     차
    (1) 기명피보험자(지정운전자 1인 한정운전 특별약관에 의해 증권에 기재된 지정운전자 포함)와 그 부모, 
      배우자 또는 자녀가 소유하거나 통상적으로 사용하는 자동차가 아닌 것
    (2) 기명피보험자가 자동차를 대체한 경우, 그 사실이 생긴 때부터 회사가 보통약관 제49조(피보험자동차
      의 교체)의 승인을 한 때까지의 대체자동차
   [2] 사업용자동차 중 승차정원 10인승 이하의 대여자동차. 단, 다음 중 하나에 해당하는 자동차는 제외합니다.
    (1) 기명피보험자(지정운전자 1인 한정운전 특별약관에 의해 증권에 기재된 지정운전자 포함)와 그 부모, 
      배우자 또는 자녀가 대여사업자로부터 8일 이상 대여받은 자동차
    (2) 기명피보험자(지정운전자 1인 한정운전 특별약관에 의해 증권에 기재된 지정운전자 포함)와 그 부모, 
      배우자 또는 자녀가 통상적으로 사용하는 자동차
92) 130쪽 프로미카 보험지식 ‘90)’ 참조
②  위 ‘①’에도 불구하고, 운전자 한정운전 특별약관에 따라 위 ‘①’의 피보험자가 운전가능범위에 포함되지 않는 
  경우에는 피보험자로 보지 않습니다.
4. 보상하지 않는 손해 
회사는 다른 자동차 운전담보 특별약관의 ‘4.’에서 정하는 사항은 보상하지 않습니다.
5. 준용규정 
이 추가특별약관에서 정하지 않은 사항은 보통약관 및 다른자동차 운전담보 특별약관을 따릅니다.
3. 피보험자 
이 특별약관에서 피보험자란 다음의 사람을 말합니다. 
 1) 기명피보험자 또는 기명피보험자의 배우자
 2) 지정운전자1인 한정운전 특별약관에 의해 보험증권에 기재된 지정운전자
다만, 운전자를 한정하는 특별약관에 따라 기명피보험자 또는 기명피보험자의 배우자가 운전가능범위에 포함되지 
않는 경우에는 피보험자로 보지 않습니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
132
133
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (69, 1, 69, '1. 가입대상 
이 추가특별약관은 다른 자동차 차량손해 특별약관을 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
① 보상내용은 다른 자동차 차량손해 특별약관 ‘2.의 ① 및 ②’와 같습니다. 
②  위 ‘①’에도 불구하고, 위 ‘①’의 손해가 아래의 보험계약에 따라 보험금이 지급될 수 있는 경우에는 회사가 보상
  할 금액이 다음 중 하나에 따라 지급될 수 있는 금액을 초과하는 때에 한정하여 그 초과액만을 보상합니다. 
 1.  다른 자동차에 적용되는 보험계약
 2.  다른 자동차를 운전한 자녀(*1)가 소유하는 자동차에 적용되는 보험계약
 3.  다른 자동차를 운전한 자녀의 배우자(사실혼 관계 포함)가 소유하는 자동차에 적용되는 보험계약
2⃞-①  자녀운전자 담보 추가특별약관
4. 보상하지 않는 손해 
회사는 보통약관 제23조(보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 다음과 같은 손해도 보상하
지 않습니다.
 1) 피보험자가 사용자의 업무에 종사하고 있을 때 그 사용자가 소유하거나 대여사업자로부터 대여 받은 자동차
   를 운전하던 중 생긴 사고로 인한 손해
 2)  피보험자가 소속한 법인이 소유하거나 대여사업자로부터 대여 받은 자동차를 운전하던 중 생긴 사고로 인한 
   손해
 3)  피보험자가 자동차정비업, 주차장업, 급유업, 세차업, 자동차판매업, 대리운전업 등 자동차 취급업무상 수탁 
   받은 자동차를 운전하던 중 생긴 사고로 인한 손해
 4)  다른 자동차가 위 <용어풀이>의 [1]에 해당하는 경우로서 피보험자가 요금 또는 대가를 지급하거나 받고 다른 
   자동차를 운전하던 중 생긴 사고로 인한 손해 
 5)  다른 자동차가 위 <용어풀이>의 [2]에 해당하는 경우로서 피보험자가 요금 또는 대가를 받고 다른 자동차를 
   운전하던 중 생긴 사고로 인한 손해
 6)  피보험자가 다른 자동차의 사용에 대하여 정당한 권리를 가지고 있는 자의 승낙을 받지 않고 다른 자동차를 
   운전하던 중 생긴 사고로 인한 손해
 7)  보험증권에 기재된 운전가능범위 외의 자가 다른 자동차를 운전하던 중 생긴 사고로 인한 손해
5. 보상한도 
① 회사가 지급하는 보험금은 보통약관 제24조(지급보험금의 계산) 제①항 제3호에도 불구하고 한 번의 사고로 
  생긴 손해가 전부손해(보통약관 제24조 ‘전부손해’ 규정을 따름)일 경우에도 보험증권에 기재된 자기부담금을 
  공제합니다.
②  회사가 사고마다 보상하는 금액의 한도는 보험증권에 기재된 보험가입금액을 한도로 하며, 보험가입금액이 다
  른 자동차의 보험가액(보통약관 제21조 ‘보험가액’ 규정을 따름)보다 많을 때에는 다른 자동차의 보험가액을 
  한도로 합니다. 그러나, 보통약관 제24조(지급보험금의 계산) 제①항 제2호에 따라 손해의 방지와 경감을 위하
  여 보험계약자나 피보험자가 지출한 비용은 보상한도를 초과한 경우라도 보상합니다.
6. 보험계약의 종료 
이 특별약관은 보통약관 제24조(지급보험금의 계산) 제③항을 적용하지 않습니다.
7. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
(*1) 이 추가특별약관에서 자녀라 함은 법률상의 혼인관계에서 출생한 자녀, 사실혼관계에서 출생한 자녀, 양자 또
   는 양녀, 계자녀를 말합니다.
1. 가입대상 
이 특별약관은 보통약관의 무보험자동차에 의한 상해에 가입하고 자기차량손해에 가입하지 않은 경우에만 가입할 
수 있습니다. 
2. 보상내용 
①  보험회사(이하 ‘회사’라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안 무보험자동차(*1)에 의
  하여 생긴 사고로 피보험자동차(피보험자동차에 통상 붙어 있거나, 장치되어 있는 부속품과 부속기계장치는 피
  보험자동차의 일부로 봅니다. 그러나 통상 붙어 있거나 장치되어 있는 것이 아닌 것은 보험증권에 기재한 것만 
  해당함)에 직접적으로 생긴 손해에 대하여 배상의무자(*2)가 있을 경우 이 약관에서 정한 바에 따라 보상하여 드
  립니다.
②  회사는 무보험자동차에 의한 사고로 피보험자동차에 직접적으로 생긴 위 ‘①’의 손해액이 다음의 금액을 초과하
  는 경우에만 그 초과액만을 보험금으로 지급합니다. 
3⃞  무보험자동차에 의한 차량손해 특별약관
③  위 ‘①’의 무보험자동차가 농업기계인 경우에는 피보험자가 피보험자동차에 탑승 중인 경우에만 그 손해액을 보
  상하여 드립니다.
배상의무자가 피보험자에게 법률상 손해배상책임을 짐으로써 입은 손해를 보상받을 수 있는 자동차보험(공
제계약을 포함) 대물배상(또는 대물배상 가입금액 확장담보 특별약관, 이하 동일)이 있는 경우, 그에 따라 보
상받을 수 있는 금액의 합계액
(*1) (1) 이 특별약관에서 ‘무보험자동차’라 함은 피보험자동차 이외의 자동차로서 피보험자동차에 직접적인 손해
     를 끼친 다음의 자동차를 말합니다. 다만, 피보험자가 소유한 자동차 또는 피보험자동차에 직접적인 손해
     를 끼친 자동차가 명확히 밝혀지지 않은 경우에 그 자동차는 제외합니다.
    ①  자동차보험 대물배상이나 공제계약이 없는 자동차
    ②  자동차보험 대물배상이나 공제계약에서 보상하지 않는 경우에 해당하는 자동차
    ③  이 약관에서 보상될 수 있는 금액보다 보상한도가 낮은 자동차보험의 대물배상이나 공제계약이 적용되
      는 자동차. 다만, 피보험자동차에 직접적인 손해를 끼친 자동차가 2대 이상인 경우에는 각각의 자동차에 
      적용되는 자동차보험의 대물배상 또는 공제계약에서 보상되는 금액의 합계액이 이 약관에서 보상될 수 
      있는 금액보다 낮은 경우에 한하여 그 각각의 자동차
   (2) (1)의 자동차란 자동차관리법에 의한 자동차, 건설기계관리법에 의한 자동차, 군수품관리법에 의한 차량, 
     도로교통법에 의한 원동기장치자전거 및 농업기계화촉진법에 의한 농업기계를 말합니다.
(*2) ‘배상의무자’란 무보험자동차의 사고로 인하여 피보험자동차에 직접적인 손해를 입혀서 법률상 손해배상책임
   을 지는 사람을 말합니다.
3. 피보험자 
①  이 추가특별약관에서 피보험자는 다음에 열거하는 사람을 말합니다. 
 1)  기명피보험자 또는 기명피보험자의 배우자
 2)  기명피보험자의 자녀
 3)  위 ‘2)’의 법률상 배우자 (사실혼 관계 제외)
②  위 ‘①’에도 불구하고, 운전자 한정운전 특별약관에 따라 위 ‘①’의 피보험자가 운전가능범위에 포함되지 않는 
  경우에는 피보험자로 보지 않습니다.
4. 보상하지 않는 손해 
회사는 다른 자동차 차량손해 특별약관의 ‘4.’에서 정하는 사항은 보상하지 않습니다.
5. 준용규정 
이 추가특별약관에서 정하지 않은 사항은 보통약관 및 다른 자동차 차량손해 특별약관을 따릅니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
134
135
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (70, 1, 70, ' 1)  배상의무자가 피보험자동차에 입힌 손해에 대하여 법률상 손해배상책임을 짐으로써 입은 손해를 보상받을 수 
   있는 자동차보험(공제계약 포함) 대물배상이 있을 경우, 그에 따라 지급될 수 있는 금액
 2)  피보험자가 배상의무자로부터 이미 지급받은 손해배상액 중 피보험자동차의 손해배상액 명목으로 받은 금액
 3)  배상의무자가 아닌 제3자가 부담하여야 할 금액으로서 피보험자가 이미 지급받은 금액
6. 보험금청구와 지급 
①  피보험자가 위 ‘2.’의 손해를 입은 때에는 피보험자는 배상의무자에 대하여 지체 없이 서면으로 손해배상청구를 
  한 후, 회사에 보험금을 청구할 때에는 다음의 서류 또는 증거를 제출하여야 합니다.
 1)  보험금청구서
(*1) ‘비용’이란 보험계약자 또는 피보험자가 이 특별약관의 규정에 의해 손해를 방지하고 줄이기 위하여 지출한 비
   용 및 배상의무자로부터 손해배상을 받을 수 있는 권리를 보전하고 행사하기 위하여 지출한 필요하거나 유익
   한 비용을 말합니다.
3. 피보험자 
이 특별약관의 피보험자란 보험증권에 기재된 기명피보험자를 말합니다. 
4. 보상하지 않는 손해 
①  회사는 보험증권에 기재된 운전가능범위 외의 자가 피보험자동차를 운전하였을 때 생긴 사고로 인한 손해는 보
  상하지 않습니다.
②  회사는 다음과 같은 손해는 보상하지 않습니다.
 1)  피보험자의 고의로 생긴 손해
 2)  피보험자가 무면허운전 중 생긴 사고로 인한 손해
 3)  피보험자가 마약 또는 약물 등(보통약관 제1조 제3호)의 영향에 따라 정상적인 운전을 할 수 없는 상태에서 
   운전하던 중 생긴 사고로 인한 손해  
 4)  영리를 목적으로 요금이나 대가를 받고 피보험자동차를 반복적으로 사용하거나 빌려 준 때에 생긴 손해. 다
   만, 임대차계약(계약기간이 30일을 초과하는 경우에 한정함)에 따라 임차인이 피보험자동차를 전속적으로 
   사용하는 경우는 보상합니다.
     그러나, 임차인이 피보험자동차를 영리를 목적으로 요금이나 대가를 받고 반복적으로 사용하는 경우는 보상
   하지 않습니다.
 5)  피보험자동차를 시험용, 경기용 또는 경기를 위한 연습용으로 사용하던 중 생긴 손해. 다만, 운전면허시험을 
   위한 도로주행시험용으로 사용하던 중 생긴 손해는 보상합니다.
 6)  전쟁, 내란, 사변, 폭동, 소요 및 이와 유사한 사태로 인하여 생긴 손해
 7)  지진, 분화, 태풍, 홍수, 해일 등 천재지변으로 인하여 생긴 손해
 8)  핵연료물질의 직접 또는 간접적인 영향으로 인하여 생긴 손해
 9)  손해를 입힌 배상의무자가 명확히 밝혀지지 않은 사고로 인한 손해
③  회사는 다음의 사람이 배상의무자인 때에는 보상하지 않습니다. 다만, 다음의 사람 이외에 다른 배상의무자가 
  있는 때에는 보상하여 드립니다.
 1)  기명피보험자의 부모, 배우자, 자녀
 2)  기명피보험자로부터 승낙을 받아 피보험자동차를 사용하거나 관리 중인 자의 부모, 배우자, 자녀
 3)  피보험자동차를 운전 중인 자(운전보조자를 포함)의 부모, 배우자, 자녀
④  위 ‘③’의 단서규정(‘다만’이하의 문장)에도 불구하고 회사는 피보험자동차에 직접적인 손해를 입힌 무보험자
  동차를 ‘③의 1)’에 해당하는 자가 운전한 경우에는 보상하지 않습니다.
5. 보상한도 및 지급보험금의 계산 
①  회사가 무보험자동차에 의한 사고로 인한 피보험자동차 손해에 대하여 지급책임을 지는 금액은 보험가액(보통
  약관 제21조 ‘보험가액’ 규정을 따름)을 한도로 합니다.
②  회사가 지급하는 보험금은 보통약관 <별표 2> 대물배상 지급기준 74쪽) 및 <별표 4> 과실상계 등 77쪽)에 따라 산
  출한 금액과 비용(*1)을 합친 금액에서 다음의 금액을 공제한 액수로 합니다.
 2)  손해액을 증명하는 서류
 3)  사고발생의 때와 장소 및 사고발생사실이 신고된 관할경찰관서
 4)  배상의무자의 주소, 성명 또는 명칭, 차량번호
 5)  배상의무자의 손해를 보상할 자동차보험 대물배상 또는 공제계약의 유무 및 그 내용
 6)  배상의무자에게 서면으로 행한 손해배상청구의 금액과 내용
 7)  피보험자가 입은 손해에 대하여 자동차보험 대물배상 또는 공제계약이나 배상의무자 또는 제3자로부터 이미 
   지급받은 손해배상금이 있을 때에는 그 금액
 8)  그 밖에 회사가 꼭 필요하다고 인정하는 서류 또는 증거
②  회사는 피보험자가 제출한 위 ‘①’의 서류 또는 증거를 받은 때부터 10일 이내에 보험금을 정하여 지급합니다.
③  회사가 보험금 지급사유의 조사 및 확인을 위하여 위 ‘②’의 지급기일 초과가 명백히 예상되는 경우에는 구체적 
  사유와 지급예정일을 피보험자에게 서면 통지하여 드립니다. 
④  회사는 ‘② 또는 ③’에서 정한 지급기일까지 보험금을 지급하지 않았을 때에는 그 다음날부터 지급일까지의 기
  간에 대하여 <부표> 보험금을 지급할 때의 적립이율78쪽)에 따라 연 단위 복리로 계산한 금액을 손해배상금에 더
  하여 드립니다. 그러나, 피보험자 또는 보험계약자에게 책임이 있는 사유로 지급이 지연된 때에는 그 해당기간
  에 대한 이자는 더하여 드리지 않습니다.
7. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
Ⅴ. 사고처리 시 필요한 비용
1. 가입대상 
이 특별약관은 보통약관 대인배상Ⅰ 및 대인배상Ⅱ 에 가입한 경우에만 가입할 수 있습니다. 
2. 보상내용 
① 보험회사(이하 “회사”라 함)는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 생긴 피보험자동차
  의 사고지식93)로 인하여 다른 사람(이하 “피해자”라 함)을 죽게 하거나 다치게 한 경우에 이 특별약관에서 정하
  는 바에 따라 법률비용지원금을 지급합니다.
② 회사가 사고마다 지급하는 법률비용지원금의 종류와 지급기준은 다음과 같습니다. 단, 이 특별약관은 기본형, 
  고급형의 상품으로 구분되며, 가입하신 상품의 지급기준에 따라 보상하여 드립니다.
1⃞  법률비용지원금 특별약관
※  이 특약들을 가입함으로써 자동차보험의 보통약관에서 보장하는 비용 이외에 교통사고와 관련하여 추
  가로 발생되는 비용을 보상받을 수 있습니다.
93) “법률비용지원금”은 “피보험자동차의 사고”에 대하여 적용하는 특별약관입니다. 따라서, 여러 대의 차량을 소유한 경우
   라면, 차량별로 각각 가입해야 합니다. 참고하시기 바랍니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
136
137
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (71, 1, 71, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
③  동일한 사고로 ‘②의 1), 2), 3), 4)’의 각 지급사유가 중복되는 경우에는 ‘②의 1), 2), 3), 4)’의 금액을 합산하
  여 지급합니다. 다만, 동일한 피해자가 상해를 입은 직접적인 결과로 의사의 치료를 받던 중 사망한 경우에는 사
  망형사합의금과 상해형사합의금을 중복 지급하지 않고 사망형사합의금 만을 지급합니다.
94) “공소제기”란 검사가 피고사건에 관하여 법원에 그 심판을 청구하는 소송행위를 말합니다. 기소 또는 소추라고도 하며, 
   이 경우 검사는 사건을 판단하여 정식재판 대신 약식기소를 할 수 있습니다.
95) “약식기소”란 벌금 등을 내릴 수 있는 사건에서 피의자의 이의가 없을 경우에 검사가 정식재판 대신 서면에 의한 약식명
   령의 재판을 청구하는 기소절차의 방식을 말합니다.
4) 벌금
2,000만원 한도
(특정범죄 가중처벌 등에 관한 법률 
제5조의 13(어린이 보호구역에서 
어린이 치사상의 가중처벌)을 
적용받는 경우 3,000만원 한도)
대한민국법원의 확정판결에 의해 피보험자
가 부담하는 벌금을 지급기준 한도 내에서 
지급
2) 상해형사합의금
다음의 사고로 피보험자가 피해자를 다치게 
하여 형사합의를 한 경우 피해자 1인당 지급
기준 한도에서 실제 합의된 금액을 지급 (단, 
한 사고가 다음 ㉮와 ㉯에 모두 해당되는 경
우에도 보험금을 중복하여 지급하지 않음)
㉮ 교통사고처리특례법 제3조 제2항 단
  서 중 이 특별약관의 <별표>에 해당하는 
  사고
㉯ 피해자가 형법 제258조 제1항 또는 제
  2항194쪽), 교통사고처리특례법 제4조 제
  1항 제2호180쪽)의 중상해를 입은 사고
상해 1~3급 : 
3,000만원 한도
상해 4~7급 : 
500만원 한도  
상해 1~3급 : 
1,000만원 한도
상해 4~7급 : 
400만원 한도  
3) 변호사선임비용
500만원 한도  
300만원 한도  
다음 중 하나에 해당하여 변호사를 선임하는
데 실제로 든 비용을 지급기준 한도 내에서 
지급
㉮ 피보험자가 구속영장에 의해 구속되거
  나 검사에 의해 공소제기지식94)된 경우 
  (단, 약식기소지식95)는 제외)
㉯ 검사가 약식기소 하였으나 형사소송법 
  제450조194쪽)에 의하여 법원에 의해 공
  판절차로 재판이 진행되는 경우
㉰ 검사 또는 피보험자가 형사소송법 제
  453조194쪽)에 의하여 정식재판을 청구
  하는 경우
구분
지급기준
기본형
고급형
보상내용
1) 사망형사합의금
3,000만원 한도  
2,000만원 한도  
피보험자가 피해자를 사망케 하여 형사합의
를 한 경우 피해자 1인당 지급기준 한도에서 
실제 합의된 금액을 지급
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
④  위 ‘②의 1) 또는 2)’에서 법원에 공탁지식96)한 경우에는 피해자 1인당 지급기준 한도에서 실제 공탁금액을 지급
  합니다. 단, 공탁자가 공탁금을 회수 시에는 지급된 형사합의금을 돌려주어야 합니다.
⑤  위 ‘②의 1) 또는 2)’의 보험금을 청구하고자 하는 경우에는 다음의 서류를 제출하여야 합니다. 단, 형법 제 258
  조 제 1항 또는 제2항194쪽)의 중상해를 입힌 경우에는 보험회사가 필요하다고 인정하는 서류(중상해 증명 서류 
  등)를 추가 제출하여야 합니다.
 1)  경찰관서에서 발행하는 교통사고사실확인원, 검찰에 의해 기소된 경우 검찰청에서 발행한 공소장
 2)  경찰관서 또는 검찰청에 제출된 교통사고 형사합의서
 3)  가해자가 법원에 공탁한 경우 법원 혹은 검찰청에 제출한 공탁(확인)서 및 공탁금 회수제한 신고서
 4)  그 밖에 보험회사가 필요하다고 인정하는 증명서류(형사합의금액을 증명할 수 있는 서류 등)
⑥ 다음 중 모두에 해당하는 경우 회사는 위 ‘②의 1) 또는 2)’의 보험금을 피해자에게 직접 지급할 수 있습니다.
  1)  피보험자와 피해자간 형사합의금액을 확정하고, 피해자가 형사합의금액을 별도로 장래에 지급받는 조건으로 
   형사합의를 한 경우.
 2)  회사가 피해자에게 형사합의금을 직접 지급하는 경우 피보험자가 이 특별약관에 따라 피해자에게 직접 지급
   되는 보험금(형사합의금)에 상응하는 청구권을 포기한 경우.
⑦  위 ‘⑥’에 따라 회사가 형사합의금을 피해자에게 직접 지급할 경우, 피보험자는 다음의 서류를 제출하여야 합니다.
 1)  경찰관서 혹은 검찰청에 제출된 자동차 교통사고 형사합의서(단, 합의금액이 명시되어 있어야 하며, 합의금
   액을 장래에 지급한다는 내용이 포함되어 있어야 함)
 2)  보험금(형사합의금) 수령에 관한 위임장 및 확인서(보험회사 양식)
 3)  경찰관서에서 발행하는 교통사고사실확인원, 검찰에 의해 기소된 경우 검찰청에서 발행한 공소장
 4)  진단서, 소견서 등 피해자의 상해등급을 확인할 수 있는 서류
 5)  그 밖에 보험회사가 필요하다고 인정하는 서류
◇ 도로교통법 제5조에 의한 신호기 또는 교통정리를 하는 경찰공무원 등의 신호나 통행의 금지 또는 일시정
  지를 내용으로 하는 안전표지가 표시하는 지시에 위반하여 운전한 경우
◇  도로교통법 제13조 제3항을 위반하여 중앙선을 침범하거나 동법 제62조의 규정에 위반하여 횡단ㆍ유턴 
  또는 후진한 경우
◇  도로교통법 제17조 제1항 또는 제2항에 의한 제한속도를 매시 20킬로미터를 초과하여 운전한 경우
◇  도로교통법 제21조 제1항•제22조•제23조 또는 제60조 제2항에 의한 앞지르기의 방법ㆍ금지시
  기ㆍ금지장소 또는 끼어들기의 금지를 위반하여 운전한 경우
◇  도로교통법 제24조에 의한 건널목통과방법을 위반하여 운전한 경우
◇  도로교통법 제27조 제1항에 의한 횡단보도에서의 보행자 보호의무를 위반하여 운전한 경우
◇  도로교통법 제13조 제1항을 위반하여 보도가 설치된 도로의 보도를 침범하거나 동법 제13조 제2항에 의
  한 보도횡단방법을 위반하여 운전한 경우
◇  도로교통법 제39조 제3항에 의한 승객의 추락방지의무를 위반하여 운전한 경우
◇  도로교통법 제12조 제3항에 의한 어린이 보호구역에서 같은 조 제1항에 의한 조치를 준수하고 어린이의 
  안전에 유의하면서 운전하여야 할 의무를 위반하여 어린이의 신체를 상해에 이르게 한 경우
◇  도로교통법 제39조 제4항을 위반하여 자동차의 화물이 떨어지지 아니하도록 필요한 조치를 하지 아니하
  고 운전한 경우
<별표> ‘2.의 ②, 2)’ 관련사고 
96) “공탁”이란 법령의 규정에 의하여 금전이나 유가증권, 기타의 물품을 공탁소에 맡기는 것을 말합니다.
138
139
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (72, 1, 72, '보험회사는 이 추가특별약관에 따라 법률비용지원금 특별약관의 ‘2.의 ②, 4)’의 손해는 보상하지 않습니다.
보험회사는 이 추가특별약관에 따라 법률비용지원금 특별약관의 ‘2.의 ②, 3)’의 손해는 보상하지 않습니다.
1⃞-①  벌금 제외 추가특별약관
1⃞-②  변호사 선임비용 제외 추가특별약관
3. 피보험자
이 특별약관에서의 피보험자는 보통약관 제7조(피보험자)에서 열거하는 사람을 말합니다. 
4. 보상하지 않는 손해
① 회사는 다음과 같은 경우에는 보상하지 않습니다.
1) 보험계약자, 피보험자의 고의로 인하여 사고가 발생한 경우
2) 전쟁, 혁명, 내란, 사변, 폭동, 소요 및 이와 유사한 사태로 인하여 사고가 발생한 경우
3) 지진, 분화, 태풍, 홍수, 해일 또는 이와 유사한 천재지변으로 인하여 사고가 발생한 경우
4) 핵연료물질의 직접 또는 간접적인 영향으로 사고가 발생한 경우
5) 범죄를 목적으로 피보험자동차를 사용하던 중에 사고가 발생한 경우
6) 피보험자가 무면허운전(보통약관 제1조 제4호) 또는 음주운전(보통약관 제1조 제9호)을 하였을 때에 사고
   가 발생한 경우
7) 영리를 목적으로 요금이나 대가를 받고 피보험자동차를 반복적으로 사용하거나 빌려 준 때에 생긴 손해. 다
   만, 임대차계약(계약기간이 30일을 초과하는 경우만을 말함)에 따라 임차인이 피보험자동차를 전속적으로 
   사용하는 경우는 보상합니다. 그러나, 임차인이 피보험자동차를 영리를 목적으로 요금이나 대가를 받고 반복
   적으로 사용하는 경우는 보상하지 않습니다.
8) 피보험자가 사고를 일으키고 도주한 경우
9) 피보험자동차를 시험용(다만, 운전면허시험을 위한 도로주행시험용은 제외) 또는 경기용이나 경기를 위한 연
   습용으로 사용하던 중에 사고가 발생한 경우
 10) 보험증권에 기재된 운전가능범위 외의 자가 피보험자동차를 운전하던 중에 사고가 발생한 경우
 11) 피보험자가 마약 또는 약물 등(보통약관 제1조 제3호) 영향에 따라 정상적인 운전을 할 수 없는 상태에서 운
   전하던 중 사고가 발생한 경우
② 다음 중 어느 하나에 해당하는 사람이 죽거나 다친 경우에는 보상하지 않습니다.
1) 기명피보험자 또는 그 부모, 배우자 및 자녀(보통약관 제1조 제15호) 
2) 피보험자동차를 운전 중인 자(운전보조자를 포함) 또는 그 부모, 배우자 및 자녀 
3) 기명피보험자로부터 허락을 받아 피보험자동차를 운행하는 자 또는 그 부모, 배우자 및 자녀
5. 대위
회사는 보험금을 지급한 경우에도 그 사고로 피보험자가 제3자에 대하여 가지고 있는 손해배상청구권을 회사에 이
전하지 않습니다.
6. 보험금의 분담
이 특별약관에서의 사망형사합의금, 상해형사합의금, 변호사선임비용, 벌금이 지급되는 경우에는 보통약관 제33
조(보험금의 분담)에서의 다른 보험계약이나 공제계약에 장기손해보험 및 일반보험을 포함하여 적용합니다.
7. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
Ⅵ. 긴급출동서비스
※ 이 특약들을 가입함으로써 피보험자동차를 소유ㆍ사용ㆍ관리하던 중 발생한 차량관련 각종 문제를 해
  결할 수 있는 서비스를 받으실 수 있습니다.
1. 회사의 서비스책임
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 피보험자동차(법정승차정원 10인승 이하의 전기자
동차 제외)를 소유ㆍ사용ㆍ관리하는 동안에 긴급출동서비스 등을 요청할 때에는 이 특별약관에 따라 해당하는 서
비스(이하 “SOS서비스”라 함)를 제공합니다. 
2. SOS서비스의 내용
① 회사가 제공하는 SOS서비스는 다음과 같습니다. 
1⃞  프로미카 SOS서비스 특별약관
1) 긴급견인
2) 비상급유
1일 1회만 제공
(초과 시 
피보험자 부담)
㉮피보험자동차가 사고 또는 고장으로 인해 자력으로 운행할 수 없어 
  수리를 위해 긴급견인이 필요할 경우, 보험증권에 기재된 견인거리
  를 한도로 가까운 정비공장까지 견인하여 드립니다. 
㉯위 ‘㉮’의 긴급견인 시 보험증권에 기재된 견인거리를 초과하는 거
  리에 대해 발생한 비용은 피보험자가 부담 합니다. 또한, 피보험자
  동차의 길이 또는 중량이 견인한도를 초과하거나,  적재물 또는 구
  조변경 등으로 인하여 서비스 제공에 제한이 생길 경우에는 서비스
  를 제공하지 않습니다.
㉮피보험자동차가 연료를 완전히 소진하여 운행이 정지된 경우에 보
  험기간 중 총 2회, 1회당 3리터를 한도로 비상급유하여 드립니다.
㉯위 ‘㉮’의 비상급유 시 3리터를 초과하는 경우 피보험자가 그 실비
  용을 부담합니다. 또한, 2회 사용 이후 비상급유서비스를 추가로 
  사용할 시에는 제공되는 연료비용은 피보험자가 부담합니다. 
㉰위 ‘㉮또는㉯’ 에도 불구하고 피보험자동차가 LPG를 연료로 사용
  하는 경우에는 위 ‘1)’에 따른 견인서비스를 제공하여 충전이 가능
  한 가장 가까운 곳까지 견인해 드립니다. 이 경우, 보험증권에 기재
  된 견인거리 한도를 초과하는 거리에 대해 발생된 비용은 피보험자
  가 부담합니다. 
서비스 종류
보상내용
1일 한도
3) 배터리충전
4) 타이어교체
1일 사용제한 
없음
배터리의 방전으로 피보험자동차를 운행할 수 없는 경우에 차량의 운
행이 가능하도록 조치하여 드립니다. 다만, 배터리 교환 시는 배터리 
실비는 피보험자가 부담합니다. 
㉮타이어의 펑크로 인하여 운행을 할 수 없는 경우, 고장 난 타이어를 
  피보험자동차에 내장되어 있는 예비타이어로 교체하여 드립니다. 
  다만, 휠(Wheel)을 개조한 차량의 경우 피보험자가 휠을 교체할 
  수 있는 장비를 지닌 경우에만 교체서비스가 가능합니다.
㉯위 ‘㉮’의 타이어교체 시 차량의 적재물 또는 구조변경 등으로 인하
  여 서비스의 제공에 제한이 생길 경우에는 서비스를 제공하지 않습
  니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
140
141
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (73, 1, 73, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
1일 사용제한 
없음
5) 타이어펑크 수리
㉮지면에 닿은 타이어트레드 부분(접지면)에 날카로운 물체에 의해 
  구멍이 뚫린 단순펑크로 인하여 피보험자동차의 운행이 불가능한 
  경우, 타이어펑크를 수리하여 드립니다. 다만, 자연 마모로 인한 펑
  크 또는 타이어가 찢어진 경우에는 이 서비스를 제공하지 않습니다.
㉯위 ‘㉮’의 타이어펑크 수리 시 다음과 같이 수리가 어려운 경우에는 
  위 ‘1)’ 또는 ‘4)’의 서비스를 제공해 드립니다.
ㄱ)야간, 눈 또는 비가 내리는 경우 등 펑크 위치를 육안으로 확인하
   기 어려운 경우
ㄴ)런플랫(Run-flat)형, 튜브형 타이어 등과 같이 펑크 수리 시 특
   수장비가 필요한 경우
ㄷ)타이어의 측면에 구멍이 뚫린 경우
ㄹ)그 밖의 현장에서 타이어펑크 수리가 곤란한 경우
㉰이 서비스는 타이어펑크 1개당 서비스 1회를 차감합니다.
6) 잠금장치 해제
7) 브레이크/
파워오일 보충
8) 휴즈교환
9) 부동액 보충
10) 긴급구난
㉮피보험자동차의 열쇠를 분실하는 등 차문을 열 수 없는 경우에 잠
  금장치를 해제하여 드립니다.(트렁크 잠금장치 해제는 제외) 다만, 
  잠금장치를 해제하기 위해 부득이 파손된 부분의 원상복구에 드는 
  비용은 보상하지 않습니다. 
㉯위 ‘㉮’의 잠금장치 해제 시 특수 잠금장치(스마트키, 이모빌라이
  저 등)가 장착되어 있거나 사이드 에어백의 장착 등으로 출동차량
  이 현장에서 잠금장치 해제가 어려운 경우, 서비스를 제공하지 않
  을 수 있습니다.
브레이크오일, 파워오일의 부족으로 피보험자동차를 운행할 수 없는 
경우에는 오일 부족분(최대 1리터 한도)을 보충해 드립니다. 
다만, 긴급출동 시 보유한 제품과 규격이 상이한 경우, 서비스가 제한
될 수 있습니다.
휴즈 합선으로 피보험자동차를 운행할 수 없는 때에는 휴즈를 교환하
여 드립니다.
다만, 긴급출동 시 보유한 제품과 규격이 상이한 경우, 서비스가 제한
될 수 있습니다.
부동액 부족으로 피보험자동차를 운행할 수 없는 경우에는 부동액을 
보충하여 드립니다.
다만, 긴급출동 시 보유한 제품과 규격이 상이한 경우, 서비스가 제한
될 수 있습니다.
㉮피보험자동차가 도로를 이탈하거나 장애물로 인하여 자력으로 운
  행을 할 수 없는 경우에는 별도의 구난장비 없이 출동한 자동차로 
  구난 가능한 경우에만 피보험자동차를 구난하여 드립니다. 다만, 
  특수한 구난을 한 경우(*1)에는 피보험자가 추가비용을 부담합니
  다.
㉯위 ‘㉮’의 긴급구난 시 차량의 적재물로 인하여 서비스의 제공이 힘
  든 경우에는 서비스를 제공하지 않습니다.
서비스 종류
보상내용
1일 한도
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
② 위 ‘①’에서 규정한 서비스를 제공하기 위하여 긴급출동하였으나 현장 조치만으로 피보험자동차가 자력운행하
  기 어려워 긴급견인을 할 경우에는 위 ‘①의 1)’과 같은 기준으로 서비스를 제공하여 드립니다.
③ 피보험자에게 책임이 없는 사유로 SOS서비스를 제공받지 못하여 피보험자가 개인적으로 부담한 금액이 있는 
  경우에는 회사가 통상적으로 부담하는 해당 SOS서비스 비용에 상응하는 금액 내에서 피보험자가 부담한 금액
  을 지급합니다.
3. 피보험자
이 특별약관에서 피보험자란 보험증권에 기재된 피보험자를 말합니다. 
4. 보상하지 않는 손해
① 회사는 서비스의 요청지가 다음에 해당할 경우 SOS서비스를 제공하지 않습니다.
1) 견인차가 접근하기 어려운 지역
2) 섬(제주도 및 연륙교로 연결된 섬 제외) 또는 산간 지역
3) 통신교환이 원활하지 못하여 회사가 서비스 제공이 불가능하다고 판단되는 지역
② 회사는 SOS서비스의 지연 또는 미제공으로 인하여 발생한 간접손해는 보상하지 않습니다.
5. 특약의 자동종료
이 특별약관은 피보험자가 이 보험계약 가입 후 SOS서비스를 6회 이상(보험기간이 1년 미만인 경우는 3회 이상) 
받았을 때에는 그 시점부터 자동으로 끝납니다.
6. 특약보험료의 환급
보험계약자 또는 피보험자에게 책임이 있는 사유로 보험계약이 해지된 때에는 회사가 ‘2.의 ①’의 서비스를 제공하
지 않은 경우에만 이미 받은 보험료에서 경과한 기간에 대하여 단기요율(보통약관 제1조 제2호)로 계산한 특약보
험료를 공제한 나머지를 돌려 드립니다.
7. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
보험회사는 이 추가특별약관에 따라 프로미카 SOS서비스 특별약관 ‘2.의 ①, 6)’의 잠금장치해제를 제공하지 않습
니다.
1⃞-①  잠금장치 해제 서비스 제외 추가특별약관
1. 회사의 서비스책임
보험회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 피보험자동차(법정승차정원 10인승 이하의 전기자
동차 제외)를 소유ㆍ사용ㆍ관리하는 동안에 이 특별약관에서 정한 서비스를 요청할 때에는 이 특별약관에 따라 해
당하는 서비스를 제공합니다. 
䣨  프로미카 오토케어서비스 특별약관
(*1)‘특수한 구난을 한 경우’는 다음과 같습니다. 
   (1) 2.5t을 초과하는 구난형 특수자동차로 구난한 경우 
   (2) 2대 이상의 구난형 특수자동차가 구난한 경우 
   (3) 구난작업을 시작하여 견인고리 연결직전까지 걸린 시간
     이 30분을 초과한 경우 
   (4) 2,500cc 이상의 “국산차량 및 외제차량”을 구난한 경우
10) 긴급구난
1일 사용제한 
없음
서비스 종류
보상내용
1일 한도
142
143
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (74, 1, 74, '1일 1회만 제공
(초과 시 
피보험자 부담)
2) 비상급유
㉮피보험자동차가 연료를 완전히 소진하여 운행이 정지된 경우에 
  보험기간 중 총 2회, 1회당 3리터를 한도로 비상급유하여 드립니
  다.
㉯위 ‘㉮’의 비상급유 시 3리터를 초과하는 경우 피보험자가 그 실비
  용을 부담합니다. 또한, 2회 사용 이후 비상급유서비스를 추가로 
  사용할 시에는 제공되는 연료비용은 피보험자가 부담합니다. 
㉰위 ‘㉮또는㉯’ 에도 불구하고 피보험자동차가 LPG를 연료로 사용
  하는 경우에는 위 ''1)''에 따른 견인서비스를 제공하여 충전이 가능
  한 가장 가까운 곳까지 견인해 드립니다. 이 경우, 보험증권에 기재
  된 견인거리 한도를 초과하는 거리에 대해 발생된 비용은 피보험자
  가 부담합니다. 
3) 배터리충전
1일 사용제한 
없음
배터리의 방전으로 피보험자동차를 운행할 수 없는 경우에 차량의 운
행이 가능하도록 조치하여 드립니다. 다만, 배터리 교환 시는 배터리 
실비는 피보험자가 부담합니다. 
4) 타이어교체
㉮타이어의 펑크로 인하여 운행을 할 수 없는 경우, 고장 난 타이어를 
  피보험자동차에 내장되어 있는 예비타이어로 교체하여 드립니다. 
  다만, 휠(Wheel)을 개조한 차량의 경우 피보험자가 휠을 교체할 
  수 있는 장비를 지닌 경우에만 교체서비스가 가능합니다.
㉯위 ‘㉮’의 타이어교체 시 차량의 적재물 또는 구조변경 등으로 인하
  여 서비스의 제공에 제한이 생길 경우에는 서비스를 제공하지 않습
  니다.
5) 타이어펑크 수리
㉮지면에 닿은 타이어트레드 부분(접지면)에 날카로운 물체에 의해 
  구멍이 뚫린 단순펑크로 인하여 피보험자동차의 운행이 불가능한 
  경우, 타이어펑크를 수리하여 드립니다. 다만, 자연 마모로 인한 펑
  크 또는 타이어가 찢어진 경우에는 이 서비스를 제공하지 않습니
  다.
㉯위 ‘㉮’의 타이어펑크 수리 시 다음과 같이 수리가 어려운 경우에는 
  위 ‘1)’ 또는 ‘4)’의 서비스를 제공해 드립니다.
ㄱ)야간, 눈 또는 비가 내리는 경우 등 펑크 위치를 육안으로 확인하
   기 어려운 경우
ㄴ)런플랫(Run-flat)형, 튜브형 타이어 등과 같이 펑크 수리 시 특
   수장비가 필요한 경우
ㄷ)타이어의 측면에 구멍이 뚫린 경우
서비스 종류
보상내용
1일 한도
1) 긴급견인
㉮피보험자동차가 사고 또는 고장으로 인해 자력으로 운행할 수 없어 
  수리를 위해 긴급견인이 필요할 경우, 60km를 한도로 가까운 정비
  공장까지 견인하여 드립니다. 
㉯위 ‘㉮’의 긴급견인 시 60km를 초과하는 거리에 대해 발생한 비용
  은 피보험자가 부담 합니다. 또한, 피보험자동차의 길이 또는 중량
  이 견인한도를 초과하거나, 적재물 또는 구조변경 등으로 인하여 
  서비스 제공에 제한이 생길 경우에는 서비스를 제공하지 않습니다.
2. SOS 서비스의 내용
① 회사가 제공하는 SOS 서비스는 다음과 같습니다.
1일 사용제한 
없음
서비스 종류
보상내용
1일 한도
9) 부동액 보충
10) 긴급구난
부동액 부족으로 피보험자동차를 운행할 수 없는 경우에는 부동액을 
보충하여 드립니다. 
다만, 긴급출동 시 보유한 제품과 규격이 상이한 경우, 서비스가 제한
될 수 있습니다.
㉮피보험자동차가 도로를 이탈하거나 장애물로 인하여 자력으로 운
  행을 할 수 없는 경우에는 별도의 구난장비 없이 출동한 자동차로 
  구난 가능한 경우에만 피보험자동차를 구난하여 드립니다. 다만, 
  특수한 구난을 한 경우(*1)에는 피보험자가 추가비용을 부담합니다.
㉯위 ‘㉮’의 긴급구난 시 차량의 적재물로 인하여 서비스의 제공이 힘
  든 경우에는 서비스를 제공하지 않습니다.
(*1)‘특수한 구난을 한 경우’는 다음과 같습니다. 
   (1) 2.5t을 초과하는 구난형 특수자동차로 구난한 경우 
   (2) 2대 이상의 구난형 특수자동차가 구난한 경우 
   (3) 구난작업을 시작하여 견인고리 연결직전까지 걸린 시간
     이 30분을 초과한 경우 
   (4) 2,500cc 이상의 “국산차량 및 외제차량”을 구난한 경우
7) 브레이크/
파워오일 보충
브레이크오일, 파워오일의 부족으로 피보험자동차를 운행할 수 없는 
경우에는 오일 부족분(최대 1리터 한도)을 보충해 드립니다. 
다만, 긴급출동 시 보유한 제품과 규격이 상이한 경우, 서비스가 제한
될 수 있습니다.
8) 휴즈교환
휴즈 합선으로 피보험자동차를 운행할 수 없는 때에는 휴즈를 교환하
여 드립니다.
다만, 긴급출동 시 보유한 제품과 규격이 상이한 경우, 서비스가 제한
될 수 있습니다.
6) 잠금장치 해제
㉮피보험자동차의 열쇠를 분실하는 등 차문을 열 수 없는 경우에 잠
  금장치를 해제하여 드립니다.(트렁크 잠금장치 해제는 제외) 다만, 
  잠금장치를 해제하기 위해 부득이 파손된 부분의 원상복구에 드는 
  비용은 보상하지 않습니다. 
㉯위 ‘㉮’의 잠금장치 해제 시 특수 잠금장치(스마트키, 이모빌라이
     저 등)가 장착되어 있거나 사이드 에어백의 장착 등으로 출동차량
  이 현장에서 잠금장치 해제가 어려운 경우, 서비스를 제공하지 않
  을 수 있습니다.
5) 타이어펑크 수리
ㄹ)그 밖의 현장에서 타이어펑크 수리가 곤란한 경우
㉰이 서비스는 타이어펑크 1개당 서비스 1회를 차감합니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
144
145
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (75, 1, 75, '③ 위 ‘①’에서 규정한 서비스를 제공하기 위하여 긴급출동하였으나 현장 조치만으로 피보험자동차가 자력운행하
  기 어려워 긴급견인을 할 경우에는 위 ‘①의 1)’과 같은 기준으로 서비스를 제공하여 드립니다.
④피보험자에게 책임이 없는 사유로 위 ‘①’의 서비스를 제공받지 못하여 피보험자가 개인적으로 부담한 금액이 
  있는 경우에는 회사가 통상적으로 부담하는 해당 SOS서비스 비용에 상응하는 금액 내에서 피보험자가 부담한 
  금액을 지급합니다.
3. 피보험자
이 특별약관에서 피보험자란 보험증권에 기재된 피보험자를 말합니다.
4. 보상하지 않는 손해
① 회사는 서비스의 요청지가 다음에 해당할 경우 SOS서비스를 제공하지 않습니다.
1) 견인차가 접근하기 어려운 지역
2) 섬(제주도 및 연륙교로 연결된 섬 제외) 또는 산간 지역
3) 통신교환이 원활하지 못하여 회사가 서비스 제공이 불가능하다고 판단되는 지역
② 회사는 SOS서비스의 지연 또는 미제공으로 인하여 발생한 간접손해는 보상하지 않습니다.
5. 서비스 제공의 제한
피보험자가 이 보험계약 가입 후 위 ‘2.의 ①’의 SOS서비스를 6회(보험기간이 1년 미만인 경우는 3회) 받았을 경
우에 그 시점부터 ‘2.의 ①’의 서비스는 제공하지 않습니다. 
6. 특약보험료의 환급
보험계약자 또는 피보험자에게 책임이 있는 사유로 보험계약이 해지된 때에는 회사가‘2.의 ①또는 ②’의 서비스를 
② Auto Care 서비스
3) 수리차량 운반
횟수제한 없음
㉮피보험자가 피보험자동차를 회사가 지정하는 정비업체에서 수리 
  할 경우, 그 작업시간이 1시간이상 걸릴 때에만 수리 후 피보험자
  가 지정하는 장소로 피보험자동차를 운반해 드립니다. 
㉯위 ‘㉮’에도 불구하고, 배터리, 라이닝, 타이어, 워셔액, 부동액, 각
  종오일 등과 같은 단순소모품만의 교체 또는 보충은 수리로 보지 
  않으며, 운반거리가 10km를 초과하는 경우에는 초과 1km당 
  2,000원의 추가비용을 피보험자가 부담합니다.
4) 차량등록대행 
예약
피보험자가 피보험자동차의 신규, 이전, 말소등록을 해야 하는 경우 피
보험자의 요청에 의해 등록대행을 전문업체에 예약하여 드립니다. 
5) 차량검사대행 
예약
피보험자가 피보험자동차의 정기검사를 받아야 하는 경우 피보험자의 
요청에 의해 검사대행을 전문업체에 예약하여 드립니다. 
2) 차량 실내 
살균/탈취
피보험자가 회사가 지정하는 서비스 제공이 가능한 정비업체에 방문하
여 피보험자동차의 차량 실내 살균, 탈취서비스를 요청하는 경우 서비
스를 제공받을 수 있습니다. 
내 
탈취
탈취
탈취
탈취
서비스 종류
보상내용
1일 한도
보험기간 중 
1회만 가능
㉮피보험자가 회사가 지정하는 정비업체에 방문하여 피보험자동차
  의 차량진단을 의뢰하는 경우, <별표>에 기재된 25가지 항목을 점
  검하고 결과표를 제공받을 수 있습니다. 
㉯위 ‘㉮’의 점검 시, 자동차 고장진단용 스캐너 장비를 사용하여 차
  량의 각종 센서류의 이상 유무를 점검받으실 수 있습니다(단, 외산
  차 및 자동차제조사의 진단코드 미제공 등으로 인해 제공 불가능한 
  차량종류는 제외)  
1) 차량점검
제공하지 않은 경우에만 이미 받은 보험료에서 경과한 기간에 대하여 단기요율(보통약관 제1조 제2호)로 계산한 
특약보험료를 공제한 나머지를 돌려 드립니다.
7. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
3⃞  전기자동차 SOS 서비스 특별약관
1. 가입대상 등
이 특별약관은 피보험자동차가 법정승차정원 10인승 이하의 전기자동차(*1)인 경우에 가입가능하며, 가입시 보험
회사(이하 “회사”라 함)는 피보험자가 보험증권에 기재된 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 긴급출동
서비스 등을 요청할 때에는 이 특별약관에 따라 해당하는 서비스(이하 ‘SOS 서비스’라 함)를 제공합니다. 
(*1)‘전기자동차’란 사용연료의 종류가 전기인 자동차로서 「환경친화적자동차의 개발 및 보급촉진에 관한 법률」 
   제2조 제3호 및 제6호에 해당하는 자동차를 말합니다.(제2조 제4호 태양광자동차 및 제2조 제5호 하이브리
   드 자동차는 제외)
2. SOS 서비스의 내용
① 회사가 제공하는 SOS  서비스는 다음과 같습니다.
점검 항목
세부 점검 항목
전기/전자 콘트롤류
오일 및 냉각수 점검
벨트류
구동계통
스타트 모터, 배터리, 헤드램프(안개등), 실내등, 브레이크등, 컴비네이션 스위치, 
알터네이터
엔진오일, 브레이크오일, 부동액(냉각수), 라지에이터 호스, 워셔액
팬벨트(에어컨벨트 포함)
오토미션오일(자동변속기) 또는 클러치 및 클러치실린더(수동변속기)
<별표〉 차량점검서비스 항목
바디 및 외장
각종 센서류
와이퍼블레이드, 사이드 미러 작동
자동차 고장진단용 스캐너 점검 (단, 외산차 및 자동차제조사의 진단코드 미제공 등으
로 인해 제공불가능한 차량종류의 경우 제외)
조향 및 현가 계통
제동(브레이크) 계통
실내장치류
파워스티어링(전동 및 유압식), 타이어 공기압(예비타이어 포함), 타이어 편마모
브레이크 패드, 주차 브레이크
에어컨(에어컨필터 포함), 히터, 경음기
보험회사는 이 추가특별약관에 따라 프로미카 오토케어서비스 특별약관 ‘2.의 ①, 6)’의 잠금장치 해제를 제공하지 
않습니다.
䣨-①  잠금장치 해제 서비스 제외 추가특별약관
서비스 종류
보상내용
1일 한도
1) 긴급견인
1일 1회만 제
공(초과 시 
피보험자 부담)
㉮피보험자동차가 사고 또는 고장, 구동 배터리(*1) 방전으로 인해 자
  력으로 운행할 수 없어 수리 또는 충전을 위해 긴급견인이 필요할 
  경우, 보험증권에 기재된 거리를 한도로 가까운 정비공장 또는 가
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
146
147
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (76, 1, 76, '  까운 전기자동차 충전소까지 견인하여 드립니다. 
서비스 종류
보상내용
1일 한도
1) 긴급견인
1일 1회만 제공
(초과 시 
피보험자 부담)
㉯보조(시동)배터리의 방전으로 피보험자동차를 운행할 수 없는 경
  우에 차량이 운행이 가능하도록 조치하여 드립니다. 다만, 보조(시
  동)배터리 교환 시는 보조(시동)배터리 실비는 피보험자가 부담합
  니다. 
㉰ 위 ‘㉮’의 긴급견인 시 보험증권에 기재된 거리를 초과하는 거리에 
  대해 발생한 비용 및 전기자동차 충전에 소요되는 비용은 피보험자
  가 부담 합니다. 또한, 피보험자동차의 길이 또는 중량이 견인한도
  를 초과하거나, 적재물 또는 구조변경 등으로 인하여 서비스 제공
  에 제한이 생길 경우에는 서비스를 제공하지 않습니다.
1일 사용제한 
없음
2) 타이어교체
㉮타이어의 펑크로 인하여 운행을 할 수 없는 경우, 고장 난 타이어를 
  피보험자동차에 내장되어 있는 예비타이어로 교체하여 드립니다. 
  다만, 휠(Wheel)을 개조한 차량의 경우 피보험자가 휠을 교체할 
  수 있는 장비를 지닌 경우에만 교체서비스가 가능합니다.
㉯ 위 ‘㉮’의 타이어교체 시 차량의 적재물 또는 구조변경 등으로 인하
  여 서비스의 제공에 제한이 생길 경우에는 서비스를 제공하지 않습
  니다.
3) 타이어펑크 수리
㉮지면에 닿은 타이어트레드 부분(접지면)에 날카로운 물체에 의해 
  구멍이 뚫린 단순펑크로 인하여 피보험자동차의 운행이 불가능한 
  경우, 타이어펑크를 수리하여 드립니다. 다만, 자연 마모로 인한 펑
  크 또는 타이어가 찢어진 경우에는 이 서비스를 제공하지 않습니
  다.
㉯ 위 ‘㉮’의 타이어펑크 수리 시 다음과 같이 수리가 어려운 경우에는 
  위 ‘1)’ 또는 ‘2)’의 서비스를 제공해 드립니다.
ㄱ)야간, 눈 또는 비가 내리는 경우 등 펑크 위치를 육안으로 확인하
   기 어려운 경우
ㄴ)런플랫(Run-flat)형, 튜브형 타이어 등과 같이 펑크 수리 시 특
   수장비가 필요한 경우
ㄷ)타이어의 측면에 구멍이 뚫린 경우
ㄹ)그 밖의 현장에서 타이어펑크 수리가 곤란한 경우
㉰ 이 서비스는 타이어펑크 1개당 서비스 1회를 차감합니다.
4) 잠금장치 해제
㉮ 피보험자동차의 열쇠를 분실하는 등 차문을 열 수 없는 경우에 잠
  금장치를 해제하여 드립니다.(트렁크 잠금장치 해제는 제외) 다만, 
  잠금장치를 해제하기 위해 부득이 파손된 부분의 원상복구에 드는 
  비용은 보상하지 않습니다. 
㉯ 위 ‘㉮’의 잠금장치 해제 시 특수 잠금장치(스마트키, 이모빌라이
  저 등)가 장착되어 있거나 사이드 에어백의 장착 등으로 출동차량
  이 현장에서 잠금장치 해제가 어려운 경우, 서비스를 제공하지 않
(*1)‘구동 배터리’란 전기자동차에 장착되어 구동모터에 전기를 
   공급해주는 배터리를 말합니다. (전기자동차에 장착된 보조
   (시동)배터리 제외)  
② 위 ‘①’에서 규정한 서비스를 제공하기 위하여 긴급출동하였으나 현장 조치만으로 피보험자동차가 자력운행하
  기 어려워 긴급견인을 할 경우에는 위 ‘①의 1)’과 같은 기준으로 서비스를 제공하여 드립니다.
③ 피보험자에게 책임이 없는 사유로 위 ‘①’의 서비스를 제공받지 못하여 피보험자가 개인적으로 부담한 금액이 
  있는 경우에는 회사가 통상적으로 부담하는 해당 SOS서비스 비용에 상응하는 금액 내에서 피보험자가 부담한 
  금액을 지급합니다. 
3. 피보험자
이 특별약관에서 피보험자란 보험증권에 기재된 피보험자를 말합니다.
4. 보상하지 않는 손해
① 회사는 서비스의 요청지가 다음에 해당할 경우 SOS서비스를 제공하지 않습니다.
1) 견인차가 접근하기 어려운 지역
2) 섬(제주도 및 연륙교로 연결된 섬 제외) 또는 산간 지역
3) 통신교환이 원활하지 못하여 회사가 서비스 제공이 불가능하다고 판단되는 지역
② 회사는 SOS서비스의 지연 또는 미제공으로 인하여 발생한 간접손해는 보상하지 않습니다.
5. 특약의 자동종료
이 특별약관은 피보험자가 이 보험계약 가입 후 SOS 서비스를 6회이상(보험기간이 1년 미만인 경우는 3회 이상) 
받았을 때에는 그 시점부터 자동으로 끝납니다. 
6. 특약보험료의 환급
보험계약자 또는 피보험자에게 책임이 있는 사유로 보험계약이 해지된 때에는 회사가 ‘2.의 ①’의 서비스를 제공하
지 않은 경우에만 이미 받은 보험료에서 경과한 기간에 대하여 단기요율(보통약관 제1조 제2호)로 계산한 특약보
험료를 공제한 나머지를 돌려 드립니다.
7. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
5) 브레이크 오일 
보충
브레이크오일의 부족으로 피보험자동차를 운행할 수 없는 경우에는 오
일 부족분(최대 1리터 한도)을 보충해 드립니다.
다만, 긴급출동 시 보유한 제품과 규격이 상이한 경우, 서비스가 제한
될 수 있습니다.
을 수 있습니다.
㉮ 피보험자동차가 도로를 이탈하거나 장애물로 인하여 자력으로 운
  행을 할 수 없는 경우에는 별도의 구난장비 없이 출동한 자동차로 
  구난 가능한 경우에만 피보험자동차를 구난하여 드립니다. 다만, 
  특수한 구난을 한 경우(*1)에는 피보험자가 추가비용을 부담합니
  다.
㉯ 위 ‘㉮’의 긴급구난 시 차량의 적재물로 인하여 서비스의 제공이 힘
  든 경우에는 서비스를 제공하지 않습니다.
서비스 종류
보상내용
1일 한도
(*1)‘특수한 구난을 한 경우’는 다음과 같습니다. 
   (1) 2.5t을 초과하는 구난형 특수자동차로 구난한 경우 
   (2) 2대 이상의 구난형 특수자동차가 구난한 경우 
   (3) 구난작업을 시작하여 견인고리 연결직전까지 걸린 시간
     이 30분을 초과한 경우 
   (4) 2,500cc 이상의 “국산차량 및 외제차량”을 구난한 경우
1일 사용제한 
없음
6) 긴급구난
4) 잠금장치 해제
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
148
149
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (77, 1, 77, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
Ⅶ. 보험료 납입
1. 보험료 분할납입 
보험회사(이하 “회사”라 함)는 이 특별약관에 따라 보험계약자가 보험료(이 보험계약의 보험기간에 해당하는 보험
료 전액을 말합니다. 이하 같음)를 보험증권에 기재된 횟수 및 금액(이하 “분할보험료”라 함)으로 분할하여 납입하
게 할 수 있습니다. 그러나, 대인배상Ⅰ 및 대물배상(또는 대물배상 가입금액 확장담보 특별약관)은 이 특별약관이 
적용되지 않으므로, 보험료를 분할하여 납입할 수 없습니다. 
2. 분할보험료의 납입방법
보험계약자는 이 보험계약을 맺으면서 제1회 분할보험료를 납입하고 제2회 이후의 분할보험료부터는 약정한 납입
일자 안에 납입해야 합니다.
3. 분할보험료의 납입최고지식97)
① 보험계약자가 약정한 납입일자까지 제2회 이후의 분할보험료를 납입하지 않는 때에는 약정한 납입일자가 속하
  는 달의 다음 달 말일까지 납입최고기간을 둡니다. 회사는 이 납입최고기간 안에 생긴 사고는 보상합니다.
②  위 ‘①’의 납입최고기간 안에 분할보험료를 납입하지 않는 때에는 납입최고기간이 끝나는 날의 24시부터 보험
  계약은 해지됩니다.
③  보험계약자가 약정한 납입일자까지 분할보험료를 납입하지 않은 경우, 회사는 보험계약자 및 기명피보험자에
  게 납입최고기간이 끝나는 날 이전에 위 ‘①, ②’의 내용을 서면으로 최고합니다. 이때 보험계약자 또는 피보험
  자가 보통약관 제45조(계약 후 알릴 의무)에 따라 주소변경을 통보하는 경우가 아니라면, 보험증권에 기재된 
  보험계약자 또는 기명피보험자의 주소를 회사의 의사표시를 받을 지정장소로 합니다.
4. 보험료의 환급
위 ‘3.의 ②’에 따라 보험계약을 해지한 때에는 회사가 보상해야 할 사고가 생기지 않은 경우에만 이미 받은 보험료
에서 해지한 날까지 경과한 기간에 대하여 단기요율(보통약관 제1조 제2호)로 계산한 보험료를 공제한 나머지를 
돌려드립니다.
5. 보험계약의 부활
①  위 ‘3.의 ②’에 따라 보험계약이 해지되고 해약환급금이 지급되지 않은 경우, 보험계약이 해지된 후 30일안에 
  보험계약자가 보험계약의 부활을 청구하고 해당 분할보험료를 납입한 때에는 이 보험계약은 유효하게 계속됩
  니다.
1⃞  보험료 분할납입 특별약관
※  이 특약들을 가입함으로써 보험료의 납입 방법과 결제수단 등을 자유롭게 선택하실 수 있습니다.
97) “최고(催告)”란 상대방에게 일정한 행위를 할 것을 요구하는 법률상 통지입니다. 따라서, “납입최고”란 보험계약자 등이 
   분할보험료를 내지 않은 경우에 회사가 그 미납보험료를 낼 것을 독촉하는 법률상 행위를 말하며, 이 때 보험계약자에게 
   주어지는 납입기간을 “납입최고기간”이라고 합니다. 
보험회사는 이 추가특별약관에 따라 전기자동차 SOS서비스 특별약관 ‘2.의 ①, 4)’의 잠금장치해제를 제공하지 않
습니다.
3⃞-①  잠금장치 해제 서비스 제외 추가특별약관
②  위 ‘①’의 경우, 회사는 보험계약이 해지된 때부터 해당 분할보험료를 받은 날의 24시까지 생긴 사고는 보상하
  지 않습니다.
6. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
98) <예시>  연속 6회납, 약정이체일은 20XX. 7. 25일, 4회 보험료를 내지 않은 경우 납입유예기간은?
   - <별표>에 따른 가산기간 : “2개월” 
   - 납입유예기간 : 20XX. 7. 25일 + 2개월이 속한 달의 말일 = 20XX. 9. 30일
1. 적용대상 
이 특별약관은 보험계약자가 이 보험계약의 보험료를 자동이체로 납입할 것을 약정한 경우 적용됩니다(단, 자동이
체는 계약자 또는 기명피보험자의 지정계좌만 해당함) 
2. 보험료 자동납입
① 보험계약자가 보험료를 분할납입할 때는 이 특별약관에 따라 보험증권에 기재된 횟수 및 금액에 따라 자동이체
  로 분할납입합니다. 그러나, 대인배상Ⅰ 및 대물배상(또는 대물배상 가입금액 확장담보 특별약관)은 이 특별약
  관이 적용되지 않으므로, 보험료를 자동이체로 분할납입할 수 없습니다. 
②  자동이체 납입일은 보험증권에 기재된 이체일자(이하 “약정이체일” 이라 함)로 합니다.
③  위 ‘②’의 약정이체일은 보험청약서 상에 열거된 이체가능일자 중에서 보험료 납입기일 이후에 최초로 도래하는 
  이체일자를 말합니다. 다만, 초회보험료를 자동이체로 내는 경우, 초회보험료 약정이체일은 보험회사(이하 ‘회
  사’라 함)와 보험계약자가 별도로 약정한 책임개시일자의 이전의 이체일자를 말합니다.
④  지정은행계좌의 이체가능 금액이 회사가 청구한 보험료에 미치지 못할 경우에는 보험료가 자동이체될 수 없습
  니다.
3. 분할보험료의 납입유예 및 납입최고
①  회사는 분할보험료를 약정이체일에 받지 못한 경우, 약정이체일부터 약정이체일에 〈별표〉의 기간을 더한 날이 
  속하는 달의 말일까지 납입유예기간을 둡니다.지식98) 다만, 11회 분할납입의 11회 분할보험료를 약정이체일에 
  받지 못한 경우에는 약정이체일부터 1개월만을 납입유예기간으로 합니다.
② 회사는 위 ‘①’의 납입유예기간 안에 생긴 사고를 보상합니다. 다만, 초회보험료는 납입유예기간이 없으며, 책임
  개시일자 이전까지 회사가 초회보험료를 받지 못한 경우, 보험계약의 효력이 발생하지 않습니다.
③  회사는 약정이체일에 분할보험료를 자동이체로 받지 못한 경우, 분할보험료 납입유예기간 중에는 계속하여 이
  체청구를 할 수 있습니다.
④  회사는 위 ‘①’의 납입유예기간이 끝나는 날의 10일전까지 보험계약자에게 납입최고를 합니다.
⑤ 납입유예기간 말일까지 분할보험료가 납입되지 않을 경우에는 납입유예기간 말일의 24시부터 보험계약은 해
  지됩니다.
4. 계약 후 알릴 의무
보험계약자 또는 기명피보험자는 지정은행계좌의 번호가 변경되거나 거래 정지된 경우에는 그 사실을 지체 없이 
회사에 알려야 합니다.
5. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
2⃞  보험료 자동납입 특별약관
150
151
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (78, 1, 78, '1. 보상내용 
보험회사(이하 “회사”라 함)는 신용카드회사(이하 “카드회사”라 함)의 카드회원을 보험계약자 및 피보험자로 하
며, 신용카드를 이용하여 보험계약을 체결하고 보험사고가 발생했을 경우 이로 인한 손해를 보상하여 드립니다. 
2. 보험료의 영수
회사는 신용카드 이용 보험료납입 특별약관(이하 “특별약관”이라 합니다)에 따라 보험계약자 또는 피보험자가 신
용카드로 보험료를 결제하고 카드회사의 승인을 받은 때를 보험료를 받은 때로 봅니다.
3. 사고카드 계약
①  사고카드로 보험계약을 체결했을 때는 보험자의 책임개시일부터 효력을 상실합니다.
②  위 ‘①’의 사고카드는 유효기간이 경과한 카드, 위조䞱변조된 카드, 무효 또는 거래정지를 받은 카드, 카드에 기재
  되어 있는 회원과 이용자가 서로 다른 카드 등을 말합니다.
4. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 
3⃞  신용카드 이용 보험료납입 특별약관
미납입 보험료
납입방법
2회
보험료
3회
보험료
4회
보험료
5회
보험료
6회
보험료
7회
보험료
8회
보험료
9회
보험료
10회
보험료
11회
보험료
〈별표〉 제2회 이후의 분할보험료 납입유예기간 계산 시 가산기간
4개월
2개월
1개월
1개월
1개월
1개월
1개월
4개월
3개월
2개월
1개월
1개월
1개월
4개월
3개월
2개월
1개월
1개월
4개월
2개월
1개월
1개월
1개월
3개월
1개월
1개월
1개월
1개월
1개월
1개월
1개월
1개월
1개월
1개월
비연속 2회납
2회납
3회납
4회납
5회납
6회납
10회납
11회납
연
속
납
(주) 1.  비연속 2회납의 가산기간 1개월은 2회 보험료 납입유예기간 계산 시 가산기간을 말합니다.
   2.  연속11회납의 11회 보험료는 가산기간 없이 약정이체일로부터 1개월간의 납입유예기간을 둡니다.
1. 적용대상 
보험회사(이하 “회사”라 함)는 보험계약자가 회사에 가입하는 보험계약 건수가 월평균 25건 이상이고, 그 보험료
가 500만원 이상이 될 것으로 예상되는 경우로서 보험계약자가 보험료정산특별약정서를 사용하고자 할 경우에는 
이 특별약관을 적용합니다.
2. 보험료의 정산
①  보험계약자가 내는 보험료(분할보험료를 포함)와 회사가 계약자에게 지급할 환급보험료는 보험료정산특별약
  정서에서 정한 바에 따라 서로 간에 정산할 수 있습니다.
②  회사가 보험료정산특별약정이 적용되는 보험계약에 따라 보험금을 지급하는 경우, 해당 보험계약의 보험료가 
  정산되지 않았을 때는 정산기일의 도래여부에 불구하고 그 보험료를 공제한 잔액을 지급합니다.
4⃞  보험료정산약정에 관한 특별약관
Ⅷ. 기타
1. 보상내용 
① 보험회사(이하 “회사”라 함)는 보험증권에 기재된 피보험자동차가 유상으로 운송용에 제공하는 경우에는 이 
  특별약관에 따라 보상합니다.  단, 대인배상Ⅰ의 경우 이 특별약관과 상관없이 보상하여 드립니다.　
②  보통약관 제8조 제①항 제6호/제14조 제7호/제19조 제7호/제23조 제5호(이상 “보상하지 않는 손해”)에도 
  불구하고 영리를 목적으로 요금이나 대가를 받고 피보험자동차를 사용한 때 또는 빌려 준 때에 생긴 사고로 인
  한 손해도 보상합니다. 
2. 보상하지 않는 손해
회사는 위 ‘1.의 ②’에도 불구하고 피보험자가 6인승 이하의 피보험자동차를 사용하여 「여객자동차운수사업법」상 
‘여객자동차운송사업’에 해당하는 운송을 하는 중 발생한 사고는 보상하지 않습니다. 다만, 피보험자동차가 구급용 
자동차(앰뷸런스) 또는 장애인 택시로서 유상으로 운송용에 제공하는 경우 발생한 사고는 보상합니다.
3. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1⃞  유상운송 위험담보 특별약관
※  이 특약들을 가입함으로써 특수한 상황에서 사고가 발생할 경우 보장받으실 수 있습니다.
1. 적용대상 
이 특별약관은 보통약관 대인배상Ⅰ 및 대물배상(또는 대물배상 가입금액 확장담보 특별약관, 이하 동일)에 대하
여 자동적으로 적용됩니다.
2. 보험계약자 및 기명피보험자
보험회사(이하 “회사”라 함)는 보통약관 제48조(피보험자동차의 양도)에도 불구하고(단서의 승인이 있는 경우는 
제외)보험증권에 기재된 피보험자동차를 양도한 날부터 15일째 되는 날의 24시까지의 기간 동안은 양도된 그 자
동차를 보통약관 대인배상Ⅰ 및 대물배상의 피보험자동차로 보고 양수인을 보험계약자 및 기명피보험자로 봅니다.
3. 보상내용
①  회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안 생긴 피보험자동차의 사고로 인하여 다른 사람
  을 죽게 하거나 다치게 한 경우와 다른 사람의 재물을 없애거나 훼손하여 법률상 손해배상책임을 짐으로써 입은 
  손해를 보통약관 대인배상Ⅰ 및 대물배상에서 규정하는 바에 따라 보상합니다. 다만, 대물배상의 경우 회사가 
  사고마다 지급하는 보험금은 사고당 자동차손해배상보장법 시행령에서 규정하는 대물배상 의무보험 가입금액
  지식99)을 한도로 합니다.
②  위 ‘①’에도 불구하고 다음의 손해는 보상하지 않습니다.
 1) 양도된 피보험자동차가 양수인 명의로 이전 등록된 이후에 발생한 손해
2⃞  의무보험 일시담보 특별약관
3. 회사의 책임개시
보험료정산특별약정이 적용되는 보험계약은 회사가 보험료를 받기 전이라도 보험증권에 기재된 책임개시일부터 
회사의 책임이 개시됩니다.
4. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
152
153
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (79, 1, 79, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
99) 자동차손해배상보장법 시행령 개정에 따라, 의무보험 가입금액 한도는 사고일자 별로 다음과 같습니다.
   - 2016년 3월 31일까지의 사고는 “1천만원”
   - 2016년 4월 1일 부터의 사고는 “2천만원”
 2) 양도된 피보험자동차에 대하여 양수인 명의로 유효한 대인배상Ⅰ 및 대물배상에 가입한 이후 발생한 손해
 3) 대인배상Ⅰ 및 대물배상 계약 성립 시 설정된 보통약관 제42조(보험기간)에 따른 보험기간의 마지막 날 24
   시 이후에 발생한 손해
 4) 대물배상의 경우, 양도인의 보험증권에 기재된 운전가능범위 또는 연령 외의 자가 피보험자동차를 운전하던 
   중 생긴 사고로 인한 손해
③  위 ‘①’에 따라 회사가 보상한 경우에는 자동차보험요율서에서 정한 불량할증을 양수인에게 적용합니다.
4. 보험료의 청구 및 납입
①  회사는 위 ‘3.’에 의해 회사가 보상책임을 지는 기간에 대하여 단기요율로 계산한 해당 보험료를 양수인에게 청
  구할 수 있습니다.
②  양수인은 ‘①’에 따라 보험료의 납입을 청구 받은 때에는 지체 없이 보험료를 회사에 납입해야 합니다.
5. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 보상내용
보험회사는 이 특별약관에 따라 보통약관 제8조 제①항 제9호/제14조 제3호/제19조 제8호/제23조 제11호(이상 
“보상하지 않는 손해”)에도 불구하고 피보험자가 피보험자동차를 시험용으로 사용한 때에 생긴 보통약관 대인배
상ⅠㆍⅡ, 대물배상, 자기신체사고, 무보험자동차에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차상해 
Family 통합보장 특별약관, 차량단독사고 보장 특별약관, 대물배상 가입금액 확장담보 특별약관을 보상합니다. 다
만, 보통약관의 해당 보장종목 및 특별약관을 가입하지 않은 경우에는 보상하지 않습니다.
2. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
4⃞  시험용 자동차 위험담보 특별약관
보험회사는 이 특별약관에 따라 보통약관에도 불구하고, 피보험자동차에 장착 또는 장비되어 있는 보험증권에 기
재된 기계장치에 생긴 손해는 보상하지 않습니다. 그러나, 차량과 동시에 입은 손해는 보상합니다.
3⃞  기계장치에 관한 자기차량손해 특별약관
1. 가입대상 등  
이 특별약관은 계약자 또는 피보험자가 이 특별약관 ‘2.’에 해당하는 서류를 제출하고 기명피보험자가 다음 중 하나
에 해당되는 것으로 확인될 경우 가입이 가능합니다. 
5⃞  프로미하트 (서민우대 보험료 할인) 특별약관
※  가입 시 보험계약자는 일정금액의 보험료를 절감할 수 있습니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
1. 가입대상
이 특별약관은 보통약관 자기신체사고, 무보험자동차에 의한 상해, 자기차량손해 및 자동차상해 특별약관, 자동차
상해 Family 통합보장 특별약관 중 어느 하나를 가입한 경우에 가입할 수 있습니다.
2. 지정대리청구인 지정
①  계약자는 ‘기명피보험자 또는 기명피보험자 이외에 보험증권에 기재된 피보험자’(이하 ‘피보험자’라 함)가 동
  의하는 경우, 이 특별약관에 따라 해당 피보험자의 지정대리청구인을 지정할 수 있습니다.
6⃞  지정대리청구에 관한 특별약관
2. 특별약관 계약 전 제출서류  
보험계약자 또는 피보험자는 계약체결 시 위 ‘1.’의 해당 여부 확인을 위해 다음 중 필요한 서류를 보험회사에 제출
해야 합니다.
 1)  국민기초생활수급자 증명서
 2)  가족관계증명서 또는 주민등록등본 등 가족관계, 부양자 및 동거 여부 확인을 위해 필요한 서류
 3)  근로소득원천징수영수증, 소득금액증명원 등 소득확인을 위해 필요한 서류. 단, 보험회사는 기명피보험자가 
   만 65세 이상인 경우에는 소득을 증명하는 서류의 제출을 생략할 수 있습니다.
 4) 기명피보험자(또는 기명피보험자의 동거가족)의 장애인 증명서 또는 장애인 등록증(장애인 복지카드). 단, 
   보험회사가 인정하는 경우 해당 증명서류의 제출을 생략할 수 있습니다.
 5)  장애인 운송용 휠체어 리프트나 슬로프가 설치되어 출고되거나 구조 변경된 차량인 사실을 확인할 수 있는 자
   동차등록증
 6)  그 밖에 보험회사가 필요하다고 인정하는 증명서류
3. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
종류
세부 내용(가입 기준)
1) 기초생활수급자
2) 위 ‘1)’ 외의 가입
 
대상자
국민기초생활보장법에 따른 기초생활보장수급자를 말합니다.
㉮ 주민등록상의 생년월일을 기준으로 만 30세 이상(기명피보험자 및 배우자의 합산
  소득이 연 4,000만원 이하, 만 20세 미만의 부양자녀가 있는 경우)으로서 중고소
  형차(*1) 1대를 소유한 사람
㉯ 주민등록상의 생년월일을 기준으로 만 65세 이상(기명피보험자 및 배우자의 합산
  소득 연 2,000만원 이하)으로서 중고소형차 1대를 소유한 사람
㉰ 장애인복지법에 따른 장애의 정도가 심한 장애인(기존 1~3급) 또는 동거가족(*2) 
  중 장애의 정도가 심한 장애인(기존 1~3급)이 있는 사람으로서 기명피보험자 및 
  배우자의 합산소득이 연 4,000만원 이하이며 최초 신규등록일로부터 5년이 경과
  한 배기량 2,000cc이하 일반승용차 또는 1.5톤 이하 화물자동차 1대를 소유한 사
  람
㉱ 피보험자동차가 장애인 운송용 휠체어리프트나 슬로프가 설치되어 출고되거나 구
  조 변경된 차량인 경우. 단, 기명피보험자 및 배우자의 합산 소득이 연 4,000만원 
  이하인 경우로 한정합니다.
(*1)‘중고소형차’란 차량연식이 최초 차량등록일을 기준으로 5년 이상의 
   1,600cc이하 승용차 또는 1.5톤 이하 화물자동차를 의미합니다.
(*2) ‘동거가족’이란 주민등록지 기준으로 동일 주소에 거주하는 기명피보험자의 
   부모, 배우자 및 자녀를 의미합니다.
154
155
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (80, 1, 80, '② 위 ‘①’의 피보험자에게 보통약관 자기신체사고, 무보험자동차에 의한 상해, 자기차량손해 및 자동차상해 특별
  약관, 자동차상해 Family 통합보장 특별약관, 차량단독사고 보장 특별약관에서 정하는 보험금(사망보험금 제
  외. 이하 같음)을 지급할 사유가 발생하였으나, 피보험자가 보험금을 청구할 수 없는 사정(의식불명상태의 회복
  을 기대할 수 없다는 의사의 소견이 있는 경우 등을 말함)이 있으면서 대리인도 없는 때는 이 특별약관에서 정하
  는 지정대리청구인이 대신하여 보험금을 청구할 수 있습니다.
③  위 ‘②’의 지정대리청구인은 민법 제1000조 및 제1003조185쪽)에서 정한 상속순위에 따라 다음과 같은 순위로 
  정하며, 동일한 순위의 자가 여러 명인 경우에는 동일 순위의 자들로부터 지정(동의)을 받은 1명이 지정대리청
  구인이 됩니다.
 1)  피보험자의 배우자, 직계비속
 2)  피보험자의 배우자, 직계존속
 3)  피보험자의 형제자매
 4)  피보험자의 4촌 이내의 방계혈족
④  동일 순위의 자들의 전원 합의가 없으면 지정대리청구를 할 수 없습니다.
3. 지정대리청구인 취소
계약자는 위 ‘2.의 ①’에 따라 지정대리청구인을 지정한 피보험자의 동의를 받아, 회사가 정한 방법에 따라 해당 피
보험자의 지정대리청구인 지정을 취소할 수 있습니다. 
4. 지정대리청구인의 보험금청구 등
①  지정대리청구인은 보험회사(이하 ‘회사’라 함)가 정하는 방법에 따라 다음의 서류를 제출하고 보험금을 청구해
  야 합니다.
 1)  보험금지급청구서(회사양식)
 2)  피보험자에게 보험금을 청구할 수 없는 사정이 있는 것을 증명하는 서류 (진단서 등)
 3)  지정대리청구인과 피보험자와의 관계를 증명하는 서류 (가족관계증명서 등)
 4)  지정대리청구인의 신분증(주민등록증 또는 운전면허증 등 사진이 부착된 정부기관 발행 신분증)
 5)  동일순서의 지정대리청구권자가 있는 경우, ‘2.의 ③’에서 정한 동일순서의 다른 지정대리청구권자들로부터 
   지정(동의) 받았다는 것을 증명할 수 있는 서류 
 6)  그 밖에 지정대리청구인의 보험금청구에 필요하다고 회사가 요청하는 서류
②  위 ‘①’에 따라 회사가 지정대리청구인에게 보험금을 지급한 경우에는 그 이후 피보험자 등으로부터 보험금청구
  를 받더라도 회사는 해당 보험금을 지급하지 않습니다.
5. 지정대리청구권의 소멸
피보험자가 죽거나 위 ‘3.’에 따라 지정대리청구인 지정을 취소한 경우에는 해당 피보험자의 지정대리청구권은 소
멸합니다. 단, 지정대리청구권이 소멸하기 전에 지정대리청구인이 한 행위의 효력에는 영향을 주지 않습니다.
6. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 가입대상  
①  이 특별약관은 피보험자동차에 차량용 영상기록장치(*1)(이하 “영상기록장치”라 함)를 장착한 경우에만 가입
  할 수 있습니다. 
②  보험회사(이하 “회사”라 함)는 ''보험계약자 또는 피보험자''(이하 “보험계약자 등”이라 함)가 이 특별약관의 가
  입 시점부터 과거 3년 동안 다음에 해당하는 사항이 있을 경우 가입을 제한할 수 있습니다.
 1)  이 특별약관을 가입한 후 ‘4.’에 따라 할인 받은 보험료를 돌려주어야 할 사유가 발생하였으나, 보험료를 돌려
   주지 않은 경우
7⃞  차량용 블랙박스에 관한 특별약관
※  가입 시 보험계약자는 일정금액의 보험료를 절감할 수 있습니다.
8⃞  교통안전교육 실버우대 특별약관
※  가입 시 보험계약자는 일정금액의 보험료를 절감할 수 있습니다. 
1. 가입대상  
이 특별약관은 기명피보험자가 다음에 모두 해당되는 경우 가입 가능합니다.
 1) 주민등록상의 생년월일을 기준으로 만 65세 이상인 경우
2. 계약 전 알릴 의무  
보험계약자 등은 이 특별약관 가입 시 영상기록장치 장착 여부를 확인하기 위해 회사가 요구하는 경우에는 다음 사
항을 회사에 알려야 합니다.
 1)  제조사, 모델명, 제품식별번호 등 영상기록장치에 대한 사항
 2)  피보험자동차에 영상기록장치가 장착된 사진
3. 보험계약자 등의 의무사항  
①  보험계약자 등은 영상기록장치에 영상기록정보가 정상적으로 저장될 수 있도록 영상기록장치를 피보험자동차
  에 항상 고정 장착해 놓고 작동시켜 놓아야 합니다.
②  피보험자동차의 소유, 사용, 관리하는 동안에 생긴 사고로 인해 회사에 보험금을 청구할 경우 회사가 요청할 경
  우에는 사고와 관련된 영상 정보를 요청 받은 때부터 7일 이내에 회사에 제출해야 합니다.
③  보험계약자 등은 피보험자동차에 장착된 영상기록장치를 교체할 경우에는 ‘2.’와 위 ‘①’ 의 사항을 이행하여야 
  합니다.
④  보험계약자 등은 보험기간 중 피보험자동차의 영상기록장치가 정상적으로 작동하지 않는 경우, 그 사실을 회사
  에 알려야 합니다. 이 경우 보험계약자 등은 그 사실을 안 날부터 영상기록장치가 정상적으로 작동될 때까지 기
  간 동안 이 특별약관에 따라 할인 받은 보험료를 회사에 돌려주어야 합니다.
4. 계약의 취소 및 무효  
①  이 특별약관 체결 후 위 ‘1.의 ②’에 해당하는 사실을 회사가 알게 된 경우 그 사실을 안 날부터 1개월 이내에 이 
  특별약관을 취소할 수 있습니다.
②  위 ‘3.’을 이행하지 않았을 경우 회사는 이 특별약관을 취소할 수 있습니다.
  다만, 영상기록장치의 고장에 따른 수리 또는 피보험자동차를 소유, 사용, 관리하는 동안에 생긴 사고로 인하여 
  영상기록장치가 파손 또는 훼손된 경우 등 특별한 상황이 인정되는 경우에는 취소하지 않습니다.
③  보험계약자 등이 위 ‘2’의 계약 전 알릴 의무를 알리지 않거나 제출한 정보가 사실과 다른 경우 이 특별약관은 
  무효가 됩니다.
5. 할인보험료의 반환  
①  위 ‘4.’에 따라 이 특별약관이 취소 또는 무효처리 되는 경우 보험계약자 등은 이 특별약관으로 할인 받은 보험
  료를 돌려주어야 합니다.
②  피보험자동차의 사고로 보험금을 지급하는 경우, 회사는 위 ‘①’에 따라 보험계약자 등이 보험회사에 돌려줄 보
  험료를 피보험자에게 지급할 보험금에서 공제하고 지급할 수 있습니다.
6. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
(*1) ‘차량용 영상기록장치(블랙박스)’란 영상기록장치를 통해 영상정보 등을 기록하고 해당정보를 제공할 수 있는 
   장치로 차량에 고정 장착된 전용기기를 말합니다. 다만, 휴대전화 및 태블릿PC 등에 애플리케이션(응용프로
   그램)을 탑재하여 사용되는 차량용 영상기록장치는 해당되지 않습니다.
 2)  이 특별약관 가입 시 회사가 블랙박스의 장착을 확인하기 위해 이 특별약관의 ‘2.’에서 요청한 사항을 제출하
   지 않거나, 허위 또는 조작하여 고지하는 경우
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
156
157
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (81, 1, 81, '1. 가입대상  
이 특별약관은 대물배상 가입금액 확장담보 특별약관을 가입한 경우에만 가입 가능합니다.
2. 보상내용  
①  보험회사(이하 ‘회사’라 함)는 대물배상 가입금액 확장담보 특별약관에서 보험금이 지급되는 사고로 인해 외제
  차(*1)에 법률상 손해배상책임이 생긴 때에는 그 외제차의 손해배상에 한정하여, 대물배상 가입금액 확장담보 
  특별약관 가입금액에도 불구하고, <별표>의 사고유형별 보험금 지급기준에 따라 보상하여 드립니다.
9⃞  외제차 충돌 시 대물 보장확대 특별약관
②  위 ‘①’에도 불구하고, 사고당 대물배상 가입금액 확장담보 특별약관 보험금과 이 특별약관 보험금의 합계는 보
  험증권에 기재된 이 특별약관의 가입금액을 초과할 수 없습니다.
사고유형 (피해물)
보험금 지급기준
외제차 단일사고(*2)
외제차 복합사고
외제차의 손해를 이 특별약관 가입금액을 한도로 확대하여 보상
대물배상 가입금액 확장담보 특별약관 가입금액 한도 내에서 우선적으로 외제차가 
아닌 피해물에 대해 보험금을 지급하고, 외제차의 손해를 이 특별약관 가입금액을 
한도로 확대하여 보상
<별표> 사고유형별 보험금 지급기준
(*1) ‘외제차’란 외국 자동차 제조회사에 의해 대한민국이 아닌 곳에서 제조되어 수입, 판매되는 자동차로서 자동차
   관리법 제2조190쪽)에 의한 자동차를 말하며, 다음의 자동차는 제외합니다.
 2) 부부운전자 한정운전 특별약관 또는 기명피보험자 1인 한정운전 특별약관에 가입한 경우
 3)  고령운전자 교통안전교육(*1)을 이수하고 교육 이수를 확인할 수 있는 서류와 ‘인지능력 자가진단’ 결과지의 
   ‘운전능력검사결과표’ 종합판정이 1~3등급인 경우. 단, 고령운전자 교통안전 권장교육 확인증의 교육 이수일
   자로부터 보험증권에 기재된 보험기간 첫 날까지의 기간이 3년 이내인 경우에만 인정됩니다. (온라인으로 실
   시되는 고령운전자 교통안전교육은 ‘인지능력 자가진단 결과’가 「수료」등급인 경우에도 가입이 가능합니다.)
(*1) ‘고령운전자 교통안전교육’이란 도로교통공단에서 시행하는 도로교통안전에 대한 교육으로서 인지능력 자가
   진단이 포함된 교육과정을 말합니다.
2. 특별약관 가입 전 제출서류  
보험계약자 또는 피보험자는 계약체결 시 위 ‘1.’의 해당 여부 확인을 위해 교통안전교육 수료증 등 ‘1.의 3)’에 해
당하는 사실을 증명할 수 있는 서류를 보험회사에 제출해야 합니다. 
3. 특별약관의 적용기간  
①  이 특별약관의 적용 시기는 다음의 기준을 따릅니다.
 1) 인지능력 자가진단 평가일이 보험증권에 기재된 보험기간(이하 ‘보험기간’ 같음)의 첫날 이전인 경우에는 보
     험기간 첫날부터 적용
 2) 인지능력 자가진단 평가일이 보험기간의 첫날 이후인 경우에는 인지능력 자가진단 평가일부터 적용
②  이 특별약관의 적용이 끝나는 시점은 보험기간의 마지막 날과 동일합니다.
4. 보험료의 할인  
이 특별약관에 의한 보험료 할인은 위 ‘3.’에 의한 특별약관의 적용기간에 해당하는 적용보험료에 회사가 별도로 정
한 할인율을 적용하여 산정합니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 가입대상  
이 특별약관은 기명피보험자가 ‘만 11세 이하의 자녀’(*1)가 있는 경우에 한정하여 가입할 수 있습니다. (단, 지정운
※  가입 시 보험계약자는 일정금액의 보험료를 절감할 수 있습니다.
[12]  Baby in Car(만11세 이하 자녀할인) 특별약관
3. 피보험자  
이 특별약관에서의 피보험자는 보통약관 제7조(피보험자)에서 열거하는 사람을 말합니다.
4. 보상하지 않는 손해  
회사는 보통약관 제8조(보상하지 않는 손해) 제①항 및 제③항에서 정하는 사항은 보상하지 않고, 또한 다음과 같
은 손해도 보상하지 않습니다. 
 1)  보험증권에 기재된 운전가능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해
 2)  외제차가 아닌 피해물에 발생한 손해
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
보험회사는 이 특별약관에 따라 보통약관 제42조에도 불구하고, 피보험자동차가 ‘일시수출입하는 차량통관에 관
한 고시’(관세청 고시) 제12조에 따라 보험에 가입해야 하는 차량에 해당하는 경우 보험기간을 보험료를 받은 때부
터 마지막날 24시까지로 합니다.
[10]  일시수입 차량에 관한 특별약관
1. 대물배상의 적용대체 등  
이 특별약관은 보통약관의 대물배상과 중복하여 가입할 수 없으며, 이 특별약관 가입 시 보통약관 대물배상을 이 특
별약관으로 대체하여 적용합니다.
2. 보상내용 및 보상하지 않는 손해  
이 특별약관의 보상내용 및 보상하지 않는 손해는 보통약관 대물배상의 보상내용 및 보상하지 않는 손해 내용을 준
용합니다.
3. 가입금액의 선택  
이 특별약관에 따라 보험계약자 및 피보험자는 보험회사(이하 ‘회사’라 함)가 정하는 바에 따른 대물배상 가입금액
을 선택할 수 있습니다.
4. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
[11]  대물배상 가입금액 확장담보 특별약관
   (1) 외국에 본점 소재지를 둔 외국 자동차 제조회사(해당 회사의 대한민국 내 자회사, 법인 포함)가 대한민국 
     내에서 제조(또는 조립) 완료한 자동차
   (2) 국내에 본점 소재지를 둔 국내 자동차제조회사(해당 회사의 외국소재 자회사, 법인 포함)가 대한민국이 아
     닌 곳에서 제조(또는 조립) 완료한 자동차
   (3) 위 ‘(1)’의 외국 자동차 제조회사와 ‘(2)’의 국내 자동차제조회사가 기술제휴(공동설계, 공동판매)하여 제
     조 (또는 조립)한 자동차
(*2) ‘외제차단일사고’란 하나의 대물사고 내에 외제차만 존재하는 사고를 말하며, ‘외제차복합사고’란 하나의 대물
   사고 내에 외제차와 외제차가 아닌 피해물이 모두 존재하는 사고를 말합니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
158
159
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (82, 1, 82, '전자 1인 한정운전 특별약관을 가입한 경우에는 제외) 
(*1) 이 특별약관에서 ‘만 11세 이하의 자녀’란 다음 중 하나를 말합니다.
   ① 기명피보험자의 법률상 혼인관계 또는 사실혼 관계에서 출생한 자녀, 양자녀 또는 기명피보험자의 법률상 
     혼인관계로 인한 계자녀로서 주민등록상 생년월일을 기준으로 보험기간 시작일 기준 만 11세 이하인 자녀
   ② 기명피보험자 또는 기명피보험자의 배우자의 임신 중 태아(출생 전 자녀)
2. 계약자 및 피보험자의 의무  
① 계약자 및 피보험자(이하 ‘계약자 등’)는 이 특별약관 가입 시 위 ‘1.’의 확인을 위하여 회사가 정한 바에 따르는 
  서류를 제출하는 등 이 특별약관 가입을 위해 회사가 요청하는 사항에 협조해야 합니다.
② 위 ‘①’의 규정에 따르지 않을 경우 특별약관 가입은 승인되지 않을 수 있습니다. 
3. 계약의 취소 및 무효  
① 이 특별약관 가입 시 확인한 사항이 사실과 다르다는 사실을 회사가 알게 된 경우, 회사는 그 사실을 안 날부터 
  1개월 이내에 이 특별약관을 취소할 수 있습니다. 
②  위 ‘①’에 따라 취소가 되는 경우, 계약자 등은 이 특별약관으로 인한 보험료 할인금액을 즉시 회사에 돌려주어
  야 합니다. 피보험자동차의 사고로 보험금을 지급하는 경우, 회사는 위 ‘①’에 따라 계약자 등이 보험회사에 돌
  려줄 보험료를 피보험자에게 지급할 보험금에서 공제하고 지급할 수 있습니다.
4. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
1. 적용대상  
이 특별약관은 보통약관 대인배상Ⅱ, 대물배상(또는 대물배상 가입금액 확장담보 특별약관), 자기신체사고, 자동
차상해 특별약관, 자동차상해 Family 통합보장 특별약관, 자기차량손해, 차량단독사고 보장 특별약관, 무보험자동
차에 의한 상해 가입 시 해당 담보에 한정하여 자동으로 적용됩니다.
2. 보상하는 손해  
① 보험회사(이하 ‘회사’라 함)는 피보험자가 보험대차(*1)를 운전 중(주차 또는 정차 중을 제외합니다. 이하 같습
  니다) 발생한 사고로 인한 손해에 대하여 보험대차를 보통약관 대인배상Ⅱ, 대물배상(또는 대물배상 가입금액 
  확장담보 특별약관), 자기신체사고, 자동차상해 특별약관, 자동차상해 Family 통합보장 특별약관, 자기차량손
  해(또는 차량단독사고 보장 특별약관), 무보험자동차에 의한 상해의 피보험자동차로 간주하여 보통약관 또는 
  해당 특별약관에서 정하는 바에 따라 보상하여 드립니다.
[13]  보험대차 운전 중 사고보상 특별약관
②  회사가 보상할 위 ‘①’의 손해 중 자기차량손해 또는 차량단독사고 보장 특별약관은 피보험자동차의 보험가액과 
  보험대차의 사고가 발생한 곳과 때의 보험대차 가액 중 낮은 가액을 한도로 보상합니다.
③  보통약관 자기차량손해 또는 차량단독사고 보장 특별약관의 규정에도 불구하고 위 ‘①’의 사고로 인한 보험대차
  의 손해에 대하여 보험대차를 사용하지 못하는 기간 동안에 발생한 해당 대여사업자의 타당한 영업손해에 대해
  서는 보통약관 <별표 2> 대물배상 지급기준의 ‘4. 휴차료’ 항목의 지급기준에 따라 보상합니다. 
④  위 ‘③’의 영업손해의 경우 해당 보험대차 대여요금의 50%를 한도로 보상합니다.
⑤  회사가 보상할 위 ‘①’의 손해에 대하여 보험대차에 적용되는 보험계약(공제계약 포함)에 따라 보험금이 지급될 
(*1) 이 특별약관에서 ‘보험대차’라 함은 보험증권에 기재된 피보험자동차의 사고로 인하여 그 피보험자동차가 파
   손 또는 오손되어 가동하지 못하는 기간 동안에 대물배상 지급기준에 따라 다른 자동차를 대차 받은 경우 그 자
   동차를 말합니다. 
  수 있는 경우에는 그 금액을 초과하는 때에 한하여 그 초과액만을 보상합니다. 단, 이 특별약관에 의하여 자기차
  량손해 또는 차량단독사고 보장 특별약관의 보험금이 지급되지 않는 경우에는 ‘③’의 손해는 보상하지 않습니
  다.
⑥  위 ‘①’의 보험대차의 사고는 대여사업자로부터 보험대차를 인수한 때부터 보험대차 인정기간 마지막 날의 24
  시를 한도로 보험대차를 반납할 때까지의 사고만을 보상합니다. 다만, 보험대차 인정기간 만료일이 보험증권에 
  기재된 보험기간 만료일 이후인 경우에는 보험기간 만료일까지의 사고만으로 합니다.
3. 보상하지 않는 손해  
회사는 보통약관 제8조/제14조/제19조/제23조 및 자동차상해 특별약관의 ‘4’, 자동차상해 Family 통합보장 특
별약관의 ‘4’, 차량단독사고 보장 특별약관의 ‘3’에서 정하는 사항(보상하지 않는 손해) 이외에 다음과 같은 손해에 
대하여도 보상하지 않습니다.
① 보험증권에 기재된 운전가능 범위 또는 운전가능 연령 범위 이외의 자가 보험대차를 운전 중 생긴 사고로 인한 
  손해
② 피보험자가 보험대차의 사용에 대하여 정당한 권리를 가지고 있는 자의 승낙을 받지 않고 보험대차를 운전 중 
  생긴 사고로 인한 손해
4. 피보험자  
이 특별약관에서 피보험자란 보험증권에 기재된 운전할 수 있는 범위의 사람을 말합니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
(*1) ‘차선이탈 경고장치’란 피보험자동차가 운전자의 의도와 무관하게 주행하는 차로를 벗어나는 경우 운전자에게 
   경고하는 차선이탈경고장치(LDWS : Lane Departure Warning System)를 말하며,  피보험자동차를 자동
   으로 제어하여 차로를 유지하도록 지원하는 차선유지지원장치(LKAS: Lane Keeping Assist System)를 포
   함합니다. 단, 블랙박스 등 탈부착이 가능한 장치에 해당 기능이 포함된 경우나 최초 출고 이후 사후적으로 장
   착된 경우는 이 특별약관의 차선이탈경고 장치에 해당되지 않습니다. 
2. 계약 전 알릴 의무  
보험계약자 또는 피보험자(이하 “보험계약자 등”이라 함)는 이 특별약관 가입 시 보험회사(이하 “회사”라함)가 요
구하는 경우 피보험자동차에 차선이탈경고장치가 장착되어 있음을 확인할 수 있는 사진 또는 기타 회사가 요구하
는 사항을 회사에 알려야 합니다. 
3. 보험계약자 등의 의무사항   
① 보험계약자 등은 차선이탈 경고장치를 정상적으로 작동시켜야 하며, 운전자에게 안전운전을 위한 경고효과를 
  충분히 발생시킬 수 있도록 경고등, 신호음, 진동의 크기나 주기 등을 유지해야 합니다.  
② 피보험자동차를 소유, 사용, 관리하는 동안에 생긴 사고로 인해 회사에 보험금을 청구할 경우 위 ‘①’의 사항 확
  인을 위해 회사가 요청하는 사항에 대해서 협조해야 합니다.
③  보험계약자 등은 보험기간 중 피보험자동차의 차선이탈 경고장치가 정상적으로 작동하지 않는 경우, 그 사실을 
  회사에 알려야 합니다. 이 경우 보험계약자 등은 그 사실을 안 날부터 차선이탈 경고장치가 정상적으로 작동 될 
  때까지 기간 동안 이 특별약관에 따라 할인 받은 보험료를 회사에 돌려주어야 합니다.
[14]  차선이탈 경고장치에 관한 특별약관
1. 가입대상  
이 특별약관은 최초 출고시 피보험자동차에 차선이탈 경고장치(*1)를 장착한 경우에만 가입할 수 있습니다.
※  가입 시 보험계약자는 일정금액의 보험료를 절감할 수 있습니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
160
161
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (83, 1, 83, '4. 계약의 취소 및 무효   
① 위 ‘3.’을 이행하지 않았을 경우 회사는 이 특별약관을 취소할 수 있습니다.
  다만, 차선이탈경고장치의 고장에 따른 수리 또는 피보험자동차를 소유, 사용, 관리하는 동안에 생긴 사고로 인
  하여 차선이탈경고장치가 파손 또는 훼손된 경우 등 특별한 상황이 인정되는 경우에는 취소하지 않습니다.
②  보험계약자 등이 위 ‘2’의 계약 전 알릴 의무를 알리지 않거나 제출한 정보가 사실과 다른 경우 이 특별약관은 
  무효가 됩니다. 
5. 할인보험료의 반환   
① 위 ‘4.’에 따라 이 특별약관이 취소 또는 무효처리 되는 경우 보험계약자 등은 이 특별약관으로 할인 받은 보험
  료를 돌려주어야 합니다.
②  피보험자동차의 사고로 보험금을 지급하는 경우, 회사는 위 ‘①’에 따라 보험계약자 등이 보험회사에 돌려줄 보
  험료를 피보험자에게 지급할 보험금에서 공제하고 지급할 수 있습니다.
6. 준용규정   
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
3. 피보험자   
이 특별약관에서 피보험자란 기명피보험자를 말합니다. 
4. 보상하지 않는 손해   
회사는 보통약관 제23조 (보상하지 않는 손해)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기재된 운전가
능범위 이외의 자가 운전하던 중 생긴 사고로 인한 손해도 보상하지 않습니다.
5. 보험금의 반환   
① 피보험자가 청구포기 등의 사유로 보통약관 자기차량손해 또는 차량단독사고 보장 특별약관에 따라 지급한 보
  험금 전액을 회사에 돌려줄 경우 이 특별약관에 따라 지급한 금액도 동시에 돌려주어야 합니다.
②  품질인증부품의 하자 등으로 인하여 OEM 부품으로 교환이 필요한 경우에는 이 특별약관 ‘2.’ 에 의하여 지급한 
  금액을 회사에 돌려준 경우에 한하여 OEM 부품으로 재교환이 가능합니다.
6. 적용배제   
회사는 이 특별약관 ‘2.’ 에도 불구하고 다음의 경우에는 이 특별약관을 적용하지 않습니다. 
 1)  품질인증부품을 공급할 수 없거나 공급 지연 등의 사유로 회사가 OEM 부품으로 수리가 필요하다고 판단하는 
   경우
 2)  품질인증부품을 사용하여 지급되는 보험금(이 특별약관에 의하여 지급된 보험금 포함)이 보험가입금액(보험
   가입금액이 보험가액보다 많은 경우에는 보험가액)을 초과하거나, OEM 부품을 사용하여 지급되는 보험금을 
(*1) ‘품질인증부품’이란 「자동차관리법」 제30조의5에   따라 인증된 부품을 말합니다.
(*2) ‘OEM(Original Equipment Manufacturing) 부품’ 이란 자동차 제조사에서 출고된 자동차에 장착된 부품
   을 말하며, ‘OEM 부품 공시가격’ 이란 자동차관리법 제30조의 5 제③항에서 말하는 대체부품인증기관이 공
   시하는 가격을 말합니다.
1. 가입대상  
이 특별약관은 보통약관 자기차량손해에 가입한 경우 적용됩니다.
2. 보상내용  
보험회사(이하 ‘회사’라 함)는 피보험자동차의 단독사고(가해자 불명사고 포함) 또는 일방과실사고로 보통약관 자
기차량손해 또는 차량단독사고 보장 특별약관에 따라서 보험금이 지급되는 경우 이 특별약관에서 정한 품질인증부
품(*1)을 사용하여 수리한 때 OEM 부품 공시가격(*2)의 25%를 피보험자에게 지급하여 드립니다.
[15]  품질인증부품 사용 특별약관
   초과하는 경우
 3) 「자동차관리법」 제30조의 5에 의한  자동차부품 성능ㆍ품질인증기관으로부터 인증 받지 않은 부품으로 피보
   험자동차를 수리한 경우 
7. 준용규정   
이 특별약관에서 정하지 않은 사항은 보통약관에 따릅니다.
(*1) ‘전방충돌 경고장치’란 전방 주행중인 차량과 피보험차량의 거리를 감지하여 운전자에게 위험을 알리는 전방
   충돌경고장치(FCW : Forward Collision Warning)를 말하며, 전방의 보행자 또는 물체를 인식하여 스스로 
   속도를 줄이거나 정지하도록 제동하는 자동비상제동장치(AEB(PED+CCR) : Autonomous Emergency 
   Braking(보행자+후면추돌)와 AEB(CCR) : Autonomous Emergency Braking(후면추돌))를 포함합니다.
   단, 블랙박스 등 탈부착이 가능한 장치에 해당 기능이 포함된 경우나 최초 출고 이후 사후적으로 장착된 경우는 
   이 특별약관의 전방충돌 경고장치에 해당하지 않습니다.
2. 계약 전 알릴 의무  
보험계약자 또는 피보험자(이하 “보험계약자 등”이라 함)는 이 특별약관 가입 시 보험회사(이하 “회사”라함)가 요
구하는 경우 피보험자동차에 전방충돌 경고장치가 장착되어 있음을 확인할 수 있는 사진 또는 기타 회사가 요구하
는 사항을 회사에 알려야 합니다. 
3. 보험계약자 등의 의무사항  
① 보험계약자 등은 전방충돌 경고장치를 정상적으로 작동시켜야 하며, 운전자에게 안전운전을 위한 경고효과를 
  충분히 발생시킬 수 있도록 경고등, 신호음, 진동의 크기나 주기 등을 유지해야 합니다.  
②  피보험자동차를 소유, 사용, 관리하는 동안에 생긴 사고로 인해 회사에 보험금을 청구할 경우 위 ‘①’의 사항 확
  인을 위해 회사가 요청하는 사항에 대해서 협조해야 합니다.
③  보험계약자 등은 보험기간 중 피보험자동차의 전방충돌 경고장치가 정상적으로 작동하지 않는 경우, 그 사실을 
  회사에 알려야 합니다. 이 경우 보험계약자 등은 그 사실을 안 날부터 전방충돌 경고장치가 정상적으로 작동 될 
  때까지 기간 동안 이 특별약관에 따라 할인 받은 보험료를 회사에 돌려주어야 합니다. 
4. 계약의 취소 및 무효  
①  위 ‘3.’을 이행하지 않았을 경우 회사는 이 특별약관을 취소할 수 있습니다.
  다만, 전방충돌 경고장치의 고장에 따른 수리 또는 피보험자동차를 소유, 사용, 관리하는 동안에 생긴 사고로 인
  하여 전방충돌 경고장치가 파손 또는 훼손된 경우 등 특별한 상황이 인정되는 경우에는 취소하지 않습니다.
②  보험계약자 등이 위 ‘2’의 계약 전 알릴 의무를 알리지 않거나 제출한 정보가 사실과 다른 경우 이 특별약관은 
  무효가 됩니다. 
5. 할인보험료의 반환  
①  위 ‘4.’에 따라 이 특별약관이 취소 또는 무효처리 되는 경우 보험계약자 등은 이 특별약관으로 할인 받은 보험
  료를 돌려주어야 합니다.
②  피보험자동차의 사고로 보험금을 지급하는 경우, 회사는 위 ‘①’에 따라 보험계약자 등이 보험회사에 돌려줄 보
  험료를 피보험자에게 지급할 보험금에서 공제하고 지급할 수 있습니다.
[16]  전방충돌 경고장치에 관한 특별약관
1. 가입대상  
이 특별약관은 최초 출고 시 피보험자동차에 전방충돌 경고장치(*1)를 장착한 경우에만 가입할 수 있습니다.
※  가입 시 보험계약자는 일정금액의 보험료를 절감할 수 있습니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
162
163
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (84, 1, 84, '6. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 
1. 적용대상  
이 특별약관은 다음 각 호의 조건에 모두 해당하는 경우에 한하여 적용될 수 있습니다.
① 「소득세법 제59조의4(특별세액공제) 제1항 제2호」에 따라 보험료가 특별세액공제의 대상이 되는 경우
② 기명피보험자가 「소득세법 시행령 제107조(장애인의 범위) 제1항」에서 규정한 장애인인 경우
[17]  장애인 전용보험 전환 특별약관
<소득세법 제59조의4(특별세액공제)>
① 근로소득이 있는 거주자(일용근로자는 제외한다. 이하 이 조에서 같다)가 해당 과세기간에 만기에 환급되는 금액
  이 납입보험료를 초과하지 아니하는 보험의 보험계약에 따라 지급하는 다음 각 호의 보험료를 지급한 경우 그 금액
  의 100분의 12(제1호의 경우에는 100분의 15)에 해당하는 금액을 해당 과세기간의 종합소득산출액에서 공제한
  다. 다만, 다음 각 호의 보험료별로 그 합계액이 각각 연 100만원을 초과하는 경우 그 초과하는 금액은 각각 없는 
  것으로 한다.
 1. 기본공제대상자 중 장애인을 피보험자 또는 수익자로 하는 장애인전용보험으로서 대통령령으로 정하는 장애인
   전용보장성보험료
 2. 기본공제대상자를 피보험자로 하는 대통령령으로 정하는 보험료(제1호에 따른 장애인전용보장성보험료는 제외
   한다)
<소득세법 시행령 제118조의4 (보험료의 세액공제)>
① 법 제59조의4 제1항 제1호에서 “대통령령으로 정하는 장애인전용보장성보험료”란 제2항 각 호에 해당하는 보
  험ㆍ공제로서 보험ㆍ공제 계약 또는 보험료ㆍ공제료 납입영수증에 장애인전용 보험ㆍ공제로 표시된 보험ㆍ공제
  의 보험료ㆍ공제료를 말한다.
② 법 제59조의4 제1항 제2호에서 “대통령령으로 정하는 보험료”란 다음 각 호의 어느 하나에 해당하는 보험ㆍ보
  증ㆍ공제의 보험료ㆍ보증료ㆍ공제료 중 기획재정부령으로 정하는 것을 말한다.
 1. 생명보험
 2. 상해보험
 3. 화재ㆍ도난이나 그 밖의 손해를 담보하는 가계에 관한 손해보험
 4. 「수산업협동조합법」, 「신용협동조합법」 또는 「새마을금고법」에 따른 공제
 5. 「군인공제회법」, 「한국교직원공제회법」, 「대한지방행정공제회법」, 「경찰공제회법」 및 「대한소방공제회법」에 
   따른 공제
 6. 주택 임차보증금의 반환을 보증하는 것을 목적으로 하는 보험ㆍ보증. 다만, 보증대상임차보증금이 3억원을 초과
   하는 경우는 제외한다.
<소득세법 시행규칙 제61조의3 (공제대상보험료의 범위)>
영 제118조의4 제2항 각 호 외의 부분에서 “기획재정부령으로 정하는 것”이란 만기에 환급되는 금액이 납입보험료를 
초과하지 아니하는 보험으로서 보험계약 또는 보험료납입영수증에 보험료 공제대상임이 표시된 보험의 보험료를 말
한다.
<「소득세법 시행령 제107조(장애인의 범위)」에서 규정한 장애인>
 1. 「장애인복지법」에 따른 장애인 및 「장애아동 복지지원법」에 따른 장애아동 중 기획재정부령으로 정하는 사람
 2. 「국가유공자 등 예우 및 지원에 관한 법률」에 의한 상이자 및 이와 유사한 사람으로서 근로능력이 없는 사람
 3. 제1호 및 제2호 외에 항시 치료를 요하는 중증환자
<소득세법 시행규칙 제54조(장애아동의 범위)>
영 제107조 제1항 제1호에서 “기획재정부령으로 정하는 사람”이란 「장애아동 복지지원법」 제21조 제1항에 따른 발
달재활서비스를 지원받고 있는 사람을 말한다.
2. 증명서류의 제출  
① 이 특별약관이 적용되기 위해서는 「소득세법 시행규칙 별지 제38호 서식에 의한 장애인 증명서의 원본 또는 사
  본」(이하, “장애인 증명서류”라 합니다)을 제출하여 제1조(적용대상) 에서 정한 조건에 해당함을 증명하여야 
  합니다.
② 제1항에도 불구하고 기명피보험자가 다음 중 하나에 해당하는 경우에는 각 해당 증명서류를 제1항의 장애인 증
  명서류로 대체 할 수 있습니다.
 1. 「국가유공자 등 예우 및 지원에 관한 법률」에 따른 상이자의 증명을 받은 사람
 2. 「장애인복지법」에 따른 장애인등록증을 발급받은 사람
3. 장애인전용보험으로의 전환  
① 회사는 보험계약자가 제2조(증명서류의 제출)에서 정한 요건에 따라 제1조(적용대상)의 적용대상에 해당함을 
  증명하는 경우, 이 보험계약의 납입보험료를 「소득세법 제59조의4(특별세액공제) 제1항 제1호」에 해당하는 
  장애인전용 보장성 보험으로 전환하여 드립니다.
② 제1항에 따라 장애인 전용 보험으로 전환된 이후 납입된 보험료는 당해연도 보험료 납입영수증에 장애인 전용 
  보장성 보험료로 표시됩니다. 
4. 전환취소  
① 보험계약자가 장애인 전용 보장성 보험으로의 전환 취소를 보험회사에 요청하는 경우, 보험회사는 지체 없이 전
  환을 취소하여 드리며, 취소한 이후 납입한 보험료는 보험료 납입영수증에 일반 보장성 보험으로 표시됩니다.
② 제1항에 따라 장애인 전용 보장성 보험 전환을 취소한 이후에는, 재전환을 요청할 수 없습니다.
③ 최초 전환을 요청했던 당해연도에 제1항에 따라 전환을 취소한 경우에는 당해연도에 납입된 모든 보험료는 보
  험료 납입영수증에 장애인 전용 보장성 보험료가 아닌 일반 보장성 보험료로 표시됩니다
5. 준용규정  
① 이 특별약관에서 정하지 아니한 사항은 보통약관 및 소득세법 등 관련법규에서 정하는 바에 따릅니다.
② 소득세법 등 관련법규가 제ㆍ개정 또는 폐지되는 경우 변경된 법령을 따릅니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
1. 가입대상  
① 이 특별약관은 보험기간이 1년인 경우에만 가입할 수 있습니다.
②  이 특별약관은 동물보호관리시스템(*1)에 등록된 기명피보험자 또는 그 배우자(*2), 자녀(*3) 소유의 반려동물이 
있는 경우에 한해 가입할 수 있습니다.
2. 계약 전 알릴의무  
보험계약자 또는 피보험자는 이 특별약관의 계약체결 시 가입하고자 하는 반려동물의 동물보호관리시스템에 등록
된 동물등록번호를 보험회사(이하 “회사”라 함)에 알려주어야 합니다.
3. 보상하는 손해
회사는 피보험자가 피보험자동차를 소유䞱사용䞱관리하는 동안에 생긴 타인자동차(*4)와 충돌 또는 접촉한 사고(*5)로 
인해 피보험자동차에 탑승중인 반려동물이 폐사(*6) 또는 부상(*7)을 입은 경우 보험증권에 기재된 반려동물당(동물
등록번호 기준) 다음 <별표> 보험금 지급기준에 따라 보험금을 지급합니다.
[18]  반려동물 교통사고 위로금 특별약관
(*1)  ‘동물보호관리시스템’이란 동물보호법 제15조(등록대상동물의 등록 등) 및 동법시행규칙 제10조(등록대상
동물의 등록사항 및 방법 등)에 따라 농림축산검역본부에서 운영하는 동물등록 및 보호 등의 업무를 수행하는 
시스템을 말합니다.
(*2)  기명피보험자의 배우자 : 보험증권에 기재된 피보험자의 법률상의 배우자 또는 사실혼관계에 있는 배우자를 
말합니다.
(*3)  기명피보험자의 자녀 : 보험증권에 기재된 피보험자의 법률상의 혼인관계 또는 사실혼관계에서 출생한 자녀, 
양자녀를 말합니다. 
164
165
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (85, 1, 85, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
단, 반려동물 부상회복 위로금은 보험기간 중 1회에 한하여 지급하며, 이후에 반려동물이 폐사하는 경우 반려동
물 장례 및 새가족 맞이 지원금 은 보험증권에 기재된 가입금액에서 반려동물 부상회복 위로금의 지급 금액을 
제외한 금액을 지급하여 드립니다
보험금 종류
보험금 지급기준 (반려동물당)
실속형
기본형
반려동물 장례 및 새가족 맞이 지원금 (폐사)
반려동물 부상회복 위로금 (부상)
50만원
20만원
100만원
50만원
<별표> 보험금 지급기준
(*4)  ‘타인자동차’란 피보험자동차 이외의 자동차로서 그 자동차의 등록번호(차량번호 또는 차대번호 등을 말함)와 
사고발생 시의 운전자 또는 소유자의 신분이 확인된 경우만을 말합니다. 이 경우, ‘자동차’란 자동차관리법에 
따른 자동차, 군수품관리법에 따른 차량, 도로교통법에 따른 원동기장치자전거, 건설기계관리법에 따른 건설
기계, 농업기계화촉진법에 따른 농업기계를 말합니다. 다만, 다음 중 어느 하나에 해당하는 자동차는 이 특별
약관의 타인자동차로 보지 않습니다.
   (1) 기명피보험자와 그 부모, 배우자, 자녀가 소유하거나 통상 사용하는 자동차
   (2)  기명피보험자의 배우자의 부모로서 기명피보험자 또는 그 배우자와 동거 중인 자가 소유하거나 통상 사용
하는 자동차
(*5)  ‘충돌 또는 접촉한 사고’란 타인자동차와 충돌 또는 접촉하여 피보험자가 가입한 보험계약의 대물배상 또는 자
기차량손해 보험금이 지급되거나 상대방이 가입한 보험회사에서 대물배상 보험금을 지급받은 사고를 말합니
다.
(*6)  ‘폐사’란 ‘3. 보상하는 손해’에서 정하는 사고의 직접적인 결과로 반려동물이 수의사법 제12조(진단서 등)에 
따라 수의사가 발급한 폐사 진단서에 의해 폐사가 확인된 경우를 말합니다.
(*7)  ‘부상’이란 ‘3. 보상하는 손해’에서 정하는 사고의 직접적인 결과로 반려동물이 상해를 입어 수의사법 제12조
(진단서 등)에 따라 수의사가 발급한 진단서에 의해 부상이 확인된 경우를 말합니다.
4. 보상하지 않는 손해
회사는 보통약관 제8조(보상하지 않는 손해) ①항의 1호 내지 7호나 8호에 해당하는 손해는 보상하지 않으며, 다
음의 손해도 보상하지 않습니다.
 1) 보험증권에 기재된 운전가능범위 외의 자가 운전하던 중 생긴 사고로 인한 손해
 2)  피보험자가 무면허운전(보통약관 제1조 제4호) 또는 음주운전(보통약관 제1조 제9호)을 하였을 때 생긴 사
고로 인한 손해
 3) 피보험자가 마약䞱약물운전(보통약관 제1조 제20호)을 하였을 때 생긴 사고로 인한 손해
5. 계약의 무효
보험계약자 또는 피보험자가 위 ‘2. 계약 전 알릴의무’에 따른 동물등록번호를 허위로 알린 경우 이 특별약관은 성
립하지 않습니다.
6. 보험금 청구 시 제출서류
보험금을 청구할 때에는 보험금 청구서와 사고를 증명하는 서류(초진차트, 진단서 등), 동물등록증, 가족관계증명
서(등록된 반려동물이 기명피보험자의 배우자 또는 자녀 소유로 등록된 경우에 한함), 그 밖에 보험회사가 꼭 필요
하다고 인정하는 서류 또는 증거를 제출하여야 합니다.
7. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다
(*1) ‘보험계약자료’란 회사가 이 보험계약의 계약자에게 제공하는 보험증권, 보험약관, 만기䞱분납보험료 안내문 
   등 서류를 말합니다.
(*2) ‘전자적 방법’이란 다음의 방법을 말하는 것으로서 계약자는 다음 중 한가지 또는 두가지 방법 모두를 선택할 
   수 있습니다. 
    (1) 전자우편
    (2) 모바일 메신저 등의 메시지 서비스
Ⅸ. 녹색상품
※  이 특약을 가입함으로써 보험계약자는 일정금액의 보험료를 절감할 수 있습니다.
1. 적용대상  
보험회사(이하 “회사”라 함)는 보험계약자가 이 보험계약의 보험계약자료(*1)를 회사가 정하는 전자적 방법(*2) 으
로 받기로 약정하는 경우에 이 특별약관을 적용합니다.
1⃞  Ever Green(전자매체 활용 약관ㆍ증권 발송) 특별약관
※  이 특약은 종이를 절감하여 저탄소 녹색성장에 기여함으로써, 환경을 보호하는 상품입니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
2. 보험계약자의 알릴 의무  
①  보험계약자는 보험계약을 청약할 때 선택한 전자적 방법에 따라 다음의 정보를 회사에 알려주어야 합니다.
 1) 전자우편 : 보험계약자료를 받을 전자우편의 수령처(이메일주소) 정보
 2) 모바일메신저 등의 메시지 서비스 : 핸드폰 번호 등 회사가 요청하는 정보 
②  위 ‘①의 1), 2)’에서 알려준 정보가 변경되거나 사용 정지된 경우에는 그 사실을 지체 없이 회사에 알려야 합니
  다.
③  위 ‘①’ 또는 ‘②’의 정보를 사실과 다르게 알리거나 알리지 않은 경우에는 회사가 알고 있는 최후의 정보에 따라 
  보험계약자료를 발급하게 되므로 불이익을 입을 수 있습니다.
3. 보험계약자료의 발급  
①  회사는 보험계약이 성립되면 보험계약자가 알려준 정보에 따라 보험계약자료를 지체 없이 발급합니다.
②  회사는 보험계약자가 위 ‘①’에 따라 발급한 보험계약자료를 발급한 날부터 1개월간 확인하지 않은 경우에는 
  1회에 한정하여 해당 보험계약자료를 전자적 방법을 통해 다시 발급합니다.
③  회사는 보험계약자가 계약사항 변경 등 이유로 보험계약자료를 다시 발급할 것을 요청할 때에는 전자적 방법을 
  통해 보험계약자료를 다시 발급할 수 있습니다.
4. 특별약관의 소멸  
이 특별약관에 따라 보험계약자는 보험기간 중에 각종 보험계약자료를 전자적 방법으로 받아야 함에도 불구하고, 
보험계약자료를 우편으로 요청할 경우에는 그 시점부터 특별약관이 자동 소멸되고 보험계약자는 할인 받은 보험료
를 회사에 돌려주어야 합니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
166
167
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (86, 1, 86, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
100) 개인이 소유한 2대 이상의 차량을 보험기간의 끝나는 날을 일치시켜 하나의 증권으로 가입하는 경우를 말하는 것으로 
   “동일증권” 계약이라고 합니다. 
1. 가입대상  
①  이 특별약관은 보험기간이 1년인 경우에만 가입할 수 있습니다. (다만, 이미 체결된 자동차보험 계약의 보험기
  간이 1년이면서 3개월 이상 남은 경우 이 특별약관을 추가 가입할 수 있음)
②  위 ‘①’에도 불구하고 기명피보험자의 다른 자동차보험 계약과 보험기간 만료일을 일치시키기 위한 계약의 경우
  
지식100) 보험기간이 3개월 이상이면 이 특별약관을 가입할 수 있습니다.
③  보험회사(이하 ‘회사’라 함)는 ''보험계약자 또는 피보험자''(이하 ‘보험계약자 등’이라 함)가 다음 중 하나에 해
  당하는 경우에는 가입을 제한할 수 있습니다. 
 1)  주행거리계 조작 또는 주행거리계 사진 위ㆍ변조 등 주행거리정보를 날조하거나 다른 자동차의 주행거리정보
   를 보내 보험료를 할인 또는 환급 받은 사실이 있는 경우. 
 2)  주행거리에 따라 보험료가 할인 또는 환급되는 특약을 가입한 후 할인 또는 환급된 보험료의 추가 징수 사유
   가 발생했지만 보험료를 돌려주지 않은 사실이 있는 경우.
④  회사는 이 특별약관의 체결 후 위 ‘③’의 사실을 알게 된 경우 안 날부터 1개월 이내에 이 특별약관의 계약을 취
  소할 수 있습니다.
2. 계약 전 알릴 의무  
①  보험계약자 등은 이 특별약관의 보험기간 개시일 이후 15일 이내에 피보험자동차의 최초 주행거리(피보험자동
  차 주행거리계의 주행거리. 이하 동일) 정보의 촬영사진(또는 자동차검사소 등 회사가 인정하는 기관의 최초 주
  행거리 확인서)과 이를 확인한 날짜를 회사가 정하는 방법(*1)으로 전송하고 회사의 승인을 얻어야 합니다.
②  위 ‘①’에도 불구하고 회사는 보험계약자 등이 타사와 맺은 직전 계약에서 주행거리 후할인(또는 선할인) 특별
  약관 정산에 사용된 최종 주행거리 정보를 보험개발원 조회를 통해 확인한 경우에는 보험계약자 등이 최초 주행
  거리 정보를 송부한 것으로 간주합니다. 
2⃞  주행거리 후할인 특별약관
※  이 특별약관은 승용차요일제 특별약관과 중복하여 가입할 수 없습니다. 
③  제2항에도 불구하고, 보험계약자(또는 피보험자)가 타사와 맺은 직후 계약에서 주행거리 후할인(또는 선할인) 
  특별약관 가입에 사용된 최초 주행거리 정보를 보험개발원 조회를 통해 확인한 경우에는 보험계약자(또는 피보
  험자)가 최종 주행거리 정보를 송부한 것으로 간주합니다.
④  보험계약자는 이 특별약관에 따라 보험료의 환급이 발생하는 경우 회사가 변경된 보험료를 정산할 수 있도록 보
  험계약자 명의의 은행계좌번호 또는 신용카드 정보를 회사에 알려야 합니다. 또한 보험계약자는 은행계좌번호 
  또는 신용카드 정보가 변경되거나 거래 정지된 경우에는 지체 없이 회사에 알려야 합니다.
4. 계약의 무효  
①  다음에 해당하는 경우에는 이 특별약관은 자동으로 무효가 됩니다.
 1) 이 특별약관의 보험기간 개시일 이후 15일 이내에 위 ‘2.’의 주행거리 정보가 확인되지 않는 경우
②  보험계약자 등이 위 ‘3.의 ②, 2)’에 따라 보내야 하는 교체(대체)전 피보험자동차의 최종 주행거리정보 및 교
  체(대체)후 피보험자동차의 최초 주행거리정보를 완료기한 이내에 보내지 않은 경우에는 이 특별약관은 성립
  하지 않습니다. 다만, 회사가 인정하는 경우에는 예외로 합니다.
③  보험계약자 등이 위 ‘2.의 ①’ 또는 ‘3.의 ②’에 따라 보내는 주행거리정보를 조작하거나 다른 자동차의 주행거
  리정보를 보내는 경우에는 이 특별약관은 무효로 됩니다.
5. 연간 주행거리 계산  
연간 주행거리(*1)는 보험계약자 등이 위 ‘2.’ 또는 ‘3.의 ②’에 따라 보내주는 주행거리정보를 기준으로 다음의 산
식에 따라 산출합니다. 다만, 피보험자동차가 교체(대체)된 경우에는 교체(대체)전 피보험자동차와 교체(대체)후 
피보험자동차의 주행거리 및 경과기간을 각각 합산하여 산출합니다.
(*1) “주행거리 확인방법”이란 다음을 말합니다.
    (1) 보험계약자 등이 피보험자동차 주행거리계의 주행거리 및 주행거리계 사진 송부
    (2) 보험계약자 등이 회사에서 지정하는 주행거리 확인이 가능한 정비업체에 방문하여 확인된 피보험자동차 
     주행거리계의 ‘주행거리’ 및 ‘주행거리계 사진’ 송부
    (3) 회사직원, 긴급출동서비스 요원 등 회사에서 지정하는 자가 확인한 피보험자동차 주행거리계의 주행거리 
     및 주행거리계 사진 송부
3. 보험계약자 또는 피보험자의 의무사항  
①  보험계약자 등은 보험기간 중에 현장출동서비스, 긴급출동서비스를 받거나 피보험자동차를 정비업체에서 수리
  할 경우 주행거리정보 확인에 협조해야 합니다.
②  보험계약자 등은 다음 중 하나에 해당하는 경우, 주행거리 확인방법에 따라 확인한 주행거리 정보를 완료기한 
  이내에 회사로 보내 주어야 합니다.
2) 보험기간 중 피보험
 
자동차가 교체(대체)
 
된 경우
교체(대체)전 피보험자동차의 최종 
주행거리 정보와 교체(대체)후 
피보험자동차의 최초 주행거리정보
교체(대체)된 날(보통약관 제49조에 따라 
회사가 승인한 날을 말함) 이전 7일부터 교
체(대체)된 날 이후 7일 이내
구분
주행거리 정보
완료기한
1) 보험기간이 끝나는 
 
경우
피보험자동차의 최종 주행거리 정보
보험기간 만료일 이전 2개월부터 보험기간 
만료일 이후 1개월 이내
6. 보험료 정산 환급 등  
①  회사는 위 ‘3.의 ② 내지 ③’에 따라 받은 주행거리정보를 지체 없이 확인하여 연간 주행거리 실적에 따라 보험
  계약자 명의의 은행계좌 또는 신용카드로 보험료 정산금액을 환급하여 드리며, 정산금액은 <별표>에서와 같이 
  연간 주행거리 실적에 따라 보험증권에 기재된 정산율을 이용하여 산정합니다.
(*1) ‘연간 주행거리’란 피보험자동차의 최종 주행거리에서 최초 주행거리를 연간으로 환산한 주행거리를 말합니
   다. 
(*2) ‘주행거리 확인일’이란 보험계약자 등이 피보험자동차의 주행거리정보를 촬영한 날짜 또는 주행거리 확인방법
   에 따라 피보험자동차의 주행거리정보를 확인한 날짜를 말합니다.  
연간 주행거리 = 일평균 주행거리 × 365
①  일평균 주행거리 : (최종 주행거리 – 최초 주행거리) ÷ 주행경과기간
②  주행경과기간 : 최초 주행거리 확인일(*2)로부터 최종 주행거리 확인일까지의 기간
168
169
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (87, 1, 87, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
②  회사는 위 ‘3.의 ② 내지 ③’에 따라 받은 주행거리정보를 재확인할 필요가 있다고 판단할 경우에는 주행거리 확
  인방법에 따라 주행거리정보의 재확인을 요청할 수 있습니다. 
  주행거리정보 재확인에 협조하지 않는 등 보험계약자 등에게 책임이 있는 사유로 주행거리정보를 재확인할 수 
  없는 경우, 연간 주행거리 15,000km를 초과한 것으로 보고 정산금액을 지급하지 않습니다. 다만, 보험계약자 
  등이 연간 주행거리를 증명한 경우에는 예외로 합니다.
③  회사는 위 ‘3.의 ② 내지 ③’에 따라 피보험자동차의 최종 주행거리정보를 받은 날(보험기간 만료일 이전에 최
  종 주행거리정보를 받은 경우에는 보험기간 만료일) 또는 회사가 보험개발원 조회를 통해 최종주행거리가 확인
  될 날(보험기간 만료일 이전에 최종주행거리가 확인된 경우에는 보험기간 만료일)로부터 10일 이내에 보험료
  를 정산하여 드립니다.  
④ 위 ‘③’에서 10일을 초과하는 경우에는 그 초과기간 동안의 이자금액(보험개발원이 공시한 보험계약대출이율)
  을 더하여 지급합니다. 다만, 보험계약자 또는 피보험자 등에게의 책임이 있는 사유로 지급이 지연된 때에는 그 
  해당기간에 대한 이자는 더하여 드리지 않습니다.
7. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
연간 주행거리
정산금액
1,000km 이하
1,000km 초과 2,000km 이하
2,000km 초과 3,000km 이하
3,000km 초과 4,000km 이하
4,000km 초과 5,000km 이하
5,000km 초과 6,000km 이하
6,000km 초과 7,000km 이하
7,000km 초과 8,000km 이하
8,000km 초과 9,000km 이하
9,000km 초과 10,000km 이하
10,000km 초과 12,000km 이하
12,000km 초과 15,000km 이하
15,000km 초과
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
없음
<별표> 보험료 정산금액
주) 적용보험료에서 긴급출동서비스 특약 보험료는 제외됩니다.
1. 가입대상  
①  이 특별약관은 보험계약 체결 시 피보험자동차를 연간 주행거리(*1) 이하로 운행하기로 약정하고 보험기간이 
  1년인 경우에만 가입할 수 있습니다. (다만, 이미 체결된 자동차보험 계약의 보험기간이 1년이면서 3개월 이상 
  남은 경우 이 특별약관을 추가 가입할 수 있음)
(*1) ‘연간 주행거리’란 피보험자동차의 최종 주행거리에서 최초 주행거리를 연간으로 환산한 주행거리를 말합니
   다.
101) 165쪽 프로미카 보험지식 ‘100)’ 참조
3⃞  주행거리 선할인 특별약관
※  이 특별약관은 승용차요일제 특별약관과 중복하여 가입할 수 없습니다. 
연간 주행거리
정산금액
1,000km 이하
1,000km 초과 2,000km 이하
2,000km 초과 3,000km 이하
3,000km 초과 4,000km 이하
4,000km 초과 5,000km 이하
5,000km 초과 6,000km 이하
6,000km 초과 7,000km 이하
7,000km 초과 8,000km 이하
8,000km 초과 9,000km 이하
9,000km 초과 10,000km 이하
10,000km 초과 12,000km 이하
12,000km 초과 15,000km 이하
15,000km 초과
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
없음
<별표> 보험료 정산금액
주) 적용보험료에서 긴급출동서비스 특약 보험료는 제외됩니다.
②  위 ‘①’에도 불구하고 기명피보험자의 다른 자동차보험 계약과 보험기간 만료일을 일치시키기 위한 계약의 경우
  
지식101) 보험기간이 3개월 이상이면 이 특별약관을 가입할 수 있습니다.
③  보험회사(이하 ‘회사’라 함)는 ''보험계약자 또는 피보험자''(이하 ‘보험계약자 등’이라 함)가 다음 중 하나에 해
  당하는 경우에는 가입을 제한할 수 있습니다. 
 1)  주행거리계 조작 또는 주행거리계 사진 위ㆍ변조 등 주행거리정보를 날조하거나 다른 자동차의 주행거리정보
   를 보내 보험료를 할인 또는 환급받은 사실이 있는 경우. 
 2)  주행거리에 따라 보험료가 할인 또는 환급되는 특약을 가입한 후 할인 또는 환급된 보험료의 추가 징수 사유
   가 발생했지만 보험료를 돌려주지 않은 사실이 있는 경우.
④  회사는 이 특별약관의 체결 후 위 ‘③’의 사실을 알게 된 경우 안 날부터 1개월 이내에 이 특별약관의 계약을 취
  소할 수 있습니다. 취소하는 경우 회사는 보험계약자가 알려준 은행 계좌번호 또는 신용카드 등으로 즉시 이 특
  별약관으로 할인 받은 보험료를 추가 징수합니다.
⑤  이 특별약관에 가입한 경우에는 <별표>의 보험료 정산금액을 보험계약 체결 시 할인하여 드립니다.
2. 계약 전 알릴 의무  
①  보험계약자 등은 이 특별약관 가입시점 피보험자동차의 최초 주행거리(피보험자동차 주행거리계의 주행거리. 
  이하 동일) 정보를 회사가 정하는 주행거리 확인방법(*1)에 따라 보내고 회사의 승인을 받아야 합니다.
②  이 특별약관이 체결되기 전까지 위 ‘①’의 정보를 보내지 않거나 회사의 승인을 받지 않는 경우, 이 특별약관은 
  성립하지 않습니다. 다만, 갱신계약 등 회사가 인정하는 경우는 예외로 합니다. 
170
171
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (88, 1, 88, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
③  보험계약자는 이 특별약관 및 보통약관의 무효, 효력 상실, 해지, 보험계약내용의 변경 등으로 인하여 이 특별약
  관에 따라 할인받은 보험료의 추징 또는 환급이 발생하는 경우, 회사가 변경된 보험료를 정산할 수 있도록 보험
  계약자 명의의 은행 계좌번호 또는 신용카드 정보 등을 회사에 알려야 합니다. 또한 보험계약자는 은행 계좌번
  호 또는 신용카드 등의 정보가 변경되거나 거래 정지된 경우에는 지체 없이 회사에 알려야 합니다.
④  보험계약자 등은 계약 체결 시 약정한 연간 주행거리를 준수하여야 합니다.
4. 계약의 무효  
①  보험계약자 등이 위 ‘3.의 ②, 2)’에 따라 보내야 하는 교체(대체)전 피보험자동차의 최종 주행거리정보 및 교체
  (대체)후 피보험자동차의 최초 주행거리정보를 완료기한 이내에 보내지 않은 경우에는 이 특별약관은 성립하
  지 않습니다. 다만, 회사가 인정하는 경우에는 예외로 합니다.
②  보험계약자 등이 위 ‘2.의 ①’ 또는 ‘3.의 ②’에 따라 보내는 주행거리정보를 조작하거나 다른 자동차의 주행거
  리정보를 보내는 경우에는 이 특별약관은 무효로 됩니다.
5. 연간 주행거리 산출  
연간 주행거리는 보험계약자 등이 위 ‘2.의 ①’ 또는 ‘3.의 ②’에 따라 보내는 주행거리정보를 기준으로 다음의 산식
에 따라 산출합니다. 다만, 피보험자동차가 교체(대체)된 경우에는 교체(대체)전 피보험자동차와 교체(대체)후 피
보험자동차의 주행거리 및 경과기간을 각각 합산하여 산출합니다.
연간 주행거리 = 일평균 주행거리 × 365
①  일평균 주행거리 : (최종 주행거리 – 최초 주행거리) ÷ 주행경과기간
②  주행경과기간 : 최초 주행거리 확인일(*1)로부터 최종 주행거리 확인일까지의 기간
(*1) ‘주행거리 확인일’이란 보험계약자 등이 피보험자동차의 주행거리정보를 촬영한 날짜 또는 주행거리 확인방법
   에 따라 피보험자동차의 주행거리정보를 확인한 날짜를 말합니다.
구분
주행거리 정보
완료기한
1) 보험기간이 끝나는 
 
경우
2) 보험기간 중 피보험
 
자동차가 교체(대체)
 
된 경우
피보험자동차의 최종 주행거리 정보
교체(대체)전 피보험자동차의 
최종 주행거리 정보와 교체(대체)후 
피보험자동차의 최초 주행거리정보
보험기간 만료일 이전 2개월부터 보험기간 
만료일 이후 1개월 이내
교체(대체)된 날(보통약관 제49조에 따라 
회사가 승인한 날을 말함) 이전 7일부터 교
체(대체)된 날 이후 7일 이내
3. 보험계약자 또는 피보험자의 의무사항  
①  보험계약자 등은 보험기간 중에 현장출동서비스, 긴급출동서비스를 받거나 피보험자동차를 정비업체에서 수리
  할 경우 주행거리정보 확인에 협조해야 합니다.
②  보험계약자 등은 다음 중 하나에 해당하는 경우, 주행거리 확인방법에 따라 확인한 주행거리 정보를 완료기한 
  이내에 회사로 보내 주어야 합니다. 
(*1) “주행거리 확인방법”이란 다음을 말합니다.
    (1) 보험계약자 등이 피보험자동차 주행거리계의 주행거리 및 주행거리계 사진 송부
    (2) 보험계약자 등이 회사에서 지정하는 주행거리 확인이 가능한 정비업체에 방문하여 확인된 피보험자동차 
     주행거리계의 ‘주행거리’ 및 ‘주행거리계 사진’ 송부
    (3) 회사직원, 긴급출동서비스 요원 등 회사에서 지정하는 자가 확인한 피보험자동차 주행거리계의 주행거리 
     및 주행거리계 사진 송부
1. 가입대상  
①  이 특별약관은 피보험자동차가 ''운행정보를 확인할 수 있는 장치''(이하 ‘운행정보 확인장치(OBD: On Board 
  Diagnostic)(*1)’라 함)를 부착할 수 있는 자동차로서, 보험기간이 1년인 경우에만 가입할 수 있습니다. (다만, 
  이미 체결된 자동차보험 계약의 보험기간이 1년이면서 3개월 이상 남은 경우 이 특별약관을 추가 가입할 수 있음)
②  위 ‘①’에도 불구하고 기명피보험자의 다른 자동차보험 계약과 보험기간 만료일을 일치시키기 위한 계약의 경
  우 보험기간이 3개월 이상이면 이 특별약관을 가입할 수 있습니다.
③  보험회사(이하 ‘회사’라 함)는 ''보험계약자 또는 피보험자''(이하 ‘보험계약자 등’이라 함)가 다음 중 하나에 해
  당하는 경우에는 가입을 제한할 수 있습니다. 
 1)  주행거리계 조작 또는 주행거리계 사진 위ㆍ변조 등 주행거리정보를 날조하거나 다른 자동차의 주행거리정보
   를 보내 보험료를 할인 또는 환급받은 사실이 있는 경우. 
 2)  주행거리에 따라 보험료가 할인 또는 환급되는 특약을 가입한 후 할인 또는 환급된 보험료의 추가 징수 사유
   가 발생했지만 보험료를 돌려주지 않은 사실이 있는 경우.
④  회사는 이 특별약관의 체결 후 위 ‘③’의 사실을 알게 된 경우 안 날부터 1개월 이내에 이 특별약관의 계약을 취
  소할 수 있습니다.
4⃞  OBD 주행거리 후할인 특별약관
※  이 특별약관은 승용차요일제 특별약관과 중복하여 가입할 수 없습니다. 
6. 보험료 할인 및 정산 등  
①  회사는 이 특별약관에 가입하는 경우 약정한 연간 주행거리에 따라 <별표>에서 정한 보험료 정산금액을 적용합
  니다.
② 회사는 위 ‘3.의 ②’에 따라 보내야 하는 최종 주행거리정보를 완료기한 이내에 보내지 않은 경우에는, 연간 주
  행거리 15,000km를 초과한 것으로 보고 보험계약자가 알려 준 은행 계좌번호 또는 신용카드 등으로 즉시 이 
  특별약관으로 할인 받은 보험료를 추가 징수합니다. 
    다만, 보험계약자 등이 연간 주행거리를 증명한 경우에는 약정한 연간 주행거리에 따라 <별표>에서 정한 보험료 
  정산금액을 환급하여 드립니다.
③ 회사는 위 ‘3.의 ②’에 따라 받은 주행거리정보를 재확인할 필요가 있다고 판단할 경우에는 주행거리 확인방법
  에 따라 주행거리정보의 재확인을 요청할 수 있습니다. 
  주행거리정보 재확인에 협조하지 않는 등 보험계약자 등에게 책임이 있는 사유로 주행거리정보를 재확인할 수 
  없는 경우, 연간 주행거리 15,000km를 초과한 것으로 보고 이 특별약관으로 할인 받은 보험료를 추가 징수합
  니다. 다만, 보험계약자 등이 연간 주행거리를 증명한 경우에는 예외로 합니다.
④ 회사는 위 ‘4.’에 따라 이 특별약관이 무효처리 되는 경우에는, 보험계약자가 알려 준 은행 계좌번호 또는 신용
  카드 등으로 즉시 이 특별약관으로 할인 받은 보험료를 추가 징수합니다. 
⑤  회사는 위 ‘①’에도 불구하고 ‘5.’에 따라 산출한 피보험자동차의 연간 주행거리가 보험계약 체결 시 약정한 연
  간 주행거리 미만이거나 초과하여 운행한 경우에는, 최종 연간 주행거리에 따른 정산금액과 보험계약 체결 시 
  할인 받은 보험료의 차액을 보험계약자에게 알려주고 보험계약자가 알려 준 은행 계좌번호 또는 신용카드 등으
  로 환급하거나 추가 징수합니다. 
⑥  회사는 위 ‘②’부터 ‘④’까지의 규정 이외에 이 특별약관 및 보통약관의 무효, 효력 상실, 해지, 보험계약내용의 
  변경 등으로 인하여 선할인 한 보험료가 변경되는 경우에는 해당 사유를 보험계약자에게 알려주고 보험계약자
  가 알려준 은행 계좌번호 또는 신용카드 등으로 이 특별약관에 의해 할인된 보험료를 정산합니다. 
7. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
172
173
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (89, 1, 89, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
② 보험계약자는 이 특별약관에 따라 보험료의 환급이 발생하는 경우 회사가 변경된 보험료를 정산할 수 있도록 보
  험계약자 명의의 은행계좌번호 또는 신용카드 정보를 회사에 알려야 합니다. 또한 보험계약자는 은행계좌번호 
  또는 신용카드 정보가 변경되거나 거래 정지된 경우에는 지체 없이 회사에 알려야 합니다.
4. 계약의 무효  
①  보험계약자 등이 위 ‘3.의 ②, 2)’에 따라 전송해야 하는 교체(대체)전 피보험자동차의 운행정보 및 교체(대체)
  후 피보험자동차의 운행정보를 완료기한 이내에 전송하지 않은 경우에는 이 특별약관은 성립하지 않습니다. 다
  만, 회사가 인정하는 경우에는 예외로 합니다.
②  보험계약자 등이 위 ‘2.의 ①’ 또는 ‘3.의 ①’에 따라 전송하는 운행정보를 조작하거나 다른 자동차의 운행정보
  를 전송하는 경우에는 이 특별약관은 무효로 됩니다.
5. 연간 주행거리 계산  
연간 주행거리(*1)는 보험계약자 등이 위 ‘2.의 ①’ 또는 ‘3.의 ①’에 따라 전송하는 운행정보를 기준으로 다음의 산
식에 따라 산출합니다. 다만, 피보험자동차가 교체(대체)된 경우에는 교체(대체)전 피보험자동차와 교체(대체)후 
피보험자동차의 주행거리 및 경과기간을 각각 합산하여 산출합니다.
연간 주행거리 = 일평균 주행거리 × 365
①  일평균 주행거리 : (최종 주행거리 – 최초 주행거리) ÷ 주행경과기간
②  주행경과기간 : 최초 주행거리 확인일(*2)로부터 최종 주행거리 확인일까지의 기간
(*1) ‘연간 주행거리’란 피보험자동차의 최종 주행거리에서 최초 주행거리를 연간으로 환산한 주행거리
(*2) ‘주행거리 확인일’이란 보험계약자 등이 피보험자동차의 운행정보를전송한 날짜를 말합니다.
6. 보험료 정산 환급 등  
①  회사는 위 ‘3.의 ①’에 따라 받은 운행정보를 지체 없이 확인하여 연간 주행거리 실적에 따라 보험계약자 명의의 
  은행계좌 또는 신용카드로 보험료 정산금액을 환급하여 드리며, 정산금액은 <별표>에서와 같이 연간 주행거리 
  실적에 따라 보험증권에 기재된 정산율을 이용하여 산정합니다.
구분
운행정보
완료기한
1) 보험기간이 끝나는 
 
경우
피보험자동차의 최종 운행정보
보험기간 만료일 이전 2개월부터 보험기간 
만료일 이후 1개월 이내
2) 보험기간 중 피보험
 
자동차가 교체(대체)
 
된 경우
3) 보험기간 중에 
 
OBD를 교체한 
 
경우
피보험자동차의 차량정보, OBD의 
모델명, 제품식별번호, 그 밖의 회사가 
요구하는 사항
 ㉮ 교체된 기존 OBD에 저장된 정보
㉯ 교체한 신규 OBD의 모델명 
  제품식별번호 및 그 밖의 회사가 
  요구하는 사항
교체(대체)된 날(보통약관 제49조에 따라 
회사가 승인한 날을 말함) 이전 7일부터 교
체(대체)된 날 이후 7일 이내
즉시 전송
기존 OBD를 분리한 날부터 7일 이내에 부
착하고 전송
2. 계약 전 알릴 의무  
①  보험계약자 등은 책임개시일부터 7일 이내에 OBD를 부착하고, 책임개시일부터 15일 이내에 피보험자동차의 
  차량정보, OBD의 모델명, 제품식별번호 및 그 밖에 회사가 요구하는 사항을 회사가 정하는 방법에 따라 전송하
  여야 합니다. 
②  책임개시일부터 15일 이전까지 위 ‘①’의 정보를 전송하지 않은 경우에는 이 특별약관은 성립하지 않습니다.
3. 운행정보의 전송 등 보험계약자 또는 피보험자의 의무사항  
①  보험계약자 등은 다음 중 하나에 해당하는 경우, 피보험자동차의 운행정보를 완료기한 이내에 회사가 정하는 방
  법에 따라 전송해야 합니다.
(*1) ‘운행정보 확인장치(OBD)’란 피보험자동차의 요일별 운행여부를 포함한 운행정보를 저장하고 그 정보를 전
   송할 수 있는 기능을 갖춘 장치로서 보험개발원 부설 자동차기술연구소의 기술인증을 부여받은 장치를 말합니
   다.
(*2) ‘비운행 약정요일’이란 매 주 월요일부터 금요일 중 하루로서 이 보험계약 체결 시 보험계약자 또는 피보험자
   가 운행하지 않기로 약정한 보험증권에 기재된 요일(07:00부터 22:00까지만 해당)을 말합니다. 다만, 운행하
   지 않는 요일이 법정공휴일(국가에서 정한 임시공휴일 및 근로자의 날을 포함)인 경우에는 비운행 약정요일에 
   해당하지 않습니다.
(*3) 이 특별약관에서 규정하는 ‘운행’이란 피보험자동차가 주행하여 거리 이동이 있는 경우로 해당 비운행 약정요
   일 당일에 주행한 총 거리의 합이 1km를 초과하는 경우만을 말합니다.
1. 가입대상  
①  이 특별약관은 피보험자동차의 운행정보(이하 “운행정보”라 함)를 확인할 수 있는 장치(이하 “운행정보 확인장
  치(OBD)(*1)”라 함)를 장착하고 보험증권에 기재된 의무보험의 보험기간 동안 비운행 약정요일(*2)에 운행(*3)
 
 하지 않을 것을 약정한 경우, 가입할 수 있습니다(단, 보험기간이 3개월 이상 남은 경우에만 한정함) 
5⃞  승용차요일제 특별약관
②  회사는 위 ‘3.의 ①’에 따라 피보험자동차의 최종 운행정보를 받은 날(보험기간 만료일 이전에 최종 운행정보를 
  받은 경우에는 보험기간 만료일)로부터 10일 이내에 보험료를 정산하여 드립니다. 
③ 위 ‘②’에서 10일을 초과하는 경우에는 그 초과기간 동안의 이자금액(보험개발원이 공시한 보험계약대출이율)
  을 더하여 지급합니다. 다만, 보험계약자 또는 피보험자 등에게의 책임이 있는 사유로 지급이 지연된 때에는 그 
  해당기간에 대한 이자는 더하여 드리지 않습니다.
7. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
연간 주행거리
정산금액
1,000km 이하
1,000km 초과 2,000km 이하
2,000km 초과 3,000km 이하
3,000km 초과 4,000km 이하
4,000km 초과 5,000km 이하
5,000km 초과 6,000km 이하
6,000km 초과 7,000km 이하
7,000km 초과 8,000km 이하
8,000km 초과 9,000km 이하
9,000km 초과 10,000km 이하
10,000km 초과 12,000km 이하
12,000km 초과 15,000km 이하
15,000km 초과
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
적용보험료 × 보험증권에 기재된 정산율
없음
<별표> 보험료 정산금액
주) 적용보험료에서 긴급출동서비스 특약 보험료는 제외됩니다.
(*1) ‘운행정보 확인장치(OBD: On Board Diagnostic)’란 피보험자동차의 주행거리를 포함한 운행정보를 저장하
   고 그 정보를 전송할 수 있는 기능을 갖춘 장치로서 보험개발원 부설 자동차기술연구소의 기술인증을 부여받
   은 장치를 말합니다.
174
175
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (90, 1, 90, '②  보험회사(이하 ‘회사’라 함)는 ''보험계약자 또는 피보험자''(이하 ‘보험계약자 등’이라 함)가 다음에 해당하는 경
  우 가입을 제한할 수 있습니다.
 1)  OBD를 조작하는 등 운행정보를 지어내서 보험료를 할인받거나 환급받은 경우
 2)  승용차요일제 특별약관에 의해 보험료 추가 징수 사유가 발생했으나 보험료를 돌려주지 않은 경우
③  회사는 이 특별약관의 체결 후 위 ‘②’의 사실을 알게 된 경우 안 날부터 1개월 이내에 이 특별약관의 계약을 취
  소할 수 있습니다.
④  회사는 다음에 해당하는 경우에는 의무보험의 보험기간 중도에 가입을 제한할 수 있습니다.
 1.  중도 가입 이전에 이 특별약관을 해지한 가입자로서 특약 가입기간 동안의 운행정보를 전송하지 않은 경우
 2.  중도 가입 이전에 이 특별약관을 해지한 가입자로서 특약 가입기간 동안 비운행 약정요일에 1회 이상 운행한 
   사실이 있는 경우
 3.  중도 가입 이전에 이 특별약관을 3회 이상 해지한 가입자
2. 특별약관 계약 전 알릴 의무  
①  보험계약자 등은 책임개시일부터 7일 이내에 OBD를 부착하고 책임개시일부터 15일 이내에 피보험자동차의 
  차량정보, OBD의 모델명, 제품식별번호 및 그 밖에 회사가 요구하는 사항을 회사가 정하는 방법에 따라 전송해
  야 합니다. 
② 책임개시일부터 15일 이전까지 위 ‘①’의 정보를 전송하지 않은 경우에는 이 특별약관은 성립하지 않습니다.
3. 운행정보의 전송 등 보험계약자 또는 피보험자의 의무사항  
①  보험계약자 등은 전체 운행정보가 정상적으로 저장될 수 있도록 피보험자동차에 OBD를 부착하여야 합니다.
②  보험계약자 등은 이 특별약관 보험기간 만료일로부터 1개월 이내에 회사가 정하는 방식에 따라 보험기간 첫날
  부터 만료일까지의 운행정보를 전송해야 합니다. 다만, OBD 부착일이 보험기간 첫날 이후인 경우에는 부착일
  로부터 만료일까지의 운행정보를 전송해야 합니다.
③  보험기간 중에 피보험자동차가 교체(대체)된 경우에는 교체(대체)된 날(보통약관 제49조에 따라 회사가 승인
  한 날을 말함)부터 7일 이내에 위 ‘2.’에 따라 정보를 전송해야 합니다.
④  보험기간 중에 OBD를 교체할 경우에는 교체 이전에 기존 OBD에 저장된 정보를 회사가 정하는 방식에 따라 지
  체 없이 전송해야 하며, 기존 OBD를 분리한 날부터 7일 이내에 교체한 OBD의 정보를 이 특별약관 위 ‘2.의 ①’
  에 따라 전송해야 합니다.
⑤  보험계약자 등은 비운행 약정요일에 사고가 발생지식102)하여 회사로부터 운행정보를 전송할 것을 요청받은 경우
  에는 요청받은 날부터 7일 이내에 정보를 전송해야 하며, 운행정보를 전송하지 않는 경우 비운행 약정요일에 운
  행 중 사고로 봅니다.
4. 특별약관의 무효 
보험계약자가 위 ‘3.의 ②’의 정보 전송 시, 피보험자동차가 아닌 다른 자동차의 정보를 송부한 경우에는 이 특별약
관은 무효로 됩니다.
5. 보험회사의 보험계약 해지 
회사는 보험계약자 등이 ‘3.의 ③’에 따라 전송해야 하는 운행정보를 기한까지 송부하지 않은 경우에는 이 특별약관
을 해지할 수 있습니다.  
6. 보험료 정산 환급 등 
①  회사는 ‘3.의 ②’에 따라 받은 운행정보를 지체 없이 확인하여 다음 <별표>의 특별약관 계약기간별 비운행 약정
  요일 운행 일수에 해당할 경우에는 운행정보를 받은 날부터 10일 이내에 보험계약자 명의의 은행계좌로 보험료 
  정산금액을 송금하여 드립니다.
특별약관 계약기간
비운행 약정요일 운행 일수
보험료 정산 금액
1년 이상
6개월 이상 1년 미만
6개월 미만
3일 이하
2일 이하
1일 이하
적용보험료(긴급출동서비스 특약 보험료 제외) 
X 보험증권에 기재된 정산율
<별표>
(*1)  ‘친환경부품수리’란 보험개발원이 인정한 업체로부터 다음의 친환경부품을 공급받아 자동차를 수리한 경우를 
말합니다.
   (1) 중고부품 : 사이드 미러, 프론트 팬더, 본네트, 라디에이터 그릴, 프론트 도어, 리어 도어, 트렁크 판넬, 프
     론트 범퍼, 리어 범퍼, 백 도어, 리어 피니셔, 쿨러 콘덴서, 테일 램프, 헤드 램프, 안개등, 룸미러(하이패스 
1. 가입대상  
이 특별약관은 보통약관의 대물배상(또는 대물배상 가입금액 확장담보 특별약관, 이하 동일)에 가입하거나 자기차
량손해에 가입한 경우 적용됩니다.
2. 보상내용  
①  회사는 보통약관 대물배상, 자기차량손해 또는 차량단독사고 보장 특별약관에서 보험금이 지급되는 사고로 친
  환경부품수리(*1)를 한 경우에는 새 부품가격(*2)의 20%에 해당하는 금액을 피보험자에게 지급하여 드립니다.
6⃞  친환경부품 사용 특별약관
다만, 의무보험 가입기간 중도에 이 특별약관 해지한 경우 등 보험기간이 만료되기 이전에 운행정보를 전송한 경우
에는 의무보험 가입기간 만료일로부터 10일 이내에 송금하여 드립니다.
② 위 ‘①’에서 10일을 초과하여 송금하는 경우에는 그 초과기간 동안의 이자금액(보험개발원이 공시한 보험계약
  대출이율)을 더하여 지급합니다. 다만, 피보험자, 손해배상청구권자 등에게 책임이 있는 사유로 지급이 지연된 
  때에는 해당 기간에 대한 이자는 더하여 드리지 않습니다.
③  위 ‘①’에도 불구하고 다음 중 하나의 경우에는 보험료 정산금액을 지급하지 않습니다. 
 1)  이 특별약관 가입기간이 3개월 미만인 경우
 2)  비운행 약정요일에 피보험자동차를 운행한 일수가 위 ‘①’의 <별표>에서 규정한 특별약관 계약기간별 운행일
   수를 초과한 경우
④  비운행 약정요일이 다음의 기간 내에 속한 경우에는 피보험자동차를 운행하지 않은 것으로 봅니다.
 1)  위 ‘3.의 ③, ④’에서 규정하고 있는 7일
  2)  회사에 책임이 있는 사유로 운행정보를 확인할 수 없는 경우에 해당 기간
⑤  비운행 약정요일이 다음의 기간 내에 속한 경우에는 피보험자동차를 운행한 것으로 봅니다.
 1) 운행정보를 전송하지 않았거나, 지연 전송하는 등 보험계약자 등에게 책임 있는 사유로 운행정보를 확인할 수 
   없는 경우에 해당기간
   2)  OBD의 불량, 오작동, 운행정보의 훼손 등으로 운행정보를 확인할 수 없는 경우에 해당 기간 
   3)  비운행 약정요일에 OBD가 부착되지 않은 경우  
 4)  위 ‘3.의 ③, ④’에서 규정하고 있는 기일을 초과하여 정보를 전송한 경우, 초과한 날부터 정보를 전송한 날까
   지의 기간 중 운행정보 확인이 불가능한 해당 기간
⑥ 보험계약자는 위 ‘①’의 은행계좌 번호가 변경되거나 거래 정지된 경우에는 지체 없이 회사에 알려야 합니다.
7. 비운행 약정요일의 변경 
비운행 약정요일은 보험기간 중 2회만 변경할 수 있으며, 변경하고자 하는 날부터 7일 이전에 회사에 신청해야 합
니다.  
8. 준용규정 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
102) 피보험자가 비운행 약정요일에 운행을 하다가 발생한 사고에 대해서는 보통약관 및 특별약관에 의하여 보장합니다.
176
177
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (91, 1, 91, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
7⃞  이동통신단말장치 활용 안전운전 UBI 특별약관
1. 가입대상  
①  이동통신단말장치 활용 안전운전 UBI(*1) 특별약관(이하 ‘특별약관’이라 함)은 기명피보험자가 본인명의의 이
동통신단말장치(이하 ‘단말기’라 함)에 보험회사(이하 ‘회사’라 함)가 인정하는 안전운전프로그램(*2)을 설치하
여 사용하는 경우에 한정하여 가입할 수 있습니다. (단, 지정운전자 1인 한정운전 특별약관을 가입한 경우에는 
제외)
(*1) ‘UBI’란 Usage Based Insurance의 줄임말로 ‘운전자 운전습관 기반의 보험’을 뜻합니다.
(*2) ‘안전운전프로그램’이란, 단말기 또는 회사와 제휴한 업체의 차량용 블랙박스에 장착한 위성위치확인시스템과 
   연동된 단말기 등에서 구현되는 안전운전 관련 프로그램으로서 특별약관 가입시점에 회사가 인정하는 네비게
   이션 프로그램 등을 말합니다.
3. 피보험자의 범위  
이 특별약관에서 피보험자는 사고 유형별로 다음과 같습니다.
 1) 자기차량손해 및 차량단독사고 보장 특별약관 사고 : 기명피보험자
 2) 대물배상 사고 : 대물배상 대상차량의 소유자
4. 보상하지 않는 손해  
회사는 보통약관 제5조/8조/14조/19조/23조(이상 “보상하지 않는 손해”)에서 정하는 사항 외에도 다음과 같은 
손해도 보상하지 않습니다.
 1)  보험증권에 기재된 운전가능범위 외의 자가 피보험자동차를 운전하던 중 생긴 사고로 인한 손해
 2)  보험개발원이 인정하지 않은 업체로부터 친환경부품을 공급받아 피보험자동차 또는 대물배상 대상차량을 수
   리한 경우 새 부품가격과의 차액
 3)  이 특별약관에서 정하지 않은 친환경부품을 공급받아 피보험자동차를 수리한 경우 새 부품가격과의 차액
 4)  이 특별약관에서 정한 친환경부품을 공급할 수 없는 경우 또는 공급기일 지연 등의 사유로 보험회사가 새 부
   품으로 수리가 필요하다고 판단하는 경우
 5)  친환경부품 사용 시 지급되는 보험금(이 특별약관에 의한 보험금을 포함)이 다음 중 하나에 해당하는 금액을 
   초과하는 경우
  ㉮ 대물배상에서 해당 대물배상 대상차량의 중고시세
  ㉯ 자기차량손해 및 차량단독사고 보장 특별약관에서 보험가액(보험가액이 보험가입금액보다 클 경우는 보험
    가입금액)
5. 보험금의 반환  
① 보통약관 제4조/7조/22조(이상 “피보험자”)에서 정한 피보험자가 청구포기 등의 사유로 보통약관 대물배상 
  또는 자기차량손해 및 차량단독사고 보장 특별약관의 보험금 전액을 회사에 돌려줄 경우 이 특별약관에 따라 지
  급받은 금액도 동시에 돌려주어야 합니다.
②  친환경부품수리를 했지만 친환경부품의 결함 등으로 이미 사용한 친환경부품을 새 부품으로 다시 교체하는 경
  우에는 이 특별약관에서 지급한 금액을 회사에 돌려주어야 합니다.
6. 준용규정  
이 특별약관에서 정하지 않는 사항은 보통약관을 따릅니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
103) 안전운전프로그램을 작동하고 주행한 경우 산정한 운전습관 점수로서 최대 3,000Km까지 주행한 거리를 기준으로 운전
   습관 점수를 누적 평가합니다.
3. 계약자 등의 의무사항  
① 계약자 등은 특별약관 가입 시 점수의 확인을 위해 회사가 정한 방법에 따른 본인인증을 하여야 하며, 그 밖의 
  특별약관의 가입 및 적용을 위해 요청하는 사항에 협조해야 합니다.
② 위 ‘①’의 규정에 따르지 않을 경우 특별약관의 가입이 승인되지 않거나, 보험료 할인이 적용되지 않을 수 있습
  니다.
4. 계약의 무효 및 해지  
① 회사가 확인한 점수가 기명피보험자 본인의 점수가 아닌 경우, 이 특별약관은 무효가 됩니다. 
② 회사는 계약자 등이 다음 중 하나에 해당하는 경우, 이 특별약관을 해지합니다. 단, 회사가 인정하는 경우에는 
  해지하지 않을 수 있습니다. 
 1) 보험기간 중 안전운전프로그램을 해지 또는 탈퇴하는 경우
 2) 회사와 제휴한 업체의 차량용 블랙박스에 장착한 위성위치확인시스템의 고장, 파손, 탈착 등으로 인하여 안전
   운전점수 산출이 불가능한 경우
 3) 보험기간 중 위 ‘1.’의 본인명의의 단말기 전화번호 또는 단말기 기기를 변경하는 경우
 4)  보험기간 중 번호이동을 하여 이동통신사업자를 변경하는 경우
 5) 보험기간 중 기명피보험자 1인 한정운전 특별약관 또는 부부 운전자 한정운전 특별약관이 아닌 다른 한정운
   전 특별약관으로 변경하는 경우
③ 위 ‘①’에 따라 무효가 되거나, ‘②’에 따라 해지되는 경우, 계약자 등은 해당 점수를 바탕으로 한 보험료 할인금
  액을 즉시 회사에 돌려주어야 합니다. 피보험자동차의 사고로 보험금을 지급하는 경우, 회사는 위 ‘① 또는 ②’
  에 따라 계약자 등이 보험회사에 돌려줄 보험료를 피보험자에게 지급할 보험금에서 공제하고 지급할 수 있습니
  다.
5. 기타 사항  
① 회사는 점수 산정을 위한 안전운전프로그램의 데이터 수집 및 가공 등에 관여하지 않습니다. 
②  계약자 등은 다음 중 하나에 해당하는 경우에는 할인을 받지 못하는 등, 점수측정 상의 불이익을 받을 수 있습니
  다.
 1) 피보험자동차가 아닌 다른 차량 또는 다른 교통수단에서 안전운전프로그램을 활용하는 경우
(*1) ‘안전운전점수’란 안전운전프로그램에서 규정한 방식지식103) 에 따라 산정되는 점수로서 기명피보험자의 점수
   를 말합니다.
②  보험계약 시 안전운전프로그램은 한 가지만 선택이 가능합니다.
③ 회사는 보험계약자 및 기명피보험자(이하 ‘계약자 등’이라 함)가 다음 중 하나에 해당할 경우에는 가입을 제한
  할 수 있습니다.
 1) 특별약관의 무효, 해지, 취소, 철회 등으로 할인받은 보험료를 회사에 돌려주지 않은 사실이 있는 경우
 2) 기명피보험자 본인 명의의 단말기가 아니거나 본인의 점수가 아닌 경우
④ 이 특별약관은 회사와 안전운전프로그램 회사 간의 제휴사업계약에 따른 것으로서, 해당 제휴사업계약이 종료
  되어 회사가 인정하는 점수가 없는 경우 가입할 수 없습니다.
⑤ 이 특별약관은 커넥티드카 안전운전 UBI 특별약관을 가입한 경우에는 가입할 수 없습니다.
2. 보험료의 할인  
① 회사는 특별약관 가입 시점에 안전운전점수(*1)(이하 ‘점수’라 함)를 확인하여 점수가 회사가  정한 일정 수준 
  이상인 경우 보험료를 할인하여 드립니다. (단, 회사가 확인한 날을 기준으로 직전 6개월 이내의 1,000Km 이
    상 주행하여 산출된 점수에 한정하며, 긴급출동 서비스 특약 보험료는 할인 제외)
     기능), 전ㆍ후방 센서
    (2) 재제조부품 : 교류발전기, 등속조인트 등 환경친화적 산업구조로의 전환촉진에 관한 법률 제22조194쪽)에 
     의해 품질인증을 받은 재제조부품
(*2)‘새 부품가격’이란 AOS(Areccom On-line System) 內 등록된 부품의 가격을 말합니다.
   * AOS란 보험개발원에서 운영하는 수리비견적 시스템을 말합니다
178
179
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (92, 1, 92, '운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
2. 보상내용  
① 전기차 충전 중 감전 사고 손해
   보험회사(이하 ‘회사’라 함)는 보통약관 자기신체손해(자동차상해 Family 통합보장 특별약관 및 자동차상해 
특별약관을 포함)를 가입한 경우에 한정하여, 피보험자가 전기자동차 충전설비(*1)를 이용하여 피보험자동차를 
충전하던 중(*2), 이로 인한 감전 사고로 치료를 요하는 상해(*3)를 입은 때의 손해를 보통약관 자기신체사고, 자
동차상해 Family 통합보장 특별약관 또는 자동차상해 특별약관에 따라 보상하여 드립니다.
② 전기자동차 화재 사고 시 대물 보장확대
 1)  보험회사(이하 ‘회사’라 함)는 보험기간 첫날부터 피보험자동차가 최초차량등록일을 기준으로 5년 이내의 차
량인 경우에 한정하여, 보통약관 대물배상 또는 대물배상 가입금액 확장담보 특별약관에서 보험금이 지급되는 
피보험자동차의 화재 사고로 인한 손해로 피보험자에게 법률상 손해배상책임이 생긴 때에는 보통약관 대물배
상 또는 대물배상 가입금액 확장담보 특별약관의 가입금액에도 불구하고, 이 특별약관에 의하여 위 가입금액
의 200% 한도로 확대하여 보상하여 드립니다.
 2)  위 ‘1)’에도 불구하고, 사고당 보통약관 대물배상 또는 대물배상 가입금액 확장담보 특별약관 보험금과 이 특
별약관 보험금의 합계는 보험증권에 기재된 보통약관 대물배상 또는 대물배상 가입금액 확장담보 특별약관 가
입금액의 200%를 초과할 수 없습니다.
(*1) ‘전기자동차 충전설비’란 해당 전기자동차의 정격의 휴대용 충전기(또는 가정용 충전기기 및 장치), 거주지 혹
   은 공공장소 등에 설치된 전기자동차 전용 완속충전기 및 급속충전기를 말합니다. 
(*2) ‘피보험자동차를 충전하던 중’ 이란 피보험자동차의 충전을 위하여 충전설비를 조작한 시점부터 충전 완료까
   지의 과정을 말합니다. 이와 관련하여 피보험자동차와 충전설비의 접촉 여부는 무관합니다.
(*3) ‘치료를 요하는 상해’란 감전을 직접적인 원인으로 발생한 화상 및 신체조직의 괴사, 심혈관계, 신경계, 근골격
   계 등의 상해로서, 의학적 치료를 필요로 한다는 점을 뒷받침할 수 있는 요양기관의 의학적 소견이 있는 경우 
   만을 말합니다. 
3. 보상하지 않는 손해  
회사는 보통약관 제8조/14조(이상 “보상하지 않는 손해”)에서 정하는 사항은 보상하지 않고, 또한 보험증권에 기
재된 운전가능범위 외의 자가 운전하던 중 생긴 사고도 보상하지 않습니다.
4. 대위
회사는 피보험자에게 보험금을 지급한 경우, 지급한 보험금 한도 내에서 제3자에 대한 피보험자의 권리를 취득합니
다. 다만, 회사가 보상한 금액이 피보험자의 손해의 일부를 보상한 경우에는 피보험자의 권리를 침해하지 않는 범위
에서 그 권리를 취득합니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
9⃞  주행거리 환급금 갱신 대체납입 특별약관
1. 가입대상  
이 특별약관은 주행거리 후할인 특별약관을 가입한 경우에 한해 가입할 수 있습니다.
2. 보험료의 정산 및 납입대체에 관한 사항 (특약의 내용)  
이 보험계약의 주행거리 후할인 특별약관 ‘3. ②’의 규정에도 불구하고, 보험계약자 또는 피보험자가 이 보험계약의 
보험기간 만료일 이전까지 회사가 정하는 주행거리 확인방법에 따라 피보험자동차의 최종 주행거리 정보를 회사로 
보낸 경우, 회사는 송부 받은 주행거리정보를 확인하여 연간 주행거리 실적에 따른 보험료 정산금액이 있는 경우 정
산금액 전액을 갱신계약(*1)의 보험료에서 차감하여 드립니다.
(*1) ‘갱신계약’이란 이 보험계약과 다음 보험계약의 보험계약자가 동일한 계약으로서, 이 보험계약의 보험기간 만
   료일이 다음 보험계약의 보험기간 시작일과 일치하는 동일한 보험회사의 계약을 말합니다.
3. 특약의 적용제외  
회사는 다음의 경우 이 특별약관을 적용하지 않습니다.
① 보험계약자가 주행거리 후할인 특별약관의 보험료 정산금액을 보험계약자 명의의 은행계좌 또는 신용카드로 
  지급받기를 요청한 경우
② 회사의 사정으로 ‘2. 보험료의 정산 및 납입대체에 관한 사항’을 적용할 수 없는 경우
4. 특약의 무효  
보험계약자가 이 보험계약의 갱신계약을 회사와 체결하지 않는 경우 해당 특약의 효력은 상실됩니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
[10]  커넥티드카지식104) 할인 특별약관
1. 가입대상  
①  이 특별약관은 피보험자동차의 사고 및 긴급상황 발생정보를 보험회사(이하 “회사”라 함) 또는 자동차제조사
에 통보하는 장치(이하 “사고통보장치”라 함)가 피보험자동차에 장착되고 자동차제조사와의 무선통신계약이 
유효한 상태에서 <용어풀이> ‘2)’에서 규정하는 기능이 상시 작동되는 경우에 한하여 가입할 수 있습니다.
②  회사는 이 특별약관의 가입일부터 과거 3년 이내에 다음에 해당하는 경우에는 이 특별약관의 가입을 제한할 수 
있습니다.
 1)   이 특별약관에 의해 할인 받은 보험료의 추징사유가 발생하였으나, 해당 보험료를 회사에 반환하지 않은 사실
이 있는 경우
 2)   회사가 사고통보장치의 장착을 확인하기 위하여 이 특별약관 ‘2. 특별약관 계약 전 알릴의무’의 규정에 따라 
요청한 사항을 제출하지 않거나, 허위 또는 조작하여 제출한 사실이 있는 경우
104) “커넥티드카”란 자동차 출고 시 장착된 단말기를 활용하여 실시간으로 자동차의 사고 및 운행정보를 주고받을 수 있는 
차량을 말합니다. (Benz : Mercedes me Connect, BMW : ConnectedDrive, 현대자동차 : BlueLink(또는 Genesis 
Connected), 기아자동차 : UVO)
8⃞  전기자동차 특별약관
1. 적용대상  
이 특별약관은 피보험자동차가 법정승차정원 10인승 이하의 전기자동차(*1)인 경우에 자동 적용됩니다.
(*1)  ‘전기자동차’란 사용연료의 종류가 전기인 자동차로서 「환경친화적자동차의 개발 및 보급촉진에 관한 법률」 제
2조 제3호 및 제6호에 해당하는 자동차를 말합니다.(제2조 제4호 태양광자동차 및 제2조 제5호 하이브리드 자
동차는 제외)
 2) 타인이 기명피보험자의 단말기를 사용하여 안전운전프로그램을 작동한 상태로 운전하도록 하는 경우
6. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다.
180
181
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (93, 1, 93, '2. 특별약관 계약 전 알릴의무
이 특별약관을 가입하고자 하는 보험계약자 또는 피보험자는 개인정보처리 동의를 하거나 자동차제조사가 발행한 
증빙서류를 제출하는 등 위 ‘1. 가입대상’ 확인을 위해 회사가 요구하는 사항에 대하여 협조해야 합니다.
3. 보험계약자 또는 피보험자의 의무사항
①  보험계약자 또는 피보험자는 사고통보장치가 상시 정상적으로 작동될 수 있도록 유지 및 관리하여야 합니다.
②  보험계약자 또는 피보험자는 보험기간 중에 피보험자동차의 사고통보장치가 정상적으로 작동하지 않는 경우에
는 이 사실을 회사에 알려야 합니다. 이 경우 보험계약자 또는 피보험자는 보험가입 시 이 특별약관에 의해 할인 
받은 보험료 중 경과되지 않은 기간에 대하여 일할로 계산한 보험료를 회사에 반환하여야 합니다.
③  피보험자동차의 소유䞱사용䞱관리 중 사고로 인해 회사에 보험금을 청구할 경우 회사는 자동차제조사에 수집된 
사고당시 차량운행정보의 확인을 요청할 수 있습니다. 이 경우 보험계약자 또는 피보험자는 이의 확인에 협조하
여야 합니다.
4. 특별약관 계약의 취소
회사는 다음 중 어느 하나에 해당하는 경우 그 사실을 안 날부터 1개월 이내에 이 특별약관을 취소할 수 있습니다. 
이 경우 보험계약자 또는 피보험자는 이 특별약관에 의해 할인 받은 보험료를 회사에 반환하여야 합니다.
①  위 ‘1. 가입대상’의 ‘2)’에 해당하는 경우
②  보험기간 중에 보험계약자 또는 피보험자가 피보험자동차의 사고통보장치가 정상적으로 작동하지 않은 경우에 
그 사실을 회사에 알리지 않은 경우
③  보험기간 중에 보험계약자 또는 피보험자가 사고와 관련된 차량운행정보의 확인에 협조하지 않은 경우
5. 특별약관 계약의 무효
보험계약자 또는 피보험자가 위 ‘2. 특별약관 계약 전 알릴의무’를 이행하지 않거나 사실과 다르게 알린 경우 이 특
별약관은 무효가 되며, 보험계약자 또는 피보험자는 보험가입 시 이 특별약관에 의해 할인받은 보험료를 회사에 반
환하여야 합니다.
6. 보험금 공제 지급
피보험자동차의 사고로 보험금을 지급하는 경우 회사는 위 ‘3.’ 내지 ‘5.’에 따라 보험계약자 또는 피보험자가 회사
에 반환할 보험료를 피보험자에게 지급할 보험금에서 이를 공제하고 지급할 수 있습니다.
7. 준용규정
이 특별약관에서 정하지 않은 사항은 보통약관에 따릅니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
[11]  커넥티드카 안전운전 UBI 특별약관
1. 가입대상  
①  이 특별약관의 가입 시점에 커넥티드카 할인 특별약관을 가입하고, 자동차제조사가 피보험자동차의 운행기록
을 분석하여 생성한 안전운전점수(*1)(이하 ‘점수’라 함)가 보험회사(이하 “회사”라 함)가 정한 기준 이상인 경
우 가입할 수 있습니다.
②  회사는 다음에 해당하는 경우에는 이 특별약관의 가입을 제한할 수 있습니다.
 1)  이 특별약관에 의해 할인 받은 보험료의 추징사유가 발생하였으나, 해당 보험료를 회사에 반환하지 않은 사실
이 있는 경우
 2)  회사와 제휴한 안전운전점수 제공 회사와의 계약이 종료되어 회사가 인정하는 점수가 없거나, 시스템 오류로 
안전운전점수 조회가 불가능한 경우
③  이 특별약관은 이동통신단말장치 활용 안전운전 UBI 특별약관을 가입한 경우에는 가입할 수 없습니다.
(*1)  이 특별약관에서 ‘안전운전점수’라 함은 자동차제조사가 피보험자동차 운행기록을 분석하여 생성한 운전습관 
점수를 말하며, 안전운전점수 확인일 직전 90일 이내 1,000km 이상 주행하여 산정된 점수에 한합니다.
운전가능자에 대한 제한
자기신체사고의 확대
자기차량손해의 확대
무보험자동차에 의한 손해
사고처리시 소요되는 비용
긴급출동 서비스
보험료 납입
기타
녹색상품
2. 보험료의 할인  
회사는 확인된 안전운전점수가 회사가 정한 일정 수준 이상인 경우 보험료를 할인하여 드립니다.
3. 계약자 등의 의무사항  
①  계약자 등은 이 특별약관 가입 시 점수의 확인을 위해 회사가 정한 방법에 따른 개인정보처리 동의 및 본인인증
을 하여야 하며, 그 밖의 특별약관의 가입 및 적용을 위해 요청하는 사항에 협조해야 합니다.
②  위 ‘①’의 규정에 따르지 않을 경우 이 특별약관의 가입이 승인되지 않거나, 보험료 할인이 적용되지 않을 수 있
습니다.
4. 계약의 무효  
①  회사가 확인한 안전운전점수가 피보험자동차의 운행기록에 근거한 점수가 아닌 경우 또는 사실과 다르게 안전
운전점수를 알린 경우 이 특별약관은 무효가 됩니다.
②  위 ‘①’의 경우 보험계약자 또는 피보험자는 이 특별약관에 의해 할인 받은 보험료를 회사에 반환하여야 합니다.
③  피보험자동차의 사고로 보험금을 지급하는 경우 위 ‘②’에 따라 보험계약자 또는 피보험자가 회사에 반환할 보
험료를 피보험자에게 지급할 보험금에서 이를 공제하고 지급할 수 있습니다.
5. 준용규정  
이 특별약관에서 정하지 않은 사항은 보통약관에 따릅니다.
이 특별약관에서 “사고통보장치”라 함은 다음 각 호의 조건을 모두 만족하는 장치를 말합니다.
 1)   차량 출고 시 자동차제조사의 표준장치 또는 옵션으로 장착된 장치(휴대전화 등에 애플리케이션(응용프로그
램)을 탑재하여 사용되는 장치는 해당되지 않음)
 2)   피보험자동차의 시동을 켠 상태에서는 무선통신을 기반으로 아래의 기능이 상시 작동되어 자동차제조사로 송
신䞱수집되며, 자동차제조사와의 무선통신계약을 해지하지 않는 한 임의로 작동을 중지할 수 없는 장치
  가.   에어백이 전개되는 사고 발생 시 자동송신 기능
  나.   차량운행정보(운행시간, 운행속도 등) 저장 등
 3)   피보험자동차의 에어백이 전개되는 사고발생 정보가 자동차제조사 또는 회사에 자동으로 통보됨으로서 신속
한 응급조치가 가능할 것
182
183
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (94, 1, 94, '약관 조항에 언급된 관련된 법령내용의 중요한 일부내용을 찾아보기 쉽도록 
아래에 모아서 기재하였습니다. 
전체 원문은 국가법령정보센터(http://www.law.go.kr)에서 확인할 수 있습니다. 
만약 관련법령이 개정 되었다면 개정된 법령내용을 따릅니다.
법령 조문체계의 표기법과 읽는 법을 참고하세요!
개인정보보호법
자동차보험 약관 - 법조문
ㄱ
제15조 (개인정보의 수집ㆍ이용) 
① 개인정보처리자는 다음 각 호의 어느 하나에 해당하는 경우에는 개인정보를 수집할 수 있으며 그 수집 목적의 범
  위에서 이용할 수 있다.
 1. 정보주체의 동의를 받은 경우
 4.  정보주체와의 계약의 체결 및 이행을 위하여 불가피하게 필요한 경우
②  개인정보처리자는 제1항제1호에 따른 동의를 받을 때에는 다음 각 호의 사항을 정보주체에게 알려야 한다. 다음 
  각 호의 어느 하나의 사항을 변경하는 경우에도 이를 알리고 동의를 받아야 한다.
 1.  개인정보의 수집ㆍ이용 목적
 2.  수집하려는 개인정보의 항목
 3.  개인정보의 보유 및 이용 기간
 4.  동의를 거부할 권리가 있다는 사실 및 동의 거부에 따른 불이익이 있는 경우에는 그 불이익의 내용
제17조 (개인정보의 제공)  
①  개인정보처리자는 다음 각 호의 어느 하나에 해당되는 경우에는 정보주체의 개인정보를 제3자에게 제공(공유를 
  포함한다. 이하 같다)할 수 있다.
 1.  정보주체의 동의를 받은 경우
 2.  제15조 제1항 제2호䞱제3호 및 제5호에 따라 개인정보를 수집한 목적 범위에서 개인정보를 제공하는 경우
②  개인정보처리자는 제1항 제1호에 따른 동의를 받을 때에는 다음 각 호의 사항을 정보주체에게 알려야 한다. 다
  음 각 호의 어느 하나의 사항을 변경하는 경우에도 이를 알리고 동의를 받아야 한다.
 1.  개인정보를 제공받는 자
 2.  개인정보를 제공받는 자의 개인정보 이용 목적
 3.  제공하는 개인정보의 항목
 4.  개인정보를 제공받는 자의 개인정보 보유 및 이용 기간
 5.  동의를 거부할 권리가 있다는 사실 및 동의 거부에 따른 불이익이 있는 경우에는 그 불이익의 내용
제22조 (동의를 받는 방법)  
①  개인정보처리자는 이 법에 따른 개인정보의 처리에 대하여 정보주체(제5항에 따른 법정대리인을 포함한다. 이
  하 이 조에서 같다)의 동의를 받을 때에는 각각의 동의 사항을 구분하여 정보주체가 이를 명확하게 인지할 수 있
  도록 알리고 각각 동의를 받아야 한다.
⑤  개인정보처리자는 정보주체가 제2항에 따라 선택적으로 동의할 수 있는 사항을 동의하지 아니하거나 제3항 및 
  제18조 제2항 제1호에 따른 동의를 하지 아니한다는 이유로 정보주체에게 재화 또는 서비스의 제공을 거부하여
  서는 아니 된다.
제23조 (민감정보의 처리 제한)  
개인정보처리자는 사상ㆍ신념, 노동조합ㆍ정당의 가입ㆍ탈퇴, 정치적 견해, 건강, 성생활 등에 관한 정보, 그 밖에 
정보주체의 사생활을 현저히 침해할 우려가 있는 개인정보로서 대통령령으로 정하는 정보(이하 “민감정보”라 한
다)를 처리하여서는 아니된다. 다만, 다음 각 호의 어느 하나에 해당하는 경우에는 그러하지 아니하다.
 1.  정보주체에게 제15조 제2항 각 호 또는 제17조 제2항 각 호의 사항을 알리고 다른 개인정보의 처리에 대한 동
   의와 별도로 동의를 받은 경우
 2.  법령에서 민감정보의 처리를 요구하거나 허용하는 경우
법조문
184
185
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (95, 1, 95, '제24조 (고유식별정보의 처리 제한)  
①  개인정보처리자는 다음 각 호의 경우를 제외하고는 법령에 따라 개인을 고유하게 구별하기 위하여 부여된 식별
  정보로서 대통령령으로 정하는 정보(이하 “고유식별정보”라 한다)를 처리할 수 없다.
 1.  정보주체에게 제15조제2항 각 호 또는 제17조 제2항 각 호의 사항을 알리고 다른 개인정보의 처리에 대한 동
   의와 별도로 동의를 받은 경우
 2.  법령에서 구체적으로 고유식별정보의 처리를 요구하거나 허용하는 경우
③  개인정보처리자가 제1항 각 호에 따라 고유식별정보를 처리하는 경우에는 그 고유식별정보가 분실ㆍ도난ㆍ유
  출ㆍ위조ㆍ변조 또는 훼손되지 아니하도록 대통령령으로 정하는 바에 따라 암호화 등 안전성 확보에 필요한 조
  치를 하여야 한다
제24조의 2 (주민등록번호 처리의 제한)  
①  제24조 제1항에도 불구하고 개인정보처리자는 다음 각 호의 어느 하나에 해당하는 경우를 제외하고는 주민등록
  번호를 처리할 수 없다.
 1.  법률ㆍ대통령령ㆍ국회규칙ㆍ대법원규칙ㆍ헌법재판소규칙ㆍ중앙선거관리위원회규칙 및 감사원규칙에서 구
   체적으로 주민등록번호의 처리를 요구하거나 허용한 경우
 2.  정보주체 또는 제3자의 급박한 생명, 신체, 재산의 이익을 위하여 명백히 필요하다고 인정되는 경우
 3.  제1호 및 제2호에 준하여 주민등록번호 처리가 불가피한 경우로서 보호위원회가 고시로 정하는 경우
②  개인정보처리자는 제24조 제3항에도 불구하고 주민등록번호가 분실ㆍ도난ㆍ유출ㆍ위조ㆍ변조 또는 훼손되지 
  아니하도록 암호화 조치를 통하여 안전하게 보관하여야 한다. 이 경우 암호화 적용 대상 및 대상별 적용 시기 등
  에 관하여 필요한 사항은 개인정보의 처리 규모와 유출 시 영향 등을 고려하여 대통령령으로 정한다.
③  개인정보처리자는 제1항 각 호에 따라 주민등록번호를 처리하는 경우에도 정보주체가 인터넷 홈페이지를 통하
  여 회원으로 가입하는 단계에서는 주민등록번호를 사용하지 아니하고도 회원으로 가입할 수 있는 방법을 제공
  하여야 한다.
④  보호위원회는 개인정보처리자가 제3항에 따른 방법을 제공할 수 있도록 관계 법령의 정비, 계획의 수립, 필요한 
  시설 및 시스템의 구축 등 제반 조치를 마련ㆍ지원할 수 있다.
교통사고처리특례법
금융소비자보호법
제4조 (보험 등에 가입된 경우의 특례)   
①  교통사고를 일으킨 차가 「보험업법」 제4조, 제126조, 제127조 및 제128조, 「여객자동차 운사업법」 제60조, 
  제61조 또는 「화물자동차 운수사업법」 제51조에 따른 보험 또는 공제에 가입된 경우에는 제3조 제2항 본문에 
  규정된 죄를 범한 차의 운전자에 대하여 공소를 제기할 수 없다. 다만, 다음 각 호의 어느 하나에 해당하는경우에
  는 그러하지 아니하다.
 1.  제3조 제2항 단서에 해당하는 경우
 2.  피해자가 신체의 상해로 인하여 생명에 대한 위험이 발생하거나 불구(不具)가 되거나 불치(不治) 또는 난치
   (難治)의 질병이 생긴 경우
(이하 기재생략)
제22조 (계약서류의 제공)    
③  법 제23조 제1항 본문에 따라 금융상품직접판매업자 및 금융상품자문업자가 계약서류를 제공하는 때에는 다음 
  각 호의 방법으로 제공한다. 다만, 금융소비자가 다음 각 호의 방법 중 특정 방법으로 제공해 줄 것을 요청하는 
  경우에는 그 방법으로 제공해야 한다. 
 1.  서면교부
 2.  우편 또는 전자우편
법조문
법조문
 3.  휴대전화 문자메시지 또는 이에 준하는 전자적 의사표시
제19조 (설명의무)    
①  금융상품판매업자등은 일반금융소비자에게 계약 체결을 권유(금융상품자문업자가 자문에 응하는 것을 포함한
  다)하는 경우 및 일반금융소비자가 설명을 요청하는 경우에는 다음 각 호의 금융상품에 관한 중요한 사항(일반
  금융소비자가 특정 사항에 대한 설명만을 원하는 경우 해당 사항으로 한정한다)을 일반금융소비자가 이해할 수 
  있도록 설명하여야 한다.
 1.  다음 각 목의 구분에 따른 사항
  가.  보장성 상품
    1) 보장성 상품의 내용
    2) 보험료(공제료를 포함한다. 이하 같다)
    3) 보험금(공제금을 포함한다. 이하 같다) 지급제한 사유 및 지급절차
    4) 위험보장의 범위
    5) 그 밖에 위험보장 기간 등 보장성 상품에 관한 중요한 사항으로서 대통령령으로 정하는 사항
 3.  제46조에 따른 청약 철회의 기한ㆍ행사방법ㆍ효과에 관한 사항
 4.  그 밖에 금융소비자 보호를 위하여 대통령령으로 정하는 사항
②  금융상품판매업자등은 제1항에 따른 설명에 필요한 설명서를 일반금융소비자에게 제공하여야 하며, 설명한 내
  용을 일반금융소비자가 이해하였음을 서명, 기명날인, 녹취 또는 그 밖에 대통령령으로 정하는 방법으로 확인을 
  받아야 한다. 다만, 금융소비자 보호 및 건전한 거래질서를 해칠 우려가 없는 경우로서 대통령령으로 정하는 경
  우에는 설명서를 제공하지 아니할 수 있다.
③  금융상품판매업자등은 제1항에 따른 설명을 할 때 일반금융소비자의 합리적인 판단 또는 금융상품의 가치에 중
  대한 영향을 미칠 수 있는 사항으로서 대통령령으로 정하는 사항을 거짓으로 또는 왜곡(불확실한 사항에 대하여 
  단정적 판단을 제공하거나 확실하다고 오인하게 할 소지가 있는 내용을 알리는 행위를 말한다)하여 설명하거나 
  대통령령으로 정하는 중요한 사항을 빠뜨려서는 아니 된다.
④  제2항에 따른 설명서의 내용 및 제공 방법ㆍ절차에 관한 세부내용은 대통령령으로 정한다.
제23조 (계약서류의 제공의무)   
①  금융상품직접판매업자 및 금융상품자문업자는 금융소비자와 금융상품 또는 금융상품자문에 관한 계약을 체결
  하는 경우 금융상품의 유형별로 대통령령으로 정하는 계약서류를 금융소비자에게 지체 없이 제공하여야 한다. 
  다만, 계약내용 등이 금융소비자 보호를 해칠 우려가 없는 경우로서 대통령령으로 정하는 경우에는 계약서류를 
  제공하지 아니할 수 있다.
②  제1항에 따른 계약서류의 제공 사실에 관하여 금융소비자와 다툼이 있는 경우에는 금융상품직접판매업자 및 금
  융상품자문업자가 이를 증명하여야 한다.
③  제1항에 따른 계약서류 제공의 방법 및 절차는 대통령령으로 정한다.
제46조 (청약의 철회)  
①  금융상품판매업자등과 대통령령으로 각각 정하는 보장성 상품, 투자성 상품, 대출성 상품 또는 금융상품자문에 
  관한 계약의 청약을 한 일반금융소비자는 다음 각 호의 구분에 따른 기간(거래 당사자 사이에 다음 각 호의 기간
  보다 긴 기간으로 약정한 경우에는 그 기간) 내에 청약을 철회할 수 있다.
 1.  보장성 상품 : 일반금융소비자가 「상법」 제640조에 따른 보험증권을 받은 날부터 15일과 청약을 한 날부터 
   30일 중 먼저 도래하는 기간
②  제1항에 따른 청약의 철회는 다음 각 호에서 정한 시기에 효력이 발생한다.
 1.  보장성 상품, 투자성 상품, 금융상품자문: 일반금융소비자가 청약의 철회의사를 표시하기 위하여 서면(대통령
   령으로 정하는 방법에 따른 경우를 포함한다. 이하 이 절에서 “서면등”이라 한다)을 발송한 때
③  제1항에 따라 청약이 철회된 경우 금융상품판매업자등이 일반금융소비자로부터 받은 금전ㆍ재화등의 반환은 
  다음 각 호의 어느 하나에 해당하는 방법으로 한다.
 1.  보장성 상품 : 금융상품판매업자등은 청약의 철회를 접수한 날부터 3영업일 이내에 이미 받은 금전ㆍ재화등을 
186
187
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (96, 1, 96, '   반환하고, 금전ㆍ재화등의 반환이 늦어진 기간에 대하여는 대통령령으로 정하는 바에 따라 계산한 금액을 더
   하여 지급할 것
④  제1항에 따라 청약이 철회된 경우 금융상품판매업자등은 일반금융소비자에 대하여 청약의 철회에 따른 손해배
  상 또는 위약금 등 금전의 지급을 청구할 수 없다.
⑤ 보장성 상품의 경우 청약이 철회된 당시 이미 보험금의 지급사유가 발생한 경우에는 청약 철회의 효력은 발생하
  지 아니한다. 다만, 일반금융소비자가 보험금의 지급사유가 발생했음을 알면서 청약을 철회한 경우에는 그러하
  지 아니하다.
⑥  제1항부터 제5항까지의 규정에 반하는 특약으로서 일반금융소비자에게 불리한 것은 무효로 한다.
⑦  제1항부터 제3항까지의 규정에 따른 청약 철회권의 행사 및 그에 따른 효과 등에 관하여 필요한 사항은 대통령
  령으로 정한다.
제47조 (위법계약의 해지)  
①  금융소비자는 금융상품판매업자등이 제17조 제3항, 제18조 제2항, 제19조 제1항ㆍ제3항, 제20조 제1항 또는 
  제21조를 위반하여 대통령령으로 정하는 금융상품에 관한 계약을 체결한 경우 5년 이내의 대통령령으로 정하
  는 기간 내에 서면등으로 해당 계약의 해지를 요구할 수 있다. 이 경우 금융상품판매업자등은 해지를 요구받은 
  날부터 10일 이내에 금융소비자에게 수락여부를 통지하여야 하며, 거절할 때에는 거절사유를 함께 통지하여야 
  한다.
②  금융소비자는 금융상품판매업자등이 정당한 사유 없이 제1항의 요구를 따르지 않는 경우 해당 계약을 해지할 
  수 있다.
③  제1항 및 제2항에 따라 계약이 해지된 경우 금융상품판매업자등은 수수료, 위약금 등 계약의 해지와 관련된 비
  용을 요구할 수 없다.
④  제1항부터 제3항까지의 규정에 따른 계약의 해지요구권의 행사요건, 행사범위 및 정당한 사유 등과 관련하여 필
  요한 사항은 대통령령으로 정한다.
제28조 (자료의 기록 및 유지ㆍ관리 등)
①  금융상품판매업자등은 금융상품판매업등의 업무와 관련한 자료로서 대통령령으로 정하는 자료를 기록하여야 
  하며, 자료의 종류별로 대통령령으로 정하는 기간 동안 유지ㆍ관리하여야 한다.
②  금융상품판매업자등은 제1항에 따라 기록 및 유지ㆍ관리하여야 하는 자료가 멸실 또는 위조되거나 변조되지 아
  니하도록 적절한 대책을 수립ㆍ시행하여야 한다.
③  금융소비자는 제36조에 따른 분쟁조정 또는 소송의 수행 등 권리구제를 위한 목적으로 제1항에 따라 금융상품
  판매업자등이 기록 및 유지ㆍ관리하는 자료의 열람(사본의 제공 또는 청취를 포함한다. 이하 이 조에서 같다)을 
  요구할 수 있다.
④  금융상품판매업자등은 제3항에 따른 열람을 요구받았을 때에는 해당 자료의 유형에 따라 요구받은 날부터 10
  일 이내의 범위에서 대통령령으로 정하는 기간 내에 금융소비자가 해당 자료를 열람할 수 있도록 하여야 한다. 
  이 경우 해당 기간 내에 열람할 수 없는 정당한 사유가 있을 때에는 금융소비자에게 그 사유를 알리고 열람을 연
  기할 수 있으며, 그 사유가 소멸하면 지체 없이 열람하게 하여야 한다.
⑤  금융상품판매업자등은 다음 각 호의 어느 하나에 해당하는 경우에는 금융소비자에게 그 사유를 알리고 열람을 
  제한하거나 거절할 수 있다.
 1.  법령에 따라 열람을 제한하거나 거절할 수 있는 경우
 2.  다른 사람의 생명ㆍ신체를 해칠 우려가 있거나 다른 사람의 재산과 그 밖의 이익을 부당하게 침해할 우려가 있
   는 경우
 3.  그 밖에 열람으로 인하여 해당 금융회사의 영업비밀(「부정경쟁방지 및 영업비밀보호에 관한 법률」 제2조 제2
   호에 따른 영업비밀을 말한다)이 현저히 침해되는 등 열람하기 부적절한 경우로서 대통령령으로 정하는 경우
⑥  금융상품판매업자등은 금융소비자가 열람을 요구하는 경우 대통령령으로 정하는 바에 따라 수수료와 우송료
  (사본의 우송을 청구하는 경우만 해당한다)를 청구할 수 있다.
⑦  제3항부터 제5항까지의 규정에 따른 열람의 요구ㆍ제한, 통지 등의 방법 및 절차에 관하여 필요한 사항은 대통
  령령으로 정한다.
법조문
제42조 (소액분쟁사건에 관한 특례)
조정대상기관은 다음 각 호의 요건 모두를 총족하는 분쟁사건(이하 “소액분쟁사건”이라 한다)에 대하여 조정절차
가 개시된 경우에는 제36조 제6항에 따라 조정안을 제시받기 전에는 소를 제기할 수 없다. 다만, 제36조 제3항에 
따라 서면통지를 받거나 제36조 제5항에서 정한 기간 내에 조정안을 제시받지 못한 경우에는 그러하지 아니하다.
 1.  일반금융소비자가 신청한 사건일 것
 2.  조정을 통하여 주장하는 권리나 이익의 가액이 2천만원 이내에서 대통령령으로 정하는 금액 이하일 것
국민기초생활 보장법
제2조 (정의)  
이 법에서 사용하는 용어의 뜻은 다음과 같다.
 2.  “수급자”란 이 법에 따른 급여를 받는 사람을 말한다.
 8.  “소득인정액”이란 개별가구의 소득평가액과 재산의 소득환산액을 합산한 금액을 말한다.
11.  “차상위계층”이란 수급권자(제5조 제2항에 따라 수급권자로 보는 사람은 제외한다)에 해당하지 아니하는 계
   층으로서 소득인정액이 대통령령으로 정하는 기준 이하인 계층을 말한다.
농어업, 농어촌 및 식품산업기본법
ㄴ
제3조 (정의) 
이 법에서 사용하는 용어의 뜻은 다음과 같다.
 2. “농어업인”이란 다음 각 목의 자를 말한다.
  가.  농업인 : 농업을 경영하거나 이에 종사하는 자로서 대통령령으로 정하는 기준에 해당하는 자
  나.  어업인 : 어업을 경영하거나 어업을 경영하는 자를 위하여 수산자원을 포획䞱채취하거나 양식하는 일 또는 
     염전에서 바닷물을 자연 증발시켜 염을 제조하는 일에 종사하는 자로서 대통령령으로 정하는 기준에 해당
     하는 자
도로교통법
ㄷ
제43조 (무면허운전 등의 금지) 
누구든지 제80조에 따라 지방경찰청장으로부터 운전면허를 받지 아니하거나 운전면허의 효력이 정지된 경우에는 
자동차등을 운전하여서는 아니 된다.
제44조 (술에 취한 상태에서의 운전 금지) 
①  누구든지 술에 취한 상태에서 자동차등(「건설기계관리법」 제26조제1항 단서에 따른 건설기계 외의 건설기계를 
  포함한다. 이하 이 조, 제45조, 제47조, 제93조 제1항 제1호부터 제4호까지 및 제148조의2에서 같다), 노면전
  차 또는 자전거를 운전하여서는 아니 된다.
②  경찰공무원은 교통의 안전과 위험방지를 위하여 필요하다고 인정하거나 제1항을 위반하여 술에 취한 상태에서 
  자동차등, 노면전차 또는 자전거를 운전하였다고 인정할 만한 상당한 이유가 있는 경우에는 운전자가 술에 취하
  였는지를 호흡조사로 측정할 수 있다. 이 경우 운전자는 경찰공무원의 측정에 응하여야 한다.
법조문
188
189
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (97, 1, 97, '③  제2항에 따른 측정 결과에 불복하는 운전자에 대하여는 그 운전자의 동의를 받아 혈액 채취 등의 방법으로 다시 
  측정할 수 있다.
④  제1항에 따라 운전이 금지되는 술에 취한 상태의 기준은 운전자의 혈중알코올농도가 0.03퍼센트 이상인 경우로 
  한다.
제45조 (과로한 때 등의 운전 금지) 
자동차등의 운전자는 제44조에 따른 술에 취한 상태 외에 과로, 질병 또는 약물(마약, 대마 및 향정신성의약품과 그 
밖에 행정안전부령으로 정하는 것을 말한다. 이하 같다)의 영향과 그 밖의 사유로 정상적으로 운전하지 못할 우려
가 있는 상태에서 자동차등을 운전하여서는 아니 된다.
제54조 (사고발생시 조치) 
①  차의 운전 등 교통으로 인하여 사람을 사상하거나 물건을 손괴(이하 “교통사고”라 한다)한 경우에는 그 차의 운
  전자나 그 밖의 승무원(이하 “운전자등”이라 한다)은 즉시 정차하여 사상자를 구호하는 등 필요한 조치를 하여
  야 한다.
제148조 (벌칙) 
제54조 제1항에 따른 교통사고 발생 시의 조치를 하지 아니한 사람(주ㆍ정차된 차만 손괴한 것이 분명한 경우에 제
54조 제1항 제2호에 따라 피해자에게 인적 사항을 제공하지 아니한 사람은 제외한다)은 5년 이하의 징역이나 1천
500만원 이하의 벌금에 처한다. 
제148조의 2 (벌칙) 
①  제44조 제1항 또는 제2항을 2회 이상 위반한 사람(자동차등 또는 노면전차를 운전한 사람으로 한정한다. 다만, 
  개인형 이동장치를 운전하는 경우는 제외한다. 이하 이 조에서 같다)은 2년 이상 5년 이하의 징역이나 1천만원 
  이상 2천만원 이하의 벌금에 처한다.
②  술에 취한 상태에 있다고 인정할 만한 상당한 이유가 있는 사람으로서 제44조 제2항에 따른 경찰공무원의 측정
  에 응하지 아니하는 사람(자동차등 또는 노면전차를 운전하는 사람으로 한정한다)은 1년 이상 5년 이하의 징역
  이나 500만원 이상 2천만원 이하의 벌금에 처한다.
③  제44조 제1항을 위반하여 술에 취한 상태에서 자동차등 또는 노면전차를 운전한 사람은 다음 각 호의 구분에 따
  라 처벌한다.
 1. 혈중알코올농도가 0.2퍼센트 이상인 사람은 2년 이상 5년 이하의 징역이나 1천만원 이상 2천만원 이하의 벌
   금
 2.  혈중알코올농도가 0.08퍼센트 이상 0.2퍼센트 미만인 사람은 1년 이상 2년 이하의 징역이나 500만원 이상 
   1천만원 이하의 벌금
 3.  혈중알코올농도가 0.03퍼센트 이상 0.08퍼센트 미만인 사람은 1년 이하의 징역이나 500만원 이하의 벌금
④  제45조를 위반하여 약물로 인하여 정상적으로 운전하지 못할 우려가 있는 상태에서 자동차등 또는 노면전차를 
  운전한 사람은 3년 이하의 징역이나 1천만원 이하의 벌금에 처한다.
마약류관리에 관한 법률
ㅁ
제2조 (정의)
이 법에서 사용하는 용어의 뜻은 다음과 같다.
 1. ~ 2. (기재생략)
 3.  “향정신성의약품”이란 인간의 중추신경계에 작용하는 것으로서 이를 오용하거나 남용할 경우 인체에 심각한 
   위해가 있다고 인정되는 다음 각 목의 어느 하나에 해당하는 것으로서 대통령령으로 정하는 것을 말한다.
법조문
보험업법
ㅂ
민법
  가.  오용하거나 남용할 우려가 심하고 의료용으로 쓰이지 아니하며 안전성이 결여되어 있는 것으로서 이를 오
     용하거나 남용할 경우 심한 신체적 또는 정신적 의존성을 일으키는 약물 또는 이를 함유하는 물질
  나.  오용하거나 남용할 우려가 심하고 매우 제한된 의료용으로만 쓰이는 것으로서 이를 오용하거나 남용할 경
     우 심한 신체적 또는 정신적 의존성을 일으키는 약물 또는 이를 함유하는 물질
  다.  가목과 나목에 규정된 것보다 오용하거나 남용할 우려가 상대적으로 적고 의료용으로 쓰이는 것으로서 이
     를 오용하거나 남용할 경우 그리 심하지 아니한 신체적 의존성을 일으키거나 심한 정신적 의존성을 일으키
     는 약물 또는 이를 함유하는 물질
  라.  다목에 규정된 것보다 오용하거나 남용할 우려가 상대적으로 적고 의료용으로 쓰이는 것으로서 이를 오용
     하거나 남용할 경우 다목에 규정된 것보다 신체적 또는 정신적 의존성을 일으킬 우려가 적은 약물 또는 이
     를 함유하는 물질
  마.  가목부터 라목까지에 열거된 것을 함유하는 혼합물질 또는 혼합제제. 다만, 다른 약물 또는 물질과 혼합되
     어 가목부터 라목까지에 열거된 것으로 다시 제조하거나 제제할 수 없고, 그것에 의하여 신체적 또는 정신
     적 의존성을 일으키지 아니하는 것으로서 총리령으로 정하는 것은 제외한다.
제1000조 (상속의 순위)
①  상속에 있어서는 다음 순위로 상속인이 된다.
 1.  피상속인의 직계비속  2. 피상속인의 직계존속  3. 피상속인의 형제자매  4. 피상속인의 4촌 이내의 방계혈족
②  전항의 경우에 동순위의 상속인이 수인인 때에는 최근친을 선순위로 하고 동친 등의 상속인이 수인인 때에는 공
  동상속인이 된다.
③  태아는 상속순위에 관하여는 이미 출생한 것으로 본다.
제1003조 (배우자의 상속순위)
①  피상속인의 배우자는 제1000조 제1항 제1호와 제2호의 규정에 의한 상속인이 있는 경우에는 그 상속인과 동순
  위로 공동상속인이 되고 그 상속인이 없는 때에는 단독상속인이 된다.
②  제1001조의 경우에 상속개시전에 사망 또는 결격된 자의 배우자는 동조의 규정에 의한 상속인과 동순위로 공동
  상속인이 되고 그 상속인이 없는 때에는 단독상속인이 된다.
제1004조 (상속인의 결격사유)
다음 각 호의 어느 하나에 해당한 자는 상속인이 되지 못한다.
 1.  고의로 직계존속, 피상속인, 그 배우자 또는 상속의 선순위나 동순위에 있는 자를 살해하거나 살해하려한 자
 2.  고의로 직계존속, 피상속인과 그 배우자에게 상해를 가하여 사망에 이르게 한 자
 3.  사기 또는 강박으로 피상속인의 상속에 관한 유언 또는 유언의 철회를 방해한 자
 4.  사기 또는 강박으로 피상속인의 상속에 관한 유언을 하게 한 자
 5.  피상속인의 상속에 관한 유언서를 위조ㆍ변조ㆍ파기 또는 은닉한 자
제2조 (정의)
이 법에서 사용하는 용어의 뜻은 다음과 같다.
 1. ~ 18. (기재생략)
19. “전문보험계약자”란 보험계약에 관한 전문성, 자산규모 등에 비추어 보험계약의 내용을 이해하고 이행할 능력
법조문
190
191
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (98, 1, 98, '산업재해보상보험법
ㅅ
사업장에서 발생된 근로자의 산업 재해 등 근로자의 업무 상의 재해를 신속하고 공정하게 보상하며, 재해근로자의 
재활 및 사회복귀를 촉진하기 위하여 이에 필요한 보험시설을 설치ㆍ운영하고, 재해예방과 그밖에 근로자의 복지 
증진을 위한 사업을 시행하여 근로자 보호에 이바지하는 것을 목적으로 시행된 법입니다.
   이 있는 자로서 다음 각 목의 어느 하나에 해당하는 자를 말한다. 다만, 전문보험계약자 중 대통령령으로 정하
   는 자가 일반보험계약자와 같은 대우를 받겠다는 의사를 보험회사에 서면으로 통지하는 경우 보험회사는 정당
   한 사유가 없으면 이에 동의하여야 하며, 보험회사가 동의한 경우에는 해당 보험계약자는 일반보험계약자로 
   본다.
  가.  국가
  나.  한국은행
  다.  대통령령으로 정하는 금융기관
  라.  주권상장법인
  마.  그 밖에 대통령령으로 정하는 자
소득세법
제19조 (사업소득)
①  사업소득은 해당 과세기간에 발생한 다음 각 호의 소득으로 한다.
 1.  농업(작물재배업 중 곡물 및 기타 식량작물 재배업은 제외한다. 이하 같다)ㆍ임업 및 어업에서 발생하는 소득
 2.  광업에서 발생하는 소득
 3.  제조업에서 발생하는 소득
 4.  전기, 가스, 증기 및 수도사업에서 발생하는 소득
 5.  하수ㆍ폐기물처리, 원료재생 및 환경복원업에서 발생하는 소득
 6.  건설업에서 발생하는 소득
 7.  도매 및 소매업에서 발생하는 소득
 8.  운수업에서 발생하는 소득
 9.  숙박 및 음식점업에서 발생하는 소득
10.  출판, 영상, 방송통신 및 정보서비스업에서 발생하는 소득
11.  금융 및 보험업에서 발생하는 소득
12.  부동산업 및 임대업에서 발생하는 소득. 다만, 지역권 등 대통령령으로 정하는 권리를 대여함으로써 발생하는 
   소득은 제외한다.
13.  전문, 과학 및 기술서비스업(대통령령으로 정하는 연구개발업은 제외한다. 이하 같다)에서 발생하는 소득
14.  사업시설관리 및 사업지원서비스업에서 발생하는 소득
15.  교육서비스업(대통령령으로 정하는 교육기관은 제외한다. 이하 같다)에서 발생하는 소득
16.  보건업 및 사회복지서비스업(대통령령으로 정하는 사회복지사업은 제외한다. 이하 같다)에서 발생하는 소득
17.  예술, 스포츠 및 여가 관련 서비스업에서 발생하는 소득
18.  협회 및 단체(대통령령으로 정하는 협회 및 단체는 제외한다. 이하 같다), 수리 및 기타 개인서비스업에서 발생
   하는 소득
19.  가구내 고용활동에서 발생하는 소득
20.  제1호부터 제19호까지의 규정에 따른 소득과 유사한 소득으로서 영리를 목적으로 자기의 계산과 책임 하에 
   계속적ㆍ반복적으로 행하는 활동을 통하여 얻는 소득
법조문
②  사업소득금액은 해당 과세기간의 총수입금액에서 이에 사용된 필요경비를 공제한 금액으로 하며, 필요경비가 
  총수입금액을 초과하는 경우 그 초과하는 금액을 “결손금”이라 한다.
③  제1항 각 호에 따른 사업의 범위에 관하여는 이 법에 특별한 규정이 있는 경우 외 관련 법령에는 「통계법」 제22
  조에 따라 통계청장이 고시하는 한국표준산업분류에 따르고, 그 밖의 사업소득의 범위에 관하여 필요한 사항은 
  대통령령으로 정한다.
제20조 (근로소득)
①  근로소득은 해당 과세기간에 발생한 다음 각 호의 소득으로 한다.
 1.  근로를 제공함으로써 받는 봉급ㆍ급료ㆍ보수ㆍ세비ㆍ임금ㆍ상여ㆍ수당과 이와 유사한 성질의 급여
 2.  법인의 주주총회ㆍ사원총회 또는 이에 준하는 의결기관의 결의에 따라 상여로 받는 소득
 3.  「법인세법」에 따라 상여로 처분된 금액
 4.  퇴직함으로써 받는 소득으로서 퇴직소득에 속하지 아니하는 소득
②  근로소득금액은 제1항 각 호의 소득의 금액의 합계액(비과세소득의 금액은 제외하며, 이하 “총급여액”이라 한
  다)에서 제47조에 따른 근로소득공제를 적용한 금액으로 한다.
③  근로소득의 범위에 관하여 필요한 사항은 대통령령으로 정한다.
신용정보의 이용 및 보호에 관한 법률
제32조 (개인신용정보의 제공ㆍ활용에 대한 동의)
①  신용정보제공ㆍ이용자가 개인신용정보를 타인에게 제공하려는 경우에는 대통령령으로 정하는 바에 따라 해당 
  신용정보주체로부터 다음 각 호의 어느 하나에 해당하는 방식으로 개인신용정보를 제공할 때마다 미리 개별적
  으로 동의를 받아야 한다. 다만, 기존에 동의한 목적 또는 이용 범위에서 개인신용정보의 정확성ㆍ최신성을 유
  지하기 위한 경우에는 그러하지 아니하다.
 1.  서면
 2.  「전자서명법」 제2조 제2호에 따른 전자서명(서명자의 실지명의를 확인할 수 있는 것을 말한다)이 있는 전자
   문서(「전자문서 및 전자거래 기본법」 제2조 제1호에 따른 전자문서를 말한다)
 3.  개인신용정보의 제공 내용 및 제공 목적 등을 고려하여 정보 제공 동의의 안정성과 신뢰성이 확보될 수 있는 유
   무선 통신으로 개인비밀번호를 입력하는 방식
 4.  유무선 통신으로 동의 내용을 해당 개인에게 알리고 동의를 받는 방법. 이 경우 본인 여부 및 동의 내용, 그에 
   대한 해당 개인의 답변을 음성녹음하는 등 증거자료를 확보ㆍ유지하여야 하며, 대통령령으로 정하는 바에 따
   른 사후 고지절차를 거친다.
 5.  그 밖에 대통령령으로 정하는 방식
② ~ ③ (기재생략)
④  신용정보회사등은 개인신용정보의 제공 및 활용과 관련하여 동의를 받을 때에는 대통령령으로 정하는 바에 따
  라 서비스 제공을 위하여 필수적 동의사항과 그 밖의 선택적 동의사항을 구분하여 설명한 후 각각 동의를 받아야 
  한다. 이 경우 필수적 동의사항은 서비스 제공과의 관련성을 설명하여야 하며, 선택적 동의사항은 정보 제공에 
  동의하지 아니할 수 있다는 사실을 고지하여야 한다.
⑤  신용정보회사등은 신용정보주체가 선택적 동의사항에 동의하지 아니한다는 이유로 신용정보주체에게 서비스의 
  제공을 거부하여서는 아니 된다.
신용정보의 이용 및 보호에 관한 법률 시행령
제28조 (개인신용정보의 제공ㆍ활용에 대한 동의) 
①  삭제 <2015. 9. 11.>
②  신용정보제공ㆍ이용자는 법 제32조제1항 각 호 외의 부분 본문에 따라 해당 신용정보주체로부터 동의를 받으
  려면 다음 각 호의 사항을 미리 알려야 한다. 다만, 동의 방식의 특성상 동의 내용을 전부 표시하거나 알리기 어
  려운 경우에는 해당 기관의 인터넷 홈페이지 주소나 사업장 전화번호 등 동의 내용을 확인할 수 있는 방법을 안
법조문
192
193
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (99, 1, 99, '  내하고 동의를 받을 수 있다.
 1.  개인신용정보를 제공받는 자
 2.  개인신용정보를 제공받는 자의 이용 목적
 3.  제공하는 개인신용정보의 내용
 4.  개인신용정보를 제공받는 자(개인신용평가회사, 개인사업자신용평가회사, 기업신용조회회사 및 신용정보집
   중기관은 제외한다)의 정보 보유 기간 및 이용 기간
 5.  동의를 거부할 권리가 있다는 사실 및 동의 거부에 따른 불이익이 있는 경우에는 그 불이익의 내용
③  신용정보제공ㆍ이용자는 법 제32조 제1항 제4호에 따라 유무선 통신을 통하여 동의를 받은 경우에는 1개월 이
  내에 서면, 전자우편, 휴대전화 문자메시지, 그 밖에 금융위원회가 정하여 고시하는 방법으로 제2항 각 호의 사
  항을 고지하여야 한다.
④  법 제32조 제1항 제5호에서 “대통령령으로 정하는 방식”이란 정보 제공 동의의 안전성과 신뢰성이 확보될 수 
  있는 수단을 활용함으로써 해당 신용정보주체에게 동의 내용을 알리고 동의의 의사표시를 확인하여 동의를 받
  는 방식을 말한다.
(이하 기재생략)
여객자동차 운수사업법
ㅇ
제28조 (등록)
①  자동차대여사업을 경영하려는 자는 사업계획을 작성하여 국토교통부령으로 정하는 바에 따라 시ㆍ도지사에게 
  등록하여야 한다.
②  제1항에 따른 자동차대여사업의 결격사유에 관하여는 제6조를 준용한다.
제84조 (자동차의 차령 제한 등) 
①  여객자동차 운수사업에 사용되는 자동차는 자동차의 종류와 여객자동차 운수사업의 종류에 따라 대통령령으로 
  정하는 연한[이하 “차령”(車齡)이라 한다] 및 운행거리를 넘겨 운행하지 못한다. 다만, 시ㆍ도지사는 해당 
  시ㆍ도의 여객자동차 운수사업용 자동차의 운행여건 등을 고려하여 대통령령으로 정하는 안전성 요건이 충족되
  는 경우에는 2년의 범위에서 차령을 연장할 수 있다.
②  여객자동차 운수사업의 면허, 허가, 등록, 증차 또는 대폐차(代廢車 : 차령이 만료되거나 운행거리를 초과한 차
  량 등을 다른 차량으로 대체하는 것을 말한다)에 충당되는 자동차는 자동차의 종류와 여객자동차 운수사업의 종
  류에 따라 3년을 넘지 아니하는 범위에서 대통령령으로 정하는 연한(이하 “차량충당연한”이라 한다) 이내로 하
  여야 한다. 다만, 다음 각 호의 어느 하나에 해당하는 경우에는 그러하지 아니하다.
 1.  노선 여객자동차운송사업의 면허를 받거나 등록을 한 자가 보유 차량으로 노선 여객자동차운송사업 범위에서 
   업종 변경을 위하여 면허를 받거나 등록을 하는 경우
 2.  대통령령으로 정하는 노선 여객자동차운송사업자 및 구역 여객자동차운송사업자가 대폐차하는 경우에는 그 
   차령이 6년 이내인 여객자동차운송사업용 자동차로 충당하는 경우
 3.  여객자동차 운수사업에 사용되었던 자동차로서 「자동차관리법」 제13조 제7항 각 호의 어느 하나에 해당하는 
   사유로 말소등록이 된 자동차를 여객자동차 운수사업자가 「자동차관리법」 제43조 제1항 제4호에 따른 임시
   검사에 합격한 후 다시 등록하는 경우. 다만, 차령을 초과한 자동차는 제외한다.
 4.  「환경친화적 자동차의 개발 및 보급 촉진에 관한 법률」 제2조 제3호에 따른 전기자동차 또는 같은 법 제2조 제
   6호에 따른 수소전기자동차의 배터리를 신규로 교체한 경우. 다만, 차령을 초과한 자동차는 제외한다.
③  시ㆍ도지사는 자동차의 제작ㆍ조립이 중단되거나 출고가 지연되는 등 부득이한 사유로 자동차를 공급하는 것이 
  현저히 곤란하다고 인정하면 6개월의 범위에서 제1항에 따른 차령을 초과하여 운행하게 할 수 있다.
④  제1항에 따른 차령과 그 연장요건, 제2항에 따른 차령충당연한의 기산일(起算日) 및 계산 방법 등에 관하여 필
  요한 사항은 대통령령으로 정한다.
법조문
여객자동차 운수사업법 시행령
제3조 (여객자동차운송사업의 종류)
「여객자동차 운수사업법」(이하 “법”이라 한다) 제3조제2항에 따라 같은 조 제1항제1호 및 제2호에 따른 노선 여
객자동차운송사업과 구역 여객자동차운송사업은 다음 각 호와 같이 세분한다.  <개정 2008. 11. 26., 2009. 11. 
27., 2011. 12. 8., 2011. 12. 30., 2012. 11. 23., 2013. 3. 23., 2015. 1. 28., 2016. 1. 6., 2016. 1. 22., 
2019. 2. 12., 2021. 4. 6.>
 1.  노선 여객자동차운송사업
  가.  시내버스운송사업 : 주로 특별시ㆍ광역시ㆍ특별자치시 또는 시(「제주특별자치도 설치 및 국제자유도시 조
     성을 위한 특별법」 제10조 제2항에 따른 행정시를 포함한다. 이하 같다)의 단일 행정구역에서 운행계통을 
     정하고 국토교통부령으로 정하는 자동차를 사용하여 여객을 운송하는 사업. 이 경우 국토교통부령으로 정
     하는 바에 따라 광역급행형ㆍ직행좌석형ㆍ좌석형 및 일반형 등으로 그 운행형태를 구분한다.
  나.  농어촌버스운송사업 : 주로 군(광역시의 군은 제외한다)의 단일 행정구역에서 운행계통을 정하고 국토교통
     부령으로 정하는 자동차를 사용하여 여객을 운송하는 사업. 이 경우 국토교통부령으로 정하는 바에 따라 직
     행좌석형ㆍ좌석형 및 일반형 등으로 그 운행형태를 구분한다.
  다.  마을버스운송사업 : 주로 시ㆍ군ㆍ구의 단일 행정구역에서 기점ㆍ종점의 특수성이나 사용되는 자동차의 특
     수성 등으로 인하여 다른 노선 여객자동차운송사업자가 운행하기 어려운 구간을 대상으로 국토교통부령으
     로 정하는 기준에 따라 운행계통을 정하고 국토교통부령으로 정하는 자동차를 사용하여 여객을 운송하는 
     사업
  라.  시외버스운송사업 : 운행계통을 정하고 국토교통부령으로 정하는 자동차를 사용하여 여객을 운송하는 사업
     으로서 가목부터 다목까지의 사업에 속하지 아니하는 사업. 이 경우 국토교통부령이 정하는 바에 따라 고속
     형ㆍ직행형 및 일반형 등으로 그 운행형태를 구분한다.
 2.  구역 여객자동차운송사업
  가.  전세버스운송사업 : 운행계통을 정하지 아니하고 전국을 사업구역으로 정하여 1개의 운송계약에 따라 국토
     교통부령으로 정하는 자동차를 사용하여 여객을 운송하는 사업. 다만, 다음 어느 하나에 해당하는 기관 또
     는 시설 등의 장과 1개의 운송계약(운임의 수령주체와 관계없이 개별 탑승자로부터 현금이나 회수권 또는 
     카드결제 등의 방식으로 운임을 받는 경우는 제외한다)에 따라 그 소속원[「산업입지 및 개발에 관한 법률」
     에 따른 산업단지, 준산업단지 및 공장입지 유도지구(이하 이 조에서 “산업단지등”이라 한다) 관리기관의 
     경우 해당 산업단지등의 입주기업체 소속원을 포함한다]만의 통근ㆍ통학목적으로 자동차를 운행하는 경우
     에는 운행계통을 정하지 아니한 것으로 본다.
    1) 정부기관ㆍ지방자치단체와 그 출연기관ㆍ연구기관 등 공법인
    2) 회사, 「초ㆍ중등교육법」 제2조에 따른 학교, 「고등교육법」 제2조에 따른 학교, 「유아교육법」 제2조 제2
      호에 따른 유치원, 「영유아보육법」 제10조에 따른 어린이집, 「학원의 설립ㆍ운영 및 과외교습에 관한 법
      률」 제2조의2 제1항 제1호에 따른 학교교과교습학원 또는 「체육시설의 설치ㆍ이용에 관한 법률」 제3조
      에 따른 체육시설(「유통산업발전법」 제2조 제3호에 따른 대규모점포에 부설된 체육시설은 제외한다)
    3)  국토교통부장관 또는 특별시장ㆍ광역시장ㆍ특별자치시장ㆍ도지사ㆍ특별자치도지사(이하 “시ㆍ도지사”
      라 한다)가 정하여 고시하는 산업단지등의 관리기관
  나.  특수여객자동차운송사업 : 운행계통을 정하지 아니하고 전국을 사업구역으로 하여 1개의 운송계약에 따라 
     국토교통부령으로 정하는 특수한 자동차를 사용하여 장례에 참여하는 자와 시체(유골을 포함한다)를 운송
     하는 사업
  다.  일반택시운송사업 : 운행계통을 정하지 아니하고 국토교통부령으로 정하는 사업구역에서 1개의 운송계약
     에 따라 국토교통부령으로 정하는 자동차를 사용하여 여객을 운송하는 사업. 이 경우 국토교통부령으로 정
     하는 바에 따라 경형ㆍ소형ㆍ중형ㆍ대형ㆍ모범형 및 고급형 등으로 구분한다.
  라.  개인택시운송사업 : 운행계통을 정하지 아니하고 국토교통부령으로 정하는 사업구역에서 1개의 운송계약
     에 따라 국토교통부령으로 정하는 자동차 1대를 사업자가 직접 운전(사업자의 질병 등 국토교통부령으로 
     정하는 사유가 있는 경우는 제외한다)하여 여객을 운송하는 사업. 이 경우 국토교통부령으로 정하는 바에 
     따라 경형ㆍ소형ㆍ중형ㆍ대형ㆍ모범형 및 고급형 등으로 구분한다.
법조문
194
195
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (100, 1, 100, '자동차관리법
자동차손해배상보장법
ㅈ
제2조 (정의)
이 법에서 사용하는 용어의 뜻은 다음과 같다.
 1.  “자동차”란 원동기에 의하여 육상에서 이동할 목적으로 제작한 용구 또는 이에 견인되어 육상을 이동할 목적
   으로 제작한 용구(이하 “피견인자동차”라 한다)를 말한다. 다만, 대통령령으로 정하는 것은 제외한다.
제8조 (신규등록)
①  신규로 자동차에 관한 등록을 하려는 자는 대통령령으로 정하는 바에 따라 시ㆍ도지사에게 신규자동차등록(이
  하 “신규등록”이라 한다)을 신청하여야 한다.
②  시ㆍ도지사는 신규등록 신청을 받으면 등록원부에 필요한 사항을 적고 자동차등록증을 발급하여야 한다.
③  자동차를 제작ㆍ조립 또는 수입하는 자(이들로부터 자동차의 판매위탁을 받은 자를 포함하며, 이하 “자동차제
  작ㆍ판매자등”이라 한다)가 자동차를 판매한 경우에는 국토교통부령으로 정하는 바에 따라 등록원부 작성에 필
  요한 자동차 제작증 정보를 제69조에 따른 전산정보처리조직에 즉시 전송하여야 하며 산 사람을 갈음하여 지체 
  없이 신규등록을 신청하여야 한다. 다만, 국토교통부령으로 정하는 바에 따라 산 사람이 직접 신규등록을 신청
  하는 경우에는 그러하지 아니하다.
④  자동차제작ㆍ판매자등이 제1항에 따라 신규등록을 신청하는 경우에는 국토교통부령으로 정하는 바에 따라 자
  동차를 산 사람으로부터 수수료를 받을 수 있다.
제29조 (자동차의 구조 및 장치 등)
①  자동차는 대통령령으로 정하는 구조 및 장치가 안전 운행에 필요한 성능과 기준(이하 “자동차안전기준”이라 한
  다)에 적합하지 아니하면 운행하지 못한다.
②  자동차에 장착되거나 사용되는 부품ㆍ장치 또는 보호장구(保護裝具)로서 대통령령으로 정하는 부품ㆍ장치 또
  는 보호장구(이하 “자동차부품”이라 한다)는 안전운행에 필요한 성능과 기준(이하 “부품안전기준”이라 한다)
  에 적합하여야 한다.
③  국토교통부령으로 정하는 캠핑용자동차 안에 취사 및 야영을 목적으로 설치하는 액화석유가스의 저장시설, 가
  스설비, 배관시설 및 그 밖의 사용시설은 「액화석유가스의 안전관리 및 사업법」에 적합하여야 하며, 전기설비 및 
  캠핑설비는 국토교통부령으로 정하는 안전기준에 적합하여야 한다.
④  자동차안전기준과 부품안전기준은 국토교통부령으로 정한다.
제2조 (정의)
이 법에서 사용하는 용어의 뜻은 다음과 같다.
 1.  “자동차”란 「자동차관리법」의 적용을 받는 자동차와 「건설기계관리법」의 적용을 받는 건설기계 중 대통령령
   으로 정하는 것을 말한다.
 1의2.  “자율주행자동차”란 「자동차관리법」 제2조제1호의3에 따른 자율주행자동차를 말한다.
 2.  “운행”이란 사람 또는 물건의 운송 여부와 관계없이 자동차를 그 용법에 따라 사용하거나 관리하는 것을 말한
   다.
 3.  “자동차보유자”란 자동차의 소유자나 자동차를 사용할 권리가 있는 자로서 자기를 위하여 자동차를 운행하는 
   자를 말한다.
 4.  “운전자”란 다른 사람을 위하여 자동차를 운전하거나 운전을 보조하는 일에 종사하는 자를 말한다.
 5.  “책임보험”이란 자동차보유자와 「보험업법」에 따라 허가를 받아 보험업을 영위하는 자(이하 “보험회사”라 한
   다)가 자동차의 운행으로 다른 사람이 사망하거나 부상한 경우 이 법에 따른 손해배상책임을 보장하는 내용
   을 약정하는 보험을 말한다.
법조문
 6.  “책임공제(責任共濟)”란 사업용 자동차의 보유자와 「여객자동차 운수사업법」, 「화물자동차 운수사업법」, 「건
   설기계관리법」 또는 「생활물류서비스산업발전법」에 따라 공제사업을 하는 자(이하 “공제사업자”라 한다)가 
   자동차의 운행으로 다른 사람이 사망하거나 부상한 경우 이 법에 따른 손해배상책임을 보장하는 내용을 약정
   하는 공제를 말한다.
 7.  “자동차보험진료수가(診療酬價)”란 자동차의 운행으로 사고를 당한 자(이하 “교통사고환자”라 한다)가 「의
   료법」에 따른 의료기관(이하 “의료기관”이라 한다)에서 진료를 받음으로써 발생하는 비용으로서 다음 각 목의 
   어느 하나의 경우에 적용되는 금액을 말한다.
  가.  보험회사(공제사업자를 포함한다. 이하 “보험회사등”이라 한다)의 보험금(공제금을 포함한다. 이하 “보험
     금등”이라 한다)으로 해당 비용을 지급하는 경우
  나.  제30조에 따른 자동차손해배상 보장사업의 보상금으로 해당 비용을 지급하는 경우
  다.  교통사고환자에 대한 배상(제30조에 따른 보상을 포함한다)이 종결된 후 해당 교통사고로 발생한 치료비
     를 교통사고환자가 의료기관에 지급하는 경우
 8.  “자동차사고 피해지원사업”이란 자동차사고로 인한 피해를 구제하거나 예방하기 위한 사업을 말하며, 다음 각 
   목과 같이 구분한다.
  가.  자동차손해배상 보장사업: 제30조에 따라 국토교통부장관이 자동차사고 피해를 보상하는 사업
  나.  자동차사고 피해예방사업: 제30조의2에 따라 국토교통부장관이 자동차사고 피해예방을 지원하는 사업
  다.  자동차사고 피해자 가족 등 지원사업: 제30조제2항에 따라 국토교통부장관이 자동차사고 피해자 및 가족
     을 지원하는 사업
  라.  자동차사고 후유장애인 재활지원사업: 제31조에 따라 국토교통부장관이 자동차사고 후유장애인 등의 재활
     을 지원하는 사업
 9.  “자율주행자동차사고”란 자율주행자동차의 운행 중에 그 운행과 관련하여 발생한 자동차사고를 말한다.
제3조 (자동차손해배상책임)
자기를 위하여 자동차를 운행하는 자는 그 운행으로 다른 사람을 사망하게 하거나 부상하게 한 경우에는 그 손해를 
배상할 책임을 진다. 다만, 다음 각 호의 어느 하나에 해당하면 그러하지 아니하다.
 1.  승객이 아닌 자가 사망하거나 부상한 경우에 자기와 운전자가 자동차의 운행에 주의를 게을리 하지 아니하였
   고, 피해자 또는 자기 및 운전자 외의 제3자에게 고의 또는 과실이 있으며, 자동차의 구조상의 결함이나 기능상
   의 장해가 없었다는 것을 증명한 경우
 2.  승객이 고의나 자살행위로 사망하거나 부상한 경우
제5조 (보험 등의 가입 의무)
①  자동차보유자는 자동차의 운행으로 다른 사람이 사망하거나 부상한 경우에 피해자(피해자가 사망한 경우에는 
  손해배상을 받을 권리를 가진 자를 말한다. 이하 같다)에게 대통령령으로 정하는 금액을 지급할 책임을 지는 책
  임보험이나 책임공제(이하 “책임보험등”이라 한다)에 가입하여야 한다.
②  자동차보유자는 책임보험등에 가입하는 것 외에 자동차의 운행으로 다른 사람의 재물이 멸실되거나 훼손된 경
  우에 피해자에게 대통령령으로 정하는 금액을 지급할 책임을 지는 「보험업법」에 따른 보험이나 「여객자동차 운
  수사업법」, 「화물자동차 운수사업법」, 「건설기계관리법」 및 「생활물류서비스산업발전법」에 따른 공제에 가입
  하여야 한다.
③  다음 각 호의 어느 하나에 해당하는 자는 책임보험등에 가입하는 것 외에 자동차 운행으로 인하여 다른 사람이 
  사망하거나 부상한 경우에 피해자에게 책임보험등의 배상책임한도를 초과하여 대통령령으로 정하는 금액을 지
  급할 책임을 지는 「보험업법」에 따른 보험이나 「여객자동차 운수사업법」, 「화물자동차 운수사업법」, 「건설기계
  관리법」 및 「생활물류서비스산업발전법」에 따른 공제에 가입하여야 한다.
 1.  「여객자동차 운수사업법」 제4조 제1항에 따라 면허를 받거나 등록한 여객자동차 운송사업자
 2.  「여객자동차 운수사업법」 제28조 제1항에 따라 등록한 자동차 대여사업자
 3.  「화물자동차 운수사업법」 제3조 및 제29조에 따라 허가를 받은 화물자동차 운송사업자 및 화물자동차 운송가
   맹사업자
 4.  「건설기계관리법」 제21조 제1항에 따라 등록한 건설기계 대여업자
법조문
196
197
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (101, 1, 101, ' 5.  「생활물류서비스산업발전법」 제2조제4호나목에 따른 소화물배송대행서비스인증사업자
④  제1항 및 제2항은 대통령령으로 정하는 자동차와 도로(「도로교통법」 제2조 제1호에 따른 도로를 말한다. 이하 
  같다)가 아닌 장소에서만 운행하는 자동차에 대하여는 적용하지 아니한다.
⑤  제1항의 책임보험등과 제2항 및 제3항의 보험 또는 공제에는 각 자동차별로 가입하여야 한다.
5조의2 (보험 등의 가입 의무 면제)
①  자동차보유자는 보유한 자동차(제5조제3항 각 호의 자가 면허 등을 받은 사업에 사용하는 자동차는 제외한다)
  를 해외체류 등으로 6개월 이상 2년 이하의 범위에서 장기간 운행할 수 없는 경우로서 대통령령으로 정하는 경
  우에는 그 자동차의 등록업무를 관할하는 특별시장ㆍ광역시장ㆍ도지사ㆍ특별자치도지사(자동차의 등록업무
  가 시장ㆍ군수ㆍ구청장에게 위임된 경우에는 시장ㆍ군수ㆍ구청장을 말한다. 이하 “시ㆍ도지사”라 한다)의 승
  인을 받아 그 운행중지기간에 한정하여 제5조제1항 및 제2항에 따른 보험 또는 공제에의 가입 의무를 면제받을 
  수 있다. 이 경우 자동차보유자는 해당 자동차등록증 및 자동차등록번호판을 시ㆍ도지사에게 보관하여야 한다.
②  제1항에 따라 보험 또는 공제에의 가입 의무를 면제받은 자는 면제기간 중에는 해당 자동차를 도로에서 운행하
  여서는 아니 된다.
③  제1항에 따른 보험 또는 공제에의 가입 의무를 면제받을 수 있는 승인 기준 및 신청 절차 등 필요한 사항은 국토
  교통부령으로 정한다.
제6조 (의무보험 미가입자에 대한 조치 등)
①  보험회사등은 자기와 제5조제1항부터 제3항까지의 규정에 따라 자동차보유자가 가입하여야 하는 보험 또는 공
  제(이하 “의무보험”이라 한다)의 계약을 체결하고 있는 자동차보유자에게 그 계약 종료일의 75일 전부터 30일 
  전까지의 기간 및 30일 전부터 10일 전까지의 기간에 각각 그 계약이 끝난다는 사실을 알려야 한다. 다만, 보험
  회사등은 보험기간이 1개월 이내인 계약인 경우와 자동차보유자가 자기와 다시 계약을 체결하거나 다른 보험회
  사등과 새로운 계약을 체결한 사실을 안 경우에는 통지를 생략할 수 있다.
(이하 기재생략)
제10조 (보험금등의 청구)
①  보험가입자등에게 제3조에 따른 손해배상책임이 발생하면 그 피해자는 대통령령으로 정하는 바에 따라 보험회
  사등에게 「상법」 제724조 제2항에 따라 보험금등을 자기에게 직접 지급할 것을 청구할 수 있다. 이 경우 피해자
  는 자동차보험진료수가에 해당하는 금액은 진료한 의료기관에 직접 지급하여 줄 것을 청구할 수 있다.
②  보험가입자등은 보험회사등이 보험금등을 지급하기 전에 피해자에게 손해에 대한 배상금을 지급한 경우에는 보
  험회사등에게 보험금등의 보상한도에서 그가 피해자에게 지급한 금액의 지급을 청구할 수 있다.
자동차손해배상 보장법 시행령
제2조 (건설기계의 범위)
「자동차손해배상 보장법」(이하 “법”이라 한다) 제2조제1호에서 “「건설기계관리법」의 적용을 받는 건설기계 중 대
통령령으로 정하는 것”이란 다음 각 호의 것을 말한다.
 1.  덤프트럭
 2.  타이어식 기중기
 3.  콘크리트믹서트럭
 4.  트럭적재식 콘크리트펌프
 5.  트럭적재식 아스팔트살포기
 6.  타이어식 굴착기
 7.  「건설기계관리법 시행령」 별표 1 제26호에 따른 특수건설기계 중 다음 각 목의 특수건설기계
  가.  트럭지게차
  나.  도로보수트럭
  다.  노면측정장비(노면측정장치를 가진 자주식인 것을 말한다)
법조문
전자서명법
제2조 (정의)
이 법에서 사용하는 용어의 뜻은 다음과 같다.
 2.  “전자서명”이란 다음 각 목의 사항을 나타내는 데 이용하기 위하여 전자문서에 첨부되거나 논리적으로 결합된 
   전자적 형태의 정보를 말한다.
 가.  서명자의 신원
 나.  서명자가 해당 전자문서에 서명하였다는 사실
(이하 기재생략)
통계법
ㅌ
제3조 (정의)
3. “통계작성기관”이란 중앙행정기관䞱지방자치단체 및 제15조에 따라 지정을 받은 통계작성지정기관을 말한다.
제15조 (통계작성지정기관의 지정)
① 통계청장은 통계의 작성ㆍ보급 및 이용을 촉진하기 위하여 정부정책의 수립ㆍ평가 또는 경제ㆍ사회현상의 연
  구ㆍ분석 등에 이용되는 수량적 정보를 작성하고 있거나 작성하고자 하는 기관등의 신청이 있는 경우 해당 기관
  등을 통계작성지정기관으로 지정할 수 있다. 이 경우 지정요건은 통계작성 조직 및 예산, 통계작성계획 등을 고
  려하여 대통령령으로 정한다.
② 통계청장은 정부정책의 수립ㆍ평가 또는 경제ㆍ사회현상의 연구ㆍ분석 등에 이용되는 수량적 정보를 작성하고 
  있는 공공기관(중앙행정기관 및 지방자치단체는 제외한다)이 제1항에 따른 지정신청을 하지 아니하는 경우에
  는 위원회의 심의ㆍ의결을 거쳐 통계작성지정기관으로 지정할 수 있다.
③ 통계작성지정기관의 지정신청, 지정의 절차 및 방법 등에 관하여 필요한 사항은 대통령령으로 정한다.
제17조 (지정통계의 지정 및 지정취소)
①  통계청장은 통계작성기관의 장의 신청에 따라 정부의 각종 정책의 수립ㆍ평가 또는 다른 통계의 작성 등에 널리 
  활용되는 통계로서 다음 각호의 어느 하나에 해당하는 통계를 지정통계로 지정한다.
 1.  전국을 대상으로 작성하는 통계
 2.  지역발전을 위한 정책수립 및 평가의 기초자료가 되는 통계
 3.  다른 통계의 모집단자료로 활용 가능한 통계
제3조 (책임보험금 등)
①  법 제5조제1항에 따라 자동차보유자가 가입하여야 하는 책임보험 또는 책임공제(이하 “책임보험등”이라 한다)
  의 보험금 또는 공제금(이하 “책임보험금”이라 한다)은 피해자 1명당 다음 각 호의 금액과 같다.
 1.  사망한 경우에는 1억5천만원의 범위에서 피해자에게 발생한 손해액. 다만, 그 손해액이 2천만원 미만인 경우
   에는 2천만원으로 한다.
 2.  부상한 경우에는 별표 1에서 정하는 금액의 범위에서 피해자에게 발생한 손해액. 다만, 그 손해액이 법 제15조
   제1항에 따른 자동차보험진료수가(診療酬價)에 관한 기준(이하 “자동차보험진료수가기준”이라 한다)에 따라 
   산출한 진료비 해당액에 미달하는 경우에는 별표 1에서 정하는 금액의 범위에서 그 진료비 해당액으로 한다.
 3.  부상에 대한 치료를 마친 후 더 이상의 치료효과를 기대할 수 없고 그 증상이 고정된 상태에서 그 부상이 원인
   이 되어 신체의 장애(이하 “후유장애”라 한다)가 생긴 경우에는 별표 2에서 정하는 금액의 범위에서 피해자에
   게 발생한 손해액
법조문
198
199
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (102, 1, 102, ' 4.  국제연합 등 국제기구에서 권고하는 통일된 기준 및 작성방법에 따라 작성하는 통계
 5.  그 밖에 지정통계로 지정할 필요가 있다고 통계청장이 인정하는 통계
②  통계청장은 지정통계가 제1항에 따른 지정요건을 갖추지 못하게 되는 경우에는 그 지정을 취소할 수 있다.
③  통계청장은 지정통계를 지정하거나 지정통계의 지정을 취소한 때에는 이를 고시하여야 한다.
④  지정통계 지정의 절차 및 방법과 제3항에 따른 고시에 포함되어야 할 사항 등에 관하여 필요한 사항은 대통령령
  으로 정한다.
형법
형사소송법
화물자동차 운수사업법
환경친화적 산업구조로의 전환촉진에 관한 법률
ㅎ
제258조 (중상해, 존속중상해)
① 사람의 신체를 상해하여 생명에 대한 위험을 발생하게 한 자는 1년 이상 10년 이하의 징역에 처한다.
② 신체의 상해로 인하여 불구 또는 불치나 난치의 질병에 이르게 한 자도 전항의 형과 같다.
③ 자기 또는 배우자의 직계존속에 대하여 전2항의 죄를 범한 때에는 2년 이상 15년 이하의 징역에 처한다.
제450조 (보통의 심판)
약식명령의 청구가 있는 경우에 그 사건이 약식명령으로 할 수 없거나 약식명령으로 하는 것이 적당하지 아니하다
고 인정한 때에는 공판절차에 의하여 심판하여야 한다.
제453조 (정식재판의 청구)
① 검사 또는 피고인은 약식명령의 고지를 받은 날로부터 7일 이내에 정식재판의 청구를 할 수 있다. 단, 피고인은 
  정식재판의 청구를 포기할 수 없다.
② 정식재판의 청구는 약식명령을 한 법원에 서면으로 제출하여야 한다.
③ 정식재판의 청구가 있는 때에는 법원은 지체없이 검사 또는 피고인에게 그 사유를 통지하여야 한다.
제57조 (차량충당조건)
① 화물자동차 운송사업 및 화물자동차 운송가맹사업의 신규등록, 증차 또는 대폐차(代廢車 : 차령이 만료된 차량 
  등을 다른 차량으로 대체하는 것을 말한다)에 충당되는 화물자동차는 차령이 3년의 범위에서 대통령령으로 정
  하는 연한 이내여야 한다. 다만, 국토교통부령으로 정하는 차량은 차량충당조건을 달리 할 수 있다.
②  제1항에 따른 대폐차의 대상, 기한, 절차 및 방법 등에 필요한 사항은 국토교통부령으로 정한다.
제22조 (환경설비 및 재제조 제품의 품질인증 등)
①  산업통상자원부장관은 환경설비 및 재제조 제품의 품질과 기술경쟁력을 강화하기 위하여 환경설비 및 재제조 
  제품에 대한 품질ㆍ성능평가와 공장심사를 거쳐 품질인증을 할 수 있다. 다만, 품질인증을 할 때에 다른 법률에
  서 재제조 제품에 대한 품질기준 및 인증을 규정하고 있는 경우에는 그 법률로 정한 관계 중앙행정기관의 장과 
  협의하여야 한다.
②  산업통상자원부장관은 환경설비와 재제조 제품을 구매하는 「녹색제품 구매촉진에 관한 법률」 제2조제2호에 따
법조문
  른 공공기관에 대하여 제1항에 따라 품질인증을 받은 환경설비와 재제조 제품을 우선하여 구매하도록 요청할 
  수 있다.
③  산업통상자원부장관은 제1항에 따른 품질ㆍ성능평가와 공장심사를 산업통상자원부령으로 정하는 관련 기관 또
  는 단체에 대행하게 할 수 있다. 이 경우 그 기관 또는 단체에 필요한 자금을 지원할 수 있다.
④  산업통상자원부장관은 제3항에 따른 대행기관 또는 단체에 품질ㆍ성능평가 및 공장심사와 관련한 자료의 제출
  을 요청할 수 있다.
⑤  산업통상자원부장관은 제1항에 따라 품질인증을 실시할 경우 품질인증의 기준ㆍ절차 및 사후관리 등 필요한 세
  부사항을 정하여 고시하여야 한다. 이 경우 재제조 제품의 품질인증기준은 산업통상자원부장관이 환경부장관과 
  협의하여 정한다.
⑥  제1항에 따른 품질인증에 필요한 사항은 대통령령으로 정한다.
법조문
200
201
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (103, 1, 103, '메모
메모
202
203
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (104, 1, 104, '메모
메모
204
205
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (105, 1, 105, '메모
메모
206
207
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (106, 1, 106, '예금자보호안내
■ 보험계약과 관련한 보험모집질서 문란행위는 보험업법에 의해 처벌받을 수 있습니다.
■ 금융감독원 보험모집질서 위반행위 신고센터 
 - 전  화 : 국번없이 1332
 - 인터넷 : www.fss.or.kr
■ 사고접수, 보험처리 등 보험계약관련 문의(DB손해보험)
 - 전  화 : 1588-0100
 - 인터넷 : www.idbins.com
■ 금융감독원 보험범죄신고센터 안내
 - 전  화 : 1588-3311
 - 인터넷 : 금융감독원 홈페이지(www.fss.or.kr) 내 「인터넷보험신고센터」
특별이익제공 행위 금지 안내
■ 이 보험계약은 예금자보호법에 따라 예금보험공사가 보호하되, 보호 한도는 본 보험회사에 있는 귀하의 모든 예
  금보호대상 금융상품의 해약환급금(또는 만기 시 보험금이나 사고보험금)에 기타지급금을 합하여 1인당 “최고 
  5천만원”이며, 5천만원을 초과하는 나머지 금액은 보호하지 않습니다. 
  (단, 법인계약자 및 보험료 납부자가 법인인 경우에는 보호되지 않습니다.) 
예금자 보호안내
보험에 관한 상담이 필요하거나 분쟁사항이 있을 때에는 고객상담센터 또는 계약체결지점으로 연락주시기 바
랍니다.
■ 저희 회사 전화번호
    - 고객상담센터 : 1588-0100   
  - 계약체결 지점 : 증권에 기재된 연락처 참조
■ 관련 기관 : 손해보험협회, 금융감독원
보험상담이 필요하시거나 분쟁이 발생한 경우
208
209
209
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (107, 1, 107, '1. 금융서비스의 이용 범위
 가. 고객의 개인신용정보는 금융거래의 설정䞱유지여부 판단 목적 및 고객이 동의한 목적만으로 이용됩니다.
 나. 고객은 영업장䞱인터넷 등 다양한 채널을 통해 금융거래를 체결하거나 금융서비스를 제공받는 과정에서 1) 금융회사가 본인
   의 개인신용정보(이하 ‘본인정보’)를 제휴䞱부가서비스 등을 위해 제휴회사 등에 제공하는 것 및 2) 당해 금융회사가 금융상
   품 소개 및 구매권유(이하 ‘마케팅’) 목적으로 이용하는 것에 대해 동의를 하지 않는 경우에도 금융거래를 체결하거나 금융서
   비스를 이용하실 수 있습니다. 다만, 이러한 동의를 하지 않으신 경우에는 제휴䞱부가서비스 및 신상품䞱서비스 등을 제공받지 
   못할 수도 있습니다.
2. 『신용정보의 이용 및 보호에 관한 법률』상의 고객 권리
 가. 본인정보의 제3자 제공사실 통보 요구
   고객은 「신용정보의 이용 및 보호에 관한 법률」 제35조에 따라 금융회사가 본인정보를 전국은행연합회, 신용조회회사, 타 금
   융회사 등 제3자에게 제공한 경우 제공한 본인정보의 주요 내용 등을 알려주도록 금융회사에 요구할 수 있습니다.
 나. 금융거래 거절 근거 신용정보 고지 요구
   고객은 「신용정보의 이용 및 보호에 관한 법률」 제36조에 따라 금융회사가 전국은행연합회, 신용조회회사 등으로부터 제공
   받은 연체정보 등에 근거하여 금융거래를 거절䞱중지하는 경우에는 그 거절䞱중지의 근거가 된 신용정보, 동 정보를 제공한 기
   관의 명칭䞱주소䞱연락처 등을 고지해 줄 것을 금융회사에 요구할 수 있습니다.
 다. 본인정보의 제3자 제공 및 마케팅 목적의 전화 등의 중단 요구
   고객은 「신용정보의 이용 및 보호에 관한 법률」 제37조에 따라 가입 신청시 동의를 한 경우에도 본인정보를 제3자에게 제공
   하는 것 및 당해 금융회사가 마케팅 목적으로 본인에게 연락하는 것을 전체 또는 사안별로 중단 시킬 수 있습니다. (다만, 고
   객의 신용도 등을 평가하기 위해 전국은행연합회 또는 신용조회회사 등에 제공하는 것에 대해서는 중단시킬 수 없습니다.)
 라. 본인정보의 열람 및 정정 요구
   고객은「신용정보의 이용 및 보호에 관한 법률」 제38조에 따라 전국은행연합회, 신용조회회사, 금융회사 등이 보유한 본인정
   보에 대해 열람 청구가 가능하며, 본인정보가 사실과 다른 경우에는 이의 정정 및 삭제를 요구할 수 있으며, 그 처리결과에 이
   의가 있는 경우에는 금융위원회에 시정을 요청할 수 있습니다.
 마. 본인정보의 무료 열람 요구
   고객은「신용정보의 이용 및 보호에 관한 법률」 제39조에 따라 본인정보를 신용조회회사를 통하여 연간 일정 범위 내에서 무
   료로 열람할 수 있습니다. 자세한 사항은 각 신용조회회사에 문의하시기 바랍니다.
※ 신청자 제한 : 신규 거래고객은 계약 체결일로부터 3개월간은 신청할 수   없습니다
개인신용정보 제공䞱이용에 대한 
고객권리 안내문
3. 위의 권리행사와 관련하여 불편함을 느끼시거나 애로가 있으신 경우 아래의 담당자 앞으로 연락하여 주시기 바
  랍니다.
한국신용정보(주)  
:  ☎ 02-2122-4000 
| 인터넷 http://www.nice.co.kr/ 
한국신용평가정보(주) 
:  ☎ 02-3771-1000 
| 인터넷 http://www.kisamc.com/ 
서울신용평가정보(주) 
:  ☎ 1577-1006 
| 인터넷 http://www.sci.co.kr/
코리아크레딧뷰로(주) 
:  ☎ 02-708-1000 
| 인터넷 http://www.koreacb.com
연
락
처
당사 개인신용정보 고충처리 담당자
대한손해보험협회 담당자
금융감독원 금융민원센터
(02)3011-4989      서울특별시 강남구 테헤란로 432 DB금융센터
(02)3702-8500      서울특별시 종로구 종로5길 68, 6층(수송동, 코리안리빌딩)
(국번없이) 1332       서울특별시 영등포구 여의대로 38
※  파본이나 잘못된 약관은 교환하여 드립니다.      강원일보   T. 02-733-7228  /  DB손해보험   T. 02-3011-3331
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (108, 2, 1, '1
 ○ 무배당 프로미라이프 New간편암건강보험2601 Q & A
※ 상품요약서는상품의제반내용을요약한자료로서자세한사항은약관내용을참조하시기바랍
니다
무배당 프로미라이프 New간편암건강보험2601 상품요약서
Q) 보험가입시보험나이의계산은어떻게합니까?
A) 피보험자(보험대상자)(이하“피보험자”라합니다)의보험나이는계약일현재만나이로계
산하고1년미만의단수가있을때에는6개월미만은버리고6개월이상은1년으로계산합
니다.
Q) 이상품의보장개시일(책임개시일)은어떻게됩니까?
A) 이상품의보장개시일(책임개시일)은회사가계약의청약을승낙하고제1회보험료를받은
때(자동이체납입및신용카드납입의경우에는자동이체신청및신용카드매출승인에필요
한정보를제공한때, 다만계약자의귀책사유로보험료납입및승인이불가능한경우에
는그러하지아니합니다)부터입니다. 또한회사가청약시에제1회보험료를받고청약을
승낙한경우에는제1회보험료를받은때를보장개시일로봅니다.
Q) 해약환급금이기납입보험료보다적은이유는무엇입니까?
A) 보험은은행의저축과는달리위험보장과저축을겸한제도로서계약자가납입한보험료
중일부는불의의사고를당한다른계약자에게지급되는보험금으로, 또다른일부는보
험회사운영에필요한경비로사용되므로중도해지시지급되는해약환급금은납입한보험
료보다적거나없을수도있습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (109, 2, 2, '2
1. 보험가입자격제한 등
(1) 1종(암건강플랜(일반고지형))
주1) 단, 회사가정하는기준(가입나이및건강상태, 직무등)에따라보험가입금액또는보험료가제
한되거나가입이불가능할수있음
(2) 2종(암건강플랜(간편고지형))
주1) 단, 회사가정하는기준(가입나이및건강상태, 직무등)에따라보험가입금액또는보험료가제
한되거나가입이불가능할수있음
보장내용
보험기간
납입기간
가입나이
납입주
기
상해사망
암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상)
기타피부암및갑상선암주요치료비Ⅱ(연간1회한)(10년지급대
상)
암(유사암제외) 치료비지원
기타피부암및갑상선암치료비지원
순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10
년지급대상)
순환계질환(3-5종)치료비지원
주요심·뇌·5대혈관수술비Ⅱ
90세/100세
10/20/30년
(100세만기)
만15~Min(70,100-납입
기간)세
(90세만기)
만15~Min(70,(90-납입
기간)세
월납,연
납
보험료납입면제대상보장(5대사유)
10/20/30년
전기납
(100세만기)
만15~Min(70,100-납입
기간)세
(90세만기)
만15~Min(70,(90-납입
기간)세
보장내용
보험기간
납입기간
가입나이
납입주기
(3.3.5간편고지)상해사망
(3.3.5간편고지)암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지
급대상)
(3.3.5간편고지)기타피부암
및
갑상선암주요치료비Ⅱ(연간1회
한)(10년지급대상)
(3.3.5간편고지)암(유사암제외) 치료비지원
(3.3.5간편고지)기타피부암및갑상선암치료비지원
(3.3.5간편고지)순환계질환(3-5종)주요치료비(요양병원제외)(연
간1회한)(10년지급대상)
(3.3.5간편고지)순환계질환(3-5종)치료비지원
(3.3.5간편고지)주요심·뇌·5대혈관수술비Ⅱ
90세/100세
10/20/30년
(100세만기)
만15~Min(70,100-납
입기간)세
(90세만기)
만15~Min(70,(90-납
입기간)세
월납,연납
(3.3.5간편고지)보험료납입면제대상보장(5대사유)
10/20/30년
전기납
(100세만기)
만15~Min(70,100-납
입기간)세
(90세만기)
만15~Min(70,(90-납
입기간)세
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (110, 2, 3, '3
2. 상품의 특이사항
구분
상품형태
고지형태
납입면제형태
1종
암건강플랜(일반고지형)
일반고지
상해·질병80%이상후유장해또는
암·뇌졸중·급성심근경색증진단시
2종
암건강플랜(간편고지형)
간편고지
(1) 보험기간, 납입기간, 납입주기: 보험가입자격제한참조
(2) 적용이율및적립이율
①보장부분적용이율: 2.5%
②적립부분적립이율: 이계약의공시이율(보장성공시이율1701)
(단, 최저보증이율은연복리0.2%로합니다.)
(3) 만기환급금
: 적립부분순보험료(적립부분영업보험료에서회사운영경비를차감한금액)에대하
여보험료를받은날로부터보험료납입경과기간에따라“이계약의공시이율”(보장성
공시이율1701)에의한이율로만기시까지적립, 산출하여만기환급금으로보험수익자
(보험금을받는자)에게지급합니다. 다만, 중도인출금이있거나보험계약대출금이있
는경우에는그원리금합계액을빼고지급합니다. 또한, 보험기간중에“이계약의공
시이율”(보장성공시이율1701)이변경되는경우에는변경된시점부터변경된이율로적
용하며, 최저보증이율은연복리0.2%로합니다.
(4) 중도인출제도
: 회사는계약자가보험료를정상적으로납입하고보험계약이유효한경우에보험계
약일로부터1년이지난후부터계약자의청구가있는경우에한하여계약자가요청하
는시점의보통약관해약환급금과보통약관적립부분해약환급금중적은금액(보험계
약대출이있는경우그원금과이자합계액을공제한후의금액)의
80% 이내에서인
출할수있습니다. 다만, 중도인출금의청구는매보험년도마다4회에한합니다.
(5) 납입면제제도
(1) 보장보험료납입면제사유는아래와같이운영함
가.
보험료납입기간중에다음중어느하나의사유가발생한경우에는차회이후
보험료납입을면제
①상해80%이상후유장해가발생한경우
②질병80%이상후유장해가발생한경우
③암보장개시일이후「암」(단, 기타피부암및갑상선암등유사암제외)으로진단확정
되었을경우
④「뇌졸중」으로진단확정되었을경우
⑤「급성심근경색증」으로진단확정되었을경우
나. 아래해당하는담보는위(1)가.에따른납입면제에관한사항을포함하고암보장개시일
이후기타피부암및갑상선암으로진단확정되었을경우차회이후보장보험료를납입면제
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (111, 2, 4, '4
함
대상 담보
기타피부암 및 갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
(3.3.5간편고지)기타피부암 및 갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
다. 아래해당하는담보는위(1)가.에따른납입면제에관한사항을포함하고순환계질환
(3-5종)으로진단확정되었을경우차회이후보장보험료를납입면제함
대상 담보
순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
(3.3.5간편고지)순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
(2) 위(1)에도불구하고보험금지급으로인하여소멸된담보는납입면제에서제외함
(3) 위(1)에따라보장보험료가납입면제된경우차회이후의적립보험료납입을중지함
3. 보험금 지급사유 및 지급제한 사항
※ 아래의지급사유, 지급금액, 보장개시일등은상품의제반내용을요약한자료로서자세한
사항은약관본문내용을참조하시기바랍니다.
(1) 보장(보상)의종류및보험금지급사유
급부종류
보험금지급사유
지급금액
상해사망
피보험자가
보험기간
중
상해사고로
사망한
경우보험가입금액지급
가입금액지급
(최초1회에한함)
암주요치료비Ⅱ(유사암제외)(연
간1회한)(10년지급대상)
피보험자가
보장개시일(계약일로부터
90일이
지난날의다음날) 이후에
약관에서정한암
(유사암제외)으로최초진단확정되고"보험금
지급대상기간"(암(유사암제외) 최초진단확
정일로부터10년) 이내에암(유사암제외)으로
암주요치료(암수술,
항암방사선치료,
항암약
물치료)를받은경우
연간1회에한하여보험가입
금액을지급함(즉, 최대10
회지급)
※ 세부내용은약관참고
기타피부암및갑상선암주요치료
비Ⅱ(연간1회한)(10년지급대상)
피보험자가
보장개시일(계약일로부터
90일이
지난날의다음날) 이후에약관에서정한기
타피부암또는갑상선암으로최초진단확정되
고"보험금지급대상기간"(기타피부암또는
갑상선암의최초진단확정일로부터10년) 이
내에기타피부암및갑상선암으로암주요치료
(암수술,
항암방사선치료,
항암약물치료)를
받은경우
연간1회에한하여보험가입
금액을지급함(즉, 최대10
회지급)
※ 세부내용은약관참고
암(유사암제외) 치료비지원
피보험자가
보장개시일(계약일로부터
90일이
지난날의다음날) 이후에암(유사암제외)으로
진단확정시
가입금액지급
(최초1회에한함. 기타피부
암, 갑상선암, 제자리암, 경
계성종양은보장하지않음)
기타피부암및갑상선암치료비
지원
피보험자가보험기간중기타피부암및갑상
선암으로진단확정시
가입금액지급
(최초1회에한함)
순환계질환(3-5종)주요치료비(요
양병원제외)(연간1회한)(10년지
급대상)
피보험자가보장개시일이후에약관에서정한
“순환계질환(3-5종)”으로
진단확정되고
"보험
금지급대상기간"(최초진단확정일로부터10
년) 이내에요양병원을제외한병원또는의
원에서“순환계질환(3-5종)”의직접적인치료
를목적으로순환계질환주요치료(수술, 혈전
가입후1년미만“순환계질
환(3-5종)”으로최초진단확
정시: 보험가입금액의50%
로보험금지급대상기간동안
연간1회한지급(최대10회지
급)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (112, 2, 5, '5
(2) 보험금지급제한사항
①회사의보장개시일은회사가계약의청약을승낙하고제1회보험료를받은때(자동
이체납입및신용카드납입의경우에는자동이체신청및신용카드매출승인에필요한
정보를제공한때, 다만계약자의귀책사유로보험료납입및승인이불가능한경우
에는그러하지아니합니다)부터입니다. 다만, 회사가청약시에제1회보험료를받고
청약을승낙한경우에는제1회보험료를받은때를보장개시일로봅니다.
②보험금을지급하지아니하는사유등기타세부적인사항은약관내용에따라제한될
수있으니, 반드시약관본문을참조하여주시기바랍니다.
4. 보험료 산출기초
(1) 보험료의구성
보험계약자가납입하는보험료는만약의사고시보험금을지급하는위험보험료, 만기시환
급금을지급하기위한적립보험료그리고보험회사의경비를위한부가보험료로구성됩니
다. 단, 순수보장형상품은위험보험료와부가보험료로구성됩니다.
(2) 적용이율및적립이율
①보장부분적용이율: 2.5%
②적립부분적립이율: 이계약의공시이율(보장성공시이율1701)
(단, 최저보증이율은연복리0.2%로합니다.)
용해치료, 종합병원중환자실치료, 특정급여
치료)를받은경우보험금지급대상기간동안
연간1회에한하여다음과같이지급
가입후1년이상“순환계질
환(3-5종)”으로최초진단확
정시
:
보험가입금액의
100%로
보험금
지급대상기
간동안연간1회한지급(최대
10회지급)
순환계질환(3-5종)치료비지원
피보험자가보험기간중순환계질환(3-5종)으
로진단확정된경우(세부내용은약관참조)
가입금액지급
(최초1회에한함)
주요심·뇌·5대혈관수술비Ⅱ
피보험자가보험기간중약관에서정한심장
질환, 뇌혈관질환또는5대혈관질환으로진단
확정되고, 그치료를직접목적으로수술을받
은경우
매수술시마다가입금액지급
(단, 5대혈관질환수술의경
우가입금액의10%를지급)
(가입
후
90일
미만수술시
가입금액의
5%지급,
가입
후
1년미만수술시
가입금액
의50%지급)
(단, 5대혈관질환수술의경
우가입후90일미만수술시
가입금액의0.5%지급, 가입
후
1년미만수술시
가입금액
의5%지급)
※ 세부내용은약관참고
보험료납입면제대상보장(5대사
유)
피보험자가보험기간중보장개시일(암(유사
암제외)은보험계약일로부터90일이지난날의
다음날, 다른질병은보험계약일) 이후상해
80%이상후유장해, 질병80%이상후유장해, 암
(유사암제외), 급성심근경색증, 뇌졸중중하
나로진단확정된경우
가입금액지급
(최초1회에한함)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (113, 2, 6, '6
적용이율이란?
- 보험회사는장래의보험금지급을대비하여계약자가납입한보험료를적립해두는데, 보험료납
입시점과보험금지급시점에는시차가발생하게됩니다.
- 이기간동안보험회사는적립된금액을운용할수있으므로운용에따라기대되는수익을미리
예상하여일정한비율로보험료를할인해주는데, 이러한할인율을“적용이율”이라고합니다.
- 일반적으로, 적용이율이높아지면보험료는낮아지고, 적용이율이낮아지면보험료는올라갑니다.
확정금리형보험상품과금리연동형보험상품의차이점
－ 확정금리형보험
보험회사가적립순보험료를확정금리로적립하여적립부분환급금을돌려주는보험
－ 금리연동형보험
보험회사가적립순보험료를자산운용수익률, 시장금리등에연동되는변동금리로적립하여적립
부분환급금을돌려주는보험
공시이율이란?
① 이계약의적용공시이율(‘보장성공시이율1701’을적용하며, 이하‘공시이율’이라합니다)은‘보장
성공시이율1701 적용에관한지침’에따라매월1일회사가정한이율로하며, 당월말일까지1
개월간확정적용합니다. 회사는운용자산이익률과객관적인외부지표금리를가중평균하여산출
한공시기준이율에조정률을가감하여공시이율을결정합니다.
② 세부적인공시이율의운영방법은회사에서별도로정한‘보장성성공시이율1701 적용에관한세부
지침’을따릅니다.
③ 회사는위① 또는②에서정한공시이율을매월회사의인터넷홈페이지등을통해공시합니다.
최저보증이율이란?
회사의운용자산이익률및외부지표금리가하락하더라도회사에서지급을보증하는최저한도의적용
이율입니다.
(3) 적용위험률
(기준: 보통약관의주요담보, 상해위험등급1급, 40세)
구
분
위험률
남자
여자
상해사망률
0.000261 
0.000137
기타피부암및갑상선암이외의암발생률
0.001403
0.003268
기타피부암발생률
0.000034
0.000027
갑상선암발생률
0.000235
0.00136
순환계질환(3-5종)발생률
0.006214
0.005692
적용위험률이란?
한개인이사망하거나질병에걸리는등의일정한보험사고가발생할수있는확률을대수의법칙에
의해예측한것을적용위험률이라고합니다.
일반적으로적용위험률이높으면보험료가높아지고낮아지면보험료가낮아집니다.
   
(4) 적용사업비율
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (114, 2, 7, '7
우리회사에서는귀하가가입하신보험계약의체결및유지, 관리등에필요한경비로사용하기위
하여보험료중일정비율을사업비로책정하고있는데, 이를적용사업비율(계약체결비용및계약관
리비용)이라합니다.
4. 보험가격지수
 보험가격지수란?
해당상품의보험료총액(보험금지급을위한보험료및보험회사의사업경비등을위한보험
료)을참조순보험료총액과평균사업비총액을합한금액으로나눈비율을“보험가격지수”라고
합니다.
○ 참조순보험료
: 금융감독원이정하는평균공시이율및참조순보험요율을적용하여산출한, 보험금지급을
위한보험료
○ 평균사업비
: 상품군별로손해보험상품전체의평균사업비율을반영하여계산(역산)한값
(1) 1종
(기준: 상해1급, 40세, 100세만기20년납, 최초계약, 월납, 장기기타보험)
(2) 2종
(기준: 상해1급, 40세, 100세만기20년납, 최초계약, 월납, 장기기타보험)
주) 플랜별보험가격지수산출시적용한가입금액
구분
성별
보험가격지수(%)
암건강플랜(일반고지형)
남자
80.2
여자
81.0
구분
담보및가입금액
1종
상해사망1억원, 암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상) 2000만,
기타피부암
및
갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
400만,
암(유사암제
외) 치료비지원10만, 기타피부암및갑상선암치료비지원10만, 순환계질환(3-5종)주
요치료비(요양병원제외)(연간1회한)(10년지급대상)
1000만,
순환계질환(3-5종)치료비
지원10만, 주요심·뇌·5대혈관수술비Ⅱ500만, 보험료납입면제대상보장(5대사유) 10만
2종
(3.3.5간편고지)상해사망1억원, (3.3.5간편고지)암주요치료비Ⅱ(유사암제외)(연간1회
한)(10년지급대상) 2000만, (3.3.5간편고지)기타피부암및갑상선암주요치료비Ⅱ(연간
1회한)(10년지급대상)
400만,
(3.3.5간편고지)암(유사암제외)
치료비지원
10만,
(3.3.5간편고지)기타피부암및갑상선암치료비지원10만, (3.3.5간편고지)순환계질환
(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상) 1000만, (3.3.5간편고지)
순환계질환(3-5종)치료비지원10만, (3.3.5간편고지)주요심·뇌·5대혈관수술비Ⅱ500만,
(3.3.5간편고지)보험료납입면제대상보장(5대사유) 10만
구분
성별
보험가격지수(%)
암건강플랜(간편고지형)
남자
105.0
여자
101.1
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (115, 2, 8, '8
5. 계약자배당에 관한 사항
이계약은무배당상품으로서배당을하지않습니다. 그러나, 무배당상품은배당상품에
비해보험료가상대적으로저렴하다는특징이있습니다.
6. 해약환급금에 관한 사항
(1) 해약환급금산출기준
회사는금융감독원장이인가한산출기준에따라계산한이계약의순보험료식계약자적
립액에서해약공제액을공제한금액에미경과보험료를더하여해약환급금으로지급하여
드립니다.
       
(2) 해약환급금이적은이유
보험은은행의저축과는달리위험보장과저축을겸한제도로서보험계약자가납입한
보험료중일부는불의의사고를당한다른보험계약자에게지급되는보험금으로, 또
다른일부는보험회사운영에필요한경비로사용되므로중도해지시지급되는해약환
급금은납입한보험료보다적거나없을수도있습니다.
(3) 해약환급금예시
    
(단위: 원, %)
경과기간
납입보험료
해약환급금(률)
최저보증이율주1)
「평균공시이율과
공시이율」중작은이율주2)
공시이율주2)
해약환급금
환급률
해약환급금
환급률
해약환급금
환급률
1년
1,200,000
259,330
21.6%
261,760
21.8%
261,760
21.8%
3년
3,600,000
2,218,680
61.6%
2,239,630
62.2%
2,239,630
62.2%
5년
6,000,000
4,202,750
70.0%
4,261,030
71.0%
4,261,030
71.0%
10년
12,000,000
8,891,170
74.1%
9,129,810
76.1%
9,129,810
76.1%
20년
24,000,000
17,671,180
73.6%
18,685,480
77.9%
18,685,480
77.9%
주1) 상기예시금액(률) 중“최저보증이율”은0.2%로적립, 산출한금액(률)입니다.
주2) 상기예시금액(률) 중“「평균공시이율과공시이율」중작은이율”은감독규정제1-2조제18호에따른
평균공시이율(2026년기준2.5%)과이계약의공시이율(2026.1월기준1.65%) 중작은이율을기
준으로적립, 산출한금액(률)이며, “공시이율”은이계약의공시이율(2026.1월기준1.65%)로적
립, 산출한금액(률)입니다.
주3) 실제해지시에는이계약의공시이율(보장성공시이율1701)을적용하며, 향후공시이율의변동, 계
약내용의변경, 보험료실제납입일자, 추가납입및중도인출여부등에따라해약환급금(률)은달
라질수있습니다. 단, 최저보증이율은0.2%입니다.
ㅇ가입기준:1종(암건강플랜(일반고지형)),남자40세, 상해1급, 100세만기30년납,월납10만원
담보
보험가입금액(만원)
상해사망
10,000
암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상)
2,000
기타피부암및
갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
400
암(유사암제외)
치료비지원
10
기타피부암및
갑상선암치료비지원
10
순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
1,000
순환계질환(3-5종)치료비지원
10
주요심·뇌·5대혈관수술비Ⅱ
500
보험료납입면제대상보장(5대사유)
10
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (116, 2, 9, '9
주4) 평균공시이율은감독원장이정하는바에따라산정한전체보험회사공시이율의평균으로, 전년도
8월말기준직전12개월간보험회사평균공시이율이며2026년기준2.5%입니다.
주5) 중도해지시해약환급금이기납입보험료보다큰경우동차액에대하여이자소득세가부과될수
있습니다.
 ※ 상품요약서는 상품의 제반 내용을 요약한 자료로서 자세한 사항은 약관 내용을
    참조하시기 바랍니다.
   
(방카슈랑스부조리신고)
금융기관보험대리점이보험계약자또는피보험자에게대출과연계하여보험가입을강요하거나
기존에가입한보험계약을부당하게해지하도록한후새로운보험계약의가입을권유하는등
부당한요구를한경우, 금융감독원으로신고하여주시기바랍니다.
금융감독원(Tel : 국번없이1332, 홈페이지: www.fss.or.kr)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (117, 3, 1, '- 1 -
【사업방법서별지】
1. 보험의종류: 장기손해보험/ 장기기타보험
2. 보험종목의명칭등
(1) 보험종목의명칭: 무배당프로미라이프New간편암건강보험2601
단, 판매채널에따라보험종목의명칭중“New간편암건강보험2601” 부분의명칭을가입자의
오해를일으키지않는범위에서다르게할수있음
(2) 보험종목의세목:
구분
상품형태
고지형태
납입면제형태
1종
암건강플랜(일반고지형)
일반고지
상해·질병80%이상후유장해또는
암·뇌졸중·급성심근경색증진단시
2종
암건강플랜(간편고지형)
간편고지
(3) 기타
회사는보험종목의명칭앞에계약자가원하는이름이나판매경로등을인식할수있는용어를
추가하여안내자료및보험증권(보험가입증서)에기재할수있음.
3. 보험의목적: 피보험자(보험대상자)의신체
4. 보험기간, 보험료납입기간, 가입나이및보험료납입주기
(1) 1종(암건강플랜(일반고지형))
주1) 단, 회사가정하는기준(가입나이및건강상태, 직무등)에따라보험가입금액또는보험료가제한
되거나가입이불가능할수있음
(2) 2종(암건강플랜(간편고지형))
보장내용
보험기간
납입기간
가입나이
납입주
기
상해사망
암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상)
기타피부암및갑상선암주요치료비Ⅱ(연간1회한)(10년지급대
상)
암(유사암제외) 치료비지원
기타피부암및갑상선암치료비지원
순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10
년지급대상)
순환계질환(3-5종)치료비지원
주요심·뇌·5대혈관수술비Ⅱ
90세/100세
10/20/30년
(100세만기)
만15~Min(70,100-납입
기간)세
(90세만기)
만15~Min(70,(90-납입
기간)세
월납,연
납
보험료납입면제대상보장(5대사유)
10/20/30년
전기납
(100세만기)
만15~Min(70,100-납입
기간)세
(90세만기)
만15~Min(70,(90-납입
기간)세
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (118, 3, 2, '- 2 -
주1) 단, 회사가정하는기준(가입나이및건강상태, 직무등)에따라보험가입금액또는보험료가제
한되거나가입이불가능할수있음
5. 의무가입에관한사항
해당사항없음
6. 배당에관한사항
배당금을지급하지아니함
7. 보험료차등적용에관한사항
해당사항없음
8. 갱신계약에관한사항
해당사항없음
9. 보험료운영에관한사항
1) 보험업감독규정제1-2조제3호의보장성보험기준을충족하도록운영함
2) 적립보험료는회사의승낙을얻어변경할수있음
10. 보험료의납입연체로인한해지계약의부활(효력회복)시연체이율에관한사항
1) 보장보험료
보장보험료에대하여이계약의평균공시이율+ 1%를적용하여연체이자를계산함
2) 적립보험료
적립보험료는별도의연체된이자를받지않으며, 적립부분순보험료에대하여는연체된적립
보험료를받은날로부터보험료납입경과기간에따라이계약의공시이율을적용하여적립함
11. 보험료선납에관한사항
보장내용
보험기간
납입기간
가입나이
납입주기
(3.3.5간편고지)상해사망
(3.3.5간편고지)암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지
급대상)
(3.3.5간편고지)기타피부암
및
갑상선암주요치료비Ⅱ(연간1회
한)(10년지급대상)
(3.3.5간편고지)암(유사암제외) 치료비지원
(3.3.5간편고지)기타피부암및갑상선암치료비지원
(3.3.5간편고지)순환계질환(3-5종)주요치료비(요양병원제외)(연
간1회한)(10년지급대상)
(3.3.5간편고지)순환계질환(3-5종)치료비지원
(3.3.5간편고지)주요심·뇌·5대혈관수술비Ⅱ
90세/100세
10/20/30년
(100세만기)
만15~Min(70,100-납
입기간)세
(90세만기)
만15~Min(70,(90-납
입기간)세
월납,연납
(3.3.5간편고지)보험료납입면제대상보장(5대사유)
10/20/30년
전기납
(100세만기)
만15~Min(70,100-납
입기간)세
(90세만기)
만15~Min(70,(90-납
입기간)세
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (119, 3, 3, '- 3 -
1) 보험계약자는보험료의일부를미리낼수있음
2) 보험료를선납할때의할인계산은3개월이상의보험료를선납할경우에보장보험료에한하여
계산하며, 할인율은이계약의평균공시이율로함
3) 위2)의선납보험료중보장보험료에대해서는보험료납입해당일까지이계약의평균공시이
율로적립하며, 적립보험료에대해서는보험료납입해당일까지이계약의공시이율로적립함
4) 3개월미만의보험료를미리낼경우적립보험료에대해서는보험료납입해당일까지이계약의
공시이율로계산한이자를지급함
5) 위3)과4)의적립부분선납보험료의이자는해약공제대상금액에서제외함
12. 추가적립보험료에관한사항
해당사항없음
13. 중도인출에관한사항
1) 중도인출시기
계약자가보험료를정상적으로납입하고계약이유효한경우계약일로부터1년이경과한후부
터인출가능함
2) 중도인출금액
중도인출가능금액은계약자가요청한시점의보통약관해약환급금과보통약관적립부분해약환
급금중적은금액(보험계약대출이있는경우그원금과이자합계액을공제한후의금액)의
80%를한도로함
3) 중도인출횟수
중도인출에대한청구는매보험년도마다4회에한함
14. 보험계약대출이율에관한사항
: 이계약의보험계약대출이율은「이계약의공시이율」에회사가정하는이율을가산하여정한다.
15. 공시이율에관한사항
1) 이계약의적립부분순보험료에대한적립이율은보장성공시이율1701로한다.
2) 이보험의공시이율은매월1일회사가정한이율로하며, 당월말일까지1개월간확정적용한다.
3) 회사는운용자산이익률과객관적인외부지표금리를가중평균하여산출한공시기준이율에조정률
을가감하여공시이율을결정한다.
외부지표금리와운용자산이익률의가중치
①가중치는다음의산식에따라산출한다.
외부지표금리의가중치(α) = 
AC
AB C
운용자산이익률의가중치(1-α) = 1- 
AC
AB C
공시기준이율= 객관적인외부지표금리x α + 운용자산이익률x (1 - α)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (120, 3, 4, '- 4 -
②직전년도는사업년도개시3개월이전12개월을말한다.
③가중치는0.5%포인트단위로반올림하여결정한다.
④가중치는사업년도에동일하게적용하여야하며, 60%를초과할수없다.
⑤「직전년도초계약자적립액」과「자산의직전년도말듀레이션」, 「보험료수입」는계정별로구
분하여산출한다.
⑥「보험료수입」은1년간받은보험료를말한다.
객관적인외부지표금리
①객관적인외부지표금리는다음의산식에따라산출한다.
  
객관적인외부지표금리
= 국고채(5년) 수익률×국고채가중치(β1)
+ 회사채(무보증3년, AA-) 수익률×회사채가중치(β2)
+ 통화안정증권(1년) 수익률×통화안정증권가중치(β3)
+ 양도성예금증서(91일) 유통수익률×양도성예금증서가중치(β4)
②외부지표공시기관등이상기외부지표금리가더이상발생되지않는사유등으로다른지표금리
로대체하여공시하는경우에는그대체된지표금리를사용할수있다.
③국고채(5년), 회사채(무보증3년, AA-) 및통화안정증권(1년) 수익률과양도성예금증서(91일) 유
통수익률은공시기준이율적용시점의전전월말직전3개월가중이동평균을통해산출한다.
④국고채가중치(β1), 회사채가중치(β2), 통화안정증권가중치(β3), 양도성예금증서가중치(β4)
는다음의산식에따라산출하여사업년도에동일하게적용한다.
운용자산이익률
①운용자산이익률은다음의산식에따라산출한다.
- A : 직전년도초계약자적립액
- B : 자산의직전년도말듀레이션
- C : 직전년도보험료수입
운용자산이익률= 운용자산수익률- 투자지출률
국고채가중치(β1) = 


회사채가중치(β2) = 


통화안정증권가중치(β3) = 


양도성예금증서가중치(β4) = 


- a는회사가보유한국내발행국공채의직전년도평균잔고(월평잔의평균)
- b는회사가보유한회사채의직전년도평균잔고(월평잔의평균)
- c는회사가보유한통화안정증권의직전년도평균잔고(월평잔의평균)
- d는회사가보유한양도성예금증서의직전년도평균잔고(월평잔의평균)
- 직전년도는사업년도개시3개월이전12개월을말한다.
- 가중치는0.5%포인트단위로반올림하여0%이상100%이하로결정한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (121, 3, 5, '- 5 -
②운용자산수익률은산출시점직전1년간의자사의투자영업수익(보험금융수익제외)을기준으로
산출하며, 투자지출률에사용되는투자영업비용(보험금융비용제외)은동기간동안투자활동에
직접적으로소요된비용을반영하여합리적인방법에의하여산출한다.
③운용자산은당기손익에반영되지않은운용자산관련미실현손익을제외한금액을기초로계산한다.
4) 재보험계약을인수한보험회사가자산운용손익전체를인식하는자산이존재하는재보험계약을체결
하는경우, 해당자산및관련투자영업수익은재보험계약을출재한보험회사가아닌이를인수한
보험회사의공시기준이율산출을위한운용자산이익률계산에포함한다.
5) 회사는계약자에게연1회이상공시이율의변경내용을통지하며, 인터넷홈페이지(상품공시실)
에공시이율과공시이율의산출방법에대하여공시한다.
6) 공시이율의최저보증이율은0.2%로한다.
7) 공시이율의세부적인운용방법은회사에서별도로정한「보장성공시이율1701 적용에관한지
침」에따른다.
16. 보험료납입면제에관한사항
(1) 보장보험료납입면제사유는아래와같이운영함
가.
보험료납입기간중에다음중어느하나의사유가발생한경우에는차회이후보험료납입을면제
①상해80%이상후유장해가발생한경우
②질병80%이상후유장해가발생한경우
③암보장개시일이후「암」(단, 기타피부암및갑상선암등유사암제외)으로진단확정
되었을경우
④「뇌졸중」으로진단확정되었을경우
⑤「급성심근경색증」으로진단확정되었을경우
나. 아래해당하는담보는위(1)가.에따른납입면제에관한사항을포함하고암보장개시일이후
기타피부암및갑상선암으로진단확정되었을경우차회이후보장보험료를납입면제함
대상 담보
기타피부암 및 갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
(3.3.5간편고지)기타피부암 및 갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
다. 아래해당하는담보는위(1)가.에따른납입면제에관한사항을포함하고순환계질환(3-5종)으
※ 운용자산수익률(%) =




×
※ 투자지출률(%)
=




×
- A(t) : 산출시점직전t개월이전월말운용자산
- P : 산출시점직전1개월이전12개월의투자영업수익(보험금융수익제외)
- C : 산출시점직전1개월이전12개월의투자영업비용(보험금융비용제외)
- A(t), P, C는계정별로구분하여산출한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (122, 3, 6, '- 6 -
로진단확정되었을경우차회이후보장보험료를납입면제함
대상 담보
순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
(3.3.5간편고지)순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
(2) 위(1)에도불구하고보험금지급으로인하여소멸된담보는납입면제에서제외함
(3) 위(1)에따라보장보험료가납입면제된경우차회이후의적립보험료납입을중지함
17. 조건부인수를위한특별약관
(1) 이륜자동차운전중상해부담보특별약관
「이륜자동차운전중상해부담보」특별약관은보험계약당시또는보험기간중이륜자동차를소유, 사용, 관
리함으로인하여이륜자동차의운전과관련된급격하고도우연한외래의사고로신체의상해를입을위험
정도가회사가정한기준에적합하지않은경우, 보험계약자의청약과회사의승낙으로보험계약에부가하
여이루어짐.
이륜자동차의운전자가이륜자동차운전중상해부담보특별약관을부가시에는이륜자동차운전을제외한직
업또는직무에해당하는상해급수를적용함. 이륜자동차운전중상해부담보특별약관은피보험자(보험대상
자)가이륜자동차를소유ㆍ사용(직업, 직무또는동호회활동등으로주기적으로운전하는경우에한하며
일회적인사용은제외)ㆍ관리하는경우에한하여부가할수있음.
(2) 특정신체부위· 질병보장제한부인수특별약관(1종에한하여운영)
피보험자(보험대상자)의건강상태가회사가정한기준에적합하지않을경우특정부위에발생한질병또는
특정질병을제외한기타질병을보상함
특정부위에발생한질병및특정부위에발생한질병의전이로인하여특정부위이외의부위에발생한질병
또는특정질병으로재진단또는치료를받지않은경우에는최초보험계약청약일부터5년이경과한이후에
는이특별약관을적용하지아니함
18. 부가서비스에관한사항
해당사항없음
19. 보험금지급사유가회사의자체적인기준이아닌계약에관한사항
(1) 다른법률과보험금지급사유가연계되는등보험금지급사유가회사의자체적인기준이아님에
따라아래와같은경우가발생되는경우회사는객관적이고합리적인범위내에서기존계약내용
에상응하는새로운보장내용으로계약내용을변경할수있음
1) 관련법률의개정또는폐지등에따라약관에서정한보험금지급사유판정기준이변경되는경우
2) 관련법률의개정또는폐지등에따라약관에서정한보험금지급사유의판정이불가능한경우
3) 관련법률의개정또는폐지등에따라계약유지필요가없어지는경우
4) 기타금융위원회등의명령이있는경우
(2) (1)에따라변경된보장내용은개정법률의시행일이후발생한보험사고에대하여적용함
(3) 회사는(1)에따라계약이변경되는경우계약내용변경일의15일이전까지서면(등기우편등),
전화(음성녹취) 또는전자문서등으로보장내용및가입금액변경내역, 보험료수준, 계약내용
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (123, 3, 7, '- 7 -
변경절차등을계약자에게알림
(4) 회사는계약체결시계약자에게(1)에따라계약이변경되는경우와관련된아래의사항을계약
자에게안내함
1) 계약내용변경으로보장내용, 가입금액및납입보험료등이변경될수있음
2) 계약내용변경시점이후잔여보험기간의보장을위한계약자적립액및미경과보험료정산으로
계약자가추가로납입또는반환받을금액이발생될수있음
(5) 회사는(1)에따라보장내용이변경되는경우최신의통계를반영하여보험료산출기초율을재산
출할수있으며다음과같이적용함
1) 계약내용변경으로보장내용및가입금액등이변경될수있음
2) 계약내용변경으로납입보험료가변경될수있음
(6) (1)에도불구하고계약자가계약내용변경을원하지않거나새로운보장내용으로계약내용을변
경하는것이불가능한경우회사는계약자에게‘보험료및해약환급금산출방법서’에서정하는바
에따라계약내용변경시점의계약자적립액및미경과보험료를지급하며, 해당계약은더이상
효력을가지지않음
20. 기타
가. 보장특성에 따른 가입 제한
해당사항없음
나. 기타
(1) 이상품은보험업법제91조에정한금융기관보험대리점을포함하여범용으로판매할수있음.
(2) 금융기관보험대리점의경우모집수수료는“보험료및책임준비금산출방법서”에서정한계약체
결비용대비90%이내에서지급함.
(3) 보험상품종구분에관한사항
○본상품의2종은“간편고지” 상품으로유병력자등1종과같은일반가입자형보험에가입하기
어려운피보험자(보험대상자)를대상으로함
①간편고지란의적결함및연령제한으로인하여보험시장에서소외되고있는유병력자나고령자
등의계약심사및건강검진의부담을줄여보험에가입할수있도록표준체에비하여간소화
된계약전알릴의무항목을활용하여계약심사과정을간소화함을의미함
②계약자가2종(간편고지형) 가입시회사는간편고지형, 일반고지형의보험료를비교하여안내하
고1종(일반고지형)의피보험자는표준체에해당하는계약전알릴의무항목을통하여보험가
입여부에대한의적심사를거쳐가입이가능한상품임을설명하여야함. 상기계약자에게안
내한사항에대한확인(별첨1 참조)을받아야함
③계약자가2종(간편고지형) 가입시회사는청약서의계약전알릴의무사항등계약자가회사에
알린정보에해당하지않는사항을계약자에게불리하게인수심사에활용하지않음
④회사는계약자가2종(간편고지형)의최초계약의계약일부터3개월이내에1종(일반고지형) 가
입을희망하는경우, 동일한피보험자를대상으로일반계약심사를통하여1종(일반고지형)을
청약할수있는기회를제공함. 다만, 본계약의보험금이이미지급되거나청구서류를접수
한경우에는그러하지않음.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (124, 3, 8, '- 8 -
⑤④에의하여1종(일반고지형)에가입하는경우에는본계약을무효로하며이미납입한보험료
를보험계약자에게돌려줌
⑥회사는계약자가2종(간편고지형)의최초계약청약일로부터직전3개월이내에표준체에해당
하는일반가입자형에해당하는상품으로가입한피보험자를대상으로2종(간편고지형)을청
약하는경우, 유병력자여부를추가로심사함. 다만, 해당일반가입자형계약의보험금이이
미지급되거나청구서류를접수한경우에는그러하지않음
⑦회사는⑥에의하여피보험자가유병력자임을알수없는경우, 2종(간편고지형) 계약의청약
을거절함
⑧회사는1종(일반고지형)의가입금액등보장내용이2종(간편고지형)보다축소되지않도록운영
(4) 암주요치료비보장담보에관한사항
○회사는아래담보를보장함에있어계약자안내강화를위해“암주요치료비보장에대한계약
자안내사항(【별첨3】참고)”의내용에대하여계약자가이해하였음을확인할수있도록상품설
명서에계약자의자필확인(전자적형태의확인방식포함(화면체크및텍스트입력방식등)) 또
는음성녹음을받음
　　(5) 순환계질환주요치료비보장담보에관한사항
　　　　○회사는아래담보를보장함에있어계약자안내강화를위해“순환계질환주요치료비(요
양병원제외) 보장에대한계약자안내사항(【별첨4】참고)”의내용에대하여계약자가이해
하였음을확인할수있도록상품설명서에계약자의자필확인(전자적형태의확인방식포함
(화면체크및텍스트입력방식등)) 또는음성녹음을받음
(6)
“보험금지급대상기간” 운영에관한사항
○아래대상담보에서보장하는암으로최초진단확정되고암주요치료(암수술, 항암방사선치료, 항
암약물치료)를받은경우보험금지급의대상이되는기간은아래와같이하며, 보험금지급대
상기간이종료된후암주요치료(암수술, 항암방사선치료, 항암약물치료)를받은경우보험금이
지급되지않음
  
 ○아래대상담보에서보험기간중보장하는질병으로최초진단확정되고순환계질환주요치료(수술,
혈전용해치료, 종합병원중환자실치료, 특정급여치료)를받은경우보험금지급의대상이되는
기간은아래와같이하며, 보험금지급대상기간이종료된후순환계질환주요치료(수술, 혈전용
대상 담보
보장하는 암
보험금 지급
대상기간
암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상)
(3.3.5간편고지)암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상)
암(기타피부암 및 
갑상선암 제외)
해당 담보에서 보장하는 
암의 
최초 진단일로부터 10년
기타피부암 및  갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
(3.3.5간편고지)기타피부암 및  갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
기타피부암 및 
갑상선암
대상 담보 
순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
    (3.3.5간편고지)순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
대상 담보
암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상)
(3.3.5간편고지)암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상)
기타피부암 및  갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
(3.3.5간편고지)기타피부암 및  갑상선암주요치료비Ⅱ(연간1회한)(10년지급대상)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (125, 3, 9, '- 9 -
해치료, 종합병원중환자실치료, 특정급여치료)를받은경우보험금이지급되지않음
대상 담보
보장하는 질병
보험금 지급
대상기간
순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
(3.3.5간편고지)순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
순환계질환(3-5종)
해당 담보에서 보험기간 
중 순환계질환(3-5종)의 
최초 진단일로부터 10년
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (126, 3, 10, '- 10 -
【별첨1】가입 내용에 대한 계약자 확인서
1. 이상품의2종(암건강플랜(간편고지형))은“간편고지” 상품으로유병력자또는연령제한등일반심사보험에가입하기
어려운피보험자를대상으로합니다.
2. 이상품의2종(암건강플랜(간편고지형))은1종(암건강플랜(일반고지형))대비보험료가할증되어있습니다. 의사의건
강검진을받거나일반계약심사를할경우이보험보다저렴한1종(암건강플랜(일반고지형))에가입할수있습니다.
3. 다만, 일반가입자보험의경우건강상태나가입나이에따라가입이제한될수있으며보장하는담보에는차이가있을
수있습니다.
4. 회사는계약자가간편고지형의최초계약의계약일부터3개월이내에일반고지형의가입을희망하는경우,
일반계약심사를통하여일반고지형을청약할수있는기회를제공합니다.
회사의승낙으로일반고지형에가입하는경우, 본계약은무효로하며이미납입한보험료를보험계약자에게돌려드립
니다.
다만, 본계약의보험금이지급되거나청구서류를접수한경우에는일반고지형으로가입할수없습니다.
※ 1종(일반고지형), 2종(간편고지형) 보험료비교(예시)
구 분
2종(암건강플랜(간편고지형))
1종(암건강플랜(일반고지형))
보
장
내
용
- (3.3.5간편고지)상해사망 1천만원
 : 피보험자가 보험기간 중 상해사고로 사망한 경우 보험가입금액 
지급
-(3.3.5간편고지)암주요치료비Ⅱ(유사암제외)(연간1회
한)(10년지급대상) 5백만원
 : 암(유사암제외)으로 진단확정되고 진단확정일로부터 10년 이내
에 암주요치료(암수술, 항암방사선치료, 항암약물치료)를 받은 경
우 연간 1회에 한하여 보험가입금액 지급
- (3.3.5간편고지)기타피부암 및 갑상선암주요치료비Ⅱ(연
간1회한)(10년지급대상) 1백만원
 : 기타피부암 또는 갑상선암으로 진단확정되고 진단확정일로부터 
10년 이내에 기타피부암 또는 갑상선암으로 암주요치료(암수술, 
항암방사선치료, 항암약물치료)를 받은 경우 연간 1회에 한하여 
보험가입금액 지급
- (3.3.5간편고지)암(유사암제외) 치료비지원 10만원
 : 암(유사암제외)으로 진단확정된 경우 보험가입금액 지급(기타피
부암, 갑상선암, 제자리암, 경계성종양은 보상하지 않음)
- (3.3.5간편고지)기타피부암 및 갑상선암 치료비지원 10
만원
 : 기타피부암 및 갑상선암으로 진단확정된 경우 보험가입금액 지
급
-(3.3.5간편고지)순환계질환(3-5종)주요치료비(요양병원제
외)(연간1회한)(10년지급대상) 5백만원
 : “순환계질환(3-5종)”으로 진단확정되고 진단확정일로부터 10년 
이내에 요양병원을 제외한 병원 또는 의원에서 “순환계질환(3-5
종)”의 직접적인 치료를 목적으로 순환계질환 주요치료(수술, 혈전
용해치료, 종합병원 중환자실치료, 특정급여치료)를 받은 경우 연
간 1회에 한하여  보험가입금액 지급(1년이내 50%지급)
- 상해사망 1천만원
 : 피보험자가 보험기간 중 상해사고로 사망한 경우 보험가입금액 지급
- 암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상) 5백
만원
 : 암(유사암제외)으로 진단확정되고 진단확정일로부터 10년 이내에 암
주요치료(암수술, 항암방사선치료, 항암약물치료)를 받은 경우 연간 1회
에 한하여 보험가입금액 지급
- 기타피부암 및 갑상선암주요치료비Ⅱ(연간1회한)(10년지급
대상) 1백만원
 : 기타피부암 또는 갑상선암으로 진단확정되고 진단확정일로부터 10년 
이내에 기타피부암 또는 갑상선암으로 암주요치료(암수술, 항암방사선
치료, 항암약물치료)를 받은 경우 연간 1회에 한하여 보험가입금액 지
급
- 암(유사암제외) 치료비지원 10만원
 : 암(유사암제외)으로 진단확정된 경우 보험가입금액 지급(기타피부암, 
갑상선암, 제자리암, 경계성종양은 보상하지 않음)
- 기타피부암 및 갑상선암 치료비지원 10만원
 : 기타피부암 및 갑상선암으로 진단확정된 경우 보험가입금액 지급
-순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년
지급대상) 5백만원
 : “순환계질환(3-5종)”으로 진단확정되고 진단확정일로부터 10년 이
내에 요양병원을 제외한 병원 또는 의원에서 “순환계질환(3-5종)”의 직
접적인 치료를 목적으로 순환계질환 주요치료(수술, 혈전용해치료, 종합
병원 중환자실치료, 특정급여치료)를 받은 경우 연간 1회에 한하여  보
험가입금액 지급(1년이내 50%지급)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (127, 3, 11, '- 11 -
위내용에대하여모집자는보험계약자에게충분히설명하였고, 보험계약자는설명받은내용을이해하였음을확인합니다.
(※ 아래엷고크게밑줄친내용에보험설계사및보험계약자가직접자필(전자적형태의확인방식포함(화면체크및텍
스트입력방식등))로기재하고서명(날인)하시거나음성녹음을통해확인받으시기바랍니다.)
20____년____월____일보험계약자_____________(인/서명)
구 분
2종(암건강플랜(간편고지형))
1종(암건강플랜(일반고지형))
- (3.3.5간편고지)순환계질환(3-5종)치료비지원 10만원
: 순환계질환(3-5종)으로 진단확정된 경우 보험가입금액 지급
- (3.3.5간편고지)주요심·뇌·5대혈관수술비Ⅱ 1백만원
 : 심장질환, 뇌혈관질환 또는 5대혈관질환으로 진단확정되고, 그 
치료를 직접목적으로 수술을 받은 경우 매수술시마다 가입금액 지
급 
(단, 5대혈관질환 수술의 경우 가입금액의 10%를 지급) 
(가입 후 90일 미만수술시 가입금액의 5%지급, 가입 후 1년미만
수술시 가입금액의 50%지급)
(단, 5대혈관질환 수술의 경우 가입 후 90일 미만수술시 가입금액
의 0.5%지급, 가입 후 1년미만수술시 가입금액의 5%지급)
- (3.3.5간편고지)보험료납입면제대상보장(5대사유) 10만
원
 : 보장개시일(암(유사암제외)은 보험계약일로부터 90일이 지난날
의 다음날, 다른 질병은 보험계약일) 이후 상해80%이상후유장해, 
질병80%이상후유장해, 암(유사암제외), 급성심근경색증, 뇌졸중 
중 하나로 진단확정된 경우
- 순환계질환(3-5종)치료비지원 10만원
: 순환계질환(3-5종)으로 진단확정된 경우 보험가입금액 지급
- 주요심·뇌·5대혈관수술비Ⅱ 1백만원
 : 심장질환, 뇌혈관질환 또는 5대혈관질환으로 진단확정되고, 그 치료
를 직접목적으로 수술을 받은 경우 매수술시마다 가입금액 지급 
(단, 5대혈관질환 수술의 경우 가입금액의 10%를 지급) 
(가입 후 90일 미만수술시 가입금액의 5%지급, 가입 후 1년미만수술시 
가입금액의 50%지급)
(단, 5대혈관질환 수술의 경우 가입 후 90일 미만수술시 가입금액의 
0.5%지급, 가입 후 1년미만수술시 가입금액의 5%지급)
- 보험료납입면제대상보장(5대사유) 10만원
 : 보장개시일(암(유사암제외)은 보험계약일로부터 90일이 지난날의 다
음날, 다른 질병은 보험계약일) 이후 상해80%이상후유장해, 질병80%이
상후유장해, 암(유사암제외), 급성심근경색증, 뇌졸중 중 하나로 진단확
정된 경우
계
약
승
낙
여
부
일반 가입자 상품 대비 질문항목(고지)을 간소화하여 지병
이나 기왕력이 있어도 가입할 수 있습니다.
피보험자의 건강상태 및 직업에 따라서 청약에 대한 승낙을 
거절 할 수 있습니다.
보
험
료
예
시
※ 기준 :  100세만기 20년납, 1급, 월납, 최초계약
나이
남자
여자
20세
18,467원
13,222원
30세
23,621원
16,697원
40세
30,635원
20,380원
50세
41,164원
23,356원
60세
56,205원
27,596원
※ 기준 :  100세만기 20년납, 1급, 월납, 최초계약
나이
남자
여자
20세
14,678원
10,817원
30세
18,694원
13,638원
40세
23,899원
16,600원
50세
31,064원
18,965원
60세
40,394원
21,783원
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (128, 3, 12, '- 12 -
【별첨2】
계약 전 알릴의무 사항
- 간편고지가입자형(3.3.5) -
■ 피보험자(보험대상자)에 관한 다음 사항은 회사가 보험계약의 청약을 심사하고 인수하는데 필요한 자료이므로 보
험계약자 및 피보험자는 아래 질문들에 대해 사실대로 알려야 하며 직접 작성하시기 바랍니다.
■ 만약 아래 질문들에 대하여 사실대로 알리지 않거나 사실과 다르게 알린 경우에는 보험가입이 거절될 수 있으며, 
특히 질문 1번～5-3번에 대하여 알린 내용이 「중요한 사항」에 해당하는 경우 회사는 보험약관에 따라 이 보험
계약을 일방적으로 해지할 수 있고, 이미 보험사고가 발생하였더라도 보험금 지급을 거절하는 등 보장이 제한될 
수 있습니다.
■ 반면, 보험설계사 등이 보험계약자 또는 피보험자에게 고지할 기회를 주지 않았거나 사실대로 고지하는 것을 방
해하는 등의 경우에는 보험계약을 해지하거나 보장을 제한할 수 없습니다.
「중요한 사항」이란 회사가 그 사실을 알았더라면 보험계약의 청약을 거절하거나 보험가입금액 한도 제한, 일부 보
장 제외, 보험금 삭감, 보험료 할증과 같이 조건부로 인수하는 등 계약 인수에 영향을 미치는 사항을 말합니다.
■ 이 청약서에서 ‘최근 3개월 이내(5년 이내)’는 청약일의 3개월 전일(5년 전일)부터 청약일까지를 의미합니다.
(예를 들어 청약일이 4월 1일인 경우 ‘최근 3개월 이내’는 1월 1일부터 4월 1일까지)
D-1년
D-3개월
D(청약)
‘24.4.1
‘25.1.1
‘25.4.1
최근 1년
최근 3개월
Ⅰ. 현재 및 과거의 질병
※ 보험료의 납입연체로 인한 해지계약을 부활하는 경우, 1번∼3번 항목의 알릴의무 기간은 해지일 이후로부터 부
활(효력회복)을 청약한 날까지의 기간과 각 질문별 알릴의무 기간 중 짧은 기간으로 합니다.
 1. 최근 3개월 이내에 의사로부터 진찰 또는 검사를 통하여 다음과 같은 의료행위를 받은 사실이 있습니까? (예, 
아니오)
가. 입원 필요 소견          나. 수술 필요 소견          다. 추가검사(재검사) 필요 소견
   라. 질병확정진단            마. 질병의심소견
※ 진찰 또는 검사란 건강검진을 포함하며, 필요소견이란 의사로부터 진단서 또는 소견서를 발급받은 경우 또는 의
사가 진료기록부 등에 기재하고 환자에게 설명하거나 권유한 경우를 말합니다.
※ 추가검사(재검사)란 검사 결과 이상 소견이 확인되어 보다 정확한 진단을 위해 시행한 검사를 의미하며, 병증에 
대한 치료 필요 없이 유지되는 상태에서 시행하는 정기검사 또는 추적관찰은 포함하지 않습니다.
※ 질병의심소견이란 의사가 진단서나 소견서 또는 진료의뢰서 등을 포함하여 서면(전자문서 포함)으로 교부한 경우
를 말합니다.
 2. 최근 3년 이내에 질병이나 상해사고로 인하여 입원 또는 수술(제왕절개 포함)을 받은 사실이 있습니까?
(예, 아니오)
 3. 최근 5년 이내에 아래 질병으로 의사로부터 진찰 또는 검사를 통하여 다음과 같은 의료행위를 받은 사실이 있
습니까? (예,  아니오) 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (129, 3, 13, '- 13 -
   
①암   ②협심증   ③심근경색   ④뇌졸중증(뇌출혈, 뇌경색) ⑤간경화   ⑥심장판막증
    가. 질병확정진단         나. 입원           다. 수술
※ 1~3번까지 "예"인 경우 병명, 치료기간, 치료내용, 치료병원, 재발경험, 완치여부를 기재하여 주십시오.
Ⅱ. 외부 환경
 4. 귀하의 직업은 무엇입니까?
가. 근무처                    
나. 근무지역                       
다. 업종                    
라. 취급하는 업무(구체적으로 기재하여 주십시오)  
                                      
※ 보험계약 체결 당시 직업* 또는 직무*를 사실대로 알리지 않거나 보험계약 체결 후 직업* 또는 직무*가 변경*
된 사실(예: 사무관리↔현장관리)을 지체없이 회사에 알리지 않은 경우 계약 해지 등 알릴 의무 위반에 따른 불
이익*이 발생할 수 있습니다.
 5-1. 현재 운전을 하고 있습니까?  (예, 아니오)
 5-2.  “예”인 경우 운전 차종 (   ,   )
가. 승용차(영업용)     나. 승용차(자가용)
다. 승합차(영업용)     라. 승합차(자가용)
마. 화물차(영업용)     바. 화물차(자가용)
사. 이륜자동차(영업용)
아. 이륜자동차(자가용)
자. 건설기계           차. 농기계  
   카. 기타                    
※ 기타에 해당하는 경우 차종을 구체적으로 기재하고, 둘 이상의 차량을 운전하거나 하나의 차량을 둘 이상의 목
적으로 사용하는 경우 해당되는 사항을 모두 기재하십시오.
5-3. 원동기장치 자전거(전동킥보드, 전동이륜평행차, 전동기의 동력만으로 움직일 수 있는 자전거 등 개인형 이동
장치를 포함)를 사용하십니까?(다만, 전동휠체어, 의료용 스쿠터 등 보행보조용 의자차는 제외합니다) (예, 아니
오)
※ 계속적으로 사용(직업, 직무 또는 동호회 활동과 출퇴근용도 등으로 주로 사용하는 경우에 한함)하는 경우 기재
   본 질문에 ‘아니오’로 기재하고 보험계약 체결 후 이륜자동차* 또는 전동킥보드 등 개인형이동장치*를 포함한 원
동기장치 자전거*를 사용하게 된 사실을 지체없이 회사에 알리지 않은 경우 계약 해지 등 알릴 의무 위반에 따
른 불이익*이 발생할 수 있습니다.
6. 월소득(보험계약자 기준)은 얼마입니까?(계약자 기준, 단 계약자가 미성년자, 주부인 경우 총소득 입력)
월평균            만원
보험설계사는 계약 전 알릴의무* 사항에 대한 수령권한이 없으므로 과거의 진단 또는 치료 사실 등 중요한 내용을 
구두*로만 알릴 경우 계약 전 알릴의무를 이행한 것으로 인정되지 않아 향후 계약이 해지*되거나 보험금을 지급받
지 못할 수 있습니다.
* 보험계약자가 직접 기재하여야 하는 문구
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (130, 3, 14, '- 14 -
보험계약자 OOO는 보험설계사 OOO로부터 계약 전 알릴의무 위반시의 효과(계약해지, 보장제한, 보험금 미지급 
등)에 대해 설명을 들었으며, 
계약 전 알릴의무 사항에 대해 청약서에 사실대로 기재하였음을 확인합니다.
년     월     일
DB손해보험 주식회사 貴中
  보험계약자 성명             (인)
  피보험자(보험대상자)성명     (인)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (131, 3, 15, '- 15 -
【별첨3】
암주요치료비 보장에 대한 계약자 안내사항
 
1. 보험금 지급사유
- 암주요치료비 보장은 보장개시일(책임개시일) 이후에 약관에서 보장하는 암으로 최초 진단 
확정되고 “보험금 지급 대상기간” 이내에 약관에서 보장하는 암으로 암주요치료를 받은 
경우 “보험금 지급 대상기간” 동안 연간 1회에 한하여 보험금을 지급합니다.
- “보험금 지급 대상기간"이라 함은 "약관에서 보장하는 암 최초 진단확정일"로부터 5년으로 
암주요치료를 받은 경우 보험금 지급의 대상이 되는 기간을 말합니다.
  
암주요치료비(유사암제외)(연간1회한) 지급예시 
(보험계약일로부터 1년 이후 암 최초진단 기준, 보험가입금액 1,000만원기준)
 •계약일 : 2023년 7월 1일
 •위암 최초진단 확정일 : 2025년 1월 1일
 •식도암 최초진단 확정일 : 2027년 1월 1일                            
진단 후 
1차년도
진단 후 
2차년
도
진단 후 
3차년도
진단 후 
4차년
도
진단 후 
5차년도
A    B
D  A   B
C
D
2025년
1월1일
2026년
1월1일
2027년
1월1일
2028년
1월1일
2029년
1월1일
  
2030년
  1월1일
구분
진단 후 
1차년도
진단 후
 2차년도
진단 후 
3차년도
진단 후 
4차년도
진단 후 
5차년도
보험금
1,000만원
-
1,000만원
1,000만원
1,000만원
※ 2025년 1월1일 위암 최초 진단 이후 위암 이외의 암(유사암제외)을 최초 진단받더라도 보험금 지급대상은 
2025년1월1일로부터 5년입니다.
A : 암수술(위암)
B : 항암방사선치료(위암)
C : 항암약물치료(위암)
D : 항암약물치료(식도암)
2. 암 주요치료의 정의
- “암 주요치료" 에는 암수술, 항암방사선치료, 항암약물치료가 포함됩니다. 
- 식이요법, 명상요법 등 암의 제거 또는 암의 증식 억제를 위하여 의학적으로 안전성과 유효
성이 입증되지 않은 치료, 면역력 강화 치료, 암이나 암 치료로 인하여 발생한 후유증 또는 
합병증의 치료, 호르몬 관련 치료 및 “암 주요치료”와 관련없는 각종 비용(진찰료,입원
료,마취료,검사료 등)은 “암 주요치료“에 포함되지 않습니다.
※ 보다 자세한 내용은 반드시 약관을 참조하시기 바랍니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (132, 3, 16, '- 16 -
【별첨4】
순환계질환 주요치료비(요양병원제외) 보장에 대한 계약자 안내사항
1. 보험금 지급사유
- 순환계질환 주요치료비(요양병원제외) 보장은 보장개시일(책임개시일) 이후에 약관에서 보장하는 
순환계질환으로 진단 확정되고 “보험금 지급 대상기간” 이내에 해당질환으로 요양병원을 제외한 
병원 또는 의원에서 순환계질환 주요치료를 받은 경우 “보험금 지급 대상기간” 동안 연간 1회에 
한하여 보험금을 지급합니다.
- “보험금 지급 대상기간"이라 함은 보험기간 중 발생한 "약관에서 보장하는 순환계질환 최초 진단
확정일"로부터 10년으로 순환계질환 주요치료를 받은 경우 보험금지급의 대상이 되는 기간을 말
합니다.
2. 순환계질환 주요치료의 정의
- “순환계질환 주요치료" 에는 수술, 혈전용해치료, 종합병원 중환자실치료, 특정급여치료가 포함됩
니다. 
※ 보다 자세한 내용은 반드시 약관을 참조하시기 바랍니다.
순환계질환 주요치료비(요양병원제외) 지급예시 
(보험가입금액 1,000만원기준)
 •특별약관의 계약일 : 2024년 7월 1일
 •급성심근경색증 최초진단 확정일 : 2026년 1월 1일
 •뇌경색증 최초진단 확정일 : 2031년 1월 1일
                            
진단 후 
1차년도
진단 후 
2차년도
. . . . .
진단 후 
6차년도
. . . . .
진단 후 
9차년도
진단 후 
10차년도
A    B
A
A   C   D
B
D
<예시>
■ 가입 특별약관:
순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상) 또는
순환계질환(4-5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상) 또는
순환계질환(5종)주요치료비(요양병원제외)(연간1회한)(10년지급대상)
2026년
1월1일
2027년
1월1일
2028년
1월1일
2031년
1월1일
2032년
1월1일
2034년
1월1일
2035년
1월1일
2036년
1월1일
A : 수술(급성심근경색증)
B : 종합병원 중환자실치료
    (급성심근경색증)
C : 혈전용해치료(뇌경색증)
D : 혈전용해치료(급성심근경색증)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (133, 3, 17, '- 17 -
  
구분
진단 후 
1차년도
진단 후
 2차년도
.....
진단 후 
6차년도
.....
진단 후 
9차년도
진단 후 
10차년도
보험금
1,000만원
1,000만원
1,000만원
1,000만원
1,000만원
※ 2026년 1월1일 급성심근경색증 최초 진단 이후 급성심근경색증 이외의 약관에서 보장하는 순환계질환을 
최초 진단받더라도 보험금 지급대상기간은 2026년1월1일로부터 10년입니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (134, 4, 1, '무배당 프로미라이프
참좋은오토바이운전자보험1707
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (135, 4, 2, '') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (136, 4, 3, '무배당 프로미라이프 참좋은오토바이운전자보험1707
3
목차
자주 발생하는 민원 예시 ···········································································  6
신용정보 제공․활용에 대한 고객 권리 안내문···········································  8
가입자 유의사항·························································································  10
주요내용 요약서·························································································  12
보험금 청구시 준비하셔야 할 서류··························································  15
프로미라이프 용어사전··············································································  21
 
프로미라이프 지식백과··············································································  25
보통약관
제1관 목적 및 용어의 정의········································································· 28
1. (목적) ····································································································· 28
2. (용어의 정의) ·························································································· 28
제2관 보험금의 지급···················································································· 29
3. (보험금의 지급사유) ················································································· 29
4. (보험금 지급에 관한 세부규정) ································································ 30
5. (보험금을 지급하지 않는 사유) ································································ 30
6. (보험금 지급사유의 통지) ········································································· 30
7. (보험금의 청구) ······················································································· 30
8. (보험금의 지급절차) ················································································· 31
9. (만기환급금의 지급) ················································································· 31
10. (보험금 받는 방법의 변경) ····································································· 32
11. (주소변경통지) ······················································································· 32
12. (보험수익자의 지정) ··············································································· 32
13. (대표자의 지정) ····················································································· 32
제3관 계약자의 계약 전 알릴 의무 등······················································· 32
14. (계약 전 알릴 의무) ·············································································· 32
15. (계약 후 알릴 의무) ·············································································· 33
16. (알릴 의무 위반의 효과) ········································································ 33
17. (사기에 의한 계약) ················································································ 34
제4관 보험계약의 성립과 유지···································································· 34
18. (보험계약의 성립) ·················································································· 34
19. (청약의 철회) ························································································ 35
20. (약관교부 및 설명의무 등) ····································································· 35
21. (계약의 무효) ························································································ 36
22. (계약내용의 변경 등) ············································································· 37
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (137, 4, 4, '4
23. (보험나이 등) ························································································ 37
24. (계약의 소멸) ························································································ 37
제5관 보험료의 납입···················································································· 38
25. (제1회 보험료 및 회사의 보장개시) ························································ 38
26. (제2회 이후 보험료의 납입) ··································································· 38
27. (보험료의 자동대출납입) ········································································ 38
28. (보험료의 납입이 연체되는 경우 납입최고(독촉)와 계약의 해지) ············· 39
29. (보험료의 납입을 연체하여 해지된 계약의 부활(효력회복)) ······················ 39
30. (강제집행 등으로 인한 해지계약의 특별부활(효력회복)) ·························· 40
제6관 계약의 해지 및 해지환급금 등························································· 40
31. (계약자의 임의해지 및 피보험자의 서면동의 철회) ·································· 40
32. (중대사유로 인한 해지) ·········································································· 40
33. (회사의 파산선고와 해지) ······································································ 40
34. (해지환급금) ·························································································· 40
35. (공시이율의 적용 및 공시) ····································································· 41
36. (중도인출금) ·························································································· 41
37. (보험계약대출) ······················································································· 41
38. (배당금의 지급) ····················································································· 41
제7관 보험계약의 자동갱신 등(2종限) ······················································· 42
39. (적용범위) ····························································································· 42
40. (보험기간 및 자동갱신) ········································································ 42
41. (갱신계약 제1회 보험료의 납입이 연체되는 경우 납입최고(독촉)와 계약의 해지) · 42
42. (자동갱신 적용) ····················································································· 42
제8관 분쟁조정 등······················································································· 42
43. (분쟁의 조정) ························································································ 42
44. (관할법원) ····························································································· 42
45. (소멸시효) ····························································································· 42
46. (약관의 해석) ························································································ 43
47. (회사가 제작한 보험안내자료 등의 효력) ················································ 43
48. (회사의 손해배상책임) ··········································································· 43
49. (개인정보보호) ······················································································· 43
50. (준거법) ································································································ 43
51. (예금보험에 의한 지급보장) ··································································· 43
특별약관
제 1장 상해관련 특별약관
1. 이륜자동차 운전중 교통상해사망(비갱신형/갱신형) 특별약관······················ 46
2. 이륜자동차 운전중 교통상해후유장해(3~100%) (비갱신형/갱신형) 특별약관·· 47
3. 이륜자동차 운전중 교통상해80%이상후유장해
(비갱신형/갱신형) 특별약관······································································ 49
4. 이륜자동차 운전중 교통상해입원일당(1일이상180일한도)
(비갱신형/갱신형) 특별약관······································································ 51
5. 이륜자동차 운전중 교통상해입원일당(4일이상180일한도)
(비갱신형/갱신형) 특별약관······································································ 52
6. 이륜자동차 운전중 교통상해 골절진단비(치아제외)
(비갱신형/갱신형) 특별약관······································································ 54
7. 이륜자동차 운전중 교통상해 안면열상치료비(3cm이상)
(비갱신형/갱신형) 특별약관······································································ 55
8. 이륜자동차 운전중 교통상해 인대 및 힘줄(건)파열치료비
(비갱신형/갱신형) 특별약관······································································ 56
9. 이륜자동차 운전중 교통상해수술비(동일사고당 1회지급)
(비갱신형/갱신형) 특별약관······································································ 58
10. 이륜자동차 운전중 중대한 교통상해수술비(1~3급)
(동일사고당 1회지급)(비갱신형/갱신형) 특별약관···································· 60
11. 이륜자동차 운전중 자동차부상치료비(1~10급)
(비갱신형/갱신형) 특별약관···································································· 62
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (138, 4, 5, '무배당 프로미라이프 참좋은오토바이운전자보험1707
5
제 2장 비용손해관련 특별약관
1. 이륜자동차 운전중 교통사고처리지원금(실손, 동승자제외)
(비갱신형/갱신형) 특별약관······································································ 66
2. 벌금(실손)(비갱신형/갱신형) 특별약관······················································· 69
3. 자동차사고 변호사선임비용(실손)(비갱신형/갱신형) 특별약관····················· 70
4. 면허취소보험금(영업용)(비갱신형/갱신형) 특별약관··································· 72
5. 면허정지일당(영업용)(비갱신형/갱신형) 특별약관······································· 74
6. 민사소송법률비용손해(실손)(비갱신형/갱신형) 특별약관····························· 75
7. 행정소송법률비용손해(실손)(비갱신형/갱신형) 특별약관····························· 80
8. (가족)과실치사상벌금(실손)(비갱신형/갱신형) 특별약관······························ 85
9. 업무상과실·중과실치사상벌금(실손, 형법 제 268조 관련)
(비갱신형/갱신형) 특별약관······································································ 86
10. 보복운전피해위로금(비갱신형/갱신형) 특별약관······································· 88
11. 보복운전피해(인적물적)위로금(비갱신형/갱신형) 특별약관························ 89
제도성 특별약관
1. 보험료자동납입 특별약관·········································································· 94
2. 선지급서비스 특별약관············································································· 94
3. 지정대리청구서비스 특별약관··································································· 96
4. 단체취급 특별약관··················································································· 97
5. 전자서명 특별약관··················································································· 98
6. 갱신형 계약 자동갱신 특별약관································································ 99
【별표1】 보험금을 지급할 때의 적립이율 계산················································· 101
【별표2】 장해분류표························································································ 101
【별표3】 자동차사고 부상등급표······································································ 112
【별표4】 교통사고처리특례법 제3조 제2항 단서··············································· 120
【별표5-1】 소송목적의 값에 따른 변호사비용··················································· 121
【별표5-2】 민사소송 등 인지법」에서 정한 인지액············································· 121
【별표5-3】 「송달료규칙의 시행에 따른 업무처리요령」에서 정한 송달료············· 121
【별표6-1】 소송목적의 값에 따른 변호사비용··················································· 122
【별표6-2】 민사소송 등 인지법」에서 정한 인지액············································· 122
【별표6-3】 「송달료규칙의 시행에 따른 업무처리요령」에서 정한 송달료············· 122
참고. 약관에서 인용한 법규····································································  123
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (139, 4, 6, '6
자주 
발생하는
민원 예시
 
• 사례 : A씨는 보험가입 6개월 후 개인사유로 보험계약을 해지하였으며, 해지시 
해지환급금이 납입한 보험료보다 적은 것에 대한 불만을 제기하였습니다.
• 유의사항 : 보험계약은 은행의 저축과 달리 납입한 보험료 중 일부는 다른 계약자
에게 보험금으로 지급되며, 또다른 일부는 보험회사의 운영에 필요한 경비로 사용
되어 해지환급금이 납입한 보험료보다 적거나 없을 수 있습니다.
  
• 사례 : A씨는 보험가입 3년 후 콜센터를 통하여 가입한 상품의 환급률을 확인해 
보았으며, 최초 가입시 가입설계서에서 안내받은 3년시점의 환급률보다 낮은 것에 
불만을 제기하였습니다.
• 유의사항 : 금리연동형 상품의 경우, 공시이율을 적용하여 적립부분 순보험료를 
적립하고 있습니다. 공시이율은 회사의 운용자산이익률과 시중지표금리에 연동되
며, 공시이율의 변경에 따라 적립부분 적립금은 변동될 수 있습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (140, 4, 7, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
7
• 사례 : A씨는 통원치료후 병원 외래의료비 및 약제의료비(처방조제비)를 실손의료
비 특별약관 보험금으로 청구하였으나, 각각 공제금액이 발생한 것에 대하여 불만
을 제기하였습니다.
• 유의사항 : 실손의료비의 통원의료비는 외래의료비와 약제의료비(처방조제비)로 구
분되어 있고, 공제금액을 각각 적용하고 있습니다. 외래의료비의 경우에는 요양기
관별로 방문 1회당, 약제의료비(처방조제비)의 경우에는 처방전 1건당 각각 약관
에서 정한 금액을 공제한 후 보험금을 지급해드리고 있습니다.  
• 사례 : A씨는 치료목적으로 한의원에서 치료를 받고 실손의료비 특별약관 보험금
을 청구하였으나, 비급여부분이 보상되지 않는 것에 대한 불만을 제기하였습니다.
• 유의사항 : 실손의료비 특별약관에서 정한 "보상하지 않는 사항"에 따라, 한방치료
에서 발생한 국민건강보험법상 요양급여에 해당하지 않는 비급여 의료비는 보상하
여 드리지 않고 있습니다.
그 밖의 보상하지 않는 사항에 대하여는 반드시 약관을 확인하시기 바랍니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (141, 4, 8, '8
신용정보 
제공․활용에 
대한 고객 
권리 안내문
가. 금융서비스 이용범위
고객의 신용정보는 고객이 동의한 이용목적만으로 사용되며, 보험관련 금융서비스는 
제휴회사 등에 대한 정보의 제공․활용 동의여부와 관계없이 이용하실 수 있습니다. 다
만, 제3자에 대한 정보의 제공․활용에 동의하지 않으시는 경우에는 제휴․부가서비스, 
신상품서비스 등은 제공받지 못할 수도 있습니다.
나. ｢신용정보의 이용 및 보호에 관한 법률｣상의 고객 권리
• 본인정보의 제3자 제공사실 통보 요구 
고객은 「신용정보의 이용 및 보호에 관한 법률」제35조에 따라 금융회사가 본인정보를 
전국은행연합회, 신용조회회사, 타 금융회사 등 제3자에게 제공한 경우 제공한 본인
정보의 주요 내용 등을 알려주도록 금융회사에 요구할 수 있습니다.
• 금융거래 거절 근거 신용정보 고지 요구
고객은 ｢신용정보의 이용 및 보호에 관한 법률｣ 제36조에 따라 금융회사가 전국은행
연합회, 신용조회회사 등으로부터 제공받은 연체정보 등에 근거하여 금융거래를 거절․
중지하는 경우에는 그 거절․중지의 근거가 된 신용정보, 동 정보를 제공한 기관의 명
칭․주소․연락처 등을 고지해 줄 것을 금융회사에 요구할 수 있습니다.
• 본인정보의 제3자 제공 및 마케팅 목적의 전화 등의 중단 요구
고객은 ｢신용정보의 이용 및 보호에 관한 법률｣ 제37조에 따라 가입 신청시 동의를 
한 경우에도 본인정보를 제3자에게 제공하는 것 및 해당 금융회사가 마케팅 목적으
로 본인에게 연락하는 것을 전체 또는 사안별로 중단 시킬 수 있습니다.(다만, 고객
의 신용도 등을 평가하기 위해 전국은행연합회 또는 신용조회회사 등에 제공하는 것
에 대해서는 중단시킬 수 없습니다.)
신청자 제한 : 신규 거래고객은 계약을 체결한 날로부터 3개월간은 신청할 수 없습
니다.
• 본인정보의 열람 및 정정 요구
고객은 「신용정보의 이용 및 보호에 관한 법률｣ 제38조에 따라 전국은행연합회, 신용
조회회사, 금융회사 등이 보유한 본인정보에 대해 열람 청구가 가능하며, 본인정보가 
사실과 다른 경우에는 이의 정정 및 삭제를 요구할 수 있으며, 그 처리결과에 이의가 
있는 경우에는 금융위원회에 시정을 요청할 수 있습니다.
• 본인정보의 무료 열람 요구
고객은 ｢신용정보의 이용 및 보호에 관한 법률｣ 제39조에 따라 본인정보를 신용조회
회사를 통하여 연간 일정 범위 내에서 무료로 열람할 수 있습니다. 자세한 사항은 각 
신용조회회사에 문의하시기 바랍니다. 
NICE신용평가정보(주)
02-3771-1000
www.nicecredit.com
서울신용평가정보(주)
1577-1006  
www.sci.co.kr
코리아크레딧뷰로(주)
02-708-6000
www.koreacb.com
다. 고객불편사항 연락처
• 고객 신용정보의 제공․활용 중단 신청
고객은 가입신청 시 동의한 본인정보의 제3자에 대한 제공 또는 당사의 보험․금융상
품(서비스) 소개 등 영업목적 사용에 대하여 전체 또는 사안별로 제공․활용을 중단 시
킬 수 있습니다. 다만, 신용정보 인프라를 해하거나, 신용정보 집중기관, 신용정보업
자, 업무위탁회사 등에 대한 정보를 제한함으로서 금융회사의 업무 효율성을 저해할 
우려가 있는 경우의 동의철회는 제한됩니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (142, 4, 9, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
9
본인정보 활용의 제한․중단을 원하시는 고객은 아래의 연락처로 신청하여 주시기 바
랍니다.
ㆍ전화번호 : 080-323-0100
ㆍ홈페이지 : www.idongbu.com
ㆍ우   편 : 서울특별시 강남구 테헤란로 432 (대치동, 동부금융센터) 
동부화재해상보험(주)  소비자보호파트
※ 단, 신규거래 고객은 계약을 체결한 날로부터 3개월간은 신청할 수 없습니다.
위의 신청과 관련한 불편과 애로가 있으신 경우에는 아래의 담당자 앞으로 연락하여 
주시기 바랍니다.
당사 개인신용정보
고충처리담당자
손해보험협회
개인신용정보
보호담당자
금융감독원
금융민원센터
연락처
(02) 3011-4992
(02) 3702-8500
1332
주  소
서울특별시 강남구 
테헤란로 432
(대치동, 동부금융센터)
동부화재해상보험(주)
소비자보호파트
서울특별시 종로구 
종로5길 68, 6층
(수송동, 코리안리빌딩)
서울특별시 영등포구 
여의대로 38
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (143, 4, 10, '10
가입자 
유의사항
가. 보험계약관련 유의사항
• 보험계약 전 알릴의무 위반
_ 과거 질병 치료사실 등을 회사에 알리지 않을 경우 보험금을 지급받지 못할 수 있
습니다.
_ 과거 질병 치료사실 등을 보험설계사에게 말로써 알린 경우에는 보험금을 지급받
지 못하는 등 불이익을 받을 수 있으므로, 반드시 청약서에 서면으로 알리시기 바
랍니다.
_ 전화 등 통신수단을 통해 보험에 가입하는 경우에는 별도의 서면질의서 없이 안내
원의 질문에 답하고 이를 녹음하는 방식으로 계약 전 알릴의무를 이행하여야 하므
로 답변에 특히 주의하셔야 합니다.
• 갱신/부활
_ 부활(효력회복)계약의 암보장 개시일은 부활(효력회복)일을 포함하여 90일이 지난
날의 다음날로 합니다.
_ 갱신계약의 보험료는 보험나이 증가, 기초율 변동(의료비 상승, 적용이율, 위험률 
등)에 따라 최초계약 당시보다 인상될 수 있습니다.
나. 해지환급금에 관한 사항
보험계약을 중도 해지시 해지환급금은 이미 납입한 보험료보다 적거나 없을 수 있습
니다. 그 이유는 납입한 보험료중 위험보장을 위한 보험료, 사업비 및 특약보험료를 
차감한 후 운용․적립되고, 해지시에는 적립금에서 이미 지출한 사업비해당액을 차감하
는 경우가 있기 때문입니다.
가. 암 관련 담보
• 보험계약일로부터 90일 이내에 암으로 진단받은 경우에는 보험금을 지급하지 않
습니다. (단, 15세미만자 제외)
• 90일이 경과한 이후에도 암 진단일이 보험계약일로부터 일정기간(예 : 1년 등)이
내인 경우 보험금이 삭감될 수 있습니다. 
• 암은 원칙적으로 조직검사, 미세바늘흡인검사(미세한 침을 이용한 생체검사 방법) 
또는 혈액검사에 대한 현미경 소견을 기초로 한 진단만 인정됩니다.
나. 특정질병 관련 담보
• 암, CI보험 등 특정질병을 보장하는 보험은 약관이나 별표에 나열되어 있는 질병
에 대해서만 보험금을 지급합니다.
다. 간병 관련 담보
• ‘활동불능상태’란 보조기구를 사용하여도 이동, 식사, 목욕, 옷입기 등 생명유지에 
필요한 일상생활 기본동작들을 스스로 할 수 없는 상태가 90일 이상 계속되어 호
전될 것을 기대할 수 없는 상태를 말합니다.
• ‘치매’는 약관에서 정한 일정정도 이상의 중증치매인 경우에 한하여 보험금이 지급
됩니다.
라. CI 관련 담보
• CI보험은 전체 질병이 아닌 중대한 암 등 약관에서 정하는 특정한 질병만을 보험
금 지급대상으로 하므로, 중대한 질병이 무엇인지를 반드시 확인하시기 바랍니다.
마. 수술 관련 담보
• 약관상 수술의 정의에 포함되지 않는 조작의 경우(예 : 주사기 등으로 빨아들이는 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (144, 4, 11, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
11
처치, 바늘 등을 통해 체액을 뽑아내거나 약물을 주입하는 것 등) 보험금을 지급
하지 않습니다.
• 수술분류표를 사용하는 보험은 동 분류표에 기재되어 있는 수술만을 지급대상으로 
합니다.
바. 입원 관련 담보
• 의료기관에 입실하여 의사의 관리하에 치료에 전념하지 않거나 정당한 사유없이 
입원기간 중 의사의 지시에 따르지 않은 때에는 입원일당의 전부 또는 일부를 지
급하지 않습니다.
사. 실손의료비 관련 담보
• 이 특별약관은 발생 의료비 중 국민건강보험 급여의 본인부담금과 비급여를 보장
해주는 보험이며, 약관상 보장제외 항목에서 발생한 의료비는 보장되지 않습니다.
보험
지식
실손의료비 범위
총 진료비 중에서 국민건강보험에서 부담한 금액을 제외하고 환자 본인이 부
담한 금액
국민건강보험 급여항목
비급여항목
국민건강보험 부담
환자본인부담
환자본인부담
• 실제 발생한 의료비를 보상하는 보험을 2개 이상 가입하더라도 실제 발생한 비용
만을 보상받게 되므로, 유사한 보험가입여부 및 보상한도를 반드시 확인하시기 바
랍니다.
• 보험금을 지급할 다수의 보험계약이 체결되어 있는 경우에는 각각의 계약에 대하
여 다른 계약이 없는 것으로 하여 산출한 보상책임액의 합계액이 이 계약의 의료
비를 초과했을 때, 회사는 이 계약에 따른 보상책임액의 위의 합계액에 대한 비율
에 따라 의료비보험금을 지급합니다.
• 실손의료비 특별약관의 보험기간은 1년만기로, 최초가입 후 보장내용 변경주기동
안 자동갱신됩니다. 자동갱신종료 후에는 재가입을 통해 보장받을 수 있습니다.
• 갱신시 보험요율의 변동에 따라 보험료가 인상 또는 인하될 수 있습니다.
아. 갱신형 특별약관 갱신에 관한 사항
• 갱신형 특별약관의 보험기간은 3년 또는 7년만기로, 최초가입 후 3년 또는 7년마
다 갱신을 통해 만기시까지 보장받을 수 있습니다.
• 갱신시 보험요율의 변동에 따라 보험료가 인상 또는 인하될 수 있습니다.
• 갱신형 특별약관의 보험료는 보통약관 보험료납입기간과 관계없이 보험기간동안 
계속해서 납입하여야 합니다. 
• 약관에 따라 보통약관의 보장보험료가 납입면제되는 경우에도 갱신형 특별약관의 
보험료는 만기까지 계속 납입하여야 합니다.
자. 배상책임 관련 담보 등 다수계약의 비례보상에 관한 사항
• 이 계약에서 담보하는 위험과 같은 위험을 담보하는 다른 계약(공제계약을 포함합
니다)이 있을 경우에는 각 계약에 대하여 다른 계약이 없는 것으로 하여 각각 산
출한 보상책임액의 합계액이 손해액을 초과할 때에는 회사는 아래에 따라 보상합
니다.
산식
손해액
×
이 계약에 의한 보상책임액
다른 계약이 없는 것으로 하여 각각 계산한 
보상책임액의 합계액
이 가입자 유의사항은 약관의 주요내용을 요약 발췌한 것이므로 기타 자세한 
사항은 해당약관(보통약관, 특별약관)의 내용을 따릅니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (145, 4, 12, '12
주요내용 
요약서
가. 자필서명
계약자와 피보험자가 자필서명을 하지 않으신 경우에는 보장을 받지 못할 수 있습니
다. 다만, 전화를 이용하여 가입할 때 일정요건이 충족되면 자필서명을 생략할 수 있
으며, 인터넷을 이용한 사이버몰에서는 전자서명으로 대체할 수 있습니다.
나. 청약철회
계약자는 보험증권을 받은 날로부터 15일이내에 그 청약을 철회할 수 있습니다. 다
만, 진단계약,  보험기간이 1년 미만인 계약 또는 전문보험계약자가 체결한 계약은 
청약을 철회할 수 없으며. 청약을 한 날로부터 30일을 초과한 경우에도 청약을 철회
할 수 없습니다. 이 경우 보험증권의 교부에 관하여 다툼이 있으면 보험회사가 이를 
증명해야 합니다.
          
다. 계약취소
계약을 체결할 때 보험약관과 계약자 보관용 청약서를 전달받지 못하였거나 약관의 
중요한 내용을 설명받지 못한 때 또는 청약서에 자필서명(날인(도장을 찍음) 및 전자
서명법 제2조 제2호에 따른 전자서명 또는 동법 제2조 제3호에 따른 공인전자서명
을 포함합니다)을 하지 않은 때에는 계약자는 계약이 성립한 날부터 3개월 이내에 
계약을 취소할 수 있으며, 이 경우 회사는 이미 납입한 보험료를 돌려 드리며, 보험
료를 받은 기간에 대하여 해당 보험약관에서 정한 이율로 계산한 금액을 더하여 되돌
려 드립니다.        
라. 계약의 무효(신체 관련)
다음 중 한 가지에 해당하는 경우 회사는 계약을 무효로 합니다.
_ 타인의 사망을 보장하는 계약에서 피보험자의 서면 동의를 얻지 않은 경우. 이 때 
단체보험의 보험수익자를 피보험자 또는 그 상속인이 아닌 자로 지정할 때에는 단
체의 규약에서 명시적으로 정한 경우가 아니면 이를 적용합니다.
_ 만 15세 미만자, 심신상실자 또는 심신박약자를 피보험자로 하여 사망을 보험금 
지급사유로 한 계약의 경우. 다만, 심신박약자가 계약을 체결하거나 소속 단체의 
규약에 따라 단체보험의 피보험자가 될 때에 의사능력이 있는 경우에는 그 계약을 
유효한 것으로 봅니다.
_ 계약을 체결할 때 계약에서 정한 피보험자의 나이에 미달되었거나 초과되었을 경우. 
다만, 회사가 나이의 착오를 발견하였을 때 이미 계약나이에 도달한 경우에는 유효
한 계약으로 보나, 위 만 15세 미만자에 관한 예외가 인정되는 것은 아닙니다.
마. 계약의 무효(재물 관련)
계약을 맺을 때 보험목적에 이미 사고가 발생하였을 경우 회사는 계약을 무효로 하며 
이미 납입한 보험료를 돌려 드립니다.
바. 계약의 소멸(신체 관련)
이 계약은 피보험자의 사망 등으로 인하여 보험금 지급사유가 더 이상 발생할 수 없
는 경우, 그때부터 효력을 가지지 않습니다.
사. 계약의 소멸(재물 관련)
_ 비례보상 : 보험금이 한 번의 사고에 대하여 보험가입금액(보험가액을 한도로 합니
다)의 80%를 넘을 경우에는 그 손해보상의 원인이 생긴 때로부터 해당 보험목적
에 대한 계약은 소멸됩니다.
_ 실손보상 : 보험금이 한 번의 사고에 대하여 보험가입금액(보험가액을 한도로 합니
다)을 넘을 경우에는 그 손해보상의 원인이 생긴 때로부터 해당 보험목적에 대한 
계약은 소멸됩니다.
아. 보험료의 납입연체 및 계약의 해지에 관한 사항
계약자가 제2회 이후 보험료를 납입기일까지 납입하지 않아 보험료 납입이 연체 중
인 경우에 회사는 14일 이상의 기간을 납입최고(독촉)기간(납입최고(독촉)기간의 마
지막 날이 영업일이 아닌 때에는 최고(독촉)기간은 그 다음 날까지로 합니다)으로 정
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (146, 4, 13, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
13
용어
정의
유상운송 
배달용
피보험자가 수당, 요금 등 대가의 보상을 직접적인 목적으로 물건 등의 
배달을 위해서 이륜자동차를 운전하는 경우를 말합니다.
(예) 매 배달시마다 요금이나 대가를 수령하는 퀵서비스, 이륜자동차를 
이용한 택배 등
비유상운송 
배달용
피보험자가 「유상운송 배달용」 이외의 목적으로 물건 등의 배달을 
위해서 이륜자동차를 운전하는 경우를 말합니다.
(예) 매 배달시 요금이나 대가를 수령하지 않는 피자, 치킨 등 음식 
배달 및 우편배달 등
가정용 
및 기타용도
상기 「유상운송 배달용」 및 「비유상운송 배달용」 이외의 목적으로 
이륜자동차를 운전하는 경우를 말합니다.
(예) 출퇴근용도, 보안경비용 등
하여 계약자에게 안내하여 드리며, 그 때까지 보험료를 납입하지 않을 경우 납입최고
(독촉)기간이 끝나는 날의 다음날 계약이 해지됩니다.
자. 해지 계약의 부활(효력회복)
보험료 납입연체로 보험계약이 해지되었으나 해지환급금을 받지 않은 경우 계약자는 
해지된 날부터 3년 이내에 회사가 정한 절차에 따라 보험계약의 부활(효력회복)을 청
약할 수 있습니다. 회사는 계약자 또는 피보험자의 건강상태, 직업, 직종 등에 따라 
승낙여부를 결정하며, 합리적인 사유가 있는 경우 부활(효력회복)을 거절하거나 보장
의 일부를 제한할 수 있습니다.
차. 중도인출
중도인출이 가능한 상품의 경우, 계약자의 요청이 있는 때에는 중도인출금을 지급합
니다. 중도인출금을 청구할 수 있는 시기, 횟수 및 금액은 상품마다 다를 수 있으니 
해당 상품의 약관을 참조하시기 바랍니다.
카. 계약 전․후 알릴 의무
1) 계약 전 알릴의무 : 계약자, 피보험자는 보험에 가입하실 때 청약서의 질문사항
에 사실대로 기재하고 자필서명(전자서명 포함)을 하셔야 합니다(단, 전화를 이용
하여 계약을 체결하는 경우에는 음성녹음으로 대체합니다).
2) 계약 후 알릴의무 : 계약자 또는 피보험자는 보험계약을 맺은 후 아래와 같은 
경우 지체없이 서면으로 회사에 알리고 보험증권에 확인을 받아야 합니다.
    _ 피보험자가 직업 또는 직무를 변경(가정용 및 기타용도 이륜자동차 운전자가 
유상운송 배달용 및 비유상운송 배달용 이륜자동차 운전자로 직업 또는 직무
를 변경하는 경우를 포함합니다)하거나 이륜자동차 운행목적을 변경하여 계속
적으로 사용하는 경우 지체없이 회사에 알려야 합니다.
      ※ 이륜자동차 운행목적 관련 용어 
    _ 보험목적물을 양도하거나 다른 장소로 옮기는 경우, 기타 위험이 증가하는 
경우 
3) 알릴의무 위반시 효과 : 회사가 별도로 정한 방법에 따라 계약을 해지하거나 
보험금 지급이 제한될 수 있습니다.
※ 계약자는 주소 또는 연락처가 변경된 경우 즉시 변경내용을 회사에 알리셔야 합니
다.
타. 보험금의 지급
1) 신체손해에 대한 보험금
회사는 보험금 청구서류를 접수한 때에는 접수증을 드리고 휴대전화 문자메시지 또는 
전자우편 등으로도 송부하며, 그 서류를 접수한 날부터 3영업일 이내에 지급합니다. 
다만, 회사가 보험금 지급사유를 조사․확인하기 위해 필요한 기간이 위 지급기일을 초
과할 것이 명백히 예상되는 경우에는 그 구체적인 사유와 지급예정일 및 보험금 가지
급 제도(회사가 추정하는 보험금의 50% 이내를 지급)에 대하여 피보험자 또는 보험
수익자에게 즉시 통지합니다.
만약 지급기일내에 보험금을 지급하지 않았을 때에는 그 다음날부터 지급기일까지의 
기간에 대하여 소정의 이자를 더하여 드립니다.
2) 재산손해에 대한 보험금
회사는 보험금 청구서류를 접수한 때에는 접수증을 드리고 휴대전화 문자메시지 또는 
전자우편 등으로도 송부하며, 그 서류를 접수받은 후 지체없이 지급할 보험금을 결정
하고 지급할 보험금이 결정되면 7일 이내에 이를 지급합니다. 그러나, 지급할 보험금 
결정되기 전이라도 피보험자의 청구가 있을 때에는 회사가 추정한 보험금의 50% 상
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (147, 4, 14, '14
당액을 가지급보험금으로 지급합니다.
만약 지급기일내에 보험금을 지급하지 않았을 때에는 그 다음날부터 지급기일까지의 
기간에 대하여 소정의 이자를 더하여 드립니다.
3) 배상책임에 대한 보험금
회사는 보험금 청구서류를 접수한 때에는 접수증을 드리고 휴대전화 문자메시지 또는 
전자우편 등으로도 송부하며, 그 서류를 접수받은 후 지체없이 지급할 보험금을 결정
하고 지급할 보험금이 결정되면 7일 이내에 이를 지급합니다. 그러나, 지급할 보험금 
결정되기 전이라도 피보험자의 청구가 있을 때에는 회사가 추정한 보험금의 50% 상
당액을 가지급보험금으로 지급합니다.
만약 지급기일내에 보험금을 지급하지 않았을 때에는 그 다음날부터 지급기일까지의 
기간에 대하여 소정의 이자를 더하여 드립니다.
파. 대위권
회사가 보험금을 지급한 때에는 회사는 지급한 보험금 한도내에서 계약자 또는 피보
험자가 제3자에 대하여 가지는 손해배상청구권을 취득합니다. 다만, 회사가 보상한 
금액이 피보험자가 입은 손해의 일부인 경우에는 피보험자의 권리를 침해하지 않는 
범위내에서 그 권리를 취득합니다.
이 주요내용 요약서는 약관의 주요내용을 요약 발췌한 것이므로 기타 자세한 
사항은 해당약관(보통약관, 특별약관)의 내용을 따릅니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (148, 4, 15, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
15
보험금 
청구시 
준비하셔야 
할 서류
구분
필요서류
비고
공통
- 보험금청구서(개인(신용)정보처리동의서, 
  계좌번호 포함)
- 청구인 신분증 사본
※ 가족관계 확인이 필요한 경우(배우자, 자녀
   등을 보장하는 상품, 수익자가 미성년자인 
   경우 등)
- 가족관계증명서, 혼인관계증명서, 
  주민등록등본, 의료보험카드사본 등
※ 대리인 청구시
- 위임장, 보험금 청구권자의 인감증명서(또는
  본인서명사실확인서), 보험금 청구권자의 
  개인(신용)정보처리동의서
※ 상해사고 청구시
- 사고 입증서류(별표 참조)
입원
실손
의료비
- 진단서
  [단, 청구금액 50만원 이하시 진단명이 포함된
   입퇴원 확인서 또는 진단명 및 입원기간이 
   포함된 진료확인서로 대체가능]
- 병원
구분
필요서류
비고
- 진료비계산서(영수증)
- 진료비세부(상세)내역서
입원
일당
- 입퇴원확인서
- 병원
통원
외래
의료비
10만원 
초과
- 병원 영수증
- 진단명이 포함된 서류
  (예시) 진단서․통원확인서․처방전․
   진료확인서․ 소견서․진료차트 등
- 병원
3만원 
초과 
10만원 
이하
- 병원 영수증
- (질병분류코드가 기재된) 처방전
  [단, 특정 진료과목(산부인과, 
   항문외과, 비뇨기과, 피부과 등) 
   및 짧은 기간내 보험금 청구횟수가
   과다한 경우 등 추가심사가 필요한 
   경우에는 별도의 추가증빙서류
   제출이 필요할 수 있음]
3만원 
이하
- 병원 영수증
  [단, 특정 진료과목(산부인과, 
   항문외과, 비뇨기과, 피부과 등) 및 
   짧은 기간내 보험금 청구횟수가 
   과다한 경우 등 추가심사가 필요한 
   경우에는 별도의 추가증빙서류
   제출이 필요할 수 있음]
약제
의료비
- 처방전
- 약제비계산서(영수증)
- 약국
골절
- 진단명이 포함된 서류
  (예시) 진단서․처방전․진료확인서․소견서․
        진료차트 등
- 병원
※ 사고내용, 특성, 상품(보장내역)에 따라 추가 심사서류를 요구할 수 있습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (149, 4, 16, '16
구분
필요서류
비고
수술
- 진단명, 수술명, 수술일자가 포함된 서류
  (예시) 수술확인서, 수술기록지, (진단명, 
   수술명, 수술일자가 포함된) 진단서 등
- 병원
진단
진단
암
- 진단서
- 진단사실 확인서류
  (예시) 조직검사결과지, MRI, CT판독결과지 등
  ※ 단계별로 더 받는 암보험의 경우에는 
     병기분류가 별도로 표기된 진단서 제출
- 병원
심질환
- 진단서
- 진단사실 확인서류
  (예시) 관상동맥 조영술, 심전도, 심초음파 
   검사결과지, 심장효소 혈액검사결과지 등
- 병원
뇌질환
- 진단서
- 진단사실 확인서류
  (예시) 뇌혈관조영술검사결과지, MRI, 
   CT판독결과지 등 
- 병원
기타
- 진단서
- 진단사실 확인서류
- 병원
장해
- 후유장해진단서
 ※ 발급 전 보험회사 콜센터 또는 
    지급담당자와 상의하시기 바랍니다.
- 병원
 ※ (일반)진단서로 대체 가능한 장해
 ㆍ만성신부전 : 최초 혈액투석일, 환자상태 
               기재
 ㆍ사지절단 : 절단부위, 환자상태 기재, 
             X-ray필름 첨부
구분
필요서류
비고
 ㆍ인공관절치환술 : 수술명, 수술일자 기재
 ㆍ비장, 신장적출 : 비장, 신장적출 수술일
                  기재
사망
- 사망진단서(시체검안서) 원본 또는 피보험자 
  기본증명서(사망사실 기재)가 첨부된 
  사망진단서(시체검안서) 사본(원본대조필
  포함)
- 병원
- 
가족관계증명서는 
사례별로 
다르므로 사전 
문의바랍니다.
※ 수익자 미지정시
- 상속관계 확인서류
  (예시) 가족관계증명서, 혼인관계증명서, 
   기본증명서 등
※ 1인의 상속인이 전액 수령을 원하는 경우
- 상속인 각각의 위임장
- 인감증명서(또는 본인서명사실확인서)
태아
신생아
입원비
- 출생증명서 또는 가족관계증명서
- 진단서
  [단, 청구금액 50만원 이하시 진단명이 포함된
   입퇴원 확인서 또는 진단명 및 입원기간이 
   포함된 진료확인서로 대체가능]
- 입퇴원확인서(인큐베이터 사용시 해당기간 
  명시)*
  * 진단서에 입원기간(인큐베이터 사용기간)이 
     포함된 경우는 제외
- 병원
유산
/사산
- 진단서(유산), 사산증명서(사산)
- 병원
응급비용
- 119 또는 129 구급구조증명서
- 소방서/ 구급대
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (150, 4, 17, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
17
구분
필요서류
비고
교통사고
- 공공기관(경찰서, 소방서 등), 손해보험사, 
  공제조합(버스, 화물, 택시 등) 사고사실확인서
- 공공기관
- 보험사/공제조합
산재사고
- 요양급여신청서 또는 보험급여지급확인원
- 근로복지공단
군복무중
사고
- 공무상병인증서
- 군부대
의료사고 등
법원분쟁
- 법원판결문
- 법원
기타
상해사고
- 공공기관(경찰서, 소방서 등) 사고사실확인서
- 공공기관
사고확인서류
발급불가시
- 병원초진차트 등 상해사고 증명서류 및 보험금 
  청구서상 사고내용 기재(6하원칙에 따라 
  상세기재)
- 병원
구분
필요서류
비고
공통
- 보험금청구서(개인(신용)정보처리동의서, 
  계좌번호 포함)
- 청구인 신분증 사본
- 사고입증서류
※ 대리인 청구시
- 위임장, 보험금 청구권자의 인감증명서(또는 
  본인서명사실확인서), 보험금 청구권자의 
  개인(신용)정보처리동의서
벌금
- 벌금영수증
- 법원 판결문 또는 약식 명령문
- 법원
자동차사고
변호사선임비용
- 판결문, 구속영장사본, 공소장, 공소사실확인원, 
  사건처분증명원, 재소․출소증명서 중 택일
- 선임한 변호사가 발행한 세금계산서
- 법원
면허정지
/취소
- 운전면허 정지처분 결정통지서(교육수료 후) 
  또는 면허정지 행정처분 확인서
- 운전면허 취소처분 결정통지서 또는 면허취소 
  확인원
- 경찰서
교통사고처리
지원금
- 형사합의서 또는 공탁서 사본
- 피해자에게 형사합의금 입금된 내역 확인서류
- 피해자 진단서 또는 사망진단서(시체검안서)
- 공소장(검찰에 의해 기소시)
- 법원
- 병원
자동차보험
할증지원금
- 자동차보험 보험금지급결의서
- 보험사
구분
필요서류
비고
한방치료
- 첩약, 약침, 특정한방물리요법 치료사항을    
  확인할 수 있는 구비서류 기재
  (예시) 진료비계산서(영수증), 
        진료비세부내역서, 진료확인서 등
- 한방병원/ 
한의원
※ 진단서, 통원확인서, 처방전, 진료확인서, 소견서, 수술확인서, 진료차트 등에는 진
단명이 기재되어 있어야 합니다.
<별표> 상해사고 입증서류 예시
※ 사고내용, 특성, 상품(보장내역)에 따라 추가 심사서류를 요구할 수 있습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (151, 4, 18, '18
구분
필요서류
비고
자동차
부상치료비
- 치료비 지급결의서
- 진단서
- 보험사
- 병원
자동차사고
성형수술비
- 진단서 또는 소견서(진단명, 성형수술 부위와 
  크기, 수술내용 포함)
- 병원
구분
필요서류
비고
공통
- 보험금청구서(개인(신용)정보처리동의서, 
  계좌번호 포함)
- 청구인 신분증 사본
※ 대리인 청구시
- 위임장, 보험금 청구권자의 인감증명서(또는
  본인서명사실확인서), 보험금 청구권자의 
  개인(신용)정보처리동의서
영구치
발거치료비
- 치과치료 진료확인서(아래 내용 반드시 포함)
 ․ 발거한 영구치의 위치 또는 치아번호
 ․ 해당 영구치의 내원 당시의 치아상태
 ․ 직접적인 영구치 발거원인
 ․ 진단확정일, 진료시작일, 진료종료일, 진료일수
- 치과진료기록 사본
- 치료 전후의 X-ray 사진 또는 이에 준하는 
  판독자료
- 병원
구분
필요서류
비고
영구치
보존치료비
- 치과치료 진료확인서(아래 내용 반드시 포함)
 ․ 치료한 치아의 위치 또는 치아번호
 ․ 해당 치아의 내원 당시의 상태
 ․ 직접적인 치아치료원인
 ․ 진단확정일, 진료시작일, 진료종료일, 진료일수
- 치과진료기록 사본
- 치료 전후의 X-ray 사진 또는 이에 준하는
  판독자료
- 병원
영구치
보철치료비
- 치과치료 진단서(아래 내용 반드시 포함)
 ․ 발거한 영구치의 위치 또는 치아번호
 ․ 해당 영구치의 내원 당시의 치아상태
 ․ 직접적인 영구치 발거원인
 ․ 진단확정일, 진료시작일, 진료종료일, 진료일수
- 치과진료기록 사본
- 치료 전후의 X-ray 사진 또는 이에 준하는 
  판독자료
- 병원
※ 사고내용, 특성, 상품(보장내역)에 따라 추가 심사서류를 요구할 수 있습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (152, 4, 19, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
19
구분
필요서류
공통
- 화재증명원(화재사고인 경우)
- 도난신고접수확인원(도난사고인 경우)
- 사고증명서(기타 사고)
- 보험금청구서(개인(신용)정보처리동의서, 계좌번호 포함)
- 청구인 신분증(사업자등록증) 사본
※ 대리인 청구시
- 위임장, 보험금 청구권자의 인감증명서(또는 본인서명사실
  확인서), 보험금 청구권자의 개인(신용)정보처리동의서
건물
- 건물등기부등본(등기소)
- 건축물관리대장
- 수리비 견적서, 영수증
- 임대차계약서 사본
기계비품
- 기계기구 명세서
- 구입영수증
- 신품가격 견적서
- 수리비 견적서, 영수증
- 감정평가서
- 리스계약서(리스물건)
동산
- 재고 및 손해명세서
- 재고장부
- 원가계산서
- 거래명세서
- 임가공계약서, 작업지시서
- 수불대장
구분
필요서류
비고
공통
- 보험금청구서(개인(신용)정보처리동의서, 
  계좌번호 포함)
- 청구인 신분증 사본
※ 대리인 청구시
- 위임장, 보험금 청구권자의 인감증명서(또는 
  본인서명사실확인서), 보험금 청구권자의 
  개인(신용)정보처리동의서
상해․질병
구직급여 
지원금
- 고용보험수급자격증
- 실업급여지급결정통지서(직업안정기관의 長
  발행)
- 병가신청서
- 의사소견서(상해, 질병으로 인하여 고용업체에
  서의 업무수행이 더 이상 불가능하다는 
  소견서)
구직급여일당
/장기구직급여
지원금
- 고용보험수급자격증
- 실업급여지급결정통지서(직업안정기관의 長 
  발행)
※ 사고내용, 특성, 상품(보장내역)에 따라 추가 심사서류를 요구할 수 있습니다.
가. 재물보험
※ 사고에 따라 담당자가 추가서류 또는 원본서류를 요구할 수 있습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (153, 4, 20, '20
구분
필요서류
가재도구
- 가재도구명세서(구입연월일 명기)
- 신품가격 견적서(구입처)
- 수리비 견적서, 영수증
구분
필요서류
피보험자(고객)의
신분을 확인하는 서류
- 보험금청구서(개인(신용)정보처리동의서, 계좌번호 포함)
- 청구인 신분증 사본
피보험자(고객)가
준비하는 서류
- 보험금 청구서(송금요청서)
- 사고경위서(6하 원칙에 의거하여 작성)
- 스코어 카드
- 동반자 확인서(홀인원/알바트로스 증명서)
  (동반 경기자, 동반 캐디, 해당 골프장 책임자 등의 
   공동서명․날인이 있어야 함)
- 기념품 구입비용, 축하 만찬 비용, 축하 라운드 등 비용 
  지출 명세서(선불카드, 상품권 등의 물품전표 제외)
나. 배상책임보험
※ 사고에 따라 담당자가 추가서류 또는 원본서류를 요구할 수 있습니다.
구분
필요서류
피보험자(고객)가
준비하는 서류
- 피보험자의 사업자등록증 사본
- 사고경위서(6하 원칙에 의거하여 작성)
- 사고현장의 사진
- 사고보증서(교통사고사실확인원 등)
- 합의서, 인감증명서(또는 본인서명사실확인서)
- 보험금 청구서(송금요청서)
손해액을
평가하는 서류
- 손해품목 명세서
- 견적서, 영수증(세금계산서)
- 피해품 사진
- 차량등록증 사본
- 치료비 영수증
- 의사의 진단서(소견서)
- 후유장해진단서(후유장해가 있는 경우)
- 근로계약서, 재직증명서
- 임금대장, 소득세 납세증명
- 사망진단서 또는 사체검안서(사망한 경우)
피해자의 신분을
확인하는 서류
- 피해자의 신분증(사업자등록증) 사본
- 건물등기부등본(피해목적물이 건물인 경우)
- 차량등록증 사본(피해목적물이 차량인 경우)
- 건설기계등록증 사본(피해목적물이 중기인 경우)
※ 사고에 따라 담당자가 추가서류 또는 원본서류를 요구할 수 있습니다.
• 경우에 따라 위 서류들은 다른 서류로 대체될 수 있습니다. 반드시 담당자와 필요
서류에 대하여 상의하시기 바랍니다.
• 기타 추가서류가 발생할 수 있으니 자세한 사항은 계약·보상상담 1588-0100으로 
문의바랍니다. 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (154, 4, 21, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
21
프로미라이프 
용어사전
계약자
보험회사와 계약을 체결하고 보험료 납입의무를 지는 사람
계약전 알릴 의무 
고지의무라고도 한다. 보험계약자 또는 피보험자는 계약체결시에 보험자에 대해서 고
지사항을 부실하게 알려서는 안될 의무를 지는데 이것을 계약전 알릴 의무라 한다. 
보험계약자가 이를 위반했을 때에는 보험자는 일정한 요건 아래 계약을 해지할 수 있
게 되어 있다. 그러나 회사가 계약당시에 그 사실을 알고 있었거나 중대한 과실로 인
하여 알지 못했을 경우에는 계약을 해지할 수 없으며, 회사가 그 사실을 안 날로부터 
1개월 이상 경과하였거나 보험계약자의 책임개시 이후 2년이 경과(건강진단을 받은 
경우는 1년 경과, 상법에서는 3년)된 경우에는 계약을 해지할 수 없다. 또한 계약전 
알릴 의무 위반의 사실이 보험금 지급사유 발생에 영향을 미쳤음을 회사가 증명하지 
못한 경우에는 계약의 해지 또는 보장을 제한하기 이전까지 발생한 해당보험금을 지
급해야 한다. 
계약후 알릴 의무 
보험계약자 또는 피보험자가 보험계약 체결 후 위험이 증가된 사실을 보험회사에 통
지하여야 하는 법률상 의무이다. 우리 상법 제652조와 제653조에서는 보험기간 중
에 보험계약자나 피보험자가 사고발생의 위험이 현저하게 변경 또는 증가된 경우 지
체 없이 보험회사에 통지하도록 정하고 있고 통지를 받은 보험회사는 1월내에 보험
료의 증액을 청구하거나 보험계약을 해지할 수 있도록 정하고 있다. 현행 손해보험표
준약관에서는 보험계약자 또는 피보험자가 직업 또는 직무를 변경하는 등 위험의 변
경사항 발생시 보험회사에 통지하도록 하고 있고 해당 변경내용에 따라 보험료가 증
액 또는 감액될 수 있도록 정하고 있다. 또한 동 의무를 이행하지 않을 경우 보험회
사는 변경 전 보험요율의 변경 후 보험요율에 대한 비율에 따라 보험금을 삭감하여 
지급할 수 있다. 이는 계약전 알릴의무(고지의무)와는 달리 보험계약 안에서 인정되
는 의무이다.
만기환급금
장기의 적립형보험에 있어서 보험기간이 만료될 때까지 일정규모 이상의 사고가 없는 
경우 납입보험료중 일정률의 금액을 보험계약자에게 환급하는 제도이다. 환급금은 납
입한 보험료에 포함된 적립보험료를 운용한 예정이자와 원리금의 합계액에 상당한다.
미경과보험료  [Unearned Premium] 
미경과보험료는 보험자가 보험계약자로부터 받은 영업보험료 중에서 아직 당해 보험
료기간이 경과하지 않은 보험료를 말한다. 가령 보험자가 1년치 보험료를 받은 후 6
개월이 경과했다면, 받은 보험료의 1/2은 나머지 6개월(미경과기간)에 대응하는 것으
로 미경과보험료라 한다. 미경과보험료는 보험자가 향후 제공할 보장서비스에 대응하
여 미리 수취한 금액에 해당되므로 보험회사의 입장에서는 부채로 계상된다. 즉 보험
자는 연1회의 결산시에 그 연도중에 수입보험료의 전부를 이익으로 간주할 수 없으
며 기 수취한 보험료 가운데 차기로 이월하는 미경과분을 미경과보험료준비금의 과목
으로 계상하게 된다. 
보험가액과 보험금액 
보험가액이란 보험사고가 발생하였을 경우에 보험목적에 발생할 수 있는 손해액의 최
고한도액을 말하며 손해보험에만 존재하는 개념이다. 보험금액이란 보험자와 보험계
약자간의 합의에 의하여 약정한 금액이며 보험사고가 발생하였을 경우에 보험자가 지
급할 금액의 최고한도를 말한다. 이같이 보험금액을 정하는 이유는 계약체결시에 보
험자의 보상한도를 명확히 함으로서 합리적이고 정확한 보험료율을 산출하기 위함이
다. 보험가액의 경우 때와 장소에 따라 변동 할 가능성이 있고, 책임보험이나 인보험
등은 평가자체가 불가능하기 때문에 보험금액을 기준으로 하여 보험자의 보상한도를 
구체화 하는 것이 바람직하다고 볼 수 있다. 
보험금액은 보험가액의 범위 내에서 정해져야 하며 보험가액을 초과하였을 경우에 그 
초과한 금액에 대해서는 보험자가 보상하지 않는다. 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (155, 4, 22, '22
보험가입금액
보험금, 보험료 및 책임준비금 등을 산정하는 기준이 되는 금액
보험계약대출  [Policy Loan] 
보험계약대출은 보험계약의 해약환급금의 범위 내에서 대출하는 계약이다. 보험기간 
중 사정변경으로 보험료 지급의 계속이 곤란하거나 일시적으로 금전이 필요한 경우, 
보험계약해지 대신 보험계약 해지시 지급하여야 할 범위 내에서 보험계약자에게 대출
을 함으로써 보험계약을 유지하게 하는 장점이 있다. 보험계약자는 보험계약대출의 
원리금을 언제든지 상환할 수 있으며, 상환하지 아니한 때에는 보험금, 해약환급금 
등의 지급사유가 발생한 날에 제지급금에서 상계할 수 있다. 다만 보험계약자의 보험
료 미납으로 인하여 보험계약이 해지되는 경우 보험회사는 즉시 해약환급금과 보험계
약대출 원리금을 상계할 수 있다. 
보험계약일
계약자가 보험회사와 보험계약을 체결한 날, 철회 산정기간의 기준일
보험기간
보험계약에 따라 보장을 받는 기간
보험금
피보험자의 사망, 장해, 입원, 만기 등 보험금 지급사유가 발생하였을 때 보험회사가 
보험수익자에게 지급하는 금액
보험료  [Premium] 
보험계약에서는 계약의 한쪽 당사자인 보험자가 위험부담이라는 급부를 제공하는 데 
대응해서, 다른 쪽의 당사자인 보험계약자는 보험자에게 그에 대한 보수를 지급한다. 
이 보수를 보험료라고 하는 것이다. 보험료의 액수는 통상 보험금액에 따라, 그리고 
보험사고 발생의 개연성을 고려하여 결정된다. 
 1) 보장보험료 : 약관에서 정한 「보험금의 지급사유」의 보험금을 지급하는데 필요한 
보험료
 2) 적립보험료 : 보험회사가 적립한 금액을 돌려주는데 필요한 보험료
 3) 적립부분 순보험료 : 적립보험료에서 사업비를 공제한 후의 금액
보험수익자
보험금 지급사유가 발생하는 때에 회사에 보험금을 청구하여 받을 수 있는 사람(신체 
및 비용관련 손해에 한하며, 재산손해 및 배상책임관련 손해는 제외) 또는 만기환급
금 지급시기에 만기환급금의 청구를 할 수 있는 사람
보험안내자료  [Insurance Guide Materials] 
보험상품의 모집을 위하여 사용하는 자료로서 보험회사 또는 보험모집을 하는 자의 
명칭, 보험금 지급제한 조건에 관한 사항, 해약환급금에 관한 사항, 기타 보험가입에 
따른 권리·의무에 관한 주요사항을 기재한 것을 말한다. ‘보험안내자료’에 보험회사의 
자산과 부채에 관한 사항을 기재하는 경우에는 감독당국에 제출한 사항과 다른 내용
을 기재하여서는 아니되며, 보험계약자의 이해를 돕기 위하여 금융위원회가 정한 경
우 외에는 보험회사의 장래의 이익의 배당 등 예상에 관한 사항을 기재할 수 없다. 
보험약관
보험계약에 관하여 계약자와 보험회사 상호간에 이행하여야 할 권리와 의무를 규정한 
것
보장개시일
보험회사의 보험금 지급의무가 시작되는 날
보험증권
보험계약의 성립과 그 내용을 증명하기 위하여 보험회사가 계약자에게 교부하는 증서
부담보기간 
부담보(특별조건부 인수특약)기간이란 보험사에서 표준미달체의 보험계약시 질병이나 
장해 등으로 인하여 가입이 제한되는 피보험자의 계약을 조건부로 승낙하는 경우, 혹
은 도덕적 해이 등에 의한 보험사기가 우려되는 경우 계약일로부터 일정기간 이내에 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (156, 4, 23, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
23
발생되는 보험사고에 대하여는 보상하지 않는 것을 말한다. 이는 일반적으로 보험계
약 청약시 피보험자가 병력에 대해 보험회사에 고지하고, 보험회사에서는 해당 질병 
및 부위에 대해 보장을 하지 않는 것으로 계약을 인수할 때 발생한다. 부담보기간은 
피보험자의 과거 병력, 치료기간, 치료부위 등에 따라 상이하며, 경우에 따라서는 보
험기간 전기간에 걸쳐 부담보하는 조건으로 인수를 하기도 한다. 암보험에서 계약체
결 이후 90일간 암 담보를 하지 않는 것은 대표적인 부담보 사례라 할 수 있다. 
자동갱신제도 
보험계약기간의 만료시점에 보험계약자가 보험계약을 갱신하고 싶지 않다는 명시적인 
의사표시가 없는 경우에 자동으로 동일한 계약내용을 동일 기간동안 연장하는 제도이
다. 계약자가 갱신 내용을 정확히 기억하고 있지 못할 경우에 대비하거나, 보험료 수
준 변동내역 등을 보험계약자에게 알려주기 위하여 보험회사는 보험계약 만료 전에 
계약 만료시점과 보험료 변동내역을 유선 혹은 문서로 보험계약자에게 알려야 한다. 
동 사항을 안내받은 보험계약자가 갱신거절을 보험회사에 통보할 경우 보험계약은 갱
신되지 않으며, 총 보험금 지급금액 등 보험회사가 정한 일정한 조건에 부합될 경우 
보험회사가 자동갱신을 거절할 수도 있다. 자동갱신제도의 적용은 1년 만기 일반보험 
상품이나 장기보험 의료비 특약 등에서 이루어진다. 
책임준비금  [Policy Reserve] 
책임준비금은 보험회사가 보험계약자에게 보험금이나 환급금 등 약정한 사항을 이행
하기 위해 적립하는 부채로서 보험료 중 예정기초율에 따라 비용(예정사업비, 위험보
험료)을 지출하고 계약자에 대한 채무(사망보험금, 중도급부금, 만기보험금 등)를 이
행하기 위해 적립하는 금액을 말한다. 책임준비금은 보험계약자를 보호하기 위하여 
감독당국이 법규에 의해 적립을 강제한 법정준비금이며 보험료적립금, 미경과보험료
적립금, 지급준비금, 계약자배당준비금, 계약자이익배당준비금으로 구성된다. 이중 보
험료적립금이 책임준비금의 대부분을 차지한다. 보험료적립금이란 대차대조표일 현재 
유지되고 있는 보험계약에 대하여 장래의 보험금 등의 지급을 위해 보험업감독규정에 
따라 적립한 금액을 말한다. 
타인을 위한 보험계약 
보험계약자가 타인의 이익을 위하여 자기의 이름으로 체결하는 보험계약을 말한다. 
타인을 위한 보험계약은 그 계약의 당사자가 아닌 피보험자 또는 보험수익자 또한 보
험계약상의 이익을 받고 일정한 의무를 지게 된다. 따라서 피보험자나 보험수익자는 
일정한 의사표시를 하지 아니하여도 당연히 그 계약의 이익을 받으므로 보험사고가 
발생하면 직접 보험자에게 보험금을 청구할 수 있다. 이들은 보험계약 당사자가 아니
므로 보험료의 납입의무가 없으나, 다만 보험계약자가 파산선고를 받거나 보험료의 
납입을 지체한 경우에는 그 권리를 포기하지 않는 한 보험료를 납입하여야 한다. 보
험자와 보험계약자 사이에 동 보험계약을 체결할 때에는 타인을 위한 보험계약이라는 
명백한 의사표시가 있어야 하며, 보험계약자는 타인의 동의를 받지 않고서도 보험계
약을 체결할 수 있다. 다만, 손해보험계약의 경우 피보험자는 보험목적에 대한 피보
험이익을 향유한 자이어야 한다. 
피보험자
보험사고 발생의 대상이 되는 사람 (재산손해 및 배상책임관련 손해의 경우에는 사고
의 발생으로 손해를 입을 수 있는 사람으로 해당 보험금의 청구를 할 수 있는 사람)
해지환급금
보험계약의 효력상실, 해약 및 해제 등의 경우에 계약자에게 환급되는 금액을 말한
다. 해지환급금은 책임준비금에서 해약공제를 하고 남은 금액으로 계산되는데, 국내
에서는 해약시점 계약의 책임준비금에서 미상각된 신계약비를 공제하여 계산한다. 해
약환급금이 발생하게 되는 원인은 두 가지에 기인하게 되는데 첫째는 보험계약자가 
납입하는 보험료 중 저축보험료 부분에 의해 발생되며, 둘째는 평준보험료방식 때문
에 발생된다. 평준보험료방식에서는 계약초기에 피보험자의 위험수준에 비해 다소 높
은 보험료를 내게 되는데, 이 부분이 적립되어 향후에 위험수준에 비해 낮은 보험료
를 내게 되는 시기에 사용된다.
휴면보험금
보험계약이 실효되거나 만기되어 보험금이나 환급금 등이 발생하였음에도, 보험계약
자가 이를 3년 동안 찾아가지 않아 소멸시효가 완성되어 보험회사에서 보관하고 있
는 것을 의미한다. 보험계약이 실효된 뒤 3년이 경과된 계약의 환급금, 만기가 지난 
뒤에도 찾아가지 않은 만기 보험금 등이 여기에 해당한다. 휴면보험금은 청구권이 소
멸된 금액으로서 상법상으로는 보험회사에 귀속되나, 당연히 보험계약자에게 돌아가
야 할 돈이기 때문에 휴면보험금이 확인될 경우 보험회사는 계약자에게 환급하고 있
다. 이를 위해 보험계약자 등이 자신의 휴면보험금을 확인할 수 있도록 ·휴면계좌통
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (157, 4, 24, '24
합조회시스템·을 설치·운영(’06.4월)하고 있으며, 최근에는 보험계약자가 생·손보협회 
홈페이지를 통해 휴면보험금을 포함한 全보험회사의 보험가입 내역을 조회할 수 있도
록 제도를 개선(’10.7월)하였다. 한편, 보험회사는 휴면보험금을 휴면예금관리재단(미
소금융재단, 「휴면예금관리재단의 설립 등에 관한 법률」시행(’08.2.4))에 출연하고 동 
재단에서 휴면보험금 관리·환급업무를 담당하고 있다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (158, 4, 25, '공
통
사
항
무배당 프로미라이프 참좋은오토바이운전자보험1707
25
프로미라이프 
지식백과
아래의 내용은 금융감독원에서 발간한 「보험상품 현명하게 가입하기」핸드북 내용을 
요약한 자료로서 보다 자세한 내용은 금융감독원 홈페이지를 참고하시기 바랍니다.
1  보험상품 내용에 대해 꼼꼼하게 설명듣기
1. 반드시 설명을 들어야 할 사항
보험계약 체결시 보험회사 또는 보험모집인은 보험계약자에게 계약의 중요한 내용을 
일반보험계약자가 이해할 수 있도록 설명하여야 합니다.(상법 제638조의3, 보험업법 
제95조의 2)
‘중요한 내용’이란 보험료와 보장범위, 보험금 지급사유 및 지급제한 사유 등 고객의 
이해관계에 중대한 영향을 미치는 사항으로서 사회 통념상 그 사항을 알았더라면 계
약을 체결하지 않았을 것으로 해석되는 사유를 말합니다.
2. 설명의무 위반의 입증책임 및 효과
보험약관의 교부와 중요한 내용을 설명했다는 증명은 보험회사가 해야 합니다. 또한 
보험계약자나 대리인이 약관의 내용을 이미 잘 알고 있는 등의 사유로 설명의무가 면
제될 경우, 그 사실에 대한 입증책임도 보험회사가 부담합니다.
보험회사가 약관 교부·설명의무를 위반한 경우 해당 약관 조항을 보험계약 내용으로 
주장할 수 없으며(약관규제법 제3조), 상법상 보험계약자는 계약성립일로부터 3개월 
이내에 그 계약을 취소할 수 있습니다.(상법 제638조의3 제2항)
2  계약전 알릴 의무(고지의무) 이행하기
1. 고지의무의 내용
보험은 신의성실의 원칙상, 보험가입자에 대하여도 일정한 의무를 인정하고 있습니
다. 대표적인 것이 “계약 전 알릴의무(고지의무)”로서, 보험계약자 또는 피보험자는 
보험계약을 체결함에 있어서 보험회사에 대하여 ‘중요한 사항’을 알려야 할 의무가 있
습니다.
 
2. 고지의무 이행 방법
‘중요한 사항’의 내용은 대부분 보험사가 동일하며, 주로 현재 및 과거의 질병이나 장
애, 직업 등에 대한 사항으로서, 보험회사가 보험사고 발생 개연성을 측정하여 보험
계약 체결여부와 보험료 등을 정하기 위한 사항입니다. 상법은 청약서에 기재된 사항
을 중요한 사항으로 보고 있습니다.
특히 “최근 5년 이내의 진단·치료”에 대한 부분은 가장 많은 다툼의 여지가 되는 항
목이므로, 청약서에 있는 (병력사항)질문표에 기재함으로써 알릴의무를 이행하여야 합
니다.
또 한가지 주의할 점은 고지의 상대방은 보험회사 등 고지수령권이 있는 자라야 한다
는 점입니다. 따라서 보험회사나 체약대리점은 고지수령권이 있지만, 보험설계사에게 
알리는 것은 인정되지 않으므로 주의를 요합니다. 따라서 청약서에 서면으로 기재하
여 보험회사에 대하여 고지가 이루어지도록 해야겠습니다.
3. 고지의무 위반시 불이익
고지의무를 이행하지 않을 경우, 보험사는 그 위반을 알게 된 날로부터 1개월, 계약
을 체결한 날로부터 3년 내에 계약을 해지할 수 있습니다.(상법 제651조) 보험약관
에는 고지의무위반 사실을 안날부터 1개월, 보험금지급사유가 발생하지 않고 2년(진
단계약의 경우 질병에 대하여는 1년)이 지난 경우 해지할 수 없다고 규정하여 보험
회사의 권리행사기간을 더욱 제한하고 있습니다.
 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (159, 4, 26, '26
3  청약철회제도
1. 청약철회의 개념 및 대상
보험을 계약한 뒤 단순히 마음에 들지 않거나 변심에 의한 경우도 일정한 기간 내에
는 위약금이나 손해 없이 그 계약을 철회할 수 있습니다. 이는 장기 상품인 보험의 
특성을 고려하여 그 가입여부를 다시 한 번 신중히 재고할 기회를 부여하는 것입니
다.
청약철회가 가능한 보험종목은 생명보험 및 손해보험 중 가입기간 1년 이상 가계성 
보험(개인의 일상생활과 관련된 보험)으로, 자동차보험·화재보험·배상책임보험 등은 
제외됩니다.
2. 청약철회 방법 및 효과
보험계약자는 보험증권을 받은 날로부터 15일이내에 그 청약을 철회할 수 있습니다. 
다만, 진단계약, 보험기간이 1년 미만인 계약 또는 전문보험계약자가 체결한 계약은 
청약을 철회할 수 없으며. 청약을 한 날로부터 30일을 초과한 경우에도 청약을 철회
할 수 없습니다. 이 경우 보험증권을 받은 날에 대한 다툼이 발생한 경우 회사가 이
를 증명하여야 합니다.
보험회사는 청약의 철회를 접수한 경우 3일 이내에 기납입 보험료를 반환하며, 보험
료 반환이 지체된 경우 일정한 이자(보험계약대출이율을 연단위 복리로 계산)를 더하
여 지급합니다.
4  계약취소와 품질보증제도
1. 계약취소의 개념과 요건
보험 계약취소 제도는 보험 품질보증제도라고도 하며, 청약철회와 달리 일정한 사유
에 해당하는 경우 계약이 성립한 날로부터 3개월 내에 보험계약을 취소할 수 있는 
제도입니다.
일정한 사유라 함은 ①보험회사가 약관 및 청약서 부본을 주지 않거나, ②약관의 주
요내용을 설명하지 않은 때, 또는 ③계약자가 계약 체결시 청약서에 자필서명을 하지 
아니한 때를 의미하며, 이를 ‘3대 기본지키기’라고도 합니다.
‘3대 기본지키기’를 위반한 계약에 대하여는 청약일로부터 3개월 이내에 계약취소가 
가능합니다. 보험계약자는 취소사유와 내용을 기재한 계약취소 청구서를 작성하여 내
용증명 우편으로 발송하거나 회사로 직접 방문하여 접수하면 됩니다.
2. 계약취소의 효과
보험 계약취소 요청이 접수된 경우 보험회사는 보험계약자에게 이미 납입한 보험료를 
돌려주어야 하며, 보험료를 받은 기간에 보험계약대출 이율을 연단위 복리로 계산한 
금액을 더해 지급해야 합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (160, 4, 27, '공
통
사
항
보통약관
이륜자동차 
운전중 
자동차부상
치료비(1~3급)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (161, 4, 28, '28
어려운 용어는 프로미라이프 용어사전 참고 ……………………………………   21
인용 법규는   약관에서 인용한 법규  참고 ……………………………………  123 
제1관 목적 및 용어의 정의
1. (목적)
이 보험계약(이하 ‘계약’이라 합니다)은 보험계약자(이하 ‘계약자’라 합니다)와 보험회
사(이하 ‘회사’라 합니다) 사이에 피보험자의 질병이나 상해 등에 대한 위험을 보장하
기 위하여 체결됩니다.
2. (용어의 정의)
이 계약에서 사용되는 용어의 정의는, 이 계약의 다른 조항에서 달리 정의되지 않는 
한 다음과 같습니다.
󰊱계약관계 관련 용어    
용어
정의
계약자
회사와 계약을 체결하고 보험료를 납입할 의무를 지는 사람을 
말합니다. 
보험수익자
보험금 지급사유가 발생하는 때에 회사에 보험금을 청구하여 
받을 수 있는 사람을 말합니다.
보험증권
계약의 성립과 그 내용을 증명하기 위하여 회사가 계약자에게 
드리는 증서를 말합니다.
진단계약
계약을 체결하기 위하여 피보험자가 건강진단을 받아야 하는 
계약을 말합니다.
피보험자
보험사고의 대상이 되는 사람을 말합니다.
󰊲지급사유 관련 용어
용어
정의
상해
보험기간 중에 발생한 급격하고도 우연한 외래의 사고로 
신체(의수, 의족, 의안, 의치 등 신체보조장구는 제외하나, 
인공장기나 부분 의치 등 신체에 이식되어 그 기능을 대신할 
경우는 포함합니다)에 입은 상해를 말합니다.
장해
【별표2】 장해분류표에서 정한 기준에 따른 장해상태를 
말합니다.
신체
의수, 의족, 의안, 의치 등 신체보조장구는 제외하나, 
인공장기나 부분 의치 등 신체에 이식되어 그 기능을 대신할 
경우는 포함합니다.
중요한 사항
계약 전 알릴 의무와 관련하여 회사가 그 사실을 알았더라면 
계약의 청약을 거절하거나 보험가입금액 한도 제한, 일부 보장 
제외, 보험금 삭감, 보험료 할증과 같이 조건부로 승낙하는 등 
계약 승낙에 영향을 미칠 수 있는 사항을 말합니다.
󰊳지급금과 이자율 관련 용어
용어
정의
연단위 복리
회사가 지급할 금전에 이자를 줄 때 1년마다 마지막 날에 그 
이자를 원금에 더한 금액을 다음 1년의 원금으로 하는 이자 
계산방법을 말합니다.
평균공시이율
전체 보험회사 공시이율의 평균으로, 이 계약 체결 시점의 
이율을 말합니다.
해지환급금
계약이 해지되는 때에 회사가 계약자에게 돌려주는 금액을 
말합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (162, 4, 29, '보
통
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
29
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
󰊴기간과 날짜 관련 용어    
용어
정의
보험기간
계약에 따라 보장을 받는 기간을 말합니다.
영업일
회사가 영업점에서 정상적으로 영업하는 날을 말하며, 토요일, 
‘관공서의 공휴일에 관한 규정’에 따른 공휴일과 근로자의 날을 
제외합니다.
󰊵이륜자동차 운행목적 관련 용어 
용어
정의
유상운송 배달용
피보험자가 수당, 요금 등 대가의 보상을 직접적인 목적으로 
물건 등의 배달을 위해서 이륜자동차를 운전하는 경우를 
말합니다.
(예) 매 배달시마다 요금이나 대가를 수령하는 퀵서비스, 
이륜자동차를 이용한 택배 등
비유상운송 배달용
피보험자가 「유상운송 배달용」 이외의 목적으로 물건 등의 
배달을 위해서 이륜자동차를 운전하는 경우를 말합니다.
(예) 매 배달시 요금이나 대가를 수령하지 않는 피자, 치킨 등 
음식 배달 및 우편배달 등
가정용 
및 기타용도
상기 「유상운송 배달용」 및 「비유상운송 배달용」 이외의 
목적으로 이륜자동차를 운전하는 경우를 말합니다.
(예) 출퇴근용도, 보안경비용 등
제2관 보험금의 지급
3. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 보험기간 중에 발생한 이륜자동차 운전중 
교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격하고도 우연한 자
동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니다)의 직접결과로써  
자동차손해배상보장법 시행령에서 정한 자동차사고부상등급표(【별표3】자동차사고 
부상등급표 참조)의 1급, 2급 또는 3급에 해당하는 부상등급을 받은 경우 보통약
관의 보험가입금액을 보험수익자에게 이륜자동차운전중자동차부상치료비(1~3급)
으로 지급합니다.
   
부상등급
지급금액
1급 ~ 3급
보통약관의 보험가입금액
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 이륜자동차라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (163, 4, 30, '30
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
4. (보험금 지급에 관한 세부규정)
보험수익자와 회사가 3.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하지 
못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 수 있
습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 중에 정하
며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
인용
문구
의료법 제3조(의료기관)
이 법에서 의료기관이라 함은 의료인이 공중 또는 특정 다수인을 위하여 의
료·조산의 업을 행하는 곳을 말합니다. 의료기관은 종합병원·병원·치과병원·한
방병원·요양병원·의원·치과의원·한의원 및 조산원으로 나누어집니다.
5. (보험금을 지급하지 않는 사유)
󰊱회사는 다음 중 어느 한가지로 보험금 지급사유가 발생한 때에는 보험금을 지급
하지 않습니다.
① 피보험자가 고의로 자신을 해친 경우. 다만, 피보험자가 심신상실 등으로 자유
로운 의사결정을 할 수 없는 상태에서 자신을 해친 경우에는 보험금을 지급합
니다.
② 보험수익자가 고의로 피보험자를 해친 경우. 다만, 그 보험수익자가 보험금의 
일부 보험수익자인 경우에는 다른 보험수익자에 대한 보험금은 지급합니다.
③ 계약자가 고의로 피보험자를 해친 경우
④ 피보험자의 임신, 출산(제왕절개를 포함합니다), 산후기. 그러나 회사가 보장하
는 보험금 지급사유로 인한 경우에는 보험금을 지급합니다.
⑤ 전쟁, 외국의 무력행사, 혁명, 내란, 사변, 폭동
󰊲회사는 다른 약정이 없으면 피보험자가 직업, 직무 또는 동호회 활동목적으로 이
륜자동차에 의한 경기, 시범, 흥행(이를 위한 연습을 포함합니다) 또는 시운전(다
만, 공용도로상에서 시운전을 하는 동안 보험금 지급사유가 발생한 경우에는 보장
합니다.)에 의하여 3.(보험금의 지급사유)의 상해 관련 보험금 지급사유가 발생한 
때에는 해당 보험금을 지급하지 않습니다.
󰊳회사는 아래에 열거된 행위로 인하여 보험금 지급사유가 발생한 때에는 보험금을 
지급하지 않습니다.
① 피보험자가 시운전, 경기(연습을 포함합니다) 또는 흥행(연습을 포함합니다)을 
위하여 운행중의 이륜자동차에 탑승(운전을 포함합니다)하고 있는 동안 보험금 
지급사유가 발생한 때
② 하역작업을 하는 동안 보험금 지급사유가 발생한 때
③ 이륜자동차의 설치, 수선, 점검, 정비나 청소작업을 하는 동안 보험금 지급사
유가 발생한 때
④ 건설기계 및 농업기계가 작업기계로 사용되는 동안 보험금 지급사유가 발생한 
때
6. (보험금 지급사유의 통지)
계약자 또는 피보험자나 보험수익자는 3.(보험금의 지급사유)에서 정한 보험금 지급
사유의 발생을 안 때에는 지체없이 그 사실을 회사에 알려야 합니다.
7. (보험금의 청구)
󰊱보험수익자는 다음의 서류를 제출하고 보험금을 청구하여야 합니다.
① 청구서(회사양식)
② 사고증명서(진료비계산서, 사망진단서, 장해진단서, 입원치료확인서, 의사처방
전(처방조제비) 등)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (164, 4, 31, '보
통
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
31
③ 신분증(주민등록증 이나 운전면허증 등 사진이 붙은 정부기관발행 신분증, 본
인이 아니면 본인의 인감증명서 포함)
④ 기타 보험수익자가 보험금의 수령에 필요하여 제출하는 서류
󰊲위 󰊱.②의 사고증명서는 의료법 제3조(의료기관)에서 규정한 국내의 병원이나 의
원 또는 국외의 의료관련법에서 정한 의료기관에서 발급한 것이어야 합니다.
인용
문구
의료법 제3조(의료기관)
이 법에서 의료기관이라 함은 의료인이 공중 또는 특정 다수인을 위하여 의
료·조산의 업을 행하는 곳을 말합니다. 의료기관은 종합병원·병원·치과병원·한
방병원·요양병원·의원·치과의원·한의원 및 조산원으로 나누어집니다.
8. (보험금의 지급절차)
󰊱회사는 7.(보험금의 청구)에서 정한 서류를 접수한 때에는 접수증을 드리고 휴대
전화 문자메시지 또는 전자우편 등으로도 송부하며, 그 서류를 접수한 날부터 3
영업일 이내에 보험금을 지급합니다. 
󰊲회사가 보험금 지급사유를 조사․확인하기 위해 필요한 기간이 위 󰊱의 지급기일을 
초과할 것이 명백히 예상되는 경우에는 그 구체적인 사유와 지급예정일 및 보험
금 가지급 제도(회사가 추정하는 보험금의 50% 이내를 지급)에 대하여 피보험자 
또는 보험수익자에게 즉시 통지합니다. 다만, 지급예정일은 다음 각 호의 어느 하
나에 해당하는 경우를 제외하고는 7.(보험금의 청구)에서 정한 서류를 접수한 날
부터 30영업일 이내에서 정합니다.
① 소송제기
② 분쟁조정 신청
③ 수사기관의 조사 
④ 해외에서 발생한 보험사고에 대한 조사
⑤ 아래 󰊶에 따른 회사의 조사요청에 대한 동의 거부 등 계약자, 피보험자 또는 
보험수익자의 책임있는 사유로 인하여 보험금 지급사유의 조사 및 확인이 지
연되는 경우
⑥ 보험금 지급사유에 대해 제3자의 의견에 따르기로 한 경우
󰊳위 󰊲에 의하여 장해지급률의 판정 및 지급할 보험금의 결정과 관련하여 확정된 
장해지급률에 따른 보험금을 초과한 부분에 대한 분쟁으로 보험금 지급이 늦어지
는 경우에는 보험수익자의 청구에 따라 이미 확정된 보험금을 먼저 가지급합니다.
󰊴위 󰊲에 의하여 추가적인 조사가 이루어지는 경우, 회사는 보험수익자의 청구에 
따라 회사가 추정하는 보험금의 50% 상당액을 가지급보험금으로 지급합니다. 
󰊵회사는 위 󰊱의 규정에 정한 지급기일내에 보험금을 지급하지 않았을 때(위 󰊲에
서 정한 지급예정일을 통지한 경우를 포함합니다)에는 그 다음날부터 지급일까지
의 기간에 대하여 ‘【별표1】 보험금을 지급할 때의 적립이율 계산’에서 정한 이율
로 계산한 금액을 보험금에 더하여 지급합니다. 그러나 계약자, 피보험자 또는 보
험수익자의 책임있는 사유로 지급이 지연된 때에는 그 해당기간에 대한 이자는 
더하여 지급하지 않습니다.
󰊶계약자, 피보험자 또는 보험수익자는 16.(알릴 의무 위반의 효과) 및 위 󰊲의 보
험금 지급사유조사와 관련하여 의료기관, 국민건강보험공단, 경찰서 등 관공서에 
대한 회사의 서면에 의한 조사요청에 동의하여야 합니다. 다만, 정당한 사유없이 
이에 동의하지 않을 경우 사실확인이 끝날 때까지 회사는 보험금 지급지연에 따
른 이자를 지급하지 않습니다.
󰊷회사는 위 󰊶의 서면조사에 대한 동의 요청시 조사목적, 사용처 등을 명시하고 
설명합니다.
9. (만기환급금의 지급)
󰊱회사는 보험기간이 끝난 때에 적립부분 순보험료(적립보험료에서 사업비를 공제한 
보험료를 말합니다.)에 대하여 보험료 납입일(회사에 입금된 날을 말합니다)부터 
이 계약의 공시이율로 “보험료 및 책임준비금 산출방법서”에 따라 적립한 금액을 
만기환급금으로 보험수익자에게 지급합니다. 그러나, 기인출된 중도인출금이 있는 
경우에는 그 원리금 합계액을 빼고 지급합니다.
󰊲위 󰊱의 공시이율이 보험기간 중에  변경되는 경우에는 변경된 시점 이후부터 
35.(공시이율의 적용 및 공시)에 따라 변경된 이율을 적용하며, 최저보증이율은 
연복리 0.3%로 합니다.
󰊳회사는 계약자 및 보험수익자의 청구에 의하여 위 󰊱에 의한 만기환급금을 지급
하는 경우 청구일부터 3영업일 이내에 지급합니다.
󰊴회사는 위 󰊱에 의한 만기환급금의 지급시기가 되면 지급시기 7일 이전에 그 사
유와 지급할 금액을 계약자 또는 보험수익자에게 알려드리며, 만기환급금을 지급
함에 있어 지급일까지의 기간에 대한 이자의 계산은 ‘【별표1】 보험금을 지급할 때
의 적립이율 계산’ 에 따릅니다. 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (165, 4, 32, '32
용어
풀이
공시이율
전통적인 보험상품에 적용되는 이율이 장기·고정금리이기 때문에 시중금리가 
급격하게 변동할 경우 이에 대응하지 못하는 단점을 고려하여, 시중의 지표
금리 등에 연동하여 일정기간 마다 변동되는 이율을 말합니다.
용어
풀이
최저보증이율
운용자산이익률 및 외부지표금리가 하락하더라도 보험회사에서 보증하는 최
저한도의 적용이율입니다. 예를 들어, 적립금이 공시이율에 따라 적립되며 
공시이율이 0.1%인 경우(최저보증이율은 0.3%일 경우), 적립금은 공시이
율(0.1%)이 아닌 최저보증이율(0.3%)로 적립됩니다.
인용
문구
상법 제651조(고지의무위반으로 인한 계약해지)
보험계약당시에 보험계약자 또는 피보험자가 고의 또는 중대한 과실로 인하
10. (보험금 받는 방법의 변경)
󰊱계약자(보험금 지급사유 발생 후에는 보험수익자)는 회사의 사업방법서에서 정한 
바에 따라 보험금의 전부 또는 일부에 대하여 나누어 지급받거나 일시에 지급받
는 방법으로 변경할 수 있습니다.
󰊲회사는 위 󰊱에 따라 일시에 지급할 금액을 나누어 지급하는 경우에는 나중에 지
급할 금액에 대하여 평균공시이율을 연단위 복리로 계산한 금액을 더하며, 나누어 
지급할 금액을 일시에 지급하는 경우에는 평균공시이율을 연단위 복리로 할인한 
금액을 지급합니다.
용어
풀이
평균공시이율
전체 보험회사 공시이율의 평균으로, 이 계약 체결 시점의 이율을 말합니다.
11. (주소변경통지)
󰊱계약자(보험수익자가 계약자와 다른 경우 보험수익자를 포함합니다)는 주소 또는 
연락처가 변경된 경우에는 지체없이 그 변경내용을 회사에 알려야 합니다.
󰊲위 󰊱에서 정한 대로 계약자 또는 보험수익자가 변경내용을 알리지 않은 경우에
는 계약자 또는 보험수익자가 회사에 알린 최종의 주소 또는 연락처로 등기우편 
등 우편물에 대한 기록이 남는 방법으로 회사가 알린 사항은 일반적으로 도달에 
필요한 기간이 지난 때에 계약자 또는 보험수익자에게 도달된 것으로 봅니다.
12. (보험수익자의 지정)
보험수익자를 지정하지 않은 때에는 보험수익자를 9.(만기환급금의 지급)의 경우는 
계약자로 하고, 사망보험금의 경우는 피보험자의 법정상속인으로 하며, 그 밖의 보험
금의 경우는 피보험자로 합니다.
13. (대표자의 지정)
󰊱계약자 또는 보험수익자가 2명 이상인 경우에는 각 대표자를 1명을 지정하여야 
합니다. 이 경우 그 대표자는 각각 다른 계약자 또는 보험수익자를 대리하는 것
으로 합니다. 
󰊲지정된 계약자 또는 보험수익자의 소재가 확실하지 않은 경우에는 이 계약에 관
하여 회사가 계약자 또는 보험수익자 1명에 대하여 한 행위는 각각 다른 계약자 
또는 보험수익자에게도 효력이 미칩니다.
󰊳계약자가 2명 이상인 경우에는 그 책임을 연대로 합니다.
제3관 계약자의 계약 전 알릴 의무 등
14. (계약 전 알릴 의무)
계약자 또는 피보험자는 청약할 때(진단계약의 경우에는 건강진단할 때를 말합니다) 
청약서에서 질문한 사항에 대하여 알고 있는 사실을 반드시 사실대로 알려야(이하 
“계약 전 알릴 의무”라 하며, 상법상 “고지의무”와 같습니다)합니다. 다만, 진단계약의 
경우 의료법 제3조(의료기관)의 규정에 따른 종합병원과 병원에서 직장 또는 개인이 
실시한 건강진단서 사본 등 건강상태를 판단할 수 있는 자료로 건강진단을 대신할 수 
있습니다. 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (166, 4, 33, '보
통
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
33
여 중요한 사항을 고지하지 아니하거나 부실의 고지를 한 때에는 보험자는 
그 사실을 안 날로부터 1월내에, 계약을 체결한 날로부터 3년내에 한하여 
계약을 해지할 수 있다. 그러나 보험자가 계약당시에 그 사실을 알았거나 중
대한 과실로 인하여 알지 못한 때에는 그러하지 아니하다.
상법 제651조의2(서면에 의한 질문의 효력)
보험자가 서면으로 질문한 사항은 중요한 사항으로 추정한다.
용어
풀이
이륜자동차 운행목적
1. 유상운송 배달용 : 피보험자가 수당, 요금 등 대가의 보상을 직접적인 목
적으로 물건 등의 배달을 위해서 이륜자동차를 운전하는 경우를 말합니다.
   (예) 매 배달시마다 요금이나 대가를 수령하는 퀵서비스, 이륜자동차를 
이용한 택배 등
2. 비유상운송 배달용 : 피보험자가 「유상운송 배달용」 이외의 목적으로 물
건 등의 배달을 위해서 이륜자동차를 운전하는 경우를 말합니다.
   (예) 매 배달시 요금이나 대가를 수령하지 않는 피자, 치킨 등 음식 배달 
및 우편배달 등
3. 가정용 및 기타용도 : 상기 「유상운송 배달용」 및 「비유상운송 배달용」 이
외의 목적으로 이륜자동차를 운전하는 경우를 말합니다.
   (예) 출퇴근용도, 보안경비용 등
예시
보험청약시 보험회사의 요구에 의하여 보험계약자가 작성하는 질문표에 기재
된 질문사항은 다른 특별한 사정이 없는 한 보험계약에 있어서의 중요한 사
항에 해당된다고 볼 수 있으므로 질문표에 사실과 다르게 기재하였다면 보험
자는 고지의무위반을 이유로 보험계약을 해지할 수 있습니다.
15. (계약 후 알릴 의무)
󰊱계약자 또는 피보험자는 보험기간 중에 피보험자가 그 직업 또는 직무를 변경(가
정용 및 기타용도 이륜자동차 운전자가 유상운송 배달용 및 비유상운송 배달용 
이륜자동차 운전자로 직업 또는 직무를 변경하는 경우를 포함합니다)하거나 이륜
자동차 운행목적을 변경하여 계속적으로 사용하는 경우 지체없이 회사에 알려야 
합니다.
󰊲회사는 위 󰊱에 따라 위험이 감소된 경우에는 그 차액보험료를 돌려드리며, 계약자 
또는 피보험자의 고의 또는 중대한 과실로 위험이 증가된 경우에는 통지를 받은 
날부터 1개월 이내에 보험료의 증액을 청구하거나 계약을 해지할 수 있습니다.
용어
풀이
중대한 과실
주의의무의 위반이 현저한 과실, 즉 현저한 부주의, 태만의 경우로서 조금만 
주의를 하였다면 충분히 피해의 발생을 막을 수 있었음에도 그 주의조차 태
만히 한 높은 강도의 주의의무위반
󰊳위 󰊱의 통지에 따라 보험료를 더 내야 할 경우 회사의 청구에 대해 계약자가 그 
납입을 게을리 했을 때, 회사는 직업 또는 직무가 변경되기 전에 적용된 보험요율
(이하 “변경 전 요율”이라 합니다)의 직업 또는 직무가 변경된 후에 적용해야 할 
보험요율(이하 “변경 후 요율” 이라 합니다)에 대한 비율에 따라 보험금을 삭감하
여 지급합니다. 다만, 변경된 직업 또는 직무와 관계없이 발생한 보험금 지급사유
에 관해서는 원래대로 지급합니다.
󰊴계약자 또는 피보험자가 고의 또는 중대한 과실로 직업 또는 직무의 변경사실을 
회사에 알리지 않은 경우 변경 후 요율이 변경 전 요율보다 높을 때에는 회사는 
동 사실을 안 날부터 1개월 이내에 계약자 또는 피보험자에게 위 󰊳에 의해 보장
됨을 통보하고 이에 따라 보험금을 지급합니다.
󰊵회사는 위 󰊱에 따라 위험이 증가하거나 감소되는 경우 변경시점 이후 잔여보험
기간의 보장을 위한 재원인 책임준비금 차이로 계약자가 추가납입하여야할(또는 
반환받을) 금액이 발생할 수 있습니다.
16. (알릴 의무 위반의 효과)
󰊱회사는 아래와 같은 사실이 있을 경우에는 손해의 발생여부에 관계없이 이 계약
을 해지할 수 있습니다. 
① 계약자 또는 피보험자가 고의 또는 중대한 과실로 14.(계약 전 알릴 의무)를 
위반하고 그 의무가 중요한 사항에 해당하는 경우
② 뚜렷한 위험의 증가와 관련된 15.(계약 후 알릴 의무) 󰊱에서 정한 계약 후 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (167, 4, 34, '34
알릴 의무를 계약자 또는 피보험자의 고의 또는 중대한 과실로 이행하지 않았
을 때
󰊲위 󰊱.①의 경우에도 불구하고 다음 중 하나에 해당하는 경우에는 회사는 계약을 
해지할 수 없습니다.
① 회사가 최초계약당시에 그 사실을 알았거나 과실로 인하여 알지 못하였을 때
② 회사가 그 사실을 안 날부터 1개월 이상 지났거나 또는 제1회 보험료를 받은 
때부터 보험금 지급사유가 발생하지 않고 2년(진단계약의 경우 질병에 대하여
는 1년)이 지났을 때
③ 최초계약을 체결한 날부터 3년이 지났을 때
④ 회사가 이 계약을 청약할 때 피보험자의 건강상태를 판단할 수 있는 기초자료
(건강진단서 사본 등)에 따라 승낙한 경우에 건강진단서 사본 등에 명기되어 
있는 사항으로 보험금 지급사유가 발생하였을 때(계약자 또는 피보험자가 회
사에 제출한 기초자료의 내용 중 중요사항을 고의로 사실과 다르게 작성한 때
에는 계약을 해지할 수 있습니다.)
⑤ 보험설계사 등이 계약자 또는 피보험자에게 고지할 기회를 주지 않았거나 계
약자 또는 피보험자가 사실대로 고지하는 것을 방해한 경우, 계약자 또는 피
보험자에게 사실대로 고지하지 않게 하였거나 부실한 고지를 권유했을 때. 다
만, 보험설계사 등의 행위가 없었다 하더라도 계약자 또는 피보험자가 사실대
로 고지하지 않거나 부실한 고지를 했다고 인정되는 경우에는 계약을 해지할 
수 있습니다.
󰊳위 󰊱에 따라 계약을 해지하였을 때에는 34.(해지환급금) 󰊱에 따른 해지환급금
을 계약자에게 지급합니다.
󰊴위 󰊱.①에 의한 계약의 해지가 보험금 지급사유 발생 후에 이루어진 경우에 회
사는 보험금을 지급하지 않으며, 계약 전 알릴 의무 위반사실뿐만 아니라 계약 
전 알릴 의무사항이 중요한 사항에 해당되는 사유를 “반대증거가 있는 경우 이의
를 제기할 수 있습니다” 라는 문구와 함께 계약자에게 서면 등으로 알려 드립니
다. 
󰊵위 󰊱.②에 의한 계약의 해지가 보험금 지급사유 발생 후에 이루어진 경우에는 
15.(계약 후 알릴 의무) 󰊳또는 󰊴에 따라 보험금을 지급합니다.
󰊶위 󰊱에도 불구하고 알릴 의무를 위반한 사실이 보험금 지급사유 발생에 영향을 
미치지 않았음을 계약자, 피보험자 또는 보험수익자가 증명한 경우에는 위 󰊴및 
󰊵에 관계없이 약정한 보험금을 지급합니다.
󰊷회사는 다른 보험가입내역에 대한 계약 전 알릴 의무 위반을 이유로 계약을 해지
하거나 보험금 지급을 거절하지 않습니다.
󰊸29.(보험료의 납입을 연체하여 해지된 계약의 부활(효력회복))에 따라 이 계약이 
부활(효력회복)된 경우에는 부활(효력회복)계약을 위 󰊲의 최초계약으로 봅니다. 
다만, 부활(효력회복)이 여러차례 발생된 경우에는 각각의 부활(효력회복)계약을 
최초계약으로 봅니다.
17. (사기에 의한 계약)
계약자 또는 피보험자가 대리진단, 약물사용을 수단으로 진단절차를 통과하거나 진단
서 위·변조 또는 청약일 이전에 암 또는 인간면역결핍바이러스(HIV) 감염의 진단 확
정을 받은 후 이를 숨기고 가입하는 등 사기에 의하여 계약이 성립되었음을 회사가 
증명하는 경우에는 계약일부터 5년 이내(사기사실을 안 날부터 1개월 이내)에 계약을 
취소할 수 있습니다.
제4관 보험계약의 성립과 유지
18. (보험계약의 성립)
󰊱계약은 계약자의 청약과 회사의 승낙으로 이루어집니다.
󰊲회사는 피보험자가 계약에 적합하지 않은 경우에는 승낙을 거절하거나 별도의 조
건(보험가입금액 제한, 일부보장 제외, 보험금 삭감, 보험료 할증 등)을 붙여 승
낙할 수 있습니다.
󰊳회사는 계약의 청약을 받고 제1회 보험료를 받은 경우에 건강진단을 받지 않는 
계약은 청약일, 진단계약은 진단일(재진단의 경우에는 최종진단일)부터 30일 이
내에 승낙 또는 거절하여야 하며, 승낙한 때에는 보험증권을 드립니다. 그러나 
30일 이내에 승낙 또는 거절의 통지가 없으면 승낙된 것으로 봅니다.
󰊴회사가 제1회 보험료를 받고 승낙을 거절한 경우에는 거절통지와 함께 받은 금액
을 계약자에게 돌려 드리며, 보험료를 받은 기간에 대하여 “평균공시이율 + 1%”
를 연단위 복리로 계산한 금액을 더하여 지급합니다. 다만, 회사는 계약자가 제1
회 보험료를 신용카드로 납입한 계약의 승낙을 거절하는 경우에는 신용카드의 매
출을 취소하며 이자를 더하여 지급하지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (168, 4, 35, '보
통
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
35
보험
지식
약관의 중요한 내용
보험업법 시행령 제42조의 2(설명의무의 중요사항 등) 및 보험업감독규정 
제4-35조의2 (보험계약 중요사항의 설명의무)에 정한 다음의 내용을 말합니
다.
 - 청약의 철회에 관한 사항
 - 지급한도, 면책사항, 감액지급 사항 등 보험금 지급제한 조건
 - 고지의무 위반의 효과
 - 계약의 취소 및 무효에 관한 사항
용어
풀이
평균공시이율
전체 보험회사 공시이율의 평균으로, 이 계약 체결 시점의 이율을 말합니다.
19. (청약의 철회)
󰊱계약자는 보험증권을 받은 날로부터 15일이내에 그 청약을 철회할 수 있습니다. 
다만, 진단계약, 보험기간이 1년 미만인 계약 또는 전문보험계약자가 체결한 계
약은 청약을 철회할 수 없습니다. 
용어
풀이
전문보험계약자
보험계약에 관한 전문성, 자산규모 등에 비추어 보험계약의 내용을 이해하고 
이행할 능력이 있는 자로서 보험업법 제2조(정의), 보험업법시행령 제6조의
2(전문보험계약자의 범위 등) 또는 보험업감독규정 제1-4조의2(전문보험계약
자의 범위)에서 정한 국가, 한국은행, 대통령령으로 정하는 금융기관, 주권상
장법인, 지방자치단체, 단체보험계약자 등의 전문보험계약자를 말합니다.
󰊲위 󰊱에도 불구하고, 청약한 날로부터 30일을 초과한 계약은 청약을 철회할 수 
없습니다. 
󰊳계약자는 청약서의 청약철회란을 작성하여 회사에 제출하거나, 통신수단을 이용하
여 위 󰊱의 청약 철회를 신청할 수 있습니다.
󰊴계약자가 청약을 철회한 때에는 회사는 청약의 철회를 접수한 날부터 3일 이내에 
납입한 보험료를 계약자에게 돌려 드리며, 보험료 반환이 늦어진 기간에 대하여
는 이 계약의 보험계약대출이율을 연단위 복리로 계산한 금액을 더하여 지급합니
다. 다만, 계약자가 제1회 보험료를 신용카드로 납입한 계약의 청약을 철회하는 
경우에 회사는 신용카드의 매출을 취소하며 이자를 더하여 지급하지 않습니다.
󰊵청약을 철회할 때에 이미 보험금 지급사유가 발생하였으나 계약자가 그 보험금 
지급사유가 발생한 사실을 알지 못한 경우에는 청약철회의 효력은 발생하지 않습
니다.
󰊶위 󰊱에서 보험증권을 받은 날에 대한 다툼이 발생한 경우 회사가 이를 증명하여
야 합니다.
용어
풀이
보험계약대출이율
해당 보험상품의 약관에 따라 계약자가 대출을 받을 경우, 회사가 정하는 대
출이율이며, 보험계약대출이율이 변경되는 경우, 변경된 시점부터 변경된 이
율을 적용합니다.
20. (약관교부 및 설명의무 등)
󰊱회사는 계약자가 청약할 때에 계약자에게 약관의 중요한 내용을 설명하여야 하며, 
청약 후에 지체없이 약관 및 계약자 보관용 청약서를 드립니다. 다만, 계약자가 
동의하는 경우 약관 및 계약자 보관용 청약서 등을 광기록매체(CD, DVD 등), 전
자우편 등 전자적 방법으로 송부할 수 있으며, 계약자 또는 그 대리인이 약관 및 
계약자 보관용 청약서 등을 수신하였을 때에는 해당 문서를 드린 것으로 봅니다. 
또한, 통신판매계약의 경우,  회사는 계약자의 동의를 얻어 다음 중 한 가지 방법
으로 약관의 중요한 내용을 설명할 수 있습니다.
① 인터넷홈페이지에서 약관 및 그 설명문(약관의 중요한 내용을 알 수 있도록 
설명한 문서)을 읽거나 내려받게 하는 방법. 이 경우 계약자가 이를 읽거나 내
려받은 것을 확인한 때에 해당 약관을 드리고 그 중요한 내용을 설명한 것으
로 봅니다.
② 전화를 이용하여 청약내용, 보험료납입, 보험기간, 계약 전 알릴 의무, 약관의 
중요한 내용 등 계약을 체결하는 데 필요한 사항을 질문 또는 설명하는 방법. 
이 경우 계약자의 답변과 확인내용을 음성 녹음함으로써 약관의 중요한 내용
을 설명한 것으로 봅니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (169, 4, 36, '36
 - 해지환급금에 관한 사항
 - 분쟁조정절차에 관한 사항
 - 만기시 자동갱신되는 보험계약의 경우 자동갱신의 조건
 - 저축성 보험계약의 공시이율
 - 유배당 보험계약의 경우 계약자 배당에 관한 사항
 - 그 밖에 약관에 기재된 보험계약의 중요사항
용어
풀이
통신판매계약
전화․우편․인터넷 등 통신수단을 이용하여 체결하는 계약을 말합니다.
󰊲회사가 위 󰊱에 따라 제공될 약관 및 계약자 보관용 청약서를 청약할 계약자에게 
전달하지 않거나 약관의 중요한 내용을 설명하지 않은 때 또는 계약을 체결할 때 
계약자가 청약서에 자필서명(날인(도장을 찍음) 및 전자서명법 제2조 제2호에 따른 
전자서명 또는 동법 제2조 제3호에 따른 공인전자서명을 포함합니다)을 하지 않은 
때에는 계약자는 계약이 성립한 날부터 3개월 이내에 계약을 취소할 수 있습니다.
인용
문구
전자서명법 제2조(정의)
2. “전자서명”이라 함은 서명자를 확인하고 서명자가 당해 전자문서에 서명
을 하였음을 나타내는데 이용하기 위하여 당해 전자문서에 첨부되거나 논
리적으로 결합된 전자적 형태의 정보를 말한다.
3. “공인전자서명“이라 함은 다음 각목의 요건을 갖추고 공인인증서에 기초
한 전자서명을 말한다.
  가. 전자서명생성정보가 가입자에게 유일하게 속할 것
  나. 서명 당시 가입자가 전자서명생성정보를 지배·관리하고 있을 것
  다. 전자서명이 있은 후에 당해 전자서명에 대한 변경여부를 확인할 수 있
을 것
  라. 전자서명이 있은 후에 당해 전자문서의 변경여부를 확인할 수 있을 것
󰊳위 󰊲에도 불구하고 전화를 이용하여 계약을 체결하는 경우 다음의 각 호의 어느 
하나를 충족하는 때에는 자필서명을 생략할 수 있으며, 위 󰊱의 규정에 따른 음
성녹음 내용을 문서화한 확인서를 계약자에게 드림으로써 계약자 보관용 청약서
를 전달한 것으로 봅니다.
① 계약자, 피보험자 및 보험수익자가 동일한 계약의 경우
② 계약자, 피보험자가 동일하고 보험수익자가 계약자의 법정상속인인 계약일 경
우
󰊴위 󰊲에 따라 계약이 취소된 경우에는 회사는 이미 납입한 보험료를 계약자에게 
돌려 드리며, 보험료를 받은 기간에 대하여 보험계약대출이율을 연단위 복리로 계
산한 금액을 더하여 지급합니다.
21. (계약의 무효)
다음 중 한 가지에 해당하는 경우에는 계약을 무효로 하며 이미 납입한 보험료를 돌
려드립니다. 다만, 회사의 고의 또는 과실로 계약이 무효로 된 경우와 회사가 승낙 
전에 무효임을 알았거나 알 수 있었음에도 보험료를 반환하지 않은 경우에는 보험료
를 납입한 날의 다음날부터 반환일까지의 기간에 대하여 회사는 보험계약대출이율을 
연단위 복리로 계산한 금액을 더하여 돌려 드립니다.
① 타인의 사망을 보험금 지급사유로 하는 계약에서 계약을 체결할 때까지 피보
험자의 서면에 의한 동의를 얻지 않은 경우. 다만, 단체가 규약에 따라 구성원
의 전부 또는 일부를 피보험자로 하는 계약을 체결하는 경우에는 이를 적용하
지 않습니다. 이 때 단체보험의 보험수익자를 피보험자 또는 그 상속인이 아
닌 자로 지정할 때에는 단체의 규약에서 명시적으로 정한 경우가 아니면 이를 
적용합니다. 
② 만15세 미만자, 심신상실자 또는 심신박약자를 피보험자로 하여 사망을 보험
금 지급사유로 한 계약의 경우. 다만, 심신박약자가 계약을 체결하거나 소속 
단체의 규약에 따라 단체보험의 피보험자가 될 때에 의사능력이 있는 경우에
는 그 계약을 유효한 것으로 봅니다.
인용
문구
2015년 3월 11일 이전 계약으로 심신박약자의 사망을 보장하는 계약은 상
법 제732조에 따라 무효가 됩니다. 그러나 2015년 3월 12일 이후 계약은, 
2015년 3월 12일부터 시행되는 상법 제732조의 개정 규정이 적용되므로, 
심신박약자의 사망을 보장하는 계약이라도 심신박약자가 계약을 체결하거나 
소속 단체의 규약에 따라 단체보험의 피보험자가 될 때에 의사능력이 있는 
경우에는 유효한 계약이 됩니다.
③ 계약을 체결할 때 계약에서 정한 피보험자의 나이에 미달되었거나 초과되었을 
경우. 다만, 회사가 나이의 착오를 발견하였을 때 이미 계약나이에 도달한 경
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (170, 4, 37, '보
통
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
37
우에는 유효한 계약으로 보나, 위 ②의 만15세 미만자에 관한 예외가 인정되
는 것은 아닙니다.
22. (계약내용의 변경 등)
󰊱계약자는 회사의 승낙을 얻어 다음의 사항을 변경할 수 있습니다. 이 경우 승낙을 
서면 등으로 알리거나 보험증권의 뒷면에 기재하여 드립니다.
① 보험종목
② 보험기간
③ 보험료 납입주기, 납입방법 및 납입기간
④ 계약자, 피보험자
⑤ 보험가입금액, 보험료 등 기타 계약의 내용
󰊲계약자는 보험수익자를 변경할 수 있으며 이 경우에는 회사의 승낙이 필요하지 
않습니다. 다만, 변경된 보험수익자가 회사에 권리를 대항하기 위해서는 계약자가 
보험수익자가 변경되었음을 회사에 통지하여야 합니다.
󰊳회사는 계약자가 제1회 보험료를 납입한 때부터 1년 이상 지난 유효한 계약으로
서 그 보험종목의 변경을 요청할 때에는 회사의 사업방법서에서 정하는 방법에 
따라 이를 변경하여 드립니다.
󰊴회사는 계약자가 위 󰊱.⑤의 규정에 따라 보험가입금액을 감액하고자 할 때에는 
그 감액된 부분은 해지된 것으로 보며, 이로써 회사가 지급하여야 할 해지환급금
이 있을 때에는 34.(해지환급금) 󰊱에 따른 해지환급금을 계약자에게 지급합니다.
󰊵계약자가 위 󰊲의 규정에 따라 보험수익자를 변경하고자 할 경우에는 보험금 지
급사유가 발생하기 전에 피보험자가 서면으로 동의하여야 합니다. 
󰊶회사는 위 󰊱에 따라 계약자를 변경한 경우, 변경된 계약자에게 보험증권 및 약
관을 교부하고 변경된 계약자가 요청하는 경우 약관의 중요한 내용을 설명하여 
드립니다.
󰊷위 󰊱에 따라 계약의 위험이 증가하거나 감소하는 등 계약내용이 변경되는 경우 
납입보험료가 변경될 수 있으며, 계약의 변경시점 이후 잔여보험기간의 보장을 
위한 재원인 책임준비금 정산으로 계약자가 추가납입하여야 할(또는 반환받을) 금
액이 발생할 수 있습니다.
󰊸위 󰊱의 규정에 따라 보험료를 감액하는 등 계약내용이 변경되는 경우 만기(해지)
환급금이 없거나 최초 가입시 안내한 만기(해지)환급금 보다 적어질 수 있습니다.
23. (보험나이 등)
󰊱이 약관에서의 피보험자의 나이는 보험나이를 기준으로 합니다. 다만, 21.(계약의 
무효) ②의 경우에는 실제 만 나이를 적용합니다.
󰊲위 󰊱의 보험나이는 계약일 현재 피보험자의 실제 만 나이를 기준으로 6개월 미
만의 끝수는 버리고 6개월 이상의 끝수는 1년으로 하여 계산하며, 이후 매년 계
약해당일에 나이가 증가하는 것으로 합니다.
󰊳피보험자의 나이 또는 성별에 관한 기재사항이 사실과 다른 경우에는 정정된 나
이 또는 성별에 해당하는 보험금 및 보험료로 변경합니다.
보험
지식
보험나이 계산 예시
생년월일 : 1986년 8월 14일, 현재(계약일) : 2017년 2월 25일
⇒ 2017년 2월 25일 - 1986년 8월 14일 = 30년 6월 11일 = 31세
24. (계약의 소멸)
󰊱보험증권에 기재된 피보험자가 보험기간 중에 사망할 경우에 이 계약은 소멸됩니다.
󰊲위 󰊱에는 보험기간에 다음 어느 하나의 사유가 발생한 경우를 포함합니다. 
① 실종선고를 받은 경우: 법원에서 인정한 실종기간이 끝나는 때에 사망한 것으
로 봅니다.
② 관공서에서 수해, 화재나 그 밖의 재난을 조사하고 사망한 것으로 통보하는 
경우: 가족관계등록부에 기재된 사망연월일을 기준으로 합니다. 
󰊳위 󰊱및 󰊲에 따라 계약이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 적립한 사망 당시의 책임준비금을 지급합니다.
용어
풀이
책임준비금
장래의 보험금, 해지환급금 등을 지급하기 위하여 계약자가 납입한 보험료 
중 일정액을 회사가 적립해 둔 금액을 말합니다.
 
󰊴위에 따라 책임준비금 지급사유가 발생한 경우 회사는 8.(보험금의 지급절차)에 
따라 책임준비금을 보험계약자에게 지급하여 드립니다. 이 때, 8.(보험금의 지급
절차)에 따른 지급기일의 다음날부터 지급일까지의 기간에 대한 이자의 계산은 
‘【별표1】 보험금을 지급할 때의 적립이율 계산’을 따릅니다.
󰊵위 󰊳에도 불구하고 다음의 두가지 사유에 모두 해당하는 경우에는 32.(중대사유
로 인한 해지)를 따릅니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (171, 4, 38, '38
① 피보험자의 사망을 보험금 지급 사유로 하는 경우
② 계약자, 피보험자 또는 보험수익자의 고의로 인해 피보험자가 사망한 경우
제5관 보험료의 납입
25. (제1회 보험료 및 회사의 보장개시)
󰊱회사는 계약의 청약을 승낙하고 제1회 보험료를 받은 때부터 이 약관이 정한 바
에 따라 보장을 합니다. 또한, 회사가 청약과 함께 제1회 보험료를 받은 후 승낙
한 경우에도 제1회 보험료를 받은 때부터 보장이 개시됩니다. 자동이체 또는 신
용카드로 납입하는 경우에는 자동이체신청 또는 신용카드매출승인에 필요한 정보
를 제공한 때를 제1회 보험료를 받은 때로 하며, 계약자의 책임 있는 사유로 자
동이체 또는 매출승인이 불가능한 경우에는 보험료가 납입되지 않은 것으로 봅니
다.
󰊲위 󰊱의 보험료는 3.(보험금의 지급사유)의 손해를 보장하는데 필요한 보험료(이
하“보장보험료”라 합니다)와 회사가 적립한 금액을 돌려주는데 필요한 보험료(이
하 “적립보험료”라 합니다)로 구성됩니다.(이하 보장보험료와 적립보험료를 합하여 
“보험료”라 합니다)
󰊳회사가 청약과 함께 제1회 보험료를 받고 청약을 승낙하기 전에 보험금 지급사
유가 발생하였을 때에도 보장개시일부터 이 약관이 정하는 바에 따라 보장을 합
니다.
보험
지식
보장개시일
회사가 보장을 개시하는 날로서 계약이 성립되고 제1회 보험료를 받은 날을 
말하나, 회사가 승낙하기 전이라도 청약과 함께 제1회 보험료를 받은 경우에
는 제1회 보험료를 받은 날을 말합니다. 또한, 보장개시일을 계약일로 봅니다.
󰊴회사는 위 󰊳에도 불구하고 다음 중 한 가지에 해당되는 경우에는 보장을 하지 
않습니다.
① 14.(계약 전 알릴 의무)의 규정에 따라 계약자 또는 피보험자가 회사에 알린 
내용이나 건강진단 내용이 보험금 지급사유의 발생에 영향을 미쳤음을 회사가 
증명하는 경우
② 16.(알릴 의무 위반의 효과)를 준용하여 회사가 보장을 하지 않을 수 있는 경
우
③ 진단계약에서 보험금 지급사유 발생할 때 까지 진단을 받지 않은 경우. 다만, 
진단계약에서 진단을 받지 않은 경우라도 상해로 보험금 지급사유가 발생하는 
경우에는 보장을 해드립니다.
26. (제2회 이후 보험료의 납입)
계약자는 제2회 이후의 보험료를 납입기일까지 납입하여야 하며, 회사는 계약자가 보
험료를 납입한 경우에는 영수증을 발행하여 드립니다. 다만, 금융회사(우체국을 포함
합니다)를 통하여 보험료를 납입한 경우에는 그 금융회사 발행 증빙서류를 영수증으
로 대신합니다.
용어
풀이
납입기일
계약자가 제2회 이후의 보험료를 납입하기로 한 날을 말합니다.
27. (보험료의 자동대출납입)
󰊱계약자는 28.(보험료의 납입이 연체되는 경우 납입최고(독촉)와 계약의 해지)에 
따른 보험료의 납입최고(독촉)기간이 지나기 전까지 회사가 정한 방법에 따라 보
험료의 자동대출납입을 신청할 수 있으며, 이 경우 37.(보험계약대출) 󰊱에 따른 
보험계약대출금으로 보험료가 자동으로 납입되어 계약은 유효하게 지속됩니다. 다
만, 계약자가 서면 이외에 인터넷 또는 전화(음성녹음) 등으로 자동대출납입을 신
청할 경우 회사는 자동대출납입 신청내역을 서면 또는 전화(음성녹음) 등으로 계
약자에게 알려드립니다.
󰊲위 󰊱의 규정에 의한 대출금과 보험료의 자동대출 납입일의 다음날부터 그 다음 
보험료의 납입최고(독촉)기간까지의 이자(보험계약대출이율 이내에서 회사가 별도
로 정하는 이율을 적용하여 계산합니다)를 더한 금액이 해당 보험료가 납입된 것
으로 계산한 해지환급금과 계약자에게 지급할 기타 모든 지급금의 합계액에서 계
약자의 회사에 대한 모든 채무액을 뺀 금액을 초과하는 경우에는 보험료의 자동
대출납입을 더는 할 수 없습니다.
󰊳위 󰊱및 󰊲에 의한 보험료의 자동대출납입 기간은 최초 자동대출납입일부터 1년
을 한도로 하며 그 이후의 기간에 대한 보험료의 자동대출 납입을 위해서는 󰊱에 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (172, 4, 39, '보
통
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
39
따라 재신청을 하여야 합니다.
󰊴보험료의 자동대출 납입이 행하여진 경우에도 자동대출 납입 전 납입최고(독촉)기
간이 끝나는 날의 다음날부터 1개월 이내에 계약자가 계약의 해지를 청구한 때에
는 회사는 보험료의 자동대출 납입이 없었던 것으로 하여 34.(해지환급금) 󰊱에 
따른 해지환급금을 지급합니다.
󰊵회사는 자동대출납입이 종료된 날부터 15일 이내에 자동대출납입이 종료되었음을 
서면, 전화(음성녹음) 또는 전자문서(SMS 포함) 등으로 계약자에게 안내하여 드
립니다.
28. (보험료의 납입이 연체되는 경우 납입최고(독촉)와 계약의 해지)
󰊱계약자가 제2회 이후의 보험료를 납입기일까지 납입하지 않아 보험료 납입이 연
체 중인 경우에 회사는 14일(보험기간이 1년 미만인 경우에는 7일) 이상의 기간
을 납입최고(독촉)기간(납입최고(독촉)기간의 마지막 날이 영업일이 아닌 때에는 
최고(독촉)기간은 그 다음 날까지로 합니다)으로 정하여 아래 사항에 대하여 서면
(등기우편 등), 전화(음성녹음) 또는 전자문서 등으로 알려드립니다. 다만, 해지 
전에 발생한 보험금 지급사유에 대하여 회사는 보상하여 드립니다.
① 계약자(보험수익자와 계약자가 다른 경우 보험수익자를 포함합니다)에게 납입
최고(독촉)기간 내에 연체보험료를 납입하여야 한다는 내용
② 납입최고(독촉)기간이 끝나는 날까지 보험료를 납입하지 않을 경우 납입최고
(독촉)기간이 끝나는 날의 다음날에 계약이 해지된다는 내용(이 경우 계약이 
해지되는 때에는 즉시 해지환급금에서 보험계약대출원금과 이자가 차감된다는 
내용을 포함합니다)
󰊲회사가 위 󰊱에 따른 납입최고(독촉) 등을 전자문서로 안내하고자 할 경우에는 계
약자에게 서면, 전자서명법 제2조 제2호에 따른 전자서명 또는 동법 제2조 제3호
에 따른 공인전자서명으로 동의를 얻어 수신확인을 조건으로 전자문서를 송신하
여야 하며, 계약자가 해당 전자문서에 대하여 수신확인을 하기 전까지는 그 전자
문서는 송신되지 않은 것으로 봅니다. 회사는 전자문서가 수신되지 않은 것을 확
인한 경우에는 위 󰊱에서 정한 내용을 서면(등기우편 등) 또는 전화(음성녹음)로 
다시 알려 드립니다.
인용
문구
전자서명법 제2조(정의)
2. “전자서명”이라 함은 서명자를 확인하고 서명자가 당해 전자문서에 서명
을 하였음을 나타내는데 이용하기 위하여 당해 전자문서에 첨부되거나 논
리적으로 결합된 전자적 형태의 정보를 말한다.
3. “공인전자서명“이라 함은 다음 각목의 요건을 갖추고 공인인증서에 기초
한 전자서명을 말한다.
  가. 전자서명생성정보가 가입자에게 유일하게 속할 것
  나. 서명 당시 가입자가 전자서명생성정보를 지배·관리하고 있을 것
  다. 전자서명이 있은 후에 당해 전자서명에 대한 변경여부를 확인할 수 있
을 것
  라. 전자서명이 있은 후에 당해 전자문서의 변경여부를 확인할 수 있을 것
󰊳위 󰊱에 따라 계약이 해지된 경우에는 34.(해지환급금) 󰊱에 따른 해지환급금을 
계약자에게 지급합니다.
29. (보험료의 납입을 연체하여 해지된 계약의 부활(효력회복))
󰊱28.(보험료의 납입이 연체되는 경우 납입최고(독촉)와 계약의 해지)에 따라 계약
이 해지되었으나 해지환급금을 받지 않은 경우(보험계약대출 등에 따라 해지환급
금이 차감되었으나 받지 않은 경우 또는 해지환급금이 없는 경우를 포함합니다) 
계약자는 해지된 날부터 3년 이내에 회사가 정한 절차에 따라 계약의 부활(효력
회복)을 청약할 수 있습니다. 회사가 부활(효력회복)을 승낙한 때에 계약자는 부
활(효력회복)을 청약한 날까지의 연체된 보험료에 “평균공시이율 + 1%” 범위내
에서 회사가 정하는 이율로 계산한 금액을 더하여 납입하여야 합니다. 다만, 금리
연동형보험은 사업방법서에서 별도로 정한 이율로 계산합니다.
󰊲위 󰊱에 따라 해지계약을 부활(효력회복)하는 경우에는 14.(계약 전 알릴 의무), 
16.(알릴 의무 위반의 효과), 17.(사기에 의한 계약), 18.(보험계약의 성립) 및 
25.(제1회 보험료 및 회사의 보장개시)를 준용합니다.
󰊳위 󰊱에서 정한 계약의 부활(효력회복)이 이루어진 경우라도 계약자 또는 피보험
자가 최초계약 청약시 14.(계약 전 알릴 의무)를 위반한 경우에는 16.(알릴 의무 
위반의 효과)가 적용됩니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (173, 4, 40, '40
용어
풀이
평균공시이율
전체 보험회사 공시이율의 평균으로, 이 계약 체결 시점의 이율을 말합니다.
30. (강제집행 등으로 인한 해지계약의 특별부활(효력회복))
󰊱회사는 계약자의 해지환급금 청구권에 대한 강제집행, 담보권실행, 국세 및 지방세 
체납처분절차에 따라 계약이 해지된 경우 해지 당시의 보험수익자가 계약자의 동
의를 얻어 계약 해지로 회사가 채권자에게 지급한 금액을 회사에 지급하고 22.(계
약내용의 변경 등) 󰊱의 절차에 따라 계약자 명의를 보험수익자로 변경하여 계약
의 특별부활(효력회복)을 청약할 수 있음을 보험수익자에게 통지하여야 합니다. 
󰊲회사는 위 󰊱에 따른 계약자 명의변경 신청 및 계약의 특별부활(효력회복) 청약을 
승낙합니다.
󰊳회사는 위 󰊱의 통지를 지정된 보험수익자에게 하여야 합니다. 다만, 회사는 법정
상속인이 보험수익자로 지정된 경우에는 위 󰊱의 통지를 계약자에게 할 수 있습
니다.
󰊴회사는 위 󰊱의 통지를 계약이 해지된 날부터 7일 이내에 하여야 합니다.
󰊵보험수익자는 통지를 받은 날(위 󰊳에 따라 계약자에게 통지된 경우에는 계약자
가 통지를 받은 날을 말합니다)부터 15일 이내에 위 󰊱의 절차를 이행할 수 있습
니다.
제6관 계약의 해지 및 해지환급금 등
31. (계약자의 임의해지 및 피보험자의 서면동의 철회)
󰊱계약자는 계약이 소멸하기 전에는 언제든지 계약을 해지할 수 있으며, 이 경우 회
사는 34.(해지환급금) 󰊱에 따른 해지환급금을 계약자에게 지급합니다. 다만, 타
인을 위한 계약의 경우에는 계약자는 그 타인의 동의를 얻거나 보험증권을 소지
한 경우에 한하여 계약을 해지할 수 있습니다.
󰊲21.(계약의 무효)에 따라 사망을 보험금 지급사유로 하는 계약에서 서면으로 동의
를 한 피보험자는 계약의 효력이 유지되는 기간에는 언제든지 서면동의를 장래를 
향하여 철회할 수 있으며, 서면동의 철회로 계약이 해지되어 회사가 지급하여야 
할 해지환급금이 있을 때에는 34.(해지환급금) 󰊱에 따른 해지환급금을 계약자에
게 지급합니다.
 
32. (중대사유로 인한 해지)
󰊱회사는 아래와 같은 사실이 있을 경우에는 그 사실을 안 날부터 1개월 이내에 계
약을 해지할 수 있습니다.
① 계약자, 피보험자 또는 보험수익자가 고의로 보험금 지급 사유를 발생시킨 경우
② 계약자, 피보험자 또는 보험수익자가 보험금 청구에 관한 서류에 고의로 사실
과 다른 것을 기재하였거나 그 서류 또는 증거를 위조 또는 변조한 경우. 다
만, 이미 보험금 지급사유가 발생한 경우에는 보험금 지급에 영향을 미치지 
않습니다.
󰊲회사가 위 󰊱에 따라 계약을 해지한 경우 회사는 그 취지를 계약자에게 통지하고 
34.(해지환급금) 󰊱에 따른 해지환급금을 지급합니다.
33. (회사의 파산선고와 해지)
󰊱회사가 파산의 선고를 받은 때에는 계약자는 계약을 해지할 수 있습니다.
󰊲위 󰊱의 규정에 따라 해지하지 않은 계약은 파산선고 후 3개월이 지난 때에는 그 
효력을 잃습니다.
󰊳위 󰊱의 규정에 따라 계약이 해지되거나 위 󰊲의 규정에 따라 계약이 효력을 잃는 
경우에 회사는 34.(해지환급금) 󰊱에 의한 해지환급금을 계약자에게 지급합니다.
34. (해지환급금)
󰊱이 약관에 따른 해지환급금은 “보험료 및 책임준비금 산출방법서”에 따라 계산합
니다. 이때, 적립부분 순보험료에 대하여는 회사는 제1회 보험료를 받은 날부터 
이 계약의 공시이율을 적용합니다. 그러나 기인출된 중도인출금이 있는 경우에는 
그 원리금 합계액을 빼고 지급합니다.
󰊲위 󰊱의 공시이율이 보험기간 중에 변경되는 경우에는 변경된 시점 이후부터 
35.(공시이율의 적용 및 공시)에 따라 변경된 이율을 적용하며, 최저보증이율은 
연복리 0.3%로 합니다.
󰊳해지환급금의 지급사유가 발생한 경우 계약자는 회사에 해지환급금을 청구하여야 
하며, 회사는 청구를 접수한 날부터 3영업일 이내에 해지환급금을 지급합니다. 해
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (174, 4, 41, '보
통
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
41
지환급금 지급일까지의 기간에 대한 이자의 계산은 ‘【별표1】 보험금을 지급할 때
의 적립이율 계산’에 따릅니다. 
󰊴회사는 경과기간별 해지환급금에 관한 표를 계약자에게 제공하여 드립니다.
용어
풀이
공시이율
전통적인 보험상품에 적용되는 이율이 장기·고정금리이기 때문에 시중금리가 
급격하게 변동할 경우 이에 대응하지 못하는 단점을 고려하여, 시중의 지표
금리 등에 연동하여 일정기간 마다 변동되는 이율을 말합니다.
최저보증이율
운용자산이익률 및 외부지표금리가 하락하더라도 보험회사에서 보증하는 최
저한도의 적용이율입니다. 예를 들어, 적립금이 공시이율에 따라 적립되며 
공시이율이 0.1%인 경우(최저보증이율은 0.3%일 경우), 적립금은 공시이
율(0.1%)이 아닌 최저보증이율(0.3%)로 적립됩니다.
35. (공시이율의 적용 및 공시)
󰊱이 계약에서 적립부분 순보험료에 대한 적립이율은 매월 1일 회사가 정한 공시이
율로 하며, 당월 말일까지 1개월간 확정 적용합니다. 여기서 공시이율은 「보장성
공시이율1701」(이하 ‘공시이율’이라 합니다)를 말합니다.
󰊲위 󰊱의 공시이율은 이 계약의 사업방법서에서 정하는 바에 따라 운용자산이익률
과 외부지표금리를 가중평균하여 산출된 공시기준이율에서 향후 예상수익 등을 
고려한 조정률을 가감하여 결정합니다.
󰊳위 󰊲에도 불구하고 최저보증이율은 0.3%로 합니다. 
󰊴회사는 위 󰊲에서 정한 공시이율을 매월 회사의 인터넷 홈페이지 등을 통해 공시
합니다.
36. (중도인출금)
󰊱회사는 계약자가 보험료를 정상적으로 납입하고 보험계약이 유효한 경우에 보험계
약일로부터 1년이 지난 후부터 계약자의 청구가 있는 경우에 매 보험년도마다 4
회에 한하여 인출할 수 있습니다. 다만, 중도인출금은 계약자가 요청하는 시점의 
보통약관 해지환급금과 보통약관 적립부분 해지환급금 중 적은 금액(보험계약대출
이 있는 경우 그 원리금 합계액을 공제한 후의 금액)의 80%이내에서 인출할 수 
있습니다.
용어
풀이
보험년도
보험계약일로부터 다음 해의 보험계약 해당일 전일까지 매1년 단위의 연도
를 말합니다. 예를 들어, 보험계약일이 2016년 10월 28일인 경우 보험년도
는 10월 28일부터 다음 해 10월 27일까지의 1년을 말합니다.
보험
지식
중도인출금의 한도 예시 
중도인출을 요청하는 시점에서 ‘보험료 및 책임준비금 산출방법서’에 의해 산
출한 보통약관 해지환급금과 보통약관 적립부분 해지환급금 중 적은 금액이 
100만원인 경우
○ 중도인출 가능액 = 100만원 × 80% = 80만원
○ 보험계약대출이 있는 경우 (원금과 이자의 합계를 30만원으로 가정)
   중도인출 가능액 = (100만원 – 30만원) × 80% = 56만원
󰊲중도인출시 만기(해지)환급금에서 인출금액 및 인출금액에 적립되었을 이자만큼 
차감되므로 만기(해지)환급금이 감소합니다.
37. (보험계약대출)
󰊱계약자는 「이 계약의 해지환급금 범위 내에서 회사가 정한 방법에 따라 대출」(이
하 “보험계약대출”이라 합니다)을 받을 수 있습니다. 그러나, 순수보장성보험 등 
보험상품의 종류에 따라 보험계약대출이 제한될 수도 있습니다.
󰊲계약자는 위 󰊱의 규정에 따른 보험계약대출금과 그 이자를 언제든지 상환할 수 
있으며 상환하지 않은 때에는 회사는 보험금, 해지환급금 등의 지급사유가 발생한 
날에 지급금에서 보험계약대출의 원금과 이자를 차감할 수 있습니다.
󰊳위 󰊲의 규정에도 불구하고 회사는 28.(보험료의 납입이 연체되는 경우 납입최고
(독촉)와 계약의 해지)에 따라 계약이 해지되는 때에는 즉시 해지환급금에서 보험
계약대출의 원금과 이자를 차감합니다.
󰊴회사는 보험수익자에게 보험계약대출 사실을 통지할 수 있습니다.
38. (배당금의 지급)
회사는 이 보험에 대하여 계약자에게 배당금을 지급하지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (175, 4, 42, '42
제7관 보험계약의 자동갱신 등(2종限)
39. (적용범위)
이 관에서 정한 내용은 이 계약을 2종(갱신형)으로 가입한 경우에만 적용됩니다.
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
계약을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기재하
여 드립니다.
예시) 3/7년만기 자동갱신
40. (보험기간 및 자동갱신) 
󰊱이 계약의 보험기간은 보험증권에 기재된 보험기간으로 합니다.
󰊲이 계약이 아래 ① 내지 ③의 조건을 충족하는 경우에는, 이 계약의 만기일의 전
일까지 계약자의 별도의 의사표시가 없을 때에는 「종전의 계약」(이하 “갱신 전 계
약”이라 합니다)과 동일한 내용으로 「이 계약의 만기일의 다음날」(이하 “갱신일”이
라 합니다)에 갱신되는 것으로 합니다.
① 「갱신된 계약」(이하 “갱신계약”이라 합니다)의 만기일이 회사가 정한 기간 내일 
것
② 갱신일에 있어서 피보험자의 나이가 회사가 정한 나이의 범위 내일 것
③ 갱신 전 계약의 보험료가 정상적으로 납입완료 되었을 것
󰊳위 󰊱에도 불구하고 갱신시점에서 잔여보험기간이 위 󰊱의 보험기간 미만일 경우 
그 잔여기간을 보장기간으로 하여 갱신되는 것으로 합니다.
󰊴회사는 위 󰊲및 󰊳에 의하여 이 계약이 갱신되는 경우 별도의 보험증권을 발행
하지 않습니다.
41. (갱신계약 제1회 보험료의 납입이 연체되는 경우 납입최고(독촉)와 계약
의 해지)
계약자가 갱신계약의 제1회 보험료를 갱신일까지 납입하지 않은 때에는 회사는 28.
(보험료의 납입이 연체되는 경우 납입최고(독촉)와 계약의 해지)에 따라 계약자에게 
최고(독촉)하고 이 납입최고(독촉)기간 안에 갱신계약 보험료가 납입되지 않은 경우 
납입최고(독촉)기간이 끝나는 날의 다음날 갱신계약은 해지됩니다. 다만, 납입최고(독
촉)기간 안에 발생한 사고에 대하여 회사는 약정한 보험금을 지급합니다. 이 경우 계
약자는 즉시 갱신계약 보험료를 납입하여야 하며, 이 보험료를 납입하지 아니하면 회
사는 지급할 보험금에서 이를 공제할 수 있습니다.
42. (자동갱신 적용)
󰊱회사는 보험가입 후 갱신계약에 대하여 가입시점의 약관을 적용하며(단, 법령 및 
금융위원회의 명령, 제도적인 약관개정에 따라 약관이 변경된 경우에는 변경된 약
관 적용합니다), 보험요율에 관한 제도 또는 보험료를 개정한 경우 이 계약에 대
해서는 갱신일 현재의 제도 또는 보험료를 적용합니다.
󰊲회사는 이 계약의 보험기간이 끝나기 15일 전까지 해당 계약자가 납입하여야하는 
갱신계약 보험료를 서면, 전화(음성녹음) 또는 전자문서 등으로 안내합니다.
제8관 분쟁조정 등
43. (분쟁의 조정)
계약에 관하여 분쟁이 있는 경우 분쟁 당사자 또는 기타 이해관계인과 회사는 금융감
독원장에게 조정을 신청할 수 있습니다.
44. (관할법원)
이 계약에 관한 소송 및 민사조정은 계약자의 주소지를 관할하는 법원으로 합니다. 
다만, 회사와 계약자가 합의하여 관할법원을 달리 정할 수 있습니다.
45. (소멸시효)
보험금청구권, 만기환급금청구권, 보험료 반환청구권, 해지환급금 청구권, 책임준비금 
반환청구권 및 배당청구권은 3년간 행사하지 않으면 소멸시효가 완성됩니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (176, 4, 43, '보
통
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
43
46. (약관의 해석)
󰊱회사는 신의성실의 원칙에 따라 공정하게 약관을 해석하여야 하며 계약자에 따라 
다르게 해석하지 않습니다.
󰊲회사는 약관의 뜻이 명백하지 않은 경우에는 계약자에게 유리하게 해석합니다.
󰊳회사는 보험금을 지급하지 않는 사유 등 계약자나 피보험자에게 불리하거나 부담
을 주는 내용은 확대하여 해석하지 않습니다.
47. (회사가 제작한 보험안내자료 등의 효력)
보험설계사 등이 모집과정에서 사용한 회사 제작의 보험안내자료(계약의 청약을 권유
하기 위해 만든 자료 등을 말합니다)의 내용이 약관의 내용과 다른 경우에는 계약자
에게 유리한 내용으로 계약이 성립된 것으로 봅니다.
48. (회사의 손해배상책임)
󰊱회사는 계약과 관련하여 임직원, 보험 설계사 및 대리점의 책임있는 사유로 계약
자, 피보험자 및 보험수익자에게 발생된 손해에 대하여 관계 법령 등에 따라 손해
배상의 책임을 집니다.
󰊲회사는 보험금 지급 거절 및 지연지급의 사유가 없음을 알았거나 알 수 있었는데
도 소를 제기하여 계약자, 피보험자 또는 보험수익자에게 손해를 가한 경우에는 
그에 따른 손해를 배상할 책임을 집니다.
󰊳회사가 보험금 지급여부 및 지급금액에 관하여 현저하게 공정을 잃은 합의로 보
험수익자에게 손해를 가한 경우에도 회사는 위 󰊲에 따라 손해를 배상할 책임을 
집니다.
49. (개인정보보호)
󰊱회사는 이 계약과 관련된 개인정보를 이 계약의 체결, 유지, 보험금 지급 등을 위
하여 「개인정보 보호법」,「신용정보의 이용 및 보호에 관한 법률」등 관계 법령에 정
한 경우를 제외하고 계약자, 피보험자 또는 보험수익자의 동의없이 수집, 이용, 
조회 또는 제공하지 않습니다. 다만, 회사는 이 계약의 체결, 유지, 보험금 지급 
등을 위하여 위 관계 법령에 따라 계약자 및 피보험자의 동의를 받아 다른 보험
회사 및 보험관련단체 등에 개인정보를 제공할 수 있습니다. 
󰊲회사는 계약과 관련된 개인정보를 안전하게 관리하여야 합니다.
50. (준거법)
이 계약은 대한민국 법에 따라 규율되고 해석되며, 약관에서 정하지 않은 사항은 상
법, 민법 등 관계 법령을 따릅니다.
51. (예금보험에 의한 지급보장)
회사가 파산 등으로 인하여 보험금 등을 지급하지 못할 경우에는 예금자보호법에서 
정하는 바에 따라 그 지급을 보장합니다. 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (177, 4, 44, '') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (178, 4, 45, '보
통
약
관
특별약관
제1장 상해관련
특별약관
제1장 상해관련
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (179, 4, 46, '46
어려운 용어는 프로미라이프 용어사전 참고 ……………………………………   21
인용 법규는   약관에서 인용한 법규  참고 ……………………………………  123 
1
이륜자동차 운전중 교통상해사망(비갱신형/갱신형)
특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)의 직접결과로써 사망한 경우 이 특별약관의 보험가입금액을 보험수익자에게 
이륜자동차운전중교통상해사망보험금으로 지급합니다.
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
2. (보험금 지급에 관한 세부규정)
󰊱1.(보험금의 지급사유)의 ‘사망’에는 보험기간에 다음 어느 하나의 사유가 발생한 
경우를 포함합니다. 
① 실종선고를 받은 경우: 법원에서 인정한 실종기간이 끝나는 때에 사망한 것으
로 봅니다.
② 관공서에서 수해, 화재나 그 밖의 재난을 조사하고 사망한 것으로 통보하는 
경우: 가족관계등록부에 기재된 사망연월일을 기준으로 합니다. 
󰊲보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (180, 4, 47, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
47
수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 
중에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
3. (보험금을 지급하지 않는 사유)
회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 발생
한 때에는 보험금을 지급하지 않습니다.
4. (특별약관의 소멸)
󰊱회사가 1.(보험금의 지급사유)의 이륜자동차운전중교통상해사망보험금을 지급한 
경우에 그 손해보장의 원인이 생긴 때로부터 이 특별약관은 소멸됩니다.
󰊲위 󰊱에 따라 특별약관이 소멸되는 경우에는 회사는 해지환급금을 지급하지 않습
니다.
󰊳위 󰊱이외의 원인으로 특별약관이 소멸되는 경우 “보험료 및 책임준비금 산출방
법서”에서 정하는 바에 따라 회사가 그 때까지 적립한 책임준비금을 지급합니다.
󰊴위 󰊳의 규정에도 불구하고 피보험자, 보험수익자 또는 계약자의 고의로 인해 특
별약관이 소멸되는 경우에는 보통약관 32.(중대사유로 인한 해지)의 규정을 따릅
니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정) 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
2
이륜자동차 운전중 교통상해후유장해(3~100%) 
(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)로 장해분류표(【별표2】장해분류표 참조. 이하 같습니다)에서 정한 장해지급률이 
3~100%에 해당하는 장해상태가 되었을 때 장해분류표에서 정한 지급률을 이 특
별약관의 보험가입금액에 곱하여 산출한 금액을 보험수익자에게 이륜자동차운전중
교통상해후유장해(3~100%)보험금으로 지급합니다.
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (181, 4, 48, '48
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
2. (보험금 지급에 관한 세부규정)
󰊱1.(보험금의 지급사유)에서 장해지급률이 이륜자동차 운전중 교통상해 발생일로부
터 180일 이내에 확정되지 않는 경우에는 이륜자동차 운전중 교통상해 발생일로
부터 180일이 되는 날의 의사 진단에 기초하여 고정될 것으로 인정되는 상태를 
장해지급률로 결정합니다. 다만, 장해분류표에 장해판정시기를 별도로 정한 경우
에는 그에 따릅니다.
󰊲위 󰊱에 따라 장해지급률이 결정되었으나 그 이후 보장받을 수 있는 기간(계약의 
효력이 없어진 경우에는 보험기간이 10년 이상인 계약은 이륜자동차 운전중 교통
상해 발생일로부터 2년 이내로 하고, 보험기간이 10년 미만인 계약은 이륜자동차 
운전중 교통상해 발생일로부터 1년 이내)에 장해상태가 더 악화된 때에는 그 악
화된 장해상태를 기준으로 장해지급률을 결정합니다.
󰊳장해분류표에 해당되지 않는 후유장해는 피보험자의 직업, 나이, 신분 또는 성별 
등에 관계없이 신체의 장해정도에 따라 장해 분류표의 구분에 준하여 지급액을 
결정합니다. 다만, 장해분류표의 각 장해분류별 최저 지급률 장해정도에 이르지 
않는 후유장해에 대하여는 후유장해보험금을 지급하지 않습니다.
󰊴보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따
를 수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문
의 중에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합
니다.
󰊵같은 이륜자동차 운전중 교통상해로 두 가지 이상의 후유장해가 생긴 경우에는 
후유장해지급률을 더하여 지급합니다. 다만, 장해분류표의 각 신체부위별 판정기
준에 별도로 정한 경우에는 그 기준에 따릅니다.
󰊶다른 이륜자동차 운전중 교통상해로 인하여 후유장해가 2회 이상 발생하였을 경
우에는 그 때마다 이에 해당하는 후유장해지급률을 결정합니다. 그러나 그 후유장
해가 이미 후유장해보험금을 지급받은 동일한 부위에 가중된 때에는 최종 장해상
태에 해당하는 후유장해보험금에서 이미 지급받은 후유장해보험금을 차감하여 지
급합니다. 다만, 장해 분류표의 각 신체부위별 판정기준에서 별도로 정한 경우에
는 그 기준에 따릅니다.
󰊷이미 이 계약에서 후유장해보험금 지급사유에 해당되지 않았거나(보장개시 이전의 
원인에 의하거나 또는 그 이전에 발생한 후유장해를 포함합니다), 후유장해보험금
이 지급되지 않았던 피보험자에게 그 신체의 동일 부위에 또다시 위 󰊶에 규정하
는 후유장해상태가 발생하였을 경우에는 직전까지의 후유장해에 대한 후유장해보
험금이 지급된 것으로 보고 최종 후유장해 상태에 해당되는 후유장해보험금에서 
이를 차감하여 지급합니다.
󰊸회사가 지급하여야 할 하나의 상해로 인한 후유장해보험금은 보험가입금액을 한도
로 합니다. 
3. (보험금을 지급하지 않는 사유)
회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 발생
한 때에는 보험금을 지급하지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (182, 4, 49, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
49
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
4. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
3
이륜자동차 운전중 교통상해80%이상후유장해
(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)로 장해분류표(【별표2】장해분류표 참조. 이하 같습니다)에서 정한 장해지급률이 
80%이상에 해당하는 장해상태가 되었을 때 1회에 한하여 이 특별약관의 보험가
입금액을 보험수익자에게 이륜자동차운전중교통상해80%이상후유장해보험금으로 
지급합니다.
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (183, 4, 50, '50
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
2. (보험금 지급에 관한 세부규정)
󰊱1.(보험금의 지급사유)에서 장해지급률이 이륜자동차 운전중 교통상해 발생일로부
터 180일 이내에 확정되지 않는 경우에는 이륜자동차 운전중 교통상해 발생일로
부터 180일이 되는 날의 의사 진단에 기초하여 고정될 것으로 인정되는 상태를 
장해지급률로 결정합니다. 다만, 장해분류표에 장해판정시기를 별도로 정한 경우
에는 그에 따릅니다.
󰊲위 󰊱에 따라 장해지급률이 결정되었으나 그 이후 보장받을 수 있는 기간(계약의 
효력이 없어진 경우에는 보험기간이 10년 이상인 계약은 이륜자동차 운전중 교통
상해 발생일로부터 2년 이내로 하고, 보험기간이 10년 미만인 계약은 이륜자동차 
운전중 교통상해 발생일로부터 1년 이내)에 장해상태가 더 악화된 때에는 그 악
화된 장해상태를 기준으로 장해지급률을 결정합니다.
󰊳장해분류표에 해당되지 않는 후유장해는 피보험자의 직업, 나이, 신분 또는 성별 
등에 관계없이 신체의 장해정도에 따라 장해 분류표의 구분에 준하여 지급액을 
결정합니다. 다만, 장해분류표의 각 장해분류별 최저 지급률 장해정도에 이르지 
않는 후유장해에 대하여는 후유장해보험금을 지급하지 않습니다.
󰊴보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따
를 수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문
의 중에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합
니다.
󰊵같은 이륜자동차 운전중 교통상해로 두 가지 이상의 후유장해가 생긴 경우에는 
후유장해지급률을 더하여 지급합니다. 다만, 장해분류표의 각 신체부위별 판정기
준에 별도로 정한 경우에는 그 기준에 따릅니다.
󰊶다른 이륜자동차 운전중 교통상해로 인하여 후유장해가 2회 이상 발생하였을 경
우에는 그 때마다 이에 해당하는 후유장해지급률을 결정합니다. 그러나 그 후유장
해가 이미 후유장해보험금을 지급받은 동일한 부위에 가중된 때에는 최종 장해상
태에 해당하는 후유장해보험금에서 이미 지급받은 후유장해보험금을 차감하여 지
급합니다. 다만, 장해 분류표의 각 신체부위별 판정기준에서 별도로 정한 경우에
는 그 기준에 따릅니다.
󰊷이미 이 계약에서 후유장해보험금 지급사유에 해당되지 않았거나(보장개시 이전의 
원인에 의하거나 또는 그 이전에 발생한 후유장해를 포함합니다), 후유장해보험금
이 지급되지 않았던 피보험자에게 그 신체의 동일 부위에 또다시 위 󰊶에 규정하
는 후유장해상태가 발생하였을 경우에는 직전까지의 후유장해에 대한 후유장해보
험금이 지급된 것으로 보고 최종 후유장해 상태에 해당되는 후유장해보험금에서 
이를 차감하여 지급합니다.
3. (보험금을 지급하지 않는 사유)
회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 발생
한 때에는 보험금을 지급하지 않습니다.
4. (특별약관의 소멸) 
󰊱회사가 1.(보험금의 지급사유)의 이륜자동차운전중교통상해80%이상후유장해보험
금을 지급한 경우에 그 손해보장의 원인이 생긴 때로부터 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 특별약관이 소멸되는 경우에는 회사는 해지환급금을 지급하지 않습
니다.
󰊳위 󰊱이외의 원인으로 특별약관이 소멸되는 경우 “보험료 및 책임준비금 산출방
법서”에서 정하는 바에 따라 회사가 그 때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (184, 4, 51, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
51
4
이륜자동차 운전중 교통상해입원일당
(1일이상180일한도)(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)의 직접결과로써 생활기능 또는 업무능력에 지장을 가져와 1일이상 계속 입원
하여 치료를 받은 경우에는 입원첫날부터 입원 1일당 이 특별약관의 보험가입금
액을 보험수익자에게 이륜자동차운전중교통상해입원일당(1일이상180일한도)으로 
지급합니다.
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
2. (보험금 지급에 관한 세부규정)
󰊱1.(보험금의 지급사유)의 이륜자동차운전중교통상해입원일당(1일이상180일한도) 
지급일수는 1회 입원당 180일을 한도로 합니다.
󰊲1.(보험금의 지급사유)의 경우 동일한 이륜자동차 운전중 교통상해의 치료를 목적
으로 2회 이상 입원한 경우(동일한 상해의 치료를 직접 목적으로 병원 또는 의원
을 이전하여 입원한 경우를 포함) 이를 1회 입원으로 보아 각 입원일수를 합산하
여 상기 󰊱을 적용합니다.
󰊳1.(보험금의 지급사유)의 경우 피보험자가 보장개시일(책임개시일) 이후 입원하여 
치료를 받던 중 보험기간이 만료되었을 때에도 보험기간 만료후 최초로 퇴원하기 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (185, 4, 52, '52
전까지의 계속 중인 입원기간에 대하여는 위 󰊲및 1.(보험금의 지급사유)에 따라 
이륜자동차운전중교통상해입원일당(1일이상180일한도)을 보장합니다.
󰊴피보험자가 정당한 이유 없이 입원기간 중 의사의 지시를 따르지 않은 때에는 회
사는 1.(보험금의 지급사유)의 이륜자동차운전중교통상해입원일당(1일이상180일
한도)의 전부 또는 일부를 지급하지 않습니다.
󰊵보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 
수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 
중에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
3. (보험금을 지급하지 않는 사유)
회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 발생
한 때에는 보험금을 지급하지 않습니다.
4. (“입원”의 정의와 장소)
이 특별약관에서 “입원”이라 함은 병원 또는 의원(한방병원 또는 한의원을 포함합니
다. 이하 같습니다.)등의 「의사, 치과의사 또는 한의사의 자격을 가진 자」(이하 “의사”
라 합니다)에 의하여 이륜자동차 운전중 교통상해의 치료가 필요하다고 인정한 경우
로서 자택 등에서의 치료가 곤란하여 의료법 제3조(의료기관) 제2항에 정한 병원, 의
원 또는 이와 동등하다고 회사가 인정하는 의료기관에 입실하여 의사의 관리 하에 치
료에 전념하는 것을 말합니다.
5. (특별약관의 소멸)
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
6. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
7. (준용규정) 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
5
이륜자동차 운전중 교통상해입원일당
(4일이상180일한도)(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)의 직접결과로써 생활기능 또는 업무능력에 지장을 가져와 4일이상 계속 입원
하여 치료를 받은 경우에는 4일째 입원일로부터 입원 1일당 이 특별약관의 보험
가입금액을 보험수익자에게 이륜자동차운전중교통상해입원일당(4일이상180일한
도)으로 지급합니다.
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (186, 4, 53, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
53
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
2. (보험금 지급에 관한 세부규정)
󰊱1.(보험금의 지급사유)의 이륜자동차운전중교통상해입원일당(4일이상180일한도) 
지급일수는 1회 입원당 180일을 한도로 합니다.
󰊲1.(보험금의 지급사유)의 경우 동일한 이륜자동차 운전중 교통상해의 치료를 목적
으로 2회 이상 입원한 경우(동일한 상해의 치료를 직접 목적으로 병원 또는 의원
을 이전하여 입원한 경우를 포함) 이를 1회 입원으로 보아 각 입원일수를 합산하
여 상기 󰊱을 적용합니다.
󰊳1.(보험금의 지급사유)의 경우 피보험자가 보장개시일(책임개시일) 이후 입원하여 
치료를 받던 중 보험기간이 만료되었을 때에도 보험기간 만료후 최초로 퇴원하기 
전까지의 계속 중인 입원기간에 대하여는 위 󰊲및 1.(보험금의 지급사유)에 따라 
이륜자동차운전중교통상해입원일당(4일이상180일한도)을 보장합니다.
󰊴피보험자가 정당한 이유 없이 입원기간 중 의사의 지시를 따르지 않은 때에는 회
사는 1.(보험금의 지급사유)의 이륜자동차운전중교통상해입원일당(4일이상180일
한도)의 전부 또는 일부를 지급하지 않습니다.
󰊵보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 
수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 
중에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
3. (보험금을 지급하지 않는 사유)
회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 발생
한 때에는 보험금을 지급하지 않습니다.
4. (“입원”의 정의와 장소)
이 특별약관에서 “입원”이라 함은 병원 또는 의원(한방병원 또는 한의원을 포함합니
다. 이하 같습니다.)등의 「의사, 치과의사 또는 한의사의 자격을 가진 자」(이하 “의사”
라 합니다)에 의하여 이륜자동차 운전중 교통상해의 치료가 필요하다고 인정한 경우
로서 자택 등에서의 치료가 곤란하여 의료법 제3조(의료기관) 제2항에 정한 병원, 의
원 또는 이와 동등하다고 회사가 인정하는 의료기관에 입실하여 의사의 관리 하에 치
료에 전념하는 것을 말합니다.
5. (특별약관의 소멸)
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
6. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (187, 4, 54, '54
신 특별약관]』에 따라 갱신됩니다.
7. (준용규정) 
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
6
이륜자동차 운전중 교통상해 골절진단비(치아제외)
(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)의 직접결과로써 자동차사고부상등급표(【별표3】자동차사고 부상등급표 참조)에
서 정한 골절이 발생하여 부상등급을 받은 경우 1사고당 이 특별약관의 보험가입
금액을 보험수익자에게 이륜자동차운전중교통상해골절진단비(치아제외)로 지급합
니다.
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
2. (보험금 지급에 관한 세부규정)
󰊱1.(보험금의 지급사유)의 이륜자동차운전중교통상해골절진단비는 동일한 상해를 
직접적인 원인으로 2가지 이상의 골절 상태가 발생한 경우에는 1회에 한하여 보
장합니다.
󰊲보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (188, 4, 55, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
55
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 
수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 
중에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
3. (보험금을 지급하지 않는 사유)
󰊱회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 
발생한 때에는 보험금을 지급하지 않습니다.
󰊲1.(보험금의 지급사유)에도 불구하고, 직․간접 원인을 묻지 않고 치아골절손해 또
는 치아골절손해가 원인이 되어 발생한 손해는 보장하지 않습니다. 다만, 동일한 
사고로 골절(치아제외)이 치아골절과 동시에 발생한 경우는 2.(보험금 지급에 관
한 세부규정)에 따라 보장합니다.
4. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
7
이륜자동차 운전중 교통상해 안면열상치료비(3cm이상)
(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)의 직접결과로써 자동차사고부상등급표(【별표3】자동차사고 부상등급표 참조)에
서 정한 안면열상(3cm 이상)이 발생하여 부상등급을 받은 경우 1사고당 이 특별
약관의 보험가입금액을 보험수익자에게 이륜자동차운전중교통상해안면열상치료비
(3cm이상)로 지급합니다.
󰊲위 󰊱에서 “안면열상(3cm 이상)”이라 함은 외부의 자극에 의하여 안면부의 피부
가 찢어져 입은 상처를 말합니다. 단, 상처의 길이가 3cm 미만인 경우는 제외합
니다.
󰊳위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊴위 󰊱및 󰊳에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (189, 4, 56, '56
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
2. (보험금 지급에 관한 세부규정)
󰊱1.(보험금의 지급사유)의 이륜자동차운전중교통상해안면열상치료비(3cm이상)는 동
일한 상해를 직접적인 원인으로 2가지 이상의 안면열상(3cm이상) 상태가 발생한 
경우에는 1회에 한하여 보장합니다.
󰊲1.(보험금의 지급사유) 󰊲에도 불구하고 동일한 상해를 직접적인 원인으로 2가지 
이상의 3cm미만 안면열상 상태가 발생한 경우 각각의 상처의 길이를 더하여 
3cm이상인 경우에는 1.(보험금의 지급사유)의 이륜자동차운전중교통상해안면열상
치료비(3cm이상)를 지급합니다.
󰊳1.(보험금의 지급사유)에서 정한 안면부란 이마 및 귀를 포함하여 목의 앞면까지
의 얼굴부분을 말합니다.
󰊴보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 
수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 중
에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
3. (보험금을 지급하지 않는 사유)
회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 발생
한 때에는 보험금을 지급하지 않습니다.
4. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
8
이륜자동차 운전중 교통상해 인대 및 힘줄(건)파열치료비
(비갱신형/갱신형) 특별약관
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (190, 4, 57, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
57
용어
정의
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)의 직접결과로써 자동차사고부상등급표(【별표3】자동차사고 부상등급표 참조)에
서 정한 인대 및 힘줄(건)의 파열이 발생하여 부상등급을 받은 경우 1사고당 이 
특별약관의 보험가입금액을 보험수익자에게 이륜자동차운전중교통상해인대및힘줄
(건)파열치료비로 지급합니다.
󰊲위 󰊱에서 “인대 및 힘줄(건)의 파열”이라 함은 외부의 자극에 의하여 “뼈와 뼈 
사이를 연결하는 섬유형 결합 조직(인대)” 또는 “근육을 뼈에 부착시키는 섬유성 
연부 조직(힘줄)”이 파열된 경우를 말합니다. 단, “근육”만 파열된 경우는 제외합
니다.
󰊳위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊴위 󰊱및 󰊳에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
2. (보험금 지급에 관한 세부규정)
󰊱1.(보험금의 지급사유)의 이륜자동차운전중교통상해인대및힘줄(건)파열치료비는 동
일한 상해를 직접적인 원인으로 2가지 이상의 인대 및 힘줄(건) 파열 상태가 발
생한 경우에는 1회에 한하여 보장합니다.
󰊲보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 
수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 
중에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
3. (보험금을 지급하지 않는 사유)
회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 발생
한 때에는 보험금을 지급하지 않습니다.
4. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (191, 4, 58, '58
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
9
이륜자동차 운전중 교통상해수술비
(동일사고당 1회지급)(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)의 직접결과로써 자동차사고부상등급표(【별표3】자동차사고 부상등급표 참조)에
서 정한 수술을 받은 경우에는 이 특별약관의 보험가입금액을 보험수익자에게 이
륜자동차운전중교통상해수술비로 지급합니다.
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
󰊴위 󰊱의 이륜자동차운전중교통상해수술비는 동일한 상해사고(이륜자동차 운전중 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (192, 4, 59, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
59
상해)를 직접적인 원인으로 두 종류 이상의 수술을 받거나 같은 종류의 수술을 2
회 이상 받은 경우에는 하나의 이륜자동차운전중교통상해수술비만 지급합니다.
2. (보험금 지급에 관한 세부규정)
보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하지 
못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 수 있
습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 중에 정하
며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
3. (보험금을 지급하지 않는 사유)
󰊱회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 
발생한 때에는 보험금을 지급하지 않습니다.
󰊲회사는 아래의 사유를 원인으로 보험금 지급사유가 발생한 때에는 보험금을 지급
하지 않습니다.
① 건강검진(단, 검사결과 이상 소견에 따라 건강검진센터 등에서 발생한 추가 의
료비용은 보상합니다), 예방접종, 인공유산에 든 비용
② 영양제, 비타민제, 호르몬 투여, 보신용 투약, 친자 확인을 위한 진단, 불임검
사, 불임수술, 불임복원술, 보조생식술(체내, 체외 인공수정을 포함합니다), 성
장촉진과 관련된 수술
③ 외모개선 목적의 치료를 위한 수술
가. 쌍꺼풀수술(이중검수술), 코성형수술(융비술), 유방확대(다만, 유방암 환자의 
유방재건술은 보상합니다)․축소술, 지방흡입술,  주름살제거술 등
나. 사시교정, 안와격리증(양쪽 눈을 감싸고 있는 뼈와 뼈 사이의 거리가 넓은 
증상)의 교정 등 시각계 수술로서 시력개선 목적이 아닌 외모개선 목적의 
수술
다. 안경, 콘택트렌즈 등을 대체하기 위한 시력교정술(국민건강보험 요양급여 대
상 수술방법 또는 치료재료가 사용되지 않은 부분은 시력교정술로 봅니다)
라. 외모개선 목적의 다리정맥류 수술
④ 위생관리, 미모를 위한 성형수술(다만, 사고전 상태로의 회복을 위한 수술은 
포함합니다)
⑤ 선천적 기형 및 이에 근거한 병상
4. ("수술"의 정의와 장소)
󰊱이 특별약관에서 “수술”이라 함은 「병원 또는 의원의 의사, 치과의사의 자격을 가
진 자」(이하 “의사”라 합니다)에 의하여 치료가 필요하다고 인정된 경우로서 자택 
등에서 치료가 곤란하여 의료기관에서 의사의 관리 하에 치료를 직접적인 목적으
로 의료기구를 사용하여 생체(生體)에 절단(切斷), 절제(切除) 등의 조작을 가하는 
것을 말합니다. 또한, 보건복지부 산하 신의료기술평가위원회【향후 제도변경시에
는 동 위원회와 동일한 기능을 수행하는 기관】로부터 안전성과 치료효과를 인정받
은 최신 수술기법도 포함됩니다. 단, 흡인(吸引), 천자(穿刺)등의 조치 및 신경(神
經)차단(NERVE BLOCK)은 제외합니다.
󰊲위 󰊱에서 의료기관이라 함은 의료법 제3조(의료기관) 제2항에 정한 국내의 병원 
또는 이와 동등하다고 회사가 인정하는 국외의 의료기관을 말합니다.
용어
풀이
절단 : 특정부위를 잘라내는 것
절제 : 특정부위를 잘라 없애는 것
흡인 : 주사기 등으로 빨아들이는 것
천자 : 바늘 또는 관을 꽂아 체액․조직을 뽑아내거나 약물을 주입하는 것
신의료기술평가위원회
의료법 제54조(신의료기술평가위원회의 설치 등)에 의거 설치된 위원회로서 
신의료기술에 관한 최고의 심의기구를 말합니다.
5. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
6. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (193, 4, 60, '60
7. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
10
이륜자동차 운전중 중대한 교통상해수술비(1~3급)
(동일사고당 1회지급)(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)의 직접결과로써 자동차사고부상등급표(【별표3】자동차사고 부상등급표 참조)에
서 정한 1~3급에 해당하는 수술을 받은 경우에는 이 특별약관의 보험가입금액을 
보험수익자에게이륜자동차운전중중대한교통상해수술비(1~3급)로 지급합니다.
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
󰊴위 󰊱의 이륜자동차운전중중대한교통상해수술비(1~3급)는 동일한 상해사고(이륜
자동차 운전중 상해)를 직접적인 원인으로 두 종류 이상의 수술을 받거나 같은 
종류의 수술을 2회 이상 받은 경우에는 하나의 이륜자동차운전중중대한교통상해
수술비(1~3급)만 지급합니다.
2. (보험금 지급에 관한 세부규정)
보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하지 
못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 수 있
습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 중에 정하
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (194, 4, 61, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
61
며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
3. (보험금을 지급하지 않는 사유)
󰊱회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 
발생한 때에는 보험금을 지급하지 않습니다.
󰊲회사는 아래의 사유를 원인으로 보험금 지급사유가 발생한 때에는 보험금을 지급
하지 않습니다.
① 건강검진(단, 검사결과 이상 소견에 따라 건강검진센터 등에서 발생한 추가 의
료비용은 보상합니다), 예방접종, 인공유산에 든 비용
② 영양제, 비타민제, 호르몬 투여, 보신용 투약, 친자 확인을 위한 진단, 불임검
사, 불임수술, 불임복원술, 보조생식술(체내, 체외 인공수정을 포함합니다), 성
장촉진과 관련된 수술
③ 외모개선 목적의 치료를 위한 수술
가. 쌍꺼풀수술(이중검수술), 코성형수술(융비술), 유방확대(다만, 유방암 환자의 
유방재건술은 보상합니다)․축소술, 지방흡입술,  주름살제거술 등
나. 사시교정, 안와격리증(양쪽 눈을 감싸고 있는 뼈와 뼈 사이의 거리가 넓은 
증상)의 교정 등 시각계 수술로서 시력개선 목적이 아닌 외모개선 목적의 
수술
다. 안경, 콘택트렌즈 등을 대체하기 위한 시력교정술(국민건강보험 요양급여 대
상 수술방법 또는 치료재료가 사용되지 않은 부분은 시력교정술로 봅니다)
라. 외모개선 목적의 다리정맥류 수술
④ 위생관리, 미모를 위한 성형수술(다만, 사고전 상태로의 회복을 위한 수술은 
포함합니다)
⑤ 선천적 기형 및 이에 근거한 병상
4. ("수술"의 정의와 장소)
󰊱이 특별약관에서 “수술”이라 함은 「병원 또는 의원의 의사, 치과의사의 자격을 가
진 자」(이하 “의사”라 합니다)에 의하여 치료가 필요하다고 인정된 경우로서 자택 
등에서 치료가 곤란하여 의료기관에서 의사의 관리 하에 치료를 직접적인 목적으
로 의료기구를 사용하여 생체(生體)에 절단(切斷), 절제(切除) 등의 조작을 가하는 
것을 말합니다. 또한, 보건복지부 산하 신의료기술평가위원회【향후 제도변경시에
는 동 위원회와 동일한 기능을 수행하는 기관】로부터 안전성과 치료효과를 인정받
은 최신 수술기법도 포함됩니다. 단, 흡인(吸引), 천자(穿刺)등의 조치 및 신경(神
經)차단(NERVE BLOCK)은 제외합니다.
󰊲위 󰊱에서 의료기관이라 함은 의료법 제3조(의료기관) 제2항에 정한 국내의 병원 
또는 이와 동등하다고 회사가 인정하는 국외의 의료기관을 말합니다.
용어
풀이
절단 : 특정부위를 잘라내는 것
절제 : 특정부위를 잘라 없애는 것
흡인 : 주사기 등으로 빨아들이는 것
천자 : 바늘 또는 관을 꽂아 체액․조직을 뽑아내거나 약물을 주입하는 것
신의료기술평가위원회
의료법 제54조(신의료기술평가위원회의 설치 등)에 의거 설치된 위원회로서 
신의료기술에 관한 최고의 심의기구를 말합니다.
5. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
6. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
7. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (195, 4, 62, '62
11
이륜자동차 운전중 자동차부상치료비(1~10급)
(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 발생한 이
륜자동차 운전중 교통상해(보험기간 중에 이륜자동차를 운전하던 중 발생한 급격
하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 신체에 입은 상해를 말합니
다)의 직접결과로써 자동차손해배상보장법 시행령에서 정한 자동차사고부상등급표
(【별표3】자동차사고 부상등급표 참조)의 부상등급을 받은 경우 부상등급에 따라 
아래와 같이 보험수익자에게 지급합니다.
부상등급
지급금액
예시
[보험가입금액 150만원 기준]
1급
보험가입금액 지급
150만원
2~4급
보험가입금액의 1/2 지급
75만원
5급
보험가입금액의 1/4 지급
37만 5천원
6급
보험가입금액의 2/15 지급
20만원
7급
보험가입금액의 1/15 지급
10만원
8-10급
보험가입금액의 1/30 지급
5만원
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
2. (보험금 지급에 관한 세부규정)
보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하지 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (196, 4, 63, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
63
못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 수 있
습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 중에 정하
며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
3. (보험금을 지급하지 않는 사유)
회사는 보통약관 5.(보험금을 지급하지 않는 사유)에 의하여 보험금 지급사유가 발생
한 때에는 보험금을 지급하지 않습니다.
4. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (197, 4, 64, '') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (198, 4, 65, '특
별
약
관
상
해
비
용
손
해
특별약관
제2장 비용손해
관련
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (199, 4, 66, '66
어려운 용어는 프로미라이프 용어사전 참고 ……………………………………   21
인용 법규는   약관에서 인용한 법규  참고 ……………………………………  123 
1
이륜자동차 운전중 교통사고처리지원금(실손, 동승자제외)
(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 「이륜자동
차를 운전하던 중 급격하고도 우연히 발생한 자동차 사고」(이하 “사고”라 합니다)
로 「타인(피보험자의 부모, 배우자, 자녀 및 피보험자(보험대상자)가 운전하던 이
륜자동차의 동승자는 제외합니다))」(이하 “피해자”라 합니다)에게 다음 각 호에 해
당하는 상해를 입힌 경우 매 사고마다 피해자 각각에 대하여 「피보험자가 형사합
의금으로 지급한 금액」(이하 “형사합의금”이라 합니다)을 이륜자동차운전중교통사
고처리지원금으로 피보험자에게 지급합니다.
① 피해자를 사망하게 한 경우
② “중대법규위반 교통사고”로 피해자가 42일(피해자 1명을 기준으로 합니다) 이
상 치료를 요한다는 진단을 받은 경우
③ “일반교통사고”로 피해자에게 중상해를 입혀 형법 제258조 제1항 또는 제2항, 
형법 제268조, 교통사고처리특례법 제3조에 따라 검찰에 의해 「공소제기」(이
하 “기소”라 합니다.)되거나 자동차손해배상보장법 시행령 제3조에서 정한 부
상등급 1급, 2급 또는 3급에 해당하는 부상(【별표3】자동차사고 부상등급표 참
조)을 입힌 경우
용어
풀이
「중상해」라 함은 사람의 신체를 상해하여 생명에 대한 위험을 발생하게 한 
경우, 신체의 상해로 인하여 불구 또는 불치나 난치의 질병에 이르게 한 경
우를 말합니다.
인용
문구
형법 제258조(중상해, 존속중상해) 제1항 및 제2항
타인의 신체를 상해하여 생명에 위험을 발생하게 하거나 신체 불구, 불치, 
난치의 질병을 이르게 한 자는 1년 이상 10년 이하 징역에 처한다.
형법 제268조(업무상과실ㆍ중과실 치사상)
업무상 과실 또는 중대한 과실로 인하여 사람을 사상에 이르게 한 자는 5년 
이하의 금고 또는 2천만원 이하의 벌금에 처한다.
교통사고처리특례법 제3조 제2항 단서(제1호 내지 제11호)
 1. 신호 및 지시위반
 2. 중앙선 침범 또는 불법 횡단ㆍ유턴ㆍ후진 위반
 3. 제한속도를 20킬로미터 초과한 속도 위반
 4. 앞지르기 금지 또는 끼어들기 금지 위반
 5. 건널목 통과방법 위반
 6. 횡단보도에서의 보행자 보호의무 위반
 7. 무면허 운전
 8. 음주 운전 또는 약물 복용 운전
 9. 보도침범 또는 보도횡단방법 위반
10. 승객 추락방지의무 위반
11. 어린이보호구역(스쿨존)에서의 주의의무 위반
󰊲위 󰊱에서 『이륜자동차를 운전하던 중』 이라 함은 도로여부, 주정차여부, 엔진의 
시동여부를 불문하고 피보험자가 이륜자동차 운전석에 탑승하여 핸들을 조작하거
나 조작 가능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 『이륜자동차』라 함은 자동차관리법 제3조(자동차의 종류)에서 정
한 이륜자동차 중 자동차관리법 제48조(이륜자동차의 사용 신고 등) 및 자동차관
리법 시행규칙 제98조의2(사용신고대상 이륜자동차)에서 정한 신고대상 이륜자동
차를 말합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (200, 4, 67, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
67
인용
문구
자동차관리법 제3조(자동차의 종류)
5. 이륜자동차: 총배기량 또는 정격출력의 크기와 관계없이 1인 또는 2인의 
사람을 운송하기에 적합하게 제작된 이륜의 자동차 및 그와 유사한 구조
로 되어 있는 자동차
자동차관리법 제48조(이륜자동차의 사용 신고 등)
  ① 국토교통부령으로 정하는 이륜자동차(이하 "이륜자동차"라 한다)를 취 득
하여 사용하려는 자는 국토교통부령으로 정하는 바에 따라 시장ㆍ군수ㆍ
구청장에게 사용 신고를 하고 이륜자동차 번호의 지정을 받아야 한다.
자동차관리법 시행규칙 제98조의2(사용신고 대상 이륜자동차)
법 제48조제1항에서 "국토교통부령으로 정하는 이륜자동차"란 최고속도가 
매시 25킬로미터 이상인 이륜자동차를 말한다. 다만, 다음 각 호의 어느 하
나에 해당하는 이륜자동차로서 국토교통부장관이 정하여 고시하는 이륜자동
차는 제외한다.
1. 산악지형이나 비포장도로에서 주로 사용할 목적으로 제작된 이륜자동차 
중 차동장치가 없는 이륜자동차
2. 그 밖에 주된 용도가 도로 운행 목적이 아닌 것으로서 조향장치 및 제동
장치 등을 손으로 조작할 수 없거나 자동차의 주요한 구조적 장치의 설
치 또는 장착 등이 현저히 곤란한 이륜자동차포함
2. (보험금 지급에 관한 세부 규정)
󰊱1.(보험금의 지급사유) 󰊱의 이륜자동차운전중교통사고처리지원금은 피해자 1인당 
아래의 금액을 한도로 합니다.
① 1.(보험금의 지급사유) 󰊱.①의 경우 : 3천만원
② 1.(보험금의 지급사유) 󰊱.②의 경우
42일~69일 진단시
70일~139일 진단시
140일이상 진단시
1천만원
2천만원
3천만원
③ 1.(보험금의 지급사유) 󰊱.③의 경우 : 3천만원
󰊲1.(보험금의 지급사유) 󰊱에서 “중대법규위반 교통사고”라 함은 교통사고처리특례
법 제3조 제2항 단서(【별표4】교통사고처리특례법 제3조 제2항 단서 참조)에 해당
되는 사고를 말합니다. 단, 단서 중 7, 8은 중대법규위반 교통사고로 보지 않습니
다.
󰊳1.(보험금의 지급사유) 󰊱에서 “일반교통사고”라 함은 이륜자동차를 운전하던 중 
급격하고도 우연히 발생한 자동차 사고 중에서 중대법규위반 교통사고에 해당되
지 아니하는 사고를 말합니다. 단, 교통사고처리특례법 제3조 제2항 단서 중 7, 
8은 일반교통사고로 보지 않습니다.
󰊴피해자에 의해 형사합의가 이루어지지 않아 공탁을 한 경우에는 피해자의 공탁금 
출급 이후 공탁금액을 위 󰊱의 금액을 한도로 보상합니다.
󰊵다음 ① 및 ②에 모두 해당하는 경우 회사는 1.(보험금의 지급사유) 󰊱에서 정한 
형사합의금을 피해자에게 직접 지급할 수 있습니다.
① 피보험자와 피해자간 형사합의금액을 확정하고, 피해자가 형사합의금액을 별도
   로 장래에 지급받는 조건으로 형사합의를 한 경우
② 보험회사가 피해자에게 형사합의금을 직접 지급하는 경우 피보험자가 이 특별
약관에 따라 피해자에게 직접 지급되는 보험금(형사합의금)에 상응하는 청구권
을 포기한 경우
󰊶1.(보험금의 지급사유) 󰊱에 따라 보험금을 청구하고자하는 피보험자는 다음의 서
류를 제출하고 보험금을 청구해야 합니다.
① 경찰서에서 발행한 교통사고사실 확인원
② 경찰서 혹은 검찰청에 제출된 자동차 교통사고 형사합의서(단, 합의금액이 명
시되어 있어야 합니다.)
③ 검찰에 의해 기소된 경우 검찰청에서 발행한 공소장
④ 법원 혹은 검찰청에 제출된 공탁서 및 피해자의 공탁금 출급 확인서 
⑤ 기타 보험회사가 필요하다고 인정하는 서류
󰊷위 󰊵에 따라 보험회사가 형사합의금을 피해자에게 직접 지급할 경우 피보험자는 
다음의 서류를 제출하여야 합니다.
① 경찰서 혹은 검찰청에 제출된 자동차 교통사고 형사합의서(단, 합의금액이 명
시되어 있어야 하며, 합의금액을 장래에 지급한다는 내용이 포함되어 있어야 
합니다.)
② 보험금(형사합의금) 수령에 관한 위임장 및 확인서(보험회사 양식)
③ 경찰서에서 발행한 교통사고사실 확인원 또는 검찰에 의해 기소된 경우 검찰
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (201, 4, 68, '68
용어
풀이
이륜자동차 운행목적
1. 유상운송 배달용 : 피보험자가 수당, 요금 등 대가의 보상을 직접적인 목
적으로 물건 등의 배달을 위해서 이륜자동차를 운전하는 경우를 말합니다.
   (예) 매 배달시마다 요금이나 대가를 수령하는 퀵서비스, 이륜자동차를 
이용한 택배 등
2. 비유상운송 배달용 : 피보험자가 「유상운송 배달용」 이외의 목적으로 물
건 등의 배달을 위해서 이륜자동차를 운전하는 경우를 말합니다.
   (예) 매 배달시 요금이나 대가를 수령하지 않는 피자, 치킨 등 음식 배달 
및 우편배달 등
3. 가정용 및 기타용도 : 상기 「유상운송 배달용」 및 「비유상운송 배달용」 이
외의 목적으로 이륜자동차를 운전하는 경우를 말합니다.
   (예) 출퇴근용도, 보안경비용 등
청에서 발행한 공소장
④ 진단서, 소견서 등 피해자의 부상정도를 확인할 수 있는 서류 
⑤ 기타 보험회사가 필요하다고 인정하는 서류
3. (보험금을 지급하지 않는 사유)
󰊱회사는 아래의 사유를 원인으로 하여 생긴 보험금 지급사유에 대해서는 보장하지 
않습니다.
① 피보험자의 고의
② 계약자의 고의
③ 피보험자가 사고를 내고 도주하였을 때
④ 피보험자가 이륜자동차를 경기용이나 경기를 위한 연습용 또는 시험용으로 운
전하던 중 사고를 일으킨 때
⑤ 피보험자가 도로교통법 제43조, 제44조에 정한 음주․무면허 상태에서 운전하
던 중 사고를 일으킨 때
⑥ 「가정용 및 기타용도」의 경우 피보험자가 이륜자동차를 「비유상운송 배달용」 
또는 「유상운송 배달용」 목적으로 운전하던 중 발생한 사고
인용
문구
도로교통법 제43조(무면허운전 등의 금지)
운전면허를 받지 아니하거나 운전면허의 효력이 정지된 경우에는 자동차등을 
운전하여서는 아니 된다.
도로교통법 제44조(술에 취한 상태에서의 운전 금지)
술에 취한 상태에서 운전하여서는 아니되며, 운전이 금지되는 술에 취한 상
태의 기준은 운전자의 혈중알코올농도가 0.05퍼센트 이상인 경우로 한다.
4. (보험금의 비례분담)
󰊱1.(보험금의 지급사유) 󰊱의 형사합의금에 대하여 이륜자동차운전중교통사고처리
지원금을 지급할 다수 계약(각종 공제계약을 포함합니다)이 체결되어 있는 경우 
형사합의금 및 각 계약의 보상책임액에 따라 󰊲에 의해 계산된 각 계약의 비례분
담액을 보상책임액으로 지급합니다.
󰊲다수 계약이 체결되어 있는 경우 각각의 계약에 대하여 다른 계약이 없는 것으로 
하여 산출한 보상책임액의 합계액이 형사합의금을 초과하는 때에는 회사는 각 계
약의 보상책임액을 비례분담하여 지급하며, 비례분담액 산출방식은 다음과 같습니
다. 
산식
각 계약별 비례분담액  = 형사합의금×
각 계약별 보상책임액
각 계약별 보상책임액의 합계액
5. (특별약관의 소멸)
󰊱보험증권에 기재된 피보험자가 보험기간 중에 사망할 경우에 이 특별약관은 소멸
됩니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
6. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (202, 4, 69, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
69
인용
문구
자동차손해배상보장법 시행령 제2조(건설기계의 범위)
1. 덤프트럭
2. 타이어식 기중기
3. 콘크리트믹서트럭
4. 트럭적재식 콘크리트펌프
5. 트럭적재식 아스팔트살포기
6. 타이어식 굴삭기
7. 「건설기계관리법 시행령」 별표 1 제26호에 따른 특수건설기계 중 다음 
각 목의 특수건설기계
   가. 트럭지게차
   나. 도로보수트럭
   다. 노면측정장비(노면측정장치를 가진 자주식인 것을 말한다)
※ 관련 법규가 변경되어 새로운 항목이 추가되는 경우에는 그 항목도 포함
신 특별약관]』에 따라 갱신됩니다.
7. (준용규정)
이 특별약관에 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 보
통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인출
금은 지급하지 않습니다.
2
벌금(실손)(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 「자동차를 
운전하던 중 발생한 급격하고도 우연한 자동차 사고」(이하 “사고”라 합니다)로 타
인의 신체에 상해를 입힘으로써 신체상해와 관련하여 받은 벌금액을 1사고당 이 
특별약관의 보험가입금액을 한도로 지급합니다.
보험
지식
벌금액
확정판결에 의하여 정해진 벌금액을 말하며, 보험기간 중에 발생한 사고의 
벌금 확정판결이 보험기간 종료 후에 이루어진 경우를 포함합니다.
󰊲위 󰊱에서 자동차를 운전하던 중이라 함은 도로여부, 주정차여부, 엔진의 시동여
부를 불문하고 피보험자가 자동차 운전석에 탑승하여 핸들을 조작하거나 조작 가
능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 자동차라 함은 자동차관리법 시행규칙 제2조에 정한 승용자동
차, 승합자동차, 화물자동차, 특수자동차, 이륜자동차 및 「자동차손해배상보장법 
시행령 제2조(건설기계의 범위)에서 정한 건설기계」를 말합니다. 다만, 「자동차손
해배상보장법 시행령 제2조(건설기계의 범위)에서 정한 건설기계」가 작업기계로 
사용되는 동안은 자동차로 보지 않습니다. 
2. (보험금 지급에 관한 세부 규정) 
위 1.(보험금의 지급사유) 󰊱의 벌금에 대하여 보험금을 지급할 다른 계약(공제를 포
함합니다)이 체결되어 있는 경우에는 각각의 계약에 대하여 다른 계약이 없는 것으로 
하여 산출한 보상책임액의 합계액이 피보험자가 부담하는 금액을 초과했을 때 회사는 
이 계약에 따른 보상책임액의 위의 합계액에 대한 비율에 따라 보험금을 지급합니다.
3. (보험금을 지급하지 않는 사유) 
󰊱회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자의 고의. 다만, 피보험자가 심신상실 등으로 자유로운 의사결정을 할 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (203, 4, 70, '70
수 없는 상태에서 자신을 해친 경우에는 보험금을 지급합니다.
② 보험수익자의 고의. 다만, 그 보험수익자가 보험금의 일부 보험수익자인 경우
에는 다른 보험수익자에 대한 보험금은 지급합니다.
③ 계약자의 고의
④ 피보험자의 임신, 출산(제왕절개를 포함합니다), 산후기. 그러나 회사가 보장하
는 보험금 지급사유로 인한 경우에는 보험금을 지급합니다.
⑤ 전쟁, 외국의 무력행사, 혁명, 내란, 사변, 폭동
󰊲회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자가 도로교통법 제43조, 제44조에 정한 음주․무면허 상태에서 운전하
던 중 발생한 사고
② 피보험자가 사고를 일으키고 도주하였을 때
③ 피보험자가 자동차를 경기용이나 경기를 위한 연습용 또는 시험용으로 운전하
던 중 사고를 일으킨 때
인용
문구
도로교통법 제43조(무면허운전 등의 금지)
운전면허를 받지 아니하거나 운전면허의 효력이 정지된 경우에는 자동차등을 
운전하여서는 아니 된다.
도로교통법 제44조(술에 취한 상태에서의 운전 금지)
술에 취한 상태에서 운전하여서는 아니되며, 운전이 금지되는 술에 취한 상
태의 기준은 운전자의 혈중알코올농도가 0.05퍼센트 이상인 경우로 한다.
4. (특별약관의 소멸)
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
3
자동차사고 변호사선임비용(실손)(비갱신형/갱신형) 
특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」중에 자동차를 운
전하던 중 발생한 급격하고도 우연한 자동차 사고(이하 “사고”라 합니다)로 타인
의 신체에 상해를 입혀 아래에서 정한 사유로 변호사선임비용을 부담함으로써 입
은 손해(이하 “변호사선임비용”이라 합니다.)를 1사고마다 이 특별약관의 가입금액
을 한도로 피보험자에게 지급합니다. 다만, 검사에 의해 약식기소 되었으나 피보
험자가 법원의 약식명령에 불복하여 정식재판을 청구한 경우에는 변호사선임비용
을 지급하지 않습니다.
① 피보험자가 구속영장에 의하여 구속된 경우
② 검찰에 의해 공소제기(이하 “기소”라 하며, 약식기소는 제외합니다)된 경우
③ 피보험자가 검사에 의해 약식기소 되었으나 법원에 의해 보통의 심판절차인 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (204, 4, 71, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
71
공판절차에 의해 재판이 진행하게 된 경우
󰊲위 󰊱의 약식기소라 함은 검사가 지방법원의 관할사건에 대하여 보통의 심판절차
인 공판절차를 거치지 않고 피고인에게 벌금, 구류 또는 몰수의 형을 과하는 것이 
타당하다고 판단하여 약식명령 공소장에 의하여 기소하는 것을 말합니다.
󰊳위 󰊱의 『자동차』라 함은 자동차관리법 시행규칙 제2조에 정한 승용자동차, 승합
자동차, 화물자동차, 특수자동차, 이륜자동차 및 「자동차손해배상보장법 시행령 제
2조(건설기계의 범위)에서 정한 건설기계」를 말합니다. 다만, 「자동차손해배상보장
법 시행령 제2조(건설기계의 범위)에서 정한 건설기계」가 작업기계로 사용되는 동
안은 자동차로 보지 않습니다. 
인용
문구
자동차손해배상보장법 시행령 제2조(건설기계의 범위)
1. 덤프트럭
2. 타이어식 기중기
3. 콘크리트믹서트럭
4. 트럭적재식 콘크리트펌프
5. 트럭적재식 아스팔트살포기
6. 타이어식 굴삭기
7. 「건설기계관리법 시행령」 별표 1 제26호에 따른 특수건설기계 중 다음 
각 목의 특수건설기계
   가. 트럭지게차
   나. 도로보수트럭
   다. 노면측정장비(노면측정장치를 가진 자주식인 것을 말한다)
※ 관련 법규가 변경되어 새로운 항목이 추가되는 경우에는 그 항목도 포함
󰊴 위 󰊱의 『자동차를 운전하던 중』 이라 함은 도로여부, 주정차 여부, 엔진의 시동
여부를 불문하고 피보험자가 자동차 운전석에 탑승하여 핸들을 조작하거나 조작 
가능한 상태에 있는 것을 말합니다.
󰊵 위 󰊱의 『1사고』 라 함은 하나의 자동차 운전 중 교통사고를 말하며, 『1사고』로 
항소심, 상고심 포함하여 다수의 소송을 하였을 경우 그 소송동안 피보험자가 부
담한 전체 변호사선임비용을 합쳐서 보험가입금액을 한도로 피보험자에게 지급합
니다.
󰊶 위 󰊱에서 정한 변호사선임비용에 대하여 보험금을 지급할 다른 계약(공제계약을 
포함)이 체결되어 있고 각각의 계약에 대하여 다른 계약(공제계약을 포함)이 없는 
것으로 하여 산출한 보상책임액의 합계액이 피보험자가 부담하는 금액을 초과했
을 때 회사는 이 계약에 따른 보상책임액의 상기 합계액에 대한 비율에 따라 보
험금을 지급합니다.
2. (보험금을 지급하지 않는 사유)
󰊱회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자의 고의. 다만, 피보험자가 심신상실 등으로 자유로운 의사결정을 할 
수 없는 상태에서 자신을 해친 경우에는 보험금을 지급합니다.
② 보험수익자의 고의. 다만, 그 보험수익자가 보험금의 일부 보험수익자인 경우
에는 다른 보험수익자에 대한 보험금은 지급합니다.
③ 계약자의 고의
④ 피보험자의 임신, 출산(제왕절개를 포함합니다), 산후기. 그러나 회사가 보장하
는 보험금 지급사유로 인한 경우에는 보험금을 지급합니다.
⑤ 전쟁, 외국의 무력행사, 혁명, 내란, 사변, 폭동
󰊲회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자가 도로교통법 제43조, 제44조에 정한 음주․무면허 상태에서 운전하
던 중 발생한 사고
② 피보험자가 사고를 일으키고 도주하였을 때
③ 피보험자가 자동차를 경기용이나 경기를 위한 연습용 또는 시험용으로 운전하
던 중 사고를 일으킨 때
인용
문구
도로교통법 제43조(무면허운전 등의 금지)
운전면허를 받지 아니하거나 운전면허의 효력이 정지된 경우에는 자동차등을 
운전하여서는 아니 된다.
도로교통법 제44조(술에 취한 상태에서의 운전 금지)
술에 취한 상태에서 운전하여서는 아니되며, 운전이 금지되는 술에 취한 상
태의 기준은 운전자의 혈중알코올농도가 0.05퍼센트 이상인 경우로 한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (205, 4, 72, '72
인용
문구
자동차손해배상보장법 시행령 제2조(건설기계의 범위)
1. 덤프트럭
2. 타이어식 기중기
3. (보험금의 청구)
󰊱피보험자 또는 보험수익자는 보험금을 청구할 때에는 다음 서류를 첨부하여 회사
에 제출하여야 합니다.
① 보험금 청구서(회사양식)
② 사고증명서(소장, 선임한 변호사가 발행한 세금계산서)
③ 신분증(주민등록증 이나 운전면허증 등 사진이 붙은 정부기관 발행 신분증, 본
인이 아니면 본인의 인감증명서 포함)
④ 기타 보험수익자가 보험금의 수령에 필요하여 제출하는 서류
4. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않으며, 보통약관 4.(보험금 지급에 관한 세부규정)은 적용하지 않습
니다.
4
면허취소보험금(영업용)(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유) 
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 「자동차를 
운전하던 중 발생한 급격하고도 우연한 자동차 사고」(이하 “사고”라 합니다)로 타
인의 신체에 상해를 입히거나 재물을 손상함으로써 피보험자의 자동차 운전면허
가 행정처분에 의해 취소되었을 때에는 이 특별약관의 보험가입금액을 면허취소
보험금으로 1사고마다 지급합니다.
󰊲위 󰊱에서 자동차를 운전하던 중이라 함은 도로여부, 주정차여부, 엔진의 시동여
부를 불문하고 피보험자가 자동차 운전석에 탑승하여 핸들을 조작하거나 조작 가
능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 자동차라 함은 자동차관리법 시행규칙 제2조에 정한 승용자동
차, 승합자동차, 화물자동차, 특수자동차, 이륜자동차 및 「자동차손해배상보장법 
시행령 제2조(건설기계의 범위)에서 정한 건설기계」를 말합니다. 다만, 「자동차손
해배상보장법 시행령 제2조(건설기계의 범위)에서 정한 건설기계」가 작업기계로 
사용되는 동안은 자동차로 보지 않습니다. 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (206, 4, 73, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
73
3. 콘크리트믹서트럭
4. 트럭적재식 콘크리트펌프
5. 트럭적재식 아스팔트살포기
6. 타이어식 굴삭기
7. 「건설기계관리법 시행령」 별표 1 제26호에 따른 특수건설기계 중 다음 
각 목의 특수건설기계
   가. 트럭지게차
   나. 도로보수트럭
   다. 노면측정장비(노면측정장치를 가진 자주식인 것을 말한다)
※ 관련 법규가 변경되어 새로운 항목이 추가되는 경우에는 그 항목도 포함
2. (보험금을 지급하지 않는 사유) 
󰊱회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자의 고의. 다만, 피보험자가 심신상실 등으로 자유로운 의사결정을 할 
수 없는 상태에서 자신을 해친 경우에는 보험금을 지급합니다.
② 보험수익자의 고의. 다만, 그 보험수익자가 보험금의 일부 보험수익자인 경우
에는 다른 보험수익자에 대한 보험금은 지급합니다.
③ 계약자의 고의
④ 피보험자의 임신, 출산(제왕절개를 포함합니다), 산후기. 그러나 회사가 보장하
는 보험금 지급사유로 인한 경우에는 보험금을 지급합니다.
⑤ 전쟁, 외국의 무력행사, 혁명, 내란, 사변, 폭동
󰊲회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자가 도로교통법 제43조, 제44조에 정한 음주․무면허 상태에서 운전하
던 중 발생한 사고
② 피보험자가 사고를 일으키고 도주하였을 때
③ 피보험자가 자동차를 경기용이나 경기를 위한 연습용 또는 시험용으로 운전하
던 중 사고를 일으킨 때
인용
문구
도로교통법 제43조(무면허운전 등의 금지)
운전면허를 받지 아니하거나 운전면허의 효력이 정지된 경우에는 자동차등을 
운전하여서는 아니 된다.
도로교통법 제44조(술에 취한 상태에서의 운전 금지)
술에 취한 상태에서 운전하여서는 아니되며, 운전이 금지되는 술에 취한 상
태의 기준은 운전자의 혈중알코올농도가 0.05퍼센트 이상인 경우로 한다.
3. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
4. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
5. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않으며, 보통약관 4.(보험금 지급에 관한 세부규정)은 적용하지 않습
니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (207, 4, 74, '74
5
면허정지일당(영업용)(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유) 
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중에 「자동차를 
운전하던 중 발생한 급격하고도 우연한 자동차 사고」(이하 “사고”라 합니다)로 타
인의 신체에 상해를 입히거나 재물을 손상함으로써 피보험자의 자동차 운전면허
가 행정 처분에 의해 일시 정지되었을 때에는 이 특별약관에서 정한 일당액을 면
허정지일당으로 1사고마다 지급합니다. 다만, 면허정지일당은 면허정지기간 동안 
최고 60일을 한도로 지급하며, 면허정지 행정처분 사유가 교통사고가 아닌 경우
에는 면허정지일당을 지급하지 않습니다.
󰊲위 󰊱에서 자동차를 운전하던 중이라 함은 도로여부, 주정차여부, 엔진의 시동여
부를 불문하고 피보험자가 자동차 운전석에 탑승하여 핸들을 조작하거나 조작 가
능한 상태에 있는 것을 말합니다.
󰊳위 󰊱및 󰊲에서 자동차라함은 자동차관리법 시행규칙 제2조에 정한 승용자동차, 
승합자동차, 화물자동차, 특수자동차, 이륜자동차 및 「자동차손해배상보장법 시행
령 제2조(건설기계의 범위)에서 정한 건설기계」를 말합니다. 다만, 「자동차손해배
상보장법 시행령 제2조(건설기계의 범위)에서 정한 건설기계」가 작업기계로 사용
되는 동안은 자동차로 보지 않습니다. 
인용
문구
자동차손해배상보장법 시행령 제2조(건설기계의 범위)
1. 덤프트럭
2. 타이어식 기중기
3. 콘크리트믹서트럭
4. 트럭적재식 콘크리트펌프
5. 트럭적재식 아스팔트살포기
6. 타이어식 굴삭기
7. 「건설기계관리법 시행령」 별표 1 제26호에 따른 특수건설기계 중 다음 
각 목의 특수건설기계
   가. 트럭지게차
   나. 도로보수트럭
   다. 노면측정장비(노면측정장치를 가진 자주식인 것을 말한다)
※ 관련 법규가 변경되어 새로운 항목이 추가되는 경우에는 그 항목도 포함
󰊴위 󰊱에서 면허정지기간이라 함은 행정기관의 교정교육을 이수하여 면허정지기간
을 감경받았거나 감경받을 수 있는 경우를 차감한 기간을 말합니다. 단, 행정기관
의 교정교육을 이수하지 않아 면허정지기간을 감경받지 못하여 면허정지 처분기
간 이후에 경찰서의 행정처분조회 확인서를 제출할 경우에는 그러하지 않습니다.
2. (보험금을 지급하지 않는 사유) 
󰊱회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자의 고의. 다만, 피보험자가 심신상실 등으로 자유로운 의사결정을 할 
수 없는 상태에서 자신을 해친 경우에는 보험금을 지급합니다.
② 보험수익자의 고의. 다만, 그 보험수익자가 보험금의 일부 보험수익자인 경우
에는 다른 보험수익자에 대한 보험금은 지급합니다.
③ 계약자의 고의
④ 피보험자의 임신, 출산(제왕절개를 포함합니다), 산후기. 그러나 회사가 보장하
는 보험금 지급사유로 인한 경우에는 보험금을 지급합니다.
⑤ 전쟁, 외국의 무력행사, 혁명, 내란, 사변, 폭동
󰊲회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (208, 4, 75, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
75
① 피보험자가 도로교통법 제43조, 제44조에 정한 음주․무면허 상태에서 운전하
던 중 발생한 사고
② 피보험자가 사고를 일으키고 도주하였을 때
③ 피보험자가 자동차를 경기용이나 경기를 위한 연습용 또는 시험용으로 운전하
던 중 사고를 일으킨 때
인용
문구
도로교통법 제43조(무면허운전 등의 금지)
운전면허를 받지 아니하거나 운전면허의 효력이 정지된 경우에는 자동차등을 
운전하여서는 아니 된다.
도로교통법 제44조(술에 취한 상태에서의 운전 금지)
술에 취한 상태에서 운전하여서는 아니되며, 운전이 금지되는 술에 취한 상
태의 기준은 운전자의 혈중알코올농도가 0.05퍼센트 이상인 경우로 한다.
3. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
4. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
5. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않으며, 보통약관 4.(보험금 지급에 관한 세부규정)은 적용하지 않습
니다.
6
민사소송법률비용손해(실손)(비갱신형/갱신형) 
특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유) 
󰊱회사는 「이 특별약관의 보험기간」 중 보험증권에 기재된 피보험자에게 소송제기의 
원인이 되는 사건이 발생하여, 아래에서 정한 민사소송사건이 보험기간 중에 대한
민국 법원에 제기되어 그 소송이 판결, 소송상 조정 또는 소송상 화해로 종료됨에 
따라 피보험자가 부담한 민사소송 법률비용을 이 특별약관에 따라 보상합니다.
보험
지식
회사가 보상하는 소송사건은 대법원 법원재판 사무처리규칙 및 사건별 부호
문자의 부여에 관한 예규에서 아래와 같이 분류되는 소송사건에 한합니다.
심급구분
민사사건
사건별 부호
1심
민사1심합의사건
가합
민사1심단독사건
가단
민사소액사건
가소
항소심
민사항소사건
나
상고심
민사상고사건
다
󰊲위 󰊱의 소송은 소를 직접 제기하거나 소의 제기를 당한 경우에 관계없이 1심 소
송, 그 1심 소송에 대한 항소심, 그 항소심에 대한 상고심 각각(이하 “심급별”이
라 합니다.)을 말하며 이 특별약관에서 정한 보험기간 내에 제기되어야 합니다.
󰊳위 󰊱의 소송은 연간 하나의 사건에 의해 제기된 위 󰊲에서 정한 각 심급별 하나
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (209, 4, 76, '76
용어
정의
소송제기의
원인이 되는 사건
소송제기의 원인이 되는 사건이란 사실관계가 객관적으로 입증 
할 수 있는 사건으로 그 예는 아래와 같습니다.
 ⃝ 채무불이행/부당이득의 경우: 보험기간 이전에 발생한 일이 
없고, 보험기간 중에 처음으로 채무불이행/부당이득이 발생한 
사건
 ⃝ 손해배상의 경우: 해당 사고가 보험기간 중에 발생한 사건
연간 하나의 사건
보험기간 첫날(1회 보험료 받은 시점)부터 1년이 되는 마지막날 
그 시점까지 및 이후 각 1년간의 기간 중 피보험자와 타인간에 
발생한 법적 분쟁으로서 소송이 제기된 원인이 된 하나의 사실을 
말합니다.
1
하나의 소송
대법원 법원재판사무처리규칙 및 사건별 부호문자의 부여에 관한 
예규에서 분류되는 소송사건 중 1.(보험금의 지급사유)에 
해당하는 사건 분류 번호상의 구별되는 1개의 사건 소송을 
말합니다.(민사소송법에 정한 파기환송심, 재심, 이송은 
제외합니다.)
다만, 사건번호가 달리 구분되지만 이미 발생된 소송으로 인한 
반소(민사소송법 제269조(반소)에 정한 것으로 피고가 원고의 
소송에 대하여 제기하는 소송을 말합니다), 동법 제412조(반소의 
제기)의 경우에는 이를 하나의 소송에 포함된 것으로 보며, 
구분되는 사건 소송으로 간주하지 않습니다.
의 소송에 한합니다.
󰊴위 󰊱에도 불구하고 이 계약이 갱신계약인 경우 직전 계약의 보험기간 중에 대한
민국 내에서 피보험자에게 발생한 사건에 대해서도 󰊱내지 󰊳에 따라 보상합니
다.
󰊵회사가 지급하여야 할 민사소송 법률비용손해 보험금은 심급별로 아래의 금액을 
한도로 합니다.
구 분
변호사보수액
인지액 + 송달료
보상한도
1,500만원 한도
(1사고당 자기부담금 10만원 공제)
500만원 한도
용어의 정의
2. (보험금 지급에 관한 세부규정)
󰊱회사는 1.(보험금의 지급사유)에 정한 바에 따라 피보험자에게 심급별로 아래 ① 
내지 ③에 대해 피보험자가 실제 부담한 금액을 민사소송 법률비용손해 보험금으
로 지급합니다.
① 「변호사보수의 소송비용 산입에 관한 규칙」에서 정한 변호사비용(【별표5-1】 
“소송목적의 값에 따른 변호사비용” 참조)의 한도 내에서 피보험자가 실제 부
담한 변호사 보수액 중 자기부담금 10만원을 초과하는 금액 
② 「민사소송 등 인지법」에서 정한 인지액(【별표5-2】 「민사소송 등 인지법」에서 정
한 인지액” 참조)의 한도 내에서 피보험자가 실제 부담한 인지액
③ 대법원의 「송달료규칙의 시행에 따른 업무처리요령」에서 정한 송달료(【별표5-
3】 “「송달료규칙의 시행에 따른 업무처리요령」에서 정한 송달료” 참조)의 한도 
내에서 피보험자가 실제 부담한 송달료
󰊲위 󰊱, ①의 경우 자기부담금을 공제하고 지급하며, 위 󰊱의 각 호에 대해 종국 
판결 결과의 변동에 따라 미지급된 보험금을 추가 지급 또는 기지급된 보험금을 
환수할 수 있습니다.
3. (보험금을 지급하지 않는 사유)
회사는 아래의 사유를 원인으로 하여 생긴 손해는 보상하지 않습니다.
① 계약자나 피보험자의 고의(소송사기를 포함합니다)에 의한 손해
② 지진, 분화, 전쟁, 외국의 무력행사, 혁명, 내란, 사변, 폭동, 소요, 기타 이들
과 유사한 사태에 기인한 손해
③ 핵연료 물질 또는 핵연료 물질에 의해서 오염된 물질의 방사성, 폭발성 또는 
그 밖의 유해한 특성에 의한 사고에 의한 손해
④ 위 󰊳이외의 방사선을 쬐는 것 또는 방사능 오염에 의한 손해 
⑤ 『민사소송법』에 정한 청구의 포기(원고가 변론에서 자기의 소송상의 청구가 이
유 없음을 자인한 것을 말합니다), 인낙(피고가 원고의 소송상의 청구가 이유 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (210, 4, 77, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
77
있음을 인정한 것을 말합니다), 소의 취하, 소의 각하
⑥ 특허법에 정한 특허, 저작권법에 정한 저작권, 상표법에 정한 상표권, 실용신
안법에 정한 실용신안권 및 지적재산권에 관련된 소송
⑦ 피보험자가 각종 단체(상법상 회사, 민법상 법인, 권리능력 없는 사단, 재단, 
조합 등)의 대표자, 이사, 임원 등의 자격으로 행한 업무와 관련된 소송
⑧ 『소비자기본법』 제70조(단체소송의 대상 등)에 따라 제기된 소송
⑨ 『자본시장과 금융투자업에 관한 법률』에 정한 금융투자상품에 관련된 소송
󰊉
󰊒 보험기간 이전에 소송의 원인이 되는 사건이 발생한 경우 및 구두계약(口頭契
約) 등 사실관계를 객관적으로 입증하기 어려운 경우
⑪ 『노동조합 및 노동관계조정법』에 관련된 쟁의행위, 『집회 및 시위에 관한 법률』
에 관련된 시위행위에 관련된 소송
⑫ 『독점규제 및 공정거래에 관련 법률』,『증권관련집단소송법』에 관련된 소송
⑬ 가입여부와 관계없이 『자동차손해배상보장법』, 『산업재해보상보험법』 등 법률에 
의하여 의무적으로 가입하여야 하는 보험(공제계약을 포함합니다. 이하 "의무
보험"이라 합니다)에서 보상되는 손해가 발생되는 경우, 의무보험에서 보상받
을 수 있는 1.(보험금의 지급사유)에서 정한 법률비용
⑭ 환경오염, 일조권, 조망권, 소음, 진동 관련 분쟁, 명예훼손 이와 유사한 사건
과 관련한 분쟁에 기인한 소송
⑮ 소송의 결과에 따라 피보험자가 민사소송 상대측에게 부담하여야 할 소송비용 
일체
⑯ 석면(이를 구성물질로 하거나 유사한 물질을 포함합니다)의 발암성, 전자파(전
자장)의 피해, 의약품의 지속적인 투여로 인한 피해, 의약용구의 지속적인 사
용으로 인한 피해, 흡연으로 인한 피해로 인한 소송
⑰ 법률상 허용되지 않는 도박 등 사행 행위 또는 마약 등의 소지가 금지되어 있
는 물건과 관련된 소송
⑱ 피보험자와 피보험자의 가족 간의 민사소송 
용어
풀이
핵연료물질
사용된 연료를 포함합니다.
핵연료물질에 오염된 물질
원자핵 분열 생성물을 포함합니다.
용어의 정의
용어
정의
소의 취하
민사소송법 제266조(소의 취하),동법 제393조(항소의 취하),동법 
제425조(항소심절차에 준용)에 정한 것으로 판결이 확정되기 전 
제기된 소(항소,상고를 포함합니다.)에 대해 취하하는 것을 
말합니다.
소의 각하
민사소송법 제254조(재판장의 소장심사권), 동법 
제399조(원심재판장의 항소장 심사권),동법 
제402조(항소심재판장의 항소장 심사권),동법 
제425조(항소심절차에 준용)에 따라 소(항소,상고를 
포함합니다.)장을 해당 재판장이 심사하여 보정을 명하였음에도 
불구하고 이를 고치지 않은 경우에 취하는 명령을 말합니다.
1
가족
 1. 피보험자의 부모와 양부모
 2. 피보험자의 배우자의 부모 또는 양부모
 3. 피보험자의 법률상의 배우자 또는 사실혼 관계에 있는 
배우자
 4. 피보험자의 법률상 혼인관계에서 출생한 자녀, 사실혼 
관계에서 출생한 자녀, 양자 또는 양녀
 5. 피보험자의 며느리
 6. 피보험자의 사위
 ※ 위에 정한 가족은 피보험자에게 발생한 사건 당시의 
    피보험자와의 관계를 말합니다.
4. (계약 후 알릴 의무)
󰊱계약을 맺은 후 아래와 같은 사실이 생긴 경우에는 계약자나 피보험자는 지체없
이 서면으로 회사에 알리고 보험증권에 확인을 받아야 합니다.
① 청약서의 기재사항을 변경하고자 할 때 또는 변경이 생겼음을 알았을 때
② 이 특별약관에서 보장하는 위험과 동일한 위험을 보장하는 계약을 다른 보험
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (211, 4, 78, '78
자와 체결하고자 할 때 또는 이와 같은 계약이 있음을 알았을 때
③ 위 ① 및 ② 이외에 위험이 뚜렷이 변경되거나 변경되었음을 알았을 때
󰊲회사는 위 󰊱에 따라 위험이 감소된 경우에는 그 차액보험료를 돌려 드리며, 위
험이 증가된 경우에는 통지를 받은 날로부터 1개월 내에 보험료의 증액을 청구하
거나 이 특별약관을 해지할 수 있습니다.
5. (특별약관의 해지)
󰊱계약자는 손해가 발생하기 전에는 언제든지 이 특별약관을 해지할 수 있습니다. 
다만 타인을 위한 계약의 경우에는 계약자는 그 타인의 동의를 얻거나 보험증권
을 소지한 경우에 한하여 이 특별약관을 해지할 수 있습니다.
󰊲회사는 계약자 또는 피보험자의 고의로 손해가 발생한 경우 이 특별약관을 해지
할 수 있습니다.
󰊳회사는 아래와 같은 사실이 있을 경우에는 손해의 발생여부에 관계없이 그 사실
을 안 날부터 1개월 이내에 이 특별약관을 해지할 수 있습니다.
① 계약자, 피보험자 또는 이들의 대리인이 보통약관 14.(계약전 알릴 의무)에도 
불구하고 고의 또는 중대한 과실로 중요한 사항에 대하여 사실과 다르게 알린 
때
② 뚜렷한 위험의 변경 또는 증가와 관련된 4.(계약후 알릴 의무)에서 정한 계약
자 또는 피보험자의 고의 또는 중대한 과실로 이행하지 않았을 때
󰊴위 󰊳.①의 경우에도 불구하고 다음 중 하나에 해당하는 경우에는 회사는 이 특
별약관을 해지할 수 없습니다.
① 회사가 최초계약 당시에 그 사실을 알았거나 과실로 인하여 알지 못하였을 때
② 회사가 그 사실을 안 날부터 1개월 이상 지났거나 또는 제1회 보험료 등을 
받은 때부터 보험금 지급사유가 발생하지 않고 2년이 지났을 때
③ 최초계약을 체결한 날부터 3년이 지났을 때
④ 「보험을 모집한 자」(이하 “보험설계사 등”이라 합니다)가 계약자 또는 피보험자
에게 알릴 기회를 주지 않았거나 계약자 또는 피보험자가 사실대로 알리는 것
을 방해한 경우, 계약자 또는 피보험자에게 사실대로 알리지 않게 하였거나 
부실한 사항을 알릴 것을 권유했을 때. 다만, 보험설계사 등의 행위가 없었다 
하더라도 계약자 또는 피보험자가 사실대로 알리지 않거나 부실한 사항을 알
렸다고 인정되는 경우에는 계약을 해지할 수 있습니다.
󰊵위 󰊳에 의한 이 특별약관의 해지는 손해가 생긴 후에 이루어진 경우에도 회사는 
그 손해를 보상하여 드리지 않습니다. 그러나 손해가 위 󰊳.① 및 ②의 사실로 생
긴 것이 아님을 계약자 또는 피보험자가 증명한 경우에는 보상하여 드립니다.
󰊶회사는 다른 보험가입내역에 대한 계약 전, 후 알릴 의무 위반을 이유로 이 특별
약관을 해지하거나 보험금 지급을 거절하지 않습니다.
󰊷보통약관 29.(보험료의 납입을 연체하여 해지된 계약의 부활(효력회복))」에 따라 
이 계약이 부활(효력회복)된 경우에는 부활(효력회복)계약을 위 󰊴의 최초계약으
로 봅니다. 다만, 부활(효력회복)이 여러차례 발생된 경우에는 각각의 부활(효력회
복)계약을 최초계약으로 봅니다.
6. (타인을 위한 계약)
󰊱계약자는 타인을 위한 계약을 체결하는 경우에 그 타인의 위임이 없는 때에는 반
드시 이를 회사에 알려야 하며, 이를 알리지 않았을 때에는 그 타인은 이 계약이 
체결된 사실을 알지 못하였다는 사유로 회사에 이의를 제기할 수 없습니다.
󰊲타인을 위한 계약에서 보험사고가 발생한 경우에 계약자가 그 타인에게 보험사고
의 발생으로 생긴 손해를 배상한 때에는 계약자는 그 타인의 권리를 해하지 아니
하는 범위 안에서 회사에 보험금의 지급을 청구할 수 있습니다.
7. (손해의 발생과 통지)
󰊱계약자 또는 피보험자는 아래와 같은 사실이 있는 경우에는 지체없이 그 내용을 
회사에 알려야 합니다.
① 사고에 의해 소송이 발생한 경우(사건의 때와 사건 관련 당사자의 성명과 주
소 및 피보험자의 소송 내용을 회사가 알 수 있는 서류를 포함합니다)
② 소송 판결 전 청구의 포기, 소의 취하, 소의 각하, 인낙, 소송의 변경, 소송상 
화해, 소송상 조정 등이 발생한 경우
③ 소송에 따른 판결이 내려진 경우
④ 기타 회사가 손해와 관련하여 필요하다고 요청한 경우 (회사는 관련 서류를 
요청할 수 있습니다)
󰊲계약자 또는 피보험자가 위 󰊱의 ①의 통지를 게을리하여 손해가 증가된 때에는 
회사는 그 증가된 손해를 보상하여 드리지 않으며, 위 󰊱, ②의 통지를 게을리 
한 때에는 회사가 보상할수 없다고 인정되는 부분은 보상하여 드리지 않습니다.
8. (손해방지의무)
보험사고가 생긴 때에는 계약자 또는 피보험자는 손해의 방지와 경감에 힘써야 합니
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (212, 4, 79, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
79
다. 만약, 계약자 또는 피보험자가 고의 또는 중대한 과실로 이를 게을리한 때에는 
방지 또는 경감할 수 있었을 것으로 밝혀진 값을 손해액에서 뺍니다.
9. (보험금의 분담)
󰊱이 계약에서 보장하는 위험과 같은 위험을 보장하는 다른 계약(공제계약을 포함합
니다)이 있을 경우 각 계약에 대하여 다른 계약이 없는 것으로 하여 각각 산출한 
보상책임액의 합계액이 손해액을 초과할 때에는 회사는 아래에 따라 보상합니다. 
이 계약과 다른 계약이 모두 의무보험인 경우에도 같습니다.
산식
손해액
×
이 계약에 의한 보상책임액
다른 계약이 없는 것으로 하여 각각 계산한 
보상책임액의 합계액
󰊲이 계약이 의무보험이 아니고 다른 의무보험이 있는 경우에는 다른 의무보험에서 
보상되는 금액(피보험자가 가입을 하지 않은 경우에는 보상될 것으로 추정되는 금
액)을 차감한 금액을 손해액으로 간주하여 위 󰊱에 의한 보상할 금액을 결정합니
다.
󰊳피보험자가 다른 계약에 대하여 보험금 청구를 포기한 경우에도 회사의 위 󰊱에 
의한 지급보험금 결정에는 영향을 미치지 않습니다.
10. (보험금의 청구)
피보험자가 보험금을 청구할 때에는 다음의 서류를 회사에 제출하여야 합니다.
① 보험금 청구서(회사양식) 
② 신분증(주민등록증이나 운전면허증 등 사진이 붙은 정부기관발행 신분증, 본인
이 아니면 본인의 인감증명서 포함)
③ 보험금 지급을 위한 증명서류(소장, 소송 상 조정 또는 소송상 화해시 해당 조
서, 선임한 변호사가 발급한 세금계산서, 소송비용액 확정결정서 등)
④ 회사가 요구하는 그 밖의 서류
11. (보험금의 지급절차)
󰊱회사는 10.(보험금의 청구)에서 정한 서류를 접수한 때에는 접수증을 드리고, 그 
서류를 접수받은 후 지체없이 지급할 보험금을 결정하고 지급할 보험금이 결정되
면 7일 이내에 이를 지급하여 드립니다. 또한, 지급할 보험금이 결정되기 전이라
도 피보험자의 청구가 있을 때에는 회사가 추정한 보험금의 50% 상당액을 가지
급보험금으로 지급합니다.
󰊲회사는 위 󰊱의 지급보험금이 결정된 후 7일이 지나도록 보험금을 지급하지 않았
을 때에는 그 다음날부터 지급일까지의 기간에 대하여 【별표1】 (보험금을 지급할 
때의 적립이율 계산)에서 정한 이율로 계산한 금액을 보험금에 더하여 지급합니
다. 그러나 계약자 또는 피보험자의 책임있는 사유로 지급이 지연된 때에는 그 해
당기간에 대한 이자는 더하여 지급하지 않습니다.
12. (대위권)
󰊱회사가 보험금을 지급한 때에는 회사는 피보험자의 판결결과에 따라 지급한 보험
금의 한도 내에서 권리를 가집니다. 다만, 회사가 보상한 금액이 피보험자가 입은 
손해의 일부인 경우에는 피보험자의 권리를 침해하지 않는 범위 내에서 그 권리
를 가집니다.
󰊲계약자 또는 피보험자는 위 󰊱에 의하여 회사가 취득한 권리를 행사하거나 지키
는 것에 관하여 필요한 조치를 하여야 하며, 또한 회사가 요구하는 증거나 서류를 
제출하여야 합니다.
󰊳위 󰊱및 󰊲에도 불구하고 타인을 위한 계약의 경우에는 계약자에 대한 대위권을 
포기합니다.
󰊴회사는 위 󰊱에 따른 권리가 계약자 또는 피보험자와 생계를 같이 하는 가족에 
대한 것인 경우에는 그 권리를 취득하지 못합니다. 다만, 손해가 그 가족의 고의로 
인하여 발생한 경우에는 그 권리를 취득합니다.
13. (조사)
󰊱회사는 보험기간 중 언제든지 피보험자의 소송진행사항, 필요한 경우에는 그의 개
선을 피보험자에게 요청할 수 있습니다. 
󰊲회사는 위 󰊱에 따른 개선이 완료될 때까지 이 특별약관의 효력을 정지할 수 있
습니다.
󰊳회사는 이 특별약관의 중요사항과 관련된 범위 내에서는 보험기간 중 또는 회사
에서 정한 보험금 청구서류를 접수한 날부터 1년 이내에는 언제든지 피보험자의 
회계장부를 열람할 수 있습니다.
󰊴계약자 또는 피보험자가 위 󰊱에 협력하지 않음에 따라 손해가 증가된 때에는 그 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (213, 4, 80, '80
증가된 손해를 보상하지 않으며, 위 󰊳을 이행하지 않은 때에는 회사가 보상할 
수 없다고 인정되는 부분은 보상하지 않습니다.
14. (특별약관의 소멸)
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
15. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
16. (준용규정)
이 특별약관에 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 보
통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인출
금은 지급하지 않습니다.
7
행정소송법률비용손해(실손)(비갱신형/갱신형) 
특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 이 특별약관의 보험기간 중 보험증권에 기재된 피보험자에게 소송제기의 
원인이 되는 사건이 발생하여, 아래에서 정한 행정소송사건이 보험기간 중에 대한
민국 법원에 제기되어 그 소송이 판결, 소송상 조정 또는 소송상 화해로 종료됨에 
따라 피보험자가 부담한 행정소송 법률비용을 이 특별약관에 따라 보상합니다.
보험
지식
회사가 보상하는 소송사건은 대법원 법원재판사무 처리규칙 및 사건별 부호
문자의 부여에 관한 예규에서 아래와 같이 분류되는 소송사건에 한합니다.
심급구분
행정소송사건
사건별 부호
1심
행정1심사건
구합
행정1심재정단독사건
구단
항소심
행정항소사건
누
상고심
행정상고사건
두
󰊲위 󰊱의 소송은 소를 직접 제기하거나 소의 제기를 당한 경우에 관계없이 1심 소
송, 그 1심 소송에 대한 항소심, 그 항소심에 대한 상고심 각각(이하 "심급별"이
라 합니다)을 말하며 이 특별약관에서 정한 보험기간 내에 제기되어야 합니다.
󰊳위 󰊱의 소송은 위 󰊱에서 정한 심급별 하나의 소송에 한합니다.
󰊴위 󰊱에도 불구하고 이 계약이 갱신계약인 경우 이전 계약의 보험기간 중에 대한
민국 내에서 피보험자에게 발생한 사건에 대해서도 󰊱내지 󰊳에 따라 보상합니
다.
󰊵회사가 지급하여야 할 행정소송 법률비용손해 보험금은 심급별로 아래의 금액을 
한도로 합니다.
구분
변호사보수액
인지액 + 송달료
보상한도
1,500만원 한도
(1사고당 자기부담금 10만원 공제)
500만원 한도
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (214, 4, 81, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
81
용어
정의
소송제기의
원인이 되는 사건
사실관계를 객관적으로 입증할 수 있는 사건이 보험기간 이전에 
발생한 일이 없고, 보험기간 중에 처음으로 국가기관 및 
행정청으로부터 받은 행정처분 등을 말합니다.
하나의 소송
대법원 법원재판사무 처리규칙 및 사건별 부호문자의 부여에 
관한 예규에서 분류되는 소송사건 중 1.(보험금의 지급사유)에 
해당하는 사건 분류 번호상의 구별되는 1개의 사건 소송을 
말합니다.(민사소송법주)에 정한 파기환송심, 재심 및 
행정소송법에 정한 제3자에 의한 재심은 제외합니다)
다만, 사건번호가 달리 구분되지만 이미 발생된 소송으로 인한 
반소(민사소송법주) 제269조(반소)에 정한 것으로 피고가 원고의 
소송에 대하여 제기하는 소송을 말합니다), 동법주) 
제412조(반소의 제기)의 경우에는 이를 하나의 소송에 포함된 
것으로 보며, 구분되는 사건 소송으로 간주하지 않습니다.
1
용어의 정의
 주) 행정소송법에 따라 행정소송상 준용되는 민사소송법을 말합니다.
2. (보험금 지급에 관한 세부규정)
󰊱회사는 1.(보험금의 지급사유)에 정한 바에 따라 피보험자에게 심급별로 아래 각 
호에 대해 피보험자가 실제 부담한 금액을 행정소송 법률비용손해 보험금으로 지
급하여 드립니다.
① 「변호사보수의 소송비용 산입에 관한 규칙」에서 정한 변호사비용(【별표6-1】 
“소송목적의 값에 따른 변호사비용” 참조)의 한도 내에서 피보험자가 실제 부
담한 변호사 보수액 중 자기부담금 10만원을 초과하는 금액 
② 「민사소송 등 인지법」에서 정한 인지액(【별표6-2】 「민사소송 등 인지법」에서 정
한 인지액” 참조)의 한도 내에서 피보험자가 실제 부담한 인지액
③ 대법원의 「송달료규칙의 시행에 따른 업무처리요령」에서 정한 송달료(【별표6-
3】 “「송달료규칙의 시행에 따른 업무처리요령」에서 정한 송달료” 참조)의 한도 
내에서 피보험자가 실제 부담한 송달료
󰊲위 󰊱, ①의 경우 자기부담금을 공제하고 지급하며, 위 󰊱의 각 호에 대해 종국 
판결 결과의 변동에 따라 미지급된 보험금을 추가 지급 또는 기지급된 보험금을 
환수할 수 있습니다.
3. (보험금을 지급하지 않는 사유)
회사는 아래의 사유를 원인으로 하여 생긴 손해는 보상하지 않습니다.
① 계약자나 피보험자의 고의(소송사기를 포함합니다)에 의한 손해
② 지진, 분화, 전쟁, 외국의 무력행사, 혁명, 내란, 사변, 폭동, 소요, 기타 이들
과 유사한 사태에 기인한 손해 
③ 핵연료 물질 또는 핵연료 물질에 의하여 오염된 물질의 방사성, 폭발성 또는 
그 밖의 유해한 특성에 의한 사고에 의한 손해 
④ 위 󰊳이외의 방사선을 쬐는 것 또는 방사능 오염에 의한 손해 
⑤ 『행정소송법』(행정소송법에 따라 행정소송상 준용되는 『민사소송법』을 포함합니
다)에 정한 청구의 포기(원고가 변론에서 자기의 소송상의 청구가 이유 없음을 
자인한 것을 말합니다), 인낙(피고가 원고의 소송상의 청구가 이유 있음을 인
정한 것을 말합니다), 소의 취하, 소의 각하
⑥ 특허법에 정한 특허, 저작권법에 정한 저작권, 상표법에 정한 상표권, 실용신
안법에 정한 실용신안권 및 지적재산권에 관련된 소송
⑦ 피보험자가 각종 단체(상법상 회사, 민법상 법인, 권리능력 없는 사단, 재단, 
조합 등)의 대표자, 이사, 임원 등의 자격으로 행한 업무와 관련된 소송
⑧ 『소비자기본법』 제70조(단체소송의 대상등)에 따라 제기된 소송
⑨ 『자본시장과 금융투자업에 관한 법률』에 정한 금융투자상품에 관련된 소송
󰊉
󰊒 보험기간 이전에 소송의 원인이 되는 사건이 발생한 경우 및 구두계약(口頭契
約) 등 사실관계를 객관적으로 입증하기 어려운 경우
⑪ 노동조합 및 노동관계조정법에 관련된 쟁의행위, 집회 및 시위에 관한 법률에 
관련 된 시위행위에 관련된 소송
⑫ 『독점규제 및 공정거래에 관련 법률』,『증권관련집단소송법』에 관련된 소송
⑬ 가입여부와 관계없이 법률에 의하여 의무적으로 가입하여야 하는 보험(공제계
약을 포함합니다. 이하 “의무보험”이라 합니다)에서 보상되는 손해가 발생되는 
경우, 의무보험에서 보상받을 수 있는 1.(보험금의 지급사유)에서 정한 법률비
용
⑭ 환경오염, 일조권, 조망권, 소음, 진동 관련 분쟁, 명예훼손, 이와 유사한 사건
과 관련한 분쟁에 기인한 소송
⑮ 소송의 결과에 따라 피보험자가 소송 상대 측에게 부담하여야 할 소송비용 일
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (215, 4, 82, '82
용어
정의
핵연료물질
사용이 끝난 연료를 포함합니다.
핵연료물질에 
의하여
오염된 물질
원자핵분열 생성물을 포함합니다.
소의 취하
민사소송법주) 제266조(소의 취하), 동법주) 제393조(항소의 
취하), 동법주) 제425조(항소심절차에 준용)에 정한 것으로 
판결이 확정되기 전 제기된 소(항소, 상고를 포함합니다)에 대해 
취하하는 것을 말합니다.
소의 각하
민사소송법주) 제254조(재판장의 소장심사권), 동법주)  
제399조(원심재판장의 항소장 심사권), 동법주) 
용어
정의
제402조(항소심재판장의 항소장 심사권), 동법주) 
제425조(항소심절차에 준용)에 따라 소(항소, 상고를 
포함합니다)장을 해당 재판장이 심사하여 보정을 명하였음에도 
불구하고 이를 고치지 않은 경우에 취하는 명령을 말합니다.
1
체
⑯ 석면(이를 구성물질로 하거나 유사한 물질을 포함합니다)의 발암성, 전자파(전
자장)의 피해, 의약품의 지속적인 투여로 인한 피해, 의약용구의 지속적인 사
용으로 인한 피해, 흡연으로 인한 피해로 인한 소송
⑰ 법률상 허용되지 않는 도박 등 사행 행위 또는 마약 등의 소지가 금지되어 있
는 물건과 관련된 소송
⑱ ‘국민투표무효소송’ 및 『공직선거법』이 정한 ‘선거 무효소송’(공직선거법 제222
조), ‘당선 무효소송’(공직선거법 제223조)
󰊉
󰊛 국가 또는 공공단체의 기관이 법률에 위반되는 행위를 한 때에 직접 자기의 
법률상 이익과 관계없이 그 시정을 구하기 위하여 제기하는 소송
󰊊
󰊒 국가 또는 공공단체의 기관 상호간에 있어서 그 권한의 존부 또는 그 행사에 
관하여 다툼이 있는 때 이에 대하여 제기하는 소송으로 국민의 구체적 권익 
구제와는 관련이 없는 기관소송(지방의회 또는 교육위원회 의결무효소송, 감독
처분에 대한 이의소송 등을 말합니다)
󰊊
󰊓 행정청이 당사자의 신청에 대하여 법률상의 응답의무가 있음에도 이를 하지 
않는 경우 행정청의 응답을 신속하게 하기 위한 소송
용어의 정의
 주) 행정소송법에 따라 행정소송상 준용되는 민사소송법을 말합니다.
4. (계약 후 알릴 의무)
󰊱계약을 맺은 후 아래와 같은 사실이 생긴 경우에는 계약자나 피보험자는 지체없
이 서면으로 회사에 알리고 보험증권에 확인을 받아야 합니다.
① 청약서의 기재사항을 변경하고자 할 때 또는 변경이 생겼음을 알았을 때
② 이 특별약관에서 보장하는 위험과 동일한 위험을 보장하는 계약을 다른 보험
자와 체결하고자 할 때 또는 이와 같은 계약이 있음을 알았을 때
③ 위 ① 및 ② 이외에 위험이 뚜렷이 변경되거나 변경되었음을 알았을 때
󰊲회사는 위 󰊱에 따라 위험이 감소된 경우에는 그 차액보험료를 돌려 드리며, 위
험이 증가된 경우에는 통지를 받은 날로부터 1개월 내에 보험료의 증액을 청구하
거나 이 특별약관을 해지할 수 있습니다.
5. (특별약관의 해지)
󰊱계약자는 손해가 발생하기 전에는 언제든지 이 특별약관을 해지할 수 있습니다. 
다만 타인을 위한 계약의 경우에는 계약자는 그 타인의 동의를 얻거나 보험증권
을 소지한 경우에 한하여 이 특별약관을 해지할 수 있습니다.
󰊲회사는 계약자 또는 피보험자의 고의로 손해가 발생한 경우 이 특별약관을 해지
할 수 있습니다.
󰊳회사는 아래와 같은 사실이 있을 경우에는 손해의 발생여부에 관계없이 그 사실
을 안 날부터 1개월 이내에 이 특별약관을 해지할 수 있습니다.
① 계약자, 피보험자 또는 이들의 대리인이 보통약관 14.(계약 전 알릴 의무)에도 
불구하고 고의 또는 중대한 과실로 중요한 사항에 대하여 사실과 다르게 알린 
때
② 뚜렷한 위험의 변경 또는 증가와 관련된 4.(계약 후 알릴 의무)에서 정한 계약 
후 알릴 의무를 이행하지 않았을 때
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (216, 4, 83, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
83
󰊴위 󰊳.①의 경우에도 불구하고 다음 중 하나에 해당하는 경우에는 회사는 이 특
별약관을 해지할 수 없습니다.
① 회사가 최초계약당시에 그 사실을 알았거나 과실로 인하여 알지 못하였을 때
② 회사가 그 사실을 안 날부터 1개월 이상 지났거나 또는 제1회 보험료를 받은 
때부터 보험금 지급사유가 발생하지 않고 2년이 지났을 때
③ 최초계약을 체결한 날부터 3년이 지났을 때
④ 「보험을 모집한 자」(이하 “보험설계사 등”이라 합니다)가 계약자 또는 피보험자
에게 알릴 기회를 주지 않았거나 계약자 또는 피보험자가 사실대로 알리는 것
을 방해한 경우, 계약자 또는 피보험자에게 사실대로 알리지 않게 하였거나 
부실한 사항을 알릴 것을 권유했을 때. 다만, 보험설계사 등의 행위가 없었다 
하더라도 계약자 또는 피보험자가 사실대로 알리지 않거나 부실한 사항을 알
렸다고 인정되는 경우에는 계약을 해지할 수 있습니다.
󰊵위 󰊳에 의한 이 특별약관의 해지는 손해가 생긴 후에 이루어진 경우에도 회사는 
그 손해를 보상하지 않습니다. 그러나 손해가 위 󰊳.① 및 ②의 사실로 생긴 것이 
아님을 계약자 또는 피보험자가 증명한 경우에는 보상합니다.
󰊶회사는 다른 보험가입내역에 대한 계약 전·후 알릴 의무 위반을 이유로 이 특별약
관을 해지하거나 보험금 지급을 거절하지 않습니다.
󰊷보통약관 29.(보험료의 납입을 연체하여 해지된 계약의 부활(효력회복))에 따라 
이 계약이 부활(효력회복)된 경우에는 부활(효력회복)계약을 위 󰊴의 최초계약으
로 봅니다. 다만, 부활(효력회복)이 여러차례 발생된 경우에는 각각의 부활(효력회
복)계약을 최초계약으로 봅니다.
6. (타인을 위한 계약)
󰊱계약자는 타인을 위한 계약을 체결하는 경우에 그 타인의 위임이 없는 때에는 반
드시 이를 회사에 알려야 하며, 이를 알리지 않았을 때에는 그 타인은 이 계약이 
체결된 사실을 알지 못하였다는 사유로 회사에 이의를 제기할 수 없습니다.
󰊲타인을 위한 계약에서 보험사고가 발생한 경우에 계약자가 그 타인에게 보험사고
의 발생으로 생긴 손해를 배상한 때에는 계약자는 그 타인의 권리를 해하지 않는 
범위 안에서 회사에 보험금의 지급을 청구할 수 있습니다.
7. (손해의 발생과 통지)
󰊱계약자 또는 피보험자는 아래와 같은 사실이 있는 경우에는 지체없이 그 내용을 
회사에 알려야 합니다.
① 사고에 의해 소송이 발생한 경우(사건의 때와 사건 관련 당사자의 성명과 주
소 및 피보험자의 소송 내용을 회사가 알 수 있는 서류를 포함합니다)
② 소송 판결 전 청구의 포기, 소의 취하, 소의 각하, 인낙, 소송의 변경, 소송 상 
화해, 소송상 조정 등이 발생한 경우
③ 소송에 따른 판결이 내려진 경우
④ 기타 회사가 손해와 관련하여 필요하다고 요청한 경우 (회사는 관련 서류를 
요청할 수 있습니다)
󰊲계약자 또는 피보험자가 위 󰊱.①의 통지를 게을리하여 손해가 증가된 때에는 회
사는 그 증가된 손해를 보상하여 드리지 않으며, 위 󰊱,②의 통지를 게을리 한 때
에는 회사가 보상할 수 없다고 인정되는 부분은 보상하지 않습니다.
8. (손해방지의무)
보험사고가 생긴 때에는 계약자 또는 피보험자는 손해의 방지와 경감에 힘써야 합니
다. 만약, 계약자 또는 피보험자가 고의 또는 중대한 과실로 이를 게을리한 때에는 
방지 또는 경감할 수 있었을 것으로 밝혀진 값을 손해액에서 뺍니다.
9. (보험금의 분담)
󰊱이 특별약관에서 보장하는 위험과 같은 위험을 보장하는 다른 계약(공제계약을 포
함합니다)이 있을 경우 각 계약에 대하여 다른 계약이 없는 것으로 하여 각각 산
출한 보상책임액의 합계액이 손해액을 초과할 때에는 회사는 아래에 따라 보상합
니다. 이 계약과 다른 계약이 모두 의무보험인 경우에도 같습니다.
산식
손해액
×
이 계약에 의한 보상책임액
다른 계약이 없는 것으로 하여 각각 계산한 
보상책임액의 합계액
󰊲이 계약이 의무보험이 아니고 다른 의무보험이 있는 경우에는 다른 의무보험에서 보
상되는 금액(피보험자가 가입을 하지 않은 경우에는 보상될 것으로 추정되는 금액)
을 차감한 금액을 손해액으로 간주하여 위 󰊱에 의한 보상할 금액을 결정합니다.
󰊳피보험자가 다른 계약에 대하여 보험금 청구를 포기한 경우에도 회사의 위 󰊱에 
의한 지급보험금 결정에는 영향을 미치지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (217, 4, 84, '84
10. (보험금의 청구)
보험수익자는 다음의 서류를 제출하고 보험금을 청구하여야 합니다.
① 보험금 청구서(회사양식)
② 신분증(주민등록증이나 운전면허증 등 사진이 붙은 정부기관발행 신분증, 본인
이 아니면 본인의 인감증명서 포함)
③ 보험금 지급을 위한 증명서류(소장, 소송 상 조정 또는 소송상 화해시 해당 조
서, 선임한 변호사가 발급한 세금계산서, 소송비용액 확정결정서 등)
④ 회사가 요구하는 그 밖의 서류
11. (보험금의 지급절차)
󰊱회사는 10.(보험금의 청구)에서 정한 서류를 접수한 때에는 접수증을 드리고, 그 
서류를 접수받은 후 지체없이 지급할 보험금을 결정하고 지급할 보험금이 결정되
면 7일 이내에 이를 지급하여 드립니다. 또한, 지급할 보험금이 결정되기 전이라
도 피보험자의 청구가 있을 때에는 회사가 추정한 보험금의 50% 상당액을 가지
급보험금으로 지급합니다.
󰊲회사는 위 󰊱의 지급보험금이 결정된 후 7일이 지나도록 보험금을 지급하지 않았
을 때에는 그 다음날부터 지급일까지의 기간에 대하여 【별표1】 (보험금을 지급할 
때의 적립이율 계산)에서 정한 이율로 계산한 금액을 보험금에 더하여 지급합니
다. 그러나 계약자 또는 피보험자의 책임있는 사유로 지급이 지연된 때에는 그 해
당기간에 대한 이자는 더하여 지급하지 않습니다.
12. (대위권)
󰊱회사가 보험금을 지급한 때에는 회사는 피보험자의 판결결과에 따라 지급한 보험
금의 한도 내에서 권리를 가집니다. 다만, 회사가 보상한 금액이 피보험자가 입은 
손해의 일부인 경우에는 피보험자의 권리를 침해하지 않는 범위 내에서 그 권리
를 가집니다.
󰊲계약자 또는 피보험자는 위 󰊱에 의하여 회사가 취득한 권리를 행사하거나 지키
는 것에 관하여 필요한 조치를 하여야 하며, 또한 회사가 요구하는 증거나 서류를 
제출하여야 합니다.
󰊳위 󰊱및 󰊲에도 불구하고 타인을 위한 계약의 경우에는 계약자에 대한 대위권을 
포기합니다.
󰊴회사는 위 󰊱에 따른 권리가 계약자 또는 피보험자와 생계를 같이 하는 가족에 
대한 것인 경우에는 그 권리를 취득하지 못합니다. 다만, 손해가 그 가족의 고의로 
인하여 발생한 경우에는 그 권리를 취득합니다.
13. (조사)
󰊱회사는 보험기간 중 언제든지 피보험자의 소송진행사항, 필요한 경우에는 그의 개
선을 피보험자에게 요청할 수 있습니다.
󰊲회사는 위 󰊱에 따른 개선이 완료될 때까지 이 특별약관의 효력을 정지할 수 있
습니다.
󰊳회사는 이 특별약관의 중요사항과 관련된 범위 내에서는 보험기간 중 또는 회사
에서 정한 보험금 청구서류를 접수한 날부터 1년 이내에는 언제든지 피보험자의 
회계장부를 열람할 수 있습니다.
󰊴계약자 또는 피보험자가 위 󰊱에 협력하지 않아서 손해가 증가된 때에는 그 증가
된 손해를 보상하지 않으며, 위 󰊳을 이행하지 않은 때에는 회사가 보상할 수 없
다고 인정되는 부분은 보상하지 않습니다.
14. (특별약관의 소멸)
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
15. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
16. (준용규정)
이 특별약관에 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 보
통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인출
금은 지급하지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (218, 4, 85, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
85
8
(가족)과실치사상벌금(실손)(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
회사는 피보험자가 「이 특별약관의 보험기간」 중에 발생한 사고로 대한민국 내에서 
형법 제266조(과실치상) 또는 제267조(과실치사)에 따른 벌금형이 확정된 경우(보험
기간 중에 발생한 사고의 벌금 확정판결이 보험기간 종료 후에 이루어진 경우를 포함
합니다) 1사고당 아래의 금액을 한도로 벌금액에 해당하는 금액을 지급합니다. 단, 
피보험자가 2인 이상인 경우 각 피보험자별로 아래의 한도를 적용합니다.
구분
보상한도액
형법 제266조(과실치상)에 의한 벌금
500만원 한도
형법 제267조(과실치사)에 의한 벌금
700만원 한도
2. (피보험자의 범위)
󰊱1.(보험금의 지급사유)에서 피보험자는 아래의 사람을 말합니다.
① 「보험증권에 기재된 피보험자」(이하 “피보험자 본인”이라 합니다)
② 피보험자 본인의 배우자(이하 “배우자”라 합니다)
③ 피보험자 본인 또는 배우자와 생계를 같이 하고, 보험증권에 기재된 주택의 
주민등록상 동거 중인 동거 친족(민법 제777조)
④ 피보험자 본인 또는 배우자와 생계를 같이 하는 별거중인 미혼 자녀
인용
문구
민법 제777조(친족의 범위)에서 규정한 친족의 범위
8촌 이내의 혈족, 4촌 이내의 인척, 배우자
󰊲위 󰊱에서 피보험자 본인과 피보험자 본인 이외의 피보험자와의 관계는 사고발생 
당시의 관계를 말합니다.
3. (보험금을 지급하지 않는 사유)
󰊱회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자의 고의. 다만, 피보험자가 심신상실 등으로 자유로운 의사결정을 할 
수 없는 상태에서 자신을 해친 경우에는 보험금을 지급합니다.
② 보험수익자의 고의. 다만, 그 보험수익자가 보험금의 일부 보험수익자인 경우
에는 다른 보험수익자에 대한 보험금은 지급합니다.
③ 계약자의 고의
④ 피보험자의 임신, 출산(제왕절개를 포함합니다), 산후기. 그러나 회사가 보장하
는 보험금 지급사유로 인한 경우에는 보험금을 지급합니다.
⑤ 전쟁, 외국의 무력행사, 혁명, 내란, 사변, 폭동
󰊲회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자에게 보험금을 받도록 하기 위하여 고용인 또는 피보험자와 세대를 
같이하는 친족의 고의
② 피보험자가 도로교통법 제43조, 제44조에 정한 음주․무면허 상태에서 운전하
던 중 발생한 사고
③ 피보험자가 사고를 일으키고 도주하였을 때
④ 피보험자가 형법 260조(폭행), 261조(특수폭행)과 경합된 사고
인용
문구
도로교통법 제43조(무면허운전 등의 금지)
운전면허를 받지 아니하거나 운전면허의 효력이 정지된 경우에는 자동차등을 
운전하여서는 아니 된다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (219, 4, 86, '86
인용
문구
도로교통법 제44조(술에 취한 상태에서의 운전 금지)
술에 취한 상태에서 운전하여서는 아니되며, 운전이 금지되는 술에 취한 상
태의 기준은 운전자의 혈중알코올농도가 0.05퍼센트 이상인 경우로 한다.
4. (보험금의 분담)
󰊱이 특별약관에서 보장하는 위험과 같은 위험을 보장하는 다른 계약(공제계약을 포
함합니다)이 있을 경우 각 계약에 대하여 다른 계약이 없는 것으로 하여 각각 산
출한 보상책임액의 합계액이 손해액을 초과할 때에는 회사는 아래에 따라 보상합
니다. 
산식
손해액
×
이 계약에 의한 보상책임액
다른 계약이 없는 것으로 하여 각각 계산한 
보상책임액의 합계액
󰊲피보험자가 다른 계약에 대하여 보험금 청구를 포기한 경우에도 회사의 위 󰊱에 
의한 지급보험금 결정에는 영향을 미치지 않습니다.
5. (보험금의 청구)
보험수익자 또는 계약자는 다음의 서류를 제출하고 보험금 또는 해지환급금을 청구해
야 합니다.
① 청구서(회사양식)
② 사고증명서(고소장, 최종 확정판결문 등)
③ 신분증(주민등록증 이나 운전면허증 등 사진이 붙은 정부기관발행 신분증, 본
인이 아니면 본인의 인감증명서 포함)
④ 기타 보험수익자가 보험금 등의 수령에 필요하여 제출하는 서류
6. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간 중에 사망할 경우에 이 특별약관은 소멸
됩니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
6. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
7. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 보통
약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인출금은 
지급하지 않으며, 보통약관 4.(보험금 지급에 관한 세부규정)은 적용하지 않습니다.
9
업무상과실·중과실치사상벌금(실손, 형법 제 268조 관련)
(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
회사는 피보험자가 「이 특별약관의 보험기간」 중에 발생한 사고로 대한민국 내에서 
형법 제268조(업무상과실·중과실 치사상)에 따른 벌금형(단, 특별법 위반을 포함한 
벌금형은 제외. 특별법이 변경될 경우에는 변경된 특별법 내용을 적용)이 확정된 경
우(보험기간 중에 발생한 사고의 벌금 확정판결이 보험기간 종료 후에 이루어진 경우
를 포함합니다) 1사고당 2,000만원을 한도로 해당 벌금형에 해당하는 금액을 지급합
니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (220, 4, 87, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
87
인용
문구
형법 제268조(업무상과실·중과실 치사상)
업무상과실 또는 중대한 과실로 인하여 사람을 사상에 이르게 한 자는 5년 
이하의 금고 또는 2천만원 이하의 벌금에 처한다.   
2. (보험금을 지급하지 않는 사유)
회사는 아래의 사유를 원인으로 하여 생긴 손해는 보상하여 드리지 아니합니다. 
① 피보험자 또는 그 법정대리인의 고의
② 계약자 및 그 법정대리인의 고의
③ 피보험자가 보험금을 받도록 하기 위한 고용인 또는 피보험자와 세대를 같이
하는 친족의 고의
④ 피보험자가 사고를 내고 도주하였을 때
⑤ 피보험자가 도로교통법 제43조, 제44조에 정한 음주무면허 상태에서 운전하던 
중 사고를 일으킨 때
⑥ 피보험자가 형법 제260조(폭행, 존속폭행), 제261조(특수폭행)과 경합된 사고
⑦ 특별법 위반을 포함한 벌금형(특별법이 변경될 경우에는 변경된 특별법 내용
을 적용)
인용
문구
도로교통법 제43조(무면허운전 등의 금지)
운전면허를 받지 아니하거나 운전면허의 효력이 정지된 경우에는 자동차등을 
운전하여서는 아니 된다.
도로교통법 제44조(술에 취한 상태에서의 운전 금지)
술에 취한 상태에서 운전하여서는 아니되며, 운전이 금지되는 술에 취한 상
태의 기준은 운전자의 혈중알코올농도가 0.05퍼센트 이상인 경우로 한다.
3. (보험금의 분담)
󰊱이 특별약관에서 보장하는 위험과 같은 위험을 보장하는 다른 계약(공제계약을 포함
합니다)이 있을 경우 각 계약에 대하여 다른 계약이 없는 것으로 하여 각각 산출한 
보상책임액의 합계액이 손해액을 초과할 때에는 회사는 아래에 따라 보상합니다. 
산식
손해액
×
이 계약에 의한 보상책임액
다른 계약이 없는 것으로 하여 각각 계산한 
보상책임액의 합계액
󰊲피보험자가 다른 계약에 대하여 보험금 청구를 포기한 경우에도 회사의 위 󰊱에 
의한 지급보험금 결정에는 영향을 미치지 않습니다.
4. (보험금의 청구)
보험수익자는 다음의 서류를 제출하고 보험금을 청구하여야 합니다.
① 보험금 청구서(회사양식) 
② 신분증(주민등록증이나 운전면허증 등 사진이 붙은 정부기관발행 신분증, 본인
이 아니면 본인의 인감증명서 포함)  
③ 보험금 지급을 위한 증명서류(고소장, 최종 확정판결문 등)
④ 회사가 요구하는 그 밖의 서류
5. (특별약관의 소멸)
󰊱보험증권에 기재된 피보험자가 보험기간 중에 사망할 경우에 이 특별약관은 소멸
됩니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
6. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
7. (준용규정)
이 특별약관에 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 보
통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인출
금은 지급하지 않습니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (221, 4, 88, '88
용어
풀이
기소유예
검찰사건사무규칙 제69조 제3항 제1호에서 정한 피의사실이 인정되나 「형
법」 제51조 각호의 사항을 참작할 때 소추를 필요로 하지 아니하여 검찰이 
기소를 유예하는 경우를 말합니다.
약식기소
검사가 지방법원의 관할사건에 대하여 보통의 심판절차인 공판절차를 거치지 
않고 피고인에게 벌금, 구류 또는 몰수의 형을 과하는 것이 타당하다고 판단
하여 약식명령공소장에 의하여 기소하는 것을 말합니다.
인용
문구
자동차손해배상보장법 시행령 제2조(건설기계의 범위)
1. 덤프트럭
2. 타이어식 기중기
3. 콘크리트믹서트럭
4. 트럭적재식 콘크리트펌프
5. 트럭적재식 아스팔트살포기
6. 타이어식 굴삭기
7. 「건설기계관리법 시행령」 별표 1 제26호에 따른 특수건설기계 중 다음 
각 목의 특수건설기계
   가. 트럭지게차
   나. 도로보수트럭
   다. 노면측정장비(노면측정장치를 가진 자주식인 것을 말한다)
※ 관련 법규가 변경되어 새로운 항목이 추가되는 경우에는 그 항목도 포함
10
보복운전피해위로금(비갱신형/갱신형) 특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중 “보복운전”의 
피해자가 되어 수사기관에 신고, 고소, 고발 등이 접수되고 검찰에 의해 공소제기
(이하 “기소”라 하며, 약식기소를 포함합니다) 또는 기소유예된 경우, 이 특별약관
의 보험가입금액을 보복운전피해위로금으로 피보험자에게 지급합니다. 
󰊲위 󰊱의 “보복운전”이라 함은 피보험자가 자동차를 운전하던 중에 발생한 시비로 
인하여 타인이 자동차를 수단 으로 피보험자를 상대로 다음 각 호에서 정한 행위
를 하여 검찰에 의해 기소 또는 기소유예된 경우를 말합니다.
① 형법 제258조의2(특수상해)에서 정한 특수상해
② 형법 제258조의2(상습특수상해) 및 제264조(상습범)에서 정한 상습특수상해
③ 형법 제261조(특수폭행)에서 정한 특수폭행
④ 형법 제261조(특수폭행) 및 제264조(상습범)에서 정한 상습특수폭행
⑤ 형법 제284조(특수협박)에서 정한 특수협박
⑥ 형법 제284조(특수협박) 및 제285조(상습범)에서 정한 상습특수협박
⑦ 형법 제369조(특수손괴)에서 정한 특수손괴
󰊳위 󰊲에서 “자동차를 운전하던 중”이라 함은 도로여부, 주정차여부, 엔진의 시동
여부를 불문하고 피보험자가 자동차 운전석에 탑승하여 핸들을 조작하거나 조작 
가능한 상태에 있는 것을 말합니다.
󰊴위 󰊲및 󰊳에서 자동차라 함은 자동차관리법 시행규칙 제2조에 정한 승용자동
차, 승합자동차, 화물자동차, 특수자동차, 이륜자동차 및 「자동차손해배상보장법 
시행령 제2조(건설기계의 범위)에서 정한 건설기계」를 말합니다. 다만, 「자동차손
해배상보장법 시행령 제2조(건설기계의 범위)에서 정한 건설기계」가 작업기계로 
사용되는 동안은 자동차로 보지 않습니다. 
2. (보험금 지급에 관한 세부 규정) 
󰊱1.(보험금의 지급사유)의 보복운전피해위로금은 하나의 “보복운전”이 1.(보험금의 
지급사유) 󰊲각 호의 행위 중 2개 이상에 해당하더라도 1회에 한하여 보복운전
피해위로금을 지급합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (222, 4, 89, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
89
󰊲보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 
수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 중
에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
󰊳피보험자는 다음의 서류를 제출하고 보험금을 청구해야 합니다.
① 검찰의 고소‧고발사건처분결과통지서, 공소장 또는 사건처분결과증명서, 검찰청
에서 발행한 불기소이유통지서 등(죄명, 불기소 이유 및 피의자와 피보험자와
의 관계를 알 수 있는 서류)
② 기타 보험회사가 필요하다고 인정하는 서류
3. (보험금을 지급하지 않는 사유) 
󰊱회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자의 고의. 다만, 피보험자가 심신상실 등으로 자유로운 의사결정을 할 
수 없는 상태에서 자신을 해친 경우에는 보험금을 지급합니다.
② 보험수익자의 고의. 다만, 그 보험수익자가 보험금의 일부 보험수익자인 경우
에는 다른 보험수익자에 대한 보험금은 지급합니다.
③ 계약자의 고의
④ 피보험자가 상호보복운전으로 기소 또는 기소유예 되는 경우
용어
풀이
상호보복운전
상호간에 보복운전을 행하여 하나의 사고에 대한 사건의 당사자가 피해자인 
동시에 가해자가 되는 경우를 말합니다.
4. (특별약관의 소멸)
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않습니다.
11
보복운전피해(인적물적)위로금(비갱신형/갱신형) 
특별약관
용어
정의
비갱신형
만기까지 갱신되지 않고 보장이 지속되는 형태를 말합니다.
예시) 3/5/10년 만기
갱신형
일정 기간을 주기로 보험기간이 자동 갱신되는 형태를 말합니다. 이 
특별약관을 갱신형으로 가입한 경우에는 보험증권에 갱신 주기를 기
재하여 드립니다.
예시) 3/7년만기 자동갱신
1. (보험금의 지급사유)
󰊱회사는 보험증권에 기재된 피보험자가 「이 특별약관의 보험기간」 중 “보복운전”의 
피해자로서 신체에 피해가 발생하거나, 피보험자의 자동차 또는 부착물의 손해가 
발생하여 수사기관에 신고, 고소, 고발 등이 접수되고 검찰에 의해 공소제기(이하 
“기소”라 하며, 약식기소를 포함합니다) 또는 기소유예된 경우, 이 특별약관의 보
험가입금액을 보복운전피해(인적물적)위로금으로 피보험자에게 지급합니다. 
󰊲위 󰊱의 “보복운전”이라 함은 피보험자가 자동차를 운전하던 중에 발생한 시비로 
인하여 타인이 자동차를 수단으로 피보험자를 상대로 다음 각 호에서 정한 행위
를 하여 검찰에 의해 기소 또는 기소유예된 경우를 말합니다.
① 형법 제258조의2(특수상해)에서 정한 특수상해
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (223, 4, 90, '90
용어
풀이
기소유예
검찰사건사무규칙 제69조 제3항 제1호에서 정한 피의사실이 인정되나 「형
법」 제51조 각호의 사항을 참작할 때 소추를 필요로 하지 아니하여 검찰이 
기소를 유예하는 경우를 말합니다.
약식기소
검사가 지방법원의 관할사건에 대하여 보통의 심판절차인 공판절차를 거치지 
않고 피고인에게 벌금, 구류 또는 몰수의 형을 과하는 것이 타당하다고 판단
하여 약식명령공소장에 의하여 기소하는 것을 말합니다.
인용
문구
자동차손해배상보장법 시행령 제2조(건설기계의 범위)
1. 덤프트럭
2. 타이어식 기중기
3. 콘크리트믹서트럭
4. 트럭적재식 콘크리트펌프
5. 트럭적재식 아스팔트살포기
6. 타이어식 굴삭기
7. 「건설기계관리법 시행령」 별표 1 제26호에 따른 특수건설기계 중 다음 
각 목의 특수건설기계
   가. 트럭지게차
   나. 도로보수트럭
   다. 노면측정장비(노면측정장치를 가진 자주식인 것을 말한다)
※ 관련 법규가 변경되어 새로운 항목이 추가되는 경우에는 그 항목도 포함
② 형법 제258조의2(상습특수상해) 및 제264조(상습범)에서 정한 상습특수상해
③ 형법 제261조(특수폭행)에서 정한 특수폭행
④ 형법 제261조(특수폭행) 및 제264조(상습범)에서 정한 상습특수폭행
⑤ 형법 제284조(특수협박)에서 정한 특수협박
⑥ 형법 제284조(특수협박) 및 제285조(상습범)에서 정한 상습특수협박
⑦ 형법 제369조(특수손괴)에서 정한 특수손괴
󰊳위 󰊲에서 “자동차를 운전하던 중”이라 함은 도로여부, 주정차여부, 엔진의 시동
여부를 불문하고 피보험자가 자동차 운전석에 탑승하여 핸들을 조작하거나 조작 
가능한 상태에 있는 것을 말합니다.
󰊴위 󰊲및 󰊳에서 자동차라 함은 자동차관리법 시행규칙 제2조에 정한 승용자동
차, 승합자동차, 화물자동차, 특수자동차, 이륜자동차 및 「자동차손해배상보장법 
시행령 제2조(건설기계의 범위)에서 정한 건설기계」를 말합니다. 다만, 「자동차손
해배상보장법 시행령 제2조(건설기계의 범위)에서 정한 건설기계」가 작업기계로 
사용되는 동안은 자동차로 보지 않습니다. 
2. (보험금 지급에 관한 세부 규정) 
󰊱1.(보험금의 지급사유)의 보복운전피해(인적물적)위로금은 하나의 “보복운전”이 
1.(보험금의 지급사유) 󰊲각 호의 행위 중 2개 이상에 해당하더라도 1회에 한하
여 보복운전피해(인적물적)위로금을 지급합니다.
󰊲보험수익자와 회사가 1.(보험금의 지급사유)의 보험금의 지급사유에 대해 합의하
지 못할 때는 보험수익자와 회사가 함께 제3자를 정하고 그 제3자의 의견에 따를 
수 있습니다. 제3자는 의료법 제3조(의료기관)에 규정한 종합병원 소속 전문의 중
에 정하며, 보험금 지급사유 판정에 드는 의료비용은 회사가 전액 부담합니다.
󰊳피보험자는 다음의 서류를 제출하고 보험금을 청구해야 합니다.
① 검찰의 고소‧고발사건처분결과통지서, 공소장 또는 사건처분결과증명서, 검찰청
에서 발행한 불기소이유통지서 등(죄명, 불기소 이유 및 피의자와 피보험자와
의 관계를 알 수 있는 서류)
② 진단서, 소견서, 입원‧통원치료확인서 또는 필요시 내원경위 및 치료사항을 확
인할 수 있는 진료확인서 및 진료기록부 등 피보험자의 부상정도를 확인할 수 
있는 서류
③ 피해물품의 수리비견적서, 수리비영수증, 자동차보험지급결의서 등
④ 기타 보험회사가 필요하다고 인정하는 서류
3. (보험금을 지급하지 않는 사유) 
󰊱회사는 다음 중 어느 한 가지의 경우에 의하여 보험금 지급사유가 발생한 때에는 
보험금을 지급하지 않습니다.
① 피보험자의 고의. 다만, 피보험자가 심신상실 등으로 자유로운 의사결정을 할 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (224, 4, 91, '특
별
약
관
상
해
비
용
손
해
무배당 프로미라이프 참좋은오토바이운전자보험1707
91
수 없는 상태에서 자신을 해친 경우에는 보험금을 지급합니다.
② 보험수익자의 고의. 다만, 그 보험수익자가 보험금의 일부 보험수익자인 경우
에는 다른 보험수익자에 대한 보험금은 지급합니다.
③ 계약자의 고의
④ 피보험자가 상호보복운전으로 기소 또는 기소유예 되는 경우
용어
풀이
상호보복운전
상호간에 보복운전을 행하여 하나의 사고에 대한 사건의 당사자가 피해자인 
동시에 가해자가 되는 경우를 말합니다.
4. (특별약관의 소멸) 
󰊱보험증권에 기재된 피보험자가 보험기간중에 사망할 경우에 이 특별약관은 소멸됩
니다.
󰊲위 󰊱에 따라 이 특별약관이 소멸되는 경우에는 “보험료 및 책임준비금 산출방법
서”에서 정하는 바에 따라 회사가 그때까지 적립한 책임준비금을 지급합니다.
5. (특별약관의 갱신)
이 특별약관을 갱신형으로 가입한 경우에는 『제도성 특별약관 [6.갱신형 계약 자동갱
신 특별약관]』에 따라 갱신됩니다.
6. (준용규정)
이 특별약관에서 정하지 않은 사항은 보통약관을 따릅니다. 단, 이 특별약관에서는 
보통약관에서 정한 9.(만기환급금의 지급)의 만기환급금 및 36.(중도인출금)의 중도인
출금은 지급하지 않으며, 보통약관 4.(보험금 지급에 관한 세부규정)은 적용하지 않습
니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (225, 4, 92, '') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (226, 4, 93, '특
별
약
관
상
해
비
용
손
해
특별약관
제7장 제도성
특별약관
제도성
특별약관
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (227, 4, 94, '94
어려운 용어는 프로미라이프 용어사전 참고 ……………………………………   21
인용 법규는   약관에서 인용한 법규  참고 ……………………………………  123 
1
보험료자동납입 특별약관
1. (보험료 납입)  
󰊱계약자는 이 특별약관에 따라 계약자의 「거래은행」(우체국을 포함합니다. 이하 같
습니다) 지정계좌를 이용하여 보험료를 자동납입합니다.
󰊲위 󰊱에 의하여 제1회 보험료의 납입방법을 계약자의 거래은행 지정 계좌를 통한 
자동납입으로 가입하고자 하는 경우에, 회사는 청약서를 접수하고 자동이체신청에 
필요한 정보를 제공한 때를 청약일 및 제1회 보험료 납입일로 하여 보통약관 
18.(보험계약의 성립)의 규정을 적용합니다. 다만, 계약자의 책임있는 사유로 보
험료 납입이 불가능한 경우에는 거래은행의 지정계좌로부터 제1회 보험료가 이체
된 날을 기준으로 합니다.
2. (보험료의 영수)  
자동납입일자는 이 보험계약청약서에 기재된 보험료 납입해당일에도 불구하고 회사와 
계약자가 별도로 약정한 일자로 합니다.
3. (보험계약후 알릴 의무) 
계약자는 지정계좌의 번호가 변경되거나 폐쇄 또는 거래정지된 경우에는 이 사실을 
회사에 알려야 합니다.
4. (준용규정) 
이 특별약관에 정하지 않은 사항은 보통약관 및 해당 특별약관을 따릅니다.
2
선지급서비스 특별약관
1. (적용대상) 
󰊱「이 선지급서비스 특별약관」(이하 “특별약관”이라 합니다)을 부가하는 보통약관은 
계약자와 피보험자가 동일한 보험계약이어야 합니다.
󰊲이 특별약관의 보험기간은 보통약관의 보험기간이 끝나는 날의 12개월 이전까지
로 합니다.
󰊳보통약관에 「사망보험금을 지급하는 특별약관」(이하 “사망보장 특별약관”이라 합니
다)이 부가되어 있는 경우에도 이 특별약관을 적용합니다.
2. (지급사유) 
󰊱회사는 특별약관의 보험기간 중 의료법 제3조에 정한 국내의 종합병원 또는 이와 
동등하다고 회사가 인정하는 국외의 의료기관에서 전문의 자격을 가진 자가 실시
한 진단결과 「피보험자의 남은 생존기간」(이하 “여명”이라 합니다)이 6개월 이내라
고 판단한 경우에 회사의 신청서에 정한 바에 따라 사망보험금의 50%를 「선지급 
사망보험금」(이하 “보험금”이라 합니다)으로 피보험자에게 지급합니다.
󰊲이 특별약관의 보험금을 지급하였을 때에는 지급한 보험금액에 해당하는 계약의 
보험가입금액이 지급일에 감액된 것으로 봅니다. 다만, 그 감액부분에 해당하는 
해지환급금이 있어도 이를 지급하지 않습니다. 이 경우 이 특별약관의 보험금 지
급일 이후 사망보장 특별약관에 정한 사망보험금의 청구를 받아도 이 특별약관에 
의하여 지급된 보험금액에 해당하는 사망보험금은 지급하지 않습니다.  
󰊳이 특별약관의 보험금이 지급되기 전에 사망보장 특별약관에 정한 사망보험금의 
청구를 받았을 경우 이 특별약관의 보험금 청구가 있어도 이를 없었던 것으로 보
아 이 특별약관의 보험금을 지급하지 않습니다.
󰊴사망보장 특별약관에 정한 사망보험금이 지급된 때에는 그 이후 이 특별약관의 
보험금을 지급하지 않습니다. 
󰊵이 특별약관의 보험금 지급에 있어서는 회사가 정하는 바에 따라 여명기간 상당
분의 이자 및 보험료를, 또 보통약관에 보험계약대출금이 있는 경우에는 그 원리
금 합계를 뺀 금액을 지급합니다.
󰊶이 특별약관의 보험금을 지급할 때 보험금액의 계산은 보험금을 지급하는 날의 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (228, 4, 95, '제
도
성
특
별
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
95
사망보장 특별약관의 사망보험금액을 기준으로 합니다.
3. (보험금의 지정대리 청구인) 
󰊱계약자가 이 특별약관의 보험금을 청구할 수 없는 특별한 사정이 있을 때에는 「계
약자가 미리 지정하거나 또는 지정대리청구인이 7.(보험금의 청구)에 정한 구비서
류 및 특별한 사정이 있음을 증명하는 서류를 제출하고 회사의 승낙을 얻어 이 
특별약관의 보험수익자의 대리인으로서 이 특별약관의 보험금을 청구할 수 있습
니다.
인용
문구
지정대리청구인 
4.(지정대리청구인의 변경지정)의 규정에 따라 변경 지정한 다음의 자
① 보험금 청구시 피보험자와 동거하거나 피보험자와 생계를 같이 하고 
있는 피보험자의 가족관계등록상 또는 주민등록상의 배우자
② 보험금 청구시 피보험자와 동거하거나 피보험자와 생계를 같이하고 
있는 피보험자의 3촌 이내의 친족
󰊲위 󰊱의 규정에 의하여 회사가 이 특별약관의 보험금을 지정대리청구인에게 지급
한 경우에는 그 이후 이 특별약관의 보험금 청구를 받더라도 회사는 이를 지급하
지 않습니다.
4. (지정대리청구인의 변경지정) 
계약자는 다음의 서류를 제출하고 지정대리청구인을 변경 지정할 수 있습니다. 이 경
우 회사는 변경지정을 서면으로 알리거나 보험증권에 그 뜻을 기재하여 드립니다.
① 청구서(회사양식)
② 보험증권
③ 지정대리청구인의 주민등록등본
④ 주민등록증 제시(본인이 아닌 경우는 본인의 인감증명서)
5. (보험금을 지급하지 않는 보험사고) 
계약자 또는 지정대리청구인의 고의에 의하여 피보험자가 2.(지급사유)의 󰊱에 해당
된 경우에는 이 특별약관의 보험금을 지급하지 않습니다.
6. (특별약관의 보험료) 
이 특별약관의 보험료는 없습니다.
7. (보험금의 청구) 
󰊱피보험자 또는 지정대리 청구인은 1.(적용대상)에 정한 특별약관의 보험기간중에 
회사가 정하는 바에 따라 다음의 서류를 제출하고 이 특별약관의 보험금을 청구
하여야 합니다.
① 청구서(회사양식)
② 사고증명서(병원 또는 의원 등에서 발급한 진단서)
③ 주민등록증 제시
④ 피보험자의 인감증명서(지정대리청구인이 청구할 경우)
⑤ 피보험자 및 지정대리청구인의 주민등록등본(지정대리청구인이 청구할 경우)
⑥ 기타 피보험자 또는 지정대리청구인이 보험금의 수령에 필요하여 제출하는 서
류
󰊲위 󰊱.②의 사고증명서는 의료법 제3조(의료기관)에서 정하는 국내의 병원이나 의
원 또는 국외의 의료관련법에서 정한 의료기관에서 발급한 것이어야 합니다.
8. (보험금의 지급) 
󰊱회사는 위 7.(보험금의 청구)의 보험금 청구서류를 접수한 때에는 접수증을 드리
고 휴대전화 문자메시지 또는 전자우편 등으로도 송부하며, 그 서류를 접수한 날
부터 3영업일 이내에 이 특별약관의 보험금을 드립니다. 다만, 지급사유의 조사나 
확인이 필요한 경우 접수 후 10영업일 이내에 지급합니다.
󰊲위 󰊱의 규정에 따라 지급사유의 조사나 확인이 필요한 경우 계약자가 회사로부
터의 사실 조회에 대하여 정당한 사유없이 회답 또는 동의를 거부한 때에는 그 
회답 또는 동의를 얻어 사실 확인이 끝날 때까지 이 특별약관의 보험금을 지급하
지 않습니다.  또한, 회사가 지정한 의사에 의한 피보험자의 진단을 요구한 경우
에도 진단을 받지 않은 때에는 진단을 받고 사실 확인이 끝날 때까지 이 특별약
관의 보험금을 지급하지 않습니다.
󰊳회사는 위 󰊱의 규정에 의한 지급기일내에 이 특별약관의 보험금을 지급하지 아니
하였을 때에는 그 지급기일의 다음날로부터 지급일까지의 기간에 대하여 ‘【별표1】 
보험금을 지급할 때의 적립이율 계산’에서 정한 이율로 계산한 금액을 보험금에 더
하여 지급합니다. 그러나 계약자, 피보험자 또는 보험수익자의 책임있는 사유로 지
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (229, 4, 96, '96
급이 지연된 때에는 그 해당기간에 대한 이자는 더하여 지급하지 않습니다.
9. (준용규정) 
이 특별약관에서 정하지 않은 사항은 보통약관 및 사망을 보장하는 특별약관을 따릅
니다.
3
지정대리청구서비스 특별약관
1. (적용대상)
이 특별약관(이하 “특별약관”이라 합니다)은 계약자, 피보험자 및 보험수익자가 모두 
동일한 보통약관 및 특별약관에 적용됩니다.
2. (특별약관의 체결 및 소멸)
󰊱이 특별약관은 보험계약자의 청약(請約)과 보험회사의 승낙(承諾)으로 부가되어집
니다. 
󰊲1.(적용대상)의 보험계약이 해지(解止) 또는 기타 사유에 의하여 효력을 가지지 
않게 되는 경우에는 이 특별약관은 더 이상 효력을 가지지 않습니다.
3. (지정대리청구인의 지정)
󰊱보험계약자는 보통약관 또는 특별약관에서 정한 보험금을 직접 청구할 수 없는 
특별한 사정이 있을 경우를 대비하여 계약을 체결할 때 또는 계약체결 이후 다음 
각호에 해당하는 자 중 1인을 「보험금의 대리청구인」(이하 “지정대리청구인”이라 
합니다)으로 지정(4.(지정대리청구인의 변경지정)에 의한 변경 지정 포함)할 수 
있습니다. 다만, 지정대리청구인은 보험금 청구시에도 다음 각호에 해당하여야 합
니다.
① 피보험자와 동거하거나 피보험자와 생계를 같이 하고 있는 피보험자의 가족관
계등록부상 또는 주민등록상의 배우자 
② 피보험자와 동거하거나 피보험자와 생계를 같이 하고 있는 피보험자의 3촌 이
내의 친족
󰊲위 󰊱에도 불구하고, 지정대리청구인이 지정된 이후에 1.(적용대상)의 보험수익자
가 변경되는 경우에는 이미 지정된 지정대리청구인의 자격은 자동적으로 상실된 
것으로 봅니다.
4. (지정대리청구인의 변경지정)
계약자는 다음의 서류를 제출하고 지정대리청구인을 변경 지정할 수 있습니다. 이 경
우 회사는 변경 지정을 서면으로 알리거나 보험증권의 뒷면에 기재하여 드립니다.
① 지정대리청구인 변경신청서(회사양식)
② 보험증권
③ 지정대리청구인의 주민등록등본, 가족관계등록부(기본증명서 등)
④ 신분증(주민등록증 이나 운전면허증 등 사진이 붙은 정부기관 발행 신분증, 본
인이 아니면 본인의 인감증명서 포함)
5. (보험금 지급 등의 절차)
󰊱지정대리청구인은 6.(보험금의 청구)에 정한 구비서류 및 1.(적용대상)의 보험수익
자가 보험금을 직접 청구할 수 없는 특별한 사정이 있음을 증명하는 서류를 제출
하고 회사의 승낙을 얻어 1.(적용대상)의 보험수익자의 대리인으로서 보험금(사망
보험금 제외)을 청구하고 수령할 수 있습니다. 
󰊲회사가 보험금을 지정대리청구인에게 지급한 경우에는 그 이후 보험금 청구를 받
더라도 회사는 이를 지급하지 않습니다.
6. (보험금의 청구)
지정대리청구인은 회사가 정하는 방법에 따라 다음의 서류를 제출하고 보험금을 청구
하여야 합니다.
① 청구서(회사양식)
② 사고증명서
③ 신분증(주민등록증 이나 운전면허증 등 사진이 붙은 정부기관 발행 신분증)
④ 피보험자의 인감증명서
⑤ 피보험자 및 지정대리청구인의 가족관계등록부(가족관계증명서) 및 주민등록등
본
⑥ 기타 지정대리청구인이 보험금 등의 수령에 필요하여 제출하는 서류
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (230, 4, 97, '제
도
성
특
별
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
97
7. (준용규정)
이 특별약관에서 정하지 않은 사항에 대하여는 보통약관 및 해당 특별약관의 규정을 
따릅니다.
4
단체취급 특별약관
1. (적용범위)
󰊱이 특별약관은 다음 조건에 해당하는 계약(이하 “단체취급계약”이라 합니다)에 대
하여 적용합니다. 계약자 또는 피보험자는 다음 중 한 가지의 단체에 소속되어야 
합니다.
   대상 단체는 각목과 같습니다.
① 동일한 회사, 사업장, 관공서, 국영기업체, 조합 등 5인 이상의 근로자를 고용
하고 있는 단체(다만, 사업장, 직제, 직종 등으로 구분되어 있는 경우의 단체
소속 여부는 관련법규 등에서 정하는 바에 따릅니다)
② 비영리법인단체 또는 변호사회, 의사회 등 동업자단체로서 5인 이상의 구성원
이 있는 단체
③ 그 밖에 단체의 구성원이 명확하고 위험의 동질성이 확보되어 계약의 일괄적
인 관리가 가능한 단체로서 5인 이상의 구성원이 있는 단체
󰊲계약자는 단체 또는 단체의 대표자 내지 단체의 소속원으로 합니다. 다만, 보험계
약자가 아닌 단체의 소속원이 보험료의 전부 또는 일부를 부담하는 경우에는 그 
소속원이 보험계약자로서의 권리를 행사할 수 있습니다.
󰊳이 특별약관의 적용을 받기 위해서는 단체에 소속된 피보험자수가 최초 계약시 5
인 이상(이하 “피보험자단체”라 합니다)이거나 단체에 소속된 계약자수가 최초 계
약시 5인 이상(이하 “계약자단체”라 합니다)이어야 합니다. 또한, 단체 소속원의 
배우자, 자녀 또는 부모(배우자의 부모 포함)를 피보험자로 할 수 있습니다.
2. (대표자의 선정)
단체의 대표자 또는 직책상 대표자를 대리할 수 있는 자 또는 위 1.(적용범위)의 󰊲
에서 정한 계약자 중에서 대표자를 선정합니다.
3. (피보험자의 추가, 감소 또는 교체) 
󰊱단체취급계약을 맺은 후 피보험자를 추가, 감소 또는 교체하고자 하는 경우에는 
보험계약자나 피보험자 또는 2.(대표자의 선정)에서 정한 대표자는 지체 없이 서
면으로 그 사실을 회사에 알리고 회사의 승인을 받아야 합니다.
󰊲회사의 보장은 회사가 승인한 이후부터 시작되며 회사가 승인을 거절할 사유가 
없는 한 위의 서면이 회사에 접수된 때를 승인한 때로 봅니다.
① 피보험자단체에 대한 단체취급계약은 보험기간 중 피보험자 감소시에 해당 피
보험자의 계약을 해지된 것으로 하며, 새로이 추가 또는 교체되는 피보험자의 
보험기간은 이 계약의 남은 보험기간으로 합니다. 이 때 이로 인하여 발생되
는 변경된 보험료를 받고, 추가 또는 환급되는 책임준비금은 받거나 돌려드립
니다. 다만, 피보험자 추가나 교체시에 회사가 받아야 할 책임준비금차액이 발
생한 경우 회사의 보장은 책임준비금을 정산한 후 변경된 보험료를 납입하는 
날로부터 시작합니다.
② 피보험자단체에 대한 단체취급계약에서 피보험자가 추가 또는 교체될 경우에 
암과 같이 보험회사가 보험금을 지급하지 않는 기간이 있는 보장에 있어서는, 
피보험자 추가시에는 책임준비금을 정산한 후 변경된 보험료를 납입한 날로부
터 보험회사가 보험금을 지급하지 않는 기간이 적용되며, 피보험자 교체시에
는 회사의 승인일로부터 보험회사가 보험금을 지급하지 않는 기간이 적용됩니
다.
② 계약자단체에 대한 단체취급계약은 보험기간 중 피보험자수의 감소시에 해당 
피보험자의 계약을 개별계약으로 전환하여 드립니다.
󰊳위 󰊱을 위반하였을 경우에는 회사는 새로이 추가 또는 교체되는 해당 피보험자
에 대하여는 보장하지 않습니다.
󰊴위 󰊱의 경우 추가 또는 교체 후 피보험자에 대한 계약내용 및 회사 승낙기준 등
은 추가 또는 교체 전 피보험자와 동일하게 적용합니다.
4. (적용보험료)
󰊱계약자수 또는 피보험자수가 5인 이상인 경우에는 단체취급보험료를 적용할 수 
있습니다.
󰊲보험기간 중 피보험자수가 감소하여 5인 미만이 된 때에는 위 󰊱을 적용하지 아
니하며, 이후 피보험자수가 증가하여 5인이상이 된 때에는 다시 위 󰊱을 적용합
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (231, 4, 98, '98
니다.
5. (보험료 납입)
󰊱보험료는 단체 또는 단체의 대표자와 회사가 정한 날에 대표자가 보험계약자를 
대리하여 보험료를 일괄 납입하여야 합니다. 다만, 급여이체 및 자동이체로 보험
료를 납입하는 경우에는 일괄납입으로 봅니다.
󰊲회사는 납입보험료에 대한 영수증을 대표자에게 드립니다. 다만, 단체 또는 단체
의 대표자의 요구가 있을 경우이거나 계약자단체인 경우에는 피보험자별로 납입
증명서를 발행하여 드립니다.
6. (특별약관의 소멸)
󰊱다음 중 한 가지의 경우에 해당되는 때에는 이 특별약관은 해당 보험계약자에 대
하여 더 이상 효력을 가지지 않습니다.
① 보험계약자 또는 피보험자가 소속단체를 이탈하였을 때
② 보험료를 일괄하여 납입하지 아니하였을 때
󰊲위 󰊱의 규정에 의하여 이 특별약관이 더 이상 효력을 가지지 아니하게 된 경우
에는 차회 이후의 보험료는 단체취급보험료를 적용하지 않습니다.
7. (적용특칙)
이 특별약관에서 단체가 규약에 따라 구성원의 전부 또는 일부를 피보험자로 하는 계
약을 체결하는 경우에는 보통약관 21.(계약의 무효)를 적용하지 않으며, 회사는 보험
계약자에게만 보험증권를 발행하여 드립니다. 다만, 보험계약자 또는 피보험자의 요
청이 있는 경우에는 피보험자별로 보험증권을 발행하여 드립니다.
8. (준용규칙)
이 특별약관에 정하지 않은 사항은 보통약관 및 해당 특별약관을 따릅니다.
5
전자서명 특별약관
1. (적용대상)
「이 전자서명 특별약관」(이하 “특별약관”이라 합니다)은 전자서명을 포함한 전자문서 
작성 및 제공에 대한 사전동의(사전동의서를 통한 동의)를 받은 보험계약에 적용됩니
다.
2. (특별약관의 체결 및 효력) 
󰊱이 특별약관은 「보험계약」(보통약관을 말하며, 특별약관이 부가된 경우에는 그 특
별약관도 포함합니다. 이하 “보험계약”이라 합니다)을 체결할 때 보험계약자의 청
약과 회사의 승낙으로 보험계약에 부가하여 이루어 집니다. 
󰊲전자서명법 제2조 제2호에 따른 전자서명 또는 제2조 제3호에 따른 공인전자서
명(이하 “전자서명”이라 합니다)으로 계약을 청약할 수 있으며, 전자서명은 자필서
명과 동일한 효력을 갖는 것으로 합니다.
인용
문구
전자서명법 제2조(정의)
2. “전자서명”이라 함은 서명자를 확인하고 서명자가 당해 전자문서에 서명
을 하였음을 나타내는데 이용하기 위하여 당해 전자문서에 첨부되거나 
논리적으로 결합된 전자적 형태의 정보를 말한다.
3. “공인전자서명“이라 함은 다음 각목의 요건을 갖추고 공인인증서에 기초
한 전자서명을 말한다.
   가. 전자서명생성정보가 가입자에게 유일하게 속할 것
   나. 서명 당시 가입자가 전자서명생성정보를 지배·관리하고 있을 것
   다. 전자서명이 있은 후에 당해 전자서명에 대한 변경여부를 확인할 수 
있을 것
   라. 전자서명이 있은 후에 당해 전자문서의 변경여부를 확인할 수 있을 것
  
3. (약관교부 등의 특례)
󰊱계약자가 동의하는 경우 상품설명서, 보험약관 및 계약자 보관용 청약서 및 보험
증권 등(이하 “보험계약 안내자료”라 합니다)을 광기록매체 및 전자우편 등 전자
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (232, 4, 99, '제
도
성
특
별
약
관
무배당 프로미라이프 참좋은오토바이운전자보험1707
99
적 방법으로 교부하고, 계약자 또는 그 대리인이 보험계약 안내자료를 수령하였을 
때에는 해당 문서를 드린 것으로 봅니다.
󰊲계약자가 보험계약 안내자료에 대하여 전자적 방법의 수령을 원하지 않거나, 서면
교부를 요청하는 경우에는 청약한날로부터 5영업일 이내에 보험계약 안내자료를 
우편 등의 방법으로 계약자에게 드립니다.
4. (보험계약자의 알릴 의무)
󰊱계약자가 3.(약관교부 등의 특례)의 󰊱에서 정한 방법으로 보험계약 안내자료를 
수령하고자 하는 경우 계약을 청약할 때 보험계약 안내자료를 수령할 전자우편
(이메일) 주소를 지정하여 회사에 알려야 합니다. 
󰊲위의 󰊱에서 지정한 전자우편(이메일) 주소가 변경되거나 사용 정지된 경우에는 
그 사실을 지체 없이 회사에 알려야 합니다.
󰊳위의 󰊱또는 󰊲에서 지정한 전자우편(이메일) 주소를 사실과 다르게 알리거나 
알리지 않은 경우에는 회사가 알고 있는 최근의 전자우편(이메일) 주소로 보험계
약 안내자료를 교부함으로써 회사의 보험계약 안내자료 제공의무를 다한 것으로 
보며, 전자우편(이메일) 주소를 사실과 다르게 알리거나 알리지 않아 발생하는 불
이익은 계약자가 부담합니다.
5. (준용규정)
이 특별약관에 정하지 않은 사항은 보통약관 및 해당 특별약관을 따릅니다.
6
갱신형 계약 자동갱신 특별약관
1. (적용대상)
󰊱이 특별약관은 「손해의 보상을 내용으로 하는 이 계약의 다른 특별약관 중 갱신형 
특별약관」(이하 “갱신형 특별약관”이라 합니다)에 적용됩니다.
󰊲위 󰊱에도 불구하고 보통약관 중 갱신형으로 보장되는 담보에는 이 특별약관을 
적용하지 않습니다. 이 경우 보통약관에서 별도로 규정된 내용을 따릅니다.
용어
풀이
갱신형
일정 기간을 주기로 보험기간이 자동으로 갱신되는 형태를 말합니다. 보험계
약을 갱신형으로 가입한 경우에는 보험증권에 보장내용별로 갱신 주기를 기
재하여 드립니다.
예시) 3년/7년/10년만기 자동갱신
2. (보험기간 및 자동갱신)
󰊱갱신형 특별약관의 보험기간은 보험증권에 기재된 각각의 보험기간으로 합니다.
󰊲갱신형 특별약관이 아래 ① 내지 ③의 조건을 충족하고 그 갱신형 특별약관의 만
기일의 전일까지 계약자의 별도의 의사표시가 없을 때에는 「종전의 갱신형 특별약
관」(이하 “갱신 전 계약”이라 합니다)과 동일한 내용으로 「그 갱신형 특별약관의 
만기일의 다음날」(이하 “갱신일”이라 합니다)에 갱신되는 것으로 합니다.
① 「갱신될 갱신형 특별약관」(이하 “갱신계약”이라 합니다)의 만기일이 회사가 정
한 기간 내일 것
② 갱신일에 있어서 피보험자의 나이가 회사가 정한 나이의 범위 내일 것
③ 갱신 전 계약의 보험료가 정상적으로 납입완료 되었을 것
󰊳위 󰊱에도 불구하고 갱신시점에서 잔여보험기간이 위 󰊱의 보험기간 미만일 경우 
그 잔여기간을 보장기간으로 하여 갱신되는 것으로 합니다.
󰊴회사는 위 󰊲및 󰊳에 의하여 갱신형 특별약관이 갱신되는 경우 별도의 보험증권
을 발행하지 않습니다.
                            
3. (자동갱신 적용)
󰊱회사는 갱신형 특별약관에 대하여 가입시점의 약관을 적용하며(단, 법령 및 금융
위원회의 명령, 제도적인 약관개정에 따라 약관이 변경된 경우에는 변경된 약관을 
적용합니다), 보험요율에 관한 제도 또는 보험료를 개정한 경우에는 갱신일 현재
의 제도 또는 보험료를 적용합니다.
󰊲회사는 갱신형 특별약관의 보험기간이 끝나기 15일 전까지 해당 계약자가 납입하
여야하는 갱신계약 보험료를 서면, 전화(음성녹음) 또는 전자문서 등으로 안내합
니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (233, 4, 100, '100
4. (갱신계약 제1회 보험료의 납입이 연체되는 경우 납입최고(독촉)와 계약
의 해지) 
계약자가 갱신계약의 제1회 보험료를 갱신일까지 납입하지 않은 때에는 회사는 보통
약관 28.(보험료 납입연체시 납입최고(독촉)와 계약의 해지)에 따라 계약자에게 최고
(독촉)하고 이 납입최고(독촉)기간 안에 갱신계약 보험료가 납입되지 않은 경우 납입
최고(독촉)기간이 끝나는 날의 다음날 갱신계약은 해지됩니다. 다만, 납입최고(독촉)
기간 안에 발생한 사고에 대하여 회사는 약정한 보험금을 지급합니다. 이 경우 계약
자는 즉시 갱신계약 보험료를 납입하여야 하며, 이 보험료를 납입하지 않으면 회사는 
지급할 보험금에서 이를 공제할 수 있습니다.
5. (준용규정)
이 특별약관에 정하지 않은 사항은 보통약관 및 해당 갱신형 특별약관을 따릅니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (234, 4, 101, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
101
【별표1】 보험금을 지급할 때의 적립이율 계산
구분
기간
지급이자
(보험금의 지급사유)의
보험금 
및 
(계약의 소멸)의 
책임준비금
지급기일의 다음 날부터 
30일 이내 기간
보험계약대출이율
지급기일의 31일이후부터 
60일이내 기간
보험계약대출이율+ 
가산이율(4.0%)
지급기일의 61일이후부터 
90일이내 기간
보험계약대출이율+ 
가산이율(6.0%)
지급기일의 91일이후 기간
보험계약대출이율+ 
가산이율(8.0%)
 만기환급금 및
해지환급금
지급사유가 발생한 날의 
다음날부터 청구일까지의 기간
1년이내 : 공시이율의  
50%
1년초과기간 : 1%
청구일의 다음날부터 
지급일까지의 기간
보험계약대출이율
주) 1. 만기환급금은 회사가 보험금의 지급시기 도래 7일 이전에 지급할 사유와 금액
을 알리지 않은 경우, 지급사유가 발생한 날의 다음 날부터 청구일까지의 기
간은 공시이율을 적용한 이자를 지급합니다.
    2. 지급이자의 계산은 연단위 복리로 계산하며, 금리연동형보험은 일자 계산합니
다.
    3. 계약자 등의 책임 있는 사유로 보험금 지급이 지연된 때에는 그 해당기간에 
대한 이자는 지급되지 않을 수 있습니다.
    4. 가산이율 적용시 보통약관 8.(보험금의 지급절차)의 󰊲, ① 내지 ⑥ 의 어느 
하나에 해당되는 사유로 지연된 경우에는 해당기간에 대하여 가산이율을 적
용하지 않습니다.
    5. 가산이율 적용시 금융위원회 또는 금융감독원이 정당한 사유로 인정하는 경
우에는 해당 기간에 대하여 가산이율을 적용하지 않습니다.
【별표2】 장해분류표
󰊱총칙
1. 장해의 정의
1) ‘장해’라 함은 상해 또는 질병에 대하여 치유된 후 신체에 남아 있는 영구적인 
정신 또는 육체의 훼손상태를 말한다. 다만, 질병과 부상의 주증상과 합병증상 
및 이에 대한 치료를 받는 과정에서 일시적으로 나타나는 증상은 장해에 포함
되지 않는다.
2) ‘영구적’이라 함은 원칙적으로 치유하는 때 장래 회복할 가망이 없는 상태로서 
정신적 또는 육체적 훼손상태임이 의학적으로 인정되는 경우를 말한다.
3) ‘치유된 후’라 함은 상해 또는 질병에 대한 치료의 효과를 기대할 수 없게 되고 
또한 그 증상이 고정된 상태를 말한다.
4) 다만, 영구히 고정된 증상은 아니지만 치료 종결 후 한시적으로 나타나는 장해
에 대하여는 그 기간이 5년 이상인 경우 해당 장해지급률의 20%를 한시장해 
지급률로 정합니다.
2. 신체부위
‘신체부위’라 함은 ① 눈 ② 귀 ③ 코 ④ 씹어먹거나 말하는 기능 ⑤ 외모 ⑥ 척추(등
뼈) ⑦ 체간골 ⑧ 팔 ⑨ 다리 󰊉
󰊒
󰊉 손가락 󰊉
󰊓 발가락 󰊉
󰊔 흉ㆍ복부장기 및 비뇨생식기 
󰊉
󰊕 신경계ㆍ정신행동의 13개 부위를 말하며, 이를 각각 동일한 신체부위라 한다. 다
만, 좌ㆍ우의 눈, 귀, 팔, 다리는 각각 다른 신체부위로 본다.
3. 기타
1) 하나의 장해가 관찰 방법에 따라서 장해분류표상 2가지 이상의 신체부위 또는 
동일한 신체부위에서, 하나의 장해에 다른 장해가 통상 파생하는 관계에 있는 
경우에는 각각 그중 높은 지급률만을 적용한다.
2) 동일한 신체부위에 2가지 이상의 장해가 발생한 경우에는 합산하지 않고 그 중 
높은 지급률을 적용함을 원칙으로 한다. 그러나 각 신체부위별 판정기준에서 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (235, 4, 102, '102
별도로 정한 경우에는 그 기준에 따른다.
3) 의학적으로 뇌사판정을 받고 호흡기능과 심장박동기능을 상실하여 인공심박동
기 등 장치에 의존하여 생명을 연장하고 있는 뇌사상태는 장해의 판정대상에 
포함되지 않는다. 
4) 장해진단서에는 ① 장해진단명 및 발생시기 ② 장해의 내용과 그 정도 ③ 사고
와의 인과관계 및 사고의 관여도 ④ 향후 치료의 문제 및 호전도를 필수적으로 
기재해야 한다. 다만, 신경계ㆍ정신행동 장해의 경우 ① 개호(장해로 혼자서 활
동이 어려운 사람을 곁에서 돌보는 것) 여부 ② 객관적 이유 및 개호의 내용을 
추가로 기재하여야 한다.
󰊲장해분류별 판정기준
1. 눈의 장해
가. 장해의 분류
장해의 분류
지급률(%)
 1) 두눈이 멀었을 때
 2) 한눈이 멀었을 때
 3) 한눈의 교정시력이  0.02 이하로 된 때
 4) 한눈의 교정시력이  0.06 이하로 된 때
 5) 한눈의 교정시력이  0.1  이하로 된 때
 6) 한눈의 교정시력이  0.2  이하로 된 때
 7) 한눈의 안구에 뚜렷한 운동장해나 뚜렷한 조절기능장해를 남긴 때
 8) 한눈의 시야가 좁아지거나 반맹증, 시야협착, 암점을 남긴 때
 9) 한눈의 눈꺼풀에 뚜렷한 결손을 남긴 때
10) 한눈의 눈꺼풀에 뚜렷한 운동장해를 남긴 때
100
50
35
25
15
5
10
5
10
5
나. 장해판정기준
1) 시력장해의 경우 공인된 시력검사표에 따라 측정한다.
2) ‘교정시력’이라 함은 안경(콘택트렌즈를 포함한 모든 종류의 시력 교정수단)으로 
교정한 시력을 말한다.
3) ‘한 눈이 멀었을 때’라 함은 눈동자의 적출은 물론 명암을 가리지 못하거나(‘광
각무’) 겨우 가릴 수 있는 경우(‘광각’)를 말한다.
4) 안구운동장해의 판정은 외상 후 1년 이상이 지난 뒤 그 장해정도를 평가한다.
5) ‘안구의 뚜렷한 운동장해’라 함은 안구의 주시야(머리를 움직이지 않고 눈만을 
움직여서 볼 수 있는 범위)의 운동범위가 정상의 1/2 이하로 감소된 경우나 정
면 양안시(두 눈으로 하나의 사물을 보는 것)에서 복시(물체가 둘로 보이거나 
겹쳐 보임)를 남긴 때를 말한다.
6) ‘안구의 뚜렷한 조절기능장해’라 함은 조절력이 정상의 1/2 이하로 감소된 경우
를 말한다. 다만, 조절력의 감소를 무시할 수 있는 45세 이상의 경우에는 제외
한다.
7) ‘시야가 좁아진 때’라 함은 시야각도의 합계가 정상시야의 60% 이하로 제한된 
경우를 말한다.
8) ‘눈꺼풀에 뚜렷한 결손을 남긴 때’라 함은 눈꺼풀의 결손으로 눈을 감았을 때 
각막(검은 자위)이 완전히 덮이지 않는 경우를 말한다.
9) ‘눈꺼풀에 뚜렷한 운동장해를 남긴 때’라 함은 눈을 떴을 때 동공을 1/2 이상 
덮거나 또는 눈을 감았을 때 각막을 완전히 덮을 수 없는 경우를 말한다.
10) 외상이나 화상 등으로 눈동자의 적출이 불가피한 경우에는 외모의 추상(추한 
모습)이 가산된다. 이 경우 눈동자가 적출되어 눈자위의 조직요몰(凹沒) 등으
로 의안마저 끼워 넣을 수 없는 상태이면 ‘뚜렷한 추상(추한 모습)’으로, 의안
을 끼워 넣을 수 있는 상태이면 ‘약간의 추상(추한 모습)’으로 지급률을 가산
한다.
11) ‘눈꺼풀에 뚜렷한 결손을 남긴 때’에 해당하는 경우에는 추상(추한 모습)장해
를 포함하여 장해를 평가한 것으로 보고 추상(추한 모습)장해를 가산하지 않
는다. 다만, 안면부의 추상(추한 모습)은 두 가지 장해평가 방법 중 피보험자
에게 유리한 것을 적용한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (236, 4, 103, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
103
2. 귀의 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 두귀의 청력을 완전히 잃었을 때
2) 한귀의 청력을 완전히 잃고, 다른 귀의 청력에 심한 장해를 남긴 때
3) 한귀의 청력을 완전히 잃었을 때
4) 한귀의 청력에 심한 장해를 남긴 때
5) 한귀의 청력에 약간의 장해를 남긴 때
6) 한귀의 귓바퀴의 대부분이 결손된 때
80
45
25
15
5
10
나. 장해판정기준
1) 청력장해는 순음청력검사 결과에 따라 데시벨(dB: decibel)로서 표시하고 3회 
이상 청력검사를 실시한 후 순음평균역치에 따라 적용한다.
2) ‘한 귀의 청력을 완전히 잃었을 때’라 함은 순음청력검사 결과 평균순음역치가 
90dB 이상인 경우를 말한다.
3) ‘심한 장해를 남긴 때’라 함은 순음청력검사 결과 평균순음역치가 80dB 이상인 
경우에 해당되어, 귀에다 대고 말하지 않고는 큰 소리를 알아듣지 못하는 경우
를 말한다.
4) ‘약간의 장해를 남긴 때’라 함은 순음청력검사 결과 평균순음역치가 70dB 이상
인 경우에 해당되어, 50cm 이상의 거리에서는 보통의 말소리를 알아듣지 못하
는 경우를 말한다.
5) 순음청력검사를 실시하기 곤란하거나 검사결과에 대한 검증이 필요한 경우에는 
‘언어청력검사, 임피던스 청력검사, 뇌간유발반응청력검사(ABR), 자기청력계기
검사, 이음향방사검사’ 등을 추가실시 후 장해를 평가한다.
다. 귓바퀴의 결손
1) ‘귓바퀴의 대부분이 결손된 때’라 함은 귓바퀴의 연골부가 1/2 이상 결손된 경
우를 말하며, 귓바퀴의 결손이 1/2 미만이고 기능에 문제가 없으면 외모의 추
상(추한 모습)장해로 평가한다.
3. 코의 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 코의 기능을 완전히 잃었을 때
15
나. 장해판정기준
1) ‘코의 기능을 완전히 잃었을 때’라 함은 양쪽 코의 호흡곤란 또는 양쪽 코의 후각
기능을 완전히 잃은 경우를 말하며, 후각감퇴는 장해의 대상으로 하지 않는다.
2) 코의 추상(추한 모습)장해를 수반한 때에는 기능장해와 각각 합산하여 지급한다.
4. 씹어먹거나 말하는 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 씹어먹는 기능과 말하는 기능 모두에 심한 장해를 남긴 때
2) 씹어먹는 기능 또는 말하는 기능에 심한 장해를 남긴 때
3) 씹어먹는 기능과 말하는 기능 모두에 뚜렷한 장해를 남긴 때
4) 씹어먹는 기능 또는 말하는 기능에 뚜렷한 장해를 남긴 때
5) 씹어먹는 기능과 말하는 기능 모두에 약간의 장해를 남긴 때
6) 씹어먹는 기능 또는 말하는 기능에 약간의 장해를 남긴 때
7) 치아에 14개 이상의 결손이 생긴 때
8) 치아에 7개 이상의 결손이 생긴 때
9) 치아에 5개 이상의 결손이 생긴 때
100
80
40
20
10
5
20
10
5
 
나. 장해의 평가기준
1) 씹어먹는 기능의 장해는 윗니와 아랫니의 맞물림(교합), 배열상태 및 아래턱의 
개폐운동, 연하(삼킴)운동 등에 따라 종합적으로 판단하여 결정한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (237, 4, 104, '104
2) ‘씹어먹는 기능에 심한 장해를 남긴 때’라 함은 물이나 이에 준하는 음료 이외
는 섭취하지 못하는 경우를 말한다.
3) ‘씹어먹는 기능에 뚜렷한 장해를 남긴 때’라 함은 미음 또는 이에 준하는 정도
의 음식물(죽 등) 외는 섭취하지 못하는 경우를 말한다.
4) ‘씹어먹는 기능에 약간의 장해를 남긴 때’라 함은 어느 정도의 고형식(밥, 빵 
등)은 섭취할 수 있으나 이를 씹어 잘게 부수는 기능에 제한이 뚜렷한 경우를 
말한다.
5) ‘말하는 기능에 심한 장해를 남긴 때’라 함은 다음 4종의 어음 중 3종 이상의 
발음을 할 수 없게 된 경우를 말한다.
① 양순음/입술소리(ㅁ, ㅂ, ㅍ)
② 치조음/잇몸소리(ㄴ, ㄷ, ㄹ)
③ 구개음/입천장소리(ㄱ, ㅈ, ㅊ)
④ 후두음/목구멍소리(ㅇ, ㅎ)
6) ‘말하는 기능에 뚜렷한 장해를 남긴 때’라 함은 위 5)의 4종의 어음 중 2종 이
상의 발음을 할 수 없는 경우를 말한다.
7) ‘말하는 기능에 약간의 장해를 남긴 때’라 함은 위 5)의 4종의 어음 중 1종의 
발음을 할 수 없는 경우를 말한다.
8) 뇌의 언어중추 손상에 따른 실어증도 말하는 기능의 장해로 평가한다.
9) ‘치아의 결손’이란 치아의 상실 또는 치아의 신경이 죽었거나 1/3 이상이 파절
(깨짐, 부러짐)된 경우를 말한다.
10) 유상의치 또는 가교의치 등을 보철한 경우의 지대관 또는 구의 장착치와 포스
트, 인레인만을 한 치아는 결손된 치아로 인정하지 않는다.
11) 상실된 치아의 크기가　크든지　또는 치간의 간격이나 치아 배열구조 등의 문
제로 사고와 관계없이 새로운 치아가 결손된 경우에는 사고로 결손된 치아 수
에 따라 지급률을 결정한다.
12) 어린이의 유치와 같이 새로 자라서 갈 수 있는 치아는 후유장해의 대상이 되
지 않는다.
13) 신체의 일부에 붙였다 떼었다 할 수 있는 의치의 결손은 후유장해의 대상이 
되지 않는다.
5. 외모의 추상(추한 모습)장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 외모에 뚜렷한 추상(추한 모습)을 남긴 때
2) 외모에 약간의 추상(추한 모습)을 남긴 때
15
5
나. 장해판정기준
1) ‘외모’란 얼굴(눈, 코, 귀, 입 포함), 머리, 목을 말한다.
2) ‘추상(추한 모습)장해’라 함은 성형수술 후에도 영구히 남게 되는 상태의 추상
(추한 모습)을 말하며, 재건수술로 흉터를 줄일 수 있는 경우는 제외한다.
3) ‘추상(추한 모습)을 남긴 때’라 함은 상처의 흔적, 화상 등으로 피부의 변색, 모
발의 결손, 조직(뼈, 피부 등)의 결손 및 함몰 등으로 성형수술을 하여도 더 이
상 추상(추한 모습)이 없어지지 않는 경우를 말한다.
다. 뚜렷한 추상(추한 모습)
1) 얼굴
① 손바닥 크기 1/2 이상의 추상(추한 모습)
② 길이 10cm 이상의 추상 반흔(추한 모습의 흉터) 
③ 지름 5cm 이상의 조직함몰
④ 코의 1/2 이상 결손
2) 머리
① 손바닥 크기 이상의 반흔(흉터) 및 모발결손
② 머리뼈의 손바닥 크기 이상의 손상 및 결손
3) 목
손바닥 크기 이상의 추상(추한 모습)
라. 약간의 추상(추한 모습)
1) 얼굴
① 손바닥 크기 1/4 이상의 추상(추한 모습)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (238, 4, 105, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
105
② 길이 5cm 이상의 추상반흔(추한 모습의 흉터) 
③ 지름 2cm 이상의 조직함몰
④ 코의 1/4 이상 결손 
2) 머리
① 손바닥 1/2 크기 이상의 반흔(흉터), 모발결손
② 머리뼈의 손바닥 1/2 크기 이상의 손상 및 결손
3) 목
손바닥 크기 1/2 이상의 추상(추한 모습)
마. 손바닥 크기
‘손바닥 크기’라 함은 해당 환자의 손가락을 제외한 손바닥의 크기를 말하며, 12세 이
상의 성인에서는 8×10㎝(1/2 크기는 40㎠, 1/4 크기는 20㎠), 6～11세의 경우는 
6×8㎝(1/2 크기는 24㎠, 1/4 크기는 12㎠), 6세 미만의 경우는 4×6㎝(1/2 크기는 
12㎠, 1/4 크기는 6㎠)로 간주한다.
6. 척추(등뼈)의 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 척추(등뼈)에 심한 운동장해를 남긴 때
2) 척추(등뼈)에 뚜렷한 운동장해를 남긴 때
3) 척추(등뼈)에 약간의 운동장해를 남긴 때
4) 척추(등뼈)에 심한 기형을 남긴 때 
5) 척추(등뼈)에 뚜렷한 기형을 남긴 때
6) 척추(등뼈)에 약간의 기형을 남긴 때  
7) 심한 추간판탈출증(속칭 디스크)
8) 뚜렷한 추간판탈출증(속칭 디스크)
9) 약간의 추간판탈출증(속칭 디스크)
40
30
10
50
30
15
20
15
10
나. 장해판정기준
1) 척추(등뼈)는 경추(목뼈) 이하를 모두 동일한 부위로 한다.
2) 척추(등뼈)의 장해는 퇴행성 기왕증 병변과 사고가 그 증상을 악화시킨 부분만
큼, 즉 이 사고와의 관여도를 산정하여 평가한다.
3) 심한 운동장해
   척추체(척추뼈 몸통)에 골절 또는 탈구로 4개 이상의 척추체(척추뼈 몸통)를 유
합(아물어 붙음) 또는 고정한 상태
4) 뚜렷한 운동장해
① 척추체(척추뼈 몸통)에 골절 또는 탈구로 3개의 척추체(척추뼈 몸통)를 유
합(아물어 붙음) 또는 고정한 상태 
② 머리뼈와 상위경추(상위목뼈: 제1, 2목뼈) 사이에 뚜렷한 이상전위가 있을 
때
5) 약간의 운동장해
   척추체(척추뼈 몸통)에 골절 또는 탈구로 2개의 척추체(척추뼈 몸통)를 유합(아
물어 붙음) 또는 고정한 상태
6) 심한 기형
   척추의 골절 또는 탈구 등으로 35° 이상의 척추전만증(척추가 앞으로 휘어지는 
증상), 척추후만증(척추가 뒤로 휘어지는 증상) 또는 20° 이상의 척추측만증(척
추가 옆으로 휘어지는 증상) 변형이 있을 때
7) 뚜렷한 기형
   척추의 골절 또는 탈구 등으로 15° 이상의 척추전만증(척추가 앞으로 휘어지는 
증상), 척추후만증(척추가 뒤로 휘어지는 증상) 또는 10° 이상의 척추측만증(척
추가 옆으로 휘어지는 증상) 변형이 있을 때
8) 약간의 기형
   1개 이상의 척추의 골절 또는 탈구로 경도(가벼운 정도)의 척추전만증(척추가 
앞으로 휘어지는 증상), 척추후만증(척추가 뒤로 휘어지는 증상) 또는 척추측만
증(척추가 옆으로 휘어지는 증상) 변형이 있을 때
9) 심한 추간판탈출증(속칭 디스크)
   추간판탈출증(속칭 디스크)으로 추간판을 2마디 이상 수술하거나 하나의 추간
판이라도 2회 이상 수술하고 마미신경증후군이 발생하여 하지의 현저한 마비 
또는 대소변의 장해가 있는 경우
10) 뚜렷한 추간판탈출증(속칭 디스크)
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (239, 4, 106, '106
   추간판 1마디를 수술하여 신경증상이 뚜렷하고 특수 보조검사에서 이상이 있으
며, 척추신경근의 불완전 마비가 인정되는 경우
11) 약간의 추간판탈출증(속칭 디스크)
    특수검사(뇌전산화단층촬영(Brain CT Scan), 자기공명영상(MRI) 등)에서 추간
판 병변이 확인되고 의학적으로 인정할 만한 하지방사통(주변부위로 뻗치는 
증상) 또는 감각 이상이 있는 경우
12) 추간판탈출증(속칭 디스크)으로 진단된 경우에는 수술 여부에 관계없이 운동
장해 및 기형장해로 평가하지 않는다.
7. 체간골의 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 어깨뼈나 골반뼈에 뚜렷한 기형을 남긴 때
2) 빗장뼈, 가슴뼈, 갈비뼈에 뚜렷한 기형을 남긴 때
15
10
나. 장해판정기준
1) ‘체간골’이라 함은 어깨뼈, 골반뼈, 빗장뼈, 가슴뼈, 갈비뼈를 말하며, 이를 모두 
동일한 부위로 한다.
2) ‘골반뼈의 뚜렷한 기형’이라 함은 아래와 같다.
① 천장관절 또는 치골문합부가 분리된 상태로 치유되었거나 좌골이 2.5cm 
이상 분리된 부정유합 상태 또는 여자에게 정상분만에 지장을 줄 정도로 
골반의 변형이 남은 상태
② 알몸이 되었을 때 변형(결손을 포함)을 명백하게 알 수 있을 정도를 말하
며, 방사선 검사로 측정한 각 변형이 20° 이상인 경우
3) ‘빗장뼈, 가슴뼈, 갈비뼈 또는 어깨뼈에 뚜렷한 기형이 남은 때’라 함은 알몸이 
되었을 때 변형(결손을 포함)을 명백하게 알 수 있을 정도를 말하며, 방사선 검
사로 측정한 각 변형이 20° 이상인 경우를 말한다.
4) 갈비뼈의 기형은 그 개수와 정도, 부위 등에 관계없이 전체를 일괄하여 하나의 
장해로 취급한다.
8. 팔의 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 두 팔의 손목 이상을 잃었을 때
2) 한 팔의 손목 이상을 잃었을 때
3) 한 팔의 3대 관절 중 관절 하나의 기능을 완전히 잃었을 때
4) 한 팔의 3대 관절 중 관절 하나의 기능에 심한 장해를 남긴 때
5) 한 팔의 3대 관절 중 관절 하나의 기능에 뚜렷한 장해를 남긴 때
6) 한 팔의 3대 관절 중 관절 하나의 기능에 약간의 장해를 남긴 때
7) 한 팔에 가관절이 남아 뚜렷한 장해를 남긴 때
8) 한 팔에 가관절이 남아 약간의 장해를 남긴 때
9) 한 팔의 뼈에 기형을 남긴 때
100
60
30
20
10
5
20
10
5
나. 장해판정기준
1) 골절부에 금속내고정물 등을 사용하였기 때문에 그것이 기능장해의 원인이 되
는 때에는 그 내고정물 등이 제거된 후 장해를 판정한다.
2) 관절을 사용하지 않아 발생한 기능장해(예컨대 석고붕대(cast)로 환부를 고정시
켰기 때문에 치유 후의 관절에 기능장해가 생긴 경우)와 일시적인 장해는 장해
보상을 하지 않는다.
3) ‘팔’이라 함은 어깨관절(肩關節)부터 손목관절까지를 말한다.
4) ‘팔의 3대 관절’이라 함은 어깨관절, 팔꿈치관절 및 손목관절을 말한다.
5) ‘한 팔의 손목 이상을 잃었을 때’라 함은 손목관절부터 심장에 가까운 쪽에서 
절단된 때를 말하며, 팔꿈치 관절 상부에서 절단된 경우도 포함된다.
6) 팔의 관절기능장해 평가는 팔의 3대 관절의 관절운동범위 제한 등으로 평가한
다. 각 관절의 운동범위 측정은 미국의사협회(A.M.A.) ‘영구적 신체장해 평가
지침’의 정상각도 및 측정방법 등을 따르며, 관절기능장해를 표시할 경우에는 
장해부위의 장해각도와 정상부위의 측정치를 동시에 판단하여 장해상태를 명확
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (240, 4, 107, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
107
히 한다.
가) ‘기능을 완전히 잃었을 때’라 함은 
   ① 완전 강직(관절굳음) 또는 인공관절이나 인공골두를 삽입한 경우
   ② 근전도 검사상 완전마비 소견이 있고 근력검사에서 근력이 ‘0등급
(Zero)’인 경우
나) ‘심한 장해’라 함은 
   ① 해당 관절의 운동범위 합계가 정상 운동범위의 1/4 이하로 제한된 경우
   ② 근전도 검사상 심한 마비 소견이 있고 근력검사에서 근력이 ‘1등급
(Trace)’인 경우
다) ‘뚜렷한 장해’라 함은 
   ① 해당 관절의 운동범위 합계가 정상 운동범위의 1/2 이하로 제한된 경우
라) ‘약간의 장해’라 함은 
   ① 해당 관절의 운동범위 합계가 정상 운동범위의 3/4 이하로 제한된 경우
7) ‘가관절이 남아 뚜렷한 장해를 남긴 때’라 함은 상완골에 가관절이 남은 경우 
또는 요골과 척골의 2개 뼈 모두에 가관절이 남은 경우를 말한다.
8) ‘가관절이 남아 약간의 장해를 남긴 때’라 함은 요골과 척골 중 어느 한 뼈에 
가관절이 남은 경우를 말한다.
9) ‘뼈에 기형을 남긴 때’라 함은 상완골 또는 요골과 척골에 변형이 남아 정상에 
비해 부정유합된 각 변형이 15° 이상인 경우를 말한다.
다. 지급률의 결정
1) 1상지(팔과 손가락)의 후유장해지급률은 원칙적으로 각각 합산하되, 지급률은 
60% 한도로 한다.
2) 한 팔의 3대 관절 중 관절 하나에 기능장해가 생기고 다른 관절 하나에 기능장
해가 발생한 경우 지급률은 각각 적용하여 합산한다.
9. 다리의 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 두 다리의 발목 이상을 잃었을 때
2) 한 다리의 발목 이상을 잃었을 때
3) 한 다리의 3대 관절 중 관절 하나의 기능을 완전히 잃었을 때
4) 한 다리의 3대 관절 중 관절 하나의 기능에 심한 장해를 남긴 때
5) 한 다리의 3대 관절 중 관절 하나의 기능에 뚜렷한 장해를 남긴 때
6) 한 다리의 3대 관절 중 관절 하나의 기능에 약간의 장해를 남긴 때
7) 한 다리에 가관절이 남아 뚜렷한 장해를 남긴 때
8) 한 다리에 가관절이 남아 약간의 장해를 남긴 때
9) 한 다리의 뼈에 기형을 남긴 때
10) 한 다리가 5cm 이상 짧아진 때
11) 한 다리가 3cm 이상 짧아진 때
12) 한 다리가 1cm 이상 짧아진 때
100
60
30
20
10
5
20
10
5
30
15
5
나. 장해판정기준
1) 골절부에 금속내고정물 등을 사용하였기 때문에 그것이 기능장해의 원인이 되
는 때에는 그 내고정물 등이 제거된 후 장해를 판정한다.
2) 관절을 사용하지 않아 발생한 기능장해(예컨대 석고붕대(cast)로 환부를 고정시
켰기 때문에 치유 후의 관절에 기능장해가 생긴 경우)와 일시적인 장해는 장해
보상을 하지 않는다.
3) ‘다리’라 함은 엉덩이관절〔股關節〕부터 발목관절까지를 말한다.
4) ‘다리의 3대 관절’이라 함은 고관절, 무릎관절 및 발목관절을 말한다.
5) ‘한 다리의 발목 이상을 잃었을 때’라 함은 발목관절부터 심장에 가까운 쪽에서 
절단된 때를 말하며, 무릎관절의 상부에서 절단된 경우도 포함된다.
6) 다리의 관절기능장해 평가는 하지의 3대 관절의 관절운동범위 제한 및 동요성 
유무 등으로 평가한다. 각 관절의 운동범위 측정은 미국의사협회(A.M.A.) ‘영
구적 신체장해 평가지침’의 정상각도 및 측정방법 등을 따르며, 관절기능장해를 
표시할 경우에는 장해부위의 장해각도와 정상부위의 측정치를 동시에 판단하여 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (241, 4, 108, '108
장해상태를 명확히 한다.
가) ‘기능을 완전히 잃었을 때’라 함은
   ① 완전 강직(관절굳음) 또는 인공관절이나 인공골두를 삽입한 경우
   ② 근전도 검사상 완전마비 소견이 있고 근력검사에서 근력이 ‘0등급(Zero)’인 
경우
나) ‘심한 장해’라 함은 
   ① 해당 관절의 운동범위 합계가 정상 운동범위의 1/4 이하로 제한된 경우
   ② 객관적 검사(스트레스 엑스선)상 15mm 이상의 동요관절(관절이 흔들리거
나 움직이는  것)이 있는 경우
   ③ 근전도 검사상 심한 마비 소견이 있고 근력검사에서 근력이 ‘1등급(Trace)’
인 경우
다) ‘뚜렷한 장해’라 함은 
   ① 해당 관절의 운동범위 합계가 정상 운동범위의 1/2 이하로 제한된 경우
   ② 객관적 검사(스트레스 엑스선)상 10mm 이상의 동요관절(관절이 흔들리거
나 움직이는 것)이 있는 경우
라) ‘약간의 장해’라 함은 
   ① 해당 관절의 운동범위 합계가 정상 운동범위의 3/4 이하로 제한된 경우
   ② 객관적 검사(스트레스 엑스선)상 5mm 이상의 동요관절(관절이 흔들리거나 
움직이는 것)이 있는 경우
7) ‘가관절이 남아 뚜렷한 장해를 남긴 때’라 함은 대퇴골에 가관절이 남은 경우 
또는 경골과 종아리뼈의 2개 뼈 모두에 가관절이 남은 경우를 말한다.
8) ‘가관절이 남아 약간의 장해를 남긴 때’라 함은 경골과 종아리뼈 중 어느 한 뼈
에 가관절이 남은 경우를 말한다.
9) ‘뼈에 기형을 남긴 때’라 함은 대퇴골 또는 경골에 기형이 남아 정상에 비해 부
정유합된 각 변형이 15° 이상인 경우를 말한다.
10) 다리의 단축은 상전장골극에서부터 경골 내측과 하단까지의 길이를 측정하여 
정상인 쪽 다리의 길이와 비교하여 단축된 길이를 산출한다.
    다리 길이의 측정에 이용하는 골표적(bony landmark)이 명확하지 않은 경우
나 다리의 단축장해 판단이 애매한 경우에는 스캐노그램(scanogram)으로 다리
의 단축 정도를 측정한다.
다. 지급률의 결정
1) 1하지(다리와 발가락)의 후유장해지급률은 원칙적으로 각각 합산하되, 지급률은 
60% 한도로 한다.
2) 한 다리의 3대 관절 중 관절 하나에 기능장해가 생기고 다른 관절 하나에 기능
장해가 발생한 경우 지급률은 각각 적용하여 합산한다.
10. 손가락의 장해
가. 장해의 분류  
장해의 분류
지급률(%)
1) 한손의 5개손가락을 모두 잃었을 때
2) 한손의 첫째 손가락을 잃었을 때
3) 한손의 첫째 손가락 이외의 손가락을 잃었을 때(손가락 하나마다)
4) 한손의 5개손가락 모두의 손가락뼈 일부를 잃었을 때 또는 
뚜렷한 장해를 남긴 때
5) 한손의 첫째 손가락의 손가락뼈 일부를 잃었을 때 또는 뚜렷한 
장해를 남긴 때
6) 한손의 첫째 손가락 이외의 손가락의 손가락뼈 일부를 잃었을 때 
또는 뚜렷한 장해를 남긴 때(손가락 하나마다)
55
15
10
30
10
5
나. 장해판정기준
1) 손가락에는 첫째 손가락에 2개의 손가락관절이 있다. 그중 심장에서 가까운 쪽
부터 중수지관절, 지관절이라 한다.
2) 다른 네 손가락에는 3개의 손가락관절이 있다. 그중 심장에서 가까운 쪽부터 
중수지관절, 제1지관절(근위지관절) 및 제2지관절(원위지관절)이라 부른다.
3) ‘손가락을 잃었을 때’라 함은 첫째 손가락에서는 지관절부터 심장에서 가까운 
쪽에서, 다른 네 손가락에서는 제1지관절(근위지관절)부터 심장에서 가까운 쪽
으로 손가락을 잃었을 때를 말한다.
4) ‘손가락뼈 일부를 잃었을 때’라 함은 첫째 손가락의 지관절, 다른 네 손가락의 
제1지관절(근위지관절)부터 심장에서 먼 쪽으로 손가락뼈를 잃었거나 뼛조각이 
떨어져 있는 것이 엑스선 사진으로 명백한 경우를 말한다.
5) ‘손가락에 뚜렷한 장해를 남긴 때’라 함은 손가락의 생리적 운동영역이 정상 운
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (242, 4, 109, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
109
동가능영역의 1/2 이하가 되었을 때이며 이 경우 손가락관절의 굴신(굽히고 펴
기)운동 가능영역으로 측정한다. 첫째 손가락 이외의 다른 네 손가락에서는 제
1, 제2지관절의 굴신(굽히고 펴기)운동영역을 합산하여 정상 운동영역의 1/2 
이하인 경우를 말한다.
6) 한 손가락에 장해가 생기고 다른 손가락에 장해가 발생한 경우, 지급률은 각각 
적용하여 합산한다.
11. 발가락의 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 한 발의 리스프랑관절 이상을 잃었을 때
2) 한 발의 5개 발가락을 모두 잃었을 때
3) 한 발의 첫째 발가락을 잃었을 때
4) 한 발의 첫째 발가락 이외의 발가락을 잃었을 때(발가락 하나마다)
5) 한 발의 5개 발가락 모두의 발가락뼈 일부를 잃었을 때 또는 
뚜렷한 장해를 남긴 때
6) 한 발의 첫째 발가락의 발가락뼈 일부를 잃었을 때 또는 뚜렷한 
장해를 남긴 때
7) 한 발의 첫째 발가락 이외의 발가락의 발가락뼈 일부를 잃었을 때 
또는 뚜렷한 장해를 남긴 때(발가락 하나마다)
40
30
10
5
20
8
3
나. 장해판정기준
1) ‘발가락을 잃었을 때’라 함은 첫째 발가락에서는 지관절부터 심장에 가까운 쪽
을, 나머지 네 발가락에서는 제1지관절(근위지관절)부터 심장에서 가까운 쪽을 
잃었을 때를 말한다.
2) 리스프랑 관절 이상에서 잃은 때라 함은 족근-중족골간 관절 이상에서 절단된 
경우를 말한다.
3) ‘발가락뼈 일부를 잃었을 때’라 함은 첫째 발가락에서는 지관절, 다른 네 발가락
에서는 제1지관절(근위지관절)부터 심장에서 먼 쪽에서 발가락뼈를 잃었을 때
를 말하고 단순히 살점이 떨어진 것만으로는 대상이 되지 않는다.
4) ‘발가락에 뚜렷한 장해를 남긴 때’라 함은 발가락의 생리적 운동영역이 정상 운
동 가능영역의 1/2 이하가 되었을 때를 말하며, 이 경우 발가락의 주된 기능인 
발가락 관절의 굴신(굽히고 펴기)기능을 측정하여 결정한다.
5) 한 발가락에 장해가 생기고 다른 발가락에 장해가 발생한 경우, 지급률은 각각 
적용하여 합산한다.
12. 흉․복부장기 및 비뇨생식기의 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 흉복부장기 또는 비뇨생식기 기능에 심한 장해를 남긴 때
2) 흉복부장기 또는 비뇨생식기 기능에 뚜렷한 장해를 남긴 때
3) 흉복부장기 또는 비뇨생식기 기능에 약간의 장해를 남긴 때
75
50
20
나. 장해의 판정기준
1) ‘흉복부장기 또는 비뇨생식기 기능에 심한 장해를 남긴 때’라 함은  
① 심장, 폐, 신장, 또는 간장의 장기이식을 한 경우
② 장기이식을 하지 않고서는 생명유지가 불가능하여 혈액투석 등 의료처치를 
평생토록 받아야 할 때
③ 방광의 기능이 완전히 없어진 때
2) ‘흉복부장기 또는 비뇨생식기 기능에 뚜렷한 장해를 남긴 때’라 함은 
① 위, 대장 또는 췌장의 전부를 잘라내었을 때
② 소장 또는 간장의 3/4 이상을 잘라내었을 때
③ 양쪽 고환 또는 양쪽 난소를 모두 잃었을 때
3) ‘흉복부장기 또는 비뇨생식기 기능에 약간의 장해를 남긴 때’라 함은
① 비장 또는 한쪽의 신장이나 한쪽의 폐를 잘라내었을 때
② 장루, 요도루, 방광누공, 요관 장문합이 남았을 때
③ 방광의 용량이 50cc 이하로 위축되었거나 요도협착으로 인공요도가 필요한 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (243, 4, 110, '110
때
④ 음경의 1/2 이상이 결손되었거나 질구 협착 등으로 성생활이 불가능한 때
⑤ 항문 괄약근의 기능장해로 인공항문을 설치한 경우(치료과정에서 일시적으
로 발생하는 경우는 제외)
4) 흉복부장기 또는 비뇨생식기의 장해로 일상생활 기본동작에 제한이 있는 경우 
‘<붙임> 일상생활 기본동작(ADLs) 제한 장해평가표’에 따라 장해를 평가하고 
둘 중 높은 지급률을 적용한다.
5) 장기간의 간병이 필요한 만성질환(만성간질환, 만성폐쇄성폐질환 등)은 장해의 
평가 대상으로 인정하지 않는다.
13. 신경계․정신행동 장해
가. 장해의 분류
장해의 분류
지급률(%)
1) 신경계에 장해가 남아 일상생활 기본동작에 제한을 남긴 때
2) 정신행동에 극심한 장해가 남아 타인의 지속적인 감시 또는 
감금상태에서 생활해야 할 때
3) 정신행동에 심한 장해가 남아 감금상태에서 생활할 정도는 아니나 
자해나 가해의 위험성이 지속적으로 있어서 부분적인 감시를 
요할 때
4) 정신행동에 뚜렷한 장해가 남아 대중교통을 이용한 이동, 장보기 
등의 기본적 사회 활동을 혼자서 할 수 없는 상태  
5) 극심한 치매 : CDR 척도 5점
6) 심한 치매 : CDR 척도 4점
7) 뚜렷한 치매 : CDR 척도 3점
8) 약간의 치매 : CDR 척도 2점
9) 심한 간질발작이 남았을 때
10) 뚜렷한 간질발작이 남았을 때
11) 약간의 간질발작이 남았을 때
10～100
100
70
40
100
80
60
40
70
40
10
나. 장해판정기준
1) 신경계
① ‘신경계에 장해를 남긴 때’라 함은 뇌, 척수 및 말초신경계 손상으로 ‘<붙
임> 일상생활 기본동작(ADLs) 제한 장해평가표’의 5가지 기본동작 중 하나 
이상의 동작이 제한되었을 때를 말한다.
② 위 ①의 경우 ‘<붙임> 일상생활 기본동작(ADLs) 제한 장해평가표’상 지급률
이 10% 미만인 경우에는 보장대상이 되는 장해로 인정하지 않는다.
③ 신경계의 장해로 발생하는 다른 신체부위의 장해(눈, 귀, 코, 팔, 다리 등)
는 해당 장해로도 평가하고 그중 높은 지급률을 적용한다. 
④ 뇌졸중, 뇌손상, 척수 및 신경계의 질환 등은 발병 또는 외상 후 6개월 동
안 지속적으로 치료한 후에 장해를 평가한다.
   그러나 6개월이 지났다고 하더라도 뚜렷하게 기능 향상이 진행되고 있는 
경우 또는 단기간 내에 사망이 예상되는 경우는 6개월의 범위에서 장해 평
가를 유보한다.
⑤ 장해진단 전문의는 재활의학과, 신경외과 또는 신경과 전문의로 한다.
2) 정신행동
① 위의 정신행동장해지급률에 미치지 않는 장해는 ‘<붙임> 일상생활 기본동작
(ADLs) 제한 장해평가표’에 따라 지급률을 산정하여 지급한다.
② 일반적으로 상해를 입고 나서 24개월이 지난 후에 판정함을 원칙으로 한
다. 다만, 상해를 입은 후 의식상실이 1개월 이상 지속된 경우에는 상해를 
입고 나서 18개월이 지난 후에 판정할 수 있다. 다만, 장해는 전문적 치료
를 충분히 받은 후 판정하여야 하며, 그렇지 않은 경우에는 그로써 고정되
거나 중하게 된 장해에 대해서는 인정하지 않는다.
③ 심리학적 평가보고서는 자격을 갖춘 임상심리전문가가 시행하고 전문의가 
작성하여야 한다.
④ 전문의란 정신건강의학과나 신경정신과 전문의를 말한다.
⑤ 평가의 객관적 근거
   ㉮ 뇌의 기능 및 결손을 입증할 수 있는 뇌자기공명촬영, 뇌전산화촬영, 뇌
파 등을 기초로 한다. 
   ㉯ 객관적 근거로 인정할 수 없는 경우
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (244, 4, 111, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
111
유형
제한정도
지급률(%)
이동동작
- 특별한 보조기구를 사용함에도 불구하고 다른 사람의 
계속적인 도움이 없이는 방 밖을 나올 수 없는 상태
- 휠체어 또는 다른 사람의 도움 없이는  방 밖을 나
올 수 없는 상태
- 목발 또는 보행기(walker)를 사용하지 않으면 독립
적인 보행이 불가능한 상태
- 독립적인 보행은 가능하나 파행이 있는(절뚝거리는) 
상태, 난간을 잡지 않고는 계단을 오르내리기가 불
가능한 상태, 계속하여 평지에서 100m 이상을 걷
지 못하는 상태
40
30
20
10
음식물 섭취
- 식사를 전혀 할 수 없어 계속적으로 튜브나 경정맥 
수액을 통해 부분 혹은 전적인 영양공급을 받는 상태
- 수저 사용이 불가능하여 다른 사람의 계속적인 도움
이 없이는 식사를 전혀 할 수 없는 상태
- 숟가락 사용은 가능하나 젓가락 사용이 불가능하여 
음식물 섭취에 있어 부분적으로 다른 사람의 도움이 
필요한 상태
- 독립적인 음식물 섭취는 가능하나 젓가락을 이용하
여 생선을 바르거나 음식물을 자르지는 못하는 상태
20
15
10
5
   - 보호자나 환자의 진술
   - 감정의의 추정이나 인정
   - 한국표준화가 이루어지지 않고 신빙성이 낮은 검사들(뇌SPECT 등)
   - 정신건강의학과나 신경정신과 전문의가 아닌 자가 시행하고 보고서를 작
성하는 심리학적 평가보고서
⑥ 각종 기질성 정신장해와 외상후 간질에 한하여 보상한다.
⑦ 외상후 스트레스장애, 우울증(반응성) 등의 질환, 정신분열증, 편집증, 조울
증(정서장애), 불안장애, 전환장애, 공포장애, 강박장애 등 각종 신경증 및 
각종 인격장애는 보상의 대상이 되지 않는다.
⑧ 정신 및 행동장해의 경우 개호인(장해로 혼자서 활동이 어려운 사람을 곁에
서 돌보는 사람)은 생명유지를 위한 동작과 행동이 불가능하거나 지속적으
로 감금해야 하는 상태에 한하여 인정한다. 개호의 내용에서는 생명유지를 
위한 개호와 행동감시를 위한 개호를 구별하여야 한다.
3) 치매
① ‘치매’라 함은 
   - 뇌 속에 후천적으로 생긴 기질적인 병으로 인한 변화 또는 뇌 속에 손상
을 입은 경우
   - 정상적으로 성숙한 뇌가 위의 기질성 장해로 파괴되어 한번 획득한 지능
이 지속적 또는 전반적으로 저하되는 경우
② 치매의 장해평가는 전문의에 의한 임상치매척도(한국판 Expanded Clinical 
Dementia Rating) 검사결과에 따른다.
4) 뇌전증(간질)
① ‘간질’이라 함은 돌발적 뇌파이상을 나타내는 뇌질환으로 발작(경련, 의식장
해 등)을 반복하는 것을 말한다.
② ‘심한 간질 발작’이라 함은 월 8회 이상의 중증발작이 연 6개월 이상의 기
간에 걸쳐 발생하고, 발작할 때 유발된 호흡장애, 흡인성 폐렴, 심한 탈진, 
구역질, 두통, 인지장해 등으로 요양관리가 필요한 상태를 말한다.
③ ‘뚜렷한 간질 발작’이라 함은 월 5회 이상의 중증발작 또는 월 10회 이상의 
경증발작이 연 6개월 이상의 기간에 걸쳐 발생하는 상태를 말한다.
④ ‘약간의 간질 발작’이라 함은 월 1회 이상의 중증발작 또는 월 2회 이상의 
경증발작이 연 6개월 이상의 기간에 걸쳐 발생하는 상태를 말한다.
⑤ ‘중증발작’이라 함은 전신경련을 동반하는 발작으로써 신체의 균형을 유지하
지 못하고 쓰러지는 발작 또는 의식장해가 3분 이상 지속되는 발작을 말한
다.
⑥ ‘경증발작’이라 함은 운동장해가 발생하나 스스로 신체의 균형을 유지할 수 
있는 발작 또는 3분 이내에 정상으로 회복되는 발작을 말한다.
<붙임> 일상생활 기본동작(ADLs) 제한 장해평가표
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (245, 4, 112, '112
유형
제한정도
지급률(%)
배변
배뇨
- 배설을 돕기 위해 설치한 의료장치나 외과적 시술물
을 사용함에 있어 타인의 계속적인 도움이 필요한 
상태
- 화장실에 가서 변기 위에 앉는 일(요강을 사용하는 
일 포함)과 대소변 후에 화장지로 닦고 옷을 입는 
일에 다른 사람의 계속적인 도움이 필요한 상태
- 배변, 배뇨는 독립적으로 가능하나 대소변 후 뒤처
리에 있어 다른 사람의 도움이 필요한 상태
- 빈번하고 불규칙한 배변으로 인해 2시간 이상 계속
되는 업무(운전, 작업, 교육 등)를 수행하는 것이 어
려운 상태
20
15
10
5
목욕
- 다른 사람의 계속적인 도움 없이는 샤워 또는 목욕
을 할 수 없는 상태
- 샤워는 가능하나, 혼자서는 때밀기를 할 수 없는 상
태
- 목욕시 신체(등 제외)의 일부 부위만 때를 밀 수 있
는 상태
10
5
3
옷입고 벗기
- 다른 사람의 계속적인 도움 없이는 전혀 옷을 챙겨 
입을 수 없는 상태
- 다른 사람의 계속적인 도움 없이는 상의 또는 하의 
중 하나만을 착용할 수 있는 상태
- 착용은 가능하나 다른 사람의 도움 없이는 마무리
(단추 잠그고 풀기, 지퍼 올리고 내리기, 끈 묶고 풀
기 등)는 불가능한 상태
10
5
3
부상등급
상해내용
1급
1. 수술 여부와 상관없이 뇌손상으로 신경학적 증상이 고도인 
상해(신경학적 증상이 48시간 이상 지속되는 경우에 적용한다)
2. 양안 안구 파열로 안구 적출술 또는 안구내용 제거술과 의안 
삽입술을 시행한 상해
3. 심장 파열로 수술을 시행한 상해
4. 흉부 대동맥 손상 또는 이에 준하는 대혈관 손상으로 수술 또는 
스탠트그라프트 삽입술을 시행한 상해
5. 척주 손상으로 완전 사지마비 또는 완전 하반신마비를 동반한 상해
6. 척수 손상을 동반한 불안정성 방출성 척추 골절
7. 척수 손상을 동반한 척추 신연손상 또는 전위성(회전성) 골절
8. 상완신경총 완전 손상으로 수술을 시행한 상해
9. 상완부 완전 절단 소실로 재접합술을 시행한 상해(주관절부 이단을 
포함한다)
10. 불안정성 골반골 골절로 수술을 시행한 상해
11. 비구 골절 또는 비구 골절 탈구로 수술을 시행한 상해
12. 대퇴부 완전 절단 소실로 재접합술을 시행한 상해
13. 골의 분절 소실로 유리생골 이식술을 시행한 상해(근육, 근막 또는 
피부 등 연부 조직을 포함한 경우에 적용한다)
14. 화상ㆍ좌창ㆍ괴사창 등 연부 조직의 심한 손상이 몸 표면의 
9퍼센트 이상인 상해
15. 그 밖에 1급에 해당한다고 인정되는 상해
2급
1. 뇌손상으로 신경학적 증상이 중등도인 상해(신경학적 증상이 
48시간 이상 지속되는 경우로 수술을 시행한 경우에 적용한다)
2. 흉부 기관, 기관지 파열, 폐 손상 또는 식도 손상으로 절제술을 
시행한 상해
3. 내부 장기 손상으로 장기의 일부분이라도 적출 수술을 시행한 상해
【별표3】 자동차사고 부상등급표
아래의 부상등급은 자동차손해배상보장법 시행령 제3조 제1항 제2호와 관련되며 법
령 변경시 변경된 내용을 적용합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (246, 4, 113, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
113
부상등급
상해내용
4. 신장 파열로 수술한 상해
5. 척주 손상으로 불완전 사지마비를 동반한 상해
6. 신경 손상 없는 불안정성 방출성 척추 골절로 수술적 고정술을 
시행한 상해 또는 경추 골절(치돌기 골절을 포함한다) 또는 탈구로 
할로베스트나 수술적 고정술을 시행한 상해
7. 상완 신경총 상부간부 또는 하부간부의 완전 손상으로 수술을 
시행한 상해
8. 전완부 완전 절단 소실로 재접합술을 시행한 상해
9. 고관절의 골절성 탈구로 수술을 시행한 상해(비구 골절을 동반하지 
않은 경우에 적용한다)
10. 대퇴 골두 골절로 수술을 시행한 상해
11. 대퇴골 경부 분쇄 골절, 전자하부 분쇄 골절, 과부 분쇄 골절, 
경골 과부 분쇄 골절 또는 경골 원위 관절내 분쇄 골절
12. 슬관절의 골절 및 탈구로 수술을 시행한 상해
13. 하퇴부 완전 절단 소실로 재접합술을 시행한 상해
14. 사지 연부 조직에 손상이 심하여 유리 피판술을 시행한 상해
15. 그 밖에 2급에 해당한다고 인정되는 상해
3급
1. 뇌손상으로 신경학적 증상이 고도인 상해(신경학적 증상이 48시간 
미만 지속되는 경우로 수술을 시행한 경우에 적용한다)
2. 뇌손상으로 신경학적 증상이 중등도인 상해(신경학적 증상이 
48시간 이상 지속되는 경우로 수술을 시행하지 않은 경우에 
적용한다) 
3. 단안 안구 적출술 또는 안구 내용 제거술과 의안 삽입술을 시행한 
상해
4. 흉부 대동맥 손상 또는 이에 준하는 대혈관 손상으로 수술을 
시행하지 않은 상해
5. 절제술을 제외한 개흉 또는 흉강경 수술을 시행한 상해(진단적 
목적으로 시행한 경우는 4급에 해당한다)
6. 요도 파열로 요도 성형술 또는 요도 내시경을 이용한 요도 
절개술을 시행한 상해
부상등급
상해내용
7. 내부 장기 손상으로 장기 적출 없이 재건수술 또는 지혈수술 등을 
시행한 상해(장간막 파열을 포함한다)
8. 척주 손상으로 불완전 하반신마비를 동반한 상해 
9. 견관절 골절 및 탈구로 수술을 시행한 상해
10. 상완부 완전 절단 소실로 재접합술을 시행하지 않은 
상해(주관절부 이단을 포함한다)
11. 주관절부 골절 및 탈구로 수술을 시행한 상해
12. 수근부 완전 절단 소실로 재접합술을 시행한 상해
13. 대퇴골 또는 경골 골절(대퇴골 골두 골절은 제외한다)
14. 대퇴부 완전 절단 소실로 재접합술을 시행하지 않은 상해
15. 슬관절의 전방 및 후방 십자인대의 파열
16. 족관절 골절 및 탈구로 수술을 시행한 상해
17. 족근관절의 손상으로 족근골의 완전탈구가 동반된 상해
18. 족근부 완전 절단 소실로 재접합술을 시행한 상해
19. 그 밖에 3급에 해당한다고 인정되는 상해
4급
1. 뇌손상으로 신경학적 증상이 고도인 상해(신경학적 증상이 48시간 
미만 지속되는 경우로 수술을 시행하지 않은 경우에 적용한다)
2. 각막 이식술을 시행한 상해
3. 후안부 안내 수술을 시행한 상해(유리체 출혈, 망막 박리 등으로 
수술을 시행한 경우에 적용한다)
4. 흉부 손상 또는 복합 손상으로 인공호흡기를 시행한 
상해(기관절개술을 시행한 경우도 포함한다)
5. 진단적 목적으로 복부 또는 흉부 수술을 시행한 상해(복강경 또는 
흉강경 수술도 포함한다)
6. 상완신경총 완전 손상으로 수술을 시행하지 않은 상해
7. 상완신경총 불완전 손상으로 수술을 시행한 상해(2개 이상의 주요 
말초신경 장애를 보이는 손상에 적용한다)
8. 상완골 경부 골절
9. 상완골 간부 분쇄성 골절
10. 상완골 과상부 또는 상완골 원위부 관절내 골절로 수술을 시행한 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (247, 4, 114, '114
부상등급
상해내용
상해(경과 골절, 과간 골절, 내과 골절, 소두 골절에 적용한다)
11. 요골 원위부 골절과 척골 골두 탈구가 동반된 상해(갈레아찌 
골절을 말한다)
12. 척골 근위부 골절과 요골 골두 탈구가 동반된 상해(몬테지아 
골절을 말한다)
13. 전완부 완전 절단 소실로 재접합술을 시행하지 않은 상해
14. 요수근관절 골절 및 탈구로 수술을 시행한 상해(수근골간 관절 
탈구, 원위 요척관절 탈구를 포함한다)
15. 수근골 골절 및 탈구가 동반된 상해
16. 무지 또는 다발성 수지의 완전 절단 소실로 재접합술을 시행한 
상해
17. 불안정성 골반골 골절로 수술하지 않은 상해
18. 골반환이 안정적인 골반골 골절로 수술을 시행한 상해(천골 골절 
및 미골 골절을 포함한다)
19. 골반골 관절의 이개로 수술을 시행한 상해
20. 비구 골절 또는 비구 골절 탈구로 수술을 시행하지 않은 상해
21. 슬관절 탈구로 수술을 시행한 상해
22. 하퇴부 완전 절단 소실로 재접합술을 시행하지 않은 상해
23. 거골 또는 종골 골절
24. 무족지 또는 다발성 족지의 완전 절단 소실로 재접합술을 시행한 
상해
25. 사지의 연부 조직에 손상이 심하여 유경 피판술 또는 원거리 
피판술을 시행한 상해
26. 화상, 좌창, 괴사창 등으로 연부 조직의 손상이 몸 표면의 약 
4.5퍼센트 이상인 상해
27. 그 밖에 4급에 해당한다고 인정되는 상해
5급
1. 뇌손상으로 신경학적 증상이 중등도에 해당하는 상해(신경학적 
증상이 48시간 미만 지속되는 경우로 수술을 시행한 경우에 
적용한다)
2. 안와 골절에 의한 복시로 안와 골절 재건술과 사시 수술을 시행한 
부상등급
상해내용
상해
3. 복강내 출혈 또는 장기 파열 등으로 중재적 방사선학적 시술을 
통하여 지혈술을 시행하거나 경피적 배액술 등을 시행하여 
보존적으로 치료한 상해
4. 안정성 추체 골절
5. 상완 신경총 상부 간부 또는 하부 간부의 완전 손상으로 수술하지 
않은 상해
6. 상완골 간부 골절
7. 요골 골두 또는 척골 구상돌기 골절로 수술을 시행한 상해
8. 요골과 척골의 간부 골절이 동반된 상해
9. 요골 경상돌기 골절
10. 요골 원위부 관절내 골절
11. 수근 주상골 골절
12. 수근부 완전 절단 소실로 재접합술을 시행하지 않은 상해
13. 무지를 제외한 단일 수지의 완전 절단 소실로 재접합술을 시행한 
상해
14. 고관절의 골절성 탈구로 수술을 시행하지 않은 상해(비구 골절을 
동반하지 않은 경우에 적용한다)
15. 고관절 탈구로 수술을 시행한 상해
16. 대퇴골두 골절로 수술을 시행하지 않은 상해
17. 대퇴골 또는 근위 경골의 견열골절  
18. 슬관절의 골절 및 탈구로 수술을 시행하지 않은 상해
19. 슬관절의 전방 또는 후방 십자인대의 파열
20. 슬개골 골절
21. 족관절의 양과 골절 또는 삼과 골절(내과, 외과, 후과를 말한다)
22. 족관절 탈구로 수술을 시행한 상해
23. 그 밖의 족근골 골절(거골 및 종골은 제외한다)
24. 중족족근관절 손상(리스프랑 관절을 말한다)
25. 3개 이상의 중족골 골절로 수술을 시행한 상해
26. 족근부 완전 절단 소실로 재접합술을 시행하지 않은 상해
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (248, 4, 115, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
115
부상등급
상해내용
27. 무족지를 제외한 단일 족지의 완전 절단 소실로 재접합술을 
시행한 상해
28. 아킬레스건, 슬개건, 대퇴 사두건 또는 대퇴 이두건 파열로 수술을 
시행한 상해 
29. 사지 근 또는 건 파열로 6개 이상의 근 또는 건 봉합술을 시행한 
상해
30. 다발성 사지의 주요 혈관 손상으로 봉합술 또는 이식술을 시행한 
상해
31. 사지의 주요 말초 신경 손상으로 수술을 시행한 상해
32. 23치 이상의 치과보철을 필요로 하는 상해 
33. 그 밖에 5급에 해당한다고 인정되는 상해
6급
1. 뇌손상으로 신경학적 증상이 경도인 상해(수술을 시행한 경우에 
적용한다)
2. 뇌손상으로 신경학적 증상이 중등도에 해당하는 상해(신경학적 
증상이 48시간 미만 지속되는 경우로 수술을 시행하지 않은 경우에 
적용한다)
3. 전안부 안내 수술을 시행한 상해(외상성 백내장, 녹내장 등으로 
수술을 시행한 경우에 적용한다)
4. 심장 타박
5. 폐좌상(일측 폐의 50퍼센트 이상 면적을 흉부 CT 등에서 확인한 
경우에 한정한다)
6. 요도 파열로 유치 카테타, 부지 삽입술을 시행한 상해
7. 혈흉 또는 기흉이 발생하여 폐쇄식 흉관 삽관수술을 시행한 상해
8. 견관절의 회전근개 파열로 수술을 시행한 상해
9. 외상성 상부관절와순 파열로 수술을 시행한 상해  
10. 견관절 탈구로 수술을 시행한 상해
11. 견관절의 골절 및 탈구로 수술을 시행하지 않은 상해
12. 상완골 대결절 견열 골절
13. 상완골 원위부 견열골절(외상과 골절, 내상과 골절 등에 해당한다)
14. 주관절부 골절 및 탈구로 수술을 시행하지 않은 상해
부상등급
상해내용
15. 주관절 탈구로 수술을 시행한 상해
16. 주관절 내측 또는 외측 측부 인대 파열로 수술을 시행한 상해
17. 요골간부 또는 원위부 관절외 골절
18. 요골 경부 골절
19. 척골 주두부 골절
20. 척골 간부 골절(근위부 골절은 제외한다)
21. 다발성 수근중수골 관절 탈구 또는 다발성 골절탈구
22. 무지 또는 다발성 수지의 완전 절단 소실로 재접합술을 시행하지 
않은 상해
23. 슬관절 탈구로 수술을 시행하지 않은 상해
24. 슬관절 내측 또는 외측 측부인대 파열로 수술을 시행한 상해
25. 반월상 연골 파열로 수술을 시행한 상해
26. 족관절 골절 및 탈구로 수술을 시행하지 않은 상해
27. 족관절 내측 또는 외측 측부인대의 파열 또는 골절을 동반하지 
않은 원위 경비골 이개
28. 2개 이하의 중족골 골절로 수술을 시행한 상해
29. 무족지 또는 다발성 족지의 완전 절단 소실로 재접합술을 
시행하지 않은 상해
30. 사지 근 또는 건 파열로 3 ～ 5개의 근 또는 건 봉합술을 시행한 
상해
31. 19치 이상 22치 이하의 치과보철을 필요로 하는 상해
32. 그 밖에 6급에 해당한다고 인정되는 상해
7급
1. 다발성 안면 두개골 골절 또는 뇌신경 손상과 동반된 안면 두개골 
골절
2. 복시를 동반한 마비 또는 제한 사시로 사시수술을 시행한 상해
3. 안와 골절로 재건술을 시행한 상해
4. 골다공증성 척추 압박골절
5. 쇄골 골절
6. 견갑골 골절(견갑골극, 체부, 흉곽내 탈구, 경부, 과부, 견봉돌기, 
오구돌기를 포함한다) 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (249, 4, 116, '116
부상등급
상해내용
7. 견봉 쇄골인대 및 오구 쇄골인대 완전 파열
8. 상완신경총 불완전 손상으로 수술을 시행하지 않은 상해
9. 요골 골두 또는 척골 구상돌기 골절로 수술을 시행하지 않은 상해
10. 척골 경상돌기 기저부 골절
11. 삼각섬유연골 복합체 손상
12. 요수근관절 탈구로 수술을 시행한 상해(수근골간관절 탈구, 원위 
요척관절 탈구를 포함한다)
13. 요수근관절 골절 및 탈구로 수술을 시행하지 않은 
상해(수근골간관절 탈구, 원위 요척관절 탈구를 포함한다)
14. 주상골 외 수근골 골절
15. 수근부 주상골ㆍ월상골간 인대 파열
16. 수근중수골 관절의 탈구 또는 골절탈구
17. 다발성 중수골 골절
18. 중수수지관절의 골절 및 탈구
19. 무지를 제외한 단일 수지의 완전 절단 소실로 재접합술을 
시행하지 않은 상해
20. 골반골 관절의 이개로 수술을 시행하지 않은 상해
21. 고관절 탈구로 수술을 시행하지 않은 상해
22. 비골 간부 골절 또는 골두 골절
23. 족관절 탈구로 수술을 시행하지 않은 상해
24. 족관절 내과, 외과 또는 후과 골절 
25. 무족지를 제외한 단일 족지의 완전 절단 소실로 재접합술을 
시행하지 않은 상해
26. 16치 이상 18치 이하의 치과보철을 필요로 하는 상해 
27. 그 밖에 7급에 해당한다고 인정되는 상해
8급
1. 뇌손상으로 신경학적 증상이 경도인 상해(수술을 시행하지 않은 
경우에 적용한다)
2. 상악골, 하악골, 치조골 등의 안면 두개골 골절
3. 외상성 시신경병증
4. 외상성 안검하수로 수술을 시행한 상해
부상등급
상해내용
5. 복합 고막 파열
6. 혈흉 또는 기흉이 발생하여 폐쇄식 흉관 삽관수술을 시행하지 않은 
상해 
7. 3개 이상의 다발성 늑골 골절
8. 각종 돌기 골절(극돌기, 횡돌기) 또는 후궁 골절
9. 견관절 탈구로 수술을 시행하지 않은 상해
10. 상완골 과상부 또는 상완골 원위부 관절내 골절(경과 골절, 과간 
골절. 내과 골절, 소두 골절 등을 말한다)로 수술을 시행하지 않은 
상해
11. 주관절 탈구로 수술을 시행하지 않은 상해
12. 중수골 골절
13. 수지골의 근위지간 또는 원위지간 골절 탈구
14. 다발성 수지골 골절
15. 무지 중수지관절 측부인대 파열
16. 골반환이 안정적인 골반골 골절(천골 골절 및 미골 골절을 
포함한다)로 수술을 시행하지 않은 상해
17. 슬관절 십자인대 부분 파열로 수술을 시행하지 않은 상해
18. 3개 이상의 중족골 골절로 수술을 시행하지 않은 상해
19. 수족지골 골절 및 탈구로 수술을 시행한 상해
20. 사지의 근 또는 건 파열로 하나 또는 두 개의 근 또는 건 
봉합술을 시행한 상해
21. 사지의 주요 말초 신경 손상으로 수술을 시행하지 않은 상해
22. 사지의 감각 신경 손상으로 수술을 시행한 상해
23. 사지의 다발성 주요 혈관손상으로 봉합술 혹은 이식술을 시행한 
상해
24. 사지의 연부 조직 손상으로 피부 이식술이나 국소 피판술을 
시행한 상해
25. 13치 이상 15치 이하의 치과보철을 필요로 하는 상해 
26. 그 밖에 8급에 해당한다고 인정되는 상해
9급
1. 안면부의 비골 골절로 수술을 시행한 상해
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (250, 4, 117, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
117
부상등급
상해내용
2. 2개 이하의 단순 늑골골절
3. 고환 손상으로 수술을 시행한 상해
4. 음경 손상으로 수술을 시행한 상해
5. 흉골 골절
6. 추간판 탈출증
7. 흉쇄관절 탈구
8. 주관절 내측 또는 외측 측부 인대 파열로 수술을 시행하지 않은 
상해
9. 요수근관절 탈구로 수술을 시행하지 않은 상해(수근골간관절 탈구, 
원위 요척관절 탈구를 포함한다)
10. 수지골 골절로 수술을 시행한 상해
11. 수지관절 탈구
12. 슬관절 측부인대 부분 파열로 수술을 시행하지 않은 상해
13. 2개 이하의 중족골 골절로 수술을 시행하지 않은 상해
14. 수족지골 골절 또는 수족지관절 탈구로 수술을 시행한 상해
15. 그 밖에 견열골절 등 제불완전골절
16. 아킬레스건, 슬개건, 대퇴 사두건 또는 대퇴 이두건 파열로 수술을 
시행하지 않은 상해
17. 수족지 신전건 1개의 파열로 건 봉합술을 시행한 상해
18. 사지의 주요 혈관손상으로 봉합술 혹은 이식술을 시행한 상해
19. 11치 이상 12치 이하의 치과보철을 필요로 하는 상해 
20. 그 밖에 9급에 해당한다고 인정되는 상해
10급
1. 3cm 이상 안면부 열상
2. 안검과 누소관 열상으로 봉합술과 누소관 재건술을 시행한 상해
3. 각막, 공막 등의 열상으로 일차 봉합술만 시행한 상해
4. 견관절부위의 회전근개 파열로 수술을 시행하지 않은 상해
5. 외상성 상부관절와순 파열 중 수술을 시행하지 않은 상해
6. 수족지관절 골절 및 탈구로 수술을 시행하지 않은 상해
7. 하지 3대 관절의 혈관절증
8. 연부조직 또는 피부 결손으로 수술을 시행하지 않은 상해
부상등급
상해내용
9. 9치 이상 10치 이하의 치과보철을 필요로 하는 상해
10. 그 밖에 10급에 해당한다고 인정되는 상해
11급
1. 뇌진탕
2. 안면부의 비골 골절로 수술을 시행하지 않는 상해
3. 수지골 골절로 수술을 시행하지 않은 상해
4. 수족지골 골절 또는 수족지관절 탈구로 수술을 시행하지 않은 상해
5. 6치 이상 8치 이하의 치과보철을 필요로 하는 상해 
6. 그 밖에 11급에 해당한다고 인정되는 상해
12급
1. 외상 후 급성 스트레스 장애
2. 3cm 미만 안면부 열상  
3. 척추 염좌
4. 사지 관절의 근 또는 건의 단순 염좌 
5. 사지의 열상으로 창상 봉합술을 시행한 상해(길이에 관계없이 
적용한다)
6. 사지 감각 신경 손상으로 수술을 시행하지 않은 상해
7. 4치 이상 5치 이하의 치과보철을 필요로 하는 상해
8. 그 밖에 12급에 해당한다고 인정되는 상해
13급
1. 결막의 열상으로 일차 봉합술을 시행한 상해  
2. 단순 고막 파열
3. 흉부 타박상으로 늑골 골절 없이 흉부의 동통을 동반한 상해
4. 2치 이상 3치 이하의 치과보철을 필요로 하는 상해
5. 그 밖에 13급에 해당한다고 인정되는 상해
14급
1. 방광, 요도, 고환, 음경, 신장, 간, 지라 등 손상으로 수술을 
시행하지 않은 상해
2. 수족지 관절 염좌
3. 사지의 단순 타박
4. 1치 이하의 치과보철을 필요로 하는 상해
5. 그 밖에 14급에 해당한다고 인정되는 상해
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (251, 4, 118, '118
영역
내용
공통
가. 2급부터 11급까지의 상해 내용 중 2가지 이상의 상해가 중복된 
경우에는 가장 높은 등급에 해당하는 상해부터 하위 3등급(예: 
상해내용이 2급에 해당하는 경우에는 5급까지) 사이의 상해가 
중복된 경우에만 가장 높은 상해 내용의 등급보다 한 등급 높은 
금액으로 배상(이하 "병급"이라 한다)한다. 
나. 일반 외상과 치과보철을 필요로 하는 상해가 중복된 경우에는 
각각의 상해 등급별 금액을 배상하되, 그 합산액이 1급의 금액을 
초과하지 않는 범위에서 배상한다.
다. 1개의 상해에서 2개 이상의 상향 또는 하향 조정의 요인이 있을 
때 등급 상향 또는 하향 조정은 1회만 큰 폭의 조정을 적용한다. 
다만, 상향 조정 요인과 하향 조정 요인이 여러 개가 함께 있을 
때에는 큰 폭의 상향 또는 큰 폭의 하향 조정 요인을 각각 
선택하여 함께 반영한다.
라. 재해 발생 시 만 13세 미만인 사람은 소아로 인정한다.
마. 연부 조직에 손상이 심하여 유리 피판술, 유경 피판술, 원거리 
피판술, 국소 피판술이나 피부 이식술을 시행할 경우 안면부는 
1등급 상위등급을 적용하고, 수부, 족부에 국한된 손상에 대해서는 
한 등급 아래의 등급을 적용한다.
두부
가. "뇌손상"이란 국소성 뇌손상인 외상성 두개강안의 출혈(경막상ㆍ하 
출혈, 뇌실 내 및 뇌실질 내 출혈, 거미막하 출혈 등을 말한다) 
또는 경막하 수활액낭종, 거미막 낭종, 두개골 골절(두개 기저부 
골절을 포함한다) 등과 미만성 축삭손상을 포함한 뇌좌상을 
말한다.
나. 4급 이하에서 의식 외에 뇌신경 손상이나 국소성 신경학적 이상 
소견이 있는 경우 한 등급을 상향조정할 수 있다. 
다. 신경학적 증상은 글라스고우 혼수척도(Glasgow coma  scale)로 
구분하며, 고도는 8점 이하, 중등도는 9 ～ 12점, 경도는 13 ～ 
15점을 말한다.
라. 글라스고우 혼수척도는 진정치료 전에 평가하는 것을 원칙으로 
영역
내용
한다.
마. 글라스고우 혼수척도 평가 시 의식이 있는 상태에서 기관지 삽관이 
필요한 경우는 제외한다.
바. 의무기록 상 의식상태가 혼수(coma)와 반혼수(semicoma)는 고도, 
혼미(stupor)는 중등도, 기면(drowsy)은 경도로 본다.
사. 두피 좌상, 열창은 14급으로 본다.
아. 만성 경막하 혈종으로 수술을 시행한 경우에는 6급 2호를 
적용한다.
자. 외상 후 급성 스트레스 장애는 다른 진단이 전혀 없이 단독 
상병으로 외상 후 1개월 이내 발병된 경우에 적용한다.
흉ㆍ복부
심장타박(6급)의 경우, ①심전도에서 Tachyarrythmia 또는 ST변화 
또는 부정맥, ②심초음파에서 심낭액증가소견이 있거나 
심장벽운동저하, ③심장효소치증가(CPK-MB, and Troponin T)의 
세가지 요구 충족 시 인정한다.
척추
가. 완전 마비는 근력등급 3 이하인 경우이며, 불완전 마비는 근력등급 
4인 경우로 정한다.
나. 척추관 협착증이나 추간판 탈출증이 외상으로 증상이 발생한 
경우나 악화된 경우는 9급으로 본다.
다. 척주 손상으로 인하여 신경근증 이나 감각이상을 호소하는 경우는 
9급으로 본다.
라. 마미증후군은 척수손상으로 본다.
상ㆍ
하지
공통
가. 2급부터 11급까지의 내용 중 사지 골절에서 별도로 상해 등급이 
규정되지 않은 경우, 보존적 치료를 시행한 골절은 해당 등급에서 
2급 낮은 등급을 적용하며, 도수 정복 및 경피적 핀고정술을 
시행한 경우에는 해당 등급에서 1급 낮은 등급을 적용한다.
나. 2급부터 11급까지의 상해 내용 중 개방성 골절 또는 탈구에서 
거스틸로 2형 이상(개방창의 길이가 1cm 이상인 경우를 말한다)의 
영역별 세부지침
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (252, 4, 119, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
119
영역
내용
개방성 골절 또는 탈구에서만 1등급 상위 등급을 적용한다.
다. 2급부터 11급까지의 상해 내용 중 "수술적 치료를 시행하지 
않은"이라고 명기되지 않은 각 등급 손상 내용은 수술적 치료를 
시행한 경우를 말하며, 보존적 치료를 시행한 경우가 따로 
명시되지 않은 경우는 두 등급 하향 조정함을 원칙으로 한다. 
라. 양측 또는 단측을 별도로 규정한 경우에는 병합하지 않으나, 별도 
규정이 없는 양측 손상인 경우에는 병합한다. 
마. 골절에 주요 말초신경의 손상 동반 시 해당 골절보다 1등급 상위 
등급을 적용한다.
바. 재접합술을 시행한 절단소실의 경우 해당부위의 절단보다 2급 높은 
등급을 적용한다.
사. 아절단은 완전 절단에 준한다.
아. 관절 이단의 경우는 상위부 절단으로 본다. 
자. 골절 치료로 인공관절 치환술 시행할 경우 해당부위의 골절과 
동일한 등급으로 본다.
차. 사지 근 또는 건의 부분 파열로 보존적으로 치료한 경우 근 또는 
건의 단순 염좌(12급)로 본다. 
카. 사지 관절의 인공관절 재치환 시 해당 부위 골절보다 1등급 높은 
등급을 적용한다. 
타. 보존적으로 치료한 사지 주요관절 골절 및 탈구는 해당관절의 골절 
및 탈구보다 3등급 낮은 등급을 적용한다.
파. 수술을 시행한 사지 주요 관절 탈구는 해당 관절의 보존적으로 
치료한 탈구보다 2등급 높은 등급을 적용한다.
하. 동일 관절 혹은 동일 골의 손상은 병합하지 않으며 상위 등급을 
적용한다.
거. 분쇄 골절을 형성하는 골절선은 선상 골절이 아닌 골절선으로 
판단한다. 
너. 수족지 절단 시 절단부위에 따른 차이는 두지 않는다.
상
지
가. 상부관절순 파열은 외상성 파열만 인정한다.
나. 회전근개 파열 개수에 따른 차등을 두지 않는다. 
다. "근, 건, 인대 파열"이란 완전 파열을 말하며, 부분 파열은 수술을 
영역
내용
시행한 경우에 완전 파열로 본다.
라. 사지골 골절 중 상해등급에서 별도로 명시하지 않은 사지골 
골절(견열골절을 포함한다)은 제불완전골절로 본다. 다만, 관혈적 
정복술을 시행한 경우는 해당 부위 골절 항에 적용한다.
마. 사지골 골절 시 시행한 외고정술도 수술을 한 것으로 본다.
바. 소아의 경우, 성인의 동일 부위 골절보다 1급 낮게 적용한다. 
다만, 성장판 손상이 동반된 경우와 연부조직 손상은 성인과 
동일한 등급을 적용한다.
사. 6급의 견관절 탈구에서 재발성 탈구를 초래할 수 있는 해부학적 
병변이 병발된 경우는 수술 여부에 상관없이 6급을 적용한다.
아. 견봉 쇄골간 관절 탈구, 관절낭 또는 견봉 쇄골간 인대 파열은 
견봉 쇄골인대 및 오구 쇄골인대의 완전 파열에 포함되고, 견봉 
쇄골인대 및 오구 쇄골인대의 완전 파열로 수술한 경우 7급을 
적용하며, 부분 파열로 보존적 치료를 시행한 경우 9급을 
적용하고, 단순 염좌의 경우 12급을 적용한다.
자. 주요 동맥 또는 정맥 파열로 봉합술을 시행한 상해의 경우, 주요 
동맥 또는 정맥이란 수술을 통한 혈행의 확보가 의학적으로 필요한 
경우를 말하며, "다발성 혈관 손상"이란 2부위 이상의 주요 동맥 
또는 정맥의 손상을 말한다. 
하
지
가. 양측 치골지 골절, 치골 상하지 골절 등에서는 병급하지 않는다.
나. 천골 골절, 미골 골절은 골반골 골절로 본다.
다. 슬관절 십자인대 파열은 전후방 십자인대의 동시 파열이 별도로 
규정되어 있으므로 병급하지 않으나 내외측 측부인대 동시 파열, 
십자인대와 측부인대 파열, 반월상 연골판 파열 등은 병급한다.
라. 후경골건 및 전경골건 파열은 족관절 측부인대 파열로 수술을 
시행한 경우의 등급으로 본다.
마. 대퇴골 또는 경비골의 견열성 골절의 경우, 동일 관절의 인대 
손상에 대하여 수술적 치료를 시행한 경우는 인대 손상 등급으로 
본다.
바. 경골 후과의 단독 골절 시 족관절 내과 또는 외과의 골절로 본다.
사. 고관절이란 대퇴골두와 골반골의 비구를 포함하며, "골절 탈구"란 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (253, 4, 120, '120
영역
내용
골절과 동시에 관절의 탈구가 발생한 상태를 말한다.
아. 불안정성 골반 골절은 골반환을 이루는 골간의 골절 탈구를 
포함한다. 
자. "하지의 3대 관절"이란 고관절, 슬관절, 족관절을 말한다.
차. 슬관절의 전방 또는 후방 십자인대의 파열은 인대 복원수술을 
시행하거나 완전 파열에 준하는 파열에 적용한다. 
카. 골반환이 안정적인 골반골의 수술을 시행한 골절은 치골 골절로 
수술한 경우 등을 포함한다.
【별표4】 교통사고처리특례법 제3조 제2항 단서
1. 도로교통법 제5조 (신호 또는 지시에 따른 의무) 의 규정에 의한 신호기 또는 교통정
리를 하는 경찰공무원 등의 신호나 통행의 금지 또는 일시정지를 내용으로 하는 안전
표지가 표시하는 지시에 위반하여 운전한 경우
2. 도로교통법 제13조 (차마의 통행)  제3항의 규정을 위반하여 중앙선을  침범하거나 
동법 제62조 (횡단 등의 금지)의 규정에 위반하여 횡단․유턴 또는 후진한 경우
3. 도로교통법 제17조 (자동차 등의 속도) 제1항 또는 제2항의 규정에 의한 제한속도를 
매시 20킬로미터를 초과하여 운전한 경우
4. 도로교통법 제19조 (앞지르기 방법등) 제1항 제22조 (앞지르기 금지의 시기 및 장소) 
내지 제23조 (끼어들기의 금지) 또는 제60조 (갓길통행금지 등) 제2항의 규정에 의한 
앞지르기의 방법, 시기, 장소 또는 끼어들기의 금지에 위반하여 운전한 경우
5. 도로교통법 제24조 (철길건널목 통과)의 규정에 의한 건널목 통과방법을 위반하여 운
전한 경우
6. 도로교통법 제27조 (보행자의 보호) 제1항의 규정에 의한 횡단보도에서의 보행자 보호
의무를 위반하여 운전한 경우
7. 도로교통법 제43조(무면허운전 등의 금지) 제1항, 건설기계관리법 제26조(건설기계조
종사면허) 또는 도로교통법 제96조(국제운전면허증에 의한 자동차 등의 운전)의 규정
에 위반하여 운전면허 또는 건설기계조종사면허를 받지 아니하거나 국제운전면허증을 
소지하지 아니하고 운전한 경우. 이 경우 운전면허 또는 건설기계조종사면허의 효력이 
정지중에 있거나 운전의 금지중에 있는 때에는 운전면허 또는 건설기계조종사면허를 
받지 아니하거나 국제운전면허증을 소지하지 않은 것으로 본다. 
8. 도로교통법 제44조(주취중의 운전금지) 제1항의 규정에 위반하여 주취중에 운전을 하
거나 동법 제42조(과로한 때 등의 운전금지)의 규정에 위반하여 약물의 영향으로 정상
한 운전을 하지 못할 염려가 있는 상태에서 운전한 경우
9. 도로교통법 제13조 (차마의 통행) 제1항의 규정에 위반하여 보도가 설치된 도로의 보
도를 침범하거나 동법 제12조 (차마의 통행) 제2항의 규정에 의한 보도횡단방법에 위
반하여 운전한 경우
10. 도로교통법 제39조 (승차 또는 적재의 방법과 제한) 제2항의 규정에 의한 승객의 추
락방지 의무를 위반하여 운전한 경우
11. 도로교통법 제12조 제3항에 따른 어린이 보호구역에서 같은 조 제1항에 따른 조치
를 준수하고 어린이의 안전에 유의하면서 운전하여야 할 의무를 위반하여 어린이의 
신체를 상해에 이르게 한 경우
▶ 상기 외 법령의 변경으로 추가되는 사항이 있는 경우에는 그 사항도 포함하는 것
으로 합니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (254, 4, 121, '별
표
무배당 프로미라이프 참좋은오토바이운전자보험1707
121
【별표5-1】 소송목적의 값에 따른 변호사비용
소송목적의 값
변호사보수액 한도
1,000만원까지
소송목적의 값 x 8%
1,000만원 초과～2,000만원까지
80만원 + (소송목적의 값 – 1,000만원) x 7%
1
2,000만원 초과～3,000만원까지
150만원 + (소송목적의 값 - 2,000만원) x 6%
3,000만원 초과～5,000만원까지
210만원 + (소송목적의 값 - 3,000만원) x 5%
5,000만원 초과～7,000만원까지
310만원 + (소송목적의 값 - 5,000만원) x 4%
7,000만원 초과～1억원까지
390만원 + (소송목적의 값 - 7,000만원) x 3%
1억원 초과～2억원까지
480만원 + (소송목적의 값 - 1억원) x 2%
2억원 초과～5억원까지
680만원 + (소송목적의 값 - 2억원) x 1%
5억원 초과 ～
980만원 + (소송목적의 값 - 5억원) x 0.5%
(단, 1,500만원을 한도로 함)
⌜변호사보수의소송비용산입에관한규칙⌟이 변경되는 경우 변경된 내용에 따릅니다.
【별표5-2】 민사소송 등 인지법」에서 정한 인지액
소송목적의 값
인지액 한도
1천만원 미만
소송목적의 값 x 0.5%
1천만원 ～ 1억미만
5,000원 + 소송목적의 값 x 0.45%
1
1억 ～ 10억미만
55,000원 + 소송목적의 값 x 0.40%
10억이상
555,000원 + 소송목적의 값 x 0.35%
항소심의 경우 상기한도의 1.5배, 상고심의 경우 2.0배를 적용 합니다.
「민사소송 등 인지법」이 변경되는 경우 변경된 내용에 따릅니다.
【별표5-3】 「송달료규칙의 시행에 따른 업무처리요령」에서 정한 
송달료
심급별
송달료 한도
1심 민사소액/민사단독/민사합의
71,000원 / 106,500원 / 106,500원 
항소심/상고심
85,200원 / 56,800원 
「송달료규칙의 시행에 따른 업무처리요령」이 변경되는 경우 변경된 내용에 따릅니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (255, 4, 122, '122
【별표6-1】 소송목적의 값에 따른 변호사비용
소송목적의 값
변호사 비용
1,000만원까지
 소송목적의 값 x 8%
1,000만원 초과～2,000만원까지
 80만원 + (소송목적의 값 –1,000만원) x 7%
1
2,000만원 초과～3,000만원까지
 150만원 + (소송목적의 값 - 2,000만원) x 6%
3,000만원 초과～5,000만원까지
 210만원 + (소송목적의 값 - 3,000만원) x 5%
5,000만원 초과～7,000만원까지
 310만원 + (소송목적의 값 - 5,000만원) x 4%
7,000만원 초과～1억원까지
 390만원 + (소송목적의 값 - 7,000만원) x 3%
1억원 초과～2억원까지
 480만원 + (소송목적의 값 - 1억원) x 2%
2억원 초과～5억원까지
 680만원 + (소송목적의 값 - 2억원) x 1%
5억원 초과 ～
 980만원+ (소송목적의 값 - 5억원) x 0.5%
 (단, 1,500만원을 한도로 함)
⌜변호사보수의소송비용산입에관한규칙⌟이 변경되는 경우 변경된 내용에 따릅니다.
【별표6-2】 민사소송 등 인지법」에서 정한 인지액
소송목적의 값
인지액 한도
1천만원 미만
소송목적의 값 x 0.5%
1천만원 ～ 1억미만
 5,000원 + 소송목적의 값 x 0.45%
1
1억 ～ 10억미만
 55,000원 + 소송목적의 값 x 0.40%
10억이상
555,000원 + 소송목적의 값 x 0.35%
항소심의 경우 상기한도의 1.5배, 상고심의 경우 2.0배를 적용 합니다.
「민사소송 등 인지법」이 변경되는 경우 변경된 내용에 따릅니다.
【별표6-3】 「송달료규칙의 시행에 따른 업무처리요령」에서 정한 
송달료
심급별
송달료 한도
행정1심사건 / 행정1심재정단독사건
71,000원
행정항소사건
71,000원
행정상고사건
56,800원
「송달료규칙의 시행에 따른 업무처리요령」이 변경되는 경우 변경된 내용에 따릅니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (256, 4, 123, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
123
약관에서
인용한 
법규
[법규1] 개인정보 보호법 (법률 제14107호, 시행일 2016.09.30.) ······················  124
[법규2] 개인정보 보호법 시행령 (대통령령 제27522호, 시행일 2016.09.30.) ···  125
[법규3] 국민건강보험법 (법률 제14183호, 시행일 2016.11.30.) ························  126
[법규4] 노인장기요양보험법 시행령                                        
(대통령령 제27575호, 시행일 2017.01.01.) ··············································  126
[법규5] 도로교통법 (법률 제14266호, 시행일 2016.11.30.) ·······························  127
[법규6] 민법 (법률 제13125호, 시행일 2016.02.04.) ···········································  127
[법규7] 상법 (법률 제13523호, 시행일 2016.03.02.) ···········································  128
[법규8] 성폭력범죄의 처벌 등에 관한 특례법                            
(법률 제12889호, 시행일 2015.07.01.) ····················································  128
[법규9] 신용정보의 이용 및 보호에 관한 법률                           
(법률 제14122호, 시행일 2016.09.30.) ····················································  130
[법규10] 신용정보의 이용 및 보호에 관한 법률 시행령                    
(대통령령 제27205호, 시행일 2016.09.30.) ············································  132
[법규11] 아동·청소년의 성보호에 관한 법률                             
(법률 제14236호, 시행일 2016.11.30.) ··················································  133
[법규12] 여객자동차운수사업법 시행령                                 
(대통령령 제27482호, 시행일 2016.09.05.) ············································  134
[법규13] 응급의료에 관한 법률 (법률 제13367호, 시행일 2015.12.23.) ···········  135
[법규14] 의료급여법 시행령 (대통령령 제27275호, 시행일 2016.08.04.) ··········  135
[법규15] 의료법 (법률 제13685호, 시행일 2016.09.30.) ·····································  136
[법규16] 의료법 시행규칙 별표4 
(보건복지부령 제442호, 시행일 2016.11.07.) ·········································  138
[법규17] 자동차관리법 시행규칙                                      
(국토교통부령 제371호, 시행일 2016.11.15.) ·········································  139
[법규18] 자동차손해배상보장법 시행령                                 
(대통령령 제25940호, 시행일 2016.04.01.) ············································  141
[법규19] 장애인복지법 시행령 (대통령령 제27427호, 시행일 2016.08.04.) ······  142
[법규20] 장애인복지법 시행규칙                                      
(보건복지부령 제415호, 시행일 2016.06.30.) ·········································  143
[법규21] 전자서명법 (법률 제12762호, 시행일 2014.10.15.) ·····························  151
[법규22] 지역보건법 (법률 제14009호, 시행일 2016.08.04.) ·····························  151
[법규23] 폭력행위등 처벌에 관한 법률                                 
(법률 제13718호, 시행일 2016.01.06.) ··················································  151
[법규24] 형법 (법률 제14178호, 시행일 2016.05.29.) ········································  153
[법규25] 화재로 인한 재해보상과 보험가입에 관한 법률                   
(법률 제12844호, 시행일 2014.11.19.) ··················································  156
[법규26] 화재로 인한 재해보상과 보험가입에 관한 법률 시행령             
(대통령령 제27445호, 시행일 2016.08.12.) ···········································  156
[법규27] 화재로 인한 재해보상과 보험가입에 관한 법률 시행규칙            
(총리령 제946호, 시행일 2011.01.01.) ···················································  156
          
※ 위의 법규가 변경되는 경우 변경된 내용을 따릅니다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (257, 4, 124, '124
【법규1】 개인정보 보호법
제15조(개인정보의 수집·이용)
① 개인정보처리자는 다음 각 호의 어느 하나에 해당하는 경우에는 개인정보를 수집
할 수 있으며 그 수집 목적의 범위에서 이용할 수 있다.
1. 정보주체의 동의를 받은 경우
2. 법률에 특별한 규정이 있거나 법령상 의무를 준수하기 위하여 불가피한 경우
3. 공공기관이 법령 등에서 정하는 소관 업무의 수행을 위하여 불가피한 경우
4. 정보주체와의 계약의 체결 및 이행을 위하여 불가피하게 필요한 경우
5. 정보주체 또는 그 법정대리인이 의사표시를 할 수 없는 상태에 있거나 주소불
명 등으로 사전 동의를 받을 수 없는 경우로서 명백히 정보주체 또는 제3자의 
급박한 생명, 신체, 재산의 이익을 위하여 필요하다고 인정되는 경우
6. 개인정보처리자의 정당한 이익을 달성하기 위하여 필요한 경우로서 명백하게 
정보주체의 권리보다 우선하는 경우. 이 경우 개인정보처리자의 정당한 이익과 
상당한 관련이 있고 합리적인 범위를 초과하지 아니하는 경우에 한한다.
② 개인정보처리자는 제1항제1호에 따른 동의를 받을 때에는 다음 각 호의 사항을 
정보주체에게 알려야 한다. 다음 각 호의 어느 하나의 사항을 변경하는 경우에도 
이를 알리고 동의를 받아야 한다.
1. 개인정보의 수집·이용 목적
2. 수집하려는 개인정보의 항목
3. 개인정보의 보유 및 이용 기간
4. 동의를 거부할 권리가 있다는 사실 및 동의 거부에 따른 불이익이 있는 경우
에는 그 불이익의 내용
제17조(개인정보의 제공)
① 개인정보처리자는 다음 각 호의 어느 하나에 해당되는 경우에는 정보주체의 개인
정보를 제3자에게 제공(공유를 포함한다. 이하 같다)할 수 있다.
1. 정보주체의 동의를 받은 경우
2. 제15조제1항제2호·제3호 및 제5호에 따라 개인정보를 수집한 목적 범위에서 
개인정보를 제공하는 경우
② 개인정보처리자는 제1항제1호에 따른 동의를 받을 때에는 다음 각 호의 사항을 
정보주체에게 알려야 한다. 다음 각 호의 어느 하나의 사항을 변경하는 경우에도 
이를 알리고 동의를 받아야 한다.
1. 개인정보를 제공받는 자
2. 개인정보를 제공받는 자의 개인정보 이용 목적
3. 제공하는 개인정보의 항목
4. 개인정보를 제공받는 자의 개인정보 보유 및 이용 기간
5. 동의를 거부할 권리가 있다는 사실 및 동의 거부에 따른 불이익이 있는 경우
에는 그 불이익의 내용
③ 개인정보처리자가 개인정보를 국외의 제3자에게 제공할 때에는 제2항 각 호에 따
른 사항을 정보주체에게 알리고 동의를 받아야 하며, 이 법을 위반하는 내용으로 
개인정보의 국외 이전에 관한 계약을 체결하여서는 아니 된다.
제22조(동의를 받는 방법)
① 개인정보처리자는 이 법에 따른 개인정보의 처리에 대하여 정보주체(제5항에 따른 
법정대리인을 포함한다. 이하 이 조에서 같다)의 동의를 받을 때에는 각각의 동의 
사항을 구분하여 정보주체가 이를 명확하게 인지할 수 있도록 알리고 각각 동의
를 받아야 한다.
② 개인정보처리자는 제15조제1항제1호, 제17조제1항제1호, 제23조제1항제1호 및 
제24조제1항 제1호에 따라 개인정보의 처리에 대하여 정보주체의 동의를 받을 
때에는 정보주체와의 계약 체결 등을 위하여 정보주체의 동의 없이 처리할 수 있
는 개인정보와 정보주체의 동의가 필요한 개인정보를 구분하여야 한다. 이 경우 
동의 없이 처리할 수 있는 개인정보라는 입증책임은 개인정보처리자가 부담한다.
③ 개인정보처리자는 정보주체에게 재화나 서비스를 홍보하거나 판매를 권유하기 위
하여 개인정보의 처리에 대한 동의를 받으려는 때에는 정보주체가 이를 명확하게 
인지할 수 있도록 알리고 동의를 받아야 한다.
④ 개인정보처리자는 정보주체가 제2항에 따라 선택적으로 동의할 수 있는 사항을 
동의하지 아니하거나 제3항 및 제18조제2항제1호에 따른 동의를 하지 아니한다
는 이유로 정보주체에게 재화 또는 서비스의 제공을 거부하여서는 아니 된다.
⑤ 개인정보처리자는 만 14세 미만 아동의 개인정보를 처리하기 위하여 이 법에 따
른 동의를 받아야 할 때에는 그 법정대리인의 동의를 받아야 한다. 이 경우 법정
대리인의 동의를 받기 위하여 필요한 최소한의 정보는 법정대리인의 동의 없이 
해당 아동으로부터 직접 수집할 수 있다.
⑥ 제1항부터 제5항까지에서 규정한 사항 외에 정보주체의 동의를 받는 세부적인 방
법 및 제5항에 따른 최소한의 정보의 내용에 관하여 필요한 사항은 개인정보의 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (258, 4, 125, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
125
수집매체 등을 고려하여 대통령령으로 정한다.
제23조(민감정보의 처리 제한)
① 개인정보처리자는 사상·신념, 노동조합·정당의 가입·탈퇴, 정치적 견해, 건강, 성생
활 등에 관한 정보, 그 밖에 정보주체의 사생활을 현저히 침해할 우려가 있는 개
인정보로서 대통령령으로 정하는 정보(이하 "민감정보"라 한다)를 처리하여서는 
아니 된다. 다만, 다음 각 호의 어느 하나에 해당하는 경우에는 그러하지 아니하
다.
1. 정보주체에게 제15조제2항 각 호 또는 제17조제2항 각 호의 사항을 알리고 
다른 개인정보의 처리에 대한 동의와 별도로 동의를 받은 경우
2. 법령에서 민감정보의 처리를 요구하거나 허용하는 경우
② 개인정보처리자가 제1항 각 호에 따라 민감정보를 처리하는 경우에는 그 민감정
보가 분실·도난·유출·위조·변조 또는 훼손되지 아니하도록 제29조에 따른 안전성 
확보에 필요한 조치를 하여야 한다.
제24조(고유식별정보의 처리 제한)
① 개인정보처리자는 다음 각 호의 경우를 제외하고는 법령에 따라 개인을 고유하게 
구별하기 위하여 부여된 식별정보로서 대통령령으로 정하는 정보(이하 "고유식별
정보"라 한다)를 처리할 수 없다.
1. 정보주체에게 제15조제2항 각 호 또는 제17조제2항 각 호의 사항을 알리고 
다른 개인정보의 처리에 대한 동의와 별도로 동의를 받은 경우
2. 법령에서 구체적으로 고유식별정보의 처리를 요구하거나 허용하는 경우
② 개인정보처리자가 제1항 각 호에 따라 고유식별정보를 처리하는 경우에는 그 고
유식별정보가 분실·도난·유출·위조·변조 또는 훼손되지 아니하도록 대통령령으로 
정하는 바에 따라 암호화 등 안전성 확보에 필요한 조치를 하여야 한다.
③ 행정자치부장관은 처리하는 개인정보의 종류·규모, 종업원 수 및 매출액 규모 등
을 고려하여 대통령령으로 정하는 기준에 해당하는 개인정보처리자가 제3항에 따
라 안전성 확보에 필요한 조치를 하였는지에 관하여 대통령령으로 정하는 바에 
따라 정기적으로 조사하여야 한다.
④ 행정자치부장관은 대통령령으로 정하는 전문기관으로 하여금 제4항에 따른 조사
를 수행하게 할 수 있다.
【법규2】 개인정보 보호법 시행령
제17조(동의를 받는 방법)
① 개인정보처리자는 법 제22조에 따라 개인정보의 처리에 대하여 다음 각 호의 어
느 하나에 해당하는 방법으로 정보주체의 동의를 받아야 한다.
1. 동의 내용이 적힌 서면을 정보주체에게 직접 발급하거나 우편 또는 팩스 등의 
방법으로 전달하고, 정보주체가 서명하거나 날인한 동의서를 받는 방법
2. 전화를 통하여 동의 내용을 정보주체에게 알리고 동의의 의사표시를 확인하는 
방법
3. 전화를 통하여 동의 내용을 정보주체에게 알리고 정보주체에게 인터넷주소 등
을 통하여 동의 사항을 확인하도록 한 후 다시 전화를 통하여 그 동의 사항에 
대한 동의의 의사표시를 확인하는 방법
4. 인터넷 홈페이지 등에 동의 내용을 게재하고 정보주체가 동의 여부를 표시하
도록 하는 방법
5. 동의 내용이 적힌 전자우편을 발송하여 정보주체로부터 동의의 의사표시가 적
힌 전자우편을 받는 방법
6. 그 밖에 제1호부터 제5호까지의 규정에 따른 방법에 준하는 방법으로 동의 내
용을 알리고 동의의 의사표시를 확인하는 방법
② 개인정보처리자가 정보주체로부터 법 제18조제2항제1호 및 제22조제3항에 따른 
동의를 받거나 법 제22조제2항에 따라 선택적으로 동의할 수 있는 사항에 대한 
동의를 받으려는 때에는 정보주체가 동의 여부를 선택할 수 있다는 사실을 명확
하게 확인할 수 있도록 선택적으로 동의할 수 있는 사항 외의 사항과 구분하여 
표시하여야 한다.
③ 개인정보처리자는 법 제22조제5항에 따라 만 14세 미만 아동의 법정대리인의 동
의를 받기 위하여 해당 아동으로부터 직접 법정대리인의 성명·연락처에 관한 정보
를 수집할 수 있다.
④ 중앙행정기관의 장은 제1항에 따른 동의방법 중 소관 분야의 개인정보처리자별 
업무, 업종의 특성 및 정보주체의 수 등을 고려하여 적절한 동의방법에 관한 기준
을 법 제12조제2항에 따른 개인정보 보호지침(이하 "개인정보 보호지침"이라 한
다)으로 정하여 그 기준에 따라 동의를 받도록 개인정보처리자에게 권장할 수 있
다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (259, 4, 126, '126
【법규3】 국민건강보험법
제42조(요양기관)
① 요양급여(간호와 이송은 제외한다)는 다음 각 호의 요양기관에서 실시한다. 이 경
우 보건복지부장관은 공익이나 국가정책에 비추어 요양기관으로 적합하지 아니한 
대통령령으로 정하는 의료기관 등은 요양기관에서 제외할 수 있다.
1. 「의료법」에 따라 개설된 의료기관
2. 「약사법」에 따라 등록된 약국
3. 「약사법」 제91조에 따라 설립된 한국희귀의약품센터
4. 「지역보건법」에 따른 보건소·보건의료원 및 보건지소
5. 「농어촌 등 보건의료를 위한 특별조치법」에 따라 설치된 보건진료소
② 보건복지부장관은 효율적인 요양급여를 위하여 필요하면 보건복지부령으로 정하는 
바에 따라 시설·장비·인력 및 진료과목 등 보건복지부령으로 정하는 기준에 해당
하는 요양기관을 전문요양기관으로 인정할 수 있다. 이 경우 해당 전문요양기관에 
인정서를 발급하여야 한다.
③ 보건복지부장관은 제2항에 따라 인정받은 요양기관이 다음 각 호의 어느 하나에 
해당하는 경우에는 그 인정을 취소한다.
1. 제2항 전단에 따른 인정기준에 미달하게 된 경우
2. 제2항 후단에 따라 발급받은 인정서를 반납한 경우
④ 제2항에 따라 전문요양기관으로 인정된 요양기관 또는 「의료법」 제3조의4에 따른 
상급종합병원에 대하여는 제41조제3항에 따른 요양급여의 절차 및 제45조에 따
른 요양급여비용을 다른 요양기관과 달리 할 수 있다.
⑤ 제1항·제2항 및 제4항에 따른 요양기관은 정당한 이유 없이 요양급여를 거부하지 
못한다.
【법규4】 노인장기요양보험법 시행령
제7조(등급판정기준 등) 
① 법 제15조제2항에 따른 등급판정기준은 다음 각 호와 같다.
1. 장기요양 1등급 ： 심신의 기능상태 장애로 일상생활에서 전적으로 다른 사람
의 도움이 필요한 자로서 장기요양인정 점수가 95점 이상인 자
2. 장기요양 2등급 ： 심신의 기능상태 장애로 일상생활에서 상당 부분 다른 사
람의 도움이 필요한 자로서 장기요양인정 점수가 75점 이상 95점 미만인 자
3. 장기요양 3등급 ： 심신의 기능상태 장애로 일상생활에서 부분적으로 다른 사
람의 도움이 필요한 자로서 장기요양인정 점수가 60점 이상 75점 미만인 자
4. 장기요양 4등급： 심신의 기능상태 장애로 일상생활에서 일정부분 다른 사람
의 도움이 필요한 자로서 장기요양인정 점수가 51점 이상 60점 미만인 자
5. 장기요양 5등급： 치매(제2조에 따른 노인성 질병에 해당하는 치매로 한정한
다)환자로서 장기요양인정 점수가 45점 이상 51점 미만인 자
② 제1항에 따른 장기요양인정 점수는 장기요양이 필요한 정도를 나타내는 점수로서 
보건복지부장관이 정하여 고시하는 심신의 기능 저하 상태를 측정하는 방법에 따
라 산정한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (260, 4, 127, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
127
【법규5】 도로교통법
제43조(무면허운전 등의 금지)
누구든지 제80조에 따라 지방경찰청장으로부터 운전면허를 받지 아니하거나 운전면
허의 효력이 정지된 경우에는 자동차등을 운전하여서는 아니 된다.
제44조(술에 취한 상태에서의 운전 금지)
① 누구든지 술에 취한 상태에서 자동차등(「건설기계관리법」 제26조제1항 단서에 따
른 건설기계 외의 건설기계를 포함한다. 이하 이 조, 제45조, 제47조, 제93조제1
항제1호부터 제4호까지 및 제148조의2에서 같다)을 운전하여서는 아니 된다.
② 경찰공무원은 교통의 안전과 위험방지를 위하여 필요하다고 인정하거나 제1항을 
위반하여 술에 취한 상태에서 자동차등을 운전하였다고 인정할 만한 상당한 이유
가 있는 경우에는 운전자가 술에 취하였는지를 호흡조사로 측정할 수 있다. 이 경
우 운전자는 경찰공무원의 측정에 응하여야 한다.
③ 제2항에 따른 측정 결과에 불복하는 운전자에 대하여는 그 운전자의 동의를 받아 
혈액 채취 등의 방법으로 다시 측정할 수 있다.
④ 제1항에 따라 운전이 금지되는 술에 취한 상태의 기준은 운전자의 혈중알코올농
도가 0.05퍼센트 이상인 경우로 한다.
【법규6】 민법
제27조(실종의 선고)
① 부재자의 생사가 5년간 분명하지 아니한 때에는 법원은 이해관계인이나 검사의 
청구에 의하여 실종선고를 하여야 한다.
② 전지에 임한 자, 침몰한 선박 중에 있던 자, 추락한 항공기 중에 있던 자 기타 사
망의 원인이 될 위난을 당한 자의 생사가 전쟁종지후 또는 선박의 침몰, 항공기의 
추락 기타 위난이 종료한 후 1년간 분명하지 아니한 때에도 제1항과 같다.
제753조(미성년자의 책임능력)
미성년자가 타인에게 손해를 가한 경우에 그 행위의 책임을 변식할 지능이 없는 때에
는 배상의 책임이 없다.
제754조(심신상실자의 책임능력)
심신상실 중에 타인에게 손해를 가한 자는 배상의 책임이 없다. 그러나 고의 또는 과
실로 인하여 심신상실을 초래한 때에는 그러하지 아니하다.
제755조(감독자의 책임)
① 다른 자에게 손해를 가한 사람이 제753조 또는 제754조에 따라 책임이 없는 경
우에는 그를 감독할 법정의무가 있는 자가 그 손해를 배상할 책임이 있다. 다만, 
감독의무를 게을리하지 아니한 경우에는 그러하지 아니하다.
② 감독의무자를 갈음하여 제753조 또는 제754조에 따라 책임이 없는 사람을 감독
하는 자도 제1항의 책임이 있다.
제777조(친족의 범위)
친족관계로 인한 법률상 효력은 이 법 또는 다른 법률에 특별한 규정이 없는 한 다
음 각호에 해당하는 자에 미친다.
1. 8촌 이내의 혈족
2. 4촌 이내의 인척
3. 배우자
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (261, 4, 128, '128
【법규7】 상법
제651조(고지위반으로 인한 계약 해지)
보험계약당시에 보험계약자 또는 피보험자가 고의 또는 중대한 과실로 인하여 중요한 
사항을 고지하지 아니하거나 부실의 고지를 한 때에는 보험자는 그 사실을 안 날로부
터 1월 내에, 계약을 체결한 날로부터 3년내에 한하여 계약을 해지할 수 있다. 그러
나 보험자가 계약당시에 그 사실을 알았거나 중대한 과실로 인하여 알지 못한 때에는 
그러하지 아니하다.
제657조(보험사고발생의 통지의무) 
① 보험계약자 또는 피보험자나 보험수익자는 보험사고의 발생을 안 때에는 지체없이 
보험자에게 그 통지를 발송하여야 한다.
② 보험계약자 또는 피보험자나 보험수익자가 제1항의 통지의무를 해태함으로 인하
여 손해가 증가된 때에는 보험자는 그 증가된 손해를 보상할 책임이 없다.
【법규8】 성폭력범죄의 처벌 등에 관한 특례법
제2장 성폭력범죄의 처벌 및 절차에 관한 특례
제3조(특수강도강간 등)
① 「형법」 제319조제1항(주거침입), 제330조(야간주거침입절도), 제331조(특수절도) 
또는 제342조(미수범. 다만, 제330조 및 제331조의 미수범으로 한정한다)의 죄
를 범한 사람이 같은 법 제297조(강간), 제297조의2(유사강간), 제298조(강제추
행) 및 제299조(준강간, 준강제추행)의 죄를 범한 경우에는 무기징역 또는 5년 
이상의 징역에 처한다.
② 「형법」 제334조(특수강도) 또는 제342조(미수범. 다만, 제334조의 미수범으로 한
정한다)의 죄를 범한 사람이 같은 법 제297조(강간), 제297조의2(유사강간), 제
298조(강제추행) 및 제299조(준강간, 준강제추행)의 죄를 범한 경우에는 사형, 무
기징역 또는 10년 이상의 징역에 처한다.
제4조(특수강간 등)
① 흉기나 그 밖의 위험한 물건을 지닌 채 또는 2명 이상이 합동하여 「형법」 제297
조(강간)의 죄를 범한 사람은 무기징역 또는 5년 이상의 징역에 처한다.
② 제1항의 방법으로 「형법」 제298조(강제추행)의 죄를 범한 사람은 3년 이상의 유
기징역에 처한다.
③ 제1항의 방법으로 「형법」 제299조(준강간, 준강제추행)의 죄를 범한 사람은 제1항 
또는 제2항의 예에 따라 처벌한다.
제5조(친족관계에 의한 강간 등)
① 친족관계인 사람이 폭행 또는 협박으로 사람을 강간한 경우에는 7년 이상의 유기
징역에 처한다.
② 친족관계인 사람이 폭행 또는 협박으로 사람을 강제추행한 경우에는 5년 이상의 
유기징역에 처한다.
③ 친족관계인 사람이 사람에 대하여 「형법」 제299조(준강간, 준강제추행)의 죄를 범
한 경우에는 제1항 또는 제2항의 예에 따라 처벌한다.
④ 제1항부터 제3항까지의 친족의 범위는 4촌 이내의 혈족·인척과 동거하는 친족으
로 한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (262, 4, 129, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
129
⑤ 제1항부터 제3항까지의 친족은 사실상의 관계에 의한 친족을 포함한다.
제6조(장애인에 대한 강간·강제추행 등)
① 신체적인 또는 정신적인 장애가 있는 사람에 대하여 「형법」 제297조(강간)의 죄를 
범한 사람은 무기징역 또는 7년 이상의 징역에 처한다.
② 신체적인 또는 정신적인 장애가 있는 사람에 대하여 폭행이나 협박으로 다음 각 
호의 어느 하나에 해당하는 행위를 한 사람은 5년 이상의 유기징역에 처한다.
1. 구강·항문 등 신체(성기는 제외한다)의 내부에 성기를 넣는 행위
2. 성기·항문에 손가락 등 신체(성기는 제외한다)의 일부나 도구를 넣는 행위
③ 신체적인 또는 정신적인 장애가 있는 사람에 대하여 「형법」 제298조(강제추행)의 
죄를 범한 사람은 3년 이상의 유기징역 또는 2천만원 이상 5천만원 이하의 벌금
에 처한다.
④ 신체적인 또는 정신적인 장애로 항거불능 또는 항거곤란 상태에 있음을 이용하여 
사람을 간음하거나 추행한 사람은 제1항부터 제3항까지의 예에 따라 처벌한다.
⑤ 위계(僞計) 또는 위력(威力)으로써 신체적인 또는 정신적인 장애가 있는 사람을 간
음한 사람은 5년 이상의 유기징역에 처한다.
⑥ 위계 또는 위력으로써 신체적인 또는 정신적인 장애가 있는 사람을 추행한 사람은 
1년 이상의 유기징역 또는 1천만원 이상 3천만원 이하의 벌금에 처한다.
⑦ 장애인의 보호, 교육 등을 목적으로 하는 시설의 장 또는 종사자가 보호, 감독의 
대상인 장애인에 대하여 제1항부터 제6항까지의 죄를 범한 경우에는 그 죄에 정
한 형의 2분의 1까지 가중한다.
제7조(13세 미만의 미성년자에 대한 강간, 강제추행 등)
① 13세 미만의 사람에 대하여 「형법」 제297조(강간)의 죄를 범한 사람은 무기징역 
또는 10년 이상의 징역에 처한다.
② 13세 미만의 사람에 대하여 폭행이나 협박으로 다음 각 호의 어느 하나에 해당하
는 행위를 한 사람은 7년 이상의 유기징역에 처한다.
1. 구강·항문 등 신체(성기는 제외한다)의 내부에 성기를 넣는 행위
2. 성기·항문에 손가락 등 신체(성기는 제외한다)의 일부나 도구를 넣는 행위
③ 13세 미만의 사람에 대하여 「형법」 제298조(강제추행)의 죄를 범한 사람은 5년 
이상의 유기징역 또는 3천만원 이상 5천만원 이하의 벌금에 처한다.
④ 13세 미만의 사람에 대하여 「형법」 제299조(준강간, 준강제추행)의 죄를 범한 사
람은 제1항부터 제3항까지의 예에 따라 처벌한다.
⑤ 위계 또는 위력으로써 13세 미만의 사람을 간음하거나 추행한 사람은 제1항부터 
제3항까지의 예에 따라 처벌한다.
제8조(강간 등 상해·치상)
① 제3조제1항, 제4조, 제6조, 제7조 또는 제15조(제3조제1항, 제4조, 제6조 또는 
제7조의 미수범으로 한정한다)의 죄를 범한 사람이 다른 사람을 상해하거나 상해
에 이르게 한 때에는 무기징역 또는 10년 이상의 징역에 처한다.
② 제5조 또는 제15조(제5조의 미수범으로 한정한다)의 죄를 범한 사람이 다른 사람
을 상해하거나 상해에 이르게 한 때에는 무기징역 또는 7년 이상의 징역에 처한
다.
제9조(강간 등 살인·치사)
① 제3조부터 제7조까지, 제15조(제3조부터 제7조까지의 미수범으로 한정한다)의 죄 
또는 「형법」 제297조(강간), 제297조의2(유사강간) 및 제298조(강제추행)부터 제
300조(미수범)까지의 죄를 범한 사람이 다른 사람을 살해한 때에는 사형 또는 무
기징역에 처한다.
② 제4조, 제5조 또는 제15조(제4조 또는 제5조의 미수범으로 한정한다)의 죄를 범
한 사람이 다른 사람을 사망에 이르게 한 때에는 무기징역 또는 10년 이상의 징
역에 처한다.
③ 제6조, 제7조 또는 제15조(제6조 또는 제7조의 미수범으로 한정한다)의 죄를 범
한 사람이 다른 사람을 사망에 이르게 한 때에는 사형, 무기징역 또는 10년 이상
의 징역에 처한다.
제10조(업무상 위력 등에 의한 추행)
① 업무, 고용이나 그 밖의 관계로 인하여 자기의 보호, 감독을 받는 사람에 대하여 
위계 또는 위력으로 추행한 사람은 2년 이하의 징역 또는 500만원 이하의 벌금
에 처한다.
② 법률에 따라 구금된 사람을 감호하는 사람이 그 사람을 추행한 때에는 3년 이하
의 징역 또는 1천500만원 이하의 벌금에 처한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (263, 4, 130, '130
제11조(공중 밀집 장소에서의 추행)
대중교통수단, 공연·집회 장소, 그 밖에 공중(公衆)이 밀집하는 장소에서 사람을 추행
한 사람은 1년 이하의 징역 또는 300만원 이하의 벌금에 처한다.
제12조(성적 목적을 위한 공공장소 침입행위)
자기의 성적 욕망을 만족시킬 목적으로 「공중화장실 등에 관한 법률」 제2조제1호부터 
제5호까지에 따른 공중화장실 등 및 「공중위생관리법」 제2조제1항제3호에 따른 목욕
장업의 목욕장 등 대통령령으로 정하는 공공장소에 침입하거나 같은 장소에서 퇴거의 
요구를 받고 응하지 아니하는 사람은 1년 이하의 징역 또는 300만원 이하의 벌금에 
처한다.
제13조(통신매체를 이용한 음란행위)
자기 또는 다른 사람의 성적 욕망을 유발하거나 만족시킬 목적으로 전화, 우편, 컴퓨
터, 그 밖의 통신매체를 통하여 성적 수치심이나 혐오감을 일으키는 말, 음향, 글, 그
림, 영상 또는 물건을 상대방에게 도달하게 한 사람은 2년 이하의 징역 또는 500만
원 이하의 벌금에 처한다.
제14조(카메라 등을 이용한 촬영)
① 카메라나 그 밖에 이와 유사한 기능을 갖춘 기계장치를 이용하여 성적 욕망 또는 
수치심을 유발할 수 있는 다른 사람의 신체를 그 의사에 반하여 촬영하거나 그 
촬영물을 반포·판매·임대·제공 또는 공공연하게 전시·상영한 자는 5년 이하의 징역 
또는 1천만원 이하의 벌금에 처한다.
② 제1항의 촬영이 촬영 당시에는 촬영대상자의 의사에 반하지 아니하는 경우에도 
사후에 그 의사에 반하여 촬영물을 반포·판매·임대·제공 또는 공공연하게 전시·상
영한 자는 3년 이하의 징역 또는 500만원 이하의 벌금에 처한다.
③ 영리를 목적으로 제1항의 촬영물을 「정보통신망 이용촉진 및 정보보호 등에 관한 
법률」 제2조제1항제1호의 정보통신망(이하 "정보통신망"이라 한다)을 이용하여 유
포한 자는 7년 이하의 징역 또는 3천만원 이하의 벌금에 처한다.
제15조(미수범) 
제3조부터 제9조까지 및 제14조의 미수범은 처벌한다.
【법규9】 신용정보의 이용 및 보호에 관한 법률
제16조(수집·조사 및 처리의 제한) 제2항
② 신용정보회사등이 개인의 질병에 관한 정보를 수집·조사하거나 타인에게 제공하려
면 미리 제32조제1항에 따른 해당 개인의 동의를 받아야 하며 대통령령으로 정하
는 목적으로만 그 정보를 이용하여야 한다.
제32조(개인신용정보의 제공․활용에 대한 동의)
① 신용정보제공·이용자가 개인신용정보를 타인에게 제공하려는 경우에는 대통령령으로 
정하는 바에 따라 해당 신용정보주체로부터 다음 각 호의 어느 하나에 해당하는 방식
으로 개인신용정보를 제공할 때마다 미리 개별적으로 동의를 받아야 한다. 다만, 기존
에 동의한 목적 또는 이용 범위에서 개인신용정보의 정확성·최신성을 유지하기 위한 
경우에는 그러하지 아니하다.
1. 서면
2. 「전자서명법」 제2조제3호에 따른 공인전자서명이 있는 전자문서(「전자거래기본
법」 제2조제1호에 따른 전자문서를 말한다)
3. 개인신용정보의 제공 내용 및 제공 목적 등을 고려하여 정보 제공 동의의 안
정성과 신뢰성이 확보될 수 있는 유무선 통신으로 개인비밀번호를 입력하는 
방식
4. 유무선 통신으로 동의 내용을 해당 개인에게 알리고 동의를 받는 방법. 이 경
우 본인 여부 및 동의 내용, 그에 대한 해당 개인의 답변을 음성녹음하는 등 
증거자료를 확보·유지하여야 하며, 대통령령으로 정하는 바에 따른 사후 고지
절차를 거친다.
5. 그 밖에 대통령령으로 정하는 방식
② 신용조회회사 또는 신용정보집중기관으로부터 개인신용정보를 제공받으려는 자는 대통
령령으로 정하는 바에 따라 해당 신용정보주체로부터 제1항 각 호의 어느 하나에 해
당하는 방식으로 개인신용정보를 제공받을 때마다 개별적으로 동의(기존에 동의한 목
적 또는 이용 범위에서 개인신용정보의 정확성·최신성을 유지하기 위한 경우는 제외한
다)를 받아야 한다. 이 경우 개인신용정보를 제공받으려는 자는 개인신용정보의 조회 
시 신용등급이 하락할 수 있는 때에는 해당 신용정보주체에게 이를 고지하여야 한다.
③ 신용조회회사 또는 신용정보집중기관이 개인신용정보를 제2항에 따라 제공하는 
경우에는 해당 개인신용정보를 제공받으려는 자가 제2항에 따른 동의를 받았는지
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (264, 4, 131, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
131
를 대통령령으로 정하는 바에 따라 확인하여야 한다.
④ 신용정보회사등은 개인신용정보의 제공 및 활용과 관련하여 동의를 받을 때에는 
대통령령으로 정하는 바에 따라 서비스 제공을 위하여 필수적 동의사항과 그 밖
의 선택적 동의사항을 구분하여 설명한 후 각각 동의를 받아야 한다. 이 경우 필
수적 동의사항은 서비스 제공과의 관련성을 설명하여야 하며, 선택적 동의사항은 
정보제공에 동의하지 아니할 수 있다는 사실을 고지하여야 한다.
⑤ 신용정보회사등은 신용정보주체가 선택적 동의사항에 동의하지 아니한다는 이유로 
신용정보주체에게 서비스의 제공을 거부하여서는 아니 된다.
⑥ 신용정보회사등이 개인신용정보를 제공하는 경우로서 다음 각 호의 어느 하나에 
해당하는 경우에는 제1항부터 제5항까지를 적용하지 아니한다.
1. 신용정보회사가 다른 신용정보회사 또는 신용정보집중기관과 서로 집중관리·활
용하기 위하여 제공하는 경우
2. 계약의 이행에 필요한 경우로서 제17조제2항에 따라 신용정보의 처리를 위탁
하기 위하여 제공하는 경우
3. 영업양도·분할·합병 등의 이유로 권리·의무의 전부 또는 일부를 이전하면서 그
와 관련된 개인신용정보를 제공하는 경우
4. 채권추심(추심채권을 추심하는 경우만 해당한다), 인가·허가의 목적, 기업의 신
용도 판단, 유가증권의 양수 등 대통령령으로 정하는 목적으로 사용하는 자에
게 제공하는 경우
5. 법원의 제출명령 또는 법관이 발부한 영장에 따라 제공하는 경우
6. 범죄 때문에 피해자의 생명이나 신체에 심각한 위험 발생이 예상되는 등 긴급
한 상황에서 제5호에 따른 법관의 영장을 발부받을 시간적 여유가 없는 경우
로서 검사 또는 사법경찰관의 요구에 따라 제공하는 경우. 이 경우 개인신용정
보를 제공받은 검사는 지체 없이 법관에게 영장을 청구하여야 하고, 사법경찰
관은 검사에게 신청하여 검사의 청구로 영장을 청구하여야 하며, 개인신용정보
를 제공받은 때부터 36시간 이내에 영장을 발부받지 못하면 지체 없이 제공받
은 개인신용정보를 폐기하여야 한다.
7. 조세에 관한 법률에 따른 질문·검사 또는 조사를 위하여 관할 관서의 장이 서
면으로 요구하거나 조세에 관한 법률에 따라 제출의무가 있는 과세자료의 제
공을 요구함에 따라 제공하는 경우
8. 국제협약 등에 따라 외국의 금융감독기구에 금융회사가 가지고 있는 개인신용
정보를 제공하는 경우
9. 그 밖에 다른 법률에 따라 제공하는 경우
⑦ 제6항 각 호에 따라 개인신용정보를 타인에게 제공하려는 자 또는 제공받은 자는 
대통령령으로 정하는 바에 따라 개인신용정보의 제공 사실 및 이유 등을 사전에 
해당 신용정보주체에게 알려야 한다. 다만, 대통령령으로 정하는 불가피한 사유가 
있는 경우에는 인터넷 홈페이지 게재 또는 그 밖에 유사한 방법을 통하여 사후에 
알리거나 공시할 수 있다.
⑧ 제6항제3호에 따라 개인신용정보를 타인에게 제공하는 신용정보제공·이용자로서 
대통령령으로 정하는 자는 제공하는 신용정보의 범위 등 대통령령으로 정하는 사
항에 관하여 금융위원회의 승인을 받아야 한다.
⑨ 제8항에 따른 승인을 받아 개인신용정보를 제공받은 자는 해당 개인신용정보를 
금융위원회가 정하는 바에 따라 현재 거래 중인 신용정보주체의 개인신용정보와 
분리하여 관리하여야 한다.
⑩ 신용정보회사등이 개인신용정보를 제공하는 경우에는 금융위원회가 정하여 고시하
는 바에 따라 개인신용정보를 제공받는 자의 신원(身元)과 이용 목적을 확인하여
야 한다.
⑪ 개인신용정보를 제공한 신용정보제공·이용자는 제1항에 따라 미리 개별적 동의를 
받았는지 여부 등에 대한 다툼이 있는 경우 이를 증명하여야 한다.
제33조(개인신용정보의 이용)
개인신용정보는 해당 신용정보주체가 신청한 금융거래 등 상거래관계의 설정 및 유지 
여부 등을 판단하기 위한 목적으로만 이용하여야 한다. 다만, 다음 각 호의 어느 하
나에 해당하는 경우에는 그러하지 아니하다.
1. 개인이 제32조제1항 각 호의 방식으로 이 조 각 호 외의 부분 본문에서 정한 
목적 외의 다른 목적에의 이용에 동의한 경우
2. 개인이 직접 제공한 개인신용정보(그 개인과의 상거래에서 생긴 신용정보를 포
함한다)를 제공받은 목적으로 이용하는 경우(상품과 서비스를 소개하거나 그 
구매를 권유할 목적으로 이용하는 경우는 제외한다)
3. 제32조제6항 각 호의 경우
4. 그 밖에 제1호부터 제3호까지의 규정에 준하는 경우로서 대통령령으로 정하는 
경우
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (265, 4, 132, '132
【법규10】 신용정보의 이용 및 보호에 관한 법률 시행령
제28조(개인신용정보의 제공·활용에 대한 동의)
① 삭제  <2015.9.11.>
② 신용정보제공·이용자는 법 제32조제1항 각 호 외의 부분 본문에 따라 해당 신용정
보주체로부터 동의를 받으려면 다음 각 호의 사항을 미리 알려야 한다. 다만, 동의 
방식의 특성상 동의 내용을 전부 표시하거나 알리기 어려운 경우에는 해당 기관의 
인터넷 홈페이지 주소나 사업장 전화번호 등 동의 내용을 확인할 수 있는 방법을 
안내하고 동의를 받을 수 있다.
1. 개인신용정보를 제공받는 자
2. 개인신용정보를 제공받는 자의 이용 목적
3. 제공하는 개인신용정보의 내용
4. 개인신용정보를 제공받는 자(신용조회회사 및 신용정보집중기관은 제외한다)의 
정보 보유 기간 및 이용 기간
③ 신용정보제공·이용자는 법 제32조제1항제4호에 따라 유무선 통신을 통하여 동의
를 받은 경우에는 1개월 이내에 서면, 전자우편, 휴대전화 문자메시지, 그 밖에 
금융위원회가 정하여 고시하는 방법으로 제2항 각 호의 사항을 고지하여야 한다.
④ 법 제32조제1항제5호에서 "대통령령으로 정하는 방식"이란 정보 제공 동의의 안전성
과 신뢰성이 확보될 수 있는 수단을 활용함으로써 해당 신용정보주체에게 동의 내용
을 알리고 동의의 의사표시를 확인하여 동의를 받는 방식을 말한다.
⑤ 제4항의 방식으로 해당 신용정보주체로부터 개인신용정보의 제공에 관한 동의를 받는 
경우 신용정보제공·이용자와 신용조회회사 또는 신용정보집중기관으로부터 개인신용정
보를 제공받으려는 자는 다음 각 호의 사항 등을 고려하여 정보 제공 동의의 안전성
과 신뢰성이 확보될 수 있는 수단을 채택하여 활용하여야 한다.
1. 금융거래 등 상거래관계의 유형·특성·위험도
2. 신용정보제공·이용자 또는 신용조회회사 또는 신용정보집중기관으로부터 개인신용
정보를 제공받으려는 자의 업무 또는 업종의 특성
3. 정보 제공 동의를 받아야 하는 신용정보주체의 수
⑥ 법 제32조제2항에 따라 신용조회회사 또는 신용정보집중기관으로부터 개인신용정
보를 제공받으려는 자는 다음 각 호의 사항을 해당 개인에게 알리고 동의를 받아
야 한다. 다만, 동의방식의 특성상 동의 내용을 전부 표시하거나 알리기 어려운 
경우에는 해당 기관의 인터넷 홈페이지 주소나 사업장 전화번호 등 동의 내용을 
확인할 수 있는 방법을 안내하고 동의를 받을 수 있다.
1. 개인신용정보를 제공하는 자
2. 개인신용정보를 제공받는 자의 이용 목적
3. 제공받는 개인신용정보의 항목
4. 개인신용정보를 제공받는 것에 대한 동의의 효력기간
⑦ 법 제32조제3항에 따라 신용조회회사 또는 신용정보집중기관은 개인신용정보를 
제공받으려는 자가 해당 신용정보주체로부터 동의를 받았는지를 서면, 전자적 기
록 등으로 확인하고, 확인한 사항의 진위 여부를 주기적으로 점검하여야 한다.
⑧ 법 제32조제4항 전단에 따라 신용정보회사등이 필수적 동의사항과 그 밖의 선택적 동
의사항을 구분하는 경우에는 다음 각 호의 사항 등을 고려하여야 한다.
1. 신용정보주체가 그 동의사항에 대하여 동의하지 아니하면 그 신용정보주체와의 금
융거래 등 상거래관계를 설정·유지할 수 없는지 여부
2. 해당 신용정보주체가 그 동의사항에 대하여 동의함으로써 제공·활용되는 개인신용
정보가 신용정보회사등과의 상거래관계에 따라 신용정보주체에게 제공되는 재화 
또는 서비스(신용정보주체가 그 신용정보회사등에 신청한 상거래관계에서 제공하
기로 한 재화 또는 서비스를 그 신용정보회사등과 별도의 계약 또는 약정 등을 체
결한 제3자가 신용정보주체에게 제공하는 경우를 포함한다)와 직접적으로 관련되
어 있는지 여부
3. 신용정보주체가 그 동의사항에 대하여 동의하지 아니하면 법 또는 다른 법령에 따
른 의무를 이행할 수 없는지 여부
⑨ 신용정보회사등이 법 제32조제4항 전단에 따라 필수적 동의 사항과 그 밖의 선택적 
동의사항을 구분하여 동의를 받는 경우 동의서 양식을 구분하는 등의 방법으로 신용
정보주체가 각 동의사항을 쉽게 이해할 수 있도록 하여야 한다.
⑩ 법 제32조제6항제4호에서 "채권추심(추심채권을 추심하는 경우만 해당한다), 인
가·허가의 목적, 기업의 신용도 판단, 유가증권의 양수 등 대통령령으로 정하는 목
적"이란 다음 각 호의 목적을 말한다.
1. 채권추심을 의뢰한 채권자가 채권추심의 대상이 되는 자의 개인신용정보를 채
권추심회사에 제공하거나 채권추심회사로부터 제공받기 위한 목적
2. 채권자 또는 채권추심회사가 변제기일까지 채무를 변제하지 아니한 자 또는 
채권추심의 대상이 되는 자에 대한 개인신용정보를 신용조회회사로부터 제공
받기 위한 목적
3. 행정기관이 인가·허가 업무에 사용하기 위하여 신용조회회사로부터 개인신용정
보를 제공받기 위한 목적
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (266, 4, 133, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
133
4. 해당 기업과의 금융거래 등 상거래관계의 설정 및 유지 여부 등을 판단하기 
위하여 그 기업의 대표자 및 제2조제1항제3호의 각 목의 어느 하나에 해당하
는 자의 개인신용정보를 신용정보집중기관 및 신용조회회사로부터 제공받기 
위한 목적
5. 제21조제2항에 따른 금융기관이 상거래관계의 설정 및 유지 여부 등을 판단하
기 위하여 또는 어음·수표 소지인이 어음·수표의 발행인, 인수인, 배서인 및 보
증인의 변제 의사 및 변제자력을 확인하기 위하여 신용정보집중기관 및 신용
조회회사로부터 어음·수표의 발행인, 인수인, 배서인 및 보증인의 개인신용정
보를 제공받기 위한 목적
6. 「민법」 제450조에 따라 지명채권을 양수한 신용정보제공·이용자가 다음 각 목의 
어느 하나에 해당하는 경우에 그 지명채권의 채무자의 개인신용정보를 신용조회회
사 또는 신용정보집중기관에 제공하거나 신용조회회사 또는 신용정보집중기관으로
부터 제공받기 위한 목적
   가. 지명채권의 양도인이 그 지명채권의 원인이 되는 상거래관계가 설정될 당시 
법 제32조제1항 각 호의 어느 하나에 해당하는 방식으로 채무자의 개인신용
정보를 제공하거나 제공받는 것에 대하여 해당 채무자로부터 동의를 받은 경
우
   나. 법 또는 다른 법령에 따라 그 지명채권의 채무자의 개인신용정보를 제공하거
나 제공받을 수 있는 경우
⑪ 법 제32조제6항제9호에서 "대통령령으로 정하는 금융질서문란행위자"란 다음 각 호의 
어느 하나에 해당하는 자를 말한다.
1. 부정한 목적으로 다른 신용정보주체의 개인식별정보(제29조에서 정하는 정보를 말
한다. 이하 이 호에서 같다)를 이용하여 금융거래 등 상거래를 하거나 그 상거래
를 하려는 타인에게 자신의 개인식별정보를 제공한 자
2. 부정한 목적으로 금융거래 등 상거래와 관련하여 거래상대방에게 위조·변조되거나 
허위인 신용정보를 제공한 자
3. 대출사기, 보험사기, 거짓이나 그 밖의 부정한 방법으로 알아낸 타인의 신용카드 
정보를 이용한 거래 또는 이와 유사한 금융거래 등 상거래를 한 자
4. 거짓이나 그 밖의 부정한 방법으로 법원의 회생절차개시결정·간이회생절차개시결
정·개인회생절차개시결정·파산선고 또는 이와 유사한 결정이나 판결을 받은 자
5. 그 밖에 금융거래 등 상거래와 관련하여 금융질서를 문란하게 한 자로서 금융위원
회가 정하여 고시하는 자
⑫ 신용정보회사등이 법 제32조제7항 본문에 따라 신용정보주체에게 개인신용정보의 제
공 사실 및 이유 등을 사전에 알리는 경우와 같은 항 단서에 따라 불가피한 사유로 
인하여 사후에 알리거나 공시하는 경우에 그 제공의 이유 및 그 알리거나 공시하는 
자별로 알리거나 공시하는 시기 및 방법은 별표 2의2와 같다.
⑬ 법 제32조제8항에서 "대통령령으로 정하는 자"란 제5조제1항제1호부터 제21호까지의 
규정의 어느 하나에 해당하는 기관을 말한다.
⑭ 법 제32조제8항에서 "제공하는 신용정보의 범위 등 대통령령으로 정하는 사항"이란 
제공하는 개인신용정보의 범위, 제공받는 자의 신용정보 관리·보호 체계를 말한다.
【법규11】 아동·청소년의 성보호에 관한 법률
제7조(아동·청소년에 대한 강간·강제추행 등)
① 폭행 또는 협박으로 아동·청소년을 강간한 사람은 무기징역 또는 5년 이상의 유기
징역에 처한다.
② 아동·청소년에 대하여 폭행이나 협박으로 다음 각 호의 어느 하나에 해당하는 행
위를 한 자는 5년 이상의 유기징역에 처한다.
1. 구강·항문 등 신체(성기는 제외한다)의 내부에 성기를 넣는 행위
2. 성기·항문에 손가락 등 신체(성기는 제외한다)의 일부나 도구를 넣는 행위
③ 아동·청소년에 대하여 「형법」 제298조의 죄를 범한 자는 2년 이상의 유기징역 또
는 1천만원 이상 3천만원 이하의 벌금에 처한다.
④ 아동·청소년에 대하여 「형법」 제299조의 죄를 범한 자는 제1항부터 제3항까지의 
예에 따른다.
⑤ 위계(僞計) 또는 위력으로써 아동·청소년을 간음하거나 아동·청소년을 추행한 자는 
제1항부터 제3항까지의 예에 따른다.
⑥ 제1항부터 제5항까지의 미수범은 처벌한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (267, 4, 134, '134
【법규12】 여객자동차운수사업법 시행령
제3조(여객자동차운송사업의 종류)
법 제3조제2항에 따라 같은 조 제1항제1호 및 제2호에 따른 노선 여객자동차운송사업
과 구역 여객자동차운송사업은 다음 각 호와 같이 세분한다.
1. 노선 여객자동차운송사업
  가. 시내버스운송사업: 주로 특별시·광역시·특별자치시 또는 시(「제주특별자치도 
설치 및 국제자유도시 조성을 위한 특별법」 제10조제2항에 따른 행정시를 
포함한다. 이하 같다)의 단일 행정구역에서 운행계통을 정하고 국토교통부
령으로 정하는 자동차를 사용하여 여객을 운송하는 사업. 이 경우 국토교통
부령으로 정하는 바에 따라 광역급행형·직행좌석형·좌석형 및 일반형 등으
로 그 운행형태를 구분한다.
  나. 농어촌버스운송사업: 주로 군(광역시의 군은 제외한다)의 단일 행정구역에서 
운행계통을 정하고 국토교통부령으로 정하는 자동차를 사용하여 여객을 운
송하는 사업. 이 경우 국토교통부령으로 정하는 바에 따라 직행좌석형·좌석
형 및 일반형 등으로 그 운행형태를 구분한다.
  다. 마을버스운송사업: 주로 시·군·구의 단일 행정구역에서 기점·종점의 특수성
이나 사용되는 자동차의 특수성 등으로 인하여 다른 노선 여객자동차운송
사업자가 운행하기 어려운 구간을 대상으로 국토교통부령으로 정하는 기준
에 따라 운행계통을 정하고 국토교통부령으로 정하는 자동차를 사용하여 
여객을 운송하는 사업
  라. 시외버스운송사업: 운행계통을 정하고 국토교통부령으로 정하는 자동차를 
사용하여 여객을 운송하는 사업으로서 가목부터 다목까지의 사업에 속하지 
아니하는 사업. 이 경우 국토교통부령이 정하는 바에 따라 고속형·직행형 
및 일반형 등으로 그 운행형태를 구분한다.
2. 구역 여객자동차운송사업
  가. 전세버스운송사업: 운행계통을 정하지 아니하고 전국을 사업구역으로 정하
여 1개의 운송계약에 따라 국토교통부령으로 정하는 자동차를 사용하여 여
객을 운송하는 사업. 다만, 다음 어느 하나에 해당하는 기관 또는 시설 등
의 장과 1개의 운송계약(운임의 수령주체와 관계없이 개별 탑승자로부터 
현금이나 회수권 또는 카드결제 등의 방식으로 운임을 받는 경우는 제외한
다)에 따라 그 소속원(산업단지 관리기관의 경우에는 해당 산업단지 입주기
업체의 소속원을 말한다)만의 통근·통학목적으로 자동차를 운행하는 경우에
는 운행계통을 정하지 아니한 것으로 본다.
      1) 정부기관·지방자치단체와 그 출연기관·연구기관 등 공법인
      2) 회사, 「초·중등교육법」 제2조에 따른 학교, 「고등교육법」 제2조에 따른 학
교, 「유아교육법」 제2조제2호에 따른 유치원, 「영유아보육법」 제10조에 따
른 어린이집, 「학원의 설립·운영 및 과외교습에 관한 법률」 제2조의2제1항
제1호에 따른 학교교과교습학원 또는 「체육시설의 설치·이용에 관한 법률」 
제3조에 따른 체육시설(「유통산업발전법」 제2조제3호에 따른 대규모점포에 
부설된 체육시설은 제외한다)
      3) 「산업집적활성화 및 공장설립에 관한 법률」에 따른 산업단지 중 국토교
통부장관 또는 특별시장·광역시장·특별자치시장·도지사·특별자치도지사(이하 
"시·도지사"라 한다)가 정하여 고시하는 산업단지의 관리기관
  나. 특수여객자동차운송사업: 운행계통을 정하지 아니하고 전국을 사업구역으로 
하여 1개의 운송계약에 따라 국토교통부령으로 정하는 특수한 자동차를 사
용하여 장례에 참여하는 자와 시체(유골을 포함한다)를 운송하는 사업
  다. 일반택시운송사업: 운행계통을 정하지 아니하고 국토교통부령으로 정하는 
사업구역에서 1개의 운송계약에 따라 국토교통부령으로 정하는 자동차를 
사용하여 여객을 운송하는 사업. 이 경우 국토교통부령으로 정하는 바에 따
라 경형·소형·중형·대형·모범형 및 고급형 등으로 구분한다.
  라. 개인택시운송사업: 운행계통을 정하지 아니하고 국토교통부령으로 정하는 
사업구역에서 1개의 운송계약에 따라 국토교통부령으로 정하는 자동차 1대
를 사업자가 직접 운전(사업자의 질병 등 국토교통부령으로 정하는 사유가 
있는 경우는 제외한다)하여 여객을 운송하는 사업. 이 경우 국토교통부령으
로 정하는 바에 따라 경형·소형·중형·대형·모범형 및 고급형 등으로 구분한
다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (268, 4, 135, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
135
【법규13】 응급의료에 관한 법률
제2조(정의)
이 법에서 사용하는 용어의 뜻은 다음과 같다.
1. "응급환자"란 질병, 분만, 각종 사고 및 재해로 인한 부상이나 그 밖의 위급한 
상태로 인하여 즉시 필요한 응급처치를 받지 아니하면 생명을 보존할 수 없거
나 심신에 중대한 위해(危害)가 발생할 가능성이 있는 환자 또는 이에 준하는 
사람으로서 보건복지부령으로 정하는 사람을 말한다.
2. "응급의료"란 응급환자가 발생한 때부터 생명의 위험에서 회복되거나 심신상의 
중대한 위해가 제거되기까지의 과정에서 응급환자를 위하여 하는 상담·구조(救
助)·이송·응급처치 및 진료 등의 조치를 말한다.
3. "응급처치"란 응급의료행위의 하나로서 응급환자의 기도를 확보하고 심장박동
의 회복, 그 밖에 생명의 위험이나 증상의 현저한 악화를 방지하기 위하여 긴
급히 필요로 하는 처치를 말한다.
4. "응급의료종사자"란 관계 법령에서 정하는 바에 따라 취득한 면허 또는 자격의 
범위에서 응급환자에 대한 응급의료를 제공하는 의료인과 응급구조사를 말한
다.
5. "응급의료기관"이란 「의료법」 제3조에 따른 의료기관 중에서 이 법에 따라 지
정된 중앙응급의료센터, 권역응급의료센터, 전문응급의료센터, 지역응급의료센
터 및 지역응급의료기관을 말한다.
6. "구급차등"이란 응급환자의 이송 등 응급의료의 목적에 이용되는 자동차, 선박 
및 항공기 등의 이송수단을 말한다.
7. "응급의료기관등"이란 응급의료기관, 구급차등의 운용자 및 응급의료지원센터
를 말한다.
8. "응급환자이송업"이란 구급차등을 이용하여 응급환자 등을 이송하는 업(業)을 
말한다.
제35조의2(응급의료기관 외의 의료기관) 
이 법에 따른 응급의료기관으로 지정받지 아니한 의료기관이 응급의료시설을 설치·운
영하려면 보건복지부령으로 정하는 시설·인력 등을 갖추어 시장·군수·구청장에게 신고
하여야 한다. 다만, 종합병원의 경우에는 그러하지 아니하다.
【법규14】 의료급여법 시행령
제13조(급여비용의 부담)
① 법 제10조에 따라 기금에서 부담하는 급여비용의 범위는 별표 1과 같다.
1. 삭제 <2005.7.5.>
2. 삭제 <2005.7.5.>
② 삭제 <2005.7.5.>
③ 제1항의 규정에 불구하고 법 제15조제1항의 규정에 의하여 의료급여가 제한되는 
경우, 기금에 상당한 부담을 초래한다고 인정되는 경우 등 보건복지부령이 정하는 
경우 또는 항목에 대하여는 보건복지부령이 정하는 금액을 수급권자가 부담한다.
④ 제1항의 규정에 따라 기금에서 부담하는 급여비용외에 수급권자가 부담하는 본인
부담금(이하 "급여대상 본인부담금"이라 한다)과 제3항의 규정에 따라 수급권자가 
부담하는 본인부담금은 의료급여기관의 청구에 의하여 수급권자가 의료급여기관에 
지급한다.
⑤ 제4항의 규정에 따라 의료급여기관에 지급한 급여 대상 본인부담금(별표 1 제1호
라목·마목, 같은 표 제2호마목·바목 및 같은 표 제3호에 따라 의료급여기관에 지
급한 급여 대상 본인부담금은 제외한다. 이하 이 조에서 같다)이 매 30일간 다음 
각 호의 금액을 초과한 경우에는 그 초과한 금액의 100분의 50에 해당하는 금액
을 보건복지부령이 정하는 바에 따라 시장·군수·구청장이 수급권자에게 지급한다. 
다만, 지급하여야 할금액이 2천원 미만인 경우에는 이를 지급하지 아니한다.
1. 1종수급권자 : 2만원
2. 2종수급권자 : 20만원
⑥ 급여대상 본인부담금에서 제5항에 따라 지급받은 금액을 차감한 금액이 다음 각 
호의 금액을 초과한 경우에는 그 초과금액을 기금에서 부담한다. 다만, 초과금액
이 2천원 미만인 경우에는 이를 수급권자가 부담한다.
1. 1종수급권자 : 매 30일간 5만원
2. 2종수급권자 : 매 6개월간 60만원
⑦ 시장·군수·구청장은 수급권자가 제6항 본문의 규정에 따라 기금에서 부담하여야 
하는 초과금액을 의료급여기관에 지급한 경우에는 보건복지부령이 정하는 바에 
따라 그 초과금액을 수급권자에게 지급하여야 한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (269, 4, 136, '136
【법규15】 의료법
제3조(의료기관)
① 이 법에서 "의료기관"이란 의료인이 공중(公衆) 또는 특정 다수인을 위하여 의료·
조산의 업(이하 "의료업"이라 한다)을 하는 곳을 말한다.
② 의료기관은 다음 각 호와 같이 구분한다.
1. 의원급 의료기관: 의사, 치과의사 또는 한의사가 주로 외래환자를 대상으로 각
각 그 의료행위를 하는 의료기관으로서 그 종류는 다음 각 목과 같다.
  가. 의원
  나. 치과의원
  다. 한의원
2. 조산원: 조산사가 조산과 임부·해산부·산욕부 및 신생아를 대상으로 보건활동과 
교육·상담을 하는 의료기관을 말한다.
3. 병원급 의료기관: 의사, 치과의사 또는 한의사가 주로 입원환자를 대상으로 의
료행위를 하는 의료기관으로서 그 종류는 다음 각 목과 같다.
  가. 병원
  나. 치과병원
  다. 한방병원
  라. 요양병원(「정신건강증진 및 정신질환자 복지서비스 지원에 관한 법률」 제3
조제5호에 따른 정신의료기관 중 정신병원, 「장애인복지법」 제58조제1항제
2호에 따른 의료재활시설로서 제3조의2의 요건을 갖춘 의료기관을 포함한
다. 이하 같다)
  마. 종합병원
③ 보건복지부장관은 보건의료정책에 필요하다고 인정하는 경우에는 제2항제1호부터 
제3호까지의 규정에 따른 의료기관의 종류별 표준업무를 정하여 고시할 수 있다.
제3조의2(병원등)
병원·치과병원·한방병원 및 요양병원(이하 "병원등"이라 한다)은 30개 이상의 병상(병
원·한방병원만 해당한다) 또는 요양병상(요양병원만 해당하며, 장기입원이 필요한 환
자를 대상으로 의료행위를 하기 위하여 설치한 병상을 말한다)을 갖추어야 한다.
제3조의3(종합병원)
① 종합병원은 다음 각 호의 요건을 갖추어야 한다.
1. 100개 이상의 병상을 갖출 것
2. 100병상 이상 300병상 이하인 경우에는 내과·외과·소아청소년과·산부인과 중 
3개 진료과목, 영상의학과, 마취통증의학과와 진단검사의학과 또는 병리과를 
포함한 7개 이상의 진료과목을 갖추고 각 진료과목마다 전속하는 전문의를 둘 
것
3. 300병상을 초과하는 경우에는 내과, 외과, 소아청소년과, 산부인과, 영상의학
과, 마취통증의학과, 진단검사의학과 또는 병리과, 정신건강의학과 및 치과를 
포함한 9개 이상의 진료과목을 갖추고 각 진료과목마다 전속하는 전문의를 둘 
것
② 종합병원은 제1항제2호 또는 제3호에 따른 진료과목(이하 이 항에서 "필수진료과
목"이라 한다) 외에 필요하면 추가로 진료과목을 설치·운영할 수 있다. 이 경우 필
수진료과목 외의 진료과목에 대하여는 해당 의료기관에 전속하지 아니한 전문의를 
둘 수 있다.
제3조의4(상급종합병원 지정)
① 보건복지부장관은 다음 각 호의 요건을 갖춘 종합병원 중에서 중증질환에 대하여 
난이도가 높은 의료행위를 전문적으로 하는 종합병원을 상급종합병원으로 지정할 
수 있다.
1. 보건복지부령으로 정하는 20개 이상의 진료과목을 갖추고 각 진료과목마다 전
속하는 전문의를 둘 것
2. 제77조제1항에 따라 전문의가 되려는 자를 수련시키는 기관일 것
3. 보건복지부령으로 정하는 인력·시설·장비 등을 갖출 것
4. 질병군별(疾病群別) 환자구성 비율이 보건복지부령으로 정하는 기준에 해당할 
것
② 보건복지부장관은 제1항에 따른 지정을 하는 경우 제1항 각 호의 사항 및 전문성 
등에 대하여 평가를 실시하여야 한다.
③ 보건복지부장관은 제1항에 따라 상급종합병원으로 지정받은 종합병원에 대하여 3
년마다 제2항에 따른 평가를 실시하여 재지정하거나 지정을 취소할 수 있다.
④ 보건복지부장관은 제2항 및 제3항에 따른 평가업무를 관계 전문기관 또는 단체에 
위탁할 수 있다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (270, 4, 137, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
137
⑤ 상급종합병원 지정·재지정의 기준·절차 및 평가업무의 위탁 절차 등에 관하여 필
요한 사항은 보건복지부령으로 정한다.
제3조의5(전문병원 지정)
① 보건복지부장관은 병원급 의료기관 중에서 특정 진료과목이나 특정 질환 등에 대
하여 난이도가 높은 의료행위를 하는 병원을 전문병원으로 지정할 수 있다. 
② 제1항에 따른 전문병원은 다음 각 호의 요건을 갖추어야 한다.
1. 특정 질환별·진료과목별 환자의 구성비율 등이 보건복지부령으로 정하는 기준
에 해당할 것
2. 보건복지부령으로 정하는 수 이상의 진료과목을 갖추고 각 진료과목마다 전속
하는 전문의를 둘 것
③ 보건복지부장관은 제1항에 따라 전문병원으로 지정하는 경우 제2항 각 호의 사항 
및 진료의 난이도 등에 대하여 평가를 실시하여야 한다.
④ 보건복지부장관은 제1항에 따라 전문병원으로 지정받은 의료기관에 대하여 3년마
다 제3항에 따른 평가를 실시하여 전문병원으로 재지정할 수 있다.
⑤ 보건복지부장관은 제1항 또는 제4항에 따라 지정받거나 재지정받은 전문병원이 
다음 각 호의 어느 하나에 해당하는 경우에는 그 지정 또는 재지정을 취소할 수 
있다. 다만, 제1호에 해당하는 경우에는 그 지정 또는 재지정을 취소하여야 한다.
1. 거짓이나 그 밖의 부정한 방법으로 지정 또는 재지정을 받은 경우
2. 지정 또는 재지정의 취소를 원하는 경우
3. 제4항에 따른 평가 결과 제2항 각 호의 요건을 갖추지 못한 것으로 확인된 경
우
⑥ 보건복지부장관은 제3항 및 제4항에 따른 평가업무를 관계 전문기관 또는 단체에 
위탁할 수 있다.
⑦ 전문병원 지정·재지정의 기준·절차 및 평가업무의 위탁 절차 등에 관하여 필요한 
사항은 보건복지부령으로 정한다.
제5조(의사·치과의사 및 한의사 면허)
① 의사·치과의사 또는 한의사가 되려는 자는 다음 각 호의 어느 하나에 해당하는 자
격을 가진 자로서 제9조에 따른 의사·치과의사 또는 한의사 국가시험에 합격한 후 
보건복지부장관의 면허를 받아야 한다.
1. 「고등교육법」 제11조의2에 따른 인정기관(이하 "평가인증기구"라 한다)의 인증
(이하 "평가인증기구의 인증"이라 한다)을 받은 의학·치의학 또는 한의학을 전
공하는 대학을 졸업하고 의학사·치의학사 또는 한의학사 학위를 받은 자
2. 평가인증기구의 인증을 받은 의학·치의학 또는 한의학을 전공하는 전문대학원
을 졸업하고 석사학위 또는 박사학위를 받은 자
3. 보건복지부장관이 인정하는 외국의 제1호나 제2호에 해당하는 학교를 졸업하
고 외국의 의사·치과의사 또는 한의사 면허를 받은 자로서 제9조에 따른 예비
시험에 합격한 자
② 평가인증기구의 인증을 받은 의학·치의학 또는 한의학을 전공하는 대학 또는 전문
대학원을 6개월 이내에 졸업하고 해당 학위를 받을 것으로 예정된 자는 제1항제1
호 및 제2호의 자격을 가진 자로 본다. 다만, 그 졸업예정시기에 졸업하고 해당 
학위를 받아야 면허를 받을 수 있다.
③ 제1항에도 불구하고 입학 당시 평가인증기구의 인증을 받은 의학·치의학 또는 한
의학을 전공하는 대학 또는 전문대학원에 입학한 사람으로서 그 대학 또는 전문
대학원을 졸업하고 해당 학위를 받은 사람은 같은 항 제1호 및 제2호의 자격을 
가진 사람으로 본다.
제54조(신의료기술평가위원회의 설치 등) 
① 보건복지부장관은 신의료기술평가에 관한 사항을 심의하기 위하여 보건복지부에 
신의료기술평가위원회(이하 "위원회"라 한다)를 둔다.
② 위원회는 위원장 1명을 포함하여 20명 이내의 위원으로 구성한다.
③ 위원은 다음 각 호의 자 중에서 보건복지부장관이 위촉하거나 임명한다. 다만, 위
원장은 제1호 또는 제2호의 자 중에서 임명한다.
1. 제28조제1항에 따른 의사회·치과의사회·한의사회에서 각각 추천하는 자
2. 보건의료에 관한 학식이 풍부한 자
3. 소비자단체에서 추천하는 자
4. 변호사의 자격을 가진 자로서 보건의료와 관련된 업무에 5년 이상 종사한 경
력이 있는 자
5. 보건의료정책 관련 업무를 담당하고 있는 보건복지부 소속 5급 이상의 공무원
④ 위원장과 위원의 임기는 3년으로 하되, 연임할 수 있다. 다만, 제3항제5호에 따른 
공무원의 경우에는 재임기간으로 한다.
⑤ 위원의 자리가 빈 때에는 새로 위원을 임명하고, 새로 임명된 위원의 임기는 임명
된 날부터 기산한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (271, 4, 138, '138
[별표 4] <개정 2013.10.4.>
의료기관의 시설규격(제34조 관련)
2. 중환자실 
가. 병상이 300개 이상인 종합병원은 입원실 병상 수의 100분의 5 이상을 중
환자실 병상으로 만들어야 한다.
나. 중환자실은 출입을 통제할 수 있는 별도의 단위로 독립되어야 하며, 무정전
(無停電) 시스템을 갖추어야 한다.
다. 중환자실의 의사당직실은 중환자실 내 또는 중환자실과 가까운 곳에 있어
야 한다.
라. 병상 1개당 면적은 10제곱미터 이상으로 하되, 신생아만을 전담하는 중환
자실(이하 "신생아중환자실"이라 한다)의 병상 1개당 면적은 5제곱미터 이
상으로 한다. 이 경우 "병상 1개당 면적"은 중환자실 내 간호사실, 당직실, 
청소실, 기기창고, 청결실, 오물실, 린넨보관실을 제외한 환자 점유 공간[중
환자실 내에 있는 간호사 스테이션(station)과 복도는 병상 면적에 포함한
다]을 병상 수로 나눈 면적을 말한다.
마. 병상마다 중앙공급식 의료가스시설, 심전도모니터, 맥박산소계측기, 지속적
수액주입기를 갖추고, 병상 수의 10퍼센트 이상 개수의 침습적 동맥혈압모
니터, 병상 수의 30퍼센트 이상 개수의 인공호흡기, 병상 수의 70퍼센트 
이상 개수의 보육기(신생아중환자실에만 해당한다)를 갖추어야 한다.
바. 중환자실 1개 단위(Unit)당 후두경, 앰부백(마스크 포함), 심전도기록기, 제
세동기를 갖추어야 한다. 다만, 신생아중환자실의 경우에는 제세동기 대신 
광선기와 집중치료기를 갖추어야 한다.
사. 중환자실에는 전담의사를 둘 수 있다. 다만, 신생아중환자실에는 전담전문
의를 두어야 한다.
아. 전담간호사를 두되, 간호사 1명당 연평균 1일 입원환자수는 1.2명(신생아 
중환자실의 경우에는 1.5명)을 초과하여서는 아니 된다.
⑥ 위원회의 심의사항을 전문적으로 검토하기 위하여 위원회에 분야별 전문평가위원
회를 둔다.
⑦ 그 밖에 위원회·전문평가위원회의 구성 및 운영 등에 필요한 사항은 보건복지부령
으로 정한다.
【법규16】 의료법 시행규칙 별표4
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (272, 4, 139, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
139
[별표 1] <개정 2014.8.18.>
자동차의 종류(제2조관련)
1. 규모별 세부기준
종류
경형
소형
중형
대형
승용
자동차
배기량이 
1000㏄미만으로
서 길이 
3.6미터·너비 
1.6미터·높이 
2.0미터 이하인 
것
배기량이 
1,600cc미만인 
것으로서 길이 
4.7미터·너비 
1.7미터·높이 
2.0미터 이하인 
것
배기량이 
1,600cc이상 
2,000㏄미만이거
나 길이·너비· 
높이중 어느 
하나라도 소형을 
초과하는 것
배기량이 
2,000㏄이상이거
나, 길이·너비·높이 
모두 소형을 초과 
하는 것
승합
자동차
배기량이 
1000㏄ 
미만으로서 길이 
3.6미터·너비 
1.6미터·높이 
2.0미터 이하인 
것
승차정원이 
15인이하인 
것으로서 길이 
4.7미터·너비 
1.7미터·높이 
2.0미터 이하인 
것
승차정원이 
16인이상 35인 
이하이거나, 길이· 
너비·높이중 어느 
하나라도 소형을 
초과하여 길이가 
9미터 미만인 것
승차정원이 
36인이상이거나, 
길이·너비·높이 
모두가 소형을 
초과하여 길이가 
9미터 이상인 것
화물
자동차
배기량이 
1000㏄ 
미만으로서 길이 
3.6미터·너비 
1.6미터·높이 
2.0미터 이하인 
것
최대적재량이 
1톤이하인 
것으로서, 
총중량이 3.5톤 
이하인 것
최대적재량이 
1톤초과 5톤 
미만이거나, 
총중량이 3.5톤 
초과 10톤 미만인 
것
최대적재량이 5톤 
이상이거나, 
총중량이 10톤 
이상인 것
특수
자동차
배기량이 
1,000㏄미만으로
서 길이 
3.6미터·너비1.6
미터·높이 2.0 
미터 이하인 것
총중량이 3.5톤 
이하인 것
총중량이 3.5톤 
초과 10톤 미만인 
것
총중량이 10톤 
이상인 것
이륜
자동차
배기량이 
50cc미만(최고정
격출력 
4킬로와트 
이하)인 것
배기량이 
100cc 이하 
(최고정격출력 
11킬로와트 
이하)인 것으로 
최대적재량(기타
형에만 
해당한다)이 
60킬로그램 
이하인 것 
배기량이 100cc 
초과 260㏄ 
이하(최고정격출력 
11킬로와트 초과 
15킬로와트 
이하)인 것으로 
최대적재량이 
60킬로그램 초과 
100킬로그램 
이하인 것
배기량이 260cc 
(최고정격출력 
15킬로와트)를 
초과하는 것
2. 유형별 세부기준
종류
유형별
세부기준
승용
자동차
일반형
2개 내지 4개의 문이 있고, 전후 2열 
또는 3열의 좌석을 구비한 유선형인 것
승용겸화물형
차실안에 화물을 적재하도록 장치된 것
다목적형
후레임형이거나 4륜구동장치 또는 
차동제한장치를 갖추는 등 험로운행이 
용이한 구조로 설계된 자동차로서 
일반형 및 승용겸화물형이 아닌 것
기타형
위 어느 형에도 속하지 아니하는 
승용자동차인 것
승합
일반형
주목적이 여객운송용인 것
【법규17】 자동차관리법 시행규칙
제2조(자동차의 종별 구분)
법 제3조제2항 및 제3항에 따른 자동차의 종류는 그 규모별 세부기준 및 유형별 세
부기준에 따라 별표 1과 같이 구분한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (273, 4, 140, '140
자동차
특수형
특정한 용도(장의·헌혈·구급·보도·캠핑 
등)를 가진 것
화물
자동차
일반형
보통의 화물운송용인 것
덤프형
적재함을 원동기의 힘으로 기울여 
적재물을 중력에 의하여 쉽게 
미끄러뜨리는 구조의 화물운송용인 것
밴형
지붕구조의 덮개가 있는 화물운송용인 
것
특수용도형
특정한 용도를 위하여 특수한 구조로 
하거나, 기구를 장치한 것으로서 위 
어느 형에도 속하지 아니하는 
화물운송용인 것
특수
자동차
견인형
피견인차의 견인을 전용으로 하는 
구조인 것
구난형
고장·사고 등으로 운행이 곤란한 
자동차를 구난·견인 할 수 있는 구조인 
것
특수작업형
위 어느 형에도 속하지 아니하는 
특수작업용인 것
이륜
자동차
일반형
자전거로부터 진화한 구조로서 사람 
또는 소량의 화물을 운송하기 위한 것
특수형
경주·오락 또는 운전을 즐기기 위한 
경쾌한 구조인 것
기타형
3륜 이상인 것으로서 최대적재량이 
100kg이하인 것
 ※ 비고
 1. 위 표 제1호 및 제2호에 따른 화물자동차 및 이륜자동차의 범위는 다음 각 목
의 기준에 따른다.
   가. 화물자동차 : 화물을 운송하기 적합하게 바닥 면적이 최소 2제곱미터 이상
(소형·경형화물자동차로서 이동용 음식판매 용도인 경우에는 0.5제곱미터 
이상, 그 밖에 특수용도형의 경형화물자동차는 1제곱미터 이상을 말한다)인 
화물적재공간을 갖춘 자동차로서 다음 각 호의 1에 해당하는 자동차
       1) 승차공간과 화물적재공간이 분리되어 있는 자동차로서 화물적재공간의 
윗부분이 개방된 구조의 자동차, 유류·가스 등을 운반하기 위한 적재함
을 설치한 자동차 및 화물을 싣고 내리는 문을 갖춘 적재함이 설치된 
자동차(구조·장치의 변경을 통하여 화물적재공간에 덮개가 설치된 자동
차를 포함한다)
       2) 승차공간과 화물적재공간이 동일 차실내에 있으면서 화물의 이동을 방
지하기 위해 격벽을 설치한 자동차로서 화물적재공간의 바닥면적이 승
차공간의 바닥면적(운전석이 있는 열의 바닥면적을 포함한다)보다 넓은 
자동차
       3) 화물을 운송하는 기능을 갖추고 자체적하 기타 작업을 수행할 수 있는 
설비를 함께 갖춘 자동차
   나. 이륜자동차(법 제3조제1항 제5호)의 "그와 유사한 구조로 되어 있는 자동
차" : 다음 각 호의 1에 해당하는 자동차를 포함한다.
       1) 이륜인 자동차에 측차를 붙인 자동차
       2) 조향장치의 조작방식, 동력전달방식 또는 원동기 냉각방식 등이 이륜의 
자동차와 유사한 구조로 되어 있는 삼륜 또는 사륜의 자동차로서 승용
자동차에 해당하지 아니하는 자동차
 2. 위 표 제1호에 따른 규모별 세부기준에 대하여는 다음 각 목의 기준을 적용한
다.
   가. 사용연료의 종류가 전기인 자동차의 경우에는 복수 기준 중 길이·너비·높이
에 따라 규모를 구분하고, 「환경친화적자동차의 개발 및 보급촉진에 관한 
법률」 제2조제5호에 따른 하이브리드자동차는 복수 기준 중 배기량과 길이·
너비·높이에 따라 규모를 구분한다.
   나. 복수의 기준중 하나가 작은 규모에 해당되고 다른 하나가 큰 규모에 해당
되면 큰 규모로 구분한다.
   다. 이륜자동차의 최고정격출력(maximum continuous rated power)은 구동
전동기의 최대의 부하(負荷, load)상태에서 측정된 출력을 말한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (274, 4, 141, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
141
【법규18】 자동차손해배상보장법 시행령
제2조(건설기계의 범위)
「자동차손해배상 보장법」(이하 "법"이라 한다) 제2조제1호에서 "「건설기계관리법」의 
적용을 받는 건설기계 중 대통령령으로 정하는 것"이란 다음 각 호의 것을 말한다.
1. 덤프트럭
2. 타이어식 기중기
3. 콘크리트믹서트럭
4. 트럭적재식 콘크리트펌프
5. 트럭적재식 아스팔트살포기
6. 타이어식 굴삭기
7. 「건설기계관리법 시행령」 별표 1 제26호에 따른 특수건설기계 중 다음 각 목
의 특수건설기계
가. 트럭지게차
나. 도로보수트럭
다. 노면측정장비(노면측정장치를 가진 자주식인 것을 말한다)
제3조(책임보험금 등)
① 법 제5조제1항에 따라 자동차보유자가 가입하여야 하는 책임보험 또는 책임공제
(이하 "책임보험등"이라 한다)의 보험금 또는 공제금(이하 "책임보험금"이라 한다)
은 피해자 1명당 다음 각 호의 금액과 같다.
1. 사망한 경우에는 1억5천만원의 범위에서 피해자에게 발생한 손해액. 다만, 그 
손해액이 2천만원 미만인 경우에는 2천만원으로 한다.
2. 부상한 경우에는 별표 1에서 정하는 금액의 범위에서 피해자에게 발생한 손해
액. 다만, 그 손해액이 법 제15조제1항에 따른 자동차보험진료수가(診療酬價)
에 관한 기준(이하 "자동차보험진료수가기준"이라 한다)에 따라 산출한 진료비 
해당액에 미달하는 경우에는 별표 1에서 정하는 금액의 범위에서 그 진료비 
해당액으로 한다.
3. 부상에 대한 치료를 마친 후 더 이상의 치료효과를 기대할 수 없고 그 증상이 
고정된 상태에서 그 부상이 원인이 되어 신체의 장애(이하 "후유장애"라 한다)
가 생긴 경우에는 별표 2에서 정하는 금액의 범위에서 피해자에게 발생한 손
해액
② 동일한 사고로 제1항 각 호의 금액을 지급할 둘 이상의 사유가 생긴 경우에는 다
음 각 호의 방법에 따라 책임보험금을 지급한다.
1. 부상한 자가 치료 중 그 부상이 원인이 되어 사망한 경우에는 제1항제1호와 
같은 항 제2호에 따른 한도금액의 합산액 범위에서 피해자에게 발생한 손해액
2. 부상한 자에게 후유장애가 생긴 경우에는 제1항제2호와 같은 항 제3호에 따른 
금액의 합산액
3. 제1항제3호에 따른 금액을 지급한 후 그 부상이 원인이 되어 사망한 경우에는 
제1항제1호에 따른 금액에서 같은 항 제3호에 따른 금액 중 사망한 날 이후
에 해당하는 손해액을 뺀 금액
③ 법 제5조제2항에서 "대통령령으로 정하는 금액"이란 사고 1건당 2천만원의 범위
에서 사고로 인하여 피해자에게 발생한 손해액을 말한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (275, 4, 142, '142
[별표 1] <개정 2014.6.30>
장애인의 종류 및 기준(제2조 관련)
1. 지체장애인(肢體障碍人)
가. 한 팔, 한 다리 또는 몸통의 기능에 영속적인 장애가 있는 사람
나. 한 손의 엄지손가락을 지골(指骨 : 손가락 뼈) 관절 이상의 부위에서 잃은 
사람 또는 한 손의 둘째 손가락을 포함한 두 개 이상의 손가락을 모두 
제1지골 관절 이상의 부위에서 잃은 사람
다. 한 다리를 리스프랑(Lisfranc : 발등뼈와 발목을 이어주는) 관절 이상의 
부위에서 잃은 사람
라. 두 발의 발가락을 모두 잃은 사람
마. 한 손의 엄지손가락 기능을 잃은 사람 또는 한 손의 둘째 손가락을 포함한 
손가락 두 개 이상의 기능을 잃은 사람
바. 왜소증으로 키가 심하게 작거나 척추에 현저한 변형 또는 기형이 있는 사람
사. 지체(肢體)에 위 각 목의 어느 하나에 해당하는 장애정도 이상의 장애가 
있다고 인정되는 사람
2. 뇌병변장애인(腦病變障碍人)
뇌성마비, 외상성 뇌손상, 뇌졸중(腦卒中) 등 뇌의 기질적 병변으로 인하여 발생한 
신체적 장애로 보행이나 일상생활의 동작 등에 상당한 제약을 받는 사람
3. 시각장애인(視覺障碍人)
가. 나쁜 눈의 시력(만국식시력표에 따라 측정된 교정시력을 말한다. 이하 
같다)이 0.02 이하인 사람
나. 좋은 눈의 시력이 0.2 이하인 사람
다. 두 눈의 시야가 각각 주시점에서 10도 이하로 남은 사람
라. 두 눈의 시야 2분의 1 이상을 잃은 사람
4. 청각장애인(聽覺障碍人)
가. 두 귀의 청력 손실이 각각 60데시벨(dB) 이상인 사람
나. 한 귀의 청력 손실이 80데시벨 이상, 다른 귀의 청력 손실이 40데시벨 
이상인 사람
다. 두 귀에 들리는 보통 말소리의 명료도가 50퍼센트 이하인 사람
라. 평형 기능에 상당한 장애가 있는 사람
5. 언어장애인(言語障碍人)
음성 기능이나 언어 기능에 영속적으로 상당한 장애가 있는 사람
6. 지적장애인(知的障碍人)
정신 발육이 항구적으로 지체되어 지적 능력의 발달이 불충분하거나 불완전하고 
자신의 일을 처리하는 것과 사회생활에 적응하는 것이 상당히 곤란한 사람
7. 자폐성장애인(自閉性障碍人)
소아기 자폐증, 비전형적 자폐증에 따른 언어·신체표현·자기조절·사회적응 기능 및 
능력의 장애로 인하여 일상생활이나 사회생활에 상당한 제약을 받아 다른 사람의 
도움이 필요한 사람
8. 정신장애인(精神障碍人)
지속적인 정신분열병, 분열형 정동장애(情動障碍 : 여러 현실 상황에서 부적절한 
정서 반응을 보이는 장애), 양극성 정동장애 및 반복성 우울장애에 따른 
감정조절·행동·사고 기능 및 능력의 장애로 인하여 일상생활이나 사회생활에 
상당한 제약을 받아 다른 사람의 도움이 필요한 사람
【법규19】 장애인복지법 시행령
제2조 (장애인의 종류 및 기준)
① 「장애인복지법」(이하 "법"이라 한다) 제2조제2항 각 호 외의 부분에서 "대통령령으
로 정하는 장애의 종류 및 기준에 해당하는 자"란 별표 1에서 정한 자를 말한다.
② 장애인은 장애의 정도에 따라 등급을 구분하되, 그 등급은 보건복지부령으로 정한
다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (276, 4, 143, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
143
9. 신장장애인(腎臟障碍人)
신장의 기능부전(機能不全)으로 인하여 혈액투석이나 복막투석을 지속적으로 
받아야 하거나 신장기능의 영속적인 장애로 인하여 일상생활에 상당한 제약을 
받는 사람
10. 심장장애인(心臟障碍人)
심장의 기능부전으로 인한 호흡곤란 등의 장애로 일상생활에 상당한 제약을 받는 
사람
11. 호흡기장애인(呼吸器障碍人)
폐나 기관지 등 호흡기관의 만성적 기능부전으로 인한 호흡기능의 장애로 
일상생활에 상당한 제약을 받는 사람
12. 간장애인(肝障碍人)
간의 만성적 기능부전과 그에 따른 합병증 등으로 인한 간기능의 장애로 
일상생활에 상당한 제약을 받는 사람
13. 안면장애인(顔面障碍人)
안면 부위의 변형이나 기형으로 사회생활에 상당한 제약을 받는 사람
14. 장루·요루장애인(腸瘻·尿瘻障碍人)
배변기능이나 배뇨기능의 장애로 인하여 장루(腸瘻) 또는 요루(尿瘻)를 시술하여 
일상생활에 상당한 제약을 받는 사람
15. 뇌전증장애인(腦電症障碍人)
뇌전증에 의한 뇌신경세포의 장애로 인하여 일상생활이나 사회생활에 상당한 
제약을 받아 다른 사람의 도움이 필요한 사람
[별표 1] <개정 2013.4.3.>
장애인의 장애등급표(제2조 관련)
1. 지체장애인
 가. 신체의 일부를 잃은 사람
   제1급
1. 두 팔을 손목관절 이상의 부위에서 잃은 사람
2. 두 다리를 무릎관절 이상의 부위에서 잃은 사람
   제2급
1. 두 손의 손가락을 모두 잃은 사람
2. 한 팔을 팔꿈치관절 이상의 부위에서 잃은 사람
3. 두 다리를 발목관절 이상의 부위에서 잃은 사람
   제3급
1. 두 손의 엄지손가락과 둘째손가락을 잃은 사람
2. 한 손의 모든 손가락을 잃은 사람
3. 두 다리를 쇼파관절(chopart''s joint) 이상의 부위에서 잃은 사람
4. 한 다리를 무릎관절 이상의 부위에서 잃은 사람
   제4급
1. 두 손의 엄지손가락을 잃은 사람
2. 한 손의 엄지손가락과 둘째손가락을 잃은 사람
3. 한 손의 엄지손가락을 포함하여 세 손가락을 잃은 사람
4. 두 다리를 리스프랑관절(Lisfranc: 발등뼈와 발목을 이어주는 관절) 
이상의 부위에서 잃은 사람
5. 한 다리를 발목관절 이상의 부위에서 잃은 사람
【법규20】 장애인복지법 시행규칙
제2조(장애인의 장애등급 등)
① 「장애인복지법 시행령」(이하 "영"이라 한다) 제2조제2항에 따른 장애인의 장애등
급은 별표 1과 같다.
② 보건복지부장관은 제1항에 따른 장애등급의 구체적인 판정기준을 정하여 고시할 
수 있다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (277, 4, 144, '144
   제5급
1. 한 손의 엄지손가락을 포함하여 두 손가락을 잃은 사람
2. 한 손의 엄지손가락을 중수수지관절 이상의 부위에서 잃은 사람
3. 한 손의 둘째손가락을 포함하여 세 손가락을 잃은 사람
4. 두 발의 발가락을 모두 잃은 사람
5. 한 다리를 쇼파관절 이상의 부위에서 잃은 사람
   제6급
1. 한 손의 엄지손가락을 잃은 사람
2. 한 손의 둘째손가락을 포함하여 두 손가락을 잃은 사람
3. 한 손의 셋째손가락, 넷째손가락 및 다섯째손가락을 모두 잃은 사람
4. 한 다리를 리스프랑관절 이상의 부위에서 잃은 사람
 나. 관절장애가 있는 사람
   제1급
1. 두 팔의 어깨관절, 팔꿈치관절, 손목관절 모두의 기능에 현저한 장애가 
있는 사람
2. 두 다리의 고관절, 무릎관절, 족관절 모두의 기능에 현저한 장애가 있는 
사람
   제2급
1. 한 팔의 어깨관절, 팔꿈치관절, 손목관절 모두의 기능에 현저한 장애가 
있는 사람
2. 두 팔의 어깨관절, 팔꿈치관절, 손목관절 중 각각 2개관절의 기능에 
현저한 장애가 있는 사람
3. 두 팔의 어깨관절, 팔꿈치관절, 손목관절 모두의 기능에 상당한 장애가 
있는 사람
4. 두 손의 모든 손가락의 관절기능에 현저한 장애가 있는 사람
5. 두 다리의 고관절, 무릎관절, 족관절 중 각각 2개관절의 기능에 현저한 
장애가 있는 사람
6. 두 다리의 고관절, 무릎관절, 족관절 모두의 기능에 상당한 장애가 있는 
사람
   제3급
1. 두 팔의 어깨관절, 팔꿈치관절, 손목관절 중 각각 2개관절의 기능에 
상당한 장애가 있는 사람
2. 두 팔의 어깨관절, 팔꿈치관절, 손목관절 모두의 기능에 장애가 있는 
사람
3. 두 손의 엄지손가락과 둘째손가락 관절기능에 현저한 장애가 있는 사람
4. 한 손의 모든 손가락의 관절기능에 현저한 장애가 있는 사람
5. 한 팔의 어깨관절, 팔꿈치관절, 손목관절 중 2개관절의 기능에 현저한 
장애가 있는 사람
6. 한 팔의 어깨관절, 팔꿈치관절, 손목관절 모두의 기능에 상당한 장애가 
있는 사람
7. 한 다리의 고관절, 무릎관절, 족관절 모두의 기능에 현저한 장애가 있는 
사람
   제4급
1. 한 팔의 어깨관절, 팔꿈치관절, 손목관절 중 한 관절의 기능에 현저한 
장애가 있는 사람
2. 두 손의 엄지손가락의 관절기능에 현저한 장애가 있는 사람
3. 한 손의 엄지손가락과 둘째손가락의 관절기능에 현저한 장애가 있는 
사람
4. 한 손의 엄지손가락 또는 둘째손가락을 포함하여 3개 손가락의 
관절기능에 현저한 장애가 있는 사람
5. 한 손의 엄지손가락 또는 둘째손가락을 포함하여 4개 손가락의 
관절기능에 상당한 장애가 있는 사람
6. 두 다리의 고관절, 무릎관절, 족관절 중 각각 2개관절의 기능에 상당한 
장애가 있는 사람
7. 두 다리의 고관절, 무릎관절, 족관절 모두의 기능에 장애가 있는 사람
8. 한 다리의 고관절, 무릎관절, 족관절 중 2개관절의 기능에 현저한 장애가 
있는 사람
9. 한 다리의 고관절, 무릎관절, 족관절 모두의 기능에 상당한 장애가 있는 
사람
10. 한 다리의 고관절 또는 무릎관절의 기능을 잃은 사람
   제5급
1. 한 팔의 어깨관절, 팔꿈치관절, 손목관절 중 2개관절의 기능에 상당한 
장애가 있는 사람
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (278, 4, 145, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
145
2. 한 팔의 어깨관절, 팔꿈치관절, 손목관절 모두의 기능에 장애가 있는 
사람
3. 두 손의 엄지손가락의 관절기능에 상당한 장애가 있는 사람
4. 한 손의 엄지손가락의 관절기능에 현저한 장애가 있는 사람
5. 한 손의 엄지손가락과 둘째손가락의 관절기능에 상당한 장애가 있는 
사람
6. 한 손의 엄지손가락 또는 둘째손가락을 포함하여 3개 손가락의 
관절기능에 상당한 장애가 있는 사람
7. 한 다리의 고관절, 무릎관절, 족관절 중 2개관절의 기능에 상당한 장애가 
있는 사람
8. 한 다리의 고관절, 무릎관절, 족관절 모두의 기능에 장애가 있는 사람
9. 두 발의 모든 발가락의 관절기능에 현저한 장애가 있는 사람
10. 한 다리의 고관절 또는 무릎관절의 기능에 현저한 장애가 있는 사람
11. 한 다리의 발목관절의 기능을 잃은 사람
   제6급
1. 한 손의 엄지손가락의 관절기능에 상당한 장애가 있는 사람
2. 한 손의 둘째손가락을 포함하여 2개 손가락의 관절기능에 현저한 장애가 
있는 사람
3. 한 손의 셋째손가락, 넷째손가락 그리고 다섯째손가락 모두의 관절기능에 
현저한 장애가 있는 사람
4. 한 팔의 어깨관절, 팔꿈치관절, 손목관절 중 한 관절의 기능에 상당한 
장애가 있는 사람
5. 한 다리의 고관절 또는 무릎관절의 기능에 상당한 장애가 있는 사람
6. 한 다리의 발목관절의 기능에 현저한 장애가 있는 사람
 다. 지체기능장애가 있는 사람 
   제1급
1. 두 팔의 기능을 잃은 사람
2. 두 다리의 기능을 잃은 사람
   제2급
1. 한 팔의 기능을 잃은 사람
2. 두 팔의 기능에 현저한 장애가 있는 사람
3. 두 손의 모든 손가락의 기능을 잃은 사람
4. 두 다리의 기능에 현저한 장애가 있는 사람
5. 경추와 흉요추의 기능을 잃은 사람
   제3급
1. 두 팔의 기능에 상당한 장애가 있는 사람
2. 두 손의 엄지손가락 및 둘째손가락의 기능을 잃은 사람
3. 한 손의 모든 손가락의 기능을 잃은 사람
4. 한 팔의 기능에 현저한 장애가 있는 사람
5. 한 다리의 기능을 잃은 사람
6. 경추 또는 흉요추의 기능을 잃은 사람
   제4급
1. 두 손의 엄지손가락의 기능을 잃은 사람
2. 한 손의 엄지손가락 및 둘째손가락의 기능을 잃은 사람
3. 한 손의 엄지손가락 또는 둘째손가락을 포함하여 세 손가락의 기능을 
잃은 사람
4. 한 손의 엄지손가락 또는 둘째손가락을 포함하여 네 손가락의 기능에 
현저한 장애가 있는 사람
5. 한 다리의 기능에 현저한 장애가 있는 사람
6. 두 다리의 기능에 상당한 장애가 있는 사람
7. 경추 또는 흉요추의 기능에 현저한 장애가 있는 사람
   제5급
1. 한 팔의 기능에 상당한 장애가 있는 사람
2. 두 손의 엄지손가락의 기능에 현저한 장애가 있는 사람
3. 한 손의 엄지손가락의 기능을 잃은 사람
4. 한 손의 엄지손가락 및 둘째손가락의 기능에 현저한 장애가 있는 사람
5. 한 손의 엄지손가락 또는 둘째손가락을 포함하여 세 손가락의 기능에 
현저한 장애가 있는 사람
6. 한 다리의 기능에 상당한 장애가 있는 사람
7. 두 발의 모든 발가락의 기능을 잃은 사람
8. 경추 또는 흉요추의 기능에 상당한 장애가 있는 사람
   제6급
1. 한 손의 엄지손가락의 기능에 현저한 장애가 있는 사람
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (279, 4, 146, '146
2. 한 손의 둘째손가락을 포함하여 두 손가락의 기능을 잃은 사람
3. 한 손의 엄지손가락을 포함하여 두 손가락의 기능에 현저한 장애가 있는 
사람
4. 한 손의 셋째손가락, 넷째손가락 및 다섯째손가락의 기능을 잃은 사람
5. 경추 또는 흉요추의 기능이 저하된 사람
 라. 신체에 변형 등의 장애가 있는 사람
   제5급
한 다리가 건강한 다리보다 10센티미터 이상 짧거나 건강한 다리 길이의 
10분의 1 이상 짧은 사람
   제6급
1. 한 다리가 건강한 다리보다 5센티미터 이상 짧거나 건강한 다리 길이의 
15분의 1 이상 짧은 사람
2. 척추측만증이 있으며, 만곡각도가 40도 이상인 사람
3. 척추후만증이 있으며, 만곡각도가 60도 이상인 사람
4. 성장이 멈춘 만 18세 이상의 남성으로서 신장이 145센티미터 이하인 
사람
5. 성장이 멈춘 만 16세 이상의 여성으로서 신장이 140센티미터 이하인 
사람
6. 연골무형성증으로 왜소증에 대한 증상이 뚜렷한 사람
2. 뇌병변장애인
   제1급
보행이 불가능하거나 일상생활동작을 거의 할 수 없어, 도움과 보호가 
필요한 사람
   제2급
1. 보행이 현저하게 제한되었거나 일상생활동작이 현저하게 제한된 사람
2. 보행과 일상생활동작이 상당히 제한된 사람
   제3급
1. 보행이 상당한 정도 제한되었거나 일상생활동작이 상당히 제한된 사람 
2. 보행이 경중한 정도 제한되고 섬세한 일상생활동작이 현저하게 제한된 
사람 
   제4급
1. 보행이 경중한 정도 제한되었거나 섬세한 일상생활동작이 현저하게 
제한된 사람 
2. 보행이 경미하게 제한되고 섬세한 일상생활동작이 상당히 제한된 사람
   제5급
1. 보행이 경미하게 제한되었거나 섬세한 일상생활동작이 상당히 제한된 
사람
2. 보행이 파행(跛行)을 보이고 섬세한 일상생활동작이 경중한 정도 제한된 
사람
   제6급
보행 시 파행을 보이거나 섬세한 일상생활동작이 경중한 정도 제한된 사람
3. 시각장애인
   제1급
좋은 눈의 시력(공인된 시력표에 의하여 측정한 것을 말하며, 굴절이상이 
있는 사람에 대하여는 최대 교정시력을 기준으로 한다. 이하 같다)이 0.02 
이하인 사람
   제2급
좋은 눈의 시력이 0.04 이하인 사람
   제3급
1. 좋은 눈의 시력이 0.06 이하인 사람
2. 두 눈의 시야가 각각 모든 방향에서 5도 이하로 남은 사람
   제4급
1. 좋은 눈의 시력이 0.1 이하인 사람
2. 두 눈의 시야가 각각 모든 방향에서 10도 이하로 남은 사람
   제5급
1. 좋은 눈의 시력이 0.2 이하인 사람
2. 두 눈의 시야가 각각 정상시야의 50%이상 감소한 사람
   제6급
나쁜 눈의 시력이 0.02 이하인 사람
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (280, 4, 147, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
147
4. 청각장애인
 가. 청력을 잃은 사람
   제2급
두 귀의 청력을 각각 90데시벨(dB) 이상 잃은 사람(두 귀가 완전히 들리지 
아니하는 사람)
   제3급
두 귀의 청력을 각각 80데시벨(dB) 이상 잃은 사람(귀에 입을 대고 
큰소리로 말을 하여도 듣지 못하는 사람)
   제4급
1. 두 귀의 청력을 각각 70데시벨(dB) 이상 잃은 사람(귀에 대고 말을 
하여야 들을 수 있는 사람)
2. 두 귀에 들리는 보통 말소리의 최대의 명료도가 50퍼센트 이하인 사람 
   제5급
두 귀의 청력을 각각 60데시벨(dB) 이상 잃은 사람(40센티미터 이상의 
거리에서 발성된 말소리를 듣지 못하는 사람)
   제6급
한 귀의 청력을 80데시벨(dB) 이상 잃고, 다른 귀의 청력을 40데시벨(dB) 
이상 잃은 사람 
 나. 평형기능에 장애가 있는 사람
   제3급
양측 평형기능의 소실로 두 눈을 뜨고 직선으로 10미터 이상을 지속적으로 
걸을 수 없는 사람
   제4급
양측 평형기능의 소실 또는 감소로 두 눈을 뜨고 10미터를 걸으려면 중간에 
균형을 잡기 위하여 멈추어야 하는 사람 
   제5급
양측 평형기능의 감소로 두 눈을 뜨고 10미터 거리를 직선으로 걸을 때 
중앙에서 60센티미터 이상 벗어나며, 복합적인 신체운동은 어려운 사람
5. 언어장애인
   제3급
음성기능이나 언어기능을 잃은 사람
   제4급
음성·언어만으로는 의사소통을 하기 곤란할 정도로 음성기능이나 언어기능에 
현저한 장애가 있는 사람
6. 지적장애인
   제1급
지능지수가 35 미만인 사람으로서 일상생활과 사회생활에 적응하는 것이 
현저하게 곤란하여 일생 동안 다른 사람의 보호가 필요한 사람
   제2급
지능지수가 35 이상 50 미만인 사람으로서 일상생활의 단순한 행동을 
훈련시킬 수 있고, 어느 정도의 감독과 도움을 받으면 복잡하지 아니하고 
특수기술이 필요하지 아니한 직업을 가질 수 있는 사람
   제3급
지능지수가 50 이상 70 이하인 사람으로서 교육을 통한 사회적·직업적 
재활이 가능한 사람
7. 자폐성장애인
   제1급
ICD-10(International Classification of Diseases, 10th Version)의 
진단기준에 따른 전반성발달장애(자폐증)로 정상발달의 단계가 나타나지 
아니하고, 지능지수가 70 이하이며, 기능 및 능력 장애로 인하여 주위의 
전적인 도움이 없이는 일상생활을 해나가는 것이 거의 불가능한 사람
   제2급
ICD-10의 진단기준에 따른 전반성발달장애(자폐증)로 정상발달의 단계가 
나타나지 아니하고, 지능지수가 70 이하이며, 기능 및 능력 장애로 인하여 
주위의 많은 도움이 없으면 일상생활을 해나가기 어려운 사람
   제3급
제2급과 같은 특징을 가지고 있으나 지능지수가 71 이상이며, 기능 및 능력 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (281, 4, 148, '148
장애로 인하여 일상생활 혹은 사회생활을 해나가기 위하여 간헐적으로 
도움이 필요한 사람
8. 정신장애인
   제1급
1. 정신분열병으로 망상, 환청, 사고장애 및 기괴한 행동 등의 양성증상이나 
사회적 위축과 같은 음성증상이 심하고, 현저한 인격변화가 있으며, 기능 
및 능력 장애로 인하여 주위의 전적인 도움이 없이는 일상생활을 
해나가는 것이 거의 불가능한 사람(정신병을 진단받은 지 1년 이상 지난 
사람만 해당한다. 이하 같다)
2. 양극성정동장애(조울병)로 기분·의욕·행동 및 사고의 장애증상이 심한 
증상기(症狀期)가 지속되거나 자주 반복되며, 기능 및 능력 장애로 
인하여 주위의 전적인 도움이 없이는 일상생활을 해나가는 것이 거의 
불가능한 사람
3. 반복성우울장애로 정신병적 증상이 동반되고, 기분·의욕 및 행동 등에 
대한 우울증상이 심한 증상기가 지속되거나 자주 반복되며, 기능 및 능력 
장애로 인하여 주위의 전적인 도움이 없이는 일상생활을 해나가는 것이 
거의 불가능한 사람
4. 분열형정동장애로 제1호부터 제3호까지에 준하는 증상이 있는 사람
   제2급
1. 정신분열병으로 망상, 환청, 사고장애 및 기괴한 행동 등의 양성증상과 
사회적 위축 등의 음성증상이 있고, 중등도의 인격 변화가 있으며, 기능 
및 능력 장애로 인하여 주위의 많은 도움이 없으면 일상생활을 해나가기 
어려운 사람
2. 양극성정동장애(조울병)로 기분·의욕·행동 및 사고의 장애증상이 있는 
증상기가 지속되거나 자주 반복되며, 기능 및 능력 장애로 인하여 주위의 
많은 도움이 없으면 일상생활을 해나가기 어려운 사람
3. 만성적인 반복성우울장애로 망상 등 정신병적 증상이 동반되고, 
기분·의욕 및 행동 등에 대한 우울증상이 있는 증상기가 지속되거나 자주 
반복되며, 기능 및 능력 장애로 인하여 주위의 많은 도움이 없으면 
일상생활을 해나가기 어려운 사람
4. 만성적인 분열형정동장애로 제1호부터 제3호까지에 준하는 증상이 있는 
사람
   제3급
1. 정신분열병으로 망상, 환청, 사고장애 및 기괴한 행동 등의 양성증상이 
있으나, 인격변화나 퇴행은 심하지 아니한 경우로서 기능 및 능력 장애로 
인하여 일상생활이나 사회생활을 해나가기 위한 기능 수행에 제한을 
받아 간헐적으로 도움이 필요한 사람 
2. 양극성정동장애(조울병)로 기분·의욕·행동 및 사고의 장애증상이 현저하지 
아니하지만, 증상기가 지속되거나 자주 반복되는 경우로서 기능 및 능력 
장애로 인하여 일상생활이나 사회생활을 해나가기 위한 기능 수행에 
제한을 받아 간헐적으로 도움이 필요한 사람 
3. 반복성우울장애로 기분·의욕·행동 등에 대한 우울증상이 있는 증상기가 
지속되거나 자주 반복되는 경우로서 기능 및 능력 장애로 인하여 
일상생활이나 사회생활을 해나가기 위한 기능 수행에 제한을 받아 
간헐적으로 도움이 필요한 사람 
4. 분열형정동장애로 제1호부터 제3호까지에 준하는 증상이 있는 사람
9. 신장장애인
   제2급
만성신부전증으로 인하여 3개월 이상 혈액투석이나 복막투석을 받고 있는 
사람
   제5급
신장을 이식받은 사람
10. 심장장애인
   제1급
심장기능의 장애가 지속되며, 안정 시에도 심부전증상이나 협심증증상 등이 
나타나서 운동능력을 완전히 상실하여 상시적으로 돌보는 사람이 필요한 
사람(심장질환을 진단받은 지 1년 이상 지난 사람만 해당한다. 이하 같다)
   제2급
심장기능의 장애가 지속되며, 자기 신체 주위의 일은 어느 정도 할 수 
있지만 그 이상의 활동을 하면 심부전증상이나 협심증증상 등이 나타나서 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (282, 4, 149, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
149
정상적인 일상생활을 해나가기 어려운 사람
   제3급
심장기능의 장애가 지속되며, 가정에서의 가벼운 활동은 할 수 있지만 그 
이상의 활동을 하면 심부전증상이나 협심증증상 등이 나타나서 정상적인 
사회활동을 해나가기 어려운 사람
   제5급
심장을 이식받은 사람
11. 호흡기장애인
   제1급
1. 폐나 기관지 등 호흡기관의 만성적인 기능부전으로 안정 시에도 
산소요법을 받아야 할 정도의 호흡곤란이 있고, 평상시의 폐환기 
기능(1초시 강제호기량) 또는 폐확산능이 정상예측치의 25% 이하이거나 
안정 시 자연호흡상태에서의 동맥혈 산소분압이 55㎜Hg 이하인 사람
2. 만성호흡기 질환으로 기관절개관을 유지하고 24시간 인공호흡기로 
생활하는 사람 
   제2급
폐나 기관지 등 호흡기관의 만성적인 기능부전으로 집안에서 이동할 때에도 
호흡곤란이 있고, 평상시의 폐환기 기능(1초시 강제호기량) 또는 폐확산능이 
정상예측치의 30% 이하이거나 안정 시 자연호흡상태에서의 동맥혈 
산소분압이 60㎜Hg 이하인 사람
   제3급
폐나 기관지 등 호흡기관의 만성적인 기능부전으로 평지에서의 보행에도 
호흡곤란이 있고, 평상시의 폐환기 기능(1초시 강제호기량) 또는 폐확산능이 
정상예측치의 40% 이하이거나 안정 시 자연호흡상태에서의 동맥혈 
산소분압이 65㎜Hg 이하인 사람
   제5급
1. 폐를 이식받은 사람
2. 늑막루가 있는 사람
12. 간장애인
   제1급
만성 간질환(간경변증, 간세포암종 등)으로 진단받은 환자 중 잔여 간기능이 
Child-Pugh 평가상 등급 C이면서 간성뇌증이 있거나 내과적 치료로 
조절되지 아니하는 난치성 복수 등의 합병증이 있는 사람
   제2급
만성 간질환(간경변증, 간세포암종 등)으로 진단받은 환자 중 잔여 간기능이 
Child-Pugh 평가상 등급 C이면서 과거 2년이내의 간성뇌증 병력 또는 
자발성 세균성 복막염 등의 병력이 있는 사람
   제3급
1. 만성 간질환(간경변증, 간세포암종 등)으로 진단받은 환자 중 잔여 
간기능이 Child-Pugh 평가상 등급 C인 사람
2. 만성 간질환(간경변증, 간세포암종 등)으로 진단받은 환자 중 잔여 
간기능이 Child-Pugh 평가상 등급 B이면서 난치성 복수가 있거나 
간성뇌증 등의 합병증이 있는 사람
   제5급
간을 이식받은 사람
13. 안면장애인
   제2급
1. 노출된 안면부의 90% 이상이 변형된 사람
2. 노출된 안면부의 60% 이상이 변형되고 코 형태의 2/3 이상이 없어진 
사람
   제3급
1. 노출된 안면부의 75% 이상이 변형된 사람
2. 노출된 안면부의 50% 이상이 변형되고 코 형태의 2/3 이상이 없어진 
사람
   제4급
1. 노출된 안면부의 60% 이상이 변형된 사람
2. 코 형태의 2/3 이상이 없어진 사람
3. 노출된 안면부의 45% 이상이 변형되고 코 형태의 1/3 이상이 없어진 
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (283, 4, 150, '150
사람
   제5급
1. 노출된 안면부의 45% 이상이 변형된 사람
2. 코 형태의 1/3 이상이 없어진 사람
14. 장루장애인 및 요루장애인
   제2급 
1. 장루와 함께 요루 또는 방광루를 가지고 있으며, 그 중 하나 이상의 
루에 합병증으로 장피누공 또는 배뇨기능장애가 있는 사람
2. 장루 또는 요루를 가지고 있으며 합병증으로 장피누공과 배뇨기능장애가 
모두 있는 사람
3. 배변을 위한 말단 공장루를 가지고 있는 사람
   제3급
1. 장루와 함께 요루 또는 방광루를 가지고 있는 사람
2. 장루 또는 요루를 가지공 있으며, 합병증으로 장피누공 또는 
배뇨기능장애가 있는 사람 
   제4급
1. 장루 또는 요루를 가진 사람
2. 방광루를 가지고 있으며, 합병증으로 장피누공이 있는 사람
   제5급
방광루를 가진 사람
15. 뇌전증장애인
가. 성인 뇌전증
   제2급
만성적인 뇌전증에 대한 적극적인 치료에도 불구하고 월 8회 이상의 
중증발작이 연 6회 이상 있고, 발작을 할 때에 유발된 호흡장애, 흡인성 
폐렴, 심한 탈진, 두통, 구역질, 인지기능의 장애 등으로 심각한 요양관리가 
필요하며, 일상생활 및 사회생활에 항상 다른 사람의 지속적인 보호와 
관리가 필요한 사람
   
   제3급
만성적인 뇌전증에 대한 적극적인 치료에도 불구하고 월 5회 이상의 
중증발작 또는 월 10회 이상의 경증발작이 연 6회 이상 발작이 있고, 
발작을 할 때에 유발된 호흡장애, 흡인성 폐렴, 심한 탈진, 두통, 구역질, 
인지기능의 장애 등으로 요양관리가 필요하며, 일상생활 및 사회생활에 
수시로 보호와 관리가 필요한 사람
   제4급
만성적인 뇌전증에 대한 적극적인 치료에도 불구하고 월 1회 이상의 
중증발작 또는 월 2회 이상의 경증발작을 포함하여 연 6회 이상 발작이 
있고, 이로 인하여 협조적인 대인관계가 현저히 곤란한 사람
   제5급
만성적인 뇌전증에 대한 적극적인 치료에도 불구하고 월 1회 이상의 
중증발작 또는 월 2회 이상의 경증발작이 연 3회 이상 있고, 이로 인하여 
협조적인 대인관계가 곤란한 사람
나. 소아청소년 뇌전증
   제2급
전신발작, 뇌전증성 뇌병증, 근간대성 발작 등으로 심각한 요양관리가 
필요하며, 일상생활 및 사회생활에 항상 다른 사람의 지속적인 보호와 
관리가 필요한 사람
   제3급
전신발작, 뇌전증성 뇌병증, 근간대성 발작, 부분발작 등으로 요양관리가 
필요하며, 일상생활 및 사회생활에 수시로 보호와 관리가 필요한 사람
   제4급
전신발작, 뇌전증성 뇌병증, 근간대성 발작, 부분발작 등으로 일상생활 및 
사회생활에 보호와 관리가 필요한 사람
16. 중복된 장애의 합산 판정
가. 같은 등급에 둘 이상의 중복장애가 있는 경우에는 1등급 위의 등급으로 한다. 
나. 서로 다른 등급에 둘 이상의 중복장애가 있는 경우에는 의료기관의 전문의가 
장애의 정도를 고려하여 보건복지부장관이 정하는 바에 따라 주된 
장애등급보다 1등급 위의 등급으로 조정할 수 있다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (284, 4, 151, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
151
다. 다음과 같은 경우는 가목 및 나목에도 불구하고 중복장애로 합산 판정할 수 
없다.
   1) 동일부위의 지체장애와 뇌병변장애가 중복된 경우
   2) 지적장애와 자폐성장애가 중복된 경우
   3) 그 밖에 장애부위가 같거나 장애성격이 중복되어 중복장애로 합산하여 
판정하는 것이 타당하지 아니한 경우로서 보건복지부장관이 정하는 경우
【법규21】 전자서명법
제2조(정의)
2. "전자서명"이라 함은 서명자를 확인하고 서명자가 해당 전자문서에 서명을 하였음
을 나타내는데 이용하기 위하여 해당 전자문서에 첨부되거나 논리적으로 결합된 
전자적 형태의 정보를 말한다.
3. "공인전자서명"이라 함은 다음 각목의 요건을 갖추고 공인인증서에 기초한 전자서
명을 말한다.
   가. 전자서명생성정보가 가입자에게 유일하게 속할 것
   나. 서명 당시 가입자가 전자서명생성정보를 지배·관리하고 있을 것
   다. 전자서명이 있은 후에 해당 전자서명에 대한 변경여부를 확인할 수 있을 것
   라. 전자서명이 있은 후에 해당 전자문서의 변경여부를 확인할 수 있을 것
【법규22】 지역보건법
제10조(보건소의 설치)
① 지역주민의 건강을 증진하고 질병을 예방·관리하기 위하여 시·군·구에 대통령령으
로 정하는 기준에 따라 해당 지방자치단체의 조례로 보건소(보건의료원을 포함한
다. 이하 같다)를 설치한다.
② 동일한 시·군·구에 2개 이상의 보건소가 설치되어 있는 경우 해당 지방자치단체의 
조례로 정하는 바에 따라 업무를 총괄하는 보건소를 지정하여 운영할 수 있다.
제12조(보건의료원)
보건소중 「의료법」 제3조제2항제3호에 따른 병원의 요건을 갖춘 보건소는 보건의료
원이라는 명칭을 사용할 수 있다.
제13조(보건지소의 설치)
지방자치단체는 보건소의 업무수행을 위하여 필요하다고 인정하는 때에는 대통령령이 
정하는 기준에 따라 당해 지방자치단체의 조례로 보건소의 지소(이하 "보건지소"라 
한다)를 설치할 수 있다.
【법규23】 폭력행위 등 처벌에 관한 법률
제2조(폭행 등) 
① 삭제  <2016.1.6.>
② 2명 이상이 공동하여 다음 각 호의 죄를 범한 사람은 「형법」 각 해당 조항에서 정
한 형의 2분의 1까지 가중한다.
1. 「형법」 제260조제1항(폭행), 제283조제1항(협박), 제319조(주거침입, 퇴거불응) 
또는 제366조(재물손괴 등)의 죄
2. 「형법」 제260조제2항(존속폭행), 제276조제1항(체포, 감금), 제283조제2항(존속협
박) 또는 제324조제1항(강요)의 죄
3. 「형법」 제257조제1항(상해)·제2항(존속상해), 제276조제2항(존속체포, 존속감금) 
또는 제350조(공갈)의 죄
③ 이 법(「형법」 각 해당 조항 및 각 해당 조항의 상습범, 특수범, 상습특수범, 각 해
당 조항의 상습범의 미수범, 특수범의 미수범, 상습특수범의 미수범을 포함한다)을 
위반하여 2회 이상 징역형을 받은 사람이 다시 제2항 각 호에 규정된 죄를 범하
여 누범(累犯)으로 처벌할 경우에는 다음 각 호의 구분에 따라 가중처벌한다.
1. 제2항제1호에 규정된 죄를 범한 사람: 7년 이하의 징역
2. 제2항제2호에 규정된 죄를 범한 사람: 1년 이상 12년 이하의 징역
3. 제2항제3호에 규정된 죄를 범한 사람: 2년 이상 20년 이하의 징역
④ 제2항과 제3항의 경우에는 「형법」 제260조제3항 및 제283조제3항을 적용하지 
아니한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (285, 4, 152, '152
제3조(집단적 폭행 등) 
① 삭제  <2016.1.6.>
② 삭제  <2006.3.24.>
③ 삭제  <2016.1.6.>
④ 이 법(「형법」 각 해당 조항 및 각 해당 조항의 상습범, 특수범, 상습특수범, 각 해
당 조항의 상습범의 미수범, 특수범의 미수범, 상습특수범의 미수범을 포함한다)을 
위반하여 2회 이상 징역형을 받은 사람이 다시 다음 각 호의 죄를 범하여 누범으
로 처벌할 경우에는 다음 각 호의 구분에 따라 가중처벌한다.
1. 「형법」 제261조(특수폭행)(제260조제1항의 죄를 범한 경우에 한정한다), 제284조
(특수협박)(제283조제1항의 죄를 범한 경우에 한정한다), 제320조(특수주거침입) 
또는 제369조제1항(특수손괴)의 죄: 1년 이상 12년 이하의 징역
2. 「형법」 제261조(특수폭행)(제260조제2항의 죄를 범한 경우에 한정한다), 제278조
(특수체포, 특수감금)(제276조제1항의 죄를 범한 경우에 한정한다), 제284조(특수
협박)(제283조제2항의 죄를 범한 경우에 한정한다) 또는 제324조제2항(강요)의 
죄: 2년 이상 20년 이하의 징역
3. 「형법」 제258조의2제1항(특수상해), 제278조(특수체포, 특수감금)(제276조제2항의 
죄를 범한 경우에 한정한다) 또는 제350조의2(특수공갈)의 죄: 3년 이상 25년 이
하의 징역
제4조(단체등의 구성·활동)
① 이 법에 규정된 범죄를 목적으로 하는 단체 또는 집단을 구성하거나 그러한 단체 
또는 집단에 가입하거나 그 구성원으로 활동한 사람은 다음 각 호의 구분에 따라 
처벌한다.
1. 수괴(首魁): 사형, 무기 또는 10년 이상의 징역
2. 간부: 무기 또는 7년 이상의 징역
3. 수괴·간부 외의 사람: 2년 이상의 유기징역
② 제1항의 단체 또는 집단을 구성하거나 그러한 단체 또는 집단에 가입한 사람이 단체 
또는 집단의 위력을 과시하거나 단체 또는 집단의 존속·유지를 위하여 다음 각 호의 
어느 하나에 해당하는 죄를 범하였을 때에는 그 죄에 대한 형의 장기(長期) 및 단기
(短期)의 2분의 1까지 가중한다.
1. 「형법」에 따른 죄 중 다음 각 목의 죄
   가. 「형법」 제8장 공무방해에 관한 죄 중 제136조(공무집행방해), 제141조(공용서
류 등의 무효, 공용물의 파괴)의 죄
   나. 「형법」 제24장 살인의 죄 중 제250조제1항(살인), 제252조(촉탁, 승낙에 의한 
살인 등), 제253조(위계 등에 의한 촉탁살인 등), 제255조(예비, 음모)의 죄
   다. 「형법」 제34장 신용, 업무와 경매에 관한 죄 중 제314조(업무방해), 제315조
(경매, 입찰의 방해)의 죄
   라. 「형법」 제38장 절도와 강도의 죄 중 제333조(강도), 제334조(특수강도), 제
335조(준강도), 제336조(인질강도), 제337조(강도상해, 치상), 제339조(강도
강간), 제340조제1항(해상강도)·제2항(해상강도상해 또는 치상), 제341조(상습
범), 제343조(예비, 음모)의 죄
2. 제2조 또는 제3조의 죄(「형법」 각 해당 조항의 상습범, 특수범, 상습특수범을 포함
한다)
③ 타인에게 제1항의 단체 또는 집단에 가입할 것을 강요하거나 권유한 사람은 2년 
이상의 유기징역에 처한다.
④ 제1항의 단체 또는 집단을 구성하거나 그러한 단체 또는 집단에 가입하여 그 단
체 또는 집단의 존속·유지를 위하여 금품을 모집한 사람은 3년 이상의 유기징역
에 처한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (286, 4, 153, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
153
【법규24】 형법
제24장 살인의 죄
제250조(살인, 존속살해)
① 사람을 살해한 자는 사형, 무기 또는 5년 이상의 징역에 처한다.
② 자기 또는 배우자의 직계존속을 살해한 자는 사형, 무기 또는 7년 이상의 징역에 
처한다.
제251조(영아살해)
직계존속이 치욕을 은폐하기 위하거나 양육할 수 없음을 예상하거나 특히 참작할 만
한 동기로 인하여 분만중 또는 분만직후의 영아를 살해한 때에는 10년 이하의 징역
에 처한다.
제252조(촉탁, 승낙에 의한 살인등)
① 사람의 촉탁 또는 승낙을 받어 그를 살해한 자는 1년 이상 10년 이하의 징역에 
처한다.
② 사람을 교사 또는 방조하여 자살하게 한 자도 전항의 형과 같다.
제253조(위계등에 의한 촉탁살인등)
전조의 경우에 위계 또는 위력으로써 촉탁 또는 승낙하게 하거나 자살을 결의하게 한 
때에는 제250조의 예에 의한다.
제254조(미수범)
전4조의 미수범은 처벌한다.
제255조(예비, 음모)
제250조와 제253조의 죄를 범할 목적으로 예비 또는 음모한 자는 10년 이하의 징
역에 처한다.
제256조(자격정지의 병과)
제250조, 제252조 또는 제253조의 경우에 유기징역에 처할 때에는 10년 이하의 자
격정지를 병과할 수 있다.
제25장 상해와 폭행의 죄
제257조(상해, 존속상해)
① 사람의 신체를 상해한 자는 7년 이하의 징역, 10년 이하의 자격정지 또는 1천만
원 이하의 벌금에 처한다.
② 자기 또는 배우자의 직계존속에 대하여 제1항의 죄를 범한 때에는 10년 이하의 
징역 또는 1천500만원 이하의 벌금에 처한다.
③ 전 2항의 미수범은 처벌한다.
제258조(중상해, 존속중상해)
① 사람의 신체를 상해하여 생명에 대한 위험을 발생하게 한 자는 1년 이상 10년 이
하의 징역에 처한다.
② 신체의 상해로 인하여 불구 또는 불치나 난치의 질병에 이르게 한 자도 전항의 
형과 같다.
③ 자기 또는 배우자의 직계존속에 대하여 전2항의 죄를 범한 때에는 2년 이상 15
년 이하의 징역에 처한다.
제258조의2(특수상해)
① 단체 또는 다중의 위력을 보이거나 위험한 물건을 휴대하여 제257조제1항 또는 
제2항의 죄를 범한 때에는 1년 이상 10년 이하의 징역에 처한다.
② 단체 또는 다중의 위력을 보이거나 위험한 물건을 휴대하여 제258조의 죄를 범한 
때에는 2년 이상 20년 이하의 징역에 처한다.
③ 제1항의 미수범은 처벌한다.
제259조(상해치사)
① 사람의 신체를 상해하여 사망에 이르게 한 자는 3년 이상의 유기징역에 처한다.
② 자기 또는 배우자의 직계존속에 대하여 전항의 죄를 범한 때에는 무기 또는 5년 
이상의 징역에 처한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (287, 4, 154, '154
제260조(폭행, 존속폭행)
① 사람의 신체에 대하여 폭행을 가한 자는 2년 이하의 징역, 500만원 이하의 벌금, 
구류 또는 과료에 처한다.
② 자기 또는 배우자의 직계존속에 대하여 제1항의 죄를 범한 때에는 5년 이하의 징
역 또는 700만원 이하의 벌금에 처한다.
③ 제1항 및 제2항의 죄는 피해자의 명시한 의사에 반하여 공소를 제기할 수 없다.
제261조(특수폭행)
단체 또는 다중의 위력을 보이거나 위험한 물건을 휴대하여 제260조제1항 또는 제2
항의 죄를 범한 때에는 5년 이하의 징역 또는 1천만원 이하의 벌금에 처한다.
제262조(폭행치사상)
전2조의 죄를 범하여 사람을 사상에 이르게 한때에는 제257조 내지 제259조의 예에 
의한다.
제263조(동시범)
독립행위가 경합하여 상해의 결과를 발생하게 한 경우에 있어서 원인된 행위가 판명
되지 아니한 때에는 공동정범의 예에 의한다.
제264조(상습범)
상습으로 제257조, 제258조, 제258조의2, 제260조 또는 제261조의 죄를 범한 때
에는 그 죄에 정한 형의 2분의 1까지 가중한다.
제265조(자격정지의 병과)
제257조제2항, 제258조, 제258조의2, 제260조제2항, 제261조 또는 전조의 경우에
는 10년 이하의 자격정지를 병과할 수 있다.
제26장 과실치사상의 죄
제266조(과실치상)
① 과실로 인하여 사람의 신체를 상해에 이르게 한 자는 500만원 이하의 벌금, 구류 
또는 과료에 처한다.
② 제1항의 죄는 피해자의 명시한 의사에 반하여 공소를 제기할 수 없다.
제267조(과실치사)
과실로 인하여 사람을 사망에 이르게 한 자는 2년 이하의 금고 또는 700만원 이하
의 벌금에 처한다.
제268조(업무상과실·중과실 치사상)
업무상과실 또는 중대한 과실로 인하여 사람을 사상에 이르게 한 자는 5년 이하의 
금고 또는 2천만원 이하의 벌금에 처한다.
제32장 강간과 추행의 죄
제297조(강간)
폭행 또는 협박으로 사람을 강간한 자는 3년 이상의 유기징역에 처한다.
제297조의2(유사강간)
폭행 또는 협박으로 사람에 대하여 구강, 항문 등 신체(성기는 제외한다)의 내부에 
성기를 넣거나 성기, 항문에 손가락 등 신체(성기는 제외한다)의 일부 또는 도구를 
넣는 행위를 한 사람은 2년 이상의 유기징역에 처한다.
제298조(강제추행)
폭행 또는 협박으로 사람에 대하여 추행을 한 자는 10년 이하의 징역 또는 1천500
만원 이하의 벌금에 처한다.
제299조(준강간, 준강제추행)
사람의 심신상실 또는 항거불능의 상태를 이용하여 간음 또는 추행을 한 자는 제297
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (288, 4, 155, '참
고
무배당 프로미라이프 참좋은오토바이운전자보험1707
155
조, 제297조의2 및 제298조의 예에 의한다.
제300조(미수범)
제297조, 제297조의2, 제298조 및 제299조의 미수범은 처벌한다.
제301조(강간등 상해·치상)
제297조, 제297조의2 및 제298조부터 제300조까지의 죄를 범한 자가 사람을 상해
하거나 상해에 이르게 한 때에는 무기 또는 5년 이상의 징역에 처한다.
제301조의2(강간등 살인·치사)
제297조, 제297조의2 및 제298조부터 제300조까지의 죄를 범한 자가 사람을 살해
한 때에는 사형 또는 무기징역에 처한다. 사망에 이르게 한 때에는 무기 또는 10년 
이상의 징역에 처한다.
제302조(미성년자등에 대한 간음)
미성년자 또는 심신미약자에 대하여 위계 또는 위력으로써 간음 또는 추행을 한 자는 
5년 이하의 징역에 처한다.
제303조(업무상위력등에 의한 간음)
① 업무, 고용 기타 관계로 인하여 자기의 보호 또는 감독을 받는 사람에 대하여 위
계 또는 위력으로써 간음한 자는 5년 이하의 징역 또는 1천500만원 이하의 벌금
에 처한다.
② 법률에 의하여 구금된 사람을 감호하는 자가 그 사람을 간음한 때에는 7년 이하
의 징역에 처한다.
제305조(미성년자에 대한 간음, 추행)
13세 미만의 사람에 대하여 간음 또는 추행을 한 자는 제297조, 제297조의2, 제
298조, 제301조 또는 제301조의2의 예에 의한다.
제305조의2(상습범)
상습으로 제297조, 제297조의2, 제298조부터 제300조까지, 제302조, 제303조 또
는 제305조의 죄를 범한 자는 그 죄에 정한 형의 2분의 1까지 가중한다.
제38장 절도와 강도의 죄
제339조(강도강간)
강도가 사람을 강간한 때에는 무기 또는 10년 이상의 징역에 처한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_pages (id, document_id, page_number, raw_text) VALUES (289, 4, 156, '156
【법규25】 화재로 인한 재해보상과 보험가입에 관한 법률
제4조(특수건물 소유자의 손해배상책임) 제 1항
① 특수건물의 소유자는 그 건물의 화재로 인하여 다른 사람이 사망하거나 부상을 입
었을 때에는 과실이 없는 경우에도 제8조에 따른 보험금액의 범위에서 그 손해를 
배상할 책임이 있다. 「실화책임에 관한 법률」에도 불구하고 특수건물 소유자에게 
경과실(輕過失)이 있는 경우에도 또한 같다.
제8조(보험금액)
① 제5조에 따라 가입하는 보험의 보험금액은 다음 각 호의 구분에 따른다.
1. 화재보험: 특수건물의 시가(時價)에 해당하는 금액
2. 신체손해배상책임보험 중 사망의 경우: 피해자 1명당 50만원 이상으로서 대통
령령으로 정하는 금액
3. 신체손해배상책임보험 중 부상의 경우: 피해자 1명당 사망자에 대한 보험금액
의 범위에서 대통령령으로 정하는 금액
② 제1항제1호에 규정한 시가의 결정에 관한 기준은 총리령으로 정한다.
【법규26】 화재로 인한 재해보상과 보험가입에 관한 법률 시행령
제5조(보험금액)
① 법 제8조제1항제2호 및 제3호의 규정에 의한 보험금액은 다음과 같다.
1. 사망의 경우에는 8천만원. 다만, 실손해액이 2천만원미만인 경우에는 2천만원
으로 한다.
2. 부상의 경우에는 별표 1에서 정하는 금액. 다만, 지급보험금은 실손해액을 초
과할 수 없다.
3. 부상의 경우 그 치료가 완료된 후 당해 부상이 원인이 되어 신체에 장해(이하 
"후유장해"라 한다)가 생긴 때에는 별표2에서 정하는 금액
② 제1항제1호 및 제2호의 규정에 의한 실손해액의 범위는 총리령으로 정한다.
③ 부상자가 치료중에 사망한 경우에는 제1항제1호 및 제2호의 보험금을 함께 지급
한다.
④ 부상한 자에게 후유장해가 생긴 경우에는 제1항제2호 및 제3호의 금액을 함께 지
급한다.
⑤ 제1항제3호의 금액을 지급한 후 부상이 원인이 되어 사망한 경우에는 제1항제1
호의 금액에서 동항제3호의 규정에 의하여 지급한 금액을 공제하고 지급한다.
제8조(보험금 지급)
① 손해보험회사는 보험금의 지급 청구가 있을 때에는 정당한 사유가 있는 경우를 제
외하고는 지체없이 이를 지급하여야 한다.
② 손해보험회사는 법 제9조의 규정에 의하여 보험금을 지급한 때에는 지체없이 다
음 각호의 사항을 보험계약자에게 통지하여야 한다.
1. 보험금의 지급청구자와 수령자의 주소 및 성명
2. 청구액과 지급액
3. 피해자의 주소 및 성명
【법규27】 화재로 인한 재해보상과 보험가입에 관한 법률 
시행규칙
제2조(실손해액)
① 「화재로 인한 재해보상과 보험가입에 관한 법률 시행령」(이하 "영"이라 한다) 제5
조 제1항제1호에 따른 실손해액은 화재로 인하여 사망한 때의 월급액이나 월실수
액 또는 평균임금에 장래의 취업가능 기간을 곱하여 산출한 금액에 남자평균임금
의 100일분에 해당하는 장례비를 더한 금액으로 한다.
② 영 제5조제1항제2호의 규정에 의한 실손해액은 화재로 인하여 신체상에 상해를 
입은 경우에 그 상해를 치료함에 소요되는 모든 비용으로 한다.
') ON CONFLICT DO NOTHING;
INSERT INTO policy_articles (id, document_id, section_id, article_no, title, paragraph_no, item_no, raw_text, page_number) VALUES (1, 1, NULL, '제21조', '보상하는 손해', NULL, NULL, '제21조 (보상하는 손해)  
① 자기차량손해에서 보험회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 발생한 사고로 인하
  여 피보험자동차에 직접적으로 생긴 손해를 보험증권에 기재된 보험가입금액을 한도로 보상하되 다음 각 호의 
  기준에 따릅니다. 
 1. 보험가입금액이 보험가액보다 많은 경우에는 보험가액을 한도로 보상합니다.
 2.  피보험자동차에 통상 붙어있거나 장치되어 있는 부속품과 부속기계장치는 피보험자동차의 일부로 봅니다. 그
   러나 통상 붙어 있거나 장치되어 있는 것이 아닌 것은 보험증권에 기재된 것에 한정합니다.
 3.  피보험자동차의 일방과실사고의 경우에는 실제 수리를 원칙으로 합니다.
 4.  경미한 손상(*1)의 경우 보험개발원이 정한 경미손상 수리기준에 따라 복원수리하거나 품질인증부품(*2)으로 
   교환수리하는 데 소요되는 비용을 한도로 보상합니다.', 25) ON CONFLICT DO NOTHING;
INSERT INTO policy_articles (id, document_id, section_id, article_no, title, paragraph_no, item_no, raw_text, page_number) VALUES (2, 1, NULL, '제23조', '보상하지 않는 손해', NULL, NULL, '제23조 (보상하지 않는 손해)  
다음 중 어느 하나에 해당하는 손해는 자기차량손해에서 보상하지 않습니다.
 1.  보험계약자 또는 피보험자의 고의로 인한 손해
 2.  전쟁, 혁명, 내란, 사변, 폭동, 소요지식17) 및 이와 유사한 사태로 인한 손해
 3.  지진, 분화 등 천재지변으로 인한 손해
 4.  핵연료물질의 직접 또는 간접적인 영향으로 인한 손해
 5.  영리를 목적으로 요금이나 대가를 받고 피보험자동차를 반복적으로 사용하거나 빌려 준 때에 생긴 손해. 다
   만, 다음 각목의 어느 하나에 해당하는 경우에는 보상합니다.
② 제①항의 ‘사고’는 다음 중 어느 하나에 해당하는 사고를 말합니다. 
 1.  타차량(*1)과의 충돌 또는 접촉으로 인한 손해
 2.  피보험자동차 전부의 도난으로 인한 손해(단, 전부도난이 아닌 경우에는 보상하지 않습니다)
(*1) ‘경미한 손상’이란 외장부품 중 자동차의 기능과 안전성을 고려할 때 부품교체 없이 복원이 가능한 손상을 말합
   니다.
   예시) 외장부품의 코팅, 색상 등의 손상에 대한 도색, 판금으로 복원이 가능한 경우 등
(*2) ‘품질인증부품’이란 「자동차관리법」 제30조의5에 따라 인증된 부품을 말합니다.
   다만, 자동차 취급업자가 업무상 위탁받은 피보험자동차를 사용하거나 관리하는 경우에는 피보험자로 보지 
   않습니다.', 25) ON CONFLICT DO NOTHING;
INSERT INTO policy_articles (id, document_id, section_id, article_no, title, paragraph_no, item_no, raw_text, page_number) VALUES (3, 1, NULL, '제24조', '지급보험금의 계산', NULL, NULL, '제24조 (지급보험금의 계산)  
①  자기차량손해의 지급보험금은 다음과 같이 계산하며, 보험회사는 ‘피보험자동차에 생긴 손해액’과 ‘비용’을 합
  한 액수에서 보험증권에 기재된 ‘자기부담금’을 공제한 후 보험금으로 지급합니다.
지급보험금
피보험자동차에
생긴 손해액
비용
보험증권에 기재된
자기부담금
=
+
-
32) “잔존물”이란 보험사고 처리 후 남아있는 피보험자동차 등 보험목적물(보험에 가입한 대상)을 말합니다.
33) “감가상각”이란 “일정기간이 지나면 상실되는 물건의 가치감소분”을 빼는 것을 말합니다. 
(*1) ‘임차인’이 법인인 경우에는 그 이사, 감사 또는 피고용자(피고용자가 피보험자동차를 법인의 업무에 사용하
   고 있는 때에 한정함)를 포함합니다.
 1.  위 ‘피보험자동차에 생긴 손해액’은 다음과 같이 결정합니다. 
  가. 보험증권에 기재된 보험가입금액을 한도로 보상하며, 보험가입금액이 보험사고 발생 당시 보험개발원의 자
    동차보험 차량기준가액표(적용요령에서 정한 기준 포함)에 정한 가액보다 많은 경우에는 보험사고 발생 당
    시 가액을 한도로 보상합니다.
  나. 피보험자동차의 손상을 고칠 수 있는 경우에는, 사고가 생기기 바로 전의 상태로 만드는데 드는 수리비. 
    단, 잔존물지식32)이 있는 경우에는 그 값을 공제합니다.
  다. 피보험자동차를 고칠 때에 부득이 새 부분품(*1)을 쓴 경우에는, 그 부분품의 값과 그 부착 비용을 합한 금액. 
    다만, 엔진, 미션 등 중요한 부분(*2)을 새 부분품으로 교환한 경우 그 교환된 기존 부분품의 감가상각지식33)에 
    해당하는 금액을 공제합니다.
  라. 피보험자동차가 제힘으로 움직일 수 없는 경우에는, 이를 고칠 수 있는 가까운 정비공장이나 보험회사가 지
    정하는 곳까지 운반하는데 든 비용 또는 그 곳까지 운반하는데 든 임시수리비용 중에서 정당하다고 인정되
    는 부분은 보상하여 드립니다.
 2. 위 ‘비용’은 다음의 금액을 말합니다. 이 비용은 보험가입금액과 관계없이 보상하여 드립니다.
  가. 손해의 방지와 경감을 위하여 지출한 비용
  나. 다른 사람으로부터 손해배상을 받을 수 있는 권리의 보전과 행사를 위하여 지출한 비용 
 3. 위 ‘자기부담금’은 피보험자동차에 전부손해(*3)가 생긴 경우 또는 보험회사가 보상해야 할 금액이 전액 이상
    인 경우에는 공제하지 않습니다.
 4. 대물배상 책임이 발생하는 사고 시 사고 당사자간 과실이 모두 있는 경우 상대방에게 손해배상금 또는 상대방
   이 가입한 보험회사에서 대물배상 보험금을 지급받기 전에 자기차량손해 담보로 보험금을 지급받고자 하는 
   경우에는 자기차량손해 담보에서 정한 자기부담금을 피보험자가 확정적으로 부담하는 조건으로 자기차량손
   해 보험금을 먼저 지급하여 드리며, 자기부담금을 부담한 피보험자는 상대방 또는 상대방이 가입한 보험회사
   에게 이 금액을 청구할 수 없습니다. 이 경우 자기차량손해 보험금을 지급한 보험회사는 지급한 보험금 범위
   에서 상대방 또는 상대방이 가입한 보험회사에 대하여 가지는 피보험자의 권리를 취득합니다. 다만, 상대방 
   손해배상책임액이 보험회사가 구상한 금액보다 큰 경우에 피보험자는 상대방 또는 상대방이 가입한 보험회사
   에 그 차액을 청구할 수 있습니다.
 5. 자기차량손해 보험금을 지급한 보험회사가 상대방 또는 상대방이 가입한 보험회사로부터 구상금을 받은 경우 
   (1) 피보험자가 이미 부담한 자기부담금과 (2) 실제 손해액에서 당해 구상금을 제외한 금액을 전제로 산정된 
   자기부담금과의 차액을 피보험자에게 지급하여 드립니다. (이 경우에도 피보험자가 최종적으로 부담하는 자
   기부담금은 최소 자기부담금 이상으로 합니다.)
② 보험회사는 피보험자동차에 생긴 손해에 대하여 보험회사가 필요하다고 인정하는 경우에는, 피보험자의 동의
  를 받아 수리하거나 대용품을 주는 것으로 보험금 지급을 대신할 수 있습니다. 
③  보험회사가 보상한 손해가 전부손해이거나 보험회사가 보상한 금액이 보험가입금액 전액 이상인 경우에는 자
  기차량손해의 보험계약은 사고 발생 시에 종료됩니다. 
④  보험회사가 피보험자동차의 전부손해에 대하여 보험금 전액을 지급한 경우에는 피해물을 인수합니다. 이 경우 
  보험가입금액이 보험가액보다 적을 때에는 보험가입금액의 보험가액에 대한 비율에 따라 피해물을 인수합니
  다. 그러나, 보험회사가 피해물을 인수하지 않는다는 뜻을 표시하고 보험금을 지급하는 경우에는 피해물에 대한 
  피보험자의 권리가 보험회사에 이전되지 않습니다.
(*1) ‘부분품’이란 보통약관 제1조(용어의 정의) 제6호의 가목의 엔진, 변속기(트랜스미션) 등 자동차가 공장에서 
   출고될 때 원형 그대로 부착되어 자동차의 조성부분이 되는 재료를 말합니다.
   다만, 피보험자가 원하는 경우 「자동차관리법」 제30조의5에 따른 품질인증부품을 사용할 수 있으며, 피보험자
   동차의 단독사고(가해자불명사고 포함) 또는 일방과실사고로 보통약관 「자기차량손해」 또는 「차량단독사고 보
   장 특별약관」에 따라서 보험금이 지급되는 경우 「품질인증부품 사용 특별약관」에 따라 수리비의 일정액을 피보
   험자에게 지급하여 드립니다.
(*2) ‘중요한 부분’이란 엔진, 미션, 캐빈, 적재함, 바디 및 전기차(하이브리드 자동차 포함)의 모터, 감속기, 구동용 
   배터리 등 중요한 부분품을 말합니다.
(*3) ‘전부손해’란 피보험자동차가 완전히 파손, 멸실 또는 오손되어 수리할 수 없는 상태이거나, 피보험자동차에 
   생긴 손해액과 보험회사가 부담하기로 한 비용의 합산액이 보험가액 이상인 경우를 말합니다.
  가. 임대차계약(계약기간이 30일을 초과하는 경우에 한함)에 따라 임차인이 피보험자동차를 전속적으로 사용
    하는 경우 (다만, 임차인이 피보험자동차를 영리를 목적으로 요금이나 대가를 받고 반복적으로 사용하는 경
    우에는 보상하지 않습니다.)
  나. 피보험자와 동승자가 「여객자동차운수사업법」에 따른 토요일, 일요일 및 공휴일을 제외한 날의 출䞱퇴근 시
    간대(오전 7시부터 오전 9시까지 및 오후 6시부터 오후 8시까지를 말합니다.)에 실제의 출䞱퇴근 용도로 자
    택과 직장 사이를 이동하면서 승용차 함께 타기를 실시한 경우
 6.  사기 또는 횡령으로 인한 손해
 7.  국가나 공공단체의 공권력 행사에 의한 압류, 징발, 몰수, 파괴 등으로 인한 손해. 그러나 소방이나 피난에 필
   요한 조치로 손해가 발생한 경우에는 그 손해를 보상합니다.
 8.  피보험자동차에 생긴 흠, 마멸, 부식, 녹, 그 밖에 자연소모로 인한 손해
 9.  피보험자동차의 일부 부분품, 부속품, 부속기계장치만의 도난으로 인한 손해
 10.  동파로 인한 손해 또는 우연한 외래의 사고에 직접 관련이 없는 전기적, 기계적 손해
 11.  피보험자동차를 시험용, 경기용 또는 경기를 위해 연습용으로 사용하던 중 생긴 손해. 다만, 운전면허시험을 
   위한 도로주행시험용으로 사용하던 중 생긴 손해는 보상합니다.
 12.  피보험자동차를 운송하거나 싣', 26) ON CONFLICT DO NOTHING;
INSERT INTO coverages (id, version_id, coverage_name, coverage_type, rule_status, trigger_text, payment_type, payment_formula, confidence_score) VALUES (1, 1, '자기차량손해', 'AUTO_OWN_DAMAGE', 'VERIFIED_POLICY', '제21조 (보상하는 손해)  
① 자기차량손해에서 보험회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 발생한 사고로 인하
  여 피보험자동차에 직접적으로 생긴 손해를 보험증권에 기재된 보험가입금액을 한도로 보상하되 다음 각 호의 
  기준에 따릅니다. 
 1. 보험가입금액이 보험가액보다 많은 경우에는 보험가액을 한도로 보상합니다.
 2.  피보험자동차에 통상 붙어있거나 장치되어 있는 부속품과 부속기계장치는 피보험자동차의 일부로 봅니다. 그
   러나 통상 붙어 있거나 장치되어 있는 것이 아닌 것은 보험증권에 기재된 것에 한정합니다.
 3.  피보험자동차의 일방과실사고의 경우에는 실제 수리를 원칙으로 합니다.
 4.  경미한 손상(*1)의 경우 보험개발원이 정한 경미손상 수리기준에 따라 복원수리하거나 품질인증부품(*2)으로 
   교환수리하는 데 소요되는 비용을 한도로 보상합니다.', 'FORMULA', 'min(vehicle_damage + expenses - deductible, insured_amount)', 0.99) ON CONFLICT DO NOTHING;
INSERT INTO coverages (id, version_id, coverage_name, coverage_type, rule_status, trigger_text, payment_type, payment_formula, confidence_score) VALUES (2, 2, '암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상)', 'TREATMENT', 'OFFICIAL_CROSSCHECKED', '암주요치료비Ⅱ(유사암제외)(연 간1회한)(10년지급대상) 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에 약관에서정한암 (유사암제외)으로최초진단확정되고"보험금 지급대상기간"(암(유사암제외) 최초진단확 정일로부터10년) 이내에암(유사암제외)으로 암주요치료(암수술, 항암방사선치료, 항암약 물치료)를받은경우 연간1회에한하여보험가입 금액을지급함(즉, 최대10 회지급) ※ 세부내용은약관참고 ', 'PERCENT_OF_INSURED_AMOUNT', 'insured_amount * payment_rate', 0.9) ON CONFLICT DO NOTHING;
INSERT INTO coverages (id, version_id, coverage_name, coverage_type, rule_status, trigger_text, payment_type, payment_formula, confidence_score) VALUES (3, 2, '암(유사암제외) 치료비지원', 'DIAGNOSIS', 'OFFICIAL_CROSSCHECKED', '암(유사암제외) 치료비지원 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에암(유사암제외)으로 진단확정시 가입금액지급 (최초1회에한함. 기타피부 암, 갑상선암, 제자리암, 경 계성종양은보장하지않음) ', 'PERCENT_OF_INSURED_AMOUNT', 'insured_amount * payment_rate', 0.9) ON CONFLICT DO NOTHING;
INSERT INTO coverage_conditions (id, coverage_id, condition_type, condition_operator, condition_value, raw_text) VALUES (1, 2, 'WAITING_PERIOD_DAYS', '>=', '"90"'::jsonb, '암주요치료비Ⅱ(유사암제외)(연 간1회한)(10년지급대상) 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에 약관에서정한암 (유사암제외)으로최초진단확정되고"보험금 지급대상기간"(암(유사암제외) 최초진단확 정일로부터10년) 이내에암(유사암제외)으로 암주요치료(암수술, 항암방사선치료, 항암약 물치료)를받은경우 연간1회에한하여보험가입 금액을지급함(즉, 최대10 회지급) ※ 세부내용은약관참고 ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_conditions (id, coverage_id, condition_type, condition_operator, condition_value, raw_text) VALUES (2, 2, 'TREATMENT_TYPE', 'INCLUDES', '"암수술"'::jsonb, '암주요치료비Ⅱ(유사암제외)(연 간1회한)(10년지급대상) 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에 약관에서정한암 (유사암제외)으로최초진단확정되고"보험금 지급대상기간"(암(유사암제외) 최초진단확 정일로부터10년) 이내에암(유사암제외)으로 암주요치료(암수술, 항암방사선치료, 항암약 물치료)를받은경우 연간1회에한하여보험가입 금액을지급함(즉, 최대10 회지급) ※ 세부내용은약관참고 ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_conditions (id, coverage_id, condition_type, condition_operator, condition_value, raw_text) VALUES (3, 2, 'TREATMENT_TYPE', 'INCLUDES', '"항암방사선치료"'::jsonb, '암주요치료비Ⅱ(유사암제외)(연 간1회한)(10년지급대상) 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에 약관에서정한암 (유사암제외)으로최초진단확정되고"보험금 지급대상기간"(암(유사암제외) 최초진단확 정일로부터10년) 이내에암(유사암제외)으로 암주요치료(암수술, 항암방사선치료, 항암약 물치료)를받은경우 연간1회에한하여보험가입 금액을지급함(즉, 최대10 회지급) ※ 세부내용은약관참고 ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_conditions (id, coverage_id, condition_type, condition_operator, condition_value, raw_text) VALUES (4, 2, 'TREATMENT_TYPE', 'INCLUDES', '"항암약물치료"'::jsonb, '암주요치료비Ⅱ(유사암제외)(연 간1회한)(10년지급대상) 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에 약관에서정한암 (유사암제외)으로최초진단확정되고"보험금 지급대상기간"(암(유사암제외) 최초진단확 정일로부터10년) 이내에암(유사암제외)으로 암주요치료(암수술, 항암방사선치료, 항암약 물치료)를받은경우 연간1회에한하여보험가입 금액을지급함(즉, 최대10 회지급) ※ 세부내용은약관참고 ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_conditions (id, coverage_id, condition_type, condition_operator, condition_value, raw_text) VALUES (5, 3, 'WAITING_PERIOD_DAYS', '>=', '"90"'::jsonb, '암(유사암제외) 치료비지원 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에암(유사암제외)으로 진단확정시 가입금액지급 (최초1회에한함. 기타피부 암, 갑상선암, 제자리암, 경 계성종양은보장하지않음) ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_conditions (id, coverage_id, condition_type, condition_operator, condition_value, raw_text) VALUES (6, 3, 'DISEASE_TERM_EXCLUSION', 'EXCLUDES', '"기타피부암"'::jsonb, '암(유사암제외) 치료비지원 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에암(유사암제외)으로 진단확정시 가입금액지급 (최초1회에한함. 기타피부 암, 갑상선암, 제자리암, 경 계성종양은보장하지않음) ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_conditions (id, coverage_id, condition_type, condition_operator, condition_value, raw_text) VALUES (7, 3, 'DISEASE_TERM_EXCLUSION', 'EXCLUDES', '"갑상선암"'::jsonb, '암(유사암제외) 치료비지원 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에암(유사암제외)으로 진단확정시 가입금액지급 (최초1회에한함. 기타피부 암, 갑상선암, 제자리암, 경 계성종양은보장하지않음) ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_conditions (id, coverage_id, condition_type, condition_operator, condition_value, raw_text) VALUES (8, 3, 'DISEASE_TERM_EXCLUSION', 'EXCLUDES', '"제자리암"'::jsonb, '암(유사암제외) 치료비지원 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에암(유사암제외)으로 진단확정시 가입금액지급 (최초1회에한함. 기타피부 암, 갑상선암, 제자리암, 경 계성종양은보장하지않음) ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_conditions (id, coverage_id, condition_type, condition_operator, condition_value, raw_text) VALUES (9, 3, 'DISEASE_TERM_EXCLUSION', 'EXCLUDES', '"경계성종양"'::jsonb, '암(유사암제외) 치료비지원 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에암(유사암제외)으로 진단확정시 가입금액지급 (최초1회에한함. 기타피부 암, 갑상선암, 제자리암, 경 계성종양은보장하지않음) ') ON CONFLICT DO NOTHING;
INSERT INTO payment_rules (id, coverage_id, payment_type, base_amount, payment_rate, formula, raw_text, confidence_score, human_verified) VALUES (1, 2, 'PERCENT_OF_INSURED_AMOUNT', NULL, 1.0, '{"expression": "insured_amount * payment_rate"}'::jsonb, '암주요치료비Ⅱ(유사암제외)(연 간1회한)(10년지급대상) 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에 약관에서정한암 (유사암제외)으로최초진단확정되고"보험금 지급대상기간"(암(유사암제외) 최초진단확 정일로부터10년) 이내에암(유사암제외)으로 암주요치료(암수술, 항암방사선치료, 항암약 물치료)를받은경우 연간1회에한하여보험가입 금액을지급함(즉, 최대10 회지급) ※ 세부내용은약관참고 ', 0.78, FALSE) ON CONFLICT DO NOTHING;
INSERT INTO payment_rules (id, coverage_id, payment_type, base_amount, payment_rate, formula, raw_text, confidence_score, human_verified) VALUES (2, 3, 'PERCENT_OF_INSURED_AMOUNT', NULL, 1.0, '{"expression": "insured_amount * payment_rate"}'::jsonb, '암(유사암제외) 치료비지원 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에암(유사암제외)으로 진단확정시 가입금액지급 (최초1회에한함. 기타피부 암, 갑상선암, 제자리암, 경 계성종양은보장하지않음) ', 0.82, FALSE) ON CONFLICT DO NOTHING;
INSERT INTO coverage_limits (id, coverage_id, limit_type, amount, currency, period_rule, raw_text) VALUES (1, 2, 'ANNUAL_FREQUENCY', 1.0, 'KRW', 'per insurance year', '암주요치료비Ⅱ(유사암제외)(연 간1회한)(10년지급대상) 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에 약관에서정한암 (유사암제외)으로최초진단확정되고"보험금 지급대상기간"(암(유사암제외) 최초진단확 정일로부터10년) 이내에암(유사암제외)으로 암주요치료(암수술, 항암방사선치료, 항암약 물치료)를받은경우 연간1회에한하여보험가입 금액을지급함(즉, 최대10 회지급) ※ 세부내용은약관참고 ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_limits (id, coverage_id, limit_type, amount, currency, period_rule, raw_text) VALUES (2, 2, 'MAX_PAYMENTS', 10.0, 'KRW', 'coverage lifetime / target period', '암주요치료비Ⅱ(유사암제외)(연 간1회한)(10년지급대상) 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에 약관에서정한암 (유사암제외)으로최초진단확정되고"보험금 지급대상기간"(암(유사암제외) 최초진단확 정일로부터10년) 이내에암(유사암제외)으로 암주요치료(암수술, 항암방사선치료, 항암약 물치료)를받은경우 연간1회에한하여보험가입 금액을지급함(즉, 최대10 회지급) ※ 세부내용은약관참고 ') ON CONFLICT DO NOTHING;
INSERT INTO coverage_limits (id, coverage_id, limit_type, amount, currency, period_rule, raw_text) VALUES (3, 3, 'MAX_PAYMENTS', 1.0, 'KRW', 'coverage lifetime / target period', '암(유사암제외) 치료비지원 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에암(유사암제외)으로 진단확정시 가입금액지급 (최초1회에한함. 기타피부 암, 갑상선암, 제자리암, 경 계성종양은보장하지않음) ') ON CONFLICT DO NOTHING;
INSERT INTO exclusions (id, coverage_id, exclusion_type, exclusion_text) VALUES (1, 1, 'POLICY_EXCLUSION', '제23조 (보상하지 않는 손해)  
다음 중 어느 하나에 해당하는 손해는 자기차량손해에서 보상하지 않습니다.
 1.  보험계약자 또는 피보험자의 고의로 인한 손해
 2.  전쟁, 혁명, 내란, 사변, 폭동, 소요지식17) 및 이와 유사한 사태로 인한 손해
 3.  지진, 분화 등 천재지변으로 인한 손해
 4.  핵연료물질의 직접 또는 간접적인 영향으로 인한 손해
 5.  영리를 목적으로 요금이나 대가를 받고 피보험자동차를 반복적으로 사용하거나 빌려 준 때에 생긴 손해. 다
   만, 다음 각목의 어느 하나에 해당하는 경우에는 보상합니다.
② 제①항의 ‘사고’는 다음 중 어느 하나에 해당하는 사고를 말합니다. 
 1.  타차량(*1)과의 충돌 또는 접촉으로 인한 손해
 2.  피보험자동차 전부의 도난으로 인한 손해(단, 전부도난이 아닌 경우에는 보상하지 않습니다)
(*1) ‘경미한 손상’이란 외장부품 중 자동차의 기능과 안전성을 고려할 때 부품교체 없이 복원이 가능한 손상을 말합
   니다.
   예시) 외장부품의 코팅, 색상 등의 손상에 대한 도색, 판금으로 복원이 가능한 경우 등
(*2) ‘품질인증부품’이란 「자동차관리법」 제30조의5에 따라 인증된 부품을 말합니다.
   다만, 자동차 취급업자가 업무상 위탁받은 피보험자동차를 사용하거나 관리하는 경우에는 피보험자로 보지 
   않습니다.') ON CONFLICT DO NOTHING;
INSERT INTO disease_codes (id, coverage_id, disease_group, kcd_code_from, kcd_code_to, included_codes, excluded_codes, raw_text, source_status) VALUES (1, 2, '암(유사암제외)', NULL, NULL, NULL, NULL, '상품요약서에는 KCD 코드표가 제시되지 않아 약관 별표 확보 필요', 'AWAITING_POLICY_APPENDIX') ON CONFLICT DO NOTHING;
INSERT INTO disease_codes (id, coverage_id, disease_group, kcd_code_from, kcd_code_to, included_codes, excluded_codes, raw_text, source_status) VALUES (2, 3, '암(유사암제외)', NULL, NULL, NULL, NULL, '상품요약서에는 KCD 코드표가 제시되지 않아 약관 별표 확보 필요', 'AWAITING_POLICY_APPENDIX') ON CONFLICT DO NOTHING;
INSERT INTO source_references (id, coverage_id, document_id, page_number, article_no, source_text, reference_type) VALUES (1, 1, 1, 25, '제21조', '제21조 (보상하는 손해)  
① 자기차량손해에서 보험회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 발생한 사고로 인하
  여 피보험자동차에 직접적으로 생긴 손해를 보험증권에 기재된 보험가입금액을 한도로 보상하되 다음 각 호의 
  기준에 따릅니다. 
 1. 보험가입금액이 보험가액보다 많은 경우에는 보험가액을 한도로 보상합니다.
 2.  피보험자동차에 통상 붙어있거나 장치되어 있는 부속품과 부속기계장치는 피보험자동차의 일부로 봅니다. 그
   러나 통상 붙어 있거나 장치되어 있는 것이 아닌 것은 보험증권에 기재된 것에 한정합니다.
 3.  피보험자동차의 일방과실사고의 경우에는 실제 수리를 원칙으로 합니다.
 4.  경미한 손상(*1)의 경우 보험개발원이 정한 경미손상 수리기준에 따라 복원수리하거나 품질인증부품(*2)으로 
   교환수리하는 데 소요되는 비용을 한도로 보상합니다.', 'TRIGGER') ON CONFLICT DO NOTHING;
INSERT INTO source_references (id, coverage_id, document_id, page_number, article_no, source_text, reference_type) VALUES (2, 1, 1, 25, '제23조', '제23조 (보상하지 않는 손해)  
다음 중 어느 하나에 해당하는 손해는 자기차량손해에서 보상하지 않습니다.
 1.  보험계약자 또는 피보험자의 고의로 인한 손해
 2.  전쟁, 혁명, 내란, 사변, 폭동, 소요지식17) 및 이와 유사한 사태로 인한 손해
 3.  지진, 분화 등 천재지변으로 인한 손해
 4.  핵연료물질의 직접 또는 간접적인 영향으로 인한 손해
 5.  영리를 목적으로 요금이나 대가를 받고 피보험자동차를 반복적으로 사용하거나 빌려 준 때에 생긴 손해. 다
   만, 다음 각목의 어느 하나에 해당하는 경우에는 보상합니다.
② 제①항의 ‘사고’는 다음 중 어느 하나에 해당하는 사고를 말합니다. 
 1.  타차량(*1)과의 충돌 또는 접촉으로 인한 손해
 2.  피보험자동차 전부의 도난으로 인한 손해(단, 전부도난이 아닌 경우에는 보상하지 않습니다)
(*1) ‘경미한 손상’이란 외장부품 중 자동차의 기능과 안전성을 고려할 때 부품교체 없이 복원이 가능한 손상을 말합
   니다.
   예시) 외장부품의 코팅, 색상 등의 손상에 대한 도색, 판금으로 복원이 가능한 경우 등
(*2) ‘품질인증부품’이란 「자동차관리법」 제30조의5에 따라 인증된 부품을 말합니다.
   다만, 자동차 취급업자가 업무상 위탁받은 피보험자동차를 사용하거나 관리하는 경우에는 피보험자로 보지 
   않습니다.', 'EXCLUSION') ON CONFLICT DO NOTHING;
INSERT INTO source_references (id, coverage_id, document_id, page_number, article_no, source_text, reference_type) VALUES (3, 1, 1, 26, '제24조', '제24조 (지급보험금의 계산)  
①  자기차량손해의 지급보험금은 다음과 같이 계산하며, 보험회사는 ‘피보험자동차에 생긴 손해액’과 ‘비용’을 합
  한 액수에서 보험증권에 기재된 ‘자기부담금’을 공제한 후 보험금으로 지급합니다.
지급보험금
피보험자동차에
생긴 손해액
비용
보험증권에 기재된
자기부담금
=
+
-
32) “잔존물”이란 보험사고 처리 후 남아있는 피보험자동차 등 보험목적물(보험에 가입한 대상)을 말합니다.
33) “감가상각”이란 “일정기간이 지나면 상실되는 물건의 가치감소분”을 빼는 것을 말합니다. 
(*1) ‘임차인’이 법인인 경우에는 그 이사, 감사 또는 피고용자(피고용자가 피보험자동차를 법인의 업무에 사용하
   고 있는 때에 한정함)를 포함합니다.
 1.  위 ‘피보험자동차에 생긴 손해액’은 다음과 같이 결정합니다. 
  가. 보험증권에 기재된 보험가입금액을 한도로 보상하며, 보험가입금액이 보험사고 발생 당시 보험개발원의 자
    동차보험 차량기준가액표(적용요령에서 정한 기준 포함)에 정한 가액보다 많은 경우에는 보험사고 발생 당
    시 가액을 한도로 보상합니다.
  나. 피보험자동차의 손상을 고칠 수 있는 경우에는, 사고가 생기기 바로 전의 상태로 만드는데 드는 수리비. 
    단, 잔존물지식32)이 있는 경우에는 그 값을 공제합니다.
  다. 피보험자동차를 고칠 때에 부득이 새 부분품(*1)을 쓴 경우에는, 그 부분품의 값과 그 부착 비용을 합한 금액. 
    다만, 엔진, 미션 등 중요한 부분(*2)을 새 부분품으로 교환한 경우 그 교환된 기존 부분품의 감가상각지식33)에 
    해당하는 금액을 공제합니다.
  라. 피보험자동차가 제힘으로 움직일 수 없는 경우에는, 이를 고칠 수 있는 가까운 정비공장이나 보험회사가 지
    정하는 곳까지 운반하는데 든 비용 또는 그 곳까지 운반하는데 든 임시수리비용 중에서 정당하다고 인정되
    는 부분은 보상하여 드립니다.
 2. 위 ‘비용’은 다음의 금액을 말합니다. 이 비용은 보험가입금액과 관계없이 보상하여 드립니다.
  가. 손해의 방지와 경감을 위하여 지출한 비용
  나. 다른 사람으로부터 손해배상을 받을 수 있는 권리의 보전과 행사를 위하여 지출한 비용 
 3. 위 ‘자기부담금’은 피보험자동차에 전부손해(*3)가 생긴 경우 또는 보험회사가 보상해야 할 금액이 전액 이상
    인 경우에는 공제하지 않습니다.
 4. 대물배상 책임이 발생하는 사고 시 사고 당사자간 과실이 모두 있는 경우 상대방에게 손해배상금 또는 상대방
   이 가입한 보험회사에서 대물배상 보험금을 지급받기 전에 자기차량손해 담보로 보험금을 지급받고자 하는 
   경우에는 자기차량손해 담보에서 정한 자기부담금을 피보험자가 확정적으로 부담하는 조건으로 자기차량손
   해 보험금을 먼저 지급하여 드리며, 자기부담금을 부담한 피보험자는 상대방 또는 상대방이 가입한 보험회사
   에게 이 금액을 청구할 수 없습니다. 이 경우 자기차량손해 보험금을 지급한 보험회사는 지급한 보험금 범위
   에서 상대방 또는 상대방이 가입한 보험회사에 대하여 가지는 피보험자의 권리를 취득합니다. 다만, 상대방 
   손해배상책임액이 보험회사가 구상한 금액보다 큰 경우에 피보험자는 상대방 또는 상대방이 가입한 보험회사
   에 그 차액을 청구할 수 있습니다.
 5. 자기차량손해 보험금을 지급한 보험회사가 상대방 또는 상대방이 가입한 보험회사로부터 구상금을 받은 경우 
   (1) 피보험자가 이미 부담한 자기부담금과 (2) 실제 손해액에서 당해 구상금을 제외한 금액을 전제로 산정된 
   자기부담금과의 차액을 피보험자에게 지급하여 드립니다. (이 경우에도 피보험자가 최종적으로 부담하는 자
   기부담금은 최소 자기부담금 이상으로 합니다.)
② 보험회사는 피보험자동차에 생긴 손해에 대하여 보험회사가 필요하다고 인정하는 경우에는, 피보험자의 동의
  를 받아 수리하거나 대용품을 주는 것으로 보험금 지급을 대신할 수 있습니다. 
③  보험회사가 보상한 손해가 전부손해이거나 보험회사가 보상한 금액이 보험가입금액 전액 이상인 경우에는 자
  기차량손해의 보험계약은 사고 발생 시에 종료됩니다. 
④  보험회사가 피보험자동차의 전부손해에 대하여 보험금 전액을 지급한 경우에는 피해물을 인수합니다. 이 경우 
  보험가입금액이 보험가액보다 적을 때에는 보험가입금액의 보험가액에 대한 비율에 따라 피해물을 인수합니
  다. 그러나, 보험회사가 피해물을 인수하지 않는다는 뜻을 표시하고 보험금을 지급하는 경우에는 피해물에 대한 
  피보험자의 권리가 보험회사에 이전되지 않습니다.
(*1) ‘부분품’이란 보통약관 제1조(용어의 정의) 제6호의 가목의 엔진, 변속기(트랜스미션) 등 자동차가 공장에서 
   출고될 때 원형 그대로 부착되어 자동차의 조성부분이 되는 재료를 말합니다.
   다만, 피보험자가 원하는 경우 「자동차관리법」 제30조의5에 따른 품질인증부품을 사용할 수 있으며, 피보험자
   동차의 단독사고(가해자불명사고 포함) 또는 일방과실사고로 보통약관 「자기차량손해」 또는 「차량단독사고 보
   장 특별약관」에 따라서 보험금이 지급되는 경우 「품질인증부품 사용 특별약관」에 따라 수리비의 일정액을 피보
   험자에게 지급하여 드립니다.
(*2) ‘중요한 부분’이란 엔진, 미션, 캐빈, 적재함, 바디 및 전기차(하이브리드 자동차 포함)의 모터, 감속기, 구동용 
   배터리 등 중요한 부분품을 말합니다.
(*3) ‘전부손해’란 피보험자동차가 완전히 파손, 멸실 또는 오손되어 수리할 수 없는 상태이거나, 피보험자동차에 
   생긴 손해액과 보험회사가 부담하기로 한 비용의 합산액이 보험가액 이상인 경우를 말합니다.
  가. 임대차계약(계약기간이 30일을 초과하는 경우에 한함)에 따라 임차인이 피보험자동차를 전속적으로 사용
    하는 경우 (다만, 임차인이 피보험자동차를 영리를 목적으로 요금이나 대가를 받고 반복적으로 사용하는 경
    우에는 보상하지 않습니다.)
  나. 피보험자와 동승자가 「여객자동차운수사업법」에 따른 토요일, 일요일 및 공휴일을 제외한 날의 출䞱퇴근 시
    간대(오전 7시부터 오전 9시까지 및 오후 6시부터 오후 8시까지를 말합니다.)에 실제의 출䞱퇴근 용도로 자
    택과 직장 사이를 이동하면서 승용차 함께 타기를 실시한 경우
 6.  사기 또는 횡령으로 인한 손해
 7.  국가나 공공단체의 공권력 행사에 의한 압류, 징발, 몰수, 파괴 등으로 인한 손해. 그러나 소방이나 피난에 필
   요한 조치로 손해가 발생한 경우에는 그 손해를 보상합니다.
 8.  피보험자동차에 생긴 흠, 마멸, 부식, 녹, 그 밖에 자연소모로 인한 손해
 9.  피보험자동차의 일부 부분품, 부속품, 부속기계장치만의 도난으로 인한 손해
 10.  동파로 인한 손해 또는 우연한 외래의 사고에 직접 관련이 없는 전기적, 기계적 손해
 11.  피보험자동차를 시험용, 경기용 또는 경기를 위해 연습용으로 사용하던 중 생긴 손해. 다만, 운전면허시험을 
   위한 도로주행시험용으로 사용하던 중 생긴 손해는 보상합니다.
 12.  피보험자동차를 운송하거나 싣', 'PAYMENT') ON CONFLICT DO NOTHING;
INSERT INTO source_references (id, coverage_id, document_id, page_number, article_no, source_text, reference_type) VALUES (4, 2, 2, 4, NULL, '암주요치료비Ⅱ(유사암제외)(연 간1회한)(10년지급대상) 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에 약관에서정한암 (유사암제외)으로최초진단확정되고"보험금 지급대상기간"(암(유사암제외) 최초진단확 정일로부터10년) 이내에암(유사암제외)으로 암주요치료(암수술, 항암방사선치료, 항암약 물치료)를받은경우 연간1회에한하여보험가입 금액을지급함(즉, 최대10 회지급) ※ 세부내용은약관참고 ', 'SUMMARY_CANDIDATE') ON CONFLICT DO NOTHING;
INSERT INTO source_references (id, coverage_id, document_id, page_number, article_no, source_text, reference_type) VALUES (5, 3, 2, 4, NULL, '암(유사암제외) 치료비지원 피보험자가 보장개시일(계약일로부터 90일이 지난날의다음날) 이후에암(유사암제외)으로 진단확정시 가입금액지급 (최초1회에한함. 기타피부 암, 갑상선암, 제자리암, 경 계성종양은보장하지않음) ', 'SUMMARY_CANDIDATE') ON CONFLICT DO NOTHING;
INSERT INTO source_references (id, coverage_id, document_id, page_number, article_no, source_text, reference_type) VALUES (6, 2, 3, 10, NULL, '- 10 -
【별첨1】가입 내용에 대한 계약자 확인서
1. 이상품의2종(암건강플랜(간편고지형))은“간편고지” 상품으로유병력자또는연령제한등일반심사보험에가입하기
어려운피보험자를대상으로합니다.
2. 이상품의2종(암건강플랜(간편고지형))은1종(암건강플랜(일반고지형))대비보험료가할증되어있습니다. 의사의건
강검진을받거나일반계약심사를할경우이보험보다저렴한1종(암건강플랜(일반고지형))에가입할수있습니다.
3. 다만, 일반가입자보험의경우건강상태나가입나이에따라가입이제한될수있으며보장하는담보에는차이가있을
수있습니다.
4. 회사는계약자가간편고지형의최초계약의계약일부터3개월이내에일반고지형의가입을희망하는경우,
일반계약심사를통하여일반고지형을청약할수있는기회를제공합니다.
회사의승낙으로일반고지형에가입하는경우, 본계약은무효로하며이미납입한보험료를보험계약자에게돌려드립
니다.
다만, 본계약의보험금이지급되거나청구서류를접수한경우에는일반고지형으로가입할수없습니다.
※ 1종(일반고지형), 2종(간편고지형) 보험료비교(예시)
구 분
2종(암건강플랜(간편고지형))
1종(암건강플랜(일반고지형))
보
장
내
용
- (3.3.5간편고지)상해사망 1천만원
 : 피보험자가 보험기간 중 상해사고로 사망한 경우 보험가입금액 
지급
-(3.3.5간편고지)암주요치료비Ⅱ(유사암제외)(연간1회
한)(10년지급대상) 5백만원
 : 암(유사암제외)으로 진단확정되고 진단확정일로부터 10년 이내
에 암주요치료(암수술, 항암방사선치료, 항암약물치료)를 받은 경
우 연간 1회에 한하여 보험가입금액 지급
- (3.3.5간편고지)기타피부암 및 갑상선암주요치료비Ⅱ(연
간1회한)(10년지급대상) 1백만원
 : 기타피부암 또는 갑상선암으로 진단확정되고 진단확정일로부터 
10년 이내에 기타피부암 또는 갑상선암으로 암주요치료(암수술, 
항암방사선치료, 항암약물치료)를 받은 경우 연간 1회에 한하여 
보험가입금액 지급
- (3.3.5간편고지)암(유사암제외) 치료비지원 10만원
 : 암(유사암제외)으로 진단확정된 경우 보험가입금액 지급(기타피
부암, 갑상선암, 제자리암, 경계성종양은 보상하지 않음)
- (3.3.5간편고지)기타피부암 및 갑상선암 치료비지원 10
만원
 : 기타피부암 및 갑상선암으로 진단확정된 경우 보험가입금액 지
급
-(3.3.5간편고지)순환계질환(3-5종)주요치료비(요양병원제
외)(연간1회한)(10년지급대상) 5백만원
 : “순환계질환(3-5종)”으로 진단확정되고 진단확정일로부터 10년 
이내에 요양병원을 제외한 병원 또는 의원에서 “순환계질환(3-5
종)”의 직접적인 치료를 목적으로 순환계질환 주요치료(수술, 혈전
용해치료, 종합병원 중환자실치료, 특정급여치료)를 받은 경우 연
간 1회에 한하여  보험가입금액 지급(1년이내 50%지급)
- 상해사망 1천만원
 : 피보험자가 보험기간 중 상해사고로 사망한 경우 보험가입금액 지급
- 암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상) 5백
만원
 : 암(유사암제외)으로 진단확정되고 진단확정일로부터 10년 이내에 암
주요치료(암수술, 항암방사선치료, 항암약물치료)를 받은 경우 연간 1회
에 한하여 보험가입금액 지급
- 기타피부암 및 갑상선암주요치료비Ⅱ(연간1회한)(10년지급
대상) 1백만원
 : 기타피부암 또는 갑상선암으로 진단확정되고 진단확정일로부터 10년 
이내에 기타피부암 또는 갑상선암으로 암주요치료(암수술, 항암방사선
치료, 항암약물치료)를 받은 경우 연간 1회에 한하여 보험가입금액 지
급
- 암(유사암제외) 치료비지원 10만원
 : 암(유사암제외)으로 진단확정된 경우 보험가입금액 지급(기타피부암, 
갑상선암, 제자리암, 경계성종양은 보상하지 않음)
- 기타피부암 및 갑상선암 치료비지원 10만원
 : 기타피부암 및 갑상선암으로 진단확정된 경우 보험가입금액 지급
-순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년
지급대상) 5백만원
 : “순환계질환(3-5종)”으로 진단확정되고 진단확정일로부터 10년 이
내에 요양병원을 제외한 병원 또는 의원에서 “순환계질환(3-5종)”의 직
접적인 치료를 목적으로 순환계질환 주요치료(수술, 혈전용해치료, 종합
병원 중환자실치료, 특정급여치료)를 받은 경우 연간 1회에 한하여  보
험가입금액 지급(1년이내 50%지급)
', 'BUSINESS_METHOD_SUPPORT') ON CONFLICT DO NOTHING;
INSERT INTO source_references (id, coverage_id, document_id, page_number, article_no, source_text, reference_type) VALUES (7, 3, 3, 10, NULL, '- 10 -
【별첨1】가입 내용에 대한 계약자 확인서
1. 이상품의2종(암건강플랜(간편고지형))은“간편고지” 상품으로유병력자또는연령제한등일반심사보험에가입하기
어려운피보험자를대상으로합니다.
2. 이상품의2종(암건강플랜(간편고지형))은1종(암건강플랜(일반고지형))대비보험료가할증되어있습니다. 의사의건
강검진을받거나일반계약심사를할경우이보험보다저렴한1종(암건강플랜(일반고지형))에가입할수있습니다.
3. 다만, 일반가입자보험의경우건강상태나가입나이에따라가입이제한될수있으며보장하는담보에는차이가있을
수있습니다.
4. 회사는계약자가간편고지형의최초계약의계약일부터3개월이내에일반고지형의가입을희망하는경우,
일반계약심사를통하여일반고지형을청약할수있는기회를제공합니다.
회사의승낙으로일반고지형에가입하는경우, 본계약은무효로하며이미납입한보험료를보험계약자에게돌려드립
니다.
다만, 본계약의보험금이지급되거나청구서류를접수한경우에는일반고지형으로가입할수없습니다.
※ 1종(일반고지형), 2종(간편고지형) 보험료비교(예시)
구 분
2종(암건강플랜(간편고지형))
1종(암건강플랜(일반고지형))
보
장
내
용
- (3.3.5간편고지)상해사망 1천만원
 : 피보험자가 보험기간 중 상해사고로 사망한 경우 보험가입금액 
지급
-(3.3.5간편고지)암주요치료비Ⅱ(유사암제외)(연간1회
한)(10년지급대상) 5백만원
 : 암(유사암제외)으로 진단확정되고 진단확정일로부터 10년 이내
에 암주요치료(암수술, 항암방사선치료, 항암약물치료)를 받은 경
우 연간 1회에 한하여 보험가입금액 지급
- (3.3.5간편고지)기타피부암 및 갑상선암주요치료비Ⅱ(연
간1회한)(10년지급대상) 1백만원
 : 기타피부암 또는 갑상선암으로 진단확정되고 진단확정일로부터 
10년 이내에 기타피부암 또는 갑상선암으로 암주요치료(암수술, 
항암방사선치료, 항암약물치료)를 받은 경우 연간 1회에 한하여 
보험가입금액 지급
- (3.3.5간편고지)암(유사암제외) 치료비지원 10만원
 : 암(유사암제외)으로 진단확정된 경우 보험가입금액 지급(기타피
부암, 갑상선암, 제자리암, 경계성종양은 보상하지 않음)
- (3.3.5간편고지)기타피부암 및 갑상선암 치료비지원 10
만원
 : 기타피부암 및 갑상선암으로 진단확정된 경우 보험가입금액 지
급
-(3.3.5간편고지)순환계질환(3-5종)주요치료비(요양병원제
외)(연간1회한)(10년지급대상) 5백만원
 : “순환계질환(3-5종)”으로 진단확정되고 진단확정일로부터 10년 
이내에 요양병원을 제외한 병원 또는 의원에서 “순환계질환(3-5
종)”의 직접적인 치료를 목적으로 순환계질환 주요치료(수술, 혈전
용해치료, 종합병원 중환자실치료, 특정급여치료)를 받은 경우 연
간 1회에 한하여  보험가입금액 지급(1년이내 50%지급)
- 상해사망 1천만원
 : 피보험자가 보험기간 중 상해사고로 사망한 경우 보험가입금액 지급
- 암주요치료비Ⅱ(유사암제외)(연간1회한)(10년지급대상) 5백
만원
 : 암(유사암제외)으로 진단확정되고 진단확정일로부터 10년 이내에 암
주요치료(암수술, 항암방사선치료, 항암약물치료)를 받은 경우 연간 1회
에 한하여 보험가입금액 지급
- 기타피부암 및 갑상선암주요치료비Ⅱ(연간1회한)(10년지급
대상) 1백만원
 : 기타피부암 또는 갑상선암으로 진단확정되고 진단확정일로부터 10년 
이내에 기타피부암 또는 갑상선암으로 암주요치료(암수술, 항암방사선
치료, 항암약물치료)를 받은 경우 연간 1회에 한하여 보험가입금액 지
급
- 암(유사암제외) 치료비지원 10만원
 : 암(유사암제외)으로 진단확정된 경우 보험가입금액 지급(기타피부암, 
갑상선암, 제자리암, 경계성종양은 보상하지 않음)
- 기타피부암 및 갑상선암 치료비지원 10만원
 : 기타피부암 및 갑상선암으로 진단확정된 경우 보험가입금액 지급
-순환계질환(3-5종)주요치료비(요양병원제외)(연간1회한)(10년
지급대상) 5백만원
 : “순환계질환(3-5종)”으로 진단확정되고 진단확정일로부터 10년 이
내에 요양병원을 제외한 병원 또는 의원에서 “순환계질환(3-5종)”의 직
접적인 치료를 목적으로 순환계질환 주요치료(수술, 혈전용해치료, 종합
병원 중환자실치료, 특정급여치료)를 받은 경우 연간 1회에 한하여  보
험가입금액 지급(1년이내 50%지급)
', 'BUSINESS_METHOD_SUPPORT') ON CONFLICT DO NOTHING;
INSERT INTO validation_logs (id, entity_type, entity_id, rule_code, status, message, created_at) VALUES (1, 'coverage', 2, 'POLICY_SOURCE_REQUIRED', 'REVIEW', '상품요약서 기반 후보 Rule. 보험약관 본문/별표 검증 전 지급판정에 사용 금지', now()) ON CONFLICT DO NOTHING;
INSERT INTO validation_logs (id, entity_type, entity_id, rule_code, status, message, created_at) VALUES (2, 'coverage', 3, 'POLICY_SOURCE_REQUIRED', 'REVIEW', '상품요약서 기반 후보 Rule. 보험약관 본문/별표 검증 전 지급판정에 사용 금지', now()) ON CONFLICT DO NOTHING;
INSERT INTO validation_logs (id, entity_type, entity_id, rule_code, status, message, created_at) VALUES (3, 'coverage', 2, 'OFFICIAL_SUPPORTING_DOC_CROSSCHECK', 'PASS', '사업방법서와 상품요약서 교차확인: PAYMENT_RATE, TREATMENT_SET, ANNUAL_FREQUENCY', now()) ON CONFLICT DO NOTHING;
INSERT INTO validation_logs (id, entity_type, entity_id, rule_code, status, message, created_at) VALUES (4, 'coverage', 2, 'CANCER_90_DAY_PRODUCT_CONTEXT', 'SUPPORTING_ONLY', '사업방법서에서 암 관련 90일 보장개시 문언을 확인했으나 해당 담보의 보험약관 조항 검증 전에는 담보별 실행조건으로 승격하지 않음', now()) ON CONFLICT DO NOTHING;
INSERT INTO validation_logs (id, entity_type, entity_id, rule_code, status, message, created_at) VALUES (5, 'coverage', 2, 'VERIFIED_POLICY_REQUIRED', 'BLOCK', '보험약관 원문 및 관련 별표(KCD) 미확보: 지급판정/보험금 계산 실행 금지', now()) ON CONFLICT DO NOTHING;
INSERT INTO validation_logs (id, entity_type, entity_id, rule_code, status, message, created_at) VALUES (6, 'coverage', 3, 'OFFICIAL_SUPPORTING_DOC_CROSSCHECK', 'PASS', '사업방법서와 상품요약서 교차확인: PAYMENT_RATE, EXCLUDED_DISEASE_TERMS', now()) ON CONFLICT DO NOTHING;
INSERT INTO validation_logs (id, entity_type, entity_id, rule_code, status, message, created_at) VALUES (7, 'coverage', 3, 'CANCER_90_DAY_PRODUCT_CONTEXT', 'SUPPORTING_ONLY', '사업방법서에서 암 관련 90일 보장개시 문언을 확인했으나 해당 담보의 보험약관 조항 검증 전에는 담보별 실행조건으로 승격하지 않음', now()) ON CONFLICT DO NOTHING;
INSERT INTO validation_logs (id, entity_type, entity_id, rule_code, status, message, created_at) VALUES (8, 'coverage', 3, 'VERIFIED_POLICY_REQUIRED', 'BLOCK', '보험약관 원문 및 관련 별표(KCD) 미확보: 지급판정/보험금 계산 실행 금지', now()) ON CONFLICT DO NOTHING;
SELECT setval(pg_get_serial_sequence('insurance_companies','id'), COALESCE((SELECT MAX(id) FROM insurance_companies), 1), true);
SELECT setval(pg_get_serial_sequence('insurance_products','id'), COALESCE((SELECT MAX(id) FROM insurance_products), 1), true);
SELECT setval(pg_get_serial_sequence('product_versions','id'), COALESCE((SELECT MAX(id) FROM product_versions), 1), true);
SELECT setval(pg_get_serial_sequence('policy_documents','id'), COALESCE((SELECT MAX(id) FROM policy_documents), 1), true);
SELECT setval(pg_get_serial_sequence('policy_pages','id'), COALESCE((SELECT MAX(id) FROM policy_pages), 1), true);
SELECT setval(pg_get_serial_sequence('policy_articles','id'), COALESCE((SELECT MAX(id) FROM policy_articles), 1), true);
SELECT setval(pg_get_serial_sequence('coverages','id'), COALESCE((SELECT MAX(id) FROM coverages), 1), true);
SELECT setval(pg_get_serial_sequence('coverage_conditions','id'), COALESCE((SELECT MAX(id) FROM coverage_conditions), 1), true);
SELECT setval(pg_get_serial_sequence('payment_rules','id'), COALESCE((SELECT MAX(id) FROM payment_rules), 1), true);
SELECT setval(pg_get_serial_sequence('coverage_limits','id'), COALESCE((SELECT MAX(id) FROM coverage_limits), 1), true);
SELECT setval(pg_get_serial_sequence('exclusions','id'), COALESCE((SELECT MAX(id) FROM exclusions), 1), true);
SELECT setval(pg_get_serial_sequence('disease_codes','id'), COALESCE((SELECT MAX(id) FROM disease_codes), 1), true);
SELECT setval(pg_get_serial_sequence('source_references','id'), COALESCE((SELECT MAX(id) FROM source_references), 1), true);
SELECT setval(pg_get_serial_sequence('validation_logs','id'), COALESCE((SELECT MAX(id) FROM validation_logs), 1), true);
COMMIT;
