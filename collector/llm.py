"""One client for every OpenAI-compatible chat API (Gemini, Groq, Cerebras, OpenRouter, ...)."""
from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass

import httpx

log = logging.getLogger(__name__)


class ProviderError(Exception):
    def __init__(self, provider: str, status: int | None, message: str):
        super().__init__(f"{provider}: {status} {message}")
        self.provider = provider
        self.status = status

    @property
    def retryable(self) -> bool:
        """429 / quota / 5xx / network: worth one retry, then move to next provider."""
        return self.status is None or self.status == 429 or self.status >= 500


@dataclass
class Provider:
    name: str
    base_url: str
    model: str
    key_env: str
    timeout_seconds: float = 60
    json_mode: bool = False
    extra_headers: dict | None = None

    @property
    def label(self) -> str:
        return f"{self.name}/{self.model}"

    @property
    def api_key(self) -> str | None:
        return os.environ.get(self.key_env) or None


def providers_from_config(cfg: list[dict]) -> list[Provider]:
    out = []
    for p in cfg:
        prov = Provider(**p)
        if prov.api_key:
            out.append(prov)
        else:
            log.info("llm: skipping %s (no %s set)", prov.name, prov.key_env)
    return out


def chat(provider: Provider, messages: list[dict], temperature: float, http: httpx.Client) -> str:
    headers = {"Authorization": f"Bearer {provider.api_key}", **(provider.extra_headers or {})}
    body: dict = {"model": provider.model, "messages": messages, "temperature": temperature}
    if provider.json_mode:
        body["response_format"] = {"type": "json_object"}
    try:
        r = http.post(
            provider.base_url.rstrip("/") + "/chat/completions",
            json=body,
            headers=headers,
            timeout=provider.timeout_seconds,
        )
    except httpx.HTTPError as e:
        raise ProviderError(provider.name, None, type(e).__name__) from None
    if r.status_code != 200:
        # Error bodies never contain our key, but trim them anyway to keep logs short.
        raise ProviderError(provider.name, r.status_code, r.text[:200])
    try:
        return r.json()["choices"][0]["message"]["content"] or ""
    except (KeyError, IndexError, ValueError, TypeError):
        raise ProviderError(provider.name, 502, "malformed response") from None


def parse_json(text: str) -> dict:
    """Extract the first JSON object from a model reply (tolerates ``` fences / prose)."""
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        raise ValueError("no JSON object in reply")
    return json.loads(text[start : end + 1])
