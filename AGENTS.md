# AGENTS.md

Repository-wide instructions for AI coding agents and human contributors.

## 1. Project Mission

This project implements an AI-assisted insurance benefit assessment system. It accepts insurance contracts, policy documents, certificates, medical-expense documents, accident documents, and other claim evidence. It extracts structured facts, resolves the applicable policy version, identifies candidate coverages, evaluates benefit conditions, and calculates an estimated benefit.

The MVP focuses on fixed-benefit third-sector insurance: cancer and specified-disease diagnosis benefits, acute myocardial infarction diagnosis benefits, disease and injury surgery benefits, fracture and burn diagnosis benefits, and disease and injury hospitalization daily benefits.

The MVP also includes two deterministic extensions already implemented in the calculation engine (2026-08 user decision):

- Proportional disability benefits (`PROPORTIONAL_DISABILITY`): insured amount multiplied by a verified disability-rate fact or a versioned rule rate, within rule-configured min/max bounds.
- Medical-cost-based benefits (`INDEMNITY`, `MEDICAL_EXPENSE`): deterministic application of versioned indemnity/copayment rates, non-benefit handling, and minimum deductions to verified actual-loss, copayment, non-benefit, and treatment-cost amounts.

Disability degrees and loss amounts enter only as verified document-derived facts; the system never performs professional disability grading or medical causation judgment itself. Complex disability assessment, full indemnity medical insurance products beyond these deterministic strategies, automobile insurance, liability insurance, workers compensation, medical-causation automation, insurer-system integration, and automated claim submission remain later-phase features unless explicitly assigned.

## 2. Source of Truth

Project documents define the intended system. When requirements conflict, use this precedence:

1. Requirements Definition / SRS
2. System Architecture
3. ERD
4. System Functional Structure
5. User Flow
6. UI Specification
7. Existing implementation
8. Comments and temporary notes

Existing code is not automatically authoritative when it conflicts with an approved design. Do not silently reinterpret conflicts or invent missing insurance rules. Identify the conflict and implement only what is safe. The registered baseline documents are listed in `docs/PROJECT_BASELINE.md`.

## 3. Non-Negotiable Architecture Rules

### CRITICAL-01 - LLMs never determine an insurance benefit amount

Forbidden:

```text
Diagnosis document -> LLM -> Benefit amount -> User
```

Required:

```text
Document -> OCR -> AI Fact Extraction -> Verified Facts
-> Policy Version Resolver -> Coverage Matcher -> Eligibility Engine
-> Calculation Engine -> Evidence -> Result
```

AI may interpret documents but is never the authoritative calculator.

### CRITICAL-02 - Only deterministic logic produces monetary results

```text
Verified Facts
+ Contract Coverage
+ Policy Version
+ Rule Version
= Coverage Assessment
+ Benefit Calculation
+ Evidence
```

The same verified inputs and versioned rules must produce the same result.

### CRITICAL-03 - Material values require provenance

Every material calculation value must trace to an approved source:

```text
diagnosis.code -> VerifiedFact -> MedicalDocument -> Page -> Bounding Box
insured_amount -> ContractCoverage -> InsuranceContract
payment_rate -> RuleVersion -> PolicyClause -> PolicyVersion
```

Never use unexplained values in a calculation.

### CRITICAL-04 - OCR output is not a verified fact

```text
MedicalDocument -> OCRResult -> ExtractedFact -> VerifiedFact -> Assessment
```

Insurance-critical fields must meet the configured verification policy before calculation.

### CRITICAL-05 - Resolve the applicable policy version

Never silently choose the newest policy, newest rule, similar product, or generic rule. Resolve the applicable version using contract and event data. If resolution produces zero or conflicting versions, return `MANUAL_REVIEW` or an equivalent explicit unresolved state.

### CRITICAL-06 - Historical calculations are immutable

`ProductVersion`, `PolicyVersion`, `RuleVersion`, and `CalculationVersion` are versioned concepts. Recalculation creates a new version and preserves the previous record.

## 4. Domain Model

```text
User
├─ Insured
├─ InsuranceContract
│  └─ ContractCoverage
└─ Claim
   ├─ Accident
   ├─ MedicalDocument
   │  └─ OCRResult
   │     └─ ExtractedFact
   │        └─ VerifiedFact
   ├─ CoverageAssessment
   │  └─ AssessmentRuleResult
   ├─ BenefitCalculation
   ├─ Evidence
   └─ Review
```

Insurance knowledge is modeled separately:

```text
InsuranceCompany -> InsuranceProduct -> ProductVersion -> Policy
-> PolicyVersion -> PolicyClause -> Coverage -> BenefitRule -> RuleVersion
```

Do not collapse these concepts for convenience.

