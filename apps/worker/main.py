from redis import Redis
from rq import Queue, Worker

from apps.api.app.config import get_settings


def import_domain_models() -> None:
    """Register every ORM mapper so FK resolution works inside the worker process.

    The API process imports all models transitively through its routes; the worker
    imports only the modules a job touches, which breaks SQLAlchemy mapper/FK
    resolution for tables it does not import (e.g. additional_document_requests).
    """

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


import_domain_models()


def sample_job(value: str) -> str:
    """Connectivity-only job; no insurance, OCR, or AI behavior belongs in CODEX-01."""
    return f"processed:{value}"


def enqueue_sample(value: str = "foundation") -> str:
    queue = Queue("foundation", connection=Redis.from_url(get_settings().redis_url))
    job = queue.enqueue(sample_job, value)
    return job.id


def run_worker() -> None:
    connection = Redis.from_url(get_settings().redis_url)
    Worker(
        [
            Queue("document-ocr", connection=connection),
            Queue("document-ai-extraction", connection=connection),
            Queue("foundation", connection=connection),
        ],
        connection=connection,
    ).work()


if __name__ == "__main__":
    run_worker()
