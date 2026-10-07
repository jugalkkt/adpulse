"""In-process chaos modes (staging only). Every mode auto-expires.

Modes: error_rate, latency, hang, cpu_burn, memory_leak. State lives in memory,
so restarting the replica (what the healer does) clears it.
"""

import asyncio
import gc
import threading
import time
from collections.abc import Callable

from .metrics import CHAOS_MODES, Metrics

MB = 1024 * 1024


class ChaosState:
    def __init__(self, metrics: Metrics, clock: Callable[[], float] = time.monotonic) -> None:
        self.metrics = metrics
        self.clock = clock
        self._modes: dict[str, tuple[float, dict]] = {}
        self._lock = threading.Lock()
        self._cpu_stop = threading.Event()
        self._leak: list[bytes] = []
        self._leak_task: asyncio.Task | None = None

    # ---- state ---------------------------------------------------------
    def activate(self, mode: str, seconds: float, **params) -> None:
        if mode not in CHAOS_MODES:
            raise ValueError(f"unknown chaos mode {mode}")
        with self._lock:
            self._modes[mode] = (self.clock() + seconds, params)
        self.metrics.chaos_active.labels(mode=mode).set(1)
        if mode == "cpu_burn":
            self._start_cpu_burn()
        elif mode == "memory_leak":
            self._start_memory_leak()

    def active(self, mode: str) -> dict | None:
        """Params of an active mode, or None. Expires the mode if its time is up."""
        with self._lock:
            entry = self._modes.get(mode)
            if entry is None:
                return None
            if self.clock() >= entry[0]:
                del self._modes[mode]
                expired = True
            else:
                return entry[1]
        if expired:
            self._stopped(mode)
        return None

    def remaining(self, mode: str) -> float:
        with self._lock:
            entry = self._modes.get(mode)
        return max(0.0, entry[0] - self.clock()) if entry else 0.0

    def expire_all(self) -> None:
        for mode in CHAOS_MODES:
            self.active(mode)

    def reset(self) -> None:
        with self._lock:
            modes = list(self._modes)
            self._modes.clear()
        for mode in modes:
            self._stopped(mode)

    def snapshot(self) -> dict:
        self.expire_all()
        with self._lock:
            return {m: {"remaining_s": round(e[0] - self.clock(), 1), **e[1]} for m, e in self._modes.items()}

    def _stopped(self, mode: str) -> None:
        self.metrics.chaos_active.labels(mode=mode).set(0)
        if mode == "cpu_burn":
            self._cpu_stop.set()
        elif mode == "memory_leak":
            if self._leak_task:
                self._leak_task.cancel()
                self._leak_task = None
            self._leak.clear()
            gc.collect()

    # ---- side effects --------------------------------------------------
    def _start_cpu_burn(self) -> None:
        self._cpu_stop.clear()

        def burn() -> None:
            # Pure-Python busy loop: holds the GIL, so the event loop slows down too,
            # like a real CPU-starved process.
            while not self._cpu_stop.is_set() and self.active("cpu_burn") is not None:
                for _ in range(100_000):
                    pass

        threading.Thread(target=burn, name="chaos-cpu-burn", daemon=True).start()

    def _start_memory_leak(self) -> None:
        if self._leak_task and not self._leak_task.done():
            return

        async def leak() -> None:
            while (params := self.active("memory_leak")) is not None:
                # Non-zero bytes so the pages are really resident, not lazily mapped.
                self._leak.append(b"\xab" * (int(params.get("mb_per_sec", 5)) * MB))
                await asyncio.sleep(1)

        self._leak_task = asyncio.get_running_loop().create_task(leak())

    @property
    def leaked_bytes(self) -> int:
        return sum(len(b) for b in self._leak)
