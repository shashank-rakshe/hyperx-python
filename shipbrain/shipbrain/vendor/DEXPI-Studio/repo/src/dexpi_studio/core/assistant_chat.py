"""Assistant chat backend utilities for optional LLM integration."""

from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from pydexpi.exports import export_llm_context

FLOWSHEET_AGENT_PROMPT = """
You are the ChatP&ID Assistant, an expert assistant for engineers working with
P&ID and flowsheet models represented using pyDEXPI and the DEXPI information model.

Your purpose is to help users understand, inspect, validate, and reason about the
currently loaded P&ID model.

SOURCE OF TRUTH
- Use only the information provided in the conversation and the exported pyDEXPI model context.
- Treat the pyDEXPI model context as the authoritative source.
- Do not invent equipment, instruments, pipelines, connections, tag names, attributes, or process functions.
- If a requested detail is not present in the context, say so clearly.
- If the graphical drawing is not included in the context, do not claim that you inspected the drawing visually.

DOMAIN FOCUS
You understand process engineering diagrams, including:
- equipment such as pumps, vessels, reactors, heat exchangers, columns, filters, and tanks,
- piping and process streams,
- instrumentation and control loops,
- connectivity between process objects,
- metadata, tags, labels, attributes, and relationships,
- validation issues in DEXPI/P&ID models.

HOW TO ANSWER
- Be concise, precise, and engineering-focused.
- Prefer evidence from the model context over general process knowledge.
- Refer to object IDs, tags, names, or classes when available.
- Distinguish clearly between:
  1. facts explicitly present in the model,
  2. reasonable assumptions,
  3. recommendations or next steps.
- If the model context appears incomplete, inconsistent, or truncated, state this explicitly.
- If multiple interpretations are possible, explain the alternatives instead of choosing one silently.
- When useful, answer with short tables or bullet points.

TASK TYPES
For questions about a selected object:
- identify the object using the selected object ID if available,
- summarize its type, name/tag, key attributes, and relationships,
- mention connected upstream/downstream objects if present in the context.

For questions about connectivity:
- describe only connections present in the context,
- avoid inferring hidden connections from process knowledge alone,
- state when directionality is unavailable or ambiguous.

For validation or troubleshooting:
- explain the issue in plain engineering language,
- identify affected objects when possible,
- suggest concrete checks or fixes,
- distinguish between model/data issues and possible process-design issues.

For summaries:
- provide a high-level overview first,
- then list important equipment, streams, instruments, and notable missing information.

SAFETY AND PRIVACY
- Do not request confidential information unnecessarily.
- Do not expose API keys, secrets, file paths, or private system details.
- If the user asks about sensitive engineering data, remind them to share only what they intend to send to the configured Assistant provider.

LIMITATIONS
- You are not a process safety authority.
- You may help identify possible issues, but final engineering decisions require qualified human review.
- You cannot guarantee correctness if the pyDEXPI model context is incomplete, outdated, or inconsistent.
""".strip()

RESPONSE_FORMAT_PROMPT = """
The Assistant is displayed in a narrow side panel.

Formatting rules:
- Prefer short paragraphs and compact bullet lists.
- Avoid wide Markdown tables unless the user explicitly asks for a table.
- Avoid deeply nested lists.
- If the user asks for "all" items and there are many, group them by type and show a concise list.
- For object lists, group by type and show at most 10 items initially.
- For each object, use one compact line when possible, e.g. `GlobeValve2` — type: `GlobeValve`, fluid code: `MNb`.
- Use bold labels for important object names, tags, and IDs.
- Use code formatting for exact IDs, tags, class names, and attribute keys.
- Do not output raw pipe-table Markdown unless specifically requested.
- If more than 10 objects match, first summarize the count by type, then list the first 10 and ask whether the user wants the full list.
""".strip()


def export_model_context_text(model: Any, *, include_full_model: bool) -> str:
    """Export model LLM context via pyDEXPI ``export_llm_context`` and return as text."""
    graph_level = "complete" if include_full_model else "process"
    with TemporaryDirectory() as tmp_dir:
        out_path = Path(tmp_dir) / "llm_context.txt"
        export_llm_context(model, out_path, graph_level=graph_level, mode="graph")
        text = out_path.read_text(encoding="utf-8", errors="replace")
    if len(text) > 120_000:
        return text[:120_000] + "\n\n[Context truncated for prompt size safety.]"
    return text


