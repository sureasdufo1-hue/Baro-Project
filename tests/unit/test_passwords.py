from shared.security.passwords import hash_password, verify_password


def test_password_is_hashed_and_verifiable() -> None:
    password = "correct-horse-battery-staple"
    password_hash = hash_password(password)
    assert password_hash != password
    assert password not in password_hash
    assert verify_password(password, password_hash)
    assert not verify_password("incorrect-password", password_hash)
