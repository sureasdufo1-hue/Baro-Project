import pytest

from domain.document.service import detected_mime, safe_filename, validate_file
from infrastructure.security.malware import DevelopmentMalwareScanner, ScanResult
from shared.errors import DomainError


@pytest.mark.parametrize(
    ("filename", "mime", "content"),
    [
        ("a.pdf", "application/pdf", b"%PDF-1.4\n%%EOF"),
        ("a.jpg", "image/jpeg", b"\xff\xd8\xff\xe0test"),
        ("a.png", "image/png", b"\x89PNG\r\n\x1a\ntest"),
        ("a.heic", "image/heic", b"\x00\x00\x00\x18ftypheicdata"),
    ],
)
def test_supported_signatures(filename: str, mime: str, content: bytes) -> None:
    assert validate_file(filename, mime, content, 100) == mime
    assert detected_mime(content) == mime


def test_disguised_executable_unsupported_type_and_size_are_rejected() -> None:
    with pytest.raises(DomainError) as disguised:
        validate_file("attack.pdf", "application/pdf", b"MZ executable", 100)
    assert disguised.value.code == "INVALID_FILE_SIGNATURE"
    with pytest.raises(DomainError) as unsupported:
        validate_file("notes.txt", "text/plain", b"hello", 100)
    assert unsupported.value.code == "UNSUPPORTED_FILE_FORMAT"
    with pytest.raises(DomainError) as too_large:
        validate_file("large.pdf", "application/pdf", b"%PDF-" + b"x" * 100, 20)
    assert too_large.value.code == "FILE_TOO_LARGE"


def test_filename_is_display_only_and_sanitized() -> None:
    assert safe_filename("../../<script>.pdf") == "_script_.pdf"
    assert len(safe_filename("a" * 300 + ".pdf")) == 255


def test_development_scanner_distinguishes_all_results() -> None:
    scanner = DevelopmentMalwareScanner()
    assert scanner.scan(b"safe") is ScanResult.CLEAN
    assert scanner.scan(b"CLAIMLENS_TEST_INFECTED") is ScanResult.INFECTED
    assert scanner.scan(b"CLAIMLENS_TEST_SCAN_FAILURE") is ScanResult.SCAN_FAILED
