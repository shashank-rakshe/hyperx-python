"""What is wrong with an opened file: what its loader reported, and what validation found.

Both lists come from pyDEXPI. The loader's error registry says what it could not read
(``pydexpi.loaders.public.load_xml_with_report``), and ``pydexpi.validation.validate``
says where the loaded model breaks a rule. This module only puts the two into one
shape the Issues panel can show, sort and export; it decides nothing about a model.
"""

from __future__ import annotations

import csv
from collections.abc import Iterable
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path
from typing import TYPE_CHECKING, Literal

if TYPE_CHECKING:
    from pydexpi.loaders.error_registry import ErrorRegistryEntry
    from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel
    from pydexpi.validation import ValidationIssue

Origin = Literal["loading", "validation"]

#: The severities, most severe first. Loading uses pyDEXPI's error levels, validation its
#: levels of recommendation; the two are kept apart because they mean different things.
LOADING_SEVERITIES: tuple[str, ...] = ("Critical", "Error", "Warning", "Info")
VALIDATION_SEVERITIES: tuple[str, ...] = ("Mandatory", "Recommended", "Optional")

#: What each severity means, for the panel's tooltips and the detail view.
SEVERITY_MEANING: dict[str, str] = {
    "Critical": "The file could not be loaded.",
    "Error": "Part of the file was not loaded: the model lacks data the file holds.",
    "Warning": "Read with an assumption or a change; no data was lost.",
    "Info": "A note from the loader.",
    "Mandatory": "Breaks a requirement of the DEXPI specification.",
    "Recommended": "Breaks a pyDEXPI convention; the model is still valid DEXPI.",
    "Optional": "A suggestion.",
}


@dataclass(frozen=True)
class Issue:
    """One problem with the opened file.

    Attributes
    ----------
    origin : {"loading", "validation"}
        Whether the loader or validation reported it.
    severity : str
        One of :data:`LOADING_SEVERITIES` or :data:`VALIDATION_SEVERITIES`.
    title : str
        One line naming the problem.
    details : str
        The full text, which may repeat the title.
    object_ids : tuple of str
        The ids of the objects the issue is about. A loading issue's object may be one the
        loader dropped, so it need not be in the model.
    group : str
        What issues are grouped by: the rule's name, or the loader's severity.
    rule_id, rule_description, rule_source : str
        For a validation issue, the rule that reported it.
    line : int or None
        For a loading issue, the line in the file, when the loader knows it.
    """

    origin: Origin
    severity: str
    title: str
    details: str = ""
    object_ids: tuple[str, ...] = ()
    group: str = ""
    rule_id: str = ""
    rule_description: str = ""
    rule_source: str = ""
    line: int | None = None


@dataclass
class IssueReport:
    """Everything known to be wrong with the opened file."""

    loading: list[Issue] = field(default_factory=list)
    validation: list[Issue] = field(default_factory=list)
    #: Whether the file was loaded with pyDEXPI's lenient setting.
    lenient: bool = False

    def count(self, severity: str) -> int:
        """How many issues of *severity* the report holds."""
        return sum(1 for i in self.loading + self.validation if i.severity == severity)

    @property
    def data_lost(self) -> bool:
        """Whether the loader left out part of the file."""
        return any(i.severity in ("Critical", "Error") for i in self.loading)

    @property
    def needs_attention(self) -> bool:
        """Whether the report holds anything a user should see without asking."""
        return self.data_lost or self.count("Mandatory") > 0


def _loading_severity(entry: ErrorRegistryEntry) -> str:
    return str(getattr(entry.level, "value", entry.level)).capitalize()


def issues_from_loading(entries: Iterable[ErrorRegistryEntry]) -> list[Issue]:
    """Turn the loader's error registry entries into issues, most severe first."""
    issues = []
    for entry in entries:
        severity = _loading_severity(entry)
        message = str(entry.message)
        title = message.split("\n", 1)[0]
        issues.append(
            Issue(
                origin="loading",
                severity=severity,
                title=title,
                details=message,
                object_ids=(str(entry.object_id),) if entry.object_id else (),
                group=severity,
                line=entry.line,
            )
        )
    order = {s: n for n, s in enumerate(LOADING_SEVERITIES)}
    return sorted(issues, key=lambda i: order.get(i.severity, len(order)))


@cache
def _rules() -> dict[str, object]:
    from pydexpi.validation import default_validator_factory

    return dict(default_validator_factory().rules)


def _validation_severity(issue: ValidationIssue) -> str:
    return str(getattr(issue.level_of_recommendation, "value", issue.level_of_recommendation))


def issues_from_validation(found: Iterable[ValidationIssue]) -> list[Issue]:
    """Turn pyDEXPI's validation issues into issues, Mandatory first, then by rule."""
    rules = _rules()
    issues = []
    for issue in found:
        rule = rules.get(issue.applied_rule_id)
        issues.append(
            Issue(
                origin="validation",
                severity=_validation_severity(issue),
                title=issue.short_description,
                details=issue.long_description,
                object_ids=tuple(str(i) for i in issue.affected_component_ids or ()),
                group=str(getattr(rule, "name", "") or issue.applied_rule_id),
                rule_id=issue.applied_rule_id,
                rule_description=str(getattr(rule, "description", "") or ""),
                rule_source=str(getattr(rule, "source", "") or ""),
            )
        )
    order = {s: n for n, s in enumerate(VALIDATION_SEVERITIES)}
    return sorted(issues, key=lambda i: (order.get(i.severity, len(order)), i.group))


def validate(model: EngineeringModel) -> list[Issue]:
    """Validate *model* with pyDEXPI's built-in rules."""
    from pydexpi.validation import validate as pydexpi_validate

    return issues_from_validation(pydexpi_validate(model))


def status_text(report: IssueReport) -> str:
    """One line for the status bar saying what the report holds."""
    parts = []
    if report.data_lost:
        lost = report.count("Error") + report.count("Critical")
        parts.append(f"{lost} loading error(s): part of the file was not loaded")
    mandatory, recommended = report.count("Mandatory"), report.count("Recommended")
    if mandatory or recommended:
        parts.append(f"{mandatory} mandatory and {recommended} recommended issue(s)")
    if not parts:
        return "Validation: no issues found."
    return "Validation: " + "; ".join(parts) + ". See the Issues panel."


def summary_text(report: IssueReport) -> str:
    """The panel's headline: what was checked and what it found."""
    loaded = "Loaded leniently" if report.lenient else "Loaded"
    lost = report.count("Error") + report.count("Critical")
    loading = (
        f"{loaded}: {lost} error(s) — part of the file was not loaded"
        if lost
        else f"{loaded}: the whole file was read"
    )
    mandatory, recommended = report.count("Mandatory"), report.count("Recommended")
    if mandatory or recommended:
        checked = f"Validation: {mandatory} mandatory, {recommended} recommended"
    else:
        checked = "Validation: no issues found"
    return f"{loading}.   {checked}."


_CSV_COLUMNS = ("origin", "severity", "group", "title", "details", "objects", "line", "rule")


def write_csv(issues: Iterable[Issue], path: str | Path) -> int:
    """Write *issues* to a CSV file and return how many were written."""
    count = 0
    with Path(path).open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(_CSV_COLUMNS)
        for issue in issues:
            writer.writerow(
                (
                    issue.origin,
                    issue.severity,
                    issue.group,
                    issue.title,
                    issue.details,
                    " ".join(issue.object_ids),
                    "" if issue.line is None else issue.line,
                    issue.rule_id,
                )
            )
            count += 1
    return count
