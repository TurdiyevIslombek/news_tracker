"""Hugging Face Daily Papers: the "papers people actually care about" signal."""
from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta

from ..models import RawItem, parse_iso, utcnow
from .base import Source

log = logging.getLogger(__name__)


def parse_entries(data: list[dict]) -> list[RawItem]:
    items = []
    for d in data:
        p = d.get("paper") or {}
        aid = p.get("id")
        if not aid:
            continue
        surfaced = p.get("submittedOnDailyAt") or d.get("publishedAt") or p.get("publishedAt")
        items.append(
            RawItem(
                id=f"arxiv:{aid}",
                title=re.sub(r"\s+", " ", p.get("title") or d.get("title") or "").strip(),
                url=f"https://huggingface.co/papers/{aid}",
                source="hf_papers",
                published_at=parse_iso(surfaced) if surfaced else utcnow(),
                text=re.sub(r"\s+", " ", p.get("summary") or d.get("summary") or "").strip(),
                arxiv_id=aid,
                category_hint="Research",
                signals={"hf_upvotes": int(p.get("upvotes") or 0)},
            )
        )
    return items


class HFPapersSource(Source):
    name = "hf_papers"

    def fetch(self, since: datetime) -> list[RawItem]:
        # Daily lists are keyed by date and keep collecting upvotes for a while,
        # so re-read every date from `since` (minus a day) through today.
        today = utcnow().date()
        day = min(since.date() - timedelta(days=1), today)
        by_id: dict[str, RawItem] = {}
        while day <= today:
            r = self.http.get(self.cfg["url"], params={"date": day.isoformat(), "limit": 100})
            r.raise_for_status()
            for it in parse_entries(r.json()):
                by_id[it.id] = it
            day += timedelta(days=1)
        log.info("hf_papers: %d items", len(by_id))
        return list(by_id.values())
