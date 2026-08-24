# 로컬 프로바이더 어댑터 검증 결과 (MinIO / ClamAV / OCR / AI)

> 클라우드 배제·$0 운영 전제. 모든 프로덕션 어댑터를 자체 호스팅 서비스로 연결하여 검증.
> 실행 환경: Docker Compose 로컬 스택, CPU 전용(로컬 LLM).

## 구성

| Port | Development | Local Production 대체 | 비고 |
| --- | --- | --- | --- |
| ObjectStorage | LocalPrivateStorage | **S3CompatibleObjectStorage → MinIO** (`OBJECT_STORAGE_PROVIDER=S3`) | private 전용 버킷 `claimlens-private` 자동 생성 |
| MalwareScanner | DevelopmentMalwareScanner | **ClamAVMalwareScanner → clamav/clamav 컨테이너** (`MALWARE_SCANNER_PROVIDER=CLAMAV`) | INSTREAM, 정의 자동 갱신 |
| OCRProvider | DevelopmentOCRProvider | **HTTPOCRProvider → Tesseract(kor) 셈 서비스** (`OCR_PROVIDER=HTTP`, `local-services/ocr`) | `--psm 6`, PDF는 PyMuPDF 렌더 |
| StructuredExtraction | DevelopmentExtractionProvider | **HTTPExtractionProvider → Ollama qwen2.5:7b-instruct 셈 서비스** (`AI_PROVIDER=HTTP`, `local-services/extraction`) | JSON mode, 팩트 타입 화이트리스트 검증 |

- 환경 주입: compose `environment`를 `${VAR:-기본값}` 보간으로 전환 → `.env` 오버라이드 가능
- 신규 설정: `S3_SERVER_SIDE_ENCRYPTION`(기본 AES256, KMS 없는 MinIO는 공란)
- Worker는 `ollama-pull` 완료에 종속(모델 4.7GB 최초 1회 다운로드)

## 검증 결과

| 항목 | 결과 |
| --- | --- |
| MinIO 객체 put/get/exists/metadata/delete 라운드트립 | PASS |
| MinIO 서명 URL 발급 | PASS (내부 호스트명 기준 — 브라우저 직접 접근은 API 프록시 경유 전제) |
| ClamAV 정상 파일 스캔 | CLEAN |
| ClamAV EICAR 테스트 바이러스 | **INFECTED 탐지** |
| OCR 계약(`{text, confidence, pages}`) 한글 진단서 | PASS — confidence 0.91, 전 필드 인식 |
| AI 추출 계약(`{facts:[StructuredFact]}`) | PASS — DIAGNOSIS_NAME/CODE, 입·퇴원일, 발행일, MEDICAL_FACILITY 추출 |
| 스택 전체 | 13 서비스 기동, api/web/admin healthy |

## 알려진 제한 (MVP 허용 범위)

1. OCR이 `I21.0`을 `|21.0`으로 인식하는 등 경미한 오타 → 사용자 팩트 검증 단계에서 교정 전제
2. LLM confidence 자체 보고값(1.0)은 과신 → `FACT_LOW_CONFIDENCE_THRESHOLD` 판정은 참고용, 사용자 검증 게이트가 실질 방어선
3. 서명 URL이 컨테이너 내부 호스트명(`minio:9000`) 기준 → 외부 브라우저 직접 다운로드 필요 시 공개 엔드포인트 설정 확장 필요
4. 로컬 LLM CPU 추론으로 문서당 수십 초 소요 가능
5. `qwen2.5:7b`는 문서 내 주입 지시 무시 프롬프트를 적용했으나, 정기적인 프롬프트 인젝션 회귀 테스트 권장

## 남은 항목

- 실제 업로드 API 경유 E2E(인증 부트스트랩 포함) — 별도 세션에서 수행 가능
- staging 외부 인프라(멀티 인스턴스 복원, 실장비 성능, 침투 테스트)는 기존 계획 유지
