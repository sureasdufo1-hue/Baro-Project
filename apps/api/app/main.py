import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from apps.api.app.config import get_settings
from apps.api.app.middleware import RequestContextMiddleware, SecurityMiddleware
from apps.api.app.routes import (
    admin,
    assessments,
    auth,
    calculations,
    claims,
    contracts,
    documents,
    evidence,
    facts,
    health,
    insurance_master,
    reviews,
)
from shared.errors import DomainError

settings = get_settings()
logging.basicConfig(level=settings.log_level, format="%(levelname)s %(name)s %(message)s")

app = FastAPI(title="ClaimLens API", version="0.1.0")
app.add_middleware(RequestContextMiddleware)
app.add_middleware(SecurityMiddleware, settings=settings)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["Content-Type", "X-Request-ID"],
)


@app.exception_handler(DomainError)
async def domain_error_handler(request: Request, exc: DomainError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": {
                "code": exc.code,
                "message": exc.message,
                "requestId": getattr(request.state, "request_id", None),
            }
        },
    )


@app.exception_handler(Exception)
async def unexpected_error_handler(request: Request, _: Exception) -> JSONResponse:
    logging.getLogger("claimlens.error").exception("unhandled_request_error")
    return JSONResponse(
        status_code=500,
        content={
            "error": {
                "code": "INTERNAL_ERROR",
                "message": "An unexpected error occurred",
                "requestId": getattr(request.state, "request_id", None),
            }
        },
    )


app.include_router(health.router)
app.include_router(auth.router)
app.include_router(admin.router)
app.include_router(insurance_master.router)
app.include_router(contracts.router)
app.include_router(claims.router)
app.include_router(documents.claim_router)
app.include_router(documents.document_router)
app.include_router(facts.claim_router)
app.include_router(facts.document_router)
app.include_router(facts.fact_router)
app.include_router(assessments.claim_router)
app.include_router(assessments.router)
app.include_router(calculations.claim_router)
app.include_router(calculations.assessment_router)
app.include_router(calculations.router)
app.include_router(evidence.claim_router)
app.include_router(evidence.calculation_router)
app.include_router(reviews.router)
app.include_router(reviews.claim_router)
