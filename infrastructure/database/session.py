from collections.abc import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from apps.api.app.config import get_settings


def create_session_factory(database_url: str | None = None) -> sessionmaker[Session]:
    url = database_url or get_settings().database_url
    connect_args = {"check_same_thread": False} if url.startswith("sqlite") else {}
    engine = create_engine(url, pool_pre_ping=True, connect_args=connect_args)
    return sessionmaker(bind=engine, expire_on_commit=False)


SessionLocal = create_session_factory()


def get_db() -> Generator[Session, None, None]:
    with SessionLocal() as session:
        yield session
