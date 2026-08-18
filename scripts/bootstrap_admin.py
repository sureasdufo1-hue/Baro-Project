import os

from sqlalchemy import select

from domain.user.models import User, UserRole
from infrastructure.database.session import SessionLocal
from shared.security.passwords import hash_password


def main() -> None:
    if os.getenv("APP_ENV") == "production":
        raise RuntimeError("Administrator bootstrap is disabled in production")
    email = os.getenv("BOOTSTRAP_ADMIN_EMAIL")
    password = os.getenv("BOOTSTRAP_ADMIN_PASSWORD")
    if not email or not password:
        raise RuntimeError("Set BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD explicitly")
    with SessionLocal.begin() as db:
        if db.scalar(select(User).where(User.email == email.lower())):
            raise RuntimeError("Administrator already exists")
        db.add(
            User(
                email=email.lower(),
                password_hash=hash_password(password),
                display_name="Development Administrator",
                role=UserRole.SYSTEM_ADMIN,
            )
        )


if __name__ == "__main__":
    main()
