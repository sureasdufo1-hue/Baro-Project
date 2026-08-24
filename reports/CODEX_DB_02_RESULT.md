# CODEX-DB-02 결과

## 판정

`PARTIAL_SUCCESS` — 실제 POLICY 수집·검증·Evidence 적재는 완료했으며 사람 검증 전 자동 승격은 차단했다.

## 공식 공시 요청 구조

- 상품 목록: `POST /insuPcPbanFindProductStep2_AX.do`
- 판매기간: `POST /insuPcPbanFindProductStep3_AX.do`
- 문서 메타데이터: `POST /insuPcPbanFindProductStep4_AX.do`
- 다운로드: `GET /cYakgwanDown.do?FilePath=InsProduct/{encoded filename}`
- 대상 SQNO: `10425`

## 실제 POLICY

- 파일: `약관_31084(03)_20260401.pdf`
- 기간: 2026-04-01 ~ 2026-06-30
- SHA-256: `39cbc6761ee58a9ece32170f2759df71c76beb7e2bd1c5e73202bda817f5ac2d`
- 크기: 4,532,650 bytes
- 페이지: 314
- PDF magic, open, 상품명, 문서유형 검증 PASS

## 확인한 근거

- 암주요치료비Ⅱ 지급사유·100%·연간 1회·최대 10회·90일: 79쪽
- 암(유사암제외) 치료비지원: 91쪽
- 별표2 악성신생물(암) 분류표/KCD: 203쪽
- 일반 면책 조항: 48쪽

## Promotion Gate

POLICY Evidence는 확보됐다. 그러나 내부 코드 `31201`과 공시 파일 코드 `31084(03)`의 매핑 및 추출된 지급 Rule/KCD에 대한 사람 검증이 남아 있어 `OFFICIAL_CROSSCHECKED`를 유지한다. Claim 결과는 계속 `HUMAN_REVIEW_REQUIRED`이며 금액을 반환하지 않는다.

## 다음 조치

보험 전문 검토자가 상품 코드 매핑, 79·91·203쪽 원문, 제외조건 및 Rule Diff를 승인한 뒤에만 `VERIFIED_POLICY`로 승격한다.
