import uuid
from datetime import date

import pytest
from pydantic import ValidationError

from domain.assessment.engine import (
    ResolutionStatus,
    RuleDSL,
    aggregate,
    execute,
    resolve_policy_version,
)
from domain.assessment.models import EligibilityResult, RuleEvaluationResult
from domain.policy.models import PolicyVersion, PolicyVersionStatus
from domain.rule.models import RuleType


def version(code: str, start: date, end: date | None = None) -> PolicyVersion:
    return PolicyVersion(
        policy_version_id=uuid.uuid4(),
        policy_id=uuid.uuid4(),
        version_code=code,
        effective_from=start,
        effective_to=end,
        status=PolicyVersionStatus.ACTIVE,
    )


def test_policy_resolver_resolves_not_found_conflict_and_never_uses_latest_fallback() -> None:
    old = version("OLD", date(2020, 1, 1), date(2020, 12, 31))
    current = version("CURRENT", date(2021, 1, 1))
    resolved = resolve_policy_version(None, [old, current], date(2021, 5, 1))
    assert resolved.status is ResolutionStatus.RESOLVED
    assert resolved.policy_version_id == current.policy_version_id
    assert (
        resolve_policy_version(None, [current], date(2019, 1, 1)).status
        is ResolutionStatus.NOT_FOUND
    )
    overlap = version("OVERLAP", date(2021, 1, 1))
    assert (
        resolve_policy_version(None, [current, overlap], date(2021, 5, 1)).status
        is ResolutionStatus.CONFLICT
    )
    assert (
        resolve_policy_version(old.policy_version_id, [old, current], date(2021, 5, 1)).status
        is ResolutionStatus.CONFLICT
    )


def test_rule_dsl_distinguishes_missing_false_and_is_deterministic() -> None:
    rule = RuleDSL.model_validate(
        {
            "schemaVersion": "1.0",
            "ruleType": "ELIGIBILITY",
            "logicalOperator": "AND",
            "conditions": [{"path": "facts.DIAGNOSIS_CODE", "operator": "IN", "value": ["I21.9"]}],
        }
    )
    assert execute(rule, {}).result is RuleEvaluationResult.MISSING_INPUT
    assert execute(rule, {"facts.DIAGNOSIS_CODE": "C50"}).result is RuleEvaluationResult.FAIL
    outcomes = [execute(rule, {"facts.DIAGNOSIS_CODE": "I21.9"}).result for _ in range(100)]
    assert set(outcomes) == {RuleEvaluationResult.PASS}


@pytest.mark.parametrize(
    "operator,value,actual",
    [
        ("EQ", 3, 3),
        ("NE", 4, 3),
        ("GT", 2, 3),
        ("GTE", 3, 3),
        ("LT", 4, 3),
        ("LTE", 3, 3),
        ("IN", [2, 3], 3),
        ("NOT_IN", [1, 2], 3),
        ("BETWEEN", [1, 5], 3),
        ("EXISTS", None, 3),
    ],
)
def test_allowed_operators(operator: str, value: object, actual: object) -> None:
    rule = RuleDSL.model_validate(
        {
            "schemaVersion": "1.0",
            "ruleType": "ELIGIBILITY",
            "conditions": [{"path": "facts.VALUE", "operator": operator, "value": value}],
        }
    )
    assert execute(rule, {"facts.VALUE": actual}).result is RuleEvaluationResult.PASS


def test_dsl_rejects_code_paths_unknown_operators_and_extra_fields() -> None:
    for condition in (
        {"path": "__import__.os", "operator": "EQ", "value": 1},
        {"path": "facts.CODE", "operator": "EVAL", "value": "__import__('os')"},
        {"path": "facts.CODE", "operator": "EQ", "value": "I21.9", "python": "exec(x)"},
    ):
        with pytest.raises(ValidationError):
            RuleDSL.model_validate(
                {"schemaVersion": "1.0", "ruleType": "ELIGIBILITY", "conditions": [condition]}
            )


def test_eligibility_aggregation_preserves_semantics() -> None:
    assert (
        aggregate([(RuleType.ELIGIBILITY, RuleEvaluationResult.PASS)]) is EligibilityResult.PAYABLE
    )
    assert (
        aggregate([(RuleType.ELIGIBILITY, RuleEvaluationResult.FAIL)])
        is EligibilityResult.NOT_PAYABLE
    )
    assert (
        aggregate([(RuleType.ELIGIBILITY, RuleEvaluationResult.MISSING_INPUT)])
        is EligibilityResult.ADDITIONAL_INFO_REQUIRED
    )
    assert aggregate([]) is EligibilityResult.MANUAL_REVIEW
    assert (
        aggregate(
            [
                (RuleType.ELIGIBILITY, RuleEvaluationResult.PASS),
                (RuleType.EXCLUSION, RuleEvaluationResult.PASS),
            ]
        )
        is EligibilityResult.NOT_PAYABLE
    )
