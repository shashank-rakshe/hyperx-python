"""Credential helper utilities for optional Assistant API keys.

Uses OS credential storage through ``keyring`` when available.
"""

from __future__ import annotations

from typing import Final

SERVICE_NAME: Final[str] = "DEXPI Studio"
KEY_NAME: Final[str] = "assistant_api_key"

try:
    import keyring as _keyring
except ImportError:  # pragma: no cover - optional dependency runtime guard
    _keyring = None


def keyring_available() -> bool:
    """Return ``True`` when OS credential storage is available."""
    return _keyring is not None


def save_api_key(api_key: str) -> bool:
    """Save API key in OS credential storage.

    Parameters
    ----------
    api_key : str
        API key text to save.

    Returns
    -------
    bool
        ``True`` if key was saved, else ``False``.
    """
    if _keyring is None:
        return False
    _keyring.set_password(SERVICE_NAME, KEY_NAME, api_key)
    return True


def load_api_key() -> str | None:
    """Load API key from OS credential storage."""
    if _keyring is None:
        return None
    return _keyring.get_password(SERVICE_NAME, KEY_NAME)


def delete_api_key() -> bool:
    """Delete API key from OS credential storage.

    Returns
    -------
    bool
        ``True`` if key was deleted, else ``False``.
    """
    if _keyring is None:
        return False
    existing = _keyring.get_password(SERVICE_NAME, KEY_NAME)
    if existing is None:
        return False
    _keyring.delete_password(SERVICE_NAME, KEY_NAME)
    return True