## 5. Repository Structure

Preserve these logical boundaries while adapting syntax to the selected framework:

```text
/
├─ apps/
│  ├─ web/
│  ├─ admin/
│  ├─ api/
│  └─ worker/
├─ domain/
│  ├─ auth/
│  ├─ user/
│  ├─ contract/
│  ├─ claim/
│  ├─ document/
│  ├─ fact/
│  ├─ policy/
│  ├─ rule/
│  ├─ assessment/
│  ├─ calculation/
│  ├─ evidence/
│  ├─ review/
│  └─ audit/
├─ infrastructure/
│  ├─ database/
│  ├─ storage/
│  ├─ queue/
│  ├─ ai/
│  ├─ ocr/
│  ├─ search/
│  └─ security/
├─ prompts/
├─ shared/
│  ├─ types/
│  ├─ errors/
│  ├─ security/
│  └─ utils/
├─ migrations/
├─ tests/
│  ├─ unit/
│  ├─ integration/
│  ├─ rules/
│  ├─ security/
│  └─ e2e/
├─ docs/
├─ scripts/
└─ AGENTS.md
```

The MVP architecture is a modular monolith plus asynchronous worker. Do not introduce microservices only because logical services exist in the design.

## 6. Domain Ownership

| Domain | Primary entities |
| --- | --- |
| Auth | User, Consent |
| Contract | Insured, InsuranceContract, ContractCoverage |
| Policy | InsuranceCompany, InsuranceProduct, ProductVersion, Policy, PolicyVersion, PolicyClause, Coverage |
| Rule | BenefitRule, RuleVersion, RuleCondition |
| Claim | Claim, Accident |
| Document | MedicalDocument |
| OCR | OCRResult |
| Fact | ExtractedFact, VerifiedFact, Diagnosis, Surgery, Hospitalization |
| Assessment | CoverageAssessment, AssessmentRuleResult |
| Calculation | BenefitCalculation |
| Evidence | Evidence |
| Review | Review, ReviewAssignment |
| Audit | AuditLog |

A domain owns its data and business logic. Use domain services/APIs or explicit application orchestration instead of directly changing another domain's persistence model.

## 7. Claim Lifecycle

Supported states are `DRAFT`, `DOCUMENT_REQUIRED`, `DOCUMENT_PROCESSING`, `USER_VERIFICATION`, `ASSESSING`, `MANUAL_REVIEW`, `COMPLETED`, `FAILED`, `CANCELLED`, and `CLOSED`.

The normal flow is `DRAFT -> DOCUMENT_REQUIRED -> DOCUMENT_PROCESSING -> USER_VERIFICATION -> ASSESSING`. Assessment may transition to `COMPLETED`, `MANUAL_REVIEW`, `DOCUMENT_REQUIRED`, or `FAILED`. Review may transition to `ASSESSING`, `DOCUMENT_REQUIRED`, or `COMPLETED`.

Centralize, validate, test, and audit material state transitions. Never create ad hoc string states in controllers.

## 8. Document and OCR Rules

```text
Upload -> File validation -> Malware scan -> Secure storage
-> OCR job -> OCRResult -> AI extraction -> ExtractedFact
```

Validate MIME type, file signature/magic bytes, configured size, upload authorization, and malware-scan status. MVP formats may include JPG, JPEG, PNG, HEIC, and PDF. Never rely only on filename extensions or expose private documents through permanent public URLs.

## 9. AI Rules

AI may classify documents, extract medical facts and dates, normalize text, retrieve possible clauses or coverage candidates, and explain approved structured results.

AI must not independently create insured amounts, payment rates, deductibles, waiting or exclusion periods, benefit limits, disability percentages, or final benefit amounts.

All AI output entering business logic must be structured and schema-validated. On invalid output, retry or route to manual review. Never guess missing fields.

## 10. Policy Version Rules

Resolve `product_version_id`, `policy_version_id`, and `rule_version_id` before material assessment. Inputs can include product version, contract date, coverage dates, accident date, and diagnosis date.

- Exactly one applicable version: resolved.
- No applicable version: unresolved and `MANUAL_REVIEW`.
- Multiple conflicting versions: `VERSION_CONFLICT` and `MANUAL_REVIEW`.

Never choose the newest version as a fallback.

## 11. Coverage Matching Rules

Coverage matching answers which subscribed coverages should be evaluated. It does not determine whether a benefit is payable: `Coverage Match != PAYABLE`.

Inputs may include verified facts, contract coverages, aliases, and structured policy metadata. Output candidate coverages with reasons.

## 12. Rule Engine Rules

