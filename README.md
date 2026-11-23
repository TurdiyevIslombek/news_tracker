# AI Pulse

A macOS desktop widget and menu bar app with a daily digest of AI research, model releases, tools and industry news. Every item gets a short plain-language summary, and every day is saved so you can look back.

> 🚧 Work in progress. The cloud collector is running now; the Mac app is coming next.

**Feed:** https://turdiyevislombek.github.io/news_tracker/latest.json

## How it works

- **`collector/`** is a Python pipeline that runs on GitHub Actions every 6 hours. It fetches arXiv and Hugging Face Daily Papers (more sources coming), dedupes and ranks them, summarizes them with free LLM APIs through a fallback chain, and publishes static JSON to GitHub Pages. It costs nothing, and the only API keys live in Actions secrets.
- **`app/`** (coming soon) is a native Swift/SwiftUI menu bar app with a WidgetKit widget. It only downloads and caches the JSON, so it has no keys and makes no LLM calls.

## Run the collector locally

```bash
uv venv -p 3.13 .venv && uv pip install -p .venv -r collector/requirements-dev.txt
echo 'GEMINI_API_KEY=...' > .env           # any one provider key is enough
.venv/bin/python -m collector providers   # check which LLM providers work
.venv/bin/python -m collector run         # writes docs/days/YYYY-MM-DD.json
.venv/bin/python -m pytest collector/tests
```

## Add a source

1. Create `collector/sources/mysource.py` with a `Source` subclass whose `fetch(since)` returns `list[RawItem]`. Use `ids.canonical_id(url)` for the id, so the item dedupes with the other sources.
2. Register it in `collector/sources/__init__.py` (`REGISTRY`).
3. Add a `mysource:` block under `sources:` in `collector/config.yaml`. That block is passed to your class as `self.cfg`.

A source that throws is logged and skipped, so it can't break the run. Ranking weights, per-source caps, the labs list and the LLM provider chain are all in `config.yaml`.
