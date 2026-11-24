# AI Pulse

A macOS desktop widget and menu bar app with a daily digest of AI research, model releases, tools and industry news. Every item gets a short plain-language summary, and every day is saved so you can look back.

> 🚧 Work in progress. The collector, the menu bar app and the widget work now; a downloadable release is coming next.

**Feed:** https://turdiyevislombek.github.io/news_tracker/latest.json

## How it works

- **`collector/`** is a Python pipeline that runs on GitHub Actions every 6 hours. It fetches arXiv, Hugging Face Daily Papers, lab blogs, Hacker News and GitHub, dedupes and ranks them, summarizes them with free LLM APIs through a fallback chain, and publishes static JSON to GitHub Pages. It costs nothing, and the only API keys live in Actions secrets.
- **`app/`** is a native Swift/SwiftUI menu bar app with a WidgetKit desktop widget in small, medium and large sizes. It only downloads and caches the JSON, so it has no keys and makes no LLM calls.

## Run the collector locally

```bash
uv venv -p 3.13 .venv && uv pip install -p .venv -r collector/requirements-dev.txt
echo 'GEMINI_API_KEY=...' > .env           # any one provider key is enough
.venv/bin/python -m collector providers   # check which LLM providers work
.venv/bin/python -m collector run         # writes docs/days/YYYY-MM-DD.json
.venv/bin/python -m pytest collector/tests
```

## Build the Mac app from source

You only need the Xcode Command Line Tools (`xcode-select --install`); full Xcode isn't required. Requires macOS 14 or later, on Apple Silicon or Intel.

```bash
app/scripts/build.sh          # → app/build/AI Pulse.app (universal, ad-hoc signed)
open "app/build/AI Pulse.app"
app/scripts/test.sh           # shared-code tests against real feed fixtures
app/scripts/widget-snapshot.sh /tmp/w   # render every widget size (light + dark) to PNGs
```

To add the widget, right-click the desktop, choose **Edit Widgets…**, and search for **AI Pulse**. Clicking a story opens its link; clicking the header opens the app.

The widget downloads `latest.json` itself, about once an hour, and keeps an offline copy. Sharing a cache with the app would need an App Group, and those require a paid Apple Developer account. It follows the feed URL you set in the app's Settings.

The app shows a ✦ icon in the menu bar. It refreshes on launch, on wake, and on the interval you choose in Settings, and it downloads any days it missed while your Mac was asleep or off. Every day is cached for offline browsing.

## Add a source

1. Create `collector/sources/mysource.py` with a `Source` subclass whose `fetch(since)` returns `list[RawItem]`. Use `ids.canonical_id(url)` for the id, so the item dedupes with the other sources.
2. Register it in `collector/sources/__init__.py` (`REGISTRY`).
3. Add a `mysource:` block under `sources:` in `collector/config.yaml`. That block is passed to your class as `self.cfg`.

A source that throws is logged and skipped, so it can't break the run. Ranking weights, per-source caps, the labs list and the LLM provider chain are all in `config.yaml`.
