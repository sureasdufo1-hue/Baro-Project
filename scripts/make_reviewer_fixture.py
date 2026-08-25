"""One-off generator for the reviewer-journey E2E additional-document fixture."""

from pathlib import Path

import fitz

FONT = r"C:\Windows\Fonts\malgun.ttf"
OUT = Path(__file__).resolve().parents[1] / "tests" / "e2e" / "fixtures" / "medical-opinion.png"

doc = fitz.open()
page = doc.new_page(width=612, height=400)
lines = [
    "진단확인서 (소견서)",
    "환자명: 김검토",
    "진단명: 급성 심근경색 (I21.0)",
    "진단일: 2026-08-10",
    "입원일: 2026-08-01",
    "퇴원일: 2026-08-14",
    "발행일: 2026-08-20",
    "의료기관: 서울종합병원",
]
y = 60
for index, line in enumerate(lines):
    page.insert_text(
        fitz.Point(50, y),
        line,
        fontsize=22 if index == 0 else 15,
        fontfile=FONT,
        fontname="malgun",
    )
    y += 45
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_bytes(page.get_pixmap(dpi=200).tobytes("png"))
print(f"wrote {OUT}")
