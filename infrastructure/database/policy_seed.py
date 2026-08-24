from __future__ import annotations

from collections.abc import Generator
from datetime import date
from decimal import Decimal
from typing import Any

from sqlalchemy import Engine, create_engine, text
from sqlalchemy.engine import Connection

from apps.api.app.config import get_settings


def create_policy_engine(url: str | None = None) -> Engine:
    database_url = url or get_settings().policy_database_url
    connect_args = {"check_same_thread": False} if database_url.startswith("sqlite") else {}
    return create_engine(database_url, pool_pre_ping=True, connect_args=connect_args)


PolicyEngine = create_policy_engine()


def get_policy_connection() -> Generator[Connection, None, None]:
    with PolicyEngine.connect() as connection:
        yield connection


class PolicySeedRepository:
    """Read-only access to the independently versioned DB Insurance seed database."""

    REQUIRED_TABLES = (
        "insurance_companies",
        "insurance_products",
        "product_versions",
        "policy_documents",
        "policy_pages",
        "policy_articles",
        "coverages",
        "coverage_conditions",
        "payment_rules",
        "coverage_limits",
        "source_references",
        "validation_logs",
    )
    VERIFICATION_CHECKS = (
        "PRODUCT_CODE_MAPPING",
        "POLICY_COVERAGE",
        "PAYMENT_RULE",
        "EXCLUSIONS_LIMITS",
        "DISEASE_DEFINITION",
        "KCD_APPENDIX",
        "SOURCE_REFERENCES",
    )

    def __init__(self, connection: Connection):
        self.connection = connection

    def _all(self, query: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        return [dict(row) for row in self.connection.execute(text(query), params or {}).mappings()]

    def _one(self, query: str, params: dict[str, Any]) -> dict[str, Any] | None:
        row = self.connection.execute(text(query), params).mappings().first()
        return dict(row) if row else None

    def health(self) -> dict[str, Any]:
        dialect = self.connection.engine.dialect.name
        missing = []
        for table in self.REQUIRED_TABLES:
            try:
                self.connection.execute(text(f"SELECT 1 FROM {table} LIMIT 1"))
            except Exception:
                missing.append(table)
        count = (
            self.connection.execute(text("SELECT COUNT(*) FROM insurance_products")).scalar_one()
            if not missing
            else 0
        )
        return {
            "database": dialect,
            "connected": True,
            "schema": "ok" if not missing else "missing",
            "seed_loaded": count > 0,
            "missing_tables": missing,
        }

    def companies(self) -> list[dict[str, Any]]:
        return self._all(
            """SELECT id, canonical_name, company_type, official_domain
            FROM insurance_companies ORDER BY id"""
        )

    def products(self, company_id: int | None = None) -> list[dict[str, Any]]:
        where = " WHERE p.company_id=:company_id" if company_id else ""
        return self._all(
            """SELECT p.*, c.canonical_name AS company_name
            FROM insurance_products p
            JOIN insurance_companies c ON c.id=p.company_id"""
            + where
            + " ORDER BY p.id",
            {"company_id": company_id},
        )

    def product(self, product_id: int) -> dict[str, Any] | None:
        return self._one(
            """SELECT p.*, c.canonical_name AS company_name
            FROM insurance_products p
            JOIN insurance_companies c ON c.id=p.company_id
            WHERE p.id=:id""",
            {"id": product_id},
        )

    def versions(self, product_id: int) -> list[dict[str, Any]]:
        return self._all(
            "SELECT * FROM product_versions WHERE product_id=:id ORDER BY effective_from",
            {"id": product_id},
        )

    def version(self, version_id: int) -> dict[str, Any] | None:
        return self._one(
            """SELECT v.*, p.raw_product_name, p.product_code
            FROM product_versions v
            JOIN insurance_products p ON p.id=v.product_id
            WHERE v.id=:id""",
            {"id": version_id},
        )

    def documents(self, version_id: int) -> list[dict[str, Any]]:
        return self._all(
            """SELECT id, version_id, document_type, file_name, local_path, source_url,
            sha256, page_count, text_layer, source_type FROM policy_documents
            WHERE version_id=:id ORDER BY id""",
            {"id": version_id},
        )

    def coverages(self, version_id: int | None = None) -> list[dict[str, Any]]:
        where = " WHERE c.version_id=:id" if version_id else ""
        return self._all(
            """SELECT c.*, p.product_code, p.raw_product_name, v.version_name
            FROM coverages c JOIN product_versions v ON v.id=c.version_id
            JOIN insurance_products p ON p.id=v.product_id"""
            + where
            + " ORDER BY c.id",
            {"id": version_id},
        )

    def coverage(self, coverage_id: int) -> dict[str, Any] | None:
        rows = self.coverages()
        return next((x for x in rows if x["id"] == coverage_id), None)

    def rule(self, coverage_id: int) -> dict[str, Any] | None:
        coverage = self.coverage(coverage_id)
        if not coverage:
            return None
        coverage["conditions"] = self._all(
            "SELECT * FROM coverage_conditions WHERE coverage_id=:id ORDER BY id",
            {"id": coverage_id},
        )
        coverage["payment_rules"] = self._all(
            "SELECT * FROM payment_rules WHERE coverage_id=:id ORDER BY id", {"id": coverage_id}
        )
        coverage["limits"] = self._all(
            "SELECT * FROM coverage_limits WHERE coverage_id=:id ORDER BY id", {"id": coverage_id}
        )
        coverage["disease_codes"] = self._all(
            "SELECT * FROM disease_codes WHERE coverage_id=:id ORDER BY id", {"id": coverage_id}
        )
        coverage["validations"] = self._all(
            """SELECT rule_code, status, message FROM validation_logs
            WHERE entity_type='coverage' AND entity_id=:id ORDER BY id""",
            {"id": coverage_id},
        )
        coverage["promotion_gate"] = self.promotion_gate(coverage_id)
        return coverage

    def evidence(self, coverage_id: int) -> list[dict[str, Any]]:
        return self._all(
            """SELECT sr.id,pd.document_type,pd.file_name,sr.page_number AS page,
          sr.article_no,pa.title AS article_title,sr.source_text,pd.source_url,pd.local_path
          FROM source_references sr JOIN policy_documents pd ON pd.id=sr.document_id
          LEFT JOIN policy_articles pa ON pa.document_id=sr.document_id
            AND pa.article_no=sr.article_no
            AND pa.page_number=sr.page_number WHERE sr.coverage_id=:id ORDER BY sr.id""",
            {"id": coverage_id},
        )

    def resolve_version(self, product_id: int, contract_date: date) -> dict[str, Any]:
        versions = self.versions(product_id)

        def as_date(value: date | str | None) -> date | None:
            return date.fromisoformat(value) if isinstance(value, str) else value

        matches = []
        for version in versions:
            start, end = as_date(version["effective_from"]), as_date(version["effective_to"])
            if (start is None or start <= contract_date) and (end is None or contract_date <= end):
                matches.append(version)
        if len(matches) > 1:
            return {"status": "AMBIGUOUS", "version": None}
        if not matches:
            return {"status": "NOT_FOUND", "version": None}
        chosen = matches[0]
        if chosen["sale_status"] == "ARCHIVED" and chosen["effective_to"] is None:
            return {"status": "HUMAN_REVIEW_REQUIRED", "version": None}
        return {"status": "RESOLVED", "version": chosen}

    def promotion_gate(self, coverage_id: int) -> dict[str, Any] | None:
        coverage = self.coverage(coverage_id)
        if not coverage:
            return None
        evidence = self.evidence(coverage_id)
        reasons = []
        policy_evidence = [e for e in evidence if e["document_type"] == "POLICY"]
        if coverage["rule_status"] != "VERIFIED_POLICY":
            reasons.append("RULE_NOT_VERIFIED_POLICY")
        if not policy_evidence:
            reasons.append("POLICY_EVIDENCE_MISSING")
        if not coverage.get("payment_formula"):
            reasons.append("PAYMENT_RULE_MISSING")
        if coverage["coverage_type"] in {"DIAGNOSIS", "TREATMENT"}:
            verified = self.connection.execute(
                text(
                    """SELECT COUNT(*) FROM disease_codes WHERE coverage_id=:id
                    AND source_status IN ('VERIFIED_POLICY','VERIFIED_POLICY_APPENDIX')"""
                ),
                {"id": coverage_id},
            ).scalar_one()
            if not verified:
                reasons.append("KCD_OR_DISEASE_DEFINITION_NOT_VERIFIED")
        blocked = self.connection.execute(
            text(
                """SELECT COUNT(*) FROM validation_logs WHERE entity_type='coverage'
                AND entity_id=:id AND status='BLOCK'"""
            ),
            {"id": coverage_id},
        ).scalar_one()
        if blocked:
            reasons.append("VALIDATION_BLOCK_PRESENT")
        return {
            "status": "PASS" if not reasons else "FAIL",
            "executable": not reasons,
            "reasons": reasons,
        }

    def calculate(self, coverage_id: int, facts: dict[str, Any]) -> dict[str, Any]:
        coverage = self.coverage(coverage_id)
        if not coverage:
            return {"status": "COVERAGE_NOT_FOUND", "final_amount": None}
        gate = self.promotion_gate(coverage_id)
        if not gate or not gate["executable"]:
            return {
                "status": "HUMAN_REVIEW_REQUIRED",
                "reason": "INSUFFICIENT_EVIDENCE",
                "final_amount": None,
                "promotion_gate": gate,
            }
        if coverage["coverage_type"] != "AUTO_OWN_DAMAGE":
            return {
                "status": "HUMAN_REVIEW_REQUIRED",
                "reason": "UNSUPPORTED_VERIFIED_RULE",
                "final_amount": None,
                "promotion_gate": gate,
            }
        values = {
            k: Decimal(str(facts.get(k, 0)))
            for k in ("vehicle_damage", "expenses", "deductible", "insured_amount")
        }
        if any(v < 0 for v in values.values()):
            return {"status": "INVALID_INPUT", "final_amount": None}
        amount = max(
            Decimal(0), values["vehicle_damage"] + values["expenses"] - values["deductible"]
        )
        amount = min(amount, values["insured_amount"])
        return {
            "status": "PAYABLE",
            "final_amount": int(amount),
            "calculation": "min(vehicle_damage + expenses - deductible, insured_amount)",
            "coverage": coverage,
            "evidence": self.evidence(coverage_id),
        }

    def summary(self) -> dict[str, int]:
        def count(table: str, where: str = "") -> int:
            return int(
                self.connection.execute(text(f"SELECT COUNT(*) FROM {table} {where}")).scalar_one()
            )

        gates = [self.promotion_gate(c["id"]) for c in self.coverages()]
        return {
            "companies": count("insurance_companies"),
            "products": count("insurance_products"),
            "versions": count("product_versions"),
            "documents": count("policy_documents"),
            "coverages": count("coverages"),
            "verified_policy": count("coverages", "WHERE rule_status='VERIFIED_POLICY'"),
            "official_crosschecked": count(
                "coverages", "WHERE rule_status='OFFICIAL_CROSSCHECKED'"
            ),
            "human_review_required": sum(1 for gate in gates if gate and not gate["executable"]),
        }

    def verification_status(self, coverage_id: int) -> dict[str, Any] | None:
        coverage = self.coverage(coverage_id)
        if not coverage:
            return None
        checks = self._all(
            """SELECT check_code,status,reviewer_id,reason,reviewed_at,created_at
            FROM policy_verification_reviews WHERE coverage_id=:id ORDER BY check_code""",
            {"id": coverage_id},
        )
        by_code = {item["check_code"]: item for item in checks}
        normalized = [
            by_code.get(code, {"check_code": code, "status": "PENDING"})
            for code in self.VERIFICATION_CHECKS
        ]
        approved = all(item["status"] == "APPROVED" for item in normalized)
        return {
            "coverage_id": coverage_id,
            "rule_status": coverage["rule_status"],
            "checks": normalized,
            "all_approved": approved,
            "eligible_for_promotion": approved and coverage["rule_status"] != "VERIFIED_POLICY",
        }

    def verification_queue(self) -> list[dict[str, Any]]:
        queue = []
        for coverage in self.coverages():
            status = self.verification_status(coverage["id"])
            if not status or coverage["rule_status"] == "VERIFIED_POLICY":
                continue
            checks = status["checks"]
            queue.append(
                {
                    "coverage_id": coverage["id"],
                    "coverage_name": coverage["coverage_name"],
                    "coverage_type": coverage["coverage_type"],
                    "product_code": coverage["product_code"],
                    "product_name": coverage["raw_product_name"],
                    "version_name": coverage["version_name"],
                    "rule_status": coverage["rule_status"],
                    "approved": sum(item["status"] == "APPROVED" for item in checks),
                    "rejected": sum(item["status"] == "REJECTED" for item in checks),
                    "pending": sum(item["status"] == "PENDING" for item in checks),
                    "eligible_for_promotion": status["eligible_for_promotion"],
                }
            )
        return queue

    def verification_context(self, coverage_id: int) -> dict[str, Any] | None:
        coverage = self.coverage(coverage_id)
        if not coverage:
            return None
        return {
            "coverage": coverage,
            "rule": self.rule(coverage_id),
            "evidence": self.evidence(coverage_id),
            "verification": self.verification_status(coverage_id),
        }

    def initialize_verification(self, coverage_id: int) -> dict[str, Any] | None:
        if not self.coverage(coverage_id):
            return None
        for code in self.VERIFICATION_CHECKS:
            self.connection.execute(
                text(
                    """INSERT INTO policy_verification_reviews(coverage_id,check_code,status)
                    VALUES (:coverage_id,:check_code,'PENDING')
                    ON CONFLICT(coverage_id,check_code) DO NOTHING"""
                ),
                {"coverage_id": coverage_id, "check_code": code},
            )
        self.connection.commit()
        return self.verification_status(coverage_id)

    def review_check(
        self,
        coverage_id: int,
        check_code: str,
        status: str,
        reviewer_id: str,
        reason: str,
    ) -> dict[str, Any] | None:
        if check_code not in self.VERIFICATION_CHECKS or status not in {"APPROVED", "REJECTED"}:
            raise ValueError("Invalid verification check or status")
        if not reason.strip():
            raise ValueError("A review reason is required")
        self.initialize_verification(coverage_id)
        result = self.connection.execute(
            text(
                """UPDATE policy_verification_reviews SET status=:status,
                reviewer_id=:reviewer_id,reason=:reason,reviewed_at=CURRENT_TIMESTAMP
                WHERE coverage_id=:coverage_id AND check_code=:check_code"""
            ),
            {
                "status": status,
                "reviewer_id": reviewer_id,
                "reason": reason,
                "coverage_id": coverage_id,
                "check_code": check_code,
            },
        )
        self.connection.commit()
        if result.rowcount == 0:
            return None
        return self.verification_status(coverage_id)

    def promote_verified_policy(
        self, coverage_id: int, reviewer_id: str, reason: str
    ) -> dict[str, Any]:
        status = self.verification_status(coverage_id)
        if not status:
            raise ValueError("Coverage not found")
        if not status["all_approved"]:
            raise ValueError("All policy verification checks must be approved")
        if not reason.strip():
            raise ValueError("A promotion reason is required")
        evidence = self.evidence(coverage_id)
        if not any(item["document_type"] == "POLICY" for item in evidence):
            raise ValueError("POLICY evidence is required")
        self.connection.execute(
            text("UPDATE coverages SET rule_status='VERIFIED_POLICY' WHERE id=:id"),
            {"id": coverage_id},
        )
        self.connection.execute(
            text("UPDATE payment_rules SET human_verified=1 WHERE coverage_id=:id"),
            {"id": coverage_id},
        )
        self.connection.execute(
            text(
                """UPDATE disease_codes SET source_status='VERIFIED_POLICY_APPENDIX'
                WHERE coverage_id=:id AND source_status='POLICY_EXTRACTED_PENDING_REVIEW'"""
            ),
            {"id": coverage_id},
        )
        self.connection.execute(
            text(
                """UPDATE validation_logs SET status='RESOLVED'
                WHERE entity_type='coverage' AND entity_id=:id
                AND status='BLOCK' AND rule_code='VERIFIED_POLICY_REQUIRED'"""
            ),
            {"id": coverage_id},
        )
        self.connection.execute(
            text(
                """INSERT INTO validation_logs
                (entity_type,entity_id,rule_code,status,message)
                VALUES ('coverage',:id,'VERIFIED_POLICY_HUMAN_APPROVAL','PASS',:message)"""
            ),
            {"id": coverage_id, "message": f"reviewer={reviewer_id}; reason={reason}"},
        )
        self.connection.commit()
        return {
            "status": "VERIFIED_POLICY",
            "coverage_id": coverage_id,
            "promotion_gate": self.promotion_gate(coverage_id),
        }
