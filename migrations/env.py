from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from apps.api.app.config import get_settings
from domain.assessment.models import AssessmentRuleResult, CoverageAssessment  # noqa: F401
from domain.audit.models import AuditLog  # noqa: F401
from domain.calculation.models import BenefitCalculation  # noqa: F401
from domain.claim.models import Accident, Claim  # noqa: F401
from domain.contract.models import ContractCoverage, InsuranceContract, Insured  # noqa: F401
from domain.document.models import MedicalDocument  # noqa: F401
from domain.evidence.models import Evidence  # noqa: F401
from domain.fact.models import ExtractedFact, OCRResult, VerifiedFact  # noqa: F401
from domain.policy.models import (  # noqa: F401
    Coverage,
    CoverageAlias,
    InsuranceCompany,
    InsuranceProduct,
    Policy,
    PolicyClause,
    PolicyVersion,
    ProductVersion,
)
from domain.review.models import (  # noqa: F401
    AdditionalDocumentRequest,
    Review,
    ReviewAssignment,
)
from domain.rule.models import (  # noqa: F401
    BenefitRule,
    BenefitRuleClause,
    RuleCondition,
    RuleVersion,
)
from domain.user.models import Consent, User  # noqa: F401
from infrastructure.database.base import Base

config = context.config
config.set_main_option("sqlalchemy.url", get_settings().database_url)
if config.config_file_name is not None:
    fileConfig(config.config_file_name)
target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata, compare_type=True)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
