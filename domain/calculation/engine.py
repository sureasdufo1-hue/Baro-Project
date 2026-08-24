from __future__ import annotations

import enum
from dataclasses import dataclass
from datetime import date
from decimal import ROUND_DOWN, ROUND_HALF_UP, ROUND_UP, Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from shared.errors import DomainError


class CalculationStrategyName(enum.StrEnum):
    FIXED_BENEFIT = "FIXED_BENEFIT"
    HOSPITAL_DAILY = "HOSPITAL_DAILY"
    PROPORTIONAL_DISABILITY = "PROPORTIONAL_DISABILITY"
    INDEMNITY = "INDEMNITY"
    MEDICAL_EXPENSE = "MEDICAL_EXPENSE"


class CalculationParameters(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    payment_rate: Decimal | None = Field(default=None, alias="paymentRate", ge=0)
    daily_amount_source: Literal["CONTRACT_COVERAGE_INSURED_AMOUNT"] | None = Field(
        default=None, alias="dailyAmountSource"
    )
    day_calculation_method: Literal["INCLUSIVE", "EXCLUSIVE"] | None = Field(
        default=None, alias="dayCalculationMethod"
    )
    max_days: int | None = Field(default=None, alias="maxDays", gt=0)

    # For PROPORTIONAL_DISABILITY
    min_disability_rate: Decimal | None = Field(
        default=Decimal("0.03"), alias="minDisabilityRate", ge=0, le=1
    )
    max_disability_rate: Decimal | None = Field(
        default=Decimal("1.00"), alias="maxDisabilityRate", ge=0, le=1
    )

    # For INDEMNITY
    indemnity_rate: Decimal | None = Field(default=None, alias="indemnityRate", ge=0, le=1)

    # For MEDICAL_EXPENSE
    expense_type: Literal["BENEFIT", "NON_BENEFIT", "TOTAL"] | None = Field(
        default=None, alias="expenseType"
    )
    copayment_rate: Decimal | None = Field(default=None, alias="copaymentRate", ge=0, le=1)
    min_deduction_amount: int | None = Field(default=0, alias="minDeductionAmount", ge=0)

    deduction_amount: int = Field(default=0, alias="deductionAmount", ge=0)
    rounding_mode: Literal["HALF_UP", "DOWN", "UP"] = Field(default="DOWN", alias="roundingMode")
    rounding_unit: int = Field(default=1, alias="roundingUnit", gt=0)


class CalculationRule(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    schema_version: Literal[1] = Field(alias="schemaVersion")
    rule_type: Literal["CALCULATION"] = Field(alias="ruleType")
    strategy: CalculationStrategyName
    parameters: CalculationParameters

    @model_validator(mode="after")
    def strategy_inputs(self) -> CalculationRule:
        if (
            self.strategy is CalculationStrategyName.FIXED_BENEFIT
            and self.parameters.payment_rate is None
        ):
            raise ValueError("FIXED_BENEFIT requires paymentRate")
        if self.strategy is CalculationStrategyName.HOSPITAL_DAILY and (
            self.parameters.daily_amount_source is None
            or self.parameters.day_calculation_method is None
        ):
            raise ValueError("HOSPITAL_DAILY parameters are incomplete")
        if (
            self.strategy is CalculationStrategyName.INDEMNITY
            and self.parameters.indemnity_rate is None
        ):
            raise ValueError("INDEMNITY requires indemnityRate")
        if (
            self.strategy is CalculationStrategyName.MEDICAL_EXPENSE
            and self.parameters.copayment_rate is None
        ):
            raise ValueError("MEDICAL_EXPENSE requires copaymentRate")
        return self


@dataclass(frozen=True)
class CalculationResult:
    gross_amount: int
    deduction_amount: int
    final_amount: int
    payment_rate: Decimal | None
    formula: str
    inputs: dict[str, str | int]


def round_krw(value: Decimal, mode: str, unit: int) -> int:
    rounding = {"HALF_UP": ROUND_HALF_UP, "DOWN": ROUND_DOWN, "UP": ROUND_UP}[mode]
    rounded_units = (value / Decimal(unit)).quantize(Decimal("1"), rounding=rounding)
    return int(rounded_units * unit)


def calculate(
    rule: CalculationRule,
    insured_amount: int,
    admission_date: date | None = None,
    discharge_date: date | None = None,
    disability_rate: Decimal | None = None,
    actual_loss: int | None = None,
    copayment_amount: int | None = None,
    non_benefit_amount: int | None = None,
) -> CalculationResult:
    if insured_amount < 0:
        raise DomainError("INVALID_CALCULATION_INPUT", "Insured amount cannot be negative", 422)
    params = rule.parameters
    applied_rate: Decimal | None = params.payment_rate
    inputs: dict[str, str | int] = {}

    if rule.strategy is CalculationStrategyName.FIXED_BENEFIT:
        assert params.payment_rate is not None
        raw = Decimal(insured_amount) * params.payment_rate
        formula = "insured_amount * payment_rate"
        inputs = {
            "insured_amount": insured_amount,
            "payment_rate": str(params.payment_rate),
        }
    elif rule.strategy is CalculationStrategyName.HOSPITAL_DAILY:
        if admission_date is None or discharge_date is None:
            raise DomainError(
                "MISSING_CALCULATION_INPUT", "Verified hospitalization dates are required", 422
            )
        days = (discharge_date - admission_date).days + (
            1 if params.day_calculation_method == "INCLUSIVE" else 0
        )
        if days < 0:
            raise DomainError("INVALID_CALCULATION_INPUT", "Hospitalization period is invalid", 422)
        payable_days = min(days, params.max_days) if params.max_days else days
        raw = Decimal(insured_amount) * Decimal(payable_days)
        formula = "daily_amount * payable_days"
        inputs = {
            "daily_amount": insured_amount,
            "payable_days": payable_days,
            "admission_date": admission_date.isoformat(),
            "discharge_date": discharge_date.isoformat(),
        }
    elif rule.strategy is CalculationStrategyName.PROPORTIONAL_DISABILITY:
        rate = disability_rate if disability_rate is not None else params.payment_rate
        if rate is None:
            raise DomainError(
                "MISSING_CALCULATION_INPUT", "Verified disability rate is required", 422
            )
        min_rate = (
            params.min_disability_rate
            if params.min_disability_rate is not None
            else Decimal("0.03")
        )
        max_rate = (
            params.max_disability_rate
            if params.max_disability_rate is not None
            else Decimal("1.00")
        )
        if rate < min_rate:
            raw = Decimal(0)
            applied_rate = rate
            formula = f"disability_rate ({rate}) < min_rate ({min_rate}) -> 0"
            inputs = {
                "insured_amount": insured_amount,
                "disability_rate": str(rate),
                "min_disability_rate": str(min_rate),
            }
        else:
            eff_rate = min(rate, max_rate)
            applied_rate = eff_rate
            raw = Decimal(insured_amount) * eff_rate
            formula = "insured_amount * disability_rate"
            inputs = {
                "insured_amount": insured_amount,
                "disability_rate": str(eff_rate),
            }
    elif rule.strategy is CalculationStrategyName.INDEMNITY:
        if actual_loss is None:
            raise DomainError(
                "MISSING_CALCULATION_INPUT", "Verified actual loss amount is required", 422
            )
        indemnity_rate = params.indemnity_rate or Decimal("1.0")
        applied_rate = indemnity_rate
        raw = min(Decimal(insured_amount), Decimal(actual_loss) * indemnity_rate)
        formula = "min(insured_amount, actual_loss * indemnity_rate)"
        inputs = {
            "insured_amount": insured_amount,
            "actual_loss": actual_loss,
            "indemnity_rate": str(indemnity_rate),
        }
    elif rule.strategy is CalculationStrategyName.MEDICAL_EXPENSE:
        copay = Decimal(copayment_amount or 0)
        non_ben = Decimal(non_benefit_amount or 0)
        if params.expense_type == "BENEFIT":
            if copayment_amount is None:
                raise DomainError(
                    "MISSING_CALCULATION_INPUT",
                    "Verified copayment expense is required",
                    422,
                )
            target_expense = copay
        elif params.expense_type == "NON_BENEFIT":
            if non_benefit_amount is None:
                raise DomainError(
                    "MISSING_CALCULATION_INPUT",
                    "Verified non-benefit expense is required",
                    422,
                )
            target_expense = non_ben
        else:
            if copayment_amount is None and non_benefit_amount is None:
                raise DomainError(
                    "MISSING_CALCULATION_INPUT",
                    "Verified copayment or non-benefit expense is required",
                    422,
                )
            target_expense = copay + non_ben

        copay_rate = params.copayment_rate or Decimal("0.20")
        applied_rate = Decimal("1.0") - copay_rate
        min_ded = Decimal(params.min_deduction_amount or 0)
        calc_deduct = max(min_ded, target_expense * copay_rate)
        raw = max(Decimal(0), min(Decimal(insured_amount), target_expense - calc_deduct))
        formula = (
            "min(insured_amount, medical_expense - "
            "max(min_deduction, medical_expense * copayment_rate))"
        )
        inputs = {
            "insured_amount": insured_amount,
            "medical_expense": int(target_expense),
            "copayment_rate": str(copay_rate),
            "deducted_copayment": int(calc_deduct),
        }
    else:
        raise DomainError(
            "UNSUPPORTED_CALCULATION_STRATEGY", "Calculation strategy is unsupported", 422
        )

    gross = round_krw(raw, params.rounding_mode, params.rounding_unit)
    final = gross - params.deduction_amount
    if final < 0:
        raise DomainError("CALCULATION_FAILED", "Calculated amount cannot be negative", 422)
    return CalculationResult(gross, params.deduction_amount, final, applied_rate, formula, inputs)
