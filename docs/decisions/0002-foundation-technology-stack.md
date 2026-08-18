# ADR-0002: Foundation 기술 스택

- 상태: 승인
- 기준일: 2026-08-18

## 결정

- 사용자·관리자 웹: Next.js, React, TypeScript, pnpm workspace
- API: Python, FastAPI, Pydantic Settings
- 데이터: PostgreSQL, SQLAlchemy, Alembic
- 비동기 기반: Redis, RQ worker
- 검증: pytest, Ruff, mypy, ESLint, TypeScript, Vitest

## 이유

제공된 CODEX-01 기본안을 따르며, 단일 저장소와 모듈러 모놀리스 안에서 애플리케이션 진입점을 분리할 수 있습니다. OCR·AI 등 장기 작업은 Redis 기반 워커로 분리할 수 있지만 이번 차수에는 연결 확인용 작업만 둡니다.

## 제약

보험 도메인 모델과 Rule은 이 결정에 포함하지 않습니다. 외부 OCR·AI 공급자도 선택하지 않습니다.

