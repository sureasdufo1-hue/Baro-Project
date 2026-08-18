from apps.worker.main import sample_job


def test_sample_job_only_checks_worker_execution() -> None:
    assert sample_job("ready") == "processed:ready"