def build_context_messages(
    *,
    model_context_text: str | None,
    selected_object_id: str | None,
    include_selected_object: bool,
    selected_object_context: dict[str, str] | None = None,
) -> list[dict[str, str]]:
    """Build additional system context messages for the LLM call."""
    messages: list[dict[str, str]] = [
        {"role": "system", "content": FLOWSHEET_AGENT_PROMPT},
        {"role": "system", "content": RESPONSE_FORMAT_PROMPT},
    ]

    if model_context_text:
        messages.append(
            {
                "role": "system",
                "content": "P&ID model context from pyDEXPI export_llm_context:\n\n"
                + model_context_text,
            }
        )

    if include_selected_object and selected_object_id:
        messages.append(
            {
                "role": "system",
                "content": f"Current selected object ID in UI: {selected_object_id}",
            }
        )

    if selected_object_context is not None:
        dexpi_xml_id = selected_object_context.get("dexpi_xml_id") or "unknown"
        display_name = selected_object_context.get("display_name") or "unknown"
        tag = selected_object_context.get("tag") or "unknown"
        class_name = selected_object_context.get("class") or "unknown"
        ui_object_id = selected_object_context.get("ui_object_id") or "unknown"
        available_ui_properties = (
            selected_object_context.get("available_ui_properties") or "unknown"
        )

        messages.append(
            {
                "role": "system",
                "content": f"""
Current selected object context from the UI:
- tag: {tag}
- type: {class_name}
- dexpi_xml_id: {dexpi_xml_id}
- display_name: {display_name}
- ui_object_id: {ui_object_id}
- available UI properties: {available_ui_properties}

Use dexpi_xml_id as the primary key to match this object in the exported pyDEXPI model context,
specifically with entries that appear as <node dexpi_xml_id="...">.
If dexpi_xml_id is unknown or not found, try matching by tag, display_name, or class.
If multiple objects match, say so and ask for clarification.
""".strip(),
            }
        )

    return messages


