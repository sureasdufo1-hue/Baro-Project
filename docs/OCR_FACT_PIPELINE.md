# OCR / Fact Verification Pipeline

```text
READY + CLEAN MedicalDocument
-> RQ document-ocr job
-> versioned OCRResult
-> schema-validated ExtractedFact
-> user confirm / modify / reject
-> VerifiedFact
```

OCR과 구조화 추출은 Provider Interface 뒤에 있으며 HTTP 요청에서 실행하지 않습니다. 개발 Adapter는
명시적인 Fixture Fact만 처리하고 Production에서는 활성화되지 않습니다. Prompt는
`prompts/medical-fact-extraction/v1.md`로 Version 관리합니다.

OCRResult 재처리는 기존 Row를 덮어쓰지 않고 새 결과를 생성합니다. ExtractedFact에는 Provider/Model,
Prompt Version, Confidence, 문서, Page와 선택적 normalized bounding box가 보존됩니다. Bounding box가
없는 Provider에는 가짜 좌표를 생성하지 않습니다.

VerifiedFact는 ExtractedFact와 분리됩니다. 사용자 수정 시 원본 AI 값은 그대로 남고 확정값과 수정
사유가 별도 Row에 저장됩니다. `AI_ONLY` 또는 추출 Confidence는 보험금 판단이나 지급확률이 아닙니다.

## API

- `POST /api/claims/{claim_id}/analysis`
- `POST /api/documents/{document_id}/ocr`
- `GET /api/claims/{claim_id}/analysis-status`
- `GET /api/claims/{claim_id}/facts`
- `POST /api/facts/{fact_id}/confirm|modify|reject`

## Security

문서와 Fact 모두 Claim 소유권을 검증합니다. OCR Text는 untrusted data이며 Prompt instruction으로
실행하지 않습니다. Raw OCR/AI 응답은 일반 Application Log에 출력하지 않습니다.

CODEX-07은 `USER_CONFIRMED`, `USER_MODIFIED` 등 허용된 VerifiedFact만 입력으로 사용해야 하며 AI가
PolicyVersion, 지급여부, 지급률 또는 보험금액을 만들 수 없습니다.
