import pytest

from domain.claim.models import Claim, ClaimStatus, ClaimType
from domain.claim.service import ClaimStateMachine
from shared.errors import DomainError


def draft_claim() -> Claim:
    return Claim(
        claim_number="CLM-TEST",
        claim_type=ClaimType.DISEASE,
        status=ClaimStatus.DRAFT,
        title="Test",
    )


def test_draft_can_require_documents_or_cancel() -> None:
    claim = draft_claim()
    ClaimStateMachine.transition(claim, ClaimStatus.DOCUMENT_REQUIRED)
    assert claim.status is ClaimStatus.DOCUMENT_REQUIRED
    claim = draft_claim()
    ClaimStateMachine.transition(claim, ClaimStatus.CANCELLED)
    assert claim.status is ClaimStatus.CANCELLED


@pytest.mark.parametrize(
    ("source", "target"),
    [(ClaimStatus.DRAFT, ClaimStatus.COMPLETED), (ClaimStatus.CANCELLED, ClaimStatus.ASSESSING)],
)
def test_invalid_transitions_are_rejected(source: ClaimStatus, target: ClaimStatus) -> None:
    claim = draft_claim()
    claim.status = source
    with pytest.raises(DomainError, match="cannot transition") as exc:
        ClaimStateMachine.transition(claim, target)
    assert exc.value.code == "INVALID_CLAIM_STATE_TRANSITION"
