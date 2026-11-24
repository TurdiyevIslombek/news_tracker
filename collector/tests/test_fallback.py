from __future__ import annotations

from datetime import timedelta

from collector.chain import Chain
from collector.llm import Provider, ProviderError

from .conftest import NOW, Router, ok_reply, read_day, run_pipeline


def prov(name: str) -> Provider:
    return Provider(name=name, base_url=f"https://{name}.test", model="m", key_env="X")


# ---- Chain unit tests --------------------------------------------------------

def test_429_retries_once_then_falls_through_and_is_remembered():
    calls = []

    def fn(p):
        calls.append(p.name)
        if p.name == "p1":
            raise ProviderError("p1", 429, "rate limited")
        return "ok"

    chain = Chain([prov("p1"), prov("p2")], sleep=lambda s: None)
    assert chain.call(fn)[0] == "ok"
    assert calls == ["p1", "p1", "p2"]          # one retry on p1, then p2
    assert chain.exhausted == {"p1/m"}

    calls.clear()
    chain.call(fn)
    assert calls == ["p2"]                      # p1 not retried again this run


def test_transient_error_recovers_on_retry():
    seen = []

    def fn(p):
        seen.append(p.name)
        if len(seen) == 1:
            raise ProviderError(p.name, 503, "busy")
        return "ok"

    chain = Chain([prov("p1"), prov("p2")], sleep=lambda s: None)
    assert chain.call(fn)[1].name == "p1"
    assert not chain.exhausted


def test_5xx_moves_on_but_provider_gets_another_chance():
    calls = []

    def fn(p):
        calls.append(p.name)
        if p.name == "p1":
            raise ProviderError("p1", 503, "high demand")
        return "ok"

    chain = Chain([prov("p1"), prov("p2")], sleep=lambda s: None, max_strikes=2)
    chain.call(fn)
    assert calls == ["p1", "p1", "p2"] and not chain.exhausted
    calls.clear()
    chain.call(fn)                               # second failed call: now exhausted
    assert calls == ["p1", "p1", "p2"] and chain.exhausted == {"p1/m"}
    calls.clear()
    chain.call(fn)
    assert calls == ["p2"]


def test_non_retryable_error_skips_immediately():
    calls = []

    def fn(p):
        calls.append(p.name)
        if p.name == "p1":
            raise ProviderError("p1", 401, "bad key")
        return "ok"

    Chain([prov("p1"), prov("p2")], sleep=lambda s: None).call(fn)
    assert calls == ["p1", "p2"]


def test_all_fail_returns_none():
    def fn(p):
        raise ProviderError(p.name, 500, "down")

    assert Chain([prov("p1"), prov("p2")], sleep=lambda s: None).call(fn) is None


def test_missing_key_provider_is_skipped(monkeypatch):
    from collector.llm import providers_from_config

    monkeypatch.delenv("NOPE_KEY", raising=False)
    monkeypatch.setenv("YES_KEY", "k")
    got = providers_from_config([
        {"name": "a", "base_url": "x", "model": "m", "key_env": "NOPE_KEY"},
        {"name": "b", "base_url": "x", "model": "m", "key_env": "YES_KEY", "notes": "ignored"},
    ])
    assert [p.name for p in got] == ["b"]


# ---- End-to-end through the pipeline (mocked HTTP) ---------------------------

def test_pipeline_uses_provider2_when_provider1_429s(repo):
    router = Router({"p1.test": 429, "p2.test": ok_reply})
    run_pipeline(repo, router)
    day = read_day(repo)
    assert {i["summarized_by"] for i in day["items"]} == {"p2/model-b"}
    assert all(i["summary_status"] == "done" for i in day["items"])
    assert day["headline_status"] == "done"
    assert router.calls["p1.test"] == 2  # first try + one retry, then remembered as exhausted


def test_all_providers_down_still_publishes_pending_then_resummarizes(repo):
    run_pipeline(repo, Router({"p1.test": 500, "p2.test": 503}))
    day = read_day(repo)
    assert len(day["items"]) == 3
    assert all(i["summary_status"] == "pending" and i["summary"] for i in day["items"])
    assert day["headline_status"] == "pending"

    # Next run (6 h later, same day, no new items needed): providers are back.
    router = Router({"p1.test": ok_reply, "p2.test": ok_reply})
    run_pipeline(repo, router, now=NOW + timedelta(hours=6))
    day = read_day(repo)
    assert all(i["summary_status"] == "done" for i in day["items"])
    assert day["headline_status"] == "done"


