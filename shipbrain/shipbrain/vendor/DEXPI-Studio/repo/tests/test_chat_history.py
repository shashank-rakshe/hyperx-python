"""Tests for chat history persistence/export helpers."""

from __future__ import annotations

from dexpi_studio.core.chat_history import (
    build_chat_markdown,
    export_chat_to_markdown,
    make_chat_message,
    new_chat_record,
)


def test_build_chat_markdown_excludes_system_and_contains_metadata() -> None:
    markdown = build_chat_markdown(
        [
            {"role": "system", "content": "internal"},
            {"role": "user", "content": "List all valves."},
            {"role": "assistant", "content": "I found **8 valves**."},
        ],
        studio_version="0.1.0",
        created="2026-05-14 10:42",
        dexpi_file="reference_pid.xml",
        provider="Gemini",
        model_name="gemini-2.5-flash",
    )

    assert "# ChatP&ID conversation" in markdown
    assert "**DEXPI Studio version:** 0.1.0" in markdown
    assert "**Created:** 2026-05-14 10:42" in markdown
    assert "**DEXPI file:** `reference_pid.xml`" in markdown
    assert "**Assistant provider:** Gemini" in markdown
    assert "**LLM model:** `gemini-2.5-flash`" in markdown
    assert "## User" in markdown
    assert "## ChatP&ID" in markdown
    assert "internal" not in markdown


def test_export_chat_to_markdown_writes_file(tmp_path) -> None:
    output = tmp_path / "chat.md"
    export_chat_to_markdown(
        [{"role": "user", "content": "Hello"}],
        output,
        provider="Gemini",
    )

    text = output.read_text(encoding="utf-8")
    assert "## User" in text
    assert "Hello" in text


def test_new_chat_record_and_message_helpers() -> None:
    record = new_chat_record(
        chat_id="chat-1",
        title="My chat",
        dexpi_file="sample.xml",
        provider="Gemini",
        model="gemini-2.5-flash",
        created_at="2026-05-14T10:42:33",
    )
    assert record["id"] == "chat-1"
    assert record["title"] == "My chat"
    assert record["updated_at"] == "2026-05-14T10:42:33"
    assert record["messages"] == []

    msg = make_chat_message("user", "List all valves.", created_at="2026-05-14T10:42:40")
    assert msg == {
        "role": "user",
        "content": "List all valves.",
        "created_at": "2026-05-14T10:42:40",
    }
