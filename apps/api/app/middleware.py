import logging
import time
import uuid
from collections import defaultdict, deque
from threading import Lock

from fastapi import Request, Response
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint

from apps.api.app.config import Settings
from infrastructure.observability.metrics import metrics
from infrastructure.security.rate_limit import RedisRateLimiter

logger = logging.getLogger("claimlens.request")


class RequestContextMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        supplied = request.headers.get("X-Request-ID", "")
        request_id = (
            supplied if supplied.isascii() and 0 < len(supplied) <= 100 else str(uuid.uuid4())
        )
        request.state.request_id = request_id
        started = time.perf_counter()
        response = await call_next(request)
        duration_ms = round((time.perf_counter() - started) * 1000, 2)
        metrics.observe_request(request.url.path, response.status_code, duration_ms)
        response.headers["X-Request-ID"] = request_id
        logger.info(
            "request_complete",
            extra={
                "request_id": request_id,
                "endpoint": request.url.path,
                "status": response.status_code,
                "duration_ms": duration_ms,
            },
        )
        return response


class SecurityMiddleware(BaseHTTPMiddleware):
    _events: dict[str, deque[float]] = defaultdict(deque)
    _lock = Lock()

    def __init__(self, app: object, settings: Settings) -> None:
        super().__init__(app)  # type: ignore[arg-type]
        self.settings = settings
        self.distributed_limiter = (
            RedisRateLimiter(settings.redis_url)
            if settings.distributed_rate_limit_enabled
            else None
        )

    def _category(self, path: str) -> tuple[str, int] | None:
        if path in {"/api/auth/login", "/api/auth/register"}:
            return "auth", self.settings.auth_rate_limit_per_minute
        if path.endswith("/documents"):
            return "upload", self.settings.upload_rate_limit_per_minute
        if path.endswith("/ocr") or path.endswith("/assess"):
            return "analysis", self.settings.analysis_rate_limit_per_minute
        if path.endswith("/calculate") or path.endswith("/recalculate"):
            return "calculation", self.settings.calculation_rate_limit_per_minute
        if path.startswith("/api/reviews/") and request_is_action(path):
            return "review", self.settings.review_rate_limit_per_minute
        return None

    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        content_length = request.headers.get("content-length")
        if (
            content_length
            and request.method in {"POST", "PUT", "PATCH"}
            and "multipart/form-data" not in request.headers.get("content-type", "")
            and content_length.isdigit()
            and int(content_length) > self.settings.max_json_body_size_kb * 1024
        ):
            return self._error(413, "REQUEST_TOO_LARGE", "Request body is too large")
        origin = request.headers.get("origin")
        if (
            origin
            and request.method not in {"GET", "HEAD", "OPTIONS"}
            and origin not in self.settings.cors_origin_list
        ):
            return self._error(403, "CSRF_ORIGIN_DENIED", "Request origin is not allowed")
        category = self._category(request.url.path)
        if category:
            name, limit = category
            host = request.client.host if request.client else "unknown"
            key = f"{name}:{host}"
            now = time.monotonic()
            if self.distributed_limiter is not None:
                allowed = self.distributed_limiter.allow(f"claimlens:rate:{key}", limit)
                if allowed is None and name == "auth":
                    return self._error(
                        503, "RATE_LIMIT_UNAVAILABLE", "Authentication is unavailable"
                    )
                if allowed is False:
                    return self._error(429, "RATE_LIMITED", "Too many requests")
            else:
                with self._lock:
                    events = self._events[key]
                    while events and events[0] <= now - 60:
                        events.popleft()
                    if len(events) >= limit:
                        return self._error(429, "RATE_LIMITED", "Too many requests")
                    events.append(now)
        response = await call_next(request)
        if self.settings.security_headers_enabled:
            response.headers["X-Content-Type-Options"] = "nosniff"
            response.headers["Referrer-Policy"] = "no-referrer"
            response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
            response.headers["Content-Security-Policy"] = (
                "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
            )
            response.headers.setdefault("Cache-Control", "no-store")
        return response

    @staticmethod
    def _error(status: int, code: str, message: str) -> JSONResponse:
        return JSONResponse(
            status_code=status, content={"error": {"code": code, "message": message}}
        )


def request_is_action(path: str) -> bool:
    return path.rsplit("/", 1)[-1] in {
        "assign",
        "accept",
        "approve",
        "modify",
        "request-documents",
        "undetermined",
        "complete",
    }
