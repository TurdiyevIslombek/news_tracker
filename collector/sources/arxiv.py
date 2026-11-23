"""arXiv API source (https://info.arxiv.org/help/api/).

Etiquette: one request at a time, >= 3 s between requests, descriptive User-Agent.
"""
from __future__ import annotations

import logging
import re
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

from ..models import RawItem, parse_iso, utcnow
from .base import Source

log = logging.getLogger(__name__)
API = "https://export.arxiv.org/api/query"
NS = {"a": "http://www.w3.org/2005/Atom", "arxiv": "http://arxiv.org/schemas/atom"}
_VERSION = re.compile(r"v\d+$")


def arxiv_id_from_url(url: str) -> str | None:
    m = re.search(r"arxiv\.org/(?:abs|pdf)/([^\s?#]+?)(?:\.pdf)?(?:[?#]|$)", url)
    return _VERSION.sub("", m.group(1)) if m else None


def _clean(s: str | None) -> str:
    return re.sub(r"\s+", " ", s or "").strip()


def parse_feed(xml_text: str) -> list[RawItem]:
    # stdlib expat (Python >= 3.13 ships expat >= 2.6) does not fetch external
    # entities and limits entity expansion, so no defusedxml dependency needed.
    root = ET.fromstring(xml_text)
    items = []
    for e in root.findall("a:entry", NS):
        abs_url = _clean(e.findtext("a:id", namespaces=NS))
        aid = arxiv_id_from_url(abs_url)
        if not aid:
            continue
        items.append(
            RawItem(
                id=f"arxiv:{aid}",
                title=_clean(e.findtext("a:title", namespaces=NS)),
                url=f"https://arxiv.org/abs/{aid}",
                source="arxiv",
                published_at=parse_iso(_clean(e.findtext("a:published", namespaces=NS))),
                text=_clean(e.findtext("a:summary", namespaces=NS)),
                arxiv_id=aid,
                category_hint="Research",
            )
        )
    return items


class ArxivSource(Source):
    name = "arxiv"

    def fetch(self, since: datetime) -> list[RawItem]:
        cats = " OR ".join(f"cat:{c}" for c in self.cfg["categories"])
        # The API only lists papers after arXiv *announces* them, 1-3 days after
        # submission (longer over weekends). So search a rolling window; the
        # pipeline's seen-index stops papers from repeating across days.
        since = min(since, utcnow() - timedelta(days=self.cfg.get("window_days", 4)))
        lo = since.astimezone(timezone.utc).strftime("%Y%m%d%H%M")
        hi = utcnow().strftime("%Y%m%d%H%M")
        query = f"({cats}) AND submittedDate:[{lo} TO {hi}]"
        page, cap = self.cfg.get("page_size", 200), self.cfg.get("max_results", 600)
        delay = max(3.0, float(self.cfg.get("delay_seconds", 3)))
        out: list[RawItem] = []
        start = 0
        while start < cap:
            if start:
                time.sleep(delay)
            r = self.http.get(
                API,
                params={
                    "search_query": query,
                    "sortBy": "submittedDate",
                    "sortOrder": "descending",
                    "start": start,
                    "max_results": min(page, cap - start),
                },
            )
            r.raise_for_status()
            batch = parse_feed(r.text)
            out.extend(i for i in batch if i.published_at >= since)
            if len(batch) < page:
                break
            start += page
        log.info("arxiv: %d items since %s", len(out), since.isoformat())
        return out
