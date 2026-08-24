CREATE TABLE IF NOT EXISTS policy_verification_reviews (
  coverage_id INTEGER NOT NULL REFERENCES coverages(id) ON DELETE CASCADE,
  check_code VARCHAR(80) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  reviewer_id VARCHAR(100),
  reason TEXT,
  reviewed_at TIMESTAMP,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY(coverage_id, check_code),
  CHECK(status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE INDEX IF NOT EXISTS idx_policy_verification_coverage
  ON policy_verification_reviews(coverage_id);
