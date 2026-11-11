"""Turn a licensecheck JSON report into a reviewable Markdown summary.

licensecheck decides pass/fail on licenses; this script adds the things its report does not
carry, and which reviewing a dependency-license failure depends on:

* whether a package is a *direct* dependency (declared in pyproject.toml) or a transitive one,
  so a failure says who to talk to;
* which dependency group pulled it in, and therefore whether it is distributed to users at all.
  A copyleft library inside the ``pdf`` extra is a materially different question from one that
  only builds the docs, so the report must not flatten the two;
* validation of ``license-exceptions.toml``, so an exemption cannot be added without recording
  the verified license, where it was checked, and which versions it was checked for.

Written for the standard library plus ``packaging``, which licensecheck already depends on.
Group resolution shells out to ``uv``, which licensecheck already requires.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    from packaging.specifiers import InvalidSpecifier, SpecifierSet
    from packaging.utils import canonicalize_name
    from packaging.version import InvalidVersion, Version
except ImportError:  # pragma: no cover - packaging ships with licensecheck
    sys.exit("error: 'packaging' is required. Install it alongside licensecheck.")

REQUIRED_EXCEPTION_FIELDS = (
    "package",
    "version_spec",
    "verified_license",
    "classification",
    "source",
    "reviewed_on",
    "reason",
)

CLASSIFICATIONS = {
    "weak-copyleft": "reviewed weak-copyleft dependency",
    "policy-exception": "policy exception",
}


@dataclass(frozen=True)
class Scope:
    """A dependency group, and whether installing pyDEXPI can put it on a user's machine."""

    key: str
    extras: tuple[str, ...]
    label: str
    distributed: bool


# Ordered by precedence: a package is attributed to the first scope that contains it, so anything
# reachable at runtime is reported as runtime even though the docs build also pulls it in.
# `export` and `dev` are omitted deliberately -- both are unions of scopes already listed here.
SCOPES: tuple[Scope, ...] = (
    Scope("core", (), "core (runtime)", True),
    Scope("cli", ("cli",), "cli extra", True),
    Scope("png", ("png",), "png extra", True),
    Scope("pdf", ("pdf",), "pdf extra", True),
    Scope("mcp", ("mcp",), "mcp extra", True),
    Scope("docs", ("docs",), "docs tooling", False),
    Scope("test", ("test",), "test tooling", False),
    Scope("lint", ("lint",), "lint tooling", False),
)

UNKNOWN_SCOPE = Scope("unknown", (), "unattributed", True)

# Strip everything from the first version specifier, extras bracket, marker or whitespace, so
# "mkdocstrings[python]>=1.0.4" and "pandas >= 3.0.3" both reduce to a bare distribution name.
_NAME_END = re.compile(r"[<>=!~;\[\s@]")


@dataclass
class Package:
    """One row of the licensecheck report, annotated with how it entered the tree."""

    name: str
    version: str
    license: str
    compatible: bool
    direct: bool
    scope: Scope = UNKNOWN_SCOPE

    @property
    def origin(self) -> str:
        return "direct" if self.direct else "transitive"

    @property
    def unknown(self) -> bool:
        """True when the license metadata could not be read, rather than being disallowed."""
        return not self.license.strip() or self.license.strip().upper() == "UNKNOWN"


@dataclass
class Report:
    packages: list[Package]
    exceptions: dict[str, dict[str, Any]]
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def failing(self) -> list[Package]:
        return [p for p in self.packages if not p.compatible and not p.unknown]

    @property
    def unknown(self) -> list[Package]:
        return [p for p in self.packages if not p.compatible and p.unknown]


def direct_dependency_names(pyproject: Path) -> set[str]:
    """Collect canonical names of every dependency pyDEXPI declares itself."""
    data = tomllib.loads(pyproject.read_text(encoding="utf-8"))
    project = data.get("project", {})

    declared: list[str] = list(project.get("dependencies", []))
    for extra_requirements in project.get("optional-dependencies", {}).values():
        declared.extend(extra_requirements)
    for group_requirements in data.get("dependency-groups", {}).values():
        declared.extend(r for r in group_requirements if isinstance(r, str))

    names = set()
    for requirement in declared:
        name = _NAME_END.split(requirement.strip(), 1)[0]
        if name:
            names.add(canonicalize_name(name))
    return names


