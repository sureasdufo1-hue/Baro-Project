import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from sqlalchemy import select  # noqa: E402

from domain.user.models import User, UserRole  # noqa: E402
from infrastructure.database.session import SessionLocal  # noqa: E402
from shared.security.passwords import hash_password  # noqa: E402

STAFF_ACCOUNTS = {
    "BOOTSTRAP_ADMIN": UserRole.SYSTEM_ADMIN,
    "BOOTSTRAP_ADJUSTER": UserRole.ADJUSTER,
}


def main() -> None:
    if os.getenv("APP_ENV") == "production":
        raise RuntimeError("Administrator bootstrap is disabled in production")
    created: list[str] = []
    skipped: list[str] = []
    for prefix, role in STAFF_ACCOUNTS.items():
        email = os.getenv(f"{prefix}_EMAIL")
        password = os.getenv(f"{prefix}_PASSWORD")
        if not email or not password:
            continue
        with SessionLocal.begin() as db:
            existing = db.scalar(select(User).where(User.email == email.lower()))
            if existing is not None:
                if existing.role is not role:
                    raise RuntimeError(
                        f"User {email} already exists with role {existing.role.value}, "
                        f"expected {role.value}"
                    )
                skipped.append(email.lower())
                continue
            db.add(
                User(
                    email=email.lower(),
                    password_hash=hash_password(password),
                    display_name=f"Development {role.value}",
                    role=role,
                )
            )
            created.append(email.lower())
    for email in created:
        print(f"created: {email}")
    for email in skipped:
        print(f"exists: {email}")


if __name__ == "__main__":
    main()
