"""Lab blogs via RSS / Atom. Each feed is configured in config.yaml under sources.blogs."""
from __future__ import annotations

import logging
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta
from email.utils import parsedate_to_datetime

from ..ids import canonical_id
from ..models import RawItem, parse_iso, utcnow
from ..textutil import clean, strip_html
from .base import Source

log = logging.getLogger(__name__)
A = "{http://www.w3.org/2005/Atom}"
CONTENT = "{http://purl.org/rss/1.0/modules/content/}encoded"


def _date(s: str | None) -> datetime | None:
    if not s:
        return None
    s = s.strip()
    try:
        return parse_iso(s)
    except ValueError:
        pass
    try:
        return parsedate_to_datetime(s)
    except (TypeError, ValueError):
        return None


def _text(e: ET.Element, *tags: str) -> str:
    for t in tags:
        x = e.find(t)
        if x is not None and (x.text or "").strip():
            return x.text or ""
    return ""


def parse_feed(xml_text: str, feed: dict) -> list[RawItem]:
    """Parse RSS 2.0 or Atom into RawItems (stdlib expat: no external entities)."""
    root = ET.fromstring(xml_text)
    entries = root.findall(".//item") or root.findall(f"{A}entry")
    out = []
    for e in entries:
        link = _text(e, "link")
        if not link:
            le = e.find(f"{A}link[@rel='alternate']")
            if le is None:
                le = e.find(f"{A}link")  # (Element truthiness is about children, so no `or`)
            link = le.get("href", "") if le is not None else ""
        title = clean(strip_html(_text(e, "title", f"{A}title")))
        published = _date(_text(e, "pubDate", f"{A}published", f"{A}updated", "{http://purl.org/dc/elements/1.1/}date"))
        if not link or not title or not published:
            continue
        body = strip_html(_text(e, CONTENT, f"{A}content", "description", f"{A}summary"))
        out.append(
            RawItem(
                id=canonical_id(link),
                title=title,
                url=link.strip(),
                source=f"blog:{feed['name']}",
                published_at=published,
                text=body,
                lab=feed.get("lab"),
                category_hint=feed.get("category_hint"),
            )
        )
    return out


class BlogsSource(Source):
    name = "blogs"

    def fetch(self, since: datetime) -> list[RawItem]:
        # Feeds sometimes surface posts late; look back a bit further and let the
        # pipeline's seen-index drop repeats.
        since = min(since, utcnow() - timedelta(hours=self.cfg.get("lookback_hours", 48)))
        out: list[RawItem] = []
        for feed in self.cfg["feeds"]:
            try:
                r = self.http.get(feed["url"])
                r.raise_for_status()
                items = [i for i in parse_feed(r.text, feed) if i.published_at >= since]
                out.extend(items)
                log.info("blogs: %s → %d new", feed["name"], len(items))
            except Exception as e:  # one broken feed must not kill the others
                log.warning("blogs: %s failed: %s: %s", feed["name"], type(e).__name__, str(e)[:120])
        return out
