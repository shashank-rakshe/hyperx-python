"""Issues panel: what the loader reported about the opened file, and what validation found."""

from __future__ import annotations

import html

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QBrush, QColor
from PySide6.QtWidgets import (
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QPushButton,
    QSplitter,
    QTextBrowser,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

from dexpi_studio.core.issues import (
    LOADING_SEVERITIES,
    SEVERITY_MEANING,
    VALIDATION_SEVERITIES,
    Issue,
    IssueReport,
    summary_text,
)

_ISSUE_ROLE = Qt.ItemDataRole.UserRole
_COLOURS = {
    "Critical": "#b91c1c",
    "Error": "#b91c1c",
    "Mandatory": "#b91c1c",
    "Warning": "#b45309",
    "Recommended": "#b45309",
}
#: Headings of the two sections, and what each says about the file.
_SECTIONS = {
    "loading": "Loading the file",
    "validation": "Validation",
}


class IssuesPanel(QWidget):
    """Shows an :class:`~dexpi_studio.core.issues.IssueReport`, grouped and sorted.

    Selecting an issue emits :attr:`objects_selected` with the ids of the objects it is about;
    double-clicking it emits :attr:`zoom_requested` with the first of them.
    """

    objects_selected = Signal(list)
    zoom_requested = Signal(str)
    revalidate_requested = Signal()
    lenient_reload_requested = Signal()
    export_requested = Signal()

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._report = IssueReport()
        self._known_ids: set[str] = set()
        self._names: dict[str, str] = {}
        self._setup_ui()
        self.clear()

    def _setup_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)
        layout.setSpacing(4)

        header = QHBoxLayout()
        self._summary = QLabel()
        self._summary.setWordWrap(True)
        header.addWidget(self._summary, stretch=1)
        self._lenient_button = QPushButton("Reopen leniently")
        self._lenient_button.setToolTip(
            "Load the file again with pyDEXPI's lenient setting: an object that lacks a "
            "mandatory attribute is loaded without it, and reported, rather than left out."
        )
        self._lenient_button.clicked.connect(self.lenient_reload_requested)
        header.addWidget(self._lenient_button)
        self._revalidate_button = QPushButton("Validate again")
        self._revalidate_button.clicked.connect(self.revalidate_requested)
        header.addWidget(self._revalidate_button)
        self._export_button = QPushButton("Export CSV…")
        self._export_button.clicked.connect(self.export_requested)
        header.addWidget(self._export_button)
        layout.addLayout(header)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        self._tree = QTreeWidget()
        self._tree.setColumnCount(2)
        self._tree.setHeaderLabels(["Issue", "Objects"])
        self._tree.header().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self._tree.header().setSectionResizeMode(1, QHeaderView.ResizeMode.Interactive)
        self._tree.header().resizeSection(1, 220)
        self._tree.setUniformRowHeights(True)
        self._tree.currentItemChanged.connect(self._on_current_changed)
        self._tree.itemDoubleClicked.connect(self._on_double_clicked)
        splitter.addWidget(self._tree)

        self._detail = QTextBrowser()
        self._detail.setOpenLinks(False)
        self._detail.anchorClicked.connect(lambda url: self.zoom_requested.emit(url.toString()))
        splitter.addWidget(self._detail)
        splitter.setStretchFactor(0, 3)
        splitter.setStretchFactor(1, 2)
        layout.addWidget(splitter, stretch=1)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def set_report(
        self,
        report: IssueReport,
        known_ids: set[str] | None = None,
        names: dict[str, str] | None = None,
    ) -> None:
        """Show *report*.

        *known_ids* are the ids of the objects the model holds, and *names* what to call an
        object instead of its id.
        """
        self._report = report
        self._known_ids = set(known_ids or ())
        self._names = dict(names or {})
        self._tree.clear()
        self._summary.setText(summary_text(report))
        self._lenient_button.setVisible(report.data_lost and not report.lenient)
        self._revalidate_button.setEnabled(True)
        self._export_button.setEnabled(bool(report.loading or report.validation))

        # Loading first: what the loader left out is often why validation complains.
        self._add_section("loading", report.loading, LOADING_SEVERITIES, by_rule=False)
        self._add_section("validation", report.validation, VALIDATION_SEVERITIES, by_rule=True)
        self._detail.setHtml(self._overview_html())

    def report(self) -> IssueReport:
        """The report shown."""
        return self._report

    def clear(self) -> None:
        """Show nothing."""
        self._report = IssueReport()
        self._known_ids = set()
        self._names = {}
        self._tree.clear()
        self._summary.setText("Open a file to see what loading and validation report.")
        self._lenient_button.setVisible(False)
        self._revalidate_button.setEnabled(False)
        self._export_button.setEnabled(False)
        self._detail.clear()

    def issue_items(self) -> list[QTreeWidgetItem]:
        """Every row that holds an issue, in display order."""
        items = []
        stack = [self._tree.topLevelItem(i) for i in range(self._tree.topLevelItemCount())]
        stack.reverse()
        while stack:
            item = stack.pop()
            if item.data(0, _ISSUE_ROLE) is not None:
                items.append(item)
            stack.extend(item.child(i) for i in reversed(range(item.childCount())))
        return items

    # ------------------------------------------------------------------
    # Building the tree
    # ------------------------------------------------------------------

    def _add_section(
        self, origin: str, issues: list[Issue], severities: tuple[str, ...], *, by_rule: bool
    ) -> None:
        section = QTreeWidgetItem([f"{_SECTIONS[origin]} ({len(issues)})", ""])
        font = section.font(0)
        font.setBold(True)
        section.setFont(0, font)
        self._tree.addTopLevelItem(section)
        if not issues:
            empty = QTreeWidgetItem(
                ["The whole file was read." if origin == "loading" else "No issues found.", ""]
            )
            section.addChild(empty)
            section.setExpanded(True)
            return

        for severity in severities:
            of_severity = [i for i in issues if i.severity == severity]
            if not of_severity:
                continue
            level = QTreeWidgetItem([f"{severity} ({len(of_severity)})", ""])
            level.setToolTip(0, SEVERITY_MEANING.get(severity, ""))
            self._colour(level, severity)
            section.addChild(level)
            if by_rule:
                groups: dict[str, list[Issue]] = {}
                for issue in of_severity:
                    groups.setdefault(issue.group, []).append(issue)
                for name, members in groups.items():
                    rule = QTreeWidgetItem([f"{name} ({len(members)})", ""])
                    rule.setToolTip(0, members[0].rule_description)
                    level.addChild(rule)
                    for issue in members:
                        rule.addChild(self._issue_item(issue))
                    rule.setExpanded(severity == "Mandatory" or len(groups) == 1)
            else:
                for issue in of_severity:
                    level.addChild(self._issue_item(issue))
            level.setExpanded(severity in ("Mandatory", "Critical", "Error"))
        section.setExpanded(True)

    def _issue_item(self, issue: Issue) -> QTreeWidgetItem:
        objects = ", ".join(self._name(oid) for oid in issue.object_ids[:3])
        if len(issue.object_ids) > 3:
            objects += f" +{len(issue.object_ids) - 3}"
        item = QTreeWidgetItem([issue.title, objects])
        item.setData(0, _ISSUE_ROLE, issue)
        item.setToolTip(0, issue.details or issue.title)
        return item

    def _name(self, object_id: str) -> str:
        return self._names.get(object_id, object_id)

    @staticmethod
    def _colour(item: QTreeWidgetItem, severity: str) -> None:
        colour = _COLOURS.get(severity)
        if colour:
            item.setForeground(0, QBrush(QColor(colour)))

    # ------------------------------------------------------------------
    # Detail view
    # ------------------------------------------------------------------

    def _overview_html(self) -> str:
        report = self._report
        rows = []
        for severity in VALIDATION_SEVERITIES + LOADING_SEVERITIES:
            count = report.count(severity)
            if count:
                rows.append(
                    f"<li><b>{severity}</b> ({count}): {html.escape(SEVERITY_MEANING[severity])}"
                    "</li>"
                )
        if report.data_lost and report.validation:
            rows.append(
                "<li>Validation checks the model as it was loaded, so what the loader left out "
                "can cause validation issues of its own. Start with the loading errors.</li>"
            )
        if report.data_lost and not report.lenient:
            rows.append(
                "<li>Part of the file was not loaded, so the drawing and the model tree may miss "
                "objects. <b>Reopen leniently</b> loads objects that lack a mandatory attribute, "
                "and lists each omission here.</li>"
            )
        body = "".join(rows) or "<li>Nothing to report.</li>"
        return f"<p>Select an issue to see it in full.</p><ul>{body}</ul>"

    def _issue_html(self, issue: Issue) -> str:
        parts = [f"<p><b>{html.escape(issue.title)}</b></p>"]
        meaning = SEVERITY_MEANING.get(issue.severity, "")
        parts.append(f"<p><i>{html.escape(issue.severity)}</i>: {html.escape(meaning)}</p>")
        if issue.details and issue.details != issue.title:
            text = html.escape(issue.details).replace("\n", "<br>")
            parts.append(f"<p>{text}</p>")
        if issue.object_ids:
            links = []
            for oid in issue.object_ids:
                name = html.escape(self._name(oid))
                if name != html.escape(oid):
                    name += f" <small>({html.escape(oid)})</small>"
                if oid in self._known_ids:
                    links.append(f'<a href="{html.escape(oid)}">{name}</a>')
                else:
                    links.append(f"{name} <i>(not in the loaded model)</i>")
            hint = " (click one to zoom to it)" if set(issue.object_ids) & self._known_ids else ""
            parts.append(f"<p><b>Objects</b>{hint}: " + ", ".join(links) + "</p>")
        if issue.line is not None:
            parts.append(f"<p><b>Line in the file:</b> {issue.line}</p>")
        if issue.origin == "validation":
            rule = f"<p><b>Rule:</b> {html.escape(issue.group)} <code>{issue.rule_id}</code>"
            if issue.rule_description:
                rule += f"<br>{html.escape(issue.rule_description)}"
            if issue.rule_source:
                rule += f"<br><b>Source:</b> {html.escape(issue.rule_source)}"
            parts.append(rule + "</p>")
        return "".join(parts)

    # ------------------------------------------------------------------
    # Signals
    # ------------------------------------------------------------------

    def _on_current_changed(self, current: QTreeWidgetItem | None, _previous: object) -> None:
        issue = current.data(0, _ISSUE_ROLE) if current is not None else None
        if issue is None:
            self._detail.setHtml(self._overview_html())
            return
        self._detail.setHtml(self._issue_html(issue))
        ids = [oid for oid in issue.object_ids if oid in self._known_ids]
        if ids:
            self.objects_selected.emit(ids)

    def _on_double_clicked(self, item: QTreeWidgetItem, _column: int) -> None:
        issue = item.data(0, _ISSUE_ROLE)
        if issue is None:
            return
        ids = [oid for oid in issue.object_ids if oid in self._known_ids]
        if ids:
            self.zoom_requested.emit(ids[0])
