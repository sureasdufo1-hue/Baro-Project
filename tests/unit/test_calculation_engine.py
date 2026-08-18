from datetime import date
from decimal import Decimal

import pytest
from pydantic import ValidationError

from domain.calculation.engine import CalculationRule, calculate
from shared.errors import DomainError


def rule(data: dict[str, object]) -> CalculationRule:
    return CalculationRule.model_validate(data)


def test_fixed_benefit_decimal_rounding_and_determinism() -> None:
    parsed = rule(
        {
            "schemaVersion": 1,
            "ruleType": "CALCULATION",
            "strategy": "FIXED_BENEFIT",
            "parameters": {"paymentRate": "0.333333", "roundingMode": "DOWN", "roundingUnit": 1},
        }
    )
    results = [calculate(parsed, 30_000_000) for _ in range(100)]
    assert {x.final_amount for x in results} == {9_999_990}
    assert results[0].payment_rate == Decimal("0.333333")


def test_fixed_benefit_deduction_and_no_negative() -> None:
    parsed = rule(
        {
            "schemaVersion": 1,
            "ruleType": "CALCULATION",
            "strategy": "FIXED_BENEFIT",
            "parameters": {"paymentRate": "1.0", "deductionAmount": 1000},
        }
    )
    assert calculate(parsed, 30_000).final_amount == 29_000
    with pytest.raises(DomainError):
        calculate(parsed, 100)


def test_hospital_daily_inclusive_and_max_days() -> None:
    parsed = rule(
        {
            "schemaVersion": 1,
            "ruleType": "CALCULATION",
            "strategy": "HOSPITAL_DAILY",
            "parameters": {
                "dailyAmountSource": "CONTRACT_COVERAGE_INSURED_AMOUNT",
                "dayCalculationMethod": "INCLUSIVE",
                "maxDays": 3,
            },
        }
    )
    result = calculate(parsed, 50_000, date(2026, 1, 1), date(2026, 1, 10))
    assert result.final_amount == 150_000
    assert result.inputs["payable_days"] == 3


def test_hospital_daily_missing_dates_fails_not_zero() -> None:
    parsed = rule(
        {
            "schemaVersion": 1,
            "ruleType": "CALCULATION",
            "strategy": "HOSPITAL_DAILY",
            "parameters": {
                "dailyAmountSource": "CONTRACT_COVERAGE_INSURED_AMOUNT",
                "dayCalculationMethod": "INCLUSIVE",
            },
        }
    )
    with pytest.raises(DomainError) as exc:
        calculate(parsed, 50_000)
    assert exc.value.code == "MISSING_CALCULATION_INPUT"


def test_arbitrary_formula_and_float_are_rejected() -> None:
    with pytest.raises(ValidationError):
        rule(
            {
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "FIXED_BENEFIT",
                "formula": "eval(x)",
                "parameters": {"paymentRate": "1"},
            }
        )
