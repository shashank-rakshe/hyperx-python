#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Check that CableDyn release identifiers agree across public interfaces."""

from __future__ import annotations

import re
import runpy
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def capture(relative_path: str, pattern: str, label: str) -> str:
    match = re.search(pattern, read(relative_path), flags=re.MULTILINE)
    if match is None:
        raise ValueError(f"{relative_path}: cannot find {label}")
    return match.group(1)


# Spellings that name a CableDyn release: "CableDyn 0.4.2", "CableDyn v0.4.2", "v0.4.2",
# "cabledyn-0.4.2-py3-none-any.whl", ".../releases/tag/v0.4.2" and "libcabledyn.so.0.4.2".
VERSION_REFERENCE = re.compile(
    r"(?i)(?:cabledyn[ _-]+v?|cabledyn-|releases/tag/v|libcabledyn\.(?:so\.)?|(?<![\w.])v)"
    r"(\d+\.\d+\.\d+)(?![\w.]*\d)"
)
SWEPT_SUFFIXES = {
    ".c", ".cff", ".f90", ".h", ".json", ".md", ".ps1", ".py", ".rst", ".toml", ".txt", ".yml",
}
# Records of a past release keep the version they describe, and the test of this check
# spells made-up versions; every other tracked file must name the current version only.
HISTORICAL = re.compile(
    r"^(CHANGELOG\.md|validation/(RELEASE|PERFORMANCE)_\d+_\d+_\d+\.md"
    r"|validation/PAPER_REPRODUCTION\.md|validation/README\.md"
    r"|validation/experiments/[^/]+/provenance\.json|validation/bodies/references/.*"
    r"|validation/performance/.*"
    r"|tests/test_documentation\.py)$"
)


# A line that names a past release on purpose (a test of how an older driver is handled)
# carries this mark.
PAST_RELEASE_MARK = "past-release"


