"""Ordered LLM fallback chain.

For each call: try providers in config order, skipping ones exhausted earlier in
this run. On a retryable error retry once with backoff, then move on:
  - 429 / quota: the provider is exhausted for the rest of the run.
  - 5xx / timeout ("high demand" blips): this call moves on, but the provider is
    only exhausted after failing `max_strikes` calls, since overload is usually brief.
  - 400/401/403/404 (bad key, unknown model): exhausted immediately, no retry.
If every provider fails, return None and the caller leaves items `pending`.
"""
from __future__ import annotations

import logging
import time
from typing import Callable, TypeVar

from .llm import Provider, ProviderError

log = logging.getLogger(__name__)
T = TypeVar("T")


class Chain:
    def __init__(
        self,
        providers: list[Provider],
        backoff_seconds: float = 5.0,
        budget_seconds: float = 420.0,
        max_strikes: int = 2,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.providers = providers
        self.backoff = backoff_seconds
        self.max_strikes = max_strikes
        self._strikes: dict[str, int] = {}
        self.sleep = sleep
        self.clock = clock
        self.deadline = clock() + budget_seconds
        self.exhausted: set[str] = set()
        self._last_call: dict[str, float] = {}
        self._calls: dict[str, int] = {}

    def out_of_time(self) -> bool:
        return self.clock() > self.deadline

    def available(self) -> list[Provider]:
        return [p for p in self.providers if p.label not in self.exhausted]

    def _pace(self, p: Provider) -> None:
        gap = p.min_interval_seconds - (self.clock() - self._last_call.get(p.label, -1e9))
        if gap > 0:
            self.sleep(gap)

    def _exhaust(self, p: Provider, why: str) -> None:
        self.exhausted.add(p.label)
        log.warning("llm: %s exhausted for this run (%s)", p.label, why)

    def call(self, fn: Callable[[Provider], T]) -> tuple[T, Provider] | None:
        for p in self.available():
            if self.out_of_time():
                log.warning("llm: run budget used up; leaving the rest pending")
                return None
            if p.max_requests_per_run and self._calls.get(p.label, 0) >= p.max_requests_per_run:
                self._exhaust(p, "max_requests_per_run reached")
                continue
            for attempt in (1, 2):
                self._pace(p)
                self._calls[p.label] = self._calls.get(p.label, 0) + 1
                self._last_call[p.label] = self.clock()
                try:
                    return fn(p), p
                except ProviderError as e:
                    if not e.retryable:
                        self._exhaust(p, f"HTTP {e.status}")
                        break
                    what = f"HTTP {e.status}" if e.status else "timeout"
                    if attempt == 1:
                        wait = min(e.retry_after or self.backoff, 30.0)
                        log.info("llm: %s got %s, retrying in %.0fs", p.label, what, wait)
                        self.sleep(wait)
                    elif e.status == 429:
                        self._exhaust(p, f"{what} after retry")
                    else:
                        self._strikes[p.label] = self._strikes.get(p.label, 0) + 1
                        if self._strikes[p.label] >= self.max_strikes:
                            self._exhaust(p, f"{what}, {self._strikes[p.label]} failed calls")
                        else:
                            log.info("llm: %s got %s after retry; next provider for this call", p.label, what)
        return None
