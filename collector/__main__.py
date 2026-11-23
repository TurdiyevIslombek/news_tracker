"""Usage (from the repo root):  python -m collector run [--config collector/config.yaml]"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

from .pipeline import Pipeline, load_config


def check_providers(config: Path) -> int:
    """Ping every provider in the chain with a tiny request. Never prints keys."""
    import httpx

    from .llm import Provider, ProviderError, chat
    from dataclasses import fields

    cfg = load_config(config)
    known = {f.name for f in fields(Provider)}
    ok = 0
    with httpx.Client() as http:
        for raw in cfg["llm"]["providers"]:
            p = Provider(**{k: v for k, v in raw.items() if k in known})
            if not p.api_key:
                print(f"  skip  {p.label:45s} ({p.key_env} not set)")
                continue
            try:
                reply = chat(p, [{"role": "user", "content": "Reply with the single word: ok"}], 0, http)
                print(f"  ok    {p.label:45s} -> {reply.strip()[:20]!r}")
                ok += 1
            except ProviderError as e:
                print(f"  FAIL  {p.label:45s} HTTP {e.status}")
    print(f"{ok} provider(s) working")
    return 0 if ok else 1


def load_dotenv(path: Path) -> None:
    """Local convenience: read KEY=value lines from .env without overriding real env vars."""
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.removeprefix("export ").strip()
        os.environ.setdefault(k, v.strip().strip("'\""))


def main(argv: list[str] | None = None) -> int:
    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
    ap = argparse.ArgumentParser(prog="collector")
    ap.add_argument("command", choices=["run", "providers"])
    ap.add_argument("--config", default=str(Path(__file__).parent / "config.yaml"))
    ap.add_argument("--log-level", default="INFO")
    args = ap.parse_args(argv)
    logging.basicConfig(level=args.log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)  # request lines are noise
    if args.command == "providers":
        return check_providers(Path(args.config))
    Pipeline(Path(args.config)).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
