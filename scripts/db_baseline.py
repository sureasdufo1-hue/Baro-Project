from __future__ import annotations

# ruff: noqa: E402 -- direct script execution must add the repository root before local imports.
import argparse
import hashlib
import json
import sqlite3
import sys
import uuid
from collections.abc import Mapping, Sequence
from contextlib import closing
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from alembic import command
from alembic.config import Config
from alembic.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import DefaultClause, Engine, UniqueConstraint, create_engine, inspect
from sqlalchemy.engine import make_url

from infrastructure.database.base import Base


class DatabaseBaselineError(RuntimeError):
    pass


def load_models() -> None:
    from domain.assessment import models as assessment_models  # noqa: F401
    from domain.audit import models as audit_models  # noqa: F401
    from domain.calculation import models as calculation_models  # noqa: F401
    from domain.claim import models as claim_models  # noqa: F401
    from domain.contract import models as contract_models  # noqa: F401
    from domain.document import models as document_models  # noqa: F401
    from domain.evidence import models as evidence_models  # noqa: F401
    from domain.fact import models as fact_models  # noqa: F401
    from domain.policy import models as policy_models  # noqa: F401
    from domain.review import models as review_models  # noqa: F401
    from domain.rule import models as rule_models  # noqa: F401
    from domain.user import models as user_models  # noqa: F401


def alembic_config(database_url: str) -> Config:
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", database_url.replace("%", "%%"))
    config.attributes["database_url_override"] = database_url
    return config


def revisions(database_url: str) -> tuple[str | None, tuple[str, ...]]:
    engine = create_engine(database_url)
    try:
        with engine.connect() as connection:
            current = MigrationContext.configure(connection).get_current_revision()
    finally:
        engine.dispose()
    heads = tuple(ScriptDirectory.from_config(alembic_config(database_url)).get_heads())
    return current, heads


def sqlite_path(database_url: str, working_directory: Path | None = None) -> Path:
    url = make_url(database_url)
    if url.get_backend_name() != "sqlite" or not url.database or url.database == ":memory:":
        raise DatabaseBaselineError("A file-backed SQLite DATABASE_URL is required")
    path = Path(url.database)
    if not path.is_absolute():
        path = (working_directory or Path.cwd()) / path
    return path.resolve()


def backup_sqlite(
    source: Path,
    backup_directory: Path,
    revision: str | None,
    timestamp: datetime | None = None,
) -> Path:
    source = source.resolve()
    if not source.is_file():
        raise DatabaseBaselineError(f"Source database does not exist: {source}")
    stamp = (timestamp or datetime.now(UTC)).strftime("%Y%m%dT%H%M%SZ")
    revision_label = revision or "unversioned"
    try:
        backup_directory.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise DatabaseBaselineError(f"Backup directory is unavailable: {exc}") from exc
    destination = backup_directory / f"{source.stem}.before-{revision_label}.{stamp}.db"
    if destination.exists():
        raise DatabaseBaselineError(f"Backup already exists: {destination}")
    temporary = destination.with_suffix(f".tmp-{uuid.uuid4().hex}")
    try:
        with closing(sqlite3.connect(f"file:{source.as_posix()}?mode=ro", uri=True)) as original:
            with closing(sqlite3.connect(temporary)) as backup:
                original.backup(backup)
                result = backup.execute("PRAGMA integrity_check").fetchone()
                if result is None or result[0] != "ok":
                    raise DatabaseBaselineError("Backup integrity check failed")
        temporary.replace(destination)
    except Exception as exc:
        temporary.unlink(missing_ok=True)
        if isinstance(exc, DatabaseBaselineError):
            raise
        raise DatabaseBaselineError(f"Database backup failed: {exc}") from exc
    return destination


def sqlite_data_snapshot(source: Path) -> dict[str, Any]:
    source = source.resolve()
    digest = hashlib.sha256()
    counts: dict[str, int] = {}
    with closing(sqlite3.connect(f"file:{source.as_posix()}?mode=ro", uri=True)) as connection:
        tables = [
            row[0]
            for row in connection.execute(
                """SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT IN ('alembic_version','sqlite_sequence')
                ORDER BY name"""
            )
        ]
        for table in tables:
            quoted = table.replace('"', '""')
            columns = [row[1] for row in connection.execute(f'PRAGMA table_info("{quoted}")')]
            rows = [
                tuple(repr(value) for value in row)
                for row in connection.execute(f'SELECT * FROM "{quoted}"')
            ]
            rows.sort()
            counts[table] = len(rows)
            digest.update(repr((table, columns, rows)).encode())
    return {"counts": counts, "sha256": digest.hexdigest()}


def _normalized_type(value: Any, engine: Engine) -> str:
    return "".join(str(value.compile(dialect=engine.dialect)).upper().split())


def _foreign_keys(
    items: Sequence[Mapping[str, Any]],
) -> set[tuple[tuple[str, ...], str, tuple[str, ...]]]:
    return {
        (
            tuple(item["constrained_columns"]),
            item["referred_table"],
            tuple(item["referred_columns"]),
        )
        for item in items
    }


