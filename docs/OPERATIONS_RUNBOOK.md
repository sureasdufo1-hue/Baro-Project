# Operations Runbook

## Deployment gates

Production startup must fail unless HTTPS cookies, a rotated non-placeholder session secret, managed private object storage, malware scanner, OCR and AI providers are configured. CORS must contain only deployed frontend origins. HSTS is enabled at the TLS ingress after HTTPS is confirmed end to end.

Run before release:

```powershell
ruff format --check .
ruff check .
mypy apps domain infrastructure shared
pytest
pnpm lint
pnpm typecheck
pnpm test
pnpm build
docker compose config
alembic upgrade head
```

## Health and observability

- `/health/live`: process liveness only.
- `/health/ready`: database readiness; load balancers must use this endpoint.
- `/metrics`: SECURITY_ADMIN/SYSTEM_ADMIN-only Prometheus text. Labels normalize UUIDs and contain no medical values.
- Alert candidates: sustained 5xx, OCR/AI failure and retry exhaustion, calculation failure, queue age, manual-review ratio and database/storage capacity.

Request logs contain request ID, normalized operational endpoint, status and duration only. Never add OCR text, VerifiedFact values, document bodies, signed URLs, session cookies, passwords or Review opinion.

## Backup and recovery

- PostgreSQL: encrypted infrastructure snapshots plus periodic `pg_dump` to access-controlled encrypted backup storage.
- Object storage: versioning/retention and encryption-at-rest using the provider's managed keys.
- Audit and database backups share a recovery point so references remain consistent.
- Test restore into an isolated environment on a schedule; a backup is not accepted until restore and referential-integrity checks pass.
- Recovery order: database → private objects → migration verification → readiness → worker queues → API traffic.
- Redis/RQ is not the source of truth. After recovery, re-enqueue only database records in retryable states and preserve bounded attempts.

## Incident response

1. Restrict traffic and preserve audit/database/object evidence.
2. Rotate session/provider/database credentials when compromise is suspected.
3. Invalidate sessions through the configured signing-key/session strategy.
4. Identify affected users and records through IDs—not sensitive values in logs.
5. Recover from a verified restore point and reconcile orphaned jobs/documents.
6. Document timeline, impact, remediation and legally required notifications.

## Retention foundation

Retention periods require approved legal/privacy policy and are not invented in application code. Deletion jobs must distinguish relational metadata, private objects, derived OCR/AI data, audit legal holds and versioned insurance decisions. Use a dry-run report and audited, idempotent deletion workflow before enabling automatic retention.