def call_openai_compatible_chat(
    *,
    endpoint: str,
    model_name: str,
    api_key: str,
    messages: list[dict[str, str]],
    timeout_seconds: float = 90.0,
) -> str:
    """Call an OpenAI-compatible chat completions endpoint and return assistant text."""
    payload: dict[str, Any] = {
        "model": model_name,
        "messages": messages,
    }
    if _model_supports_temperature(model_name):
        payload["temperature"] = 0
    headers = {
        "Content-Type": "application/json",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    req = Request(
        url=endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urlopen(req, timeout=timeout_seconds) as response:
            body = response.read().decode("utf-8", errors="replace")
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"LLM API HTTP {exc.code}: {detail}") from exc
    except URLError as exc:
        raise RuntimeError(f"Could not connect to LLM API: {exc.reason}") from exc

    parsed = json.loads(body)
    choices = parsed.get("choices")
    if not choices:
        raise RuntimeError("LLM API returned no choices.")

    message = choices[0].get("message", {})
    content = message.get("content")
    if isinstance(content, str) and content.strip():
        return content.strip()

    if isinstance(content, list):
        text_parts = [part.get("text", "") for part in content if isinstance(part, dict)]
        joined = "\n".join(part for part in text_parts if part)
        if joined.strip():
            return joined.strip()

    raise RuntimeError("LLM API returned an empty assistant message.")


def call_gemini_chat(
    *,
    endpoint: str,
    model_name: str,
    api_key: str,
    messages: list[dict[str, str]],
    timeout_seconds: float = 90.0,
) -> str:
    """Call the Google Gemini API and return assistant text."""
    if not api_key.strip():
        raise ValueError("Gemini API key is empty.")

    if not model_name.strip():
        raise ValueError("Gemini model name is empty.")

    base_endpoint = endpoint.strip() or "https://generativelanguage.googleapis.com/v1beta/"
    base_endpoint = base_endpoint.rstrip("/") + "/"
    endpoint_url = f"{base_endpoint}models/{model_name}:generateContent"

    system_parts: list[str] = []
    contents: list[dict[str, Any]] = []

    for message in messages:
        role = message.get("role")
        content = message.get("content", "")

        if not isinstance(content, str) or not content.strip():
            continue

        if role == "system":
            system_parts.append(content.strip())
        elif role == "assistant":
            contents.append(
                {
                    "role": "model",
                    "parts": [{"text": content.strip()}],
                }
            )
        else:
            contents.append(
                {
                    "role": "user",
                    "parts": [{"text": content.strip()}],
                }
            )

    payload: dict[str, Any] = {
        "contents": contents,
        "generationConfig": {
            "temperature": 0,
        },
    }

    if system_parts:
        payload["systemInstruction"] = {"parts": [{"text": "\n\n".join(system_parts)}]}

    headers = {
        "Content-Type": "application/json",
        "x-goog-api-key": api_key.strip(),
    }

    req = Request(
        url=endpoint_url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urlopen(req, timeout=timeout_seconds) as response:
            body = response.read().decode("utf-8", errors="replace")
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Gemini API HTTP {exc.code}: {detail}") from exc
    except URLError as exc:
        raise RuntimeError(f"Could not connect to Gemini API: {exc.reason}") from exc

    try:
        parsed = json.loads(body)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Gemini API returned invalid JSON: {body[:500]}") from exc

    return _extract_gemini_text(parsed)


def _extract_gemini_text(response: dict[str, Any]) -> str:
    """Extract assistant text from a Gemini generateContent response."""
    candidates = response.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise RuntimeError("Gemini API returned no candidates.")

    first = candidates[0]
    if not isinstance(first, dict):
        raise RuntimeError("Gemini API returned an invalid candidate.")

    content = first.get("content")
    if not isinstance(content, dict):
        raise RuntimeError("Gemini API returned no content.")

    parts = content.get("parts")
    if not isinstance(parts, list):
        raise RuntimeError("Gemini API returned no text parts.")

    text_parts: list[str] = []
    for part in parts:
        if isinstance(part, dict):
            text = part.get("text")
            if isinstance(text, str) and text.strip():
                text_parts.append(text.strip())

    joined = "\n".join(text_parts).strip()
    if joined:
        return joined

    finish_reason = first.get("finishReason")
    if finish_reason:
        raise RuntimeError(f"Gemini API returned no text. Finish reason: {finish_reason}")

    raise RuntimeError("Gemini API returned an empty response.")


def call_llm_chat(
    *,
    provider: str,
    endpoint: str,
    model_name: str,
    api_key: str,
    messages: list[dict[str, str]],
    timeout_seconds: float = 90.0,
) -> str:
    """Call the selected LLM provider."""
    provider_normalized = provider.strip().lower()

    if provider_normalized == "gemini":
        return call_gemini_chat(
            endpoint=endpoint,
            model_name=model_name,
            api_key=api_key,
            messages=messages,
            timeout_seconds=timeout_seconds,
        )

    if provider_normalized == "openai":
        return call_openai_compatible_chat(
            endpoint=endpoint,
            model_name=model_name,
            api_key=api_key,
            messages=messages,
            timeout_seconds=timeout_seconds,
        )

    if provider_normalized == "anthropic":
        return call_anthropic_chat(
            endpoint=endpoint,
            model_name=model_name,
            api_key=api_key,
            messages=messages,
            timeout_seconds=timeout_seconds,
        )

    raise ValueError(f"Unsupported LLM provider: {provider}")


_ANTHROPIC_VERSION = "2023-06-01"
_ANTHROPIC_MAX_TOKENS = 4096

# Reasoning models that do not accept a temperature parameter at all.
_NO_TEMPERATURE_PREFIXES = ("o1", "o3", "o4", "gpt-5")


def _model_supports_temperature(model_name: str) -> bool:
    """Return False for known reasoning models that reject the temperature parameter."""
    name = model_name.strip().lower()
    return not any(name.startswith(p) for p in _NO_TEMPERATURE_PREFIXES)


def call_anthropic_chat(
    *,
    endpoint: str,
    model_name: str,
    api_key: str,
    messages: list[dict[str, str]],
    timeout_seconds: float = 90.0,
) -> str:
    """Call the Anthropic Messages API and return assistant text."""
    if not api_key.strip():
        raise ValueError("Anthropic API key is empty.")

    if not model_name.strip():
        raise ValueError("Anthropic model name is empty.")

    endpoint_url = endpoint.strip() or "https://api.anthropic.com/v1/messages"

    system_parts: list[str] = []
    user_messages: list[dict[str, str]] = []

    for message in messages:
        role = message.get("role")
        content = message.get("content", "")
        if not isinstance(content, str) or not content.strip():
            continue
        if role == "system":
            system_parts.append(content.strip())
        else:
            user_messages.append({"role": role, "content": content.strip()})

    payload: dict[str, Any] = {
        "model": model_name.strip(),
        "max_tokens": _ANTHROPIC_MAX_TOKENS,
        "messages": user_messages,
        "temperature": 0,
    }
    if system_parts:
        payload["system"] = "\n\n".join(system_parts)

    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key.strip(),
        "anthropic-version": _ANTHROPIC_VERSION,
    }

    req = Request(
        url=endpoint_url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urlopen(req, timeout=timeout_seconds) as response:
            body = response.read().decode("utf-8", errors="replace")
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Anthropic API HTTP {exc.code}: {detail}") from exc
    except URLError as exc:
        raise RuntimeError(f"Could not connect to Anthropic API: {exc.reason}") from exc

    try:
        parsed = json.loads(body)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Anthropic API returned invalid JSON: {body[:500]}") from exc

    return _extract_anthropic_text(parsed)


def _extract_anthropic_text(response: dict[str, Any]) -> str:
    """Extract assistant text from an Anthropic Messages API response."""
    content = response.get("content")
    if not isinstance(content, list) or not content:
        error = response.get("error", {})
        msg = error.get("message") if isinstance(error, dict) else str(error)
        raise RuntimeError(f"Anthropic API returned no content. {msg or ''}".strip())

    text_parts: list[str] = []
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            text = block.get("text", "")
            if isinstance(text, str) and text.strip():
                text_parts.append(text.strip())

    joined = "\n".join(text_parts).strip()
    if joined:
        return joined

    raise RuntimeError("Anthropic API returned an empty assistant message.")


def stream_anthropic_chat(
    *,
    endpoint: str,
    model_name: str,
    api_key: str,
    messages: list[dict[str, str]],
    timeout_seconds: float = 90.0,
) -> Iterator[str]:
    """Stream text chunks from the Anthropic Messages API with fallback."""
    if not api_key.strip():
        raise ValueError("Anthropic API key is empty.")

    if not model_name.strip():
        raise ValueError("Anthropic model name is empty.")

    endpoint_url = endpoint.strip() or "https://api.anthropic.com/v1/messages"

    system_parts: list[str] = []
    user_messages: list[dict[str, str]] = []

    for message in messages:
        role = message.get("role")
        content = message.get("content", "")
        if not isinstance(content, str) or not content.strip():
            continue
        if role == "system":
            system_parts.append(content.strip())
        else:
            user_messages.append({"role": role, "content": content.strip()})

    payload: dict[str, Any] = {
        "model": model_name.strip(),
        "max_tokens": _ANTHROPIC_MAX_TOKENS,
        "messages": user_messages,
        "temperature": 0,
        "stream": True,
    }
    if system_parts:
        payload["system"] = "\n\n".join(system_parts)

    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key.strip(),
        "anthropic-version": _ANTHROPIC_VERSION,
    }

    req = Request(
        url=endpoint_url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    emitted = False
    try:
        with urlopen(req, timeout=timeout_seconds) as response:
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[len("data:") :].strip()
                if not data:
                    continue

                parsed = json.loads(data)
                if parsed.get("type") != "content_block_delta":
                    continue

                delta = parsed.get("delta", {})
                if delta.get("type") == "text_delta":
                    text = delta.get("text", "")
                    if isinstance(text, str) and text:
                        emitted = True
                        yield text
    except HTTPError:
        emitted = False
    except URLError:
        emitted = False
    except RuntimeError:
        emitted = False

    if emitted:
        return

    # Fallback to non-streaming.
    yield call_anthropic_chat(
        endpoint=endpoint,
        model_name=model_name,
        api_key=api_key,
        messages=messages,
        timeout_seconds=timeout_seconds,
    )


def stream_openai_compatible_chat(
    *,
    endpoint: str,
    model_name: str,
    api_key: str,
    messages: list[dict[str, str]],
    timeout_seconds: float = 90.0,
) -> Iterator[str]:
    """Stream text chunks from an OpenAI-compatible chat completions endpoint."""
    payload: dict[str, Any] = {
        "model": model_name,
        "messages": messages,
        "stream": True,
    }
    if _model_supports_temperature(model_name):
        payload["temperature"] = 0
    headers = {
        "Content-Type": "application/json",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    req = Request(
        url=endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    emitted = False
    try:
        with urlopen(req, timeout=timeout_seconds) as response:
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[len("data:") :].strip()
                if not data:
                    continue
                if data == "[DONE]":
                    break

                parsed = json.loads(data)
                choices = parsed.get("choices")
                if not isinstance(choices, list) or not choices:
                    continue

                delta = choices[0].get("delta", {})
                content = delta.get("content")

                if isinstance(content, str) and content:
                    emitted = True
                    yield content
                    continue

                if isinstance(content, list):
                    text_parts = [
                        part.get("text", "") for part in content if isinstance(part, dict)
                    ]
                    joined = "".join(part for part in text_parts if part)
                    if joined:
                        emitted = True
                        yield joined
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"LLM API HTTP {exc.code}: {detail}") from exc
    except URLError as exc:
        raise RuntimeError(f"Could not connect to LLM API: {exc.reason}") from exc

    if emitted:
        return

    # Fallback for endpoints that don't support streaming.
    yield call_openai_compatible_chat(
        endpoint=endpoint,
        model_name=model_name,
        api_key=api_key,
        messages=messages,
        timeout_seconds=timeout_seconds,
    )


def stream_gemini_chat(
    *,
    endpoint: str,
    model_name: str,
    api_key: str,
    messages: list[dict[str, str]],
    timeout_seconds: float = 90.0,
) -> Iterator[str]:
    """Stream text chunks from Gemini when possible, with fallback to non-streaming."""
    if not api_key.strip():
        raise ValueError("Gemini API key is empty.")

    if not model_name.strip():
        raise ValueError("Gemini model name is empty.")

    base_endpoint = endpoint.strip() or "https://generativelanguage.googleapis.com/v1beta/"
    base_endpoint = base_endpoint.rstrip("/") + "/"
    stream_endpoint_url = f"{base_endpoint}models/{model_name}:streamGenerateContent?alt=sse"

    system_parts: list[str] = []
    contents: list[dict[str, Any]] = []

    for message in messages:
        role = message.get("role")
        content = message.get("content", "")

        if not isinstance(content, str) or not content.strip():
            continue

        if role == "system":
            system_parts.append(content.strip())
        elif role == "assistant":
            contents.append({"role": "model", "parts": [{"text": content.strip()}]})
        else:
            contents.append({"role": "user", "parts": [{"text": content.strip()}]})

    payload: dict[str, Any] = {
        "contents": contents,
        "generationConfig": {
            "temperature": 0,
        },
    }
    if system_parts:
        payload["systemInstruction"] = {"parts": [{"text": "\n\n".join(system_parts)}]}

    headers = {
        "Content-Type": "application/json",
        "x-goog-api-key": api_key.strip(),
    }
    req = Request(
        url=stream_endpoint_url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    emitted = False
    try:
        with urlopen(req, timeout=timeout_seconds) as response:
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[len("data:") :].strip()
                if not data:
                    continue

                parsed = json.loads(data)
                text = _extract_gemini_text(parsed)
                if text:
                    emitted = True
                    yield text
    except HTTPError:
        # Fall through to non-streaming fallback below.
        emitted = False
    except URLError:
        emitted = False
    except RuntimeError:
        emitted = False

    if emitted:
        return

    # Fallback for unsupported stream endpoint/format.
    yield call_gemini_chat(
        endpoint=endpoint,
        model_name=model_name,
        api_key=api_key,
        messages=messages,
        timeout_seconds=timeout_seconds,
    )


def stream_llm_chat(
    *,
    provider: str,
    endpoint: str,
    model_name: str,
    api_key: str,
    messages: list[dict[str, str]],
    timeout_seconds: float = 90.0,
) -> Iterator[str]:
    """Stream chat response chunks from the selected LLM provider."""
    provider_normalized = provider.strip().lower()

    if provider_normalized == "gemini":
        yield from stream_gemini_chat(
            endpoint=endpoint,
            model_name=model_name,
            api_key=api_key,
            messages=messages,
            timeout_seconds=timeout_seconds,
        )
        return

    if provider_normalized == "openai":
        yield from stream_openai_compatible_chat(
            endpoint=endpoint,
            model_name=model_name,
            api_key=api_key,
            messages=messages,
            timeout_seconds=timeout_seconds,
        )
        return

    if provider_normalized == "anthropic":
        yield from stream_anthropic_chat(
            endpoint=endpoint,
            model_name=model_name,
            api_key=api_key,
            messages=messages,
            timeout_seconds=timeout_seconds,
        )
        return

    raise ValueError(f"Unsupported LLM provider: {provider}")
