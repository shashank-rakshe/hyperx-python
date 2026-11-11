"""Central selection model for DEXPI Studio.

Holds the currently selected DEXPI object ID and broadcasts changes to all
subscribers (canvas, model tree, properties panel) via a single Qt signal.

Placing this in ``gui/`` keeps ``core/`` free of PySide6 as required by
AGENTS.md.
"""

from __future__ import annotations

from PySide6.QtCore import QObject, Signal


class SelectionModel(QObject):
    """Single source of truth for the active selection.

    All UI components that want to react to a selection change should connect
    to :attr:`selection_changed`.  All UI components that want to *drive* a
    selection change should call :meth:`select`.

    The ``_updating`` guard prevents re-entrant signal storms when multiple
    components call ``select`` in response to the same event.

    Parameters
    ----------
    parent : QObject, optional
        Qt parent object.
    """

    #: Emitted whenever the selection changes.
    #: Carries the new DEXPI object ID (``id_XXXX…``) or ``None`` when cleared.
    selection_changed = Signal(object)  # str | None

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._selected_id: str | None = None
        self._updating: bool = False

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    @property
    def selected_id(self) -> str | None:
        """The currently selected DEXPI object ID, or ``None``."""
        return self._selected_id

    def select(self, object_id: str | None) -> None:
        """Set the active selection and notify all subscribers.

        Parameters
        ----------
        object_id : str or None
            The DEXPI object ID to select, or ``None`` to clear the selection.
            If the ID is already selected, the call is a no-op.
        """
        if self._updating:
            return
        if object_id == self._selected_id:
            return

        self._updating = True
        try:
            self._selected_id = object_id
            self.selection_changed.emit(object_id)
        finally:
            self._updating = False

    def clear(self) -> None:
        """Clear the current selection."""
        self.select(None)
