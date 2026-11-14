"""Which files the server's file tools may read and write.

``load_dexpi_xml_file`` and ``save_model`` take a path from the client. Over stdio the client is
the local user, who can reach those files anyway. Over a network transport it is whoever can
reach the port, so the server confines file access to one directory -- or refuses it outright.

Three policies, chosen once when the server starts:

* :meth:`FileAccess.unrestricted` -- any path; relative paths resolve against the working
  directory. What ``pydexpi-mcp`` uses over stdio.
* :meth:`FileAccess.sandboxed` -- only paths inside a root directory; relative paths resolve
  against the root.
* :meth:`FileAccess.disabled` -- no file access. The default of
  :func:`~pydexpi.mcp_server.server.create_server`, and what a network transport without a root
  gets.

A sandboxed path is checked twice. First **lexically**, before anything touches the filesystem:
``..`` is collapsed and the result must stay under the root, and UNC or device paths
(``\\\\host\\share``, ``\\\\?\\``, ``\\\\.\\``) are refused outright -- resolving one on Windows
would open a connection to a host the client chose, handing it the server account's
credentials. Then the path is resolved (symlinks, junctions) and must *still* be under the root.
Reserved Windows device names and ``:`` (alternate data streams) are refused in every component.

What the sandbox cannot do: a local user who can write inside the root can swap a directory for
a link between the check and the write. The root must not be writable by untrusted users.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path, PurePath

#: Windows device names, reserved in every directory and with any extension.
_RESERVED_NAME = re.compile(r"^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM\d|LPT\d)(\..*)?$", re.I)


class FileAccessError(PermissionError):
    """A path the server's file-access policy does not allow."""


@dataclass(frozen=True)
class FileAccess:
    """A file-access policy; build one with the class methods.

    Attributes
    ----------
    root : Path or None
        The resolved sandbox directory, or ``None`` when unrestricted or disabled.
    enabled : bool
        False when every file access is refused.
    """

    root: Path | None
    enabled: bool = True

    @classmethod
    def unrestricted(cls) -> FileAccess:
        """Any path the server process can reach."""
        return cls(root=None)

    @classmethod
    def sandboxed(cls, root: str | Path) -> FileAccess:
        """Only paths inside *root*, which must be an existing directory.

        Raises
        ------
        NotADirectoryError
            If *root* is not an existing directory.
        """
        resolved = Path(root).expanduser().resolve()
        if not resolved.is_dir():
            raise NotADirectoryError(f"File root {root!s} is not an existing directory.")
        return cls(root=resolved)

    @classmethod
    def disabled(cls) -> FileAccess:
        """No file access at all."""
        return cls(root=None, enabled=False)

    def describe(self) -> str:
        """One line for a startup message."""
        if not self.enabled:
            return "file tools disabled"
        if self.root is None:
            return "file tools unrestricted"
        return f"file tools confined to {self.root}"

    def resolve(self, path: str) -> Path:
        """Return the absolute path *path* names, if this policy allows it.

        Unrestricted, ``~`` is expanded and a relative path is taken from the working directory.
        Sandboxed, a relative path is taken from the root, ``~`` is an ordinary character, and
        the path must stay inside the root both before and after resolving links.

        Raises
        ------
        FileAccessError
            If file access is disabled, or the path is not allowed.
        """
        if not self.enabled:
            raise FileAccessError(
                "File access is disabled on this server. Restart it with --file-root DIR to "
                "allow reading and writing files inside DIR, or pass documents as content "
                "(load_dexpi_xml, load_dexpi_json, export_xml, export_json)."
            )
        try:
            if self.root is None:
                return Path(path).expanduser().resolve()
            return self._resolve_in_root(path, self.root)
        except FileAccessError:  # a PermissionError, so an OSError: keep its own message
            raise
        except (OSError, ValueError) as exc:  # a NUL byte, an unparseable device path
            raise FileAccessError(f"{path!r} is not a usable path.") from exc

    def display(self, path: Path) -> str:
        """*path* as a client may see it: relative to the root when sandboxed.

        A network client has no business learning where the server keeps its files.
        """
        if self.root is not None and path.is_relative_to(self.root):
            return path.relative_to(self.root).as_posix()
        return str(path)

    @staticmethod
    def _resolve_in_root(path: str, root: Path) -> Path:
        if "\0" in path:
            raise FileAccessError("A path cannot contain a NUL character.")
        if path.startswith(("\\\\", "//")):
            raise FileAccessError(f"{path!s}: network and device paths are not allowed.")
        # Lexically first: nothing below touches the filesystem until the path is known to stay
        # inside the root. Joining an absolute path, or one on another drive, replaces the root,
        # so those fail this check too.
        lexical = Path(os.path.normpath(root / PurePath(path)))
        if not lexical.is_relative_to(root):
            raise FileAccessError(f"{path!s} is outside the server's file root.")
        for part in lexical.relative_to(root).parts:
            if ":" in part or _RESERVED_NAME.match(part.rstrip(" .")):
                raise FileAccessError(f"{path!s}: {part!r} is not an allowed file name.")
        resolved = lexical.resolve()
        if not resolved.is_relative_to(root):
            raise FileAccessError(f"{path!s} leads outside the server's file root.")
        return resolved
