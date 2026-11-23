"""Source plugins.

A source is a class with a `name` and `fetch(since) -> list[RawItem]`.
To add one: write a module here, subclass `Source`, add it to REGISTRY, and add
a matching block under `sources:` in config.yaml (its dict is passed as `cfg`).
Use `ids.canonical_id(url)` for the item id so it dedupes with other sources.
"""
from __future__ import annotations

from .arxiv import ArxivSource
from .base import Source
from .github import GitHubSource
from .hf_papers import HFPapersSource
from .hn import HNSource
from .rss import BlogsSource

REGISTRY: dict[str, type[Source]] = {
    "arxiv": ArxivSource,
    "hf_papers": HFPapersSource,
    "blogs": BlogsSource,
    "hn": HNSource,
    "github": GitHubSource,
}

__all__ = ["REGISTRY", "Source"]
