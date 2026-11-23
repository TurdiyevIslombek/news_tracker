from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import httpx
import pytest
import yaml

from collector.chain import Chain
from collector.llm import providers_from_config
from collector.models import RawItem
from collector.pipeline import Pipeline
from collector.sources.base import Source

NOW = datetime(2026, 11, 23, 12, 0, tzinfo=timezone.utc)


def make_items(n: int = 3) -> list[RawItem]:
    return [
        RawItem(
            id=f"arxiv:2611.0000{i}",
            title=f"Paper number {i} about efficient attention",
            url=f"https://huggingface.co/papers/2611.0000{i}",
            source="hf_papers",
            published_at=NOW,
            text=f"We propose method {i}. " * 20,
            arxiv_id=f"2611.0000{i}",
            signals={"hf_upvotes": 10 * (i + 1)},
        )
        for i in range(n)
    ]


class FakeSource(Source):
    name = "fake"
    items: list[RawItem] = []

    def fetch(self, since):
        return [RawItem(**{**it.__dict__}) for it in self.items]


def ok_reply(request: httpx.Request) -> httpx.Response:
    """A provider that answers correctly: summaries for item prompts, else a headline."""
    body = json.loads(request.content)
    prompt = body["messages"][-1]["content"]
    if "Items:\n" in prompt:
        items = json.loads(prompt.split("Items:\n", 1)[1])
        content = {"items": [
            {"id": it["id"], "category": "Research", "summary": f"Summary of {it['id']}.",
             "why_it_matters": "It matters."} for it in items
        ]}
    else:
        content = {"headline": "Today in AI: a few papers on attention."}
    return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(content)}}]})


class Router:
    """httpx MockTransport handler: per-host behaviour + call counts."""

    def __init__(self, behaviours: dict):
        self.behaviours = behaviours
        self.calls: dict[str, int] = {}

    def __call__(self, request: httpx.Request) -> httpx.Response:
        host = request.url.host
        self.calls[host] = self.calls.get(host, 0) + 1
        b = self.behaviours[host]
        return b(request) if callable(b) else httpx.Response(b, json={"error": "nope"})


@pytest.fixture
def repo(tmp_path: Path, monkeypatch):
    """A throwaway repo root with a config that has two fake providers."""
    real = yaml.safe_load((Path(__file__).parents[1] / "config.yaml").read_text())
    real["sources"] = {"fake": {"enabled": True}}
    real["llm"]["providers"] = [
        {"name": "p1", "base_url": "https://p1.test/v1", "model": "model-a", "key_env": "P1_KEY"},
        {"name": "p2", "base_url": "https://p2.test/v1", "model": "model-b", "key_env": "P2_KEY"},
    ]
    (tmp_path / "collector").mkdir()
    (tmp_path / "collector" / "config.yaml").write_text(yaml.safe_dump(real))
    monkeypatch.setenv("P1_KEY", "k1")
    monkeypatch.setenv("P2_KEY", "k2")
    FakeSource.items = make_items()
    return tmp_path


def run_pipeline(repo: Path, router: Router, now: datetime = NOW) -> Pipeline:
    cfg = yaml.safe_load((repo / "collector" / "config.yaml").read_text())
    chain = Chain(providers_from_config(cfg["llm"]["providers"]), sleep=lambda s: None)
    http = httpx.Client(transport=httpx.MockTransport(router))
    p = Pipeline(repo / "collector" / "config.yaml", now=now, chain=chain,
                 sources={"fake": FakeSource}, http=http)
    p.run()
    return p


def read_day(repo: Path, day: str = "2026-11-23") -> dict:
    return json.loads((repo / "docs" / "days" / f"{day}.json").read_text())
