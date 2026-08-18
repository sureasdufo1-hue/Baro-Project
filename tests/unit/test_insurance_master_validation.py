import pytest
from pydantic import ValidationError

from apps.api.app.routes.insurance_master import PolicyVersionCreate, ProductVersionCreate


def test_product_version_rejects_reversed_period() -> None:
    with pytest.raises(ValidationError):
        ProductVersionCreate(
            product_id="00000000-0000-0000-0000-000000000001",
            version_name="V1",
            sale_start_date="2026-12-31",
            sale_end_date="2026-01-01",
        )


def test_policy_version_rejects_reversed_period() -> None:
    with pytest.raises(ValidationError):
        PolicyVersionCreate(
            policy_id="00000000-0000-0000-0000-000000000001",
            version_code="V1",
            effective_from="2026-12-31",
            effective_to="2026-01-01",
        )
