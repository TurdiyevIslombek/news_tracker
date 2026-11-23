"""Source plugins.

A source is a class with a `name` and `fetch(since) -> list[RawItem]`.
To add one: write a module here, subclass `Source`, and add it to REGISTRY
plus a matching block under `sources:` in config.yaml.
"""
from __future__ import annotations

from .arxiv import ArxivSource
from .base import Source
from .hf_papers import HFPapersSource

REGISTRY: dict[str, type[Source]] = {
    "arxiv": ArxivSource,
    "hf_papers": HFPapersSource,
}

__all__ = ["REGISTRY", "Source"]
