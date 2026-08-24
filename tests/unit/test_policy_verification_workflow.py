import shutil
import sqlite3
from pathlib import Path

import pytest
from sqlalchemy import create_engine

from infrastructure.database.policy_seed import PolicySeedRepository

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def repository(tmp_path: Path) -> PolicySeedRepository:
    database = tmp_path / "policy.db"
    shutil.copy2(ROOT / "dbins_poc" / "runtime" / "dbins_policy.sqlite3", database)
    with sqlite3.connect(database) as connection:
        connection.executescript(
            (ROOT / "dbins_poc" / "migrations" / "003_policy_verification_reviews.sql").read_text(
                encoding="utf-8"
            )
        )
    engine = create_engine(f"sqlite:///{database}")
    with engine.connect() as connection:
        yield PolicySeedRepository(connection)


def test_verification_workflow_starts_pending_and_fails_closed(
    repository: PolicySeedRepository,
) -> None:
    status = repository.initialize_verification(2)
    assert status is not None
    assert status["all_approved"] is False
    assert len(status["checks"]) == 7
    with pytest.raises(ValueError, match="must be approved"):
        repository.promote_verified_policy(2, "reviewer", "not ready")


def test_rejected_check_never_allows_promotion(repository: PolicySeedRepository) -> None:
    repository.initialize_verification(2)
    for code in repository.VERIFICATION_CHECKS:
        decision = "REJECTED" if code == "PRODUCT_CODE_MAPPING" else "APPROVED"
        repository.review_check(2, code, decision, "reviewer", "fixture review reason")
    status = repository.verification_status(2)
    assert status is not None and status["all_approved"] is False


def test_all_human_checks_promote_only_fixture_copy(repository: PolicySeedRepository) -> None:
    repository.initialize_verification(2)
    for code in repository.VERIFICATION_CHECKS:
        repository.review_check(2, code, "APPROVED", "reviewer", "fixture approval")
    promoted = repository.promote_verified_policy(2, "reviewer", "fixture final approval")
    assert promoted["status"] == "VERIFIED_POLICY"
    assert promoted["promotion_gate"]["status"] == "PASS"


def test_invalid_check_is_rejected(repository: PolicySeedRepository) -> None:
    with pytest.raises(ValueError, match="Invalid verification"):
        repository.review_check(2, "UNKNOWN", "APPROVED", "reviewer", "fixture reason")


def test_verification_queue_and_context_expose_review_evidence(
    repository: PolicySeedRepository,
) -> None:
    queue = repository.verification_queue()
    pending = next(item for item in queue if item["coverage_id"] == 2)
    assert pending["pending"] == 7
    assert pending["approved"] == 0
    assert pending["eligible_for_promotion"] is False

    context = repository.verification_context(2)
    assert context is not None
    assert context["verification"]["rule_status"] == "OFFICIAL_CROSSCHECKED"
    assert context["rule"]["payment_rules"]
    assert any(item["document_type"] == "POLICY" for item in context["evidence"])