def schema_issues(engine: Engine) -> list[str]:
    load_models()
    inspector = inspect(engine)
    issues: list[str] = []
    actual_tables = set(inspector.get_table_names())
    for table_name, table in Base.metadata.tables.items():
        if table_name not in actual_tables:
            issues.append(f"missing table: {table_name}")
            continue
        actual_columns = {item["name"]: item for item in inspector.get_columns(table_name)}
        expected_columns = {column.name: column for column in table.columns}
        if set(actual_columns) != set(expected_columns):
            issues.append(
                f"column set mismatch: {table_name} expected={sorted(expected_columns)} "
                f"actual={sorted(actual_columns)}"
            )
            continue
        for name, expected in expected_columns.items():
            actual = actual_columns[name]
            expected_type = _normalized_type(expected.type, engine)
            actual_type = _normalized_type(actual["type"], engine)
            if expected_type != actual_type:
                issues.append(
                    f"type mismatch: {table_name}.{name} "
                    f"expected={expected_type} actual={actual_type}"
                )
            if bool(actual["nullable"]) != bool(expected.nullable):
                issues.append(
                    f"nullable mismatch: {table_name}.{name} "
                    f"expected={expected.nullable} actual={actual['nullable']}"
                )
            expected_default = (
                str(expected.server_default.arg)
                if isinstance(expected.server_default, DefaultClause)
                else None
            )
            actual_default = actual.get("default")
            if expected_default is not None and expected_default.strip("'()") != str(
                actual_default
            ).strip("'()"):
                issues.append(
                    f"default mismatch: {table_name}.{name} "
                    f"expected={expected_default} actual={actual_default}"
                )
        expected_fks = {
            (
                tuple(column.name for column in constraint.columns),
                next(iter(constraint.elements)).column.table.name,
                tuple(element.column.name for element in constraint.elements),
            )
            for constraint in table.foreign_key_constraints
        }
        actual_fks = _foreign_keys(inspector.get_foreign_keys(table_name))
        if expected_fks != actual_fks:
            issues.append(
                f"foreign key mismatch: {table_name} "
                f"expected={sorted(expected_fks)} actual={sorted(actual_fks)}"
            )
        expected_unique = {
            tuple(constraint.columns.keys())
            for constraint in table.constraints
            if isinstance(constraint, UniqueConstraint)
        }
        expected_unique.update((column.name,) for column in table.columns if column.unique)
        actual_unique = {
            tuple(name for name in item["column_names"] if name is not None)
            for item in inspector.get_unique_constraints(table_name)
            if item["column_names"]
        }
        actual_unique.update(
            tuple(name for name in item["column_names"] if name is not None)
            for item in inspector.get_indexes(table_name)
            if item["column_names"] and item.get("unique")
        )
        if expected_unique != actual_unique:
            issues.append(
                f"unique mismatch: {table_name} "
                f"expected={sorted(expected_unique)} actual={sorted(actual_unique)}"
            )
        expected_indexes = {
            tuple(index.columns.keys()) for index in table.indexes if index.name is not None
        }
        actual_indexes = {
            tuple(name for name in item["column_names"] if name is not None)
            for item in inspector.get_indexes(table_name)
            if item["column_names"]
        }
        if not expected_indexes.issubset(actual_indexes):
            issues.append(
                f"index mismatch: {table_name} missing={sorted(expected_indexes - actual_indexes)}"
            )
    return issues


def database_status(database_url: str) -> dict[str, Any]:
    current, heads = revisions(database_url)
    engine = create_engine(database_url)
    try:
        inspector = inspect(engine)
        tables = set(inspector.get_table_names())
        issues = schema_issues(engine) if current in heads else []
    finally:
        engine.dispose()
    required = {"users", "audit_logs", "insurance_products", "claims", "evidences"}
    return {
        "connected": True,
        "current_revision": current,
        "head_revisions": list(heads),
        "migration_pending": current not in heads,
        "required_tables": {name: name in tables for name in sorted(required)},
        "schema_issues": issues,
    }


def upgrade_with_backup(database_url: str, backup_directory: Path) -> dict[str, Any]:
    current, heads = revisions(database_url)
    if len(heads) != 1:
        raise DatabaseBaselineError(f"Expected one Alembic head, found: {heads}")
    source = sqlite_path(database_url)
    before_data = sqlite_data_snapshot(source) if source.exists() else None
    backup = (
        backup_sqlite(source, backup_directory.resolve(), heads[0]) if source.exists() else None
    )
    try:
        command.upgrade(alembic_config(database_url), "head")
    except Exception as exc:
        raise DatabaseBaselineError(
            f"Migration failed; backup retained at {backup}: {exc}"
        ) from exc
    status = database_status(database_url)
    after_data = sqlite_data_snapshot(source)
    data_preserved = before_data is None or before_data == after_data
    if status["migration_pending"] or status["schema_issues"]:
        raise DatabaseBaselineError(f"Post-migration validation failed: {status}")
    if not data_preserved:
        raise DatabaseBaselineError(
            f"Post-migration data fingerprint mismatch; backup retained at {backup}"
        )
    return {
        "before_revision": current,
        "backup": str(backup) if backup else None,
        "data_preserved": data_preserved,
        "data_snapshot": after_data,
        **status,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and normalize the main DB baseline")
    parser.add_argument("command", choices=("status", "backup", "upgrade"))
    parser.add_argument("--database-url", default=None)
    parser.add_argument("--backup-directory", default="backups")
    args = parser.parse_args()
    if args.database_url is None:
        from apps.api.app.config import get_settings

        database_url = get_settings().database_url
    else:
        database_url = args.database_url
    try:
        if args.command == "status":
            result = database_status(database_url)
        elif args.command == "backup":
            current, _ = revisions(database_url)
            result = {
                "backup": str(
                    backup_sqlite(
                        sqlite_path(database_url), Path(args.backup_directory).resolve(), current
                    )
                )
            }
        else:
            result = upgrade_with_backup(database_url, Path(args.backup_directory))
        print(json.dumps(result, ensure_ascii=False, indent=2, default=str))
        return 1 if result.get("migration_pending") or result.get("schema_issues") else 0
    except DatabaseBaselineError as exc:
        print(
            json.dumps({"status": "ERROR", "message": str(exc)}, ensure_ascii=False),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
