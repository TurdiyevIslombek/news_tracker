"""Notable new AI repos via the GitHub search API, with a basic star-farming filter.

Star-farmed repos are common in AI topics. We skip a repo if its owner account is
very new, or if its watcher count is wildly out of line with its stars (bought
engagement tends to inflate both).
"""
from __future__ import annotations

import base64
import logging
import os
from datetime import datetime, timedelta

from ..models import RawItem, parse_iso, utcnow
from ..textutil import clean, strip_markdown
from .base import Source

log = logging.getLogger(__name__)
API = "https://api.github.com"


class GitHubSource(Source):
    name = "github"

    def _get(self, path: str, **params):
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
        token = os.environ.get("GITHUB_TOKEN")
        if token:
            headers["Authorization"] = f"Bearer {token}"
        r = self.http.get(API + path, params=params or None, headers=headers)
        r.raise_for_status()
        return r.json()

    def looks_legit(self, repo: dict, now: datetime) -> bool:
        detail = self._get(f"/repos/{repo['full_name']}")
        stars = max(1, detail.get("stargazers_count", 0))
        if detail.get("subscribers_count", 0) / stars > self.cfg.get("max_watcher_ratio", 0.15):
            return False
        owner = self._get(f"/users/{repo['owner']['login']}")
        age_days = (now - parse_iso(owner["created_at"])).days
        return age_days >= self.cfg.get("min_owner_age_days", 90)

    def readme(self, full_name: str) -> str:
        try:
            data = self._get(f"/repos/{full_name}/readme")
            return strip_markdown(base64.b64decode(data.get("content", "")).decode("utf-8", "replace"))
        except Exception:
            return ""

    def fetch(self, since: datetime) -> list[RawItem]:
        now = utcnow()
        created_after = (now - timedelta(days=self.cfg.get("created_within_days", 7))).date().isoformat()
        min_stars = self.cfg.get("min_stars", 100)
        found: dict[str, dict] = {}
        for topic in self.cfg["topics"]:
            q = f"topic:{topic} created:>{created_after} stars:>={min_stars}"
            for repo in self._get("/search/repositories", q=q, sort="stars", order="desc", per_page=20)["items"]:
                if not repo.get("fork") and not repo.get("archived"):
                    found[repo["full_name"].lower()] = repo

        labs = {x.lower() for x in self.cfg.get("labs", [])}
        candidates = sorted(found.values(), key=lambda r: r["stargazers_count"], reverse=True)
        out: list[RawItem] = []
        for repo in candidates[: self.cfg.get("max_checked", 20)]:
            if len(out) >= self.cfg.get("max_repos", 10):
                break
            owner = repo["owner"]["login"]
            try:
                if owner.lower() not in labs and not self.looks_legit(repo, now):
                    log.info("github: skipping %s (looks star-farmed)", repo["full_name"])
                    continue
            except Exception as e:
                log.info("github: can't vet %s (%s); skipping", repo["full_name"], type(e).__name__)
                continue
            desc = clean(repo.get("description"))
            out.append(
                RawItem(
                    id=f"github:{repo['full_name']}".lower(),
                    title=f"{repo['full_name']}: {desc}"[:140] if desc else repo["full_name"],
                    url=repo["html_url"],
                    source="github",
                    published_at=parse_iso(repo["created_at"]),
                    text=clean(f"{desc}. {self.readme(repo['full_name'])}"),
                    signals={"github_stars": int(repo["stargazers_count"])},
                    lab=owner,
                    category_hint="Tool / Open source",
                )
            )
        log.info("github: %d repos kept of %d found", len(out), len(found))
        return out
