"""Prometheus metrics (plan Section 9). One registry per app instance keeps tests isolated."""

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram

LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.25, 0.5, 1, 2.5)
CHAOS_MODES = ("error_rate", "latency", "hang", "cpu_burn", "memory_leak")


class Metrics:
    def __init__(self, registry: CollectorRegistry | None = None) -> None:
        self.registry = registry or CollectorRegistry()
        r = self.registry
        self.http_requests = Counter(
            "adpulse_http_requests_total", "HTTP requests", ["route", "method", "status"], registry=r
        )
        self.http_duration = Histogram(
            "adpulse_http_request_duration_seconds",
            "HTTP request duration",
            ["route"],
            buckets=LATENCY_BUCKETS,
            registry=r,
        )
        self.ad_served = Counter("adpulse_ad_served_total", "Ads served by source", ["source"], registry=r)
        self.cache_requests = Counter("adpulse_cache_requests_total", "Cache lookups by result", ["result"], registry=r)
        self.db_errors = Counter("adpulse_db_errors_total", "Database errors by operation", ["op"], registry=r)
        self.impression_queue_size = Gauge(
            "adpulse_impression_queue_size", "Impressions waiting to be written", registry=r
        )
        self.impressions_dropped = Counter(
            "adpulse_impressions_dropped_total", "Impressions dropped (queue full or DB error)", registry=r
        )
        self.fallback = Counter("adpulse_fallback_total", "Fallback (house) ads served", registry=r)
        self.chaos_active = Gauge("adpulse_chaos_active", "1 if a chaos mode is active", ["mode"], registry=r)
        self.build_info = Gauge("adpulse_build_info", "Build information", ["version", "git_sha", "env"], registry=r)
        # Pre-create label sets so series exist (as 0) before the first event.
        for source in ("cache", "db", "fallback"):
            self.ad_served.labels(source=source)
        for result in ("hit", "miss", "error"):
            self.cache_requests.labels(result=result)
        for op in ("select", "impression", "ready"):
            self.db_errors.labels(op=op)
        for mode in CHAOS_MODES:
            self.chaos_active.labels(mode=mode).set(0)
