# 런타임 E2E 결과 (실 API + 로컬 프로바이더 전체 스택)

> `scripts/runtime_e2e.py`가 실제 API 경유로 전 청구 라이프사이클을 구동한다.
> 스택: FastAPI + PostgreSQL + Redis/RQ worker + MinIO + ClamAV + Tesseract OCR + Ollama(qwen2.5:7b) — 전부 로컬.

## 실행 결과: **PASS**

```text
Register/Login → Insured → Contract(심근경색/허혈성심장 담보) → Claim(DISEASE)
→ SUBMIT_ACCIDENT_INFORMATION 전이 → 진단서 업로드(PNG, 한글)
→ ClamAV 스캔 → MinIO 저장(바이트 일치 검증) → analysis 202(큐)
→ worker: Tesseract OCR → Ollama 구조화 추출 → 팩트 7종
→ 사용자 검증(confirm 6 + modify 1: OCR 오타 I21.0 교정)
→ assess 201(담보별 2건) → calculate 201(2건)
→ 급성심근경색 30,000,000원 CALCULATED / 허혈성심장 0원 NOT_PAYABLE
```

## 실행 중 발견·수정한 결함

| 결함 | 원인 | 수정 |
| --- | --- | --- |
| worker FK 해석 크래시(`additional_document_requests`) | worker 프로세스가 일부 도메인 모델만 임포트 | `apps/worker/main.py`에서 전 도메인 모델 레지스트리 로드 |
| 업로드 503(STORAGE_UPLOAD_FAILED) | compose `${VAR:-기본}` 보간이 .env 빈 값을 기본값으로 덮어씀 → SSE=AES256이 MinIO로 전송 | `${VAR-기본}`(콜론 없음)으로 수정 + `S3_SERVER_SIDE_ENCRYPTION` 전달 항목 추가 |
| OCR 잡 60초 timeout 강제 종료 | RQ job_timeout이 `OCR_TIMEOUT_SECONDS`(기본 60)를 사용, 로컬 LLM 추론 시간 초과 | compose 전달 항목 추가 + `.env`에서 900초 설정 |
| 룰 평가 전부 MISSING_INPUT | api 이미지에 구버전 시드 스크립트 스냅샷 → 구 경로(`facts.diagnosis.kcd_code`) 룰이 DB에 시드됨 | api/worker 이미지 재빌드 + 개발 DB 볼륨 초기화 후 재시드 |

## 운영 참고

- **이미지 재빌드 습관화**: `COPY . .` 스냅샷 특성상 코드/스크립트 변경 후 `docker compose build api worker` 필요
- **시드 갱신 절차**: 시드 로직 변경 시 개발 DB 볼륨 초기화가 필요(멱등 스킵이 구데이터를 남김) — 향후 시드 스크립트에 업데이트/업서트 모드 추가 검토
- OCR 품질: `I21.0`→`21.0` 오인은 사용자 수정 플로우로 교정(정상 시나리오). 진단일은 문서에 명시 필요
- 실행 방법: `docker compose exec api python scripts/seed_db_insurance_master.py` 후 `.venv\Scripts\python.exe scripts\runtime_e2e.py`
