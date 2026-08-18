from redis import Redis

from apps.api.app.config import get_settings


def get_redis() -> Redis:
    return Redis.from_url(get_settings().redis_url)
