from __future__ import annotations

from abc import ABC, abstractmethod
from datetime import datetime

import httpx

from ..models import RawItem


class Source(ABC):
    name: str = "base"

    def __init__(self, cfg: dict, http: httpx.Client):
        self.cfg = cfg
        self.http = http

    @abstractmethod
    def fetch(self, since: datetime) -> list[RawItem]:
        """Return items published/surfaced after `since` (UTC)."""
