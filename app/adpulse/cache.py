"""Redis cache of ad candidates, key ads:{category}:{segment}. Fails fast, never retries."""

import json

import redis.asyncio as aioredis
from redis.backoff import NoBackoff
from redis.retry import Retry

from .config import Settings


def cache_key(category: str, segment: str) -> str:
    return f"ads:{category}:{segment}"


class Cache:
    def __init__(self, settings: Settings) -> None:
        self.ttl = settings.cache_ttl_seconds
        self.client = aioredis.Redis(
            host=settings.redis_host,
            port=settings.redis_port,
            password=settings.redis_password or None,
            socket_timeout=settings.redis_timeout_seconds,
            socket_connect_timeout=settings.redis_timeout_seconds,
            retry=Retry(NoBackoff(), 0),
            health_check_interval=0,
        )

    async def close(self) -> None:
        await self.client.aclose()

    async def get_candidates(self, category: str, segment: str) -> list[dict] | None:
        raw = await self.client.get(cache_key(category, segment))
        return None if raw is None else json.loads(raw)

    async def set_candidates(self, category: str, segment: str, candidates: list[dict]) -> None:
        await self.client.set(cache_key(category, segment), json.dumps(candidates), ex=self.ttl)

    async def ping(self) -> None:
        await self.client.ping()
