"""Merge duplicate items (same arXiv ID or same normalized URL), combining their signals."""
from __future__ import annotations

import re
from urllib.parse import urlsplit, urlunsplit

from .models import RawItem

# Prefer these sources' URL/title when merging (most useful landing page first).
SOURCE_PRIORITY = ["hf_papers", "blog", "github", "hn", "arxiv"]


def normalize_url(url: str) -> str:
    parts = urlsplit(url.strip())
    host = parts.netloc.lower().removeprefix("www.")
    path = re.sub(r"/+$", "", parts.path)
    return urlunsplit(("https", host, path, "", ""))


def _prio(source: str) -> int:
    base = source.split(":")[0]
    return SOURCE_PRIORITY.index(base) if base in SOURCE_PRIORITY else len(SOURCE_PRIORITY)


def merge(a: RawItem, b: RawItem) -> RawItem:
    """Combine two records of the same thing; `a` is kept as the primary."""
    if _prio(b.source) < _prio(a.source):
        a, b = b, a
    signals = dict(a.signals)
    for k, v in b.signals.items():
        signals[k] = max(signals.get(k, 0), v)
    a.signals = signals
    if len(b.text) > len(a.text):
        a.text = b.text
    a.published_at = min(a.published_at, b.published_at)
    a.lab = a.lab or b.lab
    a.arxiv_id = a.arxiv_id or b.arxiv_id
    a.category_hint = a.category_hint or b.category_hint
    a.sources = sorted(set(a.sources) | set(b.sources), key=_prio)
    return a


def key_of(item: RawItem) -> str:
    return f"arxiv:{item.arxiv_id}" if item.arxiv_id else normalize_url(item.url)


def dedupe(items: list[RawItem]) -> list[RawItem]:
    by_key: dict[str, RawItem] = {}
    url_to_key: dict[str, str] = {}
    for it in items:
        k = key_of(it)
        nu = normalize_url(it.url)
        if k not in by_key and nu in url_to_key:
            k = url_to_key[nu]
        if k in by_key:
            by_key[k] = merge(by_key[k], it)
        else:
            by_key[k] = it
        url_to_key[nu] = k
    return list(by_key.values())
