from domain.user.models import ConsentType, UserRole, UserStatus


def test_required_roles_and_statuses_are_typed() -> None:
    assert UserRole.SYSTEM_ADMIN.value == "SYSTEM_ADMIN"
    assert UserRole.ADJUSTER.value == "ADJUSTER"
    assert UserStatus.LOCKED.value == "LOCKED"
    assert ConsentType.SENSITIVE_INFORMATION.value == "SENSITIVE_INFORMATION"
