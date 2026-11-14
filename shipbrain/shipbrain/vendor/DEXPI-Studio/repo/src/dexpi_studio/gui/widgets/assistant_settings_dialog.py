"""Dedicated Assistant settings dialog."""

from __future__ import annotations

from PySide6.QtCore import QSettings
from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QVBoxLayout,
)

from dexpi_studio.core.assistant_chat import call_llm_chat
from dexpi_studio.core.assistant_credentials import (
    delete_api_key,
    keyring_available,
    load_api_key,
    save_api_key,
)


class AssistantSettingsDialog(QDialog):
    """Dialog for configuring Assistant provider/model/endpoint and key handling."""

    _SETTINGS_ORG = "DEXPI Studio"
    _SETTINGS_APP = "Assistant"
    _GEMINI_ENDPOINT_DEFAULT = "https://generativelanguage.googleapis.com/v1beta/"
    _OPENAI_ENDPOINT_DEFAULT = "https://api.openai.com/v1/chat/completions"
    _ANTHROPIC_ENDPOINT_DEFAULT = "https://api.anthropic.com/v1/messages"

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("ChatP&ID Settings")
        self.setMinimumWidth(520)
        self._settings = QSettings(self._SETTINGS_ORG, self._SETTINGS_APP)
        self._setup_ui()
        self._load_settings()

    def _setup_ui(self) -> None:
        layout = QVBoxLayout(self)
        form = QFormLayout()

        self._provider = QComboBox()
        self._provider.addItems(["Gemini", "OpenAI", "Anthropic"])
        self._provider.currentTextChanged.connect(self._on_provider_changed)
        self._provider.currentTextChanged.connect(self._persist_settings)
        form.addRow("Provider:", self._provider)

        self._model_name = QComboBox()
        self._model_name.setEditable(True)
        self._model_name.setInsertPolicy(QComboBox.InsertPolicy.NoInsert)
        self._model_name.currentTextChanged.connect(self._persist_settings)
        form.addRow("Model:", self._model_name)

        self._endpoint = QLineEdit()
        self._endpoint.setPlaceholderText(self._OPENAI_ENDPOINT_DEFAULT)
        self._endpoint.editingFinished.connect(self._persist_settings)
        form.addRow("Endpoint:", self._endpoint)

        key_row = QHBoxLayout()
        self._api_key = QLineEdit()
        self._api_key.setEchoMode(QLineEdit.EchoMode.Password)
        self._api_key.setPlaceholderText("Enter API key")
        key_row.addWidget(self._api_key, stretch=1)

        save_key_btn = QPushButton("Save key")
        save_key_btn.clicked.connect(self._save_key)
        key_row.addWidget(save_key_btn)

        remove_key_btn = QPushButton("Remove key")
        remove_key_btn.clicked.connect(self._remove_key)
        key_row.addWidget(remove_key_btn)

        form.addRow("API key:", key_row)

        test_btn = QPushButton("Test connection")
        test_btn.clicked.connect(self._test_connection)
        form.addRow("", test_btn)

        layout.addLayout(form)

        privacy_note = QLabel(
            "<span style='color:#64748b;'>"
            "Chat history is stored locally on this computer. "
            "You can export conversations as Markdown or delete them at any time."
            "</span>"
        )
        privacy_note.setWordWrap(True)
        layout.addWidget(privacy_note)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Close,
        )
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _save_key(self) -> None:
        key_text = self._api_key.text().strip()
        if not key_text:
            QMessageBox.information(self, "Assistant", "Please enter an API key first.")
            return

        if not keyring_available():
            QMessageBox.warning(
                self,
                "Assistant",
                "OS credential storage is unavailable. Install and configure keyring.",
            )
            return

        if save_api_key(key_text):
            QMessageBox.information(self, "Assistant", "API key saved to local credential store.")
            self._api_key.clear()

    def _remove_key(self) -> None:
        if not keyring_available():
            QMessageBox.warning(
                self,
                "Assistant",
                "OS credential storage is unavailable. Install and configure keyring.",
            )
            return

        if delete_api_key():
            QMessageBox.information(self, "Assistant", "API key removed.")
        else:
            QMessageBox.information(self, "Assistant", "No saved key was found.")

    def _test_connection(self) -> None:
        key = load_api_key() or ""
        provider = self._provider.currentText().strip()
        if not key and provider in {"Gemini", "OpenAI", "Anthropic"}:
            QMessageBox.information(self, "Assistant", "No API key found. Save a key first.")
            return

        try:
            reply = call_llm_chat(
                provider=provider,
                endpoint=self._resolved_endpoint(provider),
                model_name=self._resolved_model_name(),
                api_key=key,
                messages=[{"role": "user", "content": "Reply with: OK"}],
                timeout_seconds=30.0,
            )
        except (RuntimeError, ValueError) as exc:
            QMessageBox.warning(self, "Assistant", f"Connection test failed:\n{exc}")
            return

        QMessageBox.information(self, "Assistant", f"Connection test successful.\nReply: {reply}")

    def _persist_settings(self) -> None:
        self._settings.setValue("provider", self._provider.currentText())
        self._settings.setValue("model_name", self._model_name.currentText().strip())
        self._settings.setValue("endpoint", self._endpoint.text().strip())

    def _load_settings(self) -> None:
        provider = str(self._settings.value("provider", "OpenAI"))
        _provider_aliases = {"OpenAI-compatible": "OpenAI"}
        provider = _provider_aliases.get(provider, provider)
        idx = self._provider.findText(provider)
        self._provider.setCurrentIndex(idx if idx >= 0 else 0)
        self._on_provider_changed(self._provider.currentText())

        model_name = str(self._settings.value("model_name", ""))
        if model_name:
            if self._model_name.findText(model_name) < 0:
                self._model_name.addItem(model_name)
            self._model_name.setCurrentText(model_name)

        _provider_now = self._provider.currentText().strip()
        if _provider_now == "Gemini":
            default_endpoint = self._GEMINI_ENDPOINT_DEFAULT
        elif _provider_now == "Anthropic":
            default_endpoint = self._ANTHROPIC_ENDPOINT_DEFAULT
        else:
            default_endpoint = self._OPENAI_ENDPOINT_DEFAULT
        self._endpoint.setText(
            str(
                self._settings.value(
                    "endpoint",
                    default_endpoint,
                )
            )
        )

    def _resolved_model_name(self) -> str:
        provider = self._provider.currentText().strip()
        if provider == "Gemini":
            fallback = "gemini-2.5-flash"
        elif provider == "Anthropic":
            fallback = "claude-sonnet-4-5"
        else:
            fallback = "gpt-5-mini"
        return self._model_name.currentText().strip() or fallback

    def _resolved_endpoint(self, provider: str) -> str:
        endpoint = self._endpoint.text().strip()
        if endpoint:
            return endpoint
        if provider == "Gemini":
            return self._GEMINI_ENDPOINT_DEFAULT
        if provider == "Anthropic":
            return self._ANTHROPIC_ENDPOINT_DEFAULT
        return self._OPENAI_ENDPOINT_DEFAULT

    def _on_provider_changed(self, provider: str) -> None:
        """Refresh model presets and reset to the provider default when switching."""
        provider_name = provider.strip()

        if provider_name == "Gemini":
            presets = ["gemini-2.5-flash", "gemini-2.5-pro"]
            default_model = "gemini-2.5-flash"
            default_endpoint = self._GEMINI_ENDPOINT_DEFAULT
        elif provider_name == "Anthropic":
            presets = ["claude-sonnet-4-5", "claude-opus-4-5", "claude-haiku-4-5"]
            default_model = "claude-sonnet-4-5"
            default_endpoint = self._ANTHROPIC_ENDPOINT_DEFAULT
        else:
            presets = ["gpt-5-mini", "gpt-5"]
            default_model = "gpt-5-mini"
            default_endpoint = self._OPENAI_ENDPOINT_DEFAULT

        self._model_name.blockSignals(True)
        self._model_name.clear()
        self._model_name.addItems(presets)
        self._model_name.setCurrentText(default_model)
        self._model_name.blockSignals(False)

        current_endpoint = self._endpoint.text().strip()
        all_defaults = {
            self._GEMINI_ENDPOINT_DEFAULT,
            self._OPENAI_ENDPOINT_DEFAULT,
            self._ANTHROPIC_ENDPOINT_DEFAULT,
        }
        if not current_endpoint or current_endpoint in all_defaults - {default_endpoint}:
            self._endpoint.setText(default_endpoint)