def resolve_scope(pyproject: Path, scope: Scope) -> set[str] | None:
    """Resolve one dependency group with uv. None means uv could not resolve it."""
    command = ["uv", "pip", "compile", str(pyproject), "--no-header", "--quiet"]
    for extra in scope.extras:
        command += ["--extra", extra]

    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError:
        return None
    if result.returncode != 0:
        return None

    names = set()
    for line in result.stdout.splitlines():
        # uv emits "name==version" at column 0 and "    # via parent" continuation lines.
        if not line or line[:1].isspace() or line.startswith("#"):
            continue
        name = _NAME_END.split(line.strip(), 1)[0]
        if name:
            names.add(canonicalize_name(name))
    return names


def attribute_scopes(
    packages: list[Package], pyproject: Path, warnings: list[str], errors: list[str]
) -> dict[str, set[str]]:
    """Label each package with the first scope, by precedence, that pulls it in.

    Returns what uv resolved per scope key, so the caller can audit the inventory against it.
    """
    memberships: list[tuple[Scope, set[str]]] = []
    resolutions: dict[str, set[str]] = {}
    for scope in SCOPES:
        resolved = resolve_scope(pyproject, scope)
        if resolved is None:
            # An unresolvable core scope is not a cosmetic gap: it is the same failure that
            # makes licensecheck fall back to a resolver that sees only installed packages,
            # so there is nothing left to audit the report against. Fail rather than warn.
            message = (
                f"Could not resolve the '{scope.key}' dependency group with uv, so dependency "
                f"groups may be incomplete in this report."
            )
            if scope.key == "core":
                errors.append(
                    f"{message} The core group is what the inventory is checked against, so "
                    f"this run cannot be trusted. Re-run once uv can reach the index."
                )
            else:
                warnings.append(f"{message} The license verdict is unaffected.")
            continue
        memberships.append((scope, resolved))
        resolutions[scope.key] = resolved

    for package in packages:
        for scope, names in memberships:
            if package.name in names:
                package.scope = scope
                break
    return resolutions


def check_inventory_is_complete(report: Report, resolutions: dict[str, set[str]]) -> None:
    """Fail when the report covers less than the core dependency tree.

    licensecheck asks uv to resolve the tree, but *any* RuntimeError from that resolver -- a
    network hiccup, an index outage, an unsatisfiable constraint, a uv CLI change -- drops it
    silently to pip and then to a resolver that inspects only what is already installed. That
    fallback still exits 0, which turns a green license gate into a statement about a handful
    of packages. The presence check in scripts/licenses closes only the "uv is not installed"
    path; this closes the rest by holding the report against a core tree resolved here.
    """
    core = resolutions.get("core")
    if not core:
        return

    reported = {p.name for p in report.packages}
    missing = sorted(core - reported)
    if missing:
        report.errors.append(
            f"The report covers {len(report.packages)} packages but uv resolves "
            f"{len(core)} for the core dependency group alone, and "
            f"{len(missing)} of those are absent: {', '.join(missing[:10])}"
            f"{', ...' if len(missing) > 10 else ''}. licensecheck most likely fell back from "
            f"uv to a resolver that only sees installed packages, so this is a partial "
            f"inventory and its pass verdict means nothing. Re-run with a working uv."
        )


def load_exceptions(path: Path) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """Read and structurally validate license-exceptions.toml."""
    if not path.exists():
        return {}, []

    errors: list[str] = []
    exceptions: dict[str, dict[str, Any]] = {}

    declared = tomllib.loads(path.read_text(encoding="utf-8")).get("exception", [])
    for index, entry in enumerate(declared):
        label = entry.get("package") or f"entry #{index + 1}"

        missing = [f for f in REQUIRED_EXCEPTION_FIELDS if not str(entry.get(f, "")).strip()]
        if missing:
            errors.append(f"{path.name}: exception '{label}' is missing {', '.join(missing)}")
            continue

        if entry["classification"] not in CLASSIFICATIONS:
            errors.append(
                f"{path.name}: exception '{label}' has classification "
                f"{entry['classification']!r}, expected one of "
                f"{', '.join(sorted(CLASSIFICATIONS))}"
            )
            continue

        try:
            SpecifierSet(entry["version_spec"])
        except InvalidSpecifier:
            errors.append(
                f"{path.name}: exception '{label}' has an invalid version_spec "
                f"{entry['version_spec']!r}"
            )
            continue

        name = canonicalize_name(entry["package"])
        if name in exceptions:
            errors.append(f"{path.name}: exception '{label}' is declared more than once")
            continue
        exceptions[name] = entry

    return exceptions, errors


