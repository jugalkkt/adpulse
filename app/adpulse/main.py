"""AdPulse API (plan Section 9)."""

import asyncio
import contextlib
import hmac
import logging
import random
import time
import uuid
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from . import __version__
from .cache import Cache
from .chaos import ChaosState
from .config import Settings
from .db import Database
from .logging_setup import setup_logging
from .metrics import Metrics
from .selection import AdSelector, Category, Segment

log = logging.getLogger("adpulse")
access_log = logging.getLogger("adpulse.access")


def create_app(
    settings: Settings | None = None,
    *,
    db=None,
    cache=None,
    metrics: Metrics | None = None,
    rng: random.Random | None = None,
    chaos_clock=time.monotonic,
) -> FastAPI:
    settings = settings or Settings()
    metrics = metrics or Metrics()
    db = db or Database(settings)
    cache = cache or Cache(settings)
    selector = AdSelector(cache, db, metrics, rng)
    chaos = ChaosState(metrics, clock=chaos_clock)
    chaos_rng = random.Random()
    queue: asyncio.Queue = asyncio.Queue(maxsize=settings.impression_queue_size)
    metrics.build_info.labels(version=__version__, git_sha=settings.git_sha, env=settings.app_env).set(1)

    async def impression_worker() -> None:
        while True:
            item = await queue.get()
            try:
                await db.insert_impression(*item)
            except Exception:
                metrics.impressions_dropped.inc()
                metrics.db_errors.labels(op="impression").inc()
            finally:
                queue.task_done()

    async def chaos_reaper() -> None:
        while True:
            chaos.expire_all()
            await asyncio.sleep(1)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await db.open()
        tasks = [asyncio.create_task(impression_worker()), asyncio.create_task(chaos_reaper())]
        log.info("started", extra={"git_sha": settings.git_sha, "chaos_enabled": settings.chaos_enabled})
        try:
            yield
        finally:
            chaos.reset()
            # Graceful shutdown (e.g. a rolling deploy): flush queued impressions first,
            # but never block shutdown for more than 2s if the DB is down.
            try:
                await asyncio.wait_for(queue.join(), timeout=2)
            except TimeoutError:
                metrics.impressions_dropped.inc(queue.qsize())
                log.warning("impressions dropped at shutdown", extra={"count": queue.qsize()})
            for t in tasks:
                t.cancel()
            for t in tasks:
                with contextlib.suppress(asyncio.CancelledError):
                    await t
            await db.close()
            with contextlib.suppress(Exception):
                await cache.close()

    app = FastAPI(title="AdPulse", version=__version__, lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.settings = settings
    app.state.metrics = metrics
    app.state.chaos = chaos
    app.state.queue = queue

    @app.middleware("http")
    async def observe(request: Request, call_next):
        request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
        request.state.request_id = request_id
        request.state.source = None
        start = time.perf_counter()
        # Chaos "hang": every route except the chaos admin API stops answering,
        # so liveness checks and Prometheus scrapes time out.
        if not request.url.path.startswith("/admin/chaos"):
            # Polling (not an Event): the hang ends by time-based expiry or by reset.
            while chaos.active("hang") is not None:  # noqa: ASYNC110
                await asyncio.sleep(0.1)
        try:
            response = await call_next(request)
        except Exception:
            log.exception("unhandled error", extra={"request_id": request_id})
            response = JSONResponse({"detail": "internal error", "request_id": request_id}, status_code=500)
        route_obj = request.scope.get("route")
        route = getattr(route_obj, "path", "unmatched")
        duration = time.perf_counter() - start
        metrics.http_requests.labels(route=route, method=request.method, status=str(response.status_code)).inc()
        metrics.http_duration.labels(route=route).observe(duration)
        response.headers["X-Request-ID"] = request_id
        access_log.info(
            "request",
            extra={
                "request_id": request_id,
                "route": route,
                "method": request.method,
                "status": response.status_code,
                "duration_ms": round(duration * 1000, 2),
                "source": request.state.source,
            },
        )
        return response

    @app.get("/v1/ad")
    async def get_ad(request: Request, category: Category, segment: Segment):
        if (p := chaos.active("latency")) is not None:
            await asyncio.sleep(p["ms"] / 1000)
        if (p := chaos.active("error_rate")) is not None and chaos_rng.random() * 100 < p["pct"]:
            return JSONResponse(
                {"detail": "chaos: injected error", "request_id": request.state.request_id}, status_code=500
            )
        ad, source = await selector.select(category, segment)
        request.state.source = source
        if source != "fallback":
            try:
                queue.put_nowait((ad["id"], category, segment, source))
            except asyncio.QueueFull:
                metrics.impressions_dropped.inc()
        return {"request_id": request.state.request_id, "ad": ad, "source": source, "env": settings.app_env}

    @app.get("/healthz")
    async def healthz():
        return {"status": "ok"}

    @app.get("/readyz")
    async def readyz():
        checks: dict[str, str] = {}
        if settings.broken_release:
            checks["release"] = "BROKEN_RELEASE=true"
        try:
            await asyncio.wait_for(db.ping(), timeout=0.5)
            checks["db"] = "ok"
        except Exception as exc:
            metrics.db_errors.labels(op="ready").inc()
            checks["db"] = f"error: {type(exc).__name__}"
        try:
            await asyncio.wait_for(cache.ping(), timeout=0.5)
            checks["cache"] = "ok"
        except Exception as exc:
            checks["cache"] = f"error: {type(exc).__name__}"
        ready = checks.get("db") == "ok" and checks.get("cache") == "ok" and not settings.broken_release
        body = {"status": "ready" if ready else "not_ready", "checks": checks}
        return JSONResponse(body, status_code=200 if ready else 503)

    @app.get("/metrics")
    async def metrics_endpoint():
        metrics.impression_queue_size.set(queue.qsize())
        return Response(generate_latest(metrics.registry), media_type=CONTENT_TYPE_LATEST)

    if settings.chaos_enabled:
        app.include_router(_chaos_router(settings, chaos))

    return app


def _chaos_router(settings: Settings, chaos: ChaosState) -> APIRouter:
    def require_token(x_chaos_token: Annotated[str, Header()] = "") -> None:
        expected = settings.chaos_token.encode()
        if not expected or not hmac.compare_digest(x_chaos_token.encode(), expected):
            raise HTTPException(status_code=403, detail="invalid chaos token")

    router = APIRouter(prefix="/admin/chaos", dependencies=[Depends(require_token)])
    seconds_q = Query(default=120, ge=1, le=900)

    @router.get("")
    async def state():
        return {"active": chaos.snapshot()}

    @router.post("/error_rate")
    async def error_rate(pct: Annotated[float, Query(gt=0, le=100)] = 50, seconds: int = seconds_q):
        chaos.activate("error_rate", seconds, pct=pct)
        return {"mode": "error_rate", "pct": pct, "seconds": seconds}

    @router.post("/latency")
    async def latency(ms: Annotated[int, Query(ge=1, le=10_000)] = 400, seconds: int = seconds_q):
        chaos.activate("latency", seconds, ms=ms)
        return {"mode": "latency", "ms": ms, "seconds": seconds}

    @router.post("/hang")
    async def hang(seconds: int = seconds_q):
        chaos.activate("hang", seconds)
        return {"mode": "hang", "seconds": seconds}

    @router.post("/cpu_burn")
    async def cpu_burn(seconds: int = seconds_q):
        chaos.activate("cpu_burn", seconds)
        return {"mode": "cpu_burn", "seconds": seconds}

    @router.post("/memory_leak")
    async def memory_leak(
        mb_per_sec: Annotated[int, Query(ge=1, le=50)] = 5,
        seconds: int = seconds_q,
        max_mb: Annotated[int, Query(ge=0, le=1024)] = 0,  # 0 = grow until OOM; >0 = plateau
    ):
        chaos.activate("memory_leak", seconds, mb_per_sec=mb_per_sec, max_mb=max_mb)
        return {"mode": "memory_leak", "mb_per_sec": mb_per_sec, "max_mb": max_mb, "seconds": seconds}

    @router.delete("")
    async def reset():
        chaos.reset()
        return {"active": {}}

    return router


def _build_default_app() -> FastAPI:
    settings = Settings()
    setup_logging(settings.app_env, settings.log_level)
    return create_app(settings)


app = _build_default_app()
