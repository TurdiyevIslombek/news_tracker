"""Ranking score and fallback category heuristics.

score = w_hf * log1p(hf_upvotes) + w_hn * log1p(hn_points) + w_gh * log1p(github_stars)
      + w_lab_blog * [official lab blog post]  or  w_lab * [paper/repo from a major lab]
      + w_multi * (extra non-arXiv sources, e.g. HF paper also on HN)
      + w_recency * exp(-age_hours / half_life)

Log scaling keeps one viral item from drowning everything else; weights live in config.yaml.
"""
from __future__ import annotations

import math
import re
from datetime import datetime

from .models import RawItem, utcnow


def score(item: RawItem, cfg: dict, now: datetime | None = None) -> float:
    w = cfg["weights"]
    s = item.signals
    now = now or utcnow()
    age_h = max(0.0, (now - item.published_at).total_seconds() / 3600)
    val = (
        w["hf_upvotes"] * math.log1p(s.get("hf_upvotes", 0))
        + w["hn_points"] * math.log1p(s.get("hn_points", 0))
        + w["github_stars"] * math.log1p(s.get("github_stars", 0))
        + (w.get("lab_blog_bonus", w["lab_bonus"]) if item.source.startswith("blog:")
           else w["lab_bonus"] if item.lab else 0.0)
        + w["multi_source"] * max(0, len([x for x in item.sources if x != "arxiv"]) - 1)
        + w["recency"] * math.exp(-age_h / cfg["recency_half_life_hours"])
    )
    return round(val, 3)


_TRAINING = re.compile(
    r"\b(fine-?tun\w*|pre-?train\w*|post-?train\w*|rlhf|rlvr|reinforcement learning|"
    r"preference optimi[sz]ation|dpo|grpo|distill\w*|optimi[sz]er|scaling laws?|"
    r"curriculum|quantiz\w*|lora|training recipe|self-?play|reward model\w*)\b",
    re.I,
)
_RELEASE = re.compile(r"\b(introducing|announcing|releas\w*|launch\w*|now available|open-?weights?)\b", re.I)


def heuristic_category(item: RawItem) -> str:
    """Cheap category used for "more" items and when no LLM is available."""
    base = item.source.split(":")[0]
    if base == "github":
        return "Tool / Open source"
    if base in ("arxiv", "hf_papers"):
        return "Training method" if _TRAINING.search(item.title) else "Research"
    if _RELEASE.search(item.title):
        return "Model release"
    return item.category_hint or "Industry"
