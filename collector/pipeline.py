"""fetch → dedupe → assign to day → rank → summarize → publish."""
from __future__ import annotations

import logging
import time
from datetime import datetime, timedelta
from pathlib import Path

import httpx
import yaml

from . import publish
from .dedupe import dedupe, merge
from .llm import ProviderError, providers_from_config
from .models import RawItem, iso, utcnow
from .rank import heuristic_category, score
from .sources import REGISTRY
from .store import Store, recent_days
from .summarize import summarize_batch, write_headline

log = logging.getLogger(__name__)
SOCIAL = ("hf_upvotes", "hn_points", "github_stars")
HEADLINE_BASIS = 6  # headline is rewritten when the top-6 set changes


def load_config(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


class Summarizer:
    """Phase 1: first configured provider only; failures leave items pending."""

    def __init__(self, llm_cfg: dict, http: httpx.Client, store: Store):
        self.cfg = llm_cfg
        self.http = http
        self.store = store
        self.providers = providers_from_config(llm_cfg["providers"])

    def summarize(self, items: list[RawItem]) -> None:
        n = self.cfg["batch_size"]
        for i in range(0, len(items), n):
            if not self.providers:
                return
            batch = items[i : i + n]
            p = self.providers[0]
            try:
                res = summarize_batch(p, batch, self.cfg, self.http)
            except ProviderError as e:
                log.warning("llm: batch failed on %s (%s)", p.label, e.status)
                continue
            for item_id, rec in res.items():
                self.store.summaries[item_id] = rec
            log.info("llm: %s summarized %d/%d", p.label, len(res), len(batch))

    def headline(self, entries: list[dict]) -> tuple[str, str] | None:
        if not self.providers or not entries:
            return None
        p = self.providers[0]
        try:
            return write_headline(p, entries, self.cfg, self.http), p.label
        except ProviderError as e:
            log.warning("llm: headline failed on %s (%s)", p.label, e.status)
            return None


def _has_social(it: RawItem) -> bool:
    return any(it.signals.get(k, 0) > 0 for k in SOCIAL)


def _short(text: str, n: int = 320) -> str:
    text = text.strip()
    if len(text) <= n:
        return text
    return text[:n].rsplit(" ", 1)[0].rstrip(",;:") + "…"


def top_entry(it: RawItem, cache: dict) -> dict:
    s = cache.get(it.id)
    signals = {k: int(it.signals.get(k, 0)) for k in SOCIAL}
    base = {
        "id": it.id,
        "title": it.title,
        "url": it.url,
        "source": it.source,
        "category": (s or {}).get("category") or heuristic_category(it),
        "score": it.score,
        "signals": signals,
        "published_at": iso(it.published_at),
    }
    if s:
        return {**base, "summary": s["summary"], "why_it_matters": s["why_it_matters"],
                "summarized_by": s["summarized_by"], "summary_status": "done"}
    return {**base, "summary": _short(it.text) or "No abstract available yet.", "why_it_matters": "",
            "summarized_by": None, "summary_status": "pending"}


def more_entry(it: RawItem, cache: dict) -> dict:
    return {
        "id": it.id,
        "title": it.title,
        "url": it.url,
        "source": it.source,
        "category": (cache.get(it.id) or {}).get("category") or heuristic_category(it),
    }


class Pipeline:
    def __init__(self, config_path: Path, now: datetime | None = None):
        self.cfg = load_config(config_path)
        self.root = config_path.resolve().parent.parent
        self.now = now or utcnow()
        out = self.cfg["output"]
        self.docs = self.root / out["docs_dir"]
        self.store = Store(self.root / out["state_dir"])
        self.http = httpx.Client(
            timeout=self.cfg["http"]["timeout_seconds"],
            headers={"User-Agent": self.cfg["http"]["user_agent"]},
            follow_redirects=True,
        )
        self.summarizer = Summarizer(self.cfg["llm"], self.http, self.store)

    # ---- fetch -------------------------------------------------------------
    def fetch_all(self, since: datetime) -> list[RawItem]:
        items: list[RawItem] = []
        for name, scfg in self.cfg["sources"].items():
            if not scfg.get("enabled", True) or name not in REGISTRY:
                continue
            t0 = time.monotonic()
            try:
                got = REGISTRY[name](scfg, self.http).fetch(since)
                items.extend(got)
                log.info("source %s: %d items in %.1fs", name, len(got), time.monotonic() - t0)
            except Exception as e:  # one broken source must never kill the run
                log.warning("source %s failed: %s: %s", name, type(e).__name__, str(e)[:200])
        return items

    # ---- assign ------------------------------------------------------------
    def assign(self, items: list[RawItem], pools: dict[str, dict[str, RawItem]]) -> set[str]:
        today = self.now.date().isoformat()
        touched = {today}
        featured = self.store.featured
        for it in items:
            day = self.store.day_of(it.id)
            live = day in pools and it.id in pools[day]
            if day is None:
                pools[today][it.id] = it  # brand new
                self.store.mark_seen(it.id, today)
            elif live and (day == today or it.id in featured or _has_social(pools[day][it.id])
                           or not _has_social(it)):
                pools[day][it.id] = merge(pools[day][it.id], it)  # refresh signals in place
                touched.add(day)
            elif _has_social(it) and it.id not in featured:
                # Seen earlier as a low-signal (arXiv-only) item and never featured, but
                # it's trending now: give it a shot in today's digest.
                old = pools[day].pop(it.id) if live else None
                if live:
                    touched.add(day)
                pools[today][it.id] = merge(old, it) if old else it
                self.store.mark_seen(it.id, today)
            # else: already handled on an earlier day — leave it there
        return touched

    # ---- build a day -------------------------------------------------------
    def build_day(self, day: str, pool: dict[str, RawItem]) -> dict:
        out = self.cfg["output"]
        top_n, more_n = out["top_n"], out["more_n"]
        for it in pool.values():
            it.score = score(it, self.cfg["ranking"], self.now)
        ordered = sorted(pool.values(), key=lambda i: i.score, reverse=True)

        # Keep the pool small. Dropped ids stay "seen" so they don't resurface
        # tomorrow, unless they start trending (see assign()).
        for it in ordered[top_n + more_n + 20 :]:
            del pool[it.id]

        top, more = ordered[:top_n], ordered[top_n : top_n + more_n]
        for it in top:
            self.store.featured[it.id] = day
        cache = self.store.summaries
        self.summarizer.summarize([i for i in top if i.id not in cache])

        items = [top_entry(i, cache) for i in top]
        headline, status = self._headline(day, items)
        return {
            "schema_version": publish.SCHEMA_VERSION,
            "date": day,
            "generated_at": iso(self.now),
            "headline": headline,
            "headline_status": status,
            "items": items,
            "more": [more_entry(i, cache) for i in more],
        }

    def _headline(self, day: str, items: list[dict]) -> tuple[str, str]:
        basis = sorted(i["id"] for i in items[:HEADLINE_BASIS])
        prev = self.store.headlines.get(day)
        if prev and prev.get("status") == "done" and prev.get("basis") == basis:
            return prev["headline"], "done"
        done = [i for i in items if i["summary_status"] == "done"][:8]
        got = self.summarizer.headline(done) if done else None
        if got:
            text, by = got
            self.store.headlines[day] = {"headline": text, "basis": basis, "by": by, "status": "done"}
            return text, "done"
        if prev and prev.get("status") == "done":
            return prev["headline"], "done"  # stale but real beats placeholder
        if not items:
            return "No items collected yet today.", "pending"
        lead = items[0]["title"]
        return f"{len(items)} notable AI items today, led by “{lead}”.", "pending"

    # ---- run ---------------------------------------------------------------
    def run(self) -> list[str]:
        t0 = time.monotonic()
        lookback = timedelta(hours=self.cfg["output"]["first_run_lookback_hours"])
        last = self.store.last_run
        # Small overlap so items that land mid-run aren't missed; dedupe handles repeats.
        since = (last - timedelta(minutes=30)) if last else self.now - lookback
        log.info("run: since %s", iso(since))

        items = dedupe(self.fetch_all(since))
        days = recent_days(self.now.date(), self.store.pool_days)
        pools = {d: self.store.load_pool(d) for d in days}
        touched = self.assign(items, pools)

        written = []
        for day in sorted(touched):
            if not pools[day] and day != self.now.date().isoformat():
                continue
            data = self.build_day(day, pools[day])
            publish.write_day(self.docs, data)
            self.store.save_pool(day, pools[day])
            written.append(day)
        publish.write_index_and_latest(self.docs)
        self.store.save(self.now)
        log.info("run: wrote %s in %.1fs", ", ".join(written), time.monotonic() - t0)
        return written
