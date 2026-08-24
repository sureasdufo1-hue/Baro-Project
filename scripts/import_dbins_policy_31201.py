from __future__ import annotations

import hashlib
import json
import shutil
import sqlite3
from pathlib import Path
from typing import Any

import pymupdf

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "dbins_poc" / "dbins_policy_seed.sqlite3"
RUNTIME = ROOT / "dbins_poc" / "runtime" / "dbins_policy.sqlite3"
POLICY = (
    ROOT
    / "dbins_poc"
    / "storage"
    / "policies"
    / "db_insurance"
    / "31201"
    / "2601"
    / "policy_31084_03_20260401.pdf"
)
SOURCE_URL = (
    "https://www.idbins.com/cYakgwanDown.do?FilePath="
    "InsProduct/%EC%95%BD%EA%B4%80_31084%2803%29_20260401.pdf"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    if not POLICY.exists() or POLICY.read_bytes()[:4] != b"%PDF":
        raise RuntimeError("Verified PDF download is required before import")
    RUNTIME.parent.mkdir(parents=True, exist_ok=True)
    if not RUNTIME.exists():
        shutil.copy2(BASELINE, RUNTIME)

    document: Any = pymupdf.open(POLICY)  # type: ignore[no-untyped-call]
    pages: list[tuple[int, str]] = [
        (index + 1, page.get_text("text")) for index, page in enumerate(document)
    ]
    full_text = "\n".join(text for _, text in pages)
    if "New간편암건강보험2601" not in full_text or "보험약관" not in full_text[:20000]:
        raise RuntimeError("Downloaded PDF did not pass product/policy validation")
    digest = sha256(POLICY)

    with sqlite3.connect(RUNTIME) as db:
        existing = db.execute(
            "SELECT id FROM policy_documents WHERE sha256=?", (digest,)
        ).fetchone()
        if existing:
            print(json.dumps({"status": "REUSED", "document_id": existing[0], "sha256": digest}))
            return
        cursor = db.execute(
            """INSERT INTO policy_documents
            (version_id,document_type,file_name,local_path,source_url,sha256,page_count,
             text_layer,source_type) VALUES (2,'POLICY',?,?,?,?,?,1,'LIVE')""",
            (POLICY.name, str(POLICY), SOURCE_URL, digest, len(pages)),
        )
        if cursor.lastrowid is None:
            raise RuntimeError("Policy document insert did not return an identifier")
        document_id = cursor.lastrowid
        db.executemany(
            "INSERT INTO policy_pages(document_id,page_number,raw_text) VALUES (?,?,?)",
            [(document_id, page_number, text) for page_number, text in pages],
        )

        evidence_pages = {2: 79, 3: 91}
        for coverage_id, page_number in evidence_pages.items():
            page_text = pages[page_number - 1][1]
            db.execute(
                """INSERT INTO source_references
                (coverage_id,document_id,page_number,article_no,source_text,reference_type)
                VALUES (?,?,?,?,?,'POLICY_PAYMENT_PENDING_REVIEW')""",
                (coverage_id, document_id, page_number, "1. 보험금의 지급사유", page_text),
            )
            db.execute(
                """INSERT INTO source_references
                (coverage_id,document_id,page_number,article_no,source_text,reference_type)
                VALUES (?,?,?,?,?,'POLICY_KCD_PENDING_REVIEW')""",
                (coverage_id, document_id, 203, "별표2", pages[202][1]),
            )
            db.execute(
                """INSERT INTO disease_codes
                (coverage_id,disease_group,included_codes,raw_text,source_status)
                VALUES (?,?,?,?,'POLICY_EXTRACTED_PENDING_REVIEW')""",
                (
                    coverage_id,
                    "악성신생물(암)",
                    json.dumps(
                        [
                            "C00-C14",
                            "C15-C26",
                            "C30-C39",
                            "C40-C41",
                            "C43-C44",
                            "C45-C49",
                            "C50",
                            "C51-C58",
                            "C60-C63",
                            "C64-C68",
                            "C69-C72",
                            "C73-C75",
                            "C76-C80",
                            "C81-C96",
                            "C97",
                            "D45",
                            "D46",
                            "D47.1",
                            "D47.3",
                            "D47.4",
                            "D47.5",
                        ],
                        ensure_ascii=False,
                    ),
                    pages[202][1],
                ),
            )
            db.execute(
                """INSERT INTO validation_logs
                (entity_type,entity_id,rule_code,status,message)
                VALUES ('coverage',?,'POLICY_ACQUIRED_PENDING_HUMAN_REVIEW','REVIEW',?)""",
                (
                    coverage_id,
                    "공식 POLICY와 KCD 별표를 확보했으나 지급 Rule/KCD 사람 검증 전 승격 금지",
                ),
            )
            db.execute(
                """INSERT INTO validation_logs
                (entity_type,entity_id,rule_code,status,message)
                VALUES ('coverage',?,'DISCLOSURE_CODE_MAPPING_REVIEW','REVIEW',?)""",
                (
                    coverage_id,
                    "내부 product_code 31201과 공시 파일 코드 31084(03)의 매핑 검토 필요",
                ),
            )
        db.commit()
    print(
        json.dumps(
            {
                "status": "IMPORTED_PENDING_HUMAN_REVIEW",
                "document_id": document_id,
                "pages": len(pages),
                "sha256": digest,
            }
        )
    )


if __name__ == "__main__":
    main()
