"""Tests for assistant credential storage helpers."""

from __future__ import annotations

import pytest

from dexpi_studio.core import assistant_credentials as creds


class _FakeKeyring:
    def __init__(self) -> None:
        self._db: dict[tuple[str, str], str] = {}

    def set_password(self, service: str, key: str, value: str) -> None:
        self._db[(service, key)] = value

    def get_password(self, service: str, key: str) -> str | None:
        return self._db.get((service, key))

    def delete_password(self, service: str, key: str) -> None:
        self._db.pop((service, key), None)


def test_save_load_delete_with_keyring(monkeypatch: pytest.MonkeyPatch) -> None:
    fake = _FakeKeyring()
    monkeypatch.setattr(creds, "_keyring", fake)  # type: ignore[attr-defined]

    assert creds.keyring_available()
    assert creds.save_api_key("secret-123")
    assert creds.load_api_key() == "secret-123"
    assert creds.delete_api_key()
    assert creds.load_api_key() is None


def test_returns_safe_defaults_when_keyring_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(creds, "_keyring", None)

    assert not creds.keyring_available()
    assert not creds.save_api_key("ignored")
    assert creds.load_api_key() is None
    assert not creds.delete_api_key()
