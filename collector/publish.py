"""Write the public JSON feed: days/YYYY-MM-DD.json, index.json, latest.json."""
from __future__ import annotations

from pathlib import Path

from .models import iso, utcnow
from .store import read_json, write_json

SCHEMA_VERSION = 1


def write_day(docs: Path, day: dict) -> bool:
    return write_json(docs / "days" / f"{day['date']}.json", day)


def write_index_and_latest(docs: Path) -> None:
    days = []
    for f in sorted((docs / "days").glob("*.json"), reverse=True):
        d = read_json(f, None)
        if not d:
            continue
        days.append(
            {
                "date": d["date"],
                "headline": d.get("headline", ""),
                "item_count": len(d.get("items", [])),
                "generated_at": d.get("generated_at"),
            }
        )
    if not days:
        return
    index = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": iso(utcnow()),
        "latest": days[0]["date"],
        "days": days,
    }
    write_json(docs / "index.json", index)
    write_json(docs / "latest.json", read_json(docs / "days" / f"{days[0]['date']}.json", {}))
