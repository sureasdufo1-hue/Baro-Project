import enum
from dataclasses import dataclass
from datetime import date
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

from domain.assessment.models import EligibilityResult, RuleEvaluationResult
from domain.policy.models import PolicyVersion
from domain.rule.models import LogicalOperator, RuleOperator, RuleType
from shared.errors import DomainError


class ResolutionStatus(enum.StrEnum):
    RESOLVED = "RESOLVED"
    NOT_FOUND = "NOT_FOUND"
    CONFLICT = "CONFLICT"
    INSUFFICIENT_DATA = "INSUFFICIENT_DATA"


@dataclass(frozen=True)
class PolicyResolution:
    status: ResolutionStatus
    policy_version_id: UUID | None
    candidate_ids: tuple[UUID, ...]
    reason: str


def applicable(version: PolicyVersion, target: date) -> bool:
    return version.effective_from <= target and (
        version.effective_to is None or target <= version.effective_to
    )


def resolve_policy_version(
    explicit_id: UUID | None, candidates: list[PolicyVersion], target: date | None
) -> PolicyResolution:
    if target is None:
        return PolicyResolution(
            ResolutionStatus.INSUFFICIENT_DATA, None, (), "resolution date missing"
        )
    matching = [item for item in candidates if applicable(item, target)]
    if explicit_id is not None:
        explicit = next(
            (item for item in candidates if item.policy_version_id == explicit_id), None
        )
        if explicit is None or not applicable(explicit, target):
            return PolicyResolution(
                ResolutionStatus.CONFLICT,
                None,
                tuple(x.policy_version_id for x in matching),
                "explicit version is not applicable",
            )
        return PolicyResolution(
            ResolutionStatus.RESOLVED,
            explicit_id,
            (explicit_id,),
            "validated contract policy version",
        )
    if not matching:
        return PolicyResolution(
            ResolutionStatus.NOT_FOUND, None, (), "no applicable policy version"
        )
    if len(matching) > 1:
        return PolicyResolution(
            ResolutionStatus.CONFLICT,
            None,
            tuple(x.policy_version_id for x in matching),
            "multiple policy versions apply",
        )
    return PolicyResolution(
        ResolutionStatus.RESOLVED,
        matching[0].policy_version_id,
        (matching[0].policy_version_id,),
        "single applicable policy version",
    )


class Condition(BaseModel):
    model_config = ConfigDict(extra="forbid")
    path: str = Field(max_length=250, pattern=r"^(facts|coverage|contract)\.[A-Za-z0-9_.]+$")
    operator: RuleOperator
    value: Any | None = None

    @model_validator(mode="after")
    def value_shape(self) -> "Condition":
        if isinstance(self.value, str) and len(self.value) > 1000:
            raise ValueError("comparison string is too large")
        if isinstance(self.value, list) and len(self.value) > 100:
            raise ValueError("comparison list is too large")
        if self.operator in {
            RuleOperator.IN,
            RuleOperator.NOT_IN,
            RuleOperator.BETWEEN,
        } and not isinstance(self.value, list):
            raise ValueError("operator requires a list value")
        if self.operator is RuleOperator.BETWEEN and (
            not isinstance(self.value, list) or len(self.value) != 2
        ):
            raise ValueError("BETWEEN requires exactly two values")
        return self


class RuleDSL(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    schema_version: str = Field(alias="schemaVersion", pattern=r"^1\.0$")
    rule_type: RuleType = Field(alias="ruleType")
    logical_operator: LogicalOperator = Field(default=LogicalOperator.AND, alias="logicalOperator")
    conditions: list[Condition] = Field(min_length=1, max_length=100)


@dataclass(frozen=True)
class Evaluation:
    result: RuleEvaluationResult
    inputs: dict[str, Any]
    trace: dict[str, Any]


def compare(actual: Any, operator: RuleOperator, expected: Any) -> bool:
    if operator is RuleOperator.EXISTS:
        return actual is not None
    if operator is RuleOperator.NOT_EXISTS:
        return actual is None
    if operator is RuleOperator.EQ:
        return bool(actual == expected)
    if operator is RuleOperator.NE:
        return bool(actual != expected)
    if operator is RuleOperator.GT:
        return bool(actual > expected)
    if operator is RuleOperator.GTE:
        return bool(actual >= expected)
    if operator is RuleOperator.LT:
        return bool(actual < expected)
    if operator is RuleOperator.LTE:
        return bool(actual <= expected)
    if operator is RuleOperator.IN:
        return actual in expected
    if operator is RuleOperator.NOT_IN:
        return bool(actual not in expected)
    if operator is RuleOperator.BETWEEN:
        return bool(expected[0] <= actual <= expected[1])
    raise DomainError("INVALID_RULE_DEFINITION", "Unsupported rule operator", 422)


def execute(rule: RuleDSL, context: dict[str, Any]) -> Evaluation:
    outcomes: list[bool] = []
    inputs: dict[str, Any] = {}
    trace = []
    missing = False
    for condition in rule.conditions:
        actual = context.get(condition.path)
        inputs[condition.path] = actual
        if actual is None and condition.operator not in {
            RuleOperator.EXISTS,
            RuleOperator.NOT_EXISTS,
        }:
            missing = True
            outcome = False
        else:
            outcome = compare(actual, condition.operator, condition.value)
        outcomes.append(outcome)
        trace.append(
            {
                "path": condition.path,
                "operator": condition.operator.value,
                "result": outcome,
                "missing": actual is None,
            }
        )
    if missing:
        result = RuleEvaluationResult.MISSING_INPUT
    else:
        passed = all(outcomes) if rule.logical_operator is LogicalOperator.AND else any(outcomes)
        result = RuleEvaluationResult.PASS if passed else RuleEvaluationResult.FAIL
    return Evaluation(result, inputs, {"conditions": trace})


def aggregate(results: list[tuple[RuleType, RuleEvaluationResult]]) -> EligibilityResult:
    if not results:
        return EligibilityResult.MANUAL_REVIEW
    if any(result is RuleEvaluationResult.ERROR for _, result in results):
        return EligibilityResult.MANUAL_REVIEW
    if any(result is RuleEvaluationResult.MISSING_INPUT for _, result in results):
        return EligibilityResult.ADDITIONAL_INFO_REQUIRED
    eligibility = [result for kind, result in results if kind is RuleType.ELIGIBILITY]
    exclusions = [result for kind, result in results if kind is RuleType.EXCLUSION]
    if not eligibility:
        return EligibilityResult.MANUAL_REVIEW
    if any(result is RuleEvaluationResult.FAIL for result in eligibility):
        return EligibilityResult.NOT_PAYABLE
    if any(result is RuleEvaluationResult.PASS for result in exclusions):
        return EligibilityResult.NOT_PAYABLE
    return EligibilityResult.PAYABLE
