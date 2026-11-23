from __future__ import annotations

from datetime import datetime, timezone

from collector.dedupe import dedupe
from collector.models import RawItem
from collector.ids import arxiv_id_from_url
from collector.sources.arxiv import parse_feed
from collector.sources.hf_papers import parse_entries

ATOM = """<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
  <entry>
    <id>http://arxiv.org/abs/2611.27983v2</id>
    <published>2026-11-20T18:58:45Z</published>
    <title>Optimal Linear
      Regression</title>
    <summary>  We study regression.  </summary>
  </entry>
</feed>"""


def test_arxiv_parse_strips_version_and_whitespace():
    [it] = parse_feed(ATOM)
    assert it.id == "arxiv:2611.27983"
    assert it.title == "Optimal Linear Regression"
    assert it.url == "https://arxiv.org/abs/2611.27983"
    assert it.text == "We study regression."


def test_arxiv_id_from_url():
    assert arxiv_id_from_url("https://arxiv.org/pdf/2611.01234v3.pdf") == "2611.01234"
    assert arxiv_id_from_url("https://example.com/x") is None


def test_hf_parse_reads_upvotes():
    [it] = parse_entries([{"paper": {"id": "2611.1", "title": "T", "summary": "S", "upvotes": 42,
                                     "submittedOnDailyAt": "2026-11-23T10:00:00.000Z"}}])
    assert it.id == "arxiv:2611.1" and it.signals == {"hf_upvotes": 42}


def test_dedupe_merges_same_paper_and_keeps_best_signals():
    t = datetime(2026, 11, 23, tzinfo=timezone.utc)
    a = RawItem(id="arxiv:1", title="X", url="https://arxiv.org/abs/1", source="arxiv",
                published_at=t, text="long abstract text", arxiv_id="1")
    b = RawItem(id="arxiv:1", title="X", url="https://huggingface.co/papers/1", source="hf_papers",
                published_at=t, text="short", arxiv_id="1", signals={"hf_upvotes": 9})
    [m], aliases = dedupe([a, b])
    assert m.source == "hf_papers" and m.signals["hf_upvotes"] == 9
    assert m.text == "long abstract text" and set(m.sources) == {"arxiv", "hf_papers"}
