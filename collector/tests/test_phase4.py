from __future__ import annotations

from datetime import datetime, timedelta, timezone

import httpx

from collector.dedupe import dedupe, same_title
from collector.enrich import Enricher
from collector.ids import canonical_id, normalize_url
from collector.models import RawItem
from collector.pipeline import select_top
from collector.sources.hn import parse_hits
from collector.sources.rss import parse_feed

from .conftest import NOW, FakeSource, Router, ok_reply, read_day, run_pipeline

RSS = """<?xml version="1.0"?><rss version="2.0"
 xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>
<item><title>Introducing Model X</title><link>https://lab.example/news/model-x?utm_source=rss</link>
<pubDate>Mon, 23 Nov 2026 10:00:00 GMT</pubDate><description>&lt;p&gt;Short.&lt;/p&gt;</description>
<content:encoded><![CDATA[<p>Model X is a <b>new</b> model.</p>]]></content:encoded></item>
</channel></rss>"""

ATOM = """<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
<entry><title>Faster kernels</title><link rel="alternate" href="https://dev.example/kernels"/>
<published>2026-11-23T09:00:00Z</published><summary>We made kernels faster.</summary></entry></feed>"""


def test_rss_and_atom_parse():
    [r] = parse_feed(RSS, {"name": "lab", "lab": "Lab"})
    assert r.source == "blog:lab" and r.lab == "Lab"
    assert r.text == "Model X is a new model."           # content:encoded wins, HTML stripped
    assert r.id == canonical_id("https://lab.example/news/model-x")  # tracking params ignored
    [a] = parse_feed(ATOM, {"name": "dev"})
    assert a.url == "https://dev.example/kernels" and a.text == "We made kernels faster."


def test_canonical_ids():
    assert canonical_id("https://huggingface.co/papers/2611.01234") == "arxiv:2611.01234"
    assert canonical_id("https://arxiv.org/pdf/2611.01234v2") == "arxiv:2611.01234"
    assert canonical_id("https://github.com/Org/Repo/tree/main") == "github:org/repo"
    assert normalize_url("http://www.x.com/a/?utm_medium=x&id=3") == "https://x.com/a?id=3"


def test_hn_keeps_ai_stories_above_threshold():
    hits = [
        {"objectID": "1", "title": "GLM-5.4: a loop transformer", "url": "https://z.ai/blog/glm-5.4",
         "points": 855, "created_at_i": 1795000000},
        {"objectID": "2", "title": "Show HN: My bread recipe", "url": "https://bread.example",
         "points": 900, "created_at_i": 1795000000},
        {"objectID": "3", "title": "New LLM paper", "url": "https://arxiv.org/abs/2611.00001",
         "points": 20, "created_at_i": 1795000000},
        {"objectID": "4", "title": "Ask HN: How do you use AI at work?", "url": None,
         "points": 300, "created_at_i": 1795000000},
    ]
    got = {i.id: i for i in parse_hits(hits, 60)}
    assert set(got) == {canonical_id("https://z.ai/blog/glm-5.4"), "hn:4"}
    assert got["hn:4"].url == "https://news.ycombinator.com/item?id=4"


def test_fuzzy_title_match():
    assert same_title("OpenAI releases GPT-6 with new reasoning mode",
                      "OpenAI Releases GPT-6, With New Reasoning Mode")
    assert not same_title("OpenAI releases GPT-6", "Google releases Gemini 5")
    assert not same_title("Short", "Short")  # too few words to judge


def test_dedupe_fuzzy_merges_blog_and_hn_and_records_alias():
    t = NOW
    blog = RawItem(id="web:aaa", title="Introducing Model X: faster open weights for everyone",
                   url="https://lab.example/x", source="blog:lab", published_at=t, text="long " * 50)
    hn = RawItem(id="web:bbb", title="Introducing Model X – faster open weights for everyone",
                 url="https://news.example/x", source="hn", published_at=t, signals={"hn_points": 400})
    [m], aliases = dedupe([hn, blog])
    assert m.source == "blog:lab" and m.signals["hn_points"] == 400
    assert aliases == {"web:bbb": "web:aaa"}


def item(i, source, score):
    it = RawItem(id=f"x:{i}", title=f"t{i}", url=f"https://e/{i}", source=source, published_at=NOW)
    it.score = score
    return it


def test_select_top_caps_papers_and_backfills():
    ordered = [item(i, "hf_papers", 10 - i * 0.1) for i in range(10)] + [item(99, "hn", 1)]
    top = select_top(ordered, 5, {"papers": 3})
    assert sum(i.source == "hf_papers" for i in top) == 4  # 3 by cap + 1 back-fill
    assert any(i.source == "hn" for i in top)


def test_enrich_respects_robots():
    def handler(req: httpx.Request):
        if req.url.path == "/robots.txt":
            return httpx.Response(200, text="User-agent: *\nDisallow: /private/\n")
        page = "<html><article><p>" + "Real article text about a model. " * 20 + "</p></article></html>"
        return httpx.Response(200, text=page, headers={"content-type": "text/html"})

    e = Enricher(httpx.Client(transport=httpx.MockTransport(handler)), {})
    ok = RawItem(id="1", title="t", url="https://site.example/post", source="hn", published_at=NOW)
    no = RawItem(id="2", title="t", url="https://site.example/private/post", source="hn", published_at=NOW)
    e.enrich([ok, no])
    assert "Real article text" in ok.text and no.text == ""
    assert ok.enriched and no.enriched


def test_duplicate_arriving_next_run_merges_into_existing_item(repo):
    FakeSource.items = [RawItem(id="web:aaa", title="Introducing Model X: faster open weights for everyone",
                                url="https://lab.example/x", source="blog:lab", published_at=NOW,
                                text="Model X details. " * 30, lab="Lab")]
    run_pipeline(repo, Router({"p1.test": ok_reply, "p2.test": ok_reply}))
    FakeSource.items = [RawItem(id="web:bbb", title="Introducing Model X – faster open weights for everyone",
                                url="https://news.example/x", source="hn", published_at=NOW,
                                signals={"hn_points": 500})]
    run_pipeline(repo, Router({"p1.test": ok_reply, "p2.test": ok_reply}), now=NOW + timedelta(hours=6))
    run_pipeline(repo, Router({"p1.test": ok_reply, "p2.test": ok_reply}), now=NOW + timedelta(hours=12))
    day = read_day(repo)
    assert [i["id"] for i in day["items"]] == ["web:aaa"]     # one item, never duplicated
    assert day["items"][0]["signals"]["hn_points"] == 500
