"""Assistant panel UI with optional LLM backend integration."""

from __future__ import annotations

import html
import json
import re
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

from PySide6.QtCore import QEvent, QObject, QSettings, QStandardPaths, Qt, QThread, QTimer, Signal
from PySide6.QtGui import QAction, QKeyEvent, QTextDocument
from PySide6.QtWidgets import (
    QComboBox,
    QFileDialog,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QMenu,
    QMessageBox,
    QPushButton,
    QTextBrowser,
    QTextEdit,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from dexpi_studio import __version__
from dexpi_studio.core.assistant_chat import (
    build_context_messages,
    export_model_context_text,
    stream_llm_chat,
)
from dexpi_studio.core.assistant_credentials import load_api_key
from dexpi_studio.core.chat_history import (
    export_chat_to_markdown,
    make_chat_message,
    new_chat_record,
    now_iso_timestamp,
)


def datetime_chat_id() -> str:
    """Create a compact unique chat identifier."""
    ts = now_iso_timestamp().replace(":", "").replace("-", "").replace("T", "-")
    return f"{ts}-{uuid.uuid4().hex[:8]}"


class LLMStreamWorker(QThread):
    """Background thread that streams LLM response chunks to the UI via signals.

    Signals
    -------
    chunk_received : Signal(str)
        Emitted for each text chunk as it arrives from the provider.
    stream_finished : Signal(str)
        Emitted once streaming is complete, carrying the full reply text.
    error_occurred : Signal(str)
        Emitted if an exception is raised during the stream.
    """

    chunk_received: Signal = Signal(str)
    stream_finished: Signal = Signal(str)
    error_occurred: Signal = Signal(str)

    def __init__(
        self,
        *,
        provider: str,
        endpoint: str,
        model_name: str,
        api_key: str,
        messages: list[dict[str, str]],
        timeout_seconds: float = 90.0,
        parent: QObject | None = None,
    ) -> None:
        super().__init__(parent)
        self._provider = provider
        self._endpoint = endpoint
        self._model_name = model_name
        self._api_key = api_key
        self._messages = messages
        self._timeout_seconds = timeout_seconds

    def run(self) -> None:
        """Stream the LLM response; emit signals for each chunk and on completion."""
        try:
            chunks: list[str] = []
            for chunk in stream_llm_chat(
                provider=self._provider,
                endpoint=self._endpoint,
                model_name=self._model_name,
                api_key=self._api_key,
                messages=self._messages,
                timeout_seconds=self._timeout_seconds,
            ):
                if not chunk:
                    continue
                chunks.append(chunk)
                self.chunk_received.emit(chunk)
            self.stream_finished.emit("".join(chunks).strip())
        except Exception as exc:
            self.error_occurred.emit(str(exc))


class AssistantPanel(QWidget):
    """Assistant chat panel with settings in a dedicated dialog."""

    _SETTINGS_ORG = "DEXPI Studio"
    _SETTINGS_APP = "Assistant"
    _GEMINI_ENDPOINT_DEFAULT = "https://generativelanguage.googleapis.com/v1beta/"
    _OPENAI_ENDPOINT_DEFAULT = "https://api.openai.com/v1/chat/completions"
    _ANTHROPIC_ENDPOINT_DEFAULT = "https://api.anthropic.com/v1/messages"

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._settings = QSettings(self._SETTINGS_ORG, self._SETTINGS_APP)
        self._context_provider: Callable[[], dict[str, Any]] | None = None
        self._settings_opener: Callable[[], None] | None = None
        self._conversation: list[dict[str, str]] = []
        self._chat_messages: list[tuple[str, str]] = []
        self._cached_model_context: str | None = None
        self._last_context_model_id: int | None = None
        self._selected_object_context: dict[str, str] | None = None
        self._selected_short_label: str | None = None

        self._chat_id: str | None = None
        self._chat_title: str = "New chat"
        self._chat_created_at: str = now_iso_timestamp()
        self._chat_messages_data: list[dict[str, str]] = []
        self._suspend_chat_switch_handler = False

        # Streaming worker state
        self._stream_worker: LLMStreamWorker | None = None
        self._stream_reply_chunks: list[str] = []
        self._stream_provider: str = ""
        self._stream_model_name: str = ""
        self._stream_chat_id: str | None = None

        # Spinner state (animates a QLabel widget — never touches the HTML document)
        self._spinner_frames = ["◐", "◓", "◑", "◒"]
        self._spinner_index: int = 0
        self._spinner_timer = QTimer(self)
        self._spinner_timer.setInterval(150)
        self._spinner_timer.timeout.connect(self._tick_spinner)

        self._setup_ui()
        self._load_chat_index_or_create_default()

    def _setup_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(6)

        header_row = QHBoxLayout()
        header_row.setSpacing(4)

        note = QLabel(
            "<b>ChatP&amp;ID Assistant</b><br/>"
            "Ask questions about the selected object or loaded P&amp;ID model."
        )
        note.setWordWrap(True)
        header_row.addWidget(note, stretch=1)

        self._info_button = QToolButton()
        self._info_button.setText("ⓘ")
        self._info_button.setToolTip("About ChatP&ID")
        self._info_button.setStyleSheet(
            "QToolButton {"
            " border: none;"
            " color: #64748b;"
            " font-size: 16px;"
            " padding: 2px;"
            "}"
            "QToolButton:hover { color: #2563eb; }"
        )
        self._info_button.clicked.connect(self._show_about_info)
        header_row.addWidget(self._info_button, alignment=Qt.AlignmentFlag.AlignTop)

        layout.addLayout(header_row)

        chat_row = QHBoxLayout()
        chat_row.setSpacing(6)

        chat_label = QLabel("Chat:")
        chat_row.addWidget(chat_label)

        self._chat_selector = QComboBox()
        self._chat_selector.currentIndexChanged.connect(self._on_chat_selected)
        chat_row.addWidget(self._chat_selector, stretch=1)

        self._new_chat_button = QPushButton("+")
        self._new_chat_button.setToolTip("New chat")
        self._new_chat_button.setFixedWidth(30)
        self._new_chat_button.clicked.connect(self._create_new_chat)
        chat_row.addWidget(self._new_chat_button)

        self._chat_menu_button = QToolButton()
        self._chat_menu_button.setText("⋯")
        self._chat_menu_button.setToolTip("Chat actions")
        self._chat_menu_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self._chat_menu = QMenu(self)

        self._rename_chat_action = QAction("Rename chat", self)
        self._rename_chat_action.triggered.connect(self._rename_current_chat)
        self._chat_menu.addAction(self._rename_chat_action)

        self._export_markdown_action = QAction("Export as Markdown", self)
        self._export_markdown_action.triggered.connect(self.export_current_chat_markdown)
        self._chat_menu.addAction(self._export_markdown_action)

        self._delete_chat_action = QAction("Delete chat", self)
        self._delete_chat_action.triggered.connect(self._delete_current_chat)
        self._chat_menu.addAction(self._delete_chat_action)

        self._chat_menu.addSeparator()

        self._clear_chat_action = QAction("Clear current chat", self)
        self._clear_chat_action.triggered.connect(self._clear_chat)
        self._chat_menu.addAction(self._clear_chat_action)

        self._chat_menu_button.setMenu(self._chat_menu)
        chat_row.addWidget(self._chat_menu_button)
        layout.addLayout(chat_row)

        self._selection_hint = QLabel(
            "<span style='color:#64748b;'>"
            "Ready to answer questions about the selected object or loaded P&amp;ID model."
            "</span>"
        )
        self._selection_hint.setWordWrap(True)
        layout.addWidget(self._selection_hint)

        chips_row = QHBoxLayout()
        chips_row.setSpacing(6)
        for label, template in [
            ("Explain", "Explain this object."),
            ("Connections", "What is connected to this object?"),
            ("Missing data", "Which properties are missing for this object?"),
            ("Validation", "Are there validation issues related to this object?"),
        ]:
            btn = QPushButton(label)
            btn.setProperty("class", "chip")
            btn.setStyleSheet(
                "QPushButton {"
                " background: #eef2ff;"
                " border: 1px solid #dbe2ff;"
                " border-radius: 10px;"
                " padding: 2px 8px;"
                " font-size: 12px;"
                " color: #334155;"
                "}"
                "QPushButton:hover {"
                " background: #e0e7ff;"
                "}"
            )
            btn.clicked.connect(lambda _=False, t=template: self._fill_prompt_from_chip(t))
            chips_row.addWidget(btn)
        chips_row.addStretch()
        layout.addLayout(chips_row)

        self._chat_history = QTextBrowser()
        self._chat_history.setOpenExternalLinks(True)
        self._chat_history.setPlaceholderText("Assistant conversation will appear here.")
        layout.addWidget(self._chat_history, stretch=1)

        self._spinner_row = QLabel()
        self._spinner_row.setStyleSheet("color: #2563eb; font-size: 12px; padding: 2px 4px;")
        self._spinner_row.hide()
        layout.addWidget(self._spinner_row)

        self._prompt = QTextEdit()
        self._prompt.setPlaceholderText("Ask about the selected object or P&ID model…")
        self._prompt.setFixedHeight(72)
        self._prompt.installEventFilter(self)
        self._prompt.setStyleSheet(
            "QTextEdit {"
            " background: white;"
            " border: 1px solid #cbd5e1;"
            " border-radius: 8px;"
            " padding: 8px;"
            " font-size: 13px;"
            "}"
            "QTextEdit:focus {"
            " border: 1px solid #2563eb;"
            "}"
        )
        layout.addWidget(self._prompt)

        self._send_button = QPushButton("Send")
        self._send_button.setFixedHeight(36)
        self._send_button.setMinimumWidth(84)
        self._send_button.setStyleSheet(
            "QPushButton {"
            " background-color: #003499;"
            " color: white;"
            " border: none;"
            " border-radius: 8px;"
            " font-weight: 600;"
            " padding: 0 16px;"
            "}"
            "QPushButton:hover {"
            " background-color: #0057c2;"
            "}"
            "QPushButton:disabled {"
            " background-color: #cbd5e1;"
            " color: #64748b;"
            "}"
        )
        self._send_button.clicked.connect(self._send_prompt)

        self._settings_button = QPushButton("Settings")
        self._settings_button.clicked.connect(self._open_settings)

        button_row = QHBoxLayout()
        button_row.addWidget(self._settings_button)
        button_row.addStretch()
        button_row.addWidget(self._send_button)
        layout.addLayout(button_row)

    def set_context_provider(self, provider: Callable[[], dict[str, Any]]) -> None:
        """Set callback used to retrieve current model/selection UI context."""
        self._context_provider = provider

    def set_settings_opener(self, opener: Callable[[], None]) -> None:
        """Set callback that opens the dedicated Assistant settings dialog."""
        self._settings_opener = opener

    def set_selected_object_context(
        self,
        *,
        selected_object_context: dict[str, str] | None,
        short_label: str | None,
        class_name: str | None,
    ) -> None:
        """Set currently selected object context used as hidden LLM system context."""
        self._selected_object_context = selected_object_context
        self._selected_short_label = short_label

        if short_label:
            hint = (
                f"<span style='color:#64748b;'><b>Selected object:</b> "
                f"{html.escape(short_label)} · {html.escape(class_name or 'Unknown')}"
                "</span>"
            )
            self._selection_hint.setText(hint)
            self._prompt.setPlaceholderText(f"Ask ChatP&ID about {short_label}…")
            return

        self._selection_hint.setText(
            "<span style='color:#64748b;'>"
            "Ready to answer questions about the selected object or loaded P&amp;ID model."
            "</span>"
        )
        self._prompt.setPlaceholderText("Ask ChatP&ID about the selected object or P&ID model…")

    def focus_prompt(self) -> None:
        """Focus the chat prompt field."""
        self._prompt.setFocus(Qt.FocusReason.OtherFocusReason)

    def eventFilter(self, watched: QObject, event: QEvent) -> bool:
        """Send chat on Enter in the prompt; keep Shift+Enter for newline."""
        if watched is self._prompt and isinstance(event, QKeyEvent):
            if event.type() == QEvent.Type.KeyPress and event.key() in (
                Qt.Key.Key_Return,
                Qt.Key.Key_Enter,
            ):
                if event.modifiers() & Qt.KeyboardModifier.ShiftModifier:
                    return super().eventFilter(watched, event)
                self._send_prompt()
                return True
        return super().eventFilter(watched, event)

    def _show_about_info(self) -> None:
        """Show a dialog with information about the ChatP&ID assistant."""
        msg = QMessageBox(self)
        msg.setWindowTitle("About ChatP&ID")
        msg.setTextFormat(Qt.TextFormat.RichText)
        msg.setText(
            "<b>ChatP&ID</b> uses <b>GraphRAG</b>, a graph-based retrieval approach "
            "for LLM interaction with P&ID. "
            "This chat interface implements ContextRAG (one of our GraphRAG methods); a more advanced method will be available in the future online platform."
            "<br><br>"
            "Read our article:<br>"
            "Alimin, A. A., &amp; Schweidtmann, A. M. (2026). "
            "<i>GraphRAG for engineering diagrams: ChatP&amp;ID enables LLM interaction with P&amp;IDs.</i> "
            "arXiv:2603.22528.<br>"
            "<a href='https://arxiv.org/abs/2603.22528'>arxiv.org/abs/2603.22528</a>"
            "<br><br>"
            "ChatP&amp;ID is AI and can make mistakes. "
            "Please double-check responses."
        )
        msg.setTextInteractionFlags(Qt.TextInteractionFlag.TextBrowserInteraction)
        msg.setStandardButtons(QMessageBox.StandardButton.Ok)
        msg.exec()

    def _open_settings(self) -> None:
        if self._settings_opener is not None:
            self._settings_opener()

    def _send_prompt(self) -> None:
        if not self._send_button.isEnabled():
            return
        text = self._prompt.toPlainText().strip()
        if not text:
            return

        context = self._context_provider() if self._context_provider is not None else {}
        model = context.get("model")

        provider = str(self._settings.value("provider", "Gemini"))
        endpoint = self._resolved_endpoint(provider)
        model_name = self._resolved_model_name(provider)

        context_dexpi_file = self._current_dexpi_file_name(context)
        if context_dexpi_file:
            self._upsert_current_chat_metadata(
                dexpi_file=context_dexpi_file,
                provider=provider,
                model_name=model_name,
            )

        api_key = load_api_key() or ""
        if not api_key and provider in {"Gemini", "OpenAI", "Anthropic"}:
            QMessageBox.warning(self, "Assistant", "No API key found. Open Settings to save one.")
            return

        model_context = None
        if model is not None:
            model_context = self._load_or_build_model_context(model)

        system_msgs = build_context_messages(
            model_context_text=model_context,
            selected_object_id=None,
            include_selected_object=False,
            selected_object_context=self._selected_object_context,
        )

        self._chat_messages.append(("user", text))
        self._conversation.append({"role": "user", "content": text})
        self._chat_messages_data.append(make_chat_message("user", text))
        self._save_current_chat(provider=provider, model_name=model_name)
        self._render_chat_history()

        self._send_button.setEnabled(False)
        self._chat_messages.append(("assistant", ""))
        self._render_chat_history()

        self._stream_reply_chunks = []
        self._stream_provider = provider
        self._stream_model_name = model_name
        self._stream_chat_id = self._chat_id

        # Stop any previous worker (guard — button is disabled during streaming).
        if self._stream_worker is not None and self._stream_worker.isRunning():
            self._stream_worker.quit()
            self._stream_worker.wait(3000)

        _MAX_HISTORY_MESSAGES = 50
        history = self._conversation[-_MAX_HISTORY_MESSAGES:]
        # Ensure the slice starts with a user message (required by Anthropic and
        # good practice for all providers).
        while history and history[0]["role"] != "user":
            history = history[1:]
        self._stream_worker = LLMStreamWorker(
            provider=provider,
            endpoint=endpoint,
            model_name=model_name,
            api_key=api_key,
            messages=[*system_msgs, *history],
            parent=self,
        )
        self._stream_worker.chunk_received.connect(self._on_stream_chunk)
        self._stream_worker.stream_finished.connect(self._on_stream_finished)
        self._stream_worker.error_occurred.connect(self._on_stream_error)
        self._stream_worker.start()
        self._chat_selector.setEnabled(False)
        self._start_spinner()

    def _start_spinner(self) -> None:
        self._spinner_index = 0
        self._spinner_row.setText("◐ ChatP&ID is thinking…")
        self._spinner_row.show()
        self._spinner_timer.start()

    def _stop_spinner(self) -> None:
        self._spinner_timer.stop()
        self._spinner_row.hide()

    def _tick_spinner(self) -> None:
        self._spinner_index = (self._spinner_index + 1) % len(self._spinner_frames)
        frame = self._spinner_frames[self._spinner_index]
        self._spinner_row.setText(f"{frame} ChatP&ID is thinking…")

    def _on_stream_chunk(self, chunk: str) -> None:
        """Append a streamed chunk and refresh the assistant bubble."""
        if self._chat_id != self._stream_chat_id:
            return
        self._stream_reply_chunks.append(chunk)
        self._chat_messages[-1] = ("assistant", "".join(self._stream_reply_chunks))
        self._render_chat_history()

    def _on_stream_finished(self, reply: str) -> None:
        """Finalise the assistant message after streaming completes."""
        self._stop_spinner()
        self._chat_selector.setEnabled(True)
        self._send_button.setEnabled(True)
        if self._chat_id != self._stream_chat_id:
            return
        if not reply:
            self._chat_messages.pop()
            self._render_chat_history()
            QMessageBox.critical(
                self, "Assistant Error", "LLM returned an empty assistant message."
            )
            return
        self._chat_messages[-1] = ("assistant", reply)
        self._render_chat_history()
        self._conversation.append({"role": "assistant", "content": reply})
        self._chat_messages_data.append(make_chat_message("assistant", reply))
        self._save_current_chat(provider=self._stream_provider, model_name=self._stream_model_name)
        self._prompt.clear()

    def _on_stream_error(self, error_msg: str) -> None:
        """Handle a streaming error: remove placeholder bubble and show dialog."""
        self._stop_spinner()
        self._chat_selector.setEnabled(True)
        self._send_button.setEnabled(True)
        if self._chat_id != self._stream_chat_id:
            return
        self._chat_messages.pop()
        self._render_chat_history()
        QMessageBox.critical(self, "Assistant Error", error_msg)

    def _resolved_model_name(self, provider: str) -> str:
        if provider == "Gemini":
            fallback = "gemini-2.5-flash"
        elif provider == "Anthropic":
            fallback = "claude-sonnet-4-5"
        else:
            fallback = "gpt-5-mini"
        return str(self._settings.value("model_name", fallback)).strip() or fallback

    def _resolved_endpoint(self, provider: str) -> str:
        endpoint = str(self._settings.value("endpoint", "")).strip()
        if endpoint:
            return endpoint
        if provider == "Gemini":
            return self._GEMINI_ENDPOINT_DEFAULT
        if provider == "Anthropic":
            return self._ANTHROPIC_ENDPOINT_DEFAULT
        return self._OPENAI_ENDPOINT_DEFAULT

    def _clear_chat(self) -> None:
        self._chat_messages = []
        self._chat_history.clear()
        self._conversation = []
        self._chat_messages_data = []
        self._save_current_chat()

    def _fill_prompt_from_chip(self, template: str) -> None:
        """Fill prompt from a quick-action chip without auto-sending."""
        if self._selected_short_label is not None:
            text = f"{template} Focus on {self._selected_short_label}."
        else:
            text = template
        self._prompt.setPlainText(text)
        self._prompt.setFocus(Qt.FocusReason.OtherFocusReason)

    def _render_chat_history(self) -> None:
        """Render chat messages as HTML bubbles with Markdown support."""
        parts: list[str] = [
            """
<style>
body {
    margin: 0;
    padding: 6px 4px 8px 4px;
    font-family: "Segoe UI", Arial, sans-serif;
    font-size: 13px;
    color: #0f172a;
}
.msg-wrap-user,
.msg-wrap-assistant {
    margin: 8px 0;
}
.msg-wrap-user {
    text-align: right;
}
.msg-wrap-assistant {
    text-align: left;
}
.bubble {
    display: inline-block;
    text-align: left;
    max-width: 86%;
    border-radius: 14px;
    padding: 9px 11px;
    box-sizing: border-box;
    line-height: 1.45;
    overflow-wrap: anywhere;
}
.bubble-user {
    margin-left: 42px;
    background: #e8f1ff;
    border: 1px solid #d7e6ff;
    color: #0f172a;
}
.bubble-assistant {
    margin-right: 22px;
    background: #ffffff;
    border: 1px solid #e2e8f0;
    color: #0f172a;
    box-shadow: 0 1px 1px rgba(15, 23, 42, 0.03);
}
.meta {
    font-weight: 600;
    margin-bottom: 4px;
    font-size: 11px;
    color: #64748b;
}
p,
ul,
ol,
pre,
blockquote {
    margin-top: 0;
    margin-bottom: 7px;
}
ul,
ol {
    padding-left: 18px;
}
li {
    margin-bottom: 2px;
}
pre {
    background: #f8fafc;
    border: 1px solid #e2e8f0;
    border-radius: 8px;
    padding: 8px;
    overflow-x: auto;
    white-space: pre-wrap;
}
code {
    background: #eef2f7;
    padding: 1px 4px;
    border-radius: 4px;
    font-family: Consolas, monospace;
}
.bubble p:last-child,
.bubble ul:last-child,
.bubble ol:last-child,
.bubble pre:last-child,
.bubble blockquote:last-child {
    margin-bottom: 0;
}
</style>
            """
        ]
        for role, text in self._chat_messages:
            if role == "user":
                cls = "bubble bubble-user"
                wrapper = "msg-wrap-user"
                meta = ""
            else:
                cls = "bubble bubble-assistant"
                wrapper = "msg-wrap-assistant"
                meta = "<div class='meta'>ChatP&amp;ID</div>"

            content_html = self._markdown_to_fragment(text)
            parts.append(
                f"<div class='{wrapper}'><div class='{cls}'>{meta}{content_html}</div></div>"
            )

        self._chat_history.setHtml("\n".join(parts))
        self._chat_history.verticalScrollBar().setValue(
            self._chat_history.verticalScrollBar().maximum()
        )

    def _markdown_to_fragment(self, text: str) -> str:
        """Convert Markdown text to an HTML fragment suitable for bubble content."""
        if not text.strip():
            return ""

        doc = QTextDocument()
        doc.setMarkdown(text)
        html_doc = doc.toHtml()

        match = re.search(r"<body[^>]*>(.*)</body>", html_doc, flags=re.DOTALL)
        if match:
            return match.group(1)

        # Fallback to escaped plain text if Qt HTML extraction format changes.
        return html.escape(text).replace("\n", "<br>")

    def _load_or_build_model_context(self, model: Any) -> str:
        model_id = id(model)
        if self._cached_model_context is not None and self._last_context_model_id == model_id:
            return self._cached_model_context

        context_text = export_model_context_text(
            model,
            include_full_model=True,
        )
        self._cached_model_context = context_text
        self._last_context_model_id = model_id
        return context_text

    def export_current_chat_markdown(self) -> None:
        """Export the currently selected chat to a Markdown file."""
        if not self._chat_messages_data:
            QMessageBox.information(self, "ChatP&ID", "Current chat is empty.")
            return

        safe_title = re.sub(r"[^A-Za-z0-9._-]+", "-", self._chat_title).strip("-") or "chatpid"
        default_name = f"{safe_title}.md"
        output_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export current chat as Markdown",
            default_name,
            "Markdown Files (*.md)",
        )
        if not output_path:
            return

        record = self._read_current_chat_record() or {}
        export_chat_to_markdown(
            self._chat_messages_data,
            output_path,
            title="ChatP&ID conversation",
            studio_version=__version__,
            created=now_iso_timestamp().replace("T", " "),
            dexpi_file=str(record.get("dexpi_file") or "") or None,
            provider=str(record.get("provider") or "") or None,
            model_name=str(record.get("model") or "") or None,
        )
        QMessageBox.information(self, "ChatP&ID", f"Chat exported to:\n{output_path}")

    def _current_dexpi_file_name(self, context: dict[str, Any]) -> str | None:
        current_file = context.get("current_file")
        if isinstance(current_file, str) and current_file.strip():
            return Path(current_file).name
        return None

    def _app_data_dir(self) -> Path:
        base = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppDataLocation)
        path = Path(base)
        path.mkdir(parents=True, exist_ok=True)
        return path

    def _chats_dir(self) -> Path:
        path = self._app_data_dir() / "chats"
        path.mkdir(parents=True, exist_ok=True)
        return path

    def _chat_path(self, chat_id: str) -> Path:
        return self._chats_dir() / f"{chat_id}.json"

    def _load_chat_index_or_create_default(self) -> None:
        chats: list[dict[str, str]] = []
        for path in sorted(self._chats_dir().glob("*.json"), reverse=True):
            try:
                record = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue

            chat_id = str(record.get("id") or path.stem)
            title = str(record.get("title") or chat_id)
            updated_at = str(record.get("updated_at") or "")
            chats.append({"id": chat_id, "title": title, "updated_at": updated_at})

        chats.sort(key=lambda c: c.get("updated_at", ""), reverse=True)
        self._refresh_chat_selector(chats)
        if chats:
            self._load_chat(chats[0]["id"])
            self._select_chat_id(chats[0]["id"])
            return
        self._create_new_chat(initial=True)

    def _refresh_chat_selector(self, chats: list[dict[str, str]]) -> None:
        self._suspend_chat_switch_handler = True
        self._chat_selector.clear()
        for chat in chats:
            self._chat_selector.addItem(chat["title"], chat["id"])
        self._suspend_chat_switch_handler = False

    def _all_chats_index(self) -> list[dict[str, str]]:
        chats: list[dict[str, str]] = []
        for i in range(self._chat_selector.count()):
            chat_id = str(self._chat_selector.itemData(i) or "")
            title = self._chat_selector.itemText(i)
            if chat_id:
                chats.append({"id": chat_id, "title": title})
        return chats

    def _create_new_chat(self, _checked: bool = False, *, initial: bool = False) -> None:
        chat_id = datetime_chat_id()
        context = self._context_provider() if self._context_provider is not None else {}
        dexpi_file = self._current_dexpi_file_name(context)
        default_title = f"{dexpi_file} — chat" if dexpi_file else "New chat"

        provider = str(self._settings.value("provider", "Gemini"))
        record = new_chat_record(
            chat_id=chat_id,
            title=default_title,
            dexpi_file=dexpi_file,
            provider=provider,
            model=self._resolved_model_name(provider),
        )
        self._write_chat_record(record)

        chats = self._all_chats_index()
        chats.insert(0, {"id": chat_id, "title": default_title})
        self._refresh_chat_selector(chats)
        self._select_chat_id(chat_id)
        self._load_chat(chat_id)

        if not initial:
            self._prompt.clear()
            self._prompt.setFocus(Qt.FocusReason.OtherFocusReason)

    def _select_chat_id(self, chat_id: str) -> None:
        idx = self._chat_selector.findData(chat_id)
        if idx >= 0:
            self._suspend_chat_switch_handler = True
            self._chat_selector.setCurrentIndex(idx)
            self._suspend_chat_switch_handler = False

    def _read_current_chat_record(self) -> dict[str, Any] | None:
        if not self._chat_id:
            return None
        path = self._chat_path(self._chat_id)
        if not path.exists():
            return None
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if isinstance(loaded, dict):
            return loaded
        return None

    def _write_chat_record(self, record: dict[str, Any]) -> None:
        chat_id = str(record.get("id") or "").strip()
        if not chat_id:
            return
        self._chat_path(chat_id).write_text(
            json.dumps(record, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    def _load_chat(self, chat_id: str) -> None:
        path = self._chat_path(chat_id)
        if not path.exists():
            return
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return

        self._chat_id = str(record.get("id") or chat_id)
        self._chat_title = str(record.get("title") or "New chat")
        self._chat_created_at = str(record.get("created_at") or now_iso_timestamp())

        messages = record.get("messages")
        parsed_messages: list[dict[str, str]] = []
        if isinstance(messages, list):
            for message in messages:
                if not isinstance(message, dict):
                    continue
                role = str(message.get("role") or "").strip().lower()
                content = str(message.get("content") or "")
                if role not in {"user", "assistant"}:
                    continue
                parsed_messages.append(
                    make_chat_message(
                        role,
                        content,
                        created_at=str(message.get("created_at") or now_iso_timestamp()),
                    )
                )

        self._chat_messages_data = parsed_messages
        self._conversation = [{"role": m["role"], "content": m["content"]} for m in parsed_messages]
        self._chat_messages = [(m["role"], m["content"]) for m in parsed_messages]
        self._prompt.clear()
        self._render_chat_history()

    def _save_current_chat(
        self, *, provider: str | None = None, model_name: str | None = None
    ) -> None:
        if not self._chat_id:
            return

        existing = self._read_current_chat_record() or {}
        record = {
            "id": self._chat_id,
            "title": self._chat_title,
            "created_at": str(existing.get("created_at") or self._chat_created_at),
            "updated_at": now_iso_timestamp(),
            "dexpi_file": existing.get("dexpi_file"),
            "provider": provider or existing.get("provider"),
            "model": model_name or existing.get("model"),
            "messages": self._chat_messages_data,
        }

        if not record["dexpi_file"] and self._context_provider is not None:
            record["dexpi_file"] = self._current_dexpi_file_name(self._context_provider())

        self._write_chat_record(record)

    def _upsert_current_chat_metadata(
        self,
        *,
        dexpi_file: str | None,
        provider: str | None,
        model_name: str | None,
    ) -> None:
        if not self._chat_id:
            return
        record = self._read_current_chat_record() or {}
        if not record:
            return

        changed = False
        if dexpi_file and record.get("dexpi_file") != dexpi_file:
            record["dexpi_file"] = dexpi_file
            changed = True
        if provider and record.get("provider") != provider:
            record["provider"] = provider
            changed = True
        if model_name and record.get("model") != model_name:
            record["model"] = model_name
            changed = True

        if changed:
            record["updated_at"] = now_iso_timestamp()
            self._write_chat_record(record)

    def _on_chat_selected(self, _index: int) -> None:
        if self._suspend_chat_switch_handler:
            return
        chat_id = str(self._chat_selector.currentData() or "")
        if not chat_id:
            return
        self._load_chat(chat_id)

    def _rename_current_chat(self) -> None:
        if not self._chat_id:
            return

        new_title, ok = QInputDialog.getText(
            self,
            "Rename chat",
            "New chat name:",
            text=self._chat_title,
        )
        if not ok:
            return
        title = new_title.strip()
        if not title:
            QMessageBox.information(self, "ChatP&ID", "Chat name cannot be empty.")
            return

        self._chat_title = title
        idx = self._chat_selector.currentIndex()
        if idx >= 0:
            self._chat_selector.setItemText(idx, title)

        record = self._read_current_chat_record() or {}
        if record:
            record["title"] = title
            record["updated_at"] = now_iso_timestamp()
            self._write_chat_record(record)

    def _delete_current_chat(self) -> None:
        if not self._chat_id:
            return

        choice = QMessageBox.question(
            self,
            "Delete chat",
            f"Delete chat '{self._chat_title}'? This cannot be undone.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if choice != QMessageBox.StandardButton.Yes:
            return

        path = self._chat_path(self._chat_id)
        try:
            if path.exists():
                path.unlink()
        except OSError as exc:
            QMessageBox.warning(self, "ChatP&ID", f"Failed to delete chat:\n{exc}")
            return

        chats = [c for c in self._all_chats_index() if c["id"] != self._chat_id]
        self._refresh_chat_selector(chats)

        if chats:
            self._select_chat_id(chats[0]["id"])
            self._load_chat(chats[0]["id"])
            return

        self._create_new_chat(initial=True)
