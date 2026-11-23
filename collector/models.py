"""Core data types shared by sources and the pipeline."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone

CATEGORIES = ["Research", "Training method", "Model release", "Tool / Open source", "Industry"]


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s: str) -> datetime:
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


@dataclass
class RawItem:
    """One thing a source found. `id` is stable across runs (e.g. "arxiv:2511.01234")."""

    id: str
    title: str
    url: str
    source: str                      # "arxiv" | "hf_papers" | "blog:openai" | "hn" | "github"
    published_at: datetime
    text: str = ""                   # abstract / article text used for summarizing
    signals: dict[str, int] = field(default_factory=dict)
    arxiv_id: str | None = None      # lets papers from different sources dedupe
    lab: str | None = None           # set when the item comes from a major lab
    category_hint: str | None = None
    sources: list[str] = field(default_factory=list)  # all sources after dedupe
    score: float = 0.0
    enriched: bool = False           # tried fetching fuller text (article / abstract)

    def __post_init__(self) -> None:
        if not self.sources:
            self.sources = [self.source]
