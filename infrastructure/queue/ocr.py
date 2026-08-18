from typing import Protocol
from uuid import UUID

from redis import Redis
from rq import Queue, Retry

from apps.api.app.config import get_settings


class OCRQueue(Protocol):
    def enqueue(self, ocr_result_id: UUID) -> str: ...


class RQOCRQueue:
    def enqueue(self, ocr_result_id: UUID) -> str:
        queue = Queue("document-ocr", connection=Redis.from_url(get_settings().redis_url))
        job = queue.enqueue(
            "apps.worker.ocr_jobs.process_ocr_job",
            str(ocr_result_id),
            retry=build_retry(get_settings().ocr_max_attempts),
            job_timeout=get_settings().ocr_timeout_seconds,
        )
        return job.id


def build_retry(max_attempts: int) -> Retry:
    if max_attempts < 2:
        max_attempts = 2
    return Retry(max=max_attempts - 1)
