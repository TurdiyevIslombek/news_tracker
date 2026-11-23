"""Merge duplicates: same id (arXiv ID / repo / normalized URL) or a near-identical title.

Merged records combine signals (e.g. an HF paper that is also on HN keeps both
its upvotes and its points). The losing id is returned as an alias of the kept
one, so later runs map it straight onto the same item.
"""
from __future__ import annotations

import re
from difflib import SequenceMatcher

from .ids import normalize_url
from .models import RawItem

# Prefer these sources' URL/title when merging (most useful landing page first).
SOURCE_PRIORITY = ["hf_papers", "blog", "github", "hn", "arxiv"]
_WORD = re.compile(r"[a-z0-9]+")
_STOP = {"the", "a", "an", "of", "for", "and", "to", "in", "on", "with", "via", "is", "by", "show", "hn"}


def _prio(source: str) -> int:
    base = source.split(":")[0]
    return SOURCE_PRIORITY.index(base) if base in SOURCE_PRIORITY else len(SOURCE_PRIORITY)


def title_tokens(title: str) -> set[str]:
    return {w for w in _WORD.findall(title.lower()) if w not in _STOP}


def same_title(a: str, b: str, threshold: float = 0.9) -> bool:
    """Near-identical titles: cheap token-overlap gate, then a character-level ratio."""
    ta, tb = title_tokens(a), title_tokens(b)
    if len(ta) < 4 or len(tb) < 4:
        return False
    if len(ta & tb) / len(ta | tb) < 0.6:
        return False
    norm = lambda s: " ".join(_WORD.findall(s.lower()))  # noqa: E731
    return SequenceMatcher(None, norm(a), norm(b)).ratio() >= threshold


def merge(a: RawItem, b: RawItem) -> RawItem:
    """Combine two records of the same thing; the higher-priority source stays primary."""
    if _prio(b.source) < _prio(a.source):
        a, b = b, a
    signals = dict(a.signals)
    for k, v in b.signals.items():
        signals[k] = max(signals.get(k, 0), v)
    a.signals = signals
    if len(a.text) < 200 and len(b.text) > len(a.text):  # keep the primary's own text if it has any
        a.text = b.text
    a.published_at = min(a.published_at, b.published_at)
    a.lab = a.lab or b.lab
    a.arxiv_id = a.arxiv_id or b.arxiv_id
    a.category_hint = a.category_hint or b.category_hint
    a.enriched = a.enriched or b.enriched
    a.sources = sorted(set(a.sources) | set(b.sources), key=_prio)
    return a


def dedupe(items: list[RawItem], fuzzy: float = 0.9) -> tuple[list[RawItem], dict[str, str]]:
    """Returns (unique items, {dropped_id: kept_id})."""
    by_id: dict[str, RawItem] = {}
    url_to_id: dict[str, str] = {}
    aliases: dict[str, str] = {}
    for it in items:
        nu = normalize_url(it.url)
        target = it.id if it.id in by_id else url_to_id.get(nu)
        if target is None:
            target = next((k for k, o in by_id.items()
                           if not (it.arxiv_id or o.arxiv_id) and same_title(it.title, o.title, fuzzy)), None)
        if target is None:
            by_id[it.id] = it
            url_to_id[nu] = it.id
            continue
        kept = merge(by_id.pop(target), it)
        dropped = it.id if kept.id == target else target
        if dropped != kept.id:
            aliases[dropped] = kept.id
        by_id[kept.id] = kept
        url_to_id[nu] = kept.id
        url_to_id[normalize_url(kept.url)] = kept.id
    # Ids that pointed at a now-dropped id should point at its replacement.
    for k, v in list(aliases.items()):
        while v in aliases:
            v = aliases[v]
        aliases[k] = v
    return list(by_id.values()), aliases
