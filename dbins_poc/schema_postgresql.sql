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
