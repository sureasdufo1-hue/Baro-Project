import sqlite3
from datetime import UTC, datetime
from pathlib import Path

import pytest
from alembic import command
from sqlalchemy import create_engine, text

from scripts import db_baseline


def database_url(path: Path) -> str:
    return f"sqlite:///{path.as_posix()}"


def test_sqlite_backup_is_consistent_and_preserves_source(tmp_path: Path) -> None:
    source = tmp_path / "claimlens-dev.db"
    with sqlite3.connect(source) as connection:
        connection.execute("CREATE TABLE preserved (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
        connection.execute("INSERT INTO preserved(value) VALUES ('before')")
    original = source.read_bytes()

    backup = db_baseline.backup_sqlite(
        source,
        tmp_path / "backups",
        "d12044c5a901",
        datetime(2026, 8, 19, 0, 0, tzinfo=UTC),
    )

    assert source.read_bytes() == original
    assert backup.name == "claimlens-dev.before-d12044c5a901.20260819T000000Z.db"
    with sqlite3.connect(backup) as connection:
        assert connection.execute("SELECT value FROM preserved").fetchone() == ("before",)
    assert db_baseline.sqlite_data_snapshot(source) == db_baseline.sqlite_data_snapshot(backup)


def test_backup_failure_is_explicit_and_stops_upgrade(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = tmp_path / "legacy.db"
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE alembic_version (version_num VARCHAR(32) NOT NULL)")
        connection.execute("INSERT INTO alembic_version VALUES ('c91e7a42d4f0')")
    called = False

    def fail_backup(*_: object, **__: object) -> Path:
        raise db_baseline.DatabaseBaselineError("fixture backup failure")

    def record_upgrade(*_: object, **__: object) -> None:
        nonlocal called
        called = True

    monkeypatch.setattr(db_baseline, "backup_sqlite", fail_backup)
    monkeypatch.setattr("scripts.db_baseline.command.upgrade", record_upgrade)

    with pytest.raises(db_baseline.DatabaseBaselineError, match="fixture backup failure"):
        db_baseline.upgrade_with_backup(database_url(database), tmp_path / "backups")
    assert called is False


def test_empty_sqlite_database_upgrades_to_head_with_matching_schema(tmp_path: Path) -> None:
    database = tmp_path / "empty-to-head.db"
    url = database_url(database)
    command.upgrade(db_baseline.alembic_config(url), "head")

    status = db_baseline.database_status(url)

    assert status["current_revision"] == "f80c2e1a9b77"
    assert status["migration_pending"] is False
    assert status["schema_issues"] == []


def test_existing_revision_upgrades_to_head_without_data_loss(tmp_path: Path) -> None:
    database = tmp_path / "existing-to-head.db"
    url = database_url(database)
    command.upgrade(db_baseline.alembic_config(url), "c91e7a42d4f0")
    with create_engine(url).begin() as connection:
        connection.execute(
            text(
                """INSERT INTO users
                (user_id,email,password_hash,display_name,role,status,mfa_enabled,created_at,updated_at)
                VALUES
                (:id,'preserved@example.com','hash','Preserved','USER','ACTIVE',0,:now,:now)"""
            ),
            {"id": "00000000000000000000000000000001", "now": "2026-08-19 00:00:00"},
        )

    command.upgrade(db_baseline.alembic_config(url), "head")

    with create_engine(url).connect() as connection:
        assert (
            connection.execute(
                text("SELECT email FROM users WHERE email='preserved@example.com'")
            ).scalar_one()
            == "preserved@example.com"
        )
    assert db_baseline.database_status(url)["schema_issues"] == []


def test_head_downgrade_one_revision_and_reupgrade_is_stable(tmp_path: Path) -> None:
    database = tmp_path / "lifecycle.db"
    url = database_url(database)
    config = db_baseline.alembic_config(url)
    command.upgrade(config, "head")
    command.downgrade(config, "-1")
    assert db_baseline.revisions(url)[0] == "f31a57b42c10"
    command.upgrade(config, "head")
    assert db_baseline.revisions(url)[0] == "f80c2e1a9b77"
