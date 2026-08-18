import uuid

import pytest

from domain.review.models import Review, ReviewStatus, ReviewType
from domain.review.service import ReviewStateMachine, approve_review, mark_undetermined
from shared.errors import DomainError


def review(status: ReviewStatus) -> Review:
    return Review(
        claim_id=uuid.uuid4(),
        review_type=ReviewType.ELIGIBILITY_REVIEW,
        review_status=status,
        reason="Rule conflict",
        previous_result={"eligibility_result": "MANUAL_REVIEW"},
    )


def test_review_state_machine_happy_path() -> None:
    item = review(ReviewStatus.REQUESTED)
    ReviewStateMachine.transition(item, ReviewStatus.ASSIGNED)
    ReviewStateMachine.transition(item, ReviewStatus.IN_PROGRESS)
    approve_review(item, "Evidence supports the automatic result")
    assert item.review_status is ReviewStatus.APPROVED
    assert item.final_result == item.previous_result
    ReviewStateMachine.transition(item, ReviewStatus.COMPLETED)


def test_review_state_machine_rejects_direct_completion() -> None:
    with pytest.raises(DomainError, match="cannot transition"):
        ReviewStateMachine.transition(review(ReviewStatus.REQUESTED), ReviewStatus.COMPLETED)


def test_undetermined_is_not_not_payable_and_requires_reason() -> None:
    item = review(ReviewStatus.IN_PROGRESS)
    mark_undetermined(item, "Medical causation cannot be determined", None)
    assert item.review_status is ReviewStatus.UNDETERMINED
    assert item.final_result == {"eligibility_result": "UNDETERMINED"}
    with pytest.raises(DomainError):
        mark_undetermined(review(ReviewStatus.IN_PROGRESS), "", None)
