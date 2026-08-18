"""Create foundation identity, consent, and audit tables."""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0001_foundation"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    user_role = sa.Enum(
        "USER",
        "ADJUSTER",
        "POLICY_EDITOR",
        "RULE_EDITOR",
        "RULE_APPROVER",
        "SECURITY_ADMIN",
        "SYSTEM_ADMIN",
        name="userrole",
    )
    user_status = sa.Enum("ACTIVE", "LOCKED", "DELETED", name="userstatus")
    consent_type = sa.Enum(
        "SERVICE_TERMS", "PRIVACY", "SENSITIVE_INFORMATION", "AI_PROCESSING", name="consenttype"
    )
    audit_event = sa.Enum("LOGIN", "LOGIN_FAIL", "USER_REGISTER", "LOGOUT", name="auditeventtype")
    audit_result = sa.Enum("SUCCESS", "FAILURE", name="auditresult")

    op.create_table(
        "users",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("email", sa.String(320), nullable=False),
        sa.Column("password_hash", sa.String(512), nullable=False),
        sa.Column("display_name", sa.String(100), nullable=False),
        sa.Column("phone", sa.String(30), nullable=True),
        sa.Column("role", user_role, nullable=False),
        sa.Column("status", user_status, nullable=False),
        sa.Column("mfa_enabled", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("user_id", name="pk_users"),
        sa.UniqueConstraint("email", name="uq_users_email"),
    )
    op.create_index("ix_users_email", "users", ["email"])
    op.create_table(
        "consents",
        sa.Column("consent_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("consent_type", consent_type, nullable=False),
        sa.Column("consent_version", sa.String(50), nullable=False),
        sa.Column("agreed", sa.Boolean(), nullable=False),
        sa.Column("agreed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("source_ip", sa.String(45), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.user_id"], name="fk_consents_user_id_users"),
        sa.PrimaryKeyConstraint("consent_id", name="pk_consents"),
        sa.UniqueConstraint(
            "user_id", "consent_type", "consent_version", name="uq_consent_version"
        ),
    )
    op.create_index("ix_consents_user_id", "consents", ["user_id"])
    op.create_table(
        "audit_logs",
        sa.Column("audit_id", sa.Uuid(), nullable=False),
        sa.Column("actor_user_id", sa.Uuid(), nullable=True),
        sa.Column("event_type", audit_event, nullable=False),
        sa.Column("object_type", sa.String(100), nullable=True),
        sa.Column("object_id", sa.String(100), nullable=True),
        sa.Column("claim_id", sa.Uuid(), nullable=True),
        sa.Column("request_id", sa.String(100), nullable=False),
        sa.Column("source_ip", sa.String(45), nullable=True),
        sa.Column("before_value", sa.JSON(), nullable=True),
        sa.Column("after_value", sa.JSON(), nullable=True),
        sa.Column("result", audit_result, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["actor_user_id"], ["users.user_id"], name="fk_audit_logs_actor_user_id_users"
        ),
        sa.PrimaryKeyConstraint("audit_id", name="pk_audit_logs"),
    )
    for column in ("actor_user_id", "event_type", "claim_id", "request_id"):
        op.create_index(f"ix_audit_logs_{column}", "audit_logs", [column])


def downgrade() -> None:
    op.drop_table("audit_logs")
    op.drop_table("consents")
    op.drop_table("users")
