"""Usage (from the repo root):  python -m collector run [--config collector/config.yaml]"""
from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from .pipeline import Pipeline


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="collector")
    ap.add_argument("command", choices=["run"])
    ap.add_argument("--config", default=str(Path(__file__).parent / "config.yaml"))
    ap.add_argument("--log-level", default="INFO")
    args = ap.parse_args(argv)
    logging.basicConfig(level=args.log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)  # request lines are noise
    Pipeline(Path(args.config)).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
