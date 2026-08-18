# Security Threat Model

## Assets and trust boundaries

Protected assets are credentials and sessions, contracts, claims, medical documents, OCR/AI output, VerifiedFact, policy/rule versions, assessments, calculations, evidence, reviews, audit records and runtime secrets.

Untrusted actors and inputs include anonymous and authenticated users, compromised accounts, uploaded files, filenames, OCR text, policy text and external provider responses. ADJUSTER and editor roles are trusted only for their explicitly assigned resources. External OCR/AI providers are separate trust boundaries.

## Findings and controls

| Severity | Threat | Control/status |
| --- | --- | --- |
| HIGH | Cross-user IDOR | Owner checks across contract, claim, document, fact, calculation and evidence; Review uses assignment scope |
| HIGH | Malicious upload/path traversal | Magic-byte/MIME/size validation, malware gate, UUID storage key, private storage, nosniff/sandbox response |
| HIGH | Brute force/resource abuse | Configurable endpoint-class rate limits; JSON body and upload limits; bounded queue retry |
| HIGH | Production placeholder secrets/providers | Startup validation rejects insecure cookie, placeholder secret and development providers |
| MEDIUM | Cookie CSRF | Strict SameSite cookie, credentialed CORS allowlist and unsafe cross-origin request rejection |
| MEDIUM | Prompt injection/AI amount injection | Untrusted text enters schema-forbidden Fact extraction only; unknown fields and benefit fields rejected |
| MEDIUM | Rule DSL resource/injection abuse | No eval/exec; operator whitelist; 100-condition/list and string-size limits |
| MEDIUM | Sensitive cache/sniffing | no-store, nosniff, restrictive CSP, referrer and permissions headers |
| MEDIUM | Observability cardinality/privacy leak | UUID path segments normalized; metrics expose no medical values and require security/admin role |
| LOW | Distributed rate-limit consistency | Current limiter is per API process; production must replace it with Redis/gateway enforcement |

No CVSS score is asserted. Production penetration testing and infrastructure configuration review remain required.

## Role summary

| Resource | USER | ADJUSTER | POLICY_EDITOR | RULE_EDITOR | RULE_APPROVER | SYSTEM_ADMIN |
| --- | --- | --- | --- | --- | --- | --- |
| Contract/Claim | own R/W | assigned Review context | - | - | - | operational policy only |
| MedicalDocument | own | assigned Claim | - | - | - | restricted |
| Policy | catalog R | evidence R | R/W | R | R | R/W |
| Rule | - | evidence R | R | R/W | approval policy | R/W |
| Review | own status | assigned action | - | - | - | create/assign |
| Metrics | - | - | - | - | - | R |

Frontend visibility is not considered authorization; every sensitive endpoint enforces backend RBAC/object checks.