def check_exceptions_against_tree(report: Report) -> None:
    """Cross-check each exception against what the resolver actually produced."""
    resolved = {p.name: p for p in report.packages}

    for name, entry in report.exceptions.items():
        package = resolved.get(name)
        if package is None:
            report.warnings.append(
                f"Exception for '{entry['package']}' is stale: it is no longer in the "
                f"dependency tree and can be removed."
            )
            continue

        specifier = SpecifierSet(entry["version_spec"])
        try:
            version = Version(package.version)
        except InvalidVersion:
            report.warnings.append(
                f"Exception for '{entry['package']}': could not parse resolved version "
                f"{package.version!r}, version_spec not enforced."
            )
            continue

        if not specifier.contains(version, prereleases=True):
            report.errors.append(
                f"Exception for '{entry['package']}' was reviewed for "
                f"{entry['version_spec']} but CI resolved {package.version}. Re-verify the "
                f"license for this version and update license-exceptions.toml."
            )


def build_report(report_path: Path, pyproject: Path, exceptions_path: Path) -> Report:
    data = json.loads(report_path.read_text(encoding="utf-8"))
    direct = direct_dependency_names(pyproject)
    exceptions, errors = load_exceptions(exceptions_path)

    packages = [
        Package(
            name=canonicalize_name(entry.get("name", "")),
            version=str(entry.get("version", "")),
            license=str(entry.get("license", "")),
            compatible=bool(entry.get("licenseCompat")),
            direct=canonicalize_name(entry.get("name", "")) in direct,
        )
        for entry in data.get("packages", [])
    ]
    packages.sort(key=lambda p: p.name)

    report = Report(packages=packages, exceptions=exceptions, errors=errors)
    resolutions = attribute_scopes(report.packages, pyproject, report.warnings, report.errors)
    check_inventory_is_complete(report, resolutions)
    check_exceptions_against_tree(report)
    return report


def _table(packages: list[Package]) -> list[str]:
    lines = [
        "| Package | Version | License | Group | Origin |",
        "| --- | --- | --- | --- | --- |",
    ]
    lines += [
        f"| `{p.name}` | {p.version} | {p.license or '_none declared_'} | {p.scope.label} "
        f"| {p.origin} |"
        for p in packages
    ]
    return lines


def _by_distribution(packages: list[Package]) -> list[tuple[str, list[Package]]]:
    """Split packages by whether installing pyDEXPI can put them on a user's machine."""
    shipped = [p for p in packages if p.scope.distributed]
    internal = [p for p in packages if not p.scope.distributed]
    sections = []
    if shipped:
        sections.append(
            (
                "Reaches users (core runtime or an installable extra)",
                shipped,
            )
        )
    if internal:
        sections.append(
            (
                "Development tooling only (not distributed with pyDEXPI)",
                internal,
            )
        )
    return sections