MVP rules should be declarative and versioned. Explicitly whitelist operators such as `EQ`, `NE`, `GT`, `GTE`, `LT`, `LTE`, `IN`, `NOT_IN`, `BETWEEN`, `EXISTS`, and `NOT_EXISTS`. Never allow arbitrary executable code inside a rule.

Rules move through controlled states such as `DRAFT -> TESTING -> APPROVAL -> ACTIVE`; authors must not directly activate them.

## 13. Eligibility Rules

Preserve the semantic stages `Eligibility -> Exclusion -> Reduction -> Limit -> Calculation eligibility`.

Standard results include `PAYABLE`, `LIKELY_PAYABLE`, `ADDITIONAL_INFO_REQUIRED`, `MANUAL_REVIEW`, `LIKELY_NOT_PAYABLE`, `POSSIBLE_EXCLUSION`, `NOT_PAYABLE`, and `UNDETERMINED`. Do not turn every unresolved case into `NOT_PAYABLE`.

## 14. Calculation Rules

Only deterministic application or rule logic may produce final monetary results. Do not calculate material amounts in the frontend or ask an LLM to perform authoritative arithmetic.

Use integer KRW or an appropriate `Decimal` type, never binary floating point. Make rounding explicit.

Each `BenefitCalculation` must retain enough data to reproduce the result: contract coverage, insured amount, verified facts, policy/rule versions, calculation rule, parameters, formula, input snapshot, result, and timestamp. Never store only the final amount.

## 15. Evidence Rules

Evidence is a core business feature. Every material assessment must connect calculations to rule versions, clauses, policy versions, verified facts, source documents, pages, and bounding boxes.

A result must explain the evaluated contract and coverage, applied versions and clause, used facts and documents, and calculation formula. Every monetary result must provide an action equivalent to "View calculation basis."

## 16. Human Review Rules

Prefer manual review over fabricated certainty when confidence is insufficient, facts conflict, versions or rules are missing/conflicting, exclusions are ambiguous, mandatory evidence is missing, or professional causation/disability judgment is required.

Review changes must retain previous value/result, new value/result, reviewer, timestamp, and reason.

## 17. Database Rules

Respect the approved ERD. In particular:

```text
InsuranceProduct != InsuranceContract
Coverage != ContractCoverage
Policy != PolicyVersion
BenefitRule != RuleVersion
OCRResult != ExtractedFact != VerifiedFact
CoverageAssessment != BenefitCalculation
```

Use migrations. Prefer UUIDs for internal keys and separate human-readable display IDs. Model business dates as dates and system events as timezone-aware timestamps.

JSON is appropriate for raw provider output, bounding boxes, versioned rule definitions, calculation snapshots, and traces. Do not put the entire relational domain into one JSON column.

## 18. API Rules

Use explicit input validation and object-level authorization. Authentication alone is not authorization to a particular claim, contract, document, calculation, evidence item, or review.

Use explicit domain errors, including `POLICY_VERSION_NOT_FOUND`, `POLICY_VERSION_CONFLICT`, `RULE_NOT_FOUND`, `RULE_CONFLICT`, `UNVERIFIED_FACT`, `REQUIRED_DOCUMENT_MISSING`, `CALCULATION_FAILED`, and `ACCESS_DENIED`.

Never convert a failed calculation into a successful zero-KRW result.

## 19. Frontend Rules

The frontend displays state, collects input, validates presentation concerns, supports fact verification, and displays assessments, calculations, and evidence. It is not the source of insurance business logic.

Keep OCR confidence separate from benefit-assessment likelihood. Never present extraction confidence as payment probability without a separately approved model and definition.

Prioritize responsive user screens for contract registration, claim creation, uploads, fact verification, and results. Admin rule tools may be desktop-first.

## 20. Security and Privacy Rules

Security is a functional requirement. Apply least privilege, object-level authorization, safe upload handling, injection defenses, secret management, appropriate logging, and auditability.

Private documents require authenticated authorization and short-lived signed access to encrypted object storage. Never use permanent public URLs.

Diagnoses, treatment history, medical documents, insurance contracts, and identifiers are highly sensitive. Apply data minimization, avoid unnecessary duplication, and do not send unnecessary personal information to external OCR/AI providers. Keep external providers behind dedicated gateways/adapters.

## 21. Audit Rules

Audit material actions including authentication failures, document upload/view/download, OCR execution, fact changes, contract changes, policy/rule lifecycle events, calculation/recalculation, review override, and permission changes. Audit records must make material changes reconstructable.

## 22. Async Job Rules

Use background jobs for OCR, AI extraction, policy ingestion, indexing, bulk assessment, and notifications. Standard states are `QUEUED`, `PROCESSING`, `SUCCEEDED`, `FAILED`, `RETRYING`, and `CANCELLED`. Retries must be bounded.

