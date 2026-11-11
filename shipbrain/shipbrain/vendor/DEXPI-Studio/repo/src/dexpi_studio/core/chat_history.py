"""Chat history persistence and export helpers for ChatP&ID."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any


def now_human_timestamp() -> str:
    """Return current local timestamp for user-facing text."""
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def now_iso_timestamp() -> str:
    """Return current local timestamp in ISO-like format."""
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def make_chat_message(role: str, content: str, *, created_at: str | None = None) -> dict[str, str]:
    """Create a normalized chat message dictionary."""
    return {
        "role": role.strip() or "unknown",
        "content": content,
        "created_at": created_at or now_iso_timestamp(),
    }


def new_chat_record(
    *,
    chat_id: str,
    title: str,
    dexpi_file: str | None = None,
    provider: str | None = None,
    model: str | None = None,
    created_at: str | None = None,
) -> dict[str, Any]:
    """Create a new chat record ready for JSON persistence."""
    ts = created_at or now_iso_timestamp()
    return {
        "id": chat_id,
        "title": title,
        "created_at": ts,
        "updated_at": ts,
        "dexpi_file": dexpi_file,
        "provider": provider,
        "model": model,
        "messages": [],
    }


def build_chat_markdown(
    chat_messages: list[dict[str, str]],
    *,
    title: str = "ChatP&ID conversation",
    studio_version: str | None = None,
    created: str | None = None,
    dexpi_file: str | None = None,
    provider: str | None = None,
    model_name: str | None = None,
) -> str:
    """Build Markdown export text for a chat history.

    Parameters
    ----------
    chat_messages : list[dict[str, str]]
        Message list containing ``role`` and ``content`` keys.
    title : str, default="ChatP&ID conversation"
        Document title.
    studio_version : str | None, default=None
        DEXPI Studio version string.
    created : str | None, default=None
        Timestamp shown in export header.
    dexpi_file : str | None, default=None
        Source DEXPI file name.
    provider : str | None, default=None
        Assistant provider name.
    model_name : str | None, default=None
        LLM model name.

    Returns
    -------
    str
        Rendered Markdown transcript.
    """
    lines: list[str] = [f"# {title}", ""]

    if studio_version:
        lines.append(f"**DEXPI Studio version:** {studio_version}  ")
    lines.append(f"**Created:** {created or now_human_timestamp()}  ")
    if dexpi_file:
        lines.append(f"**DEXPI file:** `{dexpi_file}`  ")
    if provider:
        lines.append(f"**Assistant provider:** {provider}  ")
    if model_name:
        lines.append(f"**LLM model:** `{model_name}`  ")

    lines.extend(["", "---", ""])

    for message in chat_messages:
        role = str(message.get("role", "unknown")).strip().lower()
        content = str(message.get("content", "")).strip()
        if not content:
            continue

        if role == "system":
            continue
        if role == "user":
            heading = "User"
        elif role == "assistant":
            heading = "ChatP&ID"
        else:
            heading = role.title() or "Unknown"

        lines.extend([f"## {heading}", "", content, ""])

    return "\n".join(lines).rstrip() + "\n"


def export_chat_to_markdown(
    chat_messages: list[dict[str, str]],
    path: str | Path,
    *,
    title: str = "ChatP&ID conversation",
    studio_version: str | None = None,
    created: str | None = None,
    dexpi_file: str | None = None,
    provider: str | None = None,
    model_name: str | None = None,
) -> None:
    """Write a Markdown chat export to disk."""
    markdown = build_chat_markdown(
        chat_messages,
        title=title,
        studio_version=studio_version,
        created=created,
        dexpi_file=dexpi_file,
        provider=provider,
        model_name=model_name,
    )
    Path(path).write_text(markdown, encoding="utf-8")
