"""Fill in thin items before summarizing, so the LLM has real text to work from.

- arXiv papers (e.g. found via HN): one arXiv API call for their abstracts.
- Blog posts / news links: fetch the article page only if robots.txt allows our
  User-Agent, then keep its paragraph text. Never retried once attempted.
"""
from __future__ import annotations

import logging
from urllib.parse import urlsplit
from urllib.robotparser import RobotFileParser

import httpx

from .models import RawItem
from .sources.arxiv import API as ARXIV_API, parse_feed as parse_arxiv
from .textutil import article_text

log = logging.getLogger(__name__)
MAX_BYTES = 3_000_000


class Enricher:
    def __init__(self, http: httpx.Client, cfg: dict, agent: str = "AIPulse"):
        self.http = http
        self.min_chars = cfg.get("min_text_chars", 400)
        self.max_chars = cfg.get("max_article_chars", 4000)
        self.timeout = cfg.get("timeout_seconds", 15)
        self.agent = agent
        self._robots: dict[str, RobotFileParser | None] = {}

    def allowed(self, url: str) -> bool:
        parts = urlsplit(url)
        host = f"{parts.scheme}://{parts.netloc}"
        if host not in self._robots:
            rp: RobotFileParser | None = RobotFileParser()
            try:
                r = self.http.get(host + "/robots.txt", timeout=self.timeout)
                if r.status_code in (401, 403):
                    rp = None                      # locked down: treat as "no"
                elif r.status_code >= 400:
                    rp.parse([])                   # no robots.txt: allowed
                else:
                    rp.parse(r.text.splitlines())
            except httpx.HTTPError:
                rp = None                          # can't check: don't fetch
            self._robots[host] = rp
        rp = self._robots[host]
        return rp is not None and rp.can_fetch(self.agent, url)

    def _arxiv(self, items: list[RawItem]) -> None:
        try:
            r = self.http.get(ARXIV_API, params={"id_list": ",".join(i.arxiv_id for i in items),
                                                 "max_results": len(items)})
            r.raise_for_status()
            by_id = {p.arxiv_id: p for p in parse_arxiv(r.text)}
        except Exception as e:
            log.info("enrich: arXiv lookup failed (%s)", type(e).__name__)
            return
        for it in items:
            p = by_id.get(it.arxiv_id)
            if p and len(p.text) > len(it.text):
                it.text = p.text

    def _article(self, it: RawItem) -> None:
        if not it.url.startswith("http") or not self.allowed(it.url):
            log.info("enrich: robots.txt disallows (or can't check) %s", urlsplit(it.url).netloc)
            return
        try:
            r = self.http.get(it.url, timeout=self.timeout)
            if r.status_code != 200 or "html" not in r.headers.get("content-type", ""):
                return
            if len(r.content) > MAX_BYTES:
                return
            text = article_text(r.text, self.max_chars)
            if len(text) > len(it.text):
                it.text = text
        except httpx.HTTPError as e:
            log.info("enrich: %s failed (%s)", urlsplit(it.url).netloc, type(e).__name__)

    def enrich(self, items: list[RawItem]) -> None:
        thin = [i for i in items if not i.enriched and len(i.text) < self.min_chars]
        papers = [i for i in thin if i.arxiv_id]
        if papers:
            self._arxiv(papers)
        for it in thin:
            if not it.arxiv_id and not it.source.startswith("github") and not it.url.startswith(
                    "https://news.ycombinator.com"):
                self._article(it)
            it.enriched = True
        if thin:
            log.info("enrich: %d thin item(s) checked", len(thin))
