"""PostgreSQL access through a psycopg 3 async pool. Every call has a hard timeout."""

import asyncio

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from .config import Settings

CANDIDATES_SQL = """
SELECT a.id, adv.name AS advertiser, a.title, a.image_url, a.click_url, a.bid_cpm
FROM ads a
JOIN advertisers adv ON adv.id = a.advertiser_id
WHERE a.active AND a.category = %s AND a.segment IN (%s, 'all')
ORDER BY a.id
"""

IMPRESSION_SQL = "INSERT INTO impressions (ad_id, category, segment, source) VALUES (%s, %s, %s, %s)"


class Database:
    def __init__(self, settings: Settings) -> None:
        self.timeout = settings.db_timeout_seconds
        self.pool = AsyncConnectionPool(
            settings.db_conninfo,
            min_size=1,
            max_size=settings.db_pool_max_size,
            timeout=settings.db_timeout_seconds,
            open=False,
            # Drop broken connections (e.g. after a DB restart) instead of reusing them.
            check=AsyncConnectionPool.check_connection,
        )

    async def open(self) -> None:
        # wait=False: the API must start (liveness 200) even when the DB is down.
        await self.pool.open(wait=False)

    async def close(self) -> None:
        await self.pool.close()

    async def _run(self, coro_fn):
        return await asyncio.wait_for(coro_fn(), timeout=self.timeout)

    async def fetch_candidates(self, category: str, segment: str) -> list[dict]:
        async def q():
            async with self.pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
                await cur.execute(CANDIDATES_SQL, (category, segment))
                return await cur.fetchall()

        rows = await self._run(q)
        # numeric -> float so candidates are JSON-serialisable for the cache.
        return [{**r, "bid_cpm": float(r["bid_cpm"])} for r in rows]

    async def insert_impression(self, ad_id: int, category: str, segment: str, source: str) -> None:
        async def q():
            async with self.pool.connection() as conn:
                await conn.execute(IMPRESSION_SQL, (ad_id, category, segment, source))

        await self._run(q)

    async def ping(self) -> None:
        async def q():
            async with self.pool.connection() as conn:
                await conn.execute("SELECT 1")

        await self._run(q)
