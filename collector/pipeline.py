"""fetch → dedupe → assign to day → rank → summarize → publish."""
from __future__ import annotations

import logging
import time
from datetime import datetime, timedelta
from pathlib import Path

import httpx
import yaml

from . import publish
from .dedupe import dedupe, merge, same_title
from .enrich import Enricher
from .chain import Chain
from .llm import providers_from_config
from .models import RawItem, iso, parse_iso, utcnow
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
    """Summaries + headlines through the fallback chain, cached by item id."""

    def __init__(self, llm_cfg: dict, http: httpx.Client, store: Store, today: str,
                 chain: Chain | None = None):
        self.cfg = llm_cfg
        self.http = http
        self.store = store
        self.today = today
        self.chain = chain or Chain(
            providers_from_config(llm_cfg["providers"]),
            backoff_seconds=llm_cfg.get("retry_backoff_seconds", 5),
            budget_seconds=llm_cfg.get("run_budget_seconds", 420),
            max_strikes=llm_cfg.get("max_5xx_strikes", 2),
        )

    def summarize(self, items: list[RawItem]) -> None:
        # Re-ask for summaries cached before the relevance check existed (no "about_ai").
        todo = [i for i in items if "about_ai" not in self.store.summaries.get(i.id, {})]
        n = self.cfg["batch_size"]
        for k in range(0, len(todo), n):
            batch = todo[k : k + n]
            got = self.chain.call(lambda p: summarize_batch(p, batch, self.cfg, self.http))
            if got is None:
                if not self.chain.available() or self.chain.out_of_time():
                    log.warning("llm: no provider left; %d item(s) stay pending", len(todo) - k)
                    return
                log.warning("llm: batch failed on every provider; %d item(s) stay pending", len(batch))
                continue
            res, p = got
            for item_id, rec in res.items():
                self.store.summaries[item_id] = {**rec, "day": self.today}
            log.info("llm: %s summarized %d/%d", p.label, len(res), len(batch))

    def headline(self, entries: list[dict]) -> tuple[str, str] | None:
        if not entries:
            return None
        got = self.chain.call(lambda p: write_headline(p, entries, self.cfg, self.http))
        return (got[0], got[1].label) if got else None


def source_group(source: str) -> str:
    base = source.split(":")[0]
    return "papers" if base in ("arxiv", "hf_papers") else base


