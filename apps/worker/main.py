from redis import Redis
from rq import Queue, Worker

from apps.api.app.config import get_settings


def sample_job(value: str) -> str:
    """Connectivity-only job; no insurance, OCR, or AI behavior belongs in CODEX-01."""
    return f"processed:{value}"


def enqueue_sample(value: str = "foundation") -> str:
    queue = Queue("foundation", connection=Redis.from_url(get_settings().redis_url))
    job = queue.enqueue(sample_job, value)
    return job.id


def run_worker() -> None:
    connection = Redis.from_url(get_settings().redis_url)
    Worker([Queue("foundation", connection=connection)], connection=connection).work()


if __name__ == "__main__":
    run_worker()
