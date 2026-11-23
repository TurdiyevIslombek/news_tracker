"""Fill in thin items before summarizing, so the LLM has real text to work from.

- arXiv papers (e.g. found via HN): one arXiv API call for their abstracts.
- Blog posts / news links: fetch the article page only if robots.txt allows our
  User-Agent, then keep its paragraph text. Never retried once attempted.
"""
from __future__ import annotations

import ipaddress
import logging
import socket
from urllib.parse import urljoin, urlsplit, urlunsplit
from urllib.robotparser import RobotFileParser

import httpx

from .models import RawItem
from .sources.arxiv import API as ARXIV_API, parse_feed as parse_arxiv
from .textutil import article_text

log = logging.getLogger(__name__)
MAX_BYTES = 3_000_000
MAX_REDIRECTS = 5


def resolve_public(url: str) -> str | None:
    """SSRF guard (HN links are user-submitted and fetched from a CI runner).
    Returns one IP to connect to, only if the URL is http(s) and *every* address the
    host resolves to is public. The caller connects to that IP, so the name is never
    resolved a second time (no DNS-rebinding window)."""
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    try:
        port = parts.port or (443 if parts.scheme == "https" else 80)
        infos = socket.getaddrinfo(parts.hostname, port, type=socket.SOCK_STREAM)
    except (socket.gaierror, UnicodeError, ValueError):
        return None
    ips = [i[4][0].split("%")[0] for i in infos]
    if not ips or not all(ipaddress.ip_address(ip).is_global for ip in ips):
        return None
    return ips[0]


def is_public_url(url: str) -> bool:
    return resolve_public(url) is not None


class Enricher:
    def __init__(self, http: httpx.Client, cfg: dict, agent: str = "AIPulse",
                 resolver=resolve_public):
        self.http = http
        self.resolver = resolver
        self.min_chars = cfg.get("min_text_chars", 400)
        self.max_chars = cfg.get("max_article_chars", 4000)
        self.timeout = cfg.get("timeout_seconds", 15)
        self.agent = agent
        self._robots: dict[str, RobotFileParser | None] = {}

    def safe_get(self, url: str, max_bytes: int = MAX_BYTES) -> tuple[int, httpx.Headers, str] | None:
        """GET that re-validates the target on every redirect hop and stops reading
        after `max_bytes` (bodies are streamed, so a huge page can't exhaust memory)."""
        for _ in range(MAX_REDIRECTS + 1):
            parts = urlsplit(url)
            ip = self.resolver(url)
            if ip is None:
                log.info("enrich: refusing non-public URL host %s", parts.hostname)
                return None
            # Connect to the vetted IP; keep Host + SNI so TLS still verifies the real name.
            netloc = (f"[{ip}]" if ":" in ip else ip) + (f":{parts.port}" if parts.port else "")
            pinned = urlunsplit((parts.scheme, netloc, parts.path or "/", parts.query, ""))
            host_header = parts.hostname + (f":{parts.port}" if parts.port else "")
            ext = {"sni_hostname": parts.hostname} if parts.scheme == "https" else {}
            with self.http.stream("GET", pinned, headers={"Host": host_header}, extensions=ext,
                                  timeout=self.timeout, follow_redirects=False) as r:
                if r.is_redirect and "location" in r.headers:
                    url = urljoin(url, r.headers["location"])
                    continue
                if int(r.headers.get("content-length") or 0) > max_bytes:
                    return None
                buf = bytearray()
                for chunk in r.iter_bytes():
                    buf += chunk
                    if len(buf) > max_bytes:
                        return None
                return r.status_code, r.headers, buf.decode(r.encoding or "utf-8", "replace")
        return None

    def allowed(self, url: str) -> bool:
        parts = urlsplit(url)
        host = f"{parts.scheme}://{parts.netloc}"
        if host not in self._robots:
            rp: RobotFileParser | None = RobotFileParser()
            try:
                r = self.safe_get(host + "/robots.txt", max_bytes=500_000)
                if r is None or r[0] in (401, 403):
                    rp = None                      # locked down: treat as "no"
                elif r[0] >= 400:
                    rp.parse([])                   # no robots.txt: allowed
                else:
                    rp.parse(r[2].splitlines())
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
            r = self.safe_get(it.url)
            if r is None or r[0] != 200 or "html" not in r[1].get("content-type", ""):
                return
            text = article_text(r[2], self.max_chars)
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