def test_pending_on_a_past_day_is_filled_in_next_day(repo):
    from .conftest import FakeSource

    run_pipeline(repo, Router({"p1.test": 429, "p2.test": 429}))
    assert read_day(repo)["headline_status"] == "pending"

    FakeSource.items = []  # nothing new tomorrow
    run_pipeline(repo, Router({"p1.test": ok_reply, "p2.test": ok_reply}), now=NOW + timedelta(days=1))
    past = read_day(repo, "2026-11-23")
    assert all(i["summary_status"] == "done" for i in past["items"])
    assert read_day(repo, "2026-11-24")["items"] == []   # the new day exists, even if empty


def test_summaries_are_cached_by_id(repo):
    router = Router({"p1.test": ok_reply, "p2.test": ok_reply})
    run_pipeline(repo, router)
    first = router.calls["p1.test"]
    run_pipeline(repo, router, now=NOW + timedelta(hours=6))
    assert router.calls["p1.test"] == first  # same items + same top set: no new LLM calls


def test_skipped_days_are_backfilled_by_publish_date(repo):
    """GitHub skipped every run on 11-24; the 11-25 run files 11-24's news under 11-24."""
    from collector.models import RawItem
    from .conftest import FakeSource

    run_pipeline(repo, Router({"p1.test": ok_reply, "p2.test": ok_reply}))          # 11-23 12:00
    later = NOW + timedelta(days=2)                                                  # 11-25 12:00
    FakeSource.items = [
        RawItem(id="web:gap", title="Story from the skipped day", url="https://e.com/gap",
                source="hn", published_at=NOW + timedelta(days=1), signals={"hn_points": 300}),
        RawItem(id="web:new", title="Story from today", url="https://e.com/new",
                source="hn", published_at=later, signals={"hn_points": 300}),
    ]
    run_pipeline(repo, Router({"p1.test": ok_reply, "p2.test": ok_reply}), now=later)
    assert [i["id"] for i in read_day(repo, "2026-11-24")["items"]] == ["web:gap"]
    assert [i["id"] for i in read_day(repo, "2026-11-25")["items"]] == ["web:new"]


def test_skipped_day_with_nothing_published_still_gets_a_file(repo):
    from .conftest import FakeSource

    run_pipeline(repo, Router({"p1.test": ok_reply, "p2.test": ok_reply}))
    FakeSource.items = []
    run_pipeline(repo, Router({"p1.test": ok_reply, "p2.test": ok_reply}), now=NOW + timedelta(days=2))
    assert read_day(repo, "2026-11-24")["items"] == []


def test_off_topic_items_are_dropped_and_replaced(repo):
    """The model flags a non-AI item; it leaves the digest and the next item moves up."""
    import json
    import httpx
    from .conftest import FakeSource, make_items

    FakeSource.items = make_items(4)

    def reply(request: httpx.Request) -> httpx.Response:
        prompt = json.loads(request.content)["messages"][-1]["content"]
        if "Items:\n" not in prompt:
            return ok_reply(request)
        items = json.loads(prompt.split("Items:\n", 1)[1])
        content = {"items": [{"id": it["id"], "category": "Research", "summary": "S.", "why_it_matters": "W.",
                              "about_ai": it["id"] != "arxiv:2611.00003"} for it in items]}
        return httpx.Response(200, json={"choices": [{"message": {"content": json.dumps(content)}}]})

    import yaml
    cfg_path = repo / "collector" / "config.yaml"
    cfg = yaml.safe_load(cfg_path.read_text())
    cfg["output"]["top_n"] = 3
    cfg_path.write_text(yaml.safe_dump(cfg))
    run_pipeline(repo, Router({"p1.test": reply, "p2.test": reply}))
    day = read_day(repo)
    ids = [i["id"] for i in day["items"]]
    assert "arxiv:2611.00003" not in ids and len(ids) == 3          # replaced by the 4th item
    assert all(m["id"] != "arxiv:2611.00003" for m in day["more"])
