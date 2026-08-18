# MedicalDocument / Private Storage

CODEX-05는 Claim 아래에 원본 의료·보험 증빙 Metadata를 등록하고 Binary를 RDB 외부의 비공개
Object Storage에 보관합니다.

## 신뢰 경계

```text
Authenticated owner
-> size / extension / declared MIME / server signature validation
-> SHA-256
-> malware scan CLEAN
-> private object storage
-> READY MedicalDocument
```

검사 실패나 감염, Storage 실패는 절대 `READY`로 승격하지 않습니다. 사용자가 선택한 문서종류는
`document_type_source=USER`로 보존하며 AI 분류를 흉내 내지 않습니다.

## Local Development

`LOCAL_PRIVATE` adapter는 `LOCAL_OBJECT_STORAGE_ROOT` 아래에 파일을 저장하며 Web public directory나
영구 Public URL을 사용하지 않습니다. Docker Compose에서는 `document_storage` private volume을
사용합니다. 운영환경에서는 이 adapter 대신 private S3-compatible adapter와 실제 Malware Scanner를
구성해야 합니다. `DEVELOPMENT` scanner는 `APP_ENV=production`에서 CLEAN 결과를 제공하지 않습니다.

## API

- `POST /api/claims/{claim_id}/documents`: Multipart `documentType` + `file`
- `GET /api/claims/{claim_id}/documents`: 소유 Claim의 활성 문서 목록
- `GET|PATCH|DELETE /api/documents/{document_id}`: Metadata, 유형 수정, soft-delete
- `GET /api/documents/{document_id}/content`: 인증된 inline view
- `GET /api/documents/{document_id}/content?download=true`: 인증된 download

일반 응답에는 `storage_key`나 Public URL이 없습니다. Content 응답에는 `nosniff`, sandbox CSP,
`private, no-store`가 적용됩니다.

## Limits

파일당 크기, Claim당 파일 수, Claim당 전체 크기는 환경변수로 설정합니다. 현재 허용 형식은 PDF,
JPEG, PNG, HEIC이며 확장자만으로 승인하지 않습니다. 같은 Claim의 동일 SHA-256은 중복으로
거절합니다.

## CODEX-06 Boundary

OCR은 `processing_status=READY`이고 `malware_scan_status=CLEAN`인 문서만 입력으로 사용해야 합니다.
현재 구현은 OCRResult, 추출 Fact 또는 가짜 분석결과를 생성하지 않습니다.