def select_top(ordered: list[RawItem], n: int, caps: dict[str, int]) -> list[RawItem]:
    """Highest scores first, but at most caps[group] per source group so one kind of
    item (usually papers) can't crowd out everything else. Back-fills if short."""
    top, overflow, counts = [], [], {}
    for it in ordered:
        g = source_group(it.source)
        if len(top) < n and counts.get(g, 0) < caps.get(g, n):
            top.append(it)
            counts[g] = counts.get(g, 0) + 1
        else:
            overflow.append(it)
    top += overflow[: n - len(top)]
    return sorted(top, key=lambda i: i.score, reverse=True)


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
    def __init__(self, config_path: Path, now: datetime | None = None,
                 chain: Chain | None = None, sources: dict | None = None,
                 http: httpx.Client | None = None):
        self.cfg = load_config(config_path)
        self.root = config_path.resolve().parent.parent
        self.now = now or utcnow()
        out = self.cfg["output"]
        self.docs = self.root / out["docs_dir"]
        self.store = Store(self.root / out["state_dir"], pool_days=out.get("pool_days", 7))
        self.sources = sources if sources is not None else REGISTRY
        self.http = http or httpx.Client(
            timeout=self.cfg["http"]["timeout_seconds"],
            headers={"User-Agent": self.cfg["http"]["user_agent"]},
            follow_redirects=True,
        )
        self.summarizer = Summarizer(self.cfg["llm"], self.http, self.store,
                                     self.now.date().isoformat(), chain)
        self.enricher = Enricher(self.http, self.cfg.get("enrich", {}))
        self.labs = {x.lower() for x in self.cfg["ranking"].get("labs", [])}

    # ---- fetch -------------------------------------------------------------
    def fetch_all(self, since: datetime) -> list[RawItem]:
        items: list[RawItem] = []
        for name, scfg in self.cfg["sources"].items():
            if not scfg.get("enabled", True) or name not in self.sources:
                continue
            t0 = time.monotonic()
            try:
                got = self.sources[name]({**scfg, "labs": sorted(self.labs)}, self.http).fetch(since)
                items.extend(got)
                log.info("source %s: %d items in %.1fs", name, len(got), time.monotonic() - t0)
            except Exception as e:  # one broken source must never kill the run
                log.warning("source %s failed: %s: %s", name, type(e).__name__, str(e)[:200])
        for it in items:
            # Blog feeds are labs by definition; GitHub checks its own verified org list;
            # HF papers count when their HF organization is on `labs`.
            if it.source == "hf_papers" and (it.lab or "").lower() not in self.labs:
                it.lab = None
        return items

    # ---- assign ------------------------------------------------------------
    def gap_days(self) -> list[str]:
        """UTC days with no run at all since the last one (GitHub delays or drops
        scheduled runs), limited to days whose pools still exist."""
        last = self.store.last_run
        if last is None:
            return []
        today = self.now.date()
        start = max(last.date() + timedelta(days=1), today - timedelta(days=self.store.pool_days - 1))
        out, d = [], start
        while d < today:
            out.append(d.isoformat())
            d += timedelta(days=1)
        return out

    def assign(self, items: list[RawItem], pools: dict[str, dict[str, RawItem]],
               gaps: list[str] = ()) -> set[str]:
        today = self.now.date().isoformat()
        touched = {today, *gaps}
        featured = self.store.featured
        alias = self.store.alias
        # Live items on recent days, for fuzzy-title matching of brand-new ones.
        live_titles = [(d, k, i.title, bool(i.arxiv_id)) for d, pool in pools.items() for k, i in pool.items()]
        for it in items:
            it.id = alias.get(it.id, it.id)
            day = self.store.day_of(it.id)
            if day is None:
                # Fuzzy-merge only non-paper items: papers already dedupe by arXiv ID, and
                # a look-alike title must never redirect a paper to someone else's link.
                match = next(((d, k) for d, k, t, ax in live_titles
                              if not (ax or it.arxiv_id) and same_title(it.title, t)), None)
                if match and not it.arxiv_id:
                    day, kept = match
                    alias[it.id] = kept
                    it.id = kept
            live = day in pools and it.id in pools[day]
            if day is None:
                # Brand new. After skipped runs, file it under the skipped day it was
                # published on, so no day ends up missing.
                home = it.published_at.date().isoformat()
                home = home if home in gaps else today
                pools[home][it.id] = it
                self.store.mark_seen(it.id, home)
                live_titles.append((home, it.id, it.title, bool(it.arxiv_id)))
            elif live and (day == today or it.id in featured or _has_social(pools[day][it.id])
                           or not _has_social(it)):
                m = merge(pools[day][it.id], it)  # refresh signals in place
                m.id = it.id
                pools[day][it.id] = m
                touched.add(day)
            elif _has_social(it) and it.id not in featured:
                # Seen earlier as a low-signal (arXiv-only) item and never featured, but
                # it's trending now: give it a shot in today's digest.
                old = pools[day].pop(it.id) if live else None
                if live:
                    touched.add(day)
                m = merge(old, it) if old else it
                m.id = it.id
                pools[today][it.id] = m
                self.store.mark_seen(it.id, today)
            # else: already handled on an earlier day — leave it there
        return touched

    # ---- build a day -------------------------------------------------------
    def build_day(self, day: str, pool: dict[str, RawItem]) -> dict:
        out = self.cfg["output"]
        top_n, more_n = out["top_n"], out["more_n"]
        # Score past days as of their end, so re-building them (e.g. to fill in
        # pending summaries) doesn't reshuffle their ranking.
        ref = min(self.now, parse_iso(f"{day}T23:59:59Z"))
        for it in pool.values():
            it.score = score(it, self.cfg["ranking"], ref)
        ordered = sorted(pool.values(), key=lambda i: i.score, reverse=True)

        # Keep the pool small. Dropped ids stay "seen" so they don't resurface
        # tomorrow, unless they start trending (see assign()).
        for it in ordered[top_n + more_n + 20 :]:
            del pool[it.id]

        cache = self.store.summaries

        def off_topic(it: RawItem) -> bool:
            return cache.get(it.id, {}).get("about_ai") is False

        # Summarizing also tells us whether an item is really about AI. Drop the ones
        # that aren't and let the next-best items move up (a few rounds at most).
        for _ in range(3):
            candidates = [i for i in ordered if not off_topic(i)]
            top = select_top(candidates, top_n, out.get("top_caps", {}))
            self.enricher.enrich([i for i in top if i.id not in cache])
            self.summarizer.summarize(top)
            if not any(off_topic(i) for i in top):
                break
        top = [i for i in top if not off_topic(i)]
        top_ids = {i.id for i in top}
        more = [i for i in ordered if i.id not in top_ids and not off_topic(i)][:more_n]
        for it in top:
            self.store.featured[it.id] = day

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
            today = self.now.date().isoformat()
            return ("No items collected yet today." if day == today
                    else "Nothing was collected for this day."), "pending"
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

        items, aliases = dedupe(self.fetch_all(since))
        self.store.alias.update(aliases)
        days = recent_days(self.now.date(), self.store.pool_days)
        pools = {d: self.store.load_pool(d) for d in days}
        gaps = self.gap_days()
        if gaps:
            log.info("run: no runs happened on %s; backfilling them", ", ".join(gaps))
        touched = self.assign(items, pools, gaps)
        touched |= {d for d in days if pools[d] and publish.day_has_pending(self.docs, d)}

        written = []
        today = self.now.date().isoformat()
        for day in sorted(touched, reverse=True):  # today first: it gets quota priority
            if not pools[day] and day != today and day not in gaps:
                continue
            data = self.build_day(day, pools[day])
            if publish.write_day(self.docs, data):
                written.append(day)
            self.store.save_pool(day, pools[day])
        publish.write_index_and_latest(self.docs)
        self.store.save(self.now)
        log.info("run: wrote %s in %.1fs", ", ".join(written) or "nothing new", time.monotonic() - t0)
        return written
