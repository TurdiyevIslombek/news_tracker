"""Write the public JSON feed: days/YYYY-MM-DD.json, index.json, latest.json."""
from __future__ import annotations

from pathlib import Path

from .models import iso, utcnow
from .store import read_json, write_json

SCHEMA_VERSION = 1


def _strip(d: dict) -> dict:
    return {k: v for k, v in d.items() if k != "generated_at"}


def write_day(docs: Path, day: dict) -> bool:
    """Write a day file unless only `generated_at` would change."""
    path = docs / "days" / f"{day['date']}.json"
    old = read_json(path, None)
    if old is not None and _strip(old) == _strip(day):
        return False
    return write_json(path, day)


def day_has_pending(docs: Path, date: str) -> bool:
    d = read_json(docs / "days" / f"{date}.json", None)
    if d is None:
        return False
    return d.get("headline_status") == "pending" or any(
        i.get("summary_status") == "pending" for i in d.get("items", [])
    )


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
