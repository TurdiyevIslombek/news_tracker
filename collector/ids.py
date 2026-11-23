"""Stable item ids, so the same thing from different sources (or runs) collapses into one.

  arxiv:2611.01234        any arxiv.org/abs|pdf or huggingface.co/papers link
  github:owner/repo       any github.com/owner/repo[/...] link
  web:<16 hex>            hash of the normalized URL, for everything else
"""
from __future__ import annotations

import hashlib
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

_VERSION = re.compile(r"v\d+$")
_TRACKING = re.compile(r"^(utm_\w+|ref|ref_src|source|fbclid|gclid|mc_cid|mc_eid|s|si)$", re.I)


def arxiv_id_from_url(url: str) -> str | None:
    m = re.search(r"(?:arxiv\.org/(?:abs|pdf|html)|huggingface\.co/papers)/([0-9]{4}\.[0-9]{4,5}(?:v\d+)?)", url)
    return _VERSION.sub("", m.group(1)) if m else None


def normalize_url(url: str) -> str:
    parts = urlsplit(url.strip())
    host = parts.netloc.lower().removeprefix("www.").removeprefix("m.")
    path = re.sub(r"/+$", "", parts.path) or "/"
    query = urlencode(sorted((k, v) for k, v in parse_qsl(parts.query) if not _TRACKING.match(k)))
    return urlunsplit(("https", host, path, query, ""))


def canonical_id(url: str) -> str:
    aid = arxiv_id_from_url(url)
    if aid:
        return f"arxiv:{aid}"
    nu = normalize_url(url)
    m = re.match(r"https://github\.com/([\w.-]+)/([\w.-]+)", nu)
    if m and m.group(1) not in ("orgs", "topics", "sponsors", "features", "about"):
        return f"github:{m.group(1)}/{m.group(2).removesuffix('.git')}".lower()
    return "web:" + hashlib.sha1(nu.encode()).hexdigest()[:16]
