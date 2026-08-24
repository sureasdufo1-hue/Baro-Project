from __future__ import annotations

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


def test_proportional_disability_calculation() -> None:
    parsed = rule(
        {
            "schemaVersion": 1,
            "ruleType": "CALCULATION",
            "strategy": "PROPORTIONAL_DISABILITY",
            "parameters": {
                "minDisabilityRate": "0.03",
                "maxDisabilityRate": "1.00",
                "deductionAmount": 0,
            },
        }
    )
    # 20% 후유장해: 1억원 * 20% = 2,000만원
    res20 = calculate(parsed, 100_000_000, disability_rate=Decimal("0.20"))
    assert res20.final_amount == 20_000_000
    assert res20.payment_rate == Decimal("0.20")

    # 2% 후유장해: 3% 미만 면책 -> 0원
    res02 = calculate(parsed, 100_000_000, disability_rate=Decimal("0.02"))
    assert res02.final_amount == 0

    # 100% 후유장해: 1억원 * 100% = 1억원
    res100 = calculate(parsed, 100_000_000, disability_rate=Decimal("1.00"))
    assert res100.final_amount == 100_000_000


def test_indemnity_calculation() -> None:
    parsed = rule(
        {
            "schemaVersion": 1,
            "ruleType": "CALCULATION",
            "strategy": "INDEMNITY",
            "parameters": {
                "indemnityRate": "1.0",
                "deductionAmount": 200_000,
            },
        }
    )
    # 손해액 500만원, 자기부담금 20만원 -> 480만원
    res = calculate(parsed, 100_000_000, actual_loss=5_000_000)
    assert res.final_amount == 4_800_000
    assert res.deduction_amount == 200_000

    # 가입금액 한도(1,000만원) 초과 손해액(1,500만원) -> 1,000만원 - 20만원 = 980만원
    res_limit = calculate(parsed, 10_000_000, actual_loss=15_000_000)
    assert res_limit.final_amount == 9_800_000


def test_medical_expense_benefit_and_non_benefit() -> None:
    # 급여 실손의료비: 20% 공제 (최소공제 1만원)
    parsed_ben = rule(
        {
            "schemaVersion": 1,
            "ruleType": "CALCULATION",
            "strategy": "MEDICAL_EXPENSE",
            "parameters": {
                "copaymentRate": "0.20",
                "minDeductionAmount": 10000,
            },
        }
    )
    # 본인부담금 100만원 -> 공제 20만원 -> 80만원 지급
    res_ben = calculate(parsed_ben, 50_000_000, copayment_amount=1_000_000)
    assert res_ben.final_amount == 800_000

    # 비급여 실손의료비: 30% 공제 (최소공제 3만원)
    parsed_non = rule(
        {
            "schemaVersion": 1,
            "ruleType": "CALCULATION",
            "strategy": "MEDICAL_EXPENSE",
            "parameters": {
                "copaymentRate": "0.30",
                "minDeductionAmount": 30000,
            },
        }
    )
    # 비급여 200만원 -> 공제 60만원 -> 140만원 지급
    res_non = calculate(parsed_non, 50_000_000, non_benefit_amount=2_000_000)
    assert res_non.final_amount == 1_400_000


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