def render(report: Report, policy_failed: bool) -> str:
    out: list[str] = ["# Dependency license report", ""]

    total = len(report.packages)
    exempted = len(report.exceptions)

    if report.errors:
        out += ["**FAILED** - the license exception file is not valid.", ""]
    elif policy_failed:
        out += ["**FAILED** - a dependency license is not allowed by the policy.", ""]
    else:
        out += [
            (
                f"**PASSED** - {total} dependencies checked, all allowed by the policy "
                f"({exempted} via a reviewed exception)."
            ),
            "",
        ]

    if report.errors:
        out += ["## Errors", ""] + [f"- {e}" for e in report.errors] + [""]

    if report.failing:
        out += [
            "## Disallowed licenses",
            "",
            (
                "These licenses are not permitted by the permissive-only policy in "
                "`[tool.licensecheck]`. Weigh a package that reaches users differently from one that "
                "only builds or tests pyDEXPI."
            ),
            "",
        ]
        for heading, packages in _by_distribution(report.failing):
            out += [f"**{heading}**", "", *_table(packages), ""]

    if report.unknown:
        out += [
            "## Unknown or missing license metadata",
            "",
            (
                "These packages could not be classified. An unknown license is not treated as "
                "compliant: verify each one at its source, then record it in "
                "`license-exceptions.toml`."
            ),
            "",
        ]
        for heading, packages in _by_distribution(report.unknown):
            out += [f"**{heading}**", "", *_table(packages), ""]
        out += ["<details><summary>Template to copy</summary>", "", "```toml"]
        for package in report.unknown:
            out += [
                "[[exception]]",
                f'package = "{package.name}"',
                f'version_spec = ">={package.version}"',
                'verified_license = "<SPDX id you confirmed>"',
                'classification = "weak-copyleft"  # or "policy-exception"',
                'source = "<URL of the LICENSE file you read>"',
                'reviewed_on = "<YYYY-MM-DD>"',
                'reviewed_by = "<name>"',
                f'reason = "<why this is acceptable for pyDEXPI ({package.scope.label})>"',
                "",
            ]
        out += ["```", "", "</details>", ""]

    if report.warnings:
        out += ["## Warnings", ""] + [f"- {w}" for w in report.warnings] + [""]

    if report.exceptions:
        resolved = {p.name: p for p in report.packages}
        out += [
            "## Reviewed exceptions",
            "",
            (
                "Maintainers' compatibility assessments, not legal approval. See "
                "`license-exceptions.toml` for the full reasoning."
            ),
            "",
            "| Package | Verified license | Assessment | Group | Reviewed | Source |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
        for name in sorted(report.exceptions):
            entry = report.exceptions[name]
            package = resolved.get(name)
            group = package.scope.label if package else "not in tree"
            out.append(
                f"| `{entry['package']}` | {entry['verified_license']} "
                f"| {CLASSIFICATIONS[entry['classification']]} | {group} "
                f"| {entry['reviewed_on']} | {entry['source']} |"
            )
        out.append("")

    direct_count = sum(1 for p in report.packages if p.direct)
    shipped_count = sum(1 for p in report.packages if p.scope.distributed)
    out += [
        "## Full inventory",
        "",
        (
            f"{total} packages: {direct_count} direct, {total - direct_count} transitive. "
            f"{shipped_count} can reach users, {total - shipped_count} are tooling only."
        ),
        "",
        "| Group | Packages |",
        "| --- | --- |",
    ]
    for scope in (*SCOPES, UNKNOWN_SCOPE):
        count = sum(1 for p in report.packages if p.scope.key == scope.key)
        if count:
            reach = "reaches users" if scope.distributed else "tooling only"
            out.append(f"| {scope.label} ({reach}) | {count} |")
    out += [
        "",
        "<details><summary>Show all dependencies</summary>",
        "",
        *_table(report.packages),
        "",
        "</details>",
        "",
    ]
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path, help="licensecheck JSON report")
    parser.add_argument("--pyproject", type=Path, default=Path("pyproject.toml"))
    parser.add_argument("--exceptions", type=Path, default=Path("license-exceptions.toml"))
    parser.add_argument("--out", type=Path, help="write the Markdown summary here as well")
    parser.add_argument(
        "--policy-failed",
        action="store_true",
        help="licensecheck exited non-zero, so report the run as failed",
    )
    args = parser.parse_args()

    report = build_report(args.report, args.pyproject, args.exceptions)
    markdown = render(report, policy_failed=args.policy_failed)

    print(markdown)
    if args.out:
        args.out.write_text(markdown, encoding="utf-8")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a", encoding="utf-8") as handle:
            handle.write(markdown + "\n")

    # --policy-failed means the headline says FAILED, so the exit code has to say so too:
    # a caller wiring this into CI should not have to also inspect licensecheck's own status.
    return 1 if report.errors or args.policy_failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