## 23. Error Handling

Do not swallow business errors or use `null`, zero, or an empty array as a universal failure state. Explicitly distinguish no applicable coverage from failure to determine coverage, and a legitimate zero result from calculation failure. Fail safely and provide actionable messages.

## 24. Testing Strategy

Use unit, integration, rule-regression, security, and end-to-end tests as appropriate. Highest-priority unit targets are:

1. Policy Version Resolver
2. Rule Parser and Validator
3. Eligibility Engine
4. Calculation Engine
5. Coverage Matcher
6. Fact verification
7. Claim State Machine

Every material rule needs positive and negative golden cases. Changing a rule requires running existing regression cases. Do not change an expected result merely to make a modified rule pass unless the intended business outcome changed.

## 25. Coding Conventions

Prefer explicit domain names and types, small functions, explicit domain errors, deterministic logic, provider dependency injection, and pure calculation functions. Do not hardcode product-specific terms or rates in generic application logic. Authoritative values belong in versioned policy/rule data.

## 26. Change Management and Agent Procedure

Before changing code:

1. Inspect existing modules, entities, services, APIs, tests, migrations, rules, and errors.
2. Identify the owning domain and affected requirement.
3. Check critical invariants, versioning, historical reproducibility, security, privacy, and audit impact.
4. Implement the minimum coherent change without speculative architecture.
5. Add normal, invalid-input, domain-error, and relevant authorization tests.
6. Run formatting, linting, type checking, tests, and migration validation as configured.
7. Review sensitive-data logging, document access, external-provider payloads, and authorization.
8. Report exactly what changed and what remains unresolved.

Do not claim success when required validation fails.

## 27. Definition of Done

A feature is complete only when all applicable requirements are met: implementation, build/types/checks, tests, domain boundaries, errors, authorization, security/privacy review, migrations, audit events, rule regression, historical reproducibility, evidence preservation, and updated documentation.

## 28. MVP Implementation Order

1. Foundation: structure, configuration, database/migrations, authentication, RBAC, audit.
2. Insurance master: company, product/version, policy/version/clause, coverage, basic rule model.
3. Contract: insured, contract, contract coverage, APIs and UI.
4. Claim: claim, accident, state machine, APIs and UI.
5. Document: secure upload/storage, validation, malware scanning, metadata.
6. OCR/AI: provider abstractions, workers, OCR result, extracted and verified facts, verification UI.
7. Insurance decision: version resolver, coverage matcher, rule parser/validator/executor, eligibility.
8. Calculation: engine, snapshots, versioning, recalculation.
9. Evidence: model, decision trace, calculation-basis UI, clause viewer.
10. Review: queue, expert review, additional-document requests, audited overrides.

## 29. Prohibited Actions

Unless the architecture is formally changed, do not:

- use LLM output directly as a benefit amount;
- use raw OCR as authoritative calculation facts;
- guess policy versions, rates, exclusions, waiting periods, or disability rates;
- hardcode product-specific rules in generic code;
- activate AI-extracted rules without human review and testing;
- permit arbitrary execution inside the rule DSL;
- overwrite historical calculations;
- use binary floating point for authoritative money calculations;
- return zero KRW for a calculation failure;
- expose private documents publicly or skip object authorization;
- commit credentials or log documents, medical data, or secrets unnecessarily;
- confuse OCR confidence with payment probability;
- present unresolved questions as certain;
- remove evidence from calculation behavior;
- bypass intended domain interfaces or perform unrelated large refactors;
- claim completion while required tests fail.

## 30. MVP Happy Path

```text
Login -> Register contract and coverage -> Create claim
-> Upload diagnosis certificate -> Validate and OCR document
-> Extract diagnosis facts -> User verifies facts -> Resolve PolicyVersion
-> Match subscribed coverage -> Execute versioned eligibility rules
-> Deterministically calculate estimated benefit
-> Build evidence chain to policy clause and source location
-> Display amount, status, formula, and evidence
```

MVP success requires the complete `Document -> Verified Fact -> Policy -> Rule -> Assessment -> Calculation -> Evidence` chain, not merely OCR or AI extraction.

## 31. Completion Report Format

Use these headings when completing a development task:

```text
## Implemented
## Changed Files
## Domain Impact
## Database Changes
## API Changes
## Policy / Rule Impact
## Calculation Impact
## Security / Privacy Impact
## Tests
## Validation Performed
## Remaining Issues
```

## Final Project Invariant

Verified facts, contract coverage, policy version, and rule version are the only inputs that may produce an authoritative coverage assessment, benefit calculation, and evidence chain. Never let an LLM directly determine an insurance benefit amount. Every material decision must be traceable and reproducible.