def tracked_files() -> list[str]:
    try:
        listing = subprocess.run(
            ["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True
        ).stdout.decode("utf-8")
        names = [name for name in listing.split("\0") if name]
    except (OSError, subprocess.CalledProcessError):
        names = [path.relative_to(ROOT).as_posix() for path in ROOT.rglob("*") if path.is_file()]
    return sorted(name for name in names if Path(name).suffix in SWEPT_SUFFIXES)


def stale_version_references(version: str) -> list[str]:
    """Return ``path:line: text`` for every reference to a CableDyn version other than ``version``."""
    stale = []
    for name in tracked_files():
        if HISTORICAL.match(name):
            continue
        path = ROOT / name
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if PAST_RELEASE_MARK in line:
                continue
            for match in VERSION_REFERENCE.finditer(line):
                if match.group(1) != version and match.group(1).startswith("0."):
                    stale.append(f"{name}:{number}: {line.strip()}")
    return stale


def main() -> int:
    try:
        version = capture(
            "CMakeLists.txt",
            r"project\(CableDynCore VERSION (\d+\.\d+\.\d+)",
            "CMake project version",
        )
        citation_version = capture("CITATION.cff", r"^version:\s*([^\s]+)$", "citation version")
        release_date = capture(
            "CITATION.cff", r"^date-released:\s*(\d{4}-\d{2}-\d{2})$", "release date"
        )
        abi_version = capture(
            "src/CableDyn_CAPI.f90",
            r"CD_C_ABI_VERSION\s*=\s*(\d+)_C_INT",
            "C ABI version",
        )
        abi_minor = capture(
            "src/CableDyn_CAPI.f90",
            r"CD_C_ABI_MINOR\s*=\s*(\d+)_C_INT",
            "C ABI minor level",
        )
    except ValueError as error:
        print(f"release metadata: FAIL\n- {error}", file=sys.stderr)
        return 1

    major, minor, patch = version.split(".")
    # The manual derives its version from CMakeLists.txt; evaluate its configuration.
    sphinx_conf = runpy.run_path(str(ROOT / "doc" / "conf.py"))

    checks = {
        "CITATION.cff version": citation_version == version,
        "Python project version": f'version = "{version}"' in read("python/pyproject.toml"),
        "Published distribution version": f'version = "{version}"' in read("pyproject.toml"),
        "Python runtime version": f'__version__ = "{version}"' in read("python/cabledyn/__init__.py"),
        "Fortran banner version": f"CableDyn  v{version}" in read("src/CableDyn_Banner.f90"),
        "C ABI version string": f"CableDyn {version} C-ABI {abi_version}" in read(
            "src/CableDyn_CAPI.f90"
        ),
        "C ABI numeric version": all(
            token in read("src/CableDyn_CAPI.f90")
            for token in (
                f"CD_C_VERSION_MAJOR = {major}_C_INT",
                f"CD_C_VERSION_MINOR = {minor}_C_INT",
                f"CD_C_VERSION_PATCH = {patch}_C_INT",
            )
        ),
        "C header numeric version": all(
            token in read("src/CableDyn_CAPI.h")
            for token in (
                f"CABLEDYN_CAPI_VERSION_MAJOR {major}",
                f"CABLEDYN_CAPI_VERSION_MINOR {minor}",
                f"CABLEDYN_CAPI_VERSION_PATCH {patch}",
            )
        ),
        "C header ABI minor level": f"CABLEDYN_CAPI_ABI_MINOR {abi_minor}" in read(
            "src/CableDyn_CAPI.h"
        ),
        "Python ABI minor level": f"HOST_FLUID_ABI_MINOR = {abi_minor}" in read(
            "python/cabledyn/_lib.py"
        ),
        "C header ABI version": f"CABLEDYN_CAPI_ABI_VERSION {abi_version}" in read(
            "src/CableDyn_CAPI.h"
        ),
        "Python ABI version": f"SUPPORTED_ABI = {abi_version}" in read(
            "python/cabledyn/_lib.py"
        ),
        "Fortran C API test version": (
            f"major == {major}_C_INT" in read("tests/test_c_api.f90")
            and f"minor == {minor}_C_INT" in read("tests/test_c_api.f90")
            and f"patch == {patch}_C_INT" in read("tests/test_c_api.f90")
            and f"abi_version == {abi_version}_C_INT" in read("tests/test_c_api.f90")
        ),
        "OpenFAST module version": f"'v{version}', '{release_date}'" in read(
            "src/openfast/CableDyn_OF.f90"
        ),
        "Sphinx version": sphinx_conf["version"] == version,
        "Sphinx release": sphinx_conf["release"] == version,
        "README stable version": f"stable release is `v{version}`" in read("README.md"),
        "manual stable version": f"``v{version}`` is the current stable release" in read(
            "doc/index.rst"
        ),
        "changelog release heading": f"## [{version}] - {release_date}" in read("CHANGELOG.md"),
        "OpenFAST integration version": f"CableDyn v{version})" in read(
            "integration/openfast/README.md"
        ),
        "OpenFAST example banner": f"Running CableDyn (v{version}," in read(
            "examples/openfast/README.md"
        ),
        # The name openfast.exe reports (release/build_static_windows.ps1 checks the binary).
        "OpenFAST executable identity": all(
            re.search(rf"OpenFAST-v\d+\.\d+\.\d+-CableDyn-{re.escape(version)}\b", read(name))
            for name in ("doc/installation.rst", "RELEASE.md", "integration/openfast/README.md")
        ),
        "Python licence metadata": 'license-files = ["LICENSE"]' in read(
            "python/pyproject.toml"
        ),
        "Python licence file": (ROOT / "python" / "LICENSE").is_file(),
        "Published distribution licence metadata": 'license-files = ["LICENSE", "NOTICE"]' in read(
            "pyproject.toml"
        ),
    }
    failures = [label for label, passed in checks.items() if not passed]
    failures += [f"stale version reference {where}" for where in stale_version_references(version)]
    if failures:
        print("release metadata: FAIL", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"release metadata: PASS (CableDyn v{version}, {release_date})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
