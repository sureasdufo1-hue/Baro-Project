"""Local Tesseract OCR service implementing the ClaimLens HTTPOCRProvider contract.

POST /extract (multipart file) -> {"text": str, "confidence": float, "pages": [...]}
"""

import io
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

import fitz
import pytesseract
from fastapi import FastAPI, File, HTTPException, UploadFile
from PIL import Image

app = FastAPI(title="claimlens-local-ocr")

LANGS = "kor"
TESSERACT_CONFIG = "--psm 6"
DPI = 200
MAX_BYTES = 20 * 1024 * 1024


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


def _render(data: bytes) -> list[tuple[int, Image.Image, int, int]]:
    pages: list[tuple[int, Image.Image, int, int]] = []
    if data[:5] == b"%PDF-":
        with fitz.open(stream=data, filetype="pdf") as document:
            for index, page in enumerate(document, start=1):
                pixmap = page.get_pixmap(dpi=DPI)
                image = Image.frombytes("RGB", (pixmap.width, pixmap.height), pixmap.samples)
                pages.append((index, image, pixmap.width, pixmap.height))
    else:
        image = Image.open(io.BytesIO(data))
        image = image.convert("RGB")
        pages.append((1, image, image.width, image.height))
    return pages


def _ocr_page(image: Image.Image) -> tuple[list[str], list[float]]:
    payload = pytesseract.image_to_data(
        image, lang=LANGS, config=TESSERACT_CONFIG, output_type=pytesseract.Output.DICT
    )
    lines: dict[tuple[int, int, int], list[str]] = {}
    confidences: list[float] = []
    for index in range(len(payload["text"])):
        word = (payload["text"][index] or "").strip()
        if not word:
            continue
        try:
            confidence = float(payload["conf"][index])
        except (TypeError, ValueError):
            continue
        if confidence < 0:
            continue
        key = (
            payload["block_num"][index],
            payload["par_num"][index],
            payload["line_num"][index],
        )
        lines.setdefault(key, []).append(word)
        confidences.append(confidence)
    ordered = sorted(lines.items(), key=lambda item: min(item[0]))
    text = "\n".join(" ".join(words) for _, words in ordered)
    return [text], confidences


@app.post("/extract")
async def extract(file: UploadFile = File(...)) -> dict[str, Any]:
    data = await file.read()
    if len(data) > MAX_BYTES:
        raise HTTPException(status_code=413, detail="file too large")
    try:
        rendered = _render(data)
    except Exception as exc:
        raise HTTPException(status_code=422, detail="unsupported document") from exc

    texts: list[str] = []
    page_meta: list[dict[str, Any]] = []
    all_confidences: list[float] = []
    for number, image, width, height in rendered:
        page_text, confidences = _ocr_page(image)
        texts.extend(page_text)
        all_confidences.extend(confidences)
        page_meta.append({"page": number, "width": width, "height": height})

    if all_confidences:
        mean = Decimal(str(sum(all_confidences) / len(all_confidences) / 100.0))
        confidence = mean.quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)
    else:
        confidence = Decimal("0.0000")

    return {
        "text": "\n".join(texts)[:100_000],
        "confidence": float(confidence),
        "pages": page_meta,
    }
