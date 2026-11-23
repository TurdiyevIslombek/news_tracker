"""Hacker News via the Algolia API: AI/ML stories above a points threshold."""
from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta, timezone

from ..ids import arxiv_id_from_url, canonical_id
from ..models import RawItem, utcnow
from ..textutil import strip_html
from .base import Source

log = logging.getLogger(__name__)
API = "https://hn.algolia.com/api/v1/search_by_date"

# Title must mention one of these to count as AI news. Kept specific on purpose:
# words like "model" or "agent" alone pull in too much unrelated news.
AI_TERMS = re.compile(
    r"\b(AI|A\.I\.|AGI|LLMs?|GPTs?|GPT-?[\w.]+|ChatGPT|Claude|Gemini|Gemma|Llama|Mistral|Qwen|DeepSeek|"
    r"Kimi|GLM-?[\w.]*|Grok|OpenAI|Anthropic|DeepMind|Hugging ?Face|transformers?|neural( nets?| networks?)?|"
    r"machine learning|deep learning|reinforcement learning|diffusion models?|RLHF|fine-?tun\w*|"
    r"embeddings?|AI agents?|agentic|LLM agents?|coding agents?|Copilot|chatbots?|"
    r"language models?|foundation models?|world models?|open[- ]weights?|inference|MCP|vibe[- ]coding)\b",
    re.I,
)


def parse_hits(hits: list[dict], min_points: int) -> list[RawItem]:
    out = []
    for h in hits:
        title = (h.get("title") or "").strip()
        points = int(h.get("points") or 0)
        if points < min_points or not title or not AI_TERMS.search(title):
            continue
        hn_url = f"https://news.ycombinator.com/item?id={h['objectID']}"
        url = h.get("url") or hn_url
        aid = arxiv_id_from_url(url)
        hint = "Research" if aid else ("Tool / Open source" if "github.com/" in url else None)
        out.append(
            RawItem(
                id=canonical_id(url) if h.get("url") else f"hn:{h['objectID']}",
                title=title,
                url=url,
                source="hn",
                published_at=datetime.fromtimestamp(int(h["created_at_i"]), tz=timezone.utc),
                text=strip_html(h.get("story_text") or ""),
                arxiv_id=aid,
                signals={"hn_points": points},
                category_hint=hint,
            )
        )
    return out


class HNSource(Source):
    name = "hn"

    def fetch(self, since: datetime) -> list[RawItem]:
        # Stories keep gaining points for a day or two, so re-read a window and
        # let the pipeline refresh signals on items it has already placed.
        since = min(since, utcnow() - timedelta(hours=self.cfg.get("window_hours", 48)))
        min_points = self.cfg.get("min_points", 60)
        r = self.http.get(
            API,
            params={
                "tags": "story",
                "numericFilters": f"created_at_i>{int(since.timestamp())},points>={min_points}",
                "hitsPerPage": 1000,
            },
        )
        r.raise_for_status()
        items = parse_hits(r.json().get("hits", []), min_points)
        log.info("hn: %d AI stories with >= %d points", len(items), min_points)
        return items
