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
    def strategy_inputs(self) -> "CalculationRule":
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
) -> CalculationResult:
    if insured_amount < 0:
        raise DomainError("INVALID_CALCULATION_INPUT", "Insured amount cannot be negative", 422)
    params = rule.parameters
    if rule.strategy is CalculationStrategyName.FIXED_BENEFIT:
        assert params.payment_rate is not None
        raw = Decimal(insured_amount) * params.payment_rate
        formula = "insured_amount * payment_rate"
        inputs: dict[str, str | int] = {
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
    else:
        raise DomainError(
            "UNSUPPORTED_CALCULATION_STRATEGY", "Calculation strategy is unsupported", 422
        )
    gross = round_krw(raw, params.rounding_mode, params.rounding_unit)
    final = gross - params.deduction_amount
    if final < 0:
        raise DomainError("CALCULATION_FAILED", "Calculated amount cannot be negative", 422)
    return CalculationResult(
        gross, params.deduction_amount, final, params.payment_rate, formula, inputs
    )
