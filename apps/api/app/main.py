import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from apps.api.app.config import get_settings
from apps.api.app.middleware import RequestContextMiddleware
from apps.api.app.routes import admin, auth, health
from shared.errors import DomainError

settings = get_settings()
logging.basicConfig(level=settings.log_level, format="%(levelname)s %(name)s %(message)s")

app = FastAPI(title="ClaimLens API", version="0.1.0")
app.add_middleware(RequestContextMiddleware)
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
