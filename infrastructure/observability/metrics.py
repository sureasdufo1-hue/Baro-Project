from collections import Counter
from threading import Lock


class MetricsRegistry:
    def __init__(self) -> None:
        self._lock = Lock()
        self._requests: Counter[tuple[str, int]] = Counter()
        self._duration_ms: Counter[str] = Counter()

    def observe_request(self, endpoint: str, status: int, duration_ms: float) -> None:
        endpoint = normalized_endpoint(endpoint)
        with self._lock:
            self._requests[(endpoint, status)] += 1
            self._duration_ms[endpoint] += round(duration_ms)

    def render(self) -> str:
        lines = [
            "# HELP claimlens_http_requests_total HTTP requests by normalized endpoint and status",
            "# TYPE claimlens_http_requests_total counter",
        ]
        with self._lock:
            for (endpoint, status), count in sorted(self._requests.items()):
                lines.append(
                    "claimlens_http_requests_total"
                    f'{{endpoint="{endpoint}",status="{status}"}} {count}'
                )
            lines.extend(
                [
                    "# HELP claimlens_http_request_duration_ms_total Accumulated request duration",
                    "# TYPE claimlens_http_request_duration_ms_total counter",
                ]
            )
            for endpoint, duration in sorted(self._duration_ms.items()):
                lines.append(
                    f'claimlens_http_request_duration_ms_total{{endpoint="{endpoint}"}} {duration}'
                )
        return "\n".join(lines) + "\n"


def normalized_endpoint(path: str) -> str:
    parts = []
    for part in path.split("/"):
        if len(part) == 36 and part.count("-") == 4:
            parts.append("{id}")
        else:
            parts.append(part[:80])
    return "/".join(parts)


metrics = MetricsRegistry()
