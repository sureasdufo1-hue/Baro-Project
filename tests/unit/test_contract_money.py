import pytest
from pydantic import ValidationError

from apps.api.app.routes.contracts import CoverageInput


@pytest.mark.parametrize("amount", [1, 10000, 1000000, 30000000, 150000000])
def test_money_values_remain_exact_integers(amount: int) -> None:
    value = CoverageInput(
        coverage_id="00000000-0000-0000-0000-000000000001",
        coverage_name_snapshot="TEST",
        insured_amount=amount,
    )
    assert value.insured_amount == amount and isinstance(value.insured_amount, int)


def test_float_and_negative_money_are_rejected() -> None:
    with pytest.raises(ValidationError):
        CoverageInput(
            coverage_id="00000000-0000-0000-0000-000000000001",
            coverage_name_snapshot="TEST",
            insured_amount=-1,
        )
    with pytest.raises(ValidationError):
        CoverageInput(
            coverage_id="00000000-0000-0000-0000-000000000001",
            coverage_name_snapshot="TEST",
            insured_amount=1.5,
        )
