"""Small HTML/markdown → plain text helpers (stdlib only)."""
from __future__ import annotations

import html
import re
from html.parser import HTMLParser


def clean(s: str | None) -> str:
    return re.sub(r"\s+", " ", s or "").strip()


def strip_html(s: str | None) -> str:
    s = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", s or "")
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    return clean(html.unescape(s))


def strip_markdown(s: str) -> str:
    s = re.sub(r"(?s)```.*?```", " ", s)                 # code blocks
    s = re.sub(r"(?s)<!--.*?-->", " ", s)
    s = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", s)          # images
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)       # links → text
    s = re.sub(r"(?m)^\s*[#>|*-]+\s*", " ", s)           # headings, quotes, tables, bullets
    s = re.sub(r"[*_`]{1,3}", "", s)
    return strip_html(s)


class _ArticleText(HTMLParser):
    """Collect paragraph text, preferring content inside <article>/<main>."""

    SKIP = {"script", "style", "nav", "footer", "header", "aside", "form", "noscript", "svg"}
    KEEP = {"p", "h1", "h2", "h3", "li"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.skip = 0
        self.in_main = 0
        self.cur: list[str] | None = None
        self.main_parts: list[str] = []
        self.all_parts: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        elif tag in ("article", "main"):
            self.in_main += 1
        elif tag in self.KEEP and not self.skip:
            self.cur = []

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skip = max(0, self.skip - 1)
        elif tag in ("article", "main"):
            self.in_main = max(0, self.in_main - 1)
        elif tag in self.KEEP and self.cur is not None:
            text = clean("".join(self.cur))
            if len(text) > 40:
                self.all_parts.append(text)
                if self.in_main:
                    self.main_parts.append(text)
            self.cur = None

    def handle_data(self, data):
        if self.cur is not None and not self.skip:
            self.cur.append(data)


def article_text(page_html: str, max_chars: int = 4000) -> str:
    p = _ArticleText()
    try:
        p.feed(page_html)
    except Exception:
        return ""
    parts = p.main_parts if sum(map(len, p.main_parts)) > 300 else p.all_parts
    return " ".join(parts)[:max_chars]
