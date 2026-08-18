from collections.abc import Generator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from apps.api.app.main import app
from domain.audit.models import AuditLog  # noqa: F401
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
