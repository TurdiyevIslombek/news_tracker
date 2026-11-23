"""Persistent run state, kept in `state/` (committed to the repo, not published).

state/state.json       last_run + which day each item id was assigned to
state/summaries.json   summary cache by item id (an item is never summarized twice)
state/headlines.json   headline per day + the top ids it was written from
state/pool/DAY.json    candidate items for recent days (with text, for re-ranking)
"""
from __future__ import annotations

import json
import os
from dataclasses import asdict
from datetime import date, datetime, timedelta
from pathlib import Path

from .models import RawItem, iso, parse_iso


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def write_json(path: Path, data, indent: int | None = 2) -> bool:
    """Atomic write. Returns False (and doesn't touch the file) if content is unchanged."""
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(data, ensure_ascii=False, indent=indent, sort_keys=False) + "\n"
    if path.exists() and path.read_text() == text:
        return False
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)
    return True


def item_to_dict(it: RawItem) -> dict:
    d = asdict(it)
    d["published_at"] = iso(it.published_at)
    return d


def item_from_dict(d: dict) -> RawItem:
    d = dict(d)
    d["published_at"] = parse_iso(d["published_at"])
    return RawItem(**d)


class Store:
    def __init__(self, root: Path, pool_days: int = 3, seen_days: int = 45):
        self.root = root
        self.pool_days = pool_days
        self.seen_days = seen_days
        self.state = read_json(root / "state.json", {})
        self.state.setdefault("last_run", None)
        self.state.setdefault("seen", {})      # item id -> day it was assigned to
        self.state.setdefault("featured", {})  # item id -> day it made the top list
        self.summaries: dict[str, dict] = read_json(root / "summaries.json", {})
        self.headlines: dict[str, dict] = read_json(root / "headlines.json", {})

    @property
    def featured(self) -> dict[str, str]:
        return self.state["featured"]

    @property
    def last_run(self) -> datetime | None:
        v = self.state.get("last_run")
        return parse_iso(v) if v else None

    def day_of(self, item_id: str) -> str | None:
        return self.state["seen"].get(item_id)

    def mark_seen(self, item_id: str, day: str) -> None:
        self.state["seen"][item_id] = day

    def load_pool(self, day: str) -> dict[str, RawItem]:
        raw = read_json(self.root / "pool" / f"{day}.json", [])
        return {d["id"]: item_from_dict(d) for d in raw}

    def save_pool(self, day: str, pool: dict[str, RawItem]) -> None:
        write_json(self.root / "pool" / f"{day}.json", [item_to_dict(i) for i in pool.values()], indent=None)

    def save(self, now: datetime) -> None:
        today = now.date()
        cutoff = (today - timedelta(days=self.seen_days)).isoformat()
        for key in ("seen", "featured"):
            self.state[key] = {k: v for k, v in self.state[key].items() if v >= cutoff}
        self.state["last_run"] = iso(now)
        # Keep pools only for days that can still change.
        pool_cutoff = (today - timedelta(days=self.pool_days)).isoformat()
        for f in (self.root / "pool").glob("*.json"):
            if f.stem < pool_cutoff:
                f.unlink()
        write_json(self.root / "state.json", self.state, indent=None)
        write_json(self.root / "summaries.json", self.summaries, indent=None)
        write_json(self.root / "headlines.json", self.headlines)


def recent_days(today: date, n: int) -> list[str]:
    return [(today - timedelta(days=i)).isoformat() for i in range(n)]
