"""Tests for assistant chat backend utilities."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Self

import pytest

from dexpi_studio.core import assistant_chat


def test_export_model_context_text_uses_export_llm_context(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[str, str]] = []

    def _fake_export(_model: object, path: Path, *, graph_level: str, mode: str) -> None:
        calls.append((graph_level, mode))
        path.write_text("CONTEXT", encoding="utf-8")

    monkeypatch.setattr(assistant_chat, "export_llm_context", _fake_export)  # type: ignore[attr-defined]

    out = assistant_chat.export_model_context_text(object(), include_full_model=False)

    assert out == "CONTEXT"
    assert calls == [("process", "graph")]


def test_build_context_messages_includes_prompt_and_selected() -> None:
    msgs = assistant_chat.build_context_messages(
        model_context_text="CTX",
        selected_object_id="id-123",
        include_selected_object=True,
    )

    assert msgs[0]["role"] == "system"
    assert "ChatP&ID" in msgs[0]["content"]
    assert any("Formatting rules" in m["content"] for m in msgs)
    assert any("CTX" in m["content"] for m in msgs)
    assert any("id-123" in m["content"] for m in msgs)


def test_build_context_messages_includes_selected_object_xml_block() -> None:
    msgs = assistant_chat.build_context_messages(
        model_context_text="CTX",
        selected_object_id=None,
        include_selected_object=False,
        selected_object_context={
            "dexpi_xml_id": "dexpi-42",
            "display_name": "Pump P-101",
            "tag": "P-101",
            "class": "CentrifugalPump",
            "ui_object_id": "ui-abc",
            "available_ui_properties": "ID, Tag Name, Type",
        },
    )

    combined = "\n".join(m["content"] for m in msgs)
    assert "Current selected object context from the UI" in combined
    assert "- dexpi_xml_id: dexpi-42" in combined
    assert "- display_name: Pump P-101" in combined
    assert "- tag: P-101" in combined
    assert "- type: CentrifugalPump" in combined
    assert "- ui_object_id: ui-abc" in combined
    assert '<node dexpi_xml_id="...">' in combined


def test_call_openai_compatible_chat_parses_content(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {
        "choices": [
            {
                "message": {
                    "content": "Assistant reply",
                }
            }
        ]
    }

    class _Resp:
        def __enter__(self) -> Self:
            return self

        def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
            return None

        def read(self) -> bytes:
            return json.dumps(payload).encode("utf-8")

    def _fake_urlopen(_request: object, timeout: float = 0.0) -> _Resp:
        _ = timeout
        return _Resp()

    monkeypatch.setattr(assistant_chat, "urlopen", _fake_urlopen)

    reply = assistant_chat.call_openai_compatible_chat(
        endpoint="https://example.invalid/v1/chat/completions",
        model_name="gpt-test",
        api_key="k",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert reply == "Assistant reply"


def test_extract_gemini_text_returns_joined_parts() -> None:
    response = {
        "candidates": [
            {
                "content": {
                    "parts": [
                        {"text": "Part one"},
                        {"text": "Part two"},
                    ]
                }
            }
        ]
    }

    out = assistant_chat._extract_gemini_text(response)
    assert out == "Part one\nPart two"


def test_call_llm_chat_routes_to_gemini(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_gemini(
        *,
        endpoint: str,
        model_name: str,
        api_key: str,
        messages: list[dict[str, str]],
        timeout_seconds: float = 90.0,
    ) -> str:
        _ = (endpoint, model_name, api_key, messages, timeout_seconds)
        return "gemini-ok"

    monkeypatch.setattr(assistant_chat, "call_gemini_chat", _fake_gemini)

    out = assistant_chat.call_llm_chat(
        provider="Gemini",
        endpoint="",
        model_name="gemini-2.5-flash",
        api_key="k",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert out == "gemini-ok"


def test_call_llm_chat_routes_to_openai_compatible(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_openai(
        *,
        endpoint: str,
        model_name: str,
        api_key: str,
        messages: list[dict[str, str]],
        timeout_seconds: float = 90.0,
    ) -> str:
        _ = (endpoint, model_name, api_key, messages, timeout_seconds)
        return "openai-ok"

    monkeypatch.setattr(assistant_chat, "call_openai_compatible_chat", _fake_openai)

    out = assistant_chat.call_llm_chat(
        provider="OpenAI",
        endpoint="https://api.openai.com/v1/chat/completions",
        model_name="gpt-4.1-mini",
        api_key="k",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert out == "openai-ok"


def test_stream_llm_chat_routes_to_gemini(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_stream_gemini(
        *,
        endpoint: str,
        model_name: str,
        api_key: str,
        messages: list[dict[str, str]],
        timeout_seconds: float = 90.0,
    ):
        _ = (endpoint, model_name, api_key, messages, timeout_seconds)
        yield "chunk-1"
        yield "chunk-2"

    monkeypatch.setattr(assistant_chat, "stream_gemini_chat", _fake_stream_gemini)

    out = list(
        assistant_chat.stream_llm_chat(
            provider="Gemini",
            endpoint="https://generativelanguage.googleapis.com/v1beta/",
            model_name="gemini-2.5-flash",
            api_key="k",
            messages=[{"role": "user", "content": "hi"}],
        )
    )

    assert out == ["chunk-1", "chunk-2"]


def test_stream_llm_chat_routes_to_openai_compatible(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_stream_openai(
        *,
        endpoint: str,
        model_name: str,
        api_key: str,
        messages: list[dict[str, str]],
        timeout_seconds: float = 90.0,
    ):
        _ = (endpoint, model_name, api_key, messages, timeout_seconds)
        yield "hello"

    monkeypatch.setattr(
        assistant_chat,
        "stream_openai_compatible_chat",
        _fake_stream_openai,
    )

    out = list(
        assistant_chat.stream_llm_chat(
            provider="OpenAI",
            endpoint="https://api.openai.com/v1/chat/completions",
            model_name="gpt-4.1-mini",
            api_key="k",
            messages=[{"role": "user", "content": "hi"}],
        )
    )

    assert out == ["hello"]


def test_call_anthropic_chat_parses_content(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {
        "content": [
            {"type": "text", "text": "Anthropic reply"},
        ]
    }

    class _Resp:
        def __enter__(self) -> Self:
            return self

        def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
            return None

        def read(self) -> bytes:
            return json.dumps(payload).encode("utf-8")

    def _fake_urlopen(_request: object, timeout: float = 0.0) -> _Resp:
        _ = timeout
        return _Resp()

    monkeypatch.setattr(assistant_chat, "urlopen", _fake_urlopen)

    reply = assistant_chat.call_anthropic_chat(
        endpoint="https://api.anthropic.com/v1/messages",
        model_name="claude-sonnet-4-5",
        api_key="k",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert reply == "Anthropic reply"


def test_extract_anthropic_text_joins_multiple_blocks() -> None:
    response = {
        "content": [
            {"type": "text", "text": "Block one"},
            {"type": "text", "text": "Block two"},
        ]
    }

    out = assistant_chat._extract_anthropic_text(response)
    assert out == "Block one\nBlock two"


def test_extract_anthropic_text_raises_on_empty_content() -> None:
    with pytest.raises(RuntimeError, match="no content"):
        assistant_chat._extract_anthropic_text({"content": []})


def test_call_llm_chat_routes_to_anthropic(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_anthropic(
        *,
        endpoint: str,
        model_name: str,
        api_key: str,
        messages: list[dict[str, str]],
        timeout_seconds: float = 90.0,
    ) -> str:
        _ = (endpoint, model_name, api_key, messages, timeout_seconds)
        return "anthropic-ok"

    monkeypatch.setattr(assistant_chat, "call_anthropic_chat", _fake_anthropic)

    out = assistant_chat.call_llm_chat(
        provider="Anthropic",
        endpoint="https://api.anthropic.com/v1/messages",
        model_name="claude-sonnet-4-5",
        api_key="k",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert out == "anthropic-ok"


def test_stream_llm_chat_routes_to_anthropic(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_stream_anthropic(
        *,
        endpoint: str,
        model_name: str,
        api_key: str,
        messages: list[dict[str, str]],
        timeout_seconds: float = 90.0,
    ):
        _ = (endpoint, model_name, api_key, messages, timeout_seconds)
        yield "anthr-chunk"

    monkeypatch.setattr(assistant_chat, "stream_anthropic_chat", _fake_stream_anthropic)

    out = list(
        assistant_chat.stream_llm_chat(
            provider="Anthropic",
            endpoint="https://api.anthropic.com/v1/messages",
            model_name="claude-sonnet-4-5",
            api_key="k",
            messages=[{"role": "user", "content": "hi"}],
        )
    )

    assert out == ["anthr-chunk"]
