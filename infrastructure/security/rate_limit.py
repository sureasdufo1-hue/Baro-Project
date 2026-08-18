from typing import Protocol

from redis import Redis
from redis.exceptions import RedisError


class RateLimiter(Protocol):
    def allow(self, key: str, limit: int, window_seconds: int = 60) -> bool | None: ...


class RedisRateLimiter:
    """Distributed fixed-window limiter. None means Redis was unavailable."""

    def __init__(self, redis_url: str) -> None:
        self.redis = Redis.from_url(redis_url, socket_connect_timeout=1, socket_timeout=1)

    def allow(self, key: str, limit: int, window_seconds: int = 60) -> bool | None:
        try:
            with self.redis.pipeline(transaction=True) as pipeline:
                pipeline.incr(key)
                pipeline.expire(key, window_seconds, nx=True)
                count, _ = pipeline.execute()
            return int(count) <= limit
        except RedisError:
            return None
