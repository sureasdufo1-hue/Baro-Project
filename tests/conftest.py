from collections.abc import Generator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from apps.api.app.main import app
from domain.assessment.models import AssessmentRuleResult, CoverageAssessment  # noqa: F401
from domain.audit.models import AuditLog  # noqa: F401
from domain.calculation.models import BenefitCalculation  # noqa: F401
from domain.claim.models import Accident, Claim  # noqa: F401
from domain.contract.models import ContractCoverage, InsuranceContract, Insured  # noqa: F401
from domain.document.models import MedicalDocument  # noqa: F401
from domain.evidence.models import Evidence  # noqa: F401
from domain.fact.models import ExtractedFact, OCRResult, VerifiedFact  # noqa: F401
from domain.policy.models import Coverage, InsuranceCompany  # noqa: F401
from domain.review.models import AdditionalDocumentRequest, Review, ReviewAssignment  # noqa: F401
from domain.rule.models import BenefitRule, RuleVersion  # noqa: F401
from domain.user.models import Consent, User  # noqa: F401
from infrastructure.database.base import Base
from infrastructure.database.session import get_db


@pytest.fixture
def db_session(tmp_path: Path) -> Generator[Session, None, None]:
    engine = create_engine(
        f"sqlite:///{tmp_path / 'test.db'}", connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)
    with factory() as session:
        yield session
    Base.metadata.drop_all(engine)


@pytest.fixture
def client(db_session: Session) -> Generator[TestClient, None, None]:
    def override_db() -> Generator[Session, None, None]:
        yield db_session

    app.dependency_overrides[get_db] = override_db
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()


@pytest.fixture
def registration_payload() -> dict[str, object]:
    return {
        "email": "user@example.com",
        "password": "correct-horse-battery-staple",
        "display_name": "Test User",
        "consents": [
            {"consent_type": "SERVICE_TERMS", "consent_version": "1.0", "agreed": True},
            {"consent_type": "PRIVACY", "consent_version": "1.0", "agreed": True},
        ],
    }
