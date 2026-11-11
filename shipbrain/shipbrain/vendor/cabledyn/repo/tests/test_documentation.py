#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Fast structural checks for the public Sphinx manual."""

from __future__ import annotations

import ast
import re
import runpy
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "doc"
SOURCE_SUFFIXES = {".rst", ".md"}
MARKDOWN_AREAS = (
    ROOT,
    ROOT / ".github",
    ROOT / "doc",
    ROOT / "examples",
    ROOT / "integration",
    ROOT / "python",
    ROOT / "release",
    ROOT / "validation",
)


def source_documents() -> set[str]:
    return {
        path.stem
        for path in DOC.iterdir()
        if path.is_file()
        and path.suffix in SOURCE_SUFFIXES
        and path.name != "index.rst"
    }


def toctree_documents() -> set[str]:
    entries: set[str] = set()
    in_tree = False
    for line in (DOC / "index.rst").read_text(encoding="utf-8").splitlines():
        if line.strip() == ".. toctree::":
            in_tree = True
            continue
        if not in_tree:
            continue
        if not line.strip() or line.lstrip().startswith(":"):
            continue
        if line.startswith("   "):
            entries.add(line.strip())
        else:
            in_tree = False
    return entries


def public_markdown_files() -> list[Path]:
    """Return the tracked areas that form the public software documentation."""
    files = set(ROOT.glob("*.md"))
    for area in MARKDOWN_AREAS[1:]:
        files.update(area.rglob("*.md"))
    return sorted(files)


class DocumentationTests(unittest.TestCase):
    def test_release_metadata_is_consistent(self) -> None:
        cmake = (ROOT / "CMakeLists.txt").read_text(encoding="utf-8")
        match = re.search(r"project\(CableDynCore VERSION (\d+\.\d+\.\d+)", cmake)
        self.assertIsNotNone(match, "CMake project version is missing")
        version = match.group(1)
        major, minor, patch = version.split(".")
        expected = {
            ROOT / "CITATION.cff": f"version: {version}",
            ROOT / "src" / "CableDyn_Banner.f90": f"CableDyn  v{version}",
            ROOT / "src" / "CableDyn_CAPI.f90": f"CableDyn {version} C-ABI 1",
            ROOT / "src" / "CableDyn_CAPI.h": f"CABLEDYN_CAPI_VERSION_MINOR {minor}",
            ROOT / "src" / "openfast" / "CableDyn_OF.f90": f"'v{version}'",
            ROOT / "python" / "pyproject.toml": f'version = "{version}"',
            ROOT / "python" / "cabledyn" / "__init__.py": f'__version__ = "{version}"',
            DOC / "index.rst": f"``v{version}``",
        }
        for path, token in expected.items():
            self.assertIn(
                token, path.read_text(encoding="utf-8"), f"stale version in {path}"
            )
        # The manual derives its version from CMakeLists.txt rather than repeating it.
        conf = runpy.run_path(str(DOC / "conf.py"))
        self.assertEqual(conf["release"], version, "doc/conf.py release differs from CMake")
        self.assertEqual(conf["version"], version, "doc/conf.py version differs from CMake")
        header = (ROOT / "src" / "CableDyn_CAPI.h").read_text(encoding="utf-8")
        self.assertIn(f"CABLEDYN_CAPI_VERSION_MAJOR {major}", header)
        self.assertIn(f"CABLEDYN_CAPI_VERSION_PATCH {patch}", header)

    def test_every_tracked_file_names_the_current_version(self) -> None:
        checker = runpy.run_path(str(ROOT / "release" / "check_release_metadata.py"))
        cmake = (ROOT / "CMakeLists.txt").read_text(encoding="utf-8")
        match = re.search(r"project\(CableDynCore VERSION (\d+\.\d+\.\d+)", cmake)
        self.assertIsNotNone(match, "CMake project version is missing")
        version = match.group(1)
        self.assertEqual(checker["stale_version_references"](version), [])
        pattern = checker["VERSION_REFERENCE"]
        for spelling in (
            "CableDyn  v0.0.9",
            "Running CableDyn (v0.0.9, 2026-01-01)",
            "cabledyn-0.0.9-py3-none-any.whl",
            "releases/tag/v0.0.9",
            "lib/libcabledyn.so.0.0.9",
            "CableDyn 0.0.9 C-ABI 1",
        ):
            found = pattern.search(spelling)
            self.assertIsNotNone(found, spelling)
            self.assertEqual(found.group(1), "0.0.9", spelling)
        for unrelated in ("tolerance 0.0.9e-3", "OpenFAST v5.0.0", "numpy 2.4.3"):
            versions = [m.group(1) for m in pattern.finditer(unrelated)]
            self.assertFalse(any(v.startswith("0.") for v in versions), unrelated)
        self.assertEqual(checker["PAST_RELEASE_MARK"], "past-release")
        historical = checker["HISTORICAL"]
        self.assertIsNotNone(historical.match("validation/RELEASE_0_1_0.md"))
        self.assertIsNone(historical.match("doc/installation.rst"))

    def test_windows_release_is_publicly_reproducible(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "release-windows-static.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("repository: OpenFAST/openfast", workflow)
        self.assertIn("build_static_windows.ps1", workflow)
        self.assertNotIn("CABLEDYN_OPENFAST_TOKEN", workflow)
        for asset in ("CableDyn_driver.exe", "openfast.exe", "SHA256SUMS.txt"):
            self.assertIn(asset, workflow)
        patches = sorted(
            (ROOT / "integration" / "openfast" / "patches").glob("*.patch")
        )
        self.assertGreater(
            len(patches), 0, "OpenFAST integration patch series is missing"
        )
        build_script = (ROOT / "release" / "build_static_windows.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("prepare_openfast_source.ps1", build_script)
        self.assertIn("integrate_openfast_vs_solution.ps1", build_script)
        self.assertLess(
            build_script.index("prepare_openfast_source.ps1"),
            build_script.index("integrate_openfast_vs_solution.ps1"),
            "the host glue patch must be applied before adding the Visual Studio project",
        )
        # openfast.exe names its OpenFAST base and the CableDyn version, never '-dirty':
        # both build routes stamp it, the release build checks it, and the release
        # checkout carries the tags `git describe` needs.
        integrate_script = (
            ROOT / "integration" / "openfast" / "integrate_openfast_vs_solution.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("CreateGitVersion.bat", integrate_script)
        self.assertIn("describe --tags --abbrev=8", integrate_script)
        version_patch = (
            ROOT / "integration" / "openfast" / "patches" / "0021-version-cmake.patch"
        ).read_text(encoding="utf-8")
        self.assertIn('-CableDyn-${_cabledyn_version}', version_patch)
        self.assertIn("@('-v')", build_script)
        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn("devenv.com", build_script)
        self.assertIn("Release|x64", build_script)
        self.assertNotIn('cmake --build `"$ofBuild`"', build_script)
        self.assertLess(
            build_script.index("$vsRoot ="),
            build_script.index("if (-not $VcVarsAll)"),
            "Visual Studio discovery must also run when -VcVarsAll is overridden",
        )
        vs_project = (
            ROOT / "integration" / "openfast" / "vs-build" / "CableDyn.vfproj.in"
        )
        self.assertTrue(vs_project.is_file())
        farm_patch = (
            ROOT / "integration" / "openfast" / "patches" / "0004-fast-farm-subs.patch"
        ).read_text(encoding="utf-8")
        for token in (
            "CD_InitInp%Tmax",
            "p_FAST%Gravity",
            "WaveField%WtrDens",
            "WaveField%WtrDpth",
            "farm%CD%InputTimes(1) =  0.0_DbKi",
        ):
            self.assertIn(
                token,
                farm_patch,
                f"FAST.Farm host environment propagation lost: {token}",
            )
        # both hosts tell CableDyn that a run completed, which gates its whole-run outputs
        for hook in ("0014-fast-subs.patch", "0023-fast-farm-end.patch"):
            self.assertIn(
                "%CD%m%HostComplete = .true.",
                (ROOT / "integration" / "openfast" / "patches" / hook).read_text(encoding="utf-8"),
                f"run-completion signal lost: {hook}",
            )
        self.assertNotIn("CD_InitInp%g         =    9.81", farm_patch)
        self.assertNotIn("CD_InitInp%rhoW      = 1025.0", farm_patch)
        farm_registry = (
            ROOT
            / "integration"
            / "openfast"
            / "patches"
            / "0003-fast-farm-registry.patch"
        ).read_text(encoding="utf-8")
        farm_types = (
            ROOT / "integration" / "openfast" / "patches" / "0005-fast-farm-types.patch"
        ).read_text(encoding="utf-8")
        self.assertIn("usefrom CableDyn_Registry.txt", farm_registry)
        self.assertIn("USE CableDyn_Types", farm_types)
        # the CMake route links openfast.exe and FAST.Farm.exe with a stack reserve on Windows
        # GNU: MinGW's 2 MiB default overflows while FAST.Farm initialises its turbines
        stack_patch = (
            ROOT / "integration" / "openfast" / "patches" / "0022-glue-stack-cmake.patch"
        ).read_text(encoding="utf-8")
        for target in ("openfast", "FAST.Farm"):
            self.assertIn(
                f'target_link_options({target} PRIVATE "LINKER:--stack,268435456")',
                stack_patch,
            )

    def test_public_documentation_has_one_source_tree(self) -> None:
        self.assertFalse(
            (ROOT / "docs").exists(),
            "use doc/; do not recreate the retired docs/ split",
        )
        for name in ("conventions.rst", "coupling_boundary.md", "driver_format.md"):
            self.assertTrue((DOC / name).is_file(), f"missing authoritative doc/{name}")

    def test_all_markdown_relative_links_resolve(self) -> None:
        link = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
        for path in public_markdown_files():
            for raw_target in link.findall(path.read_text(encoding="utf-8")):
                target = raw_target.strip().strip("<>")
                if target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                target = target.split("#", 1)[0]
                if target:
                    resolved = (path.parent / target).resolve()
                    self.assertTrue(
                        resolved.exists(),
                        f"{path.relative_to(ROOT)}: missing link {target}",
                    )

    def test_every_public_python_name_has_an_api_directive(self) -> None:
        init = ROOT / "python" / "cabledyn" / "__init__.py"
        public: list[str] | None = None
        for node in ast.parse(init.read_text(encoding="utf-8")).body:
            if isinstance(node, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id == "__all__"
                for target in node.targets
            ):
                public = ast.literal_eval(node.value)
        self.assertIsNotNone(public, "cabledyn.__all__ is missing")
        directive = re.compile(
            r"^\.\.\s+(?:auto(?:class|function|exception|data)"
            r"|py:(?:class|function|exception|data))::\s+(?:cabledyn\.)?([A-Za-z_]\w*)",
            re.MULTILINE,
        )
        documented = set(
            directive.findall((DOC / "api_python.rst").read_text(encoding="utf-8"))
        )
        missing = sorted(set(public or ()) - documented)
        self.assertEqual(missing, [], f"doc/api_python.rst does not document {missing}")

    def test_every_source_is_in_navigation(self) -> None:
        self.assertEqual(source_documents(), toctree_documents())

    def test_doc_roles_resolve_to_local_sources(self) -> None:
        available = source_documents() | {"index"}
        role = re.compile(r":doc:`(?:[^`<>]+<)?\s*([^`<>\s]+)\s*>?`")
        for path in DOC.iterdir():
            if path.suffix not in SOURCE_SUFFIXES:
                continue
            for target in role.findall(path.read_text(encoding="utf-8")):
                self.assertIn(
                    target, available, f"{path.name}: unresolved :doc: target {target}"
                )

    def test_markdown_include_targets_exist(self) -> None:
        include = re.compile(r"\{include\}\s+([^\s}]+)")
        for path in DOC.glob("*.md"):
            for target in include.findall(path.read_text(encoding="utf-8")):
                self.assertTrue(
                    (DOC / target).resolve().is_file(), f"{path.name}: missing {target}"
                )

    def test_every_public_example_is_catalogued(self) -> None:
        catalogue = (DOC / "examples.rst").read_text(encoding="utf-8")
        examples = ROOT / "examples"
        public_inputs = list(examples.glob("*.dat"))
        public_inputs += list(examples.glob("moordynC_*/*.dat"))
        public_inputs += list((examples / "openfast").glob("*.dat"))
        public_inputs += list((examples / "openfast").glob("*.fst"))
        for path in public_inputs:
            self.assertIn(
                path.name, catalogue, f"examples.rst does not catalogue {path.name}"
            )

    def test_example_file_roles_are_separated(self) -> None:
        examples = ROOT / "examples"
        self.assertEqual(
            list(examples.glob("*.inp")),
            [],
            "examples contain only .dat decks and auxiliary data",
        )
        self.assertEqual(
            list(examples.glob("syrope_settings.dat")),
            [],
            "material data belong in examples/data",
        )
        self.assertEqual(
            list(examples.glob("syrope_owc.dat")),
            [],
            "material data belong in examples/data",
        )
        self.assertFalse((examples / "line_driver").exists(), "developer fixtures are not examples")

    def test_retired_claims_do_not_return(self) -> None:
        text = "\n".join(
            path.read_text(encoding="utf-8")
            for path in DOC.iterdir()
            if path.suffix in SOURCE_SUFFIXES
        )
        retired = (
            "standalone deck-dynamic route uses the legacy Cosserat",
            "coupled 6-DOF rigid bodies and rods\n     - these run in the **standalone** driver",
            "Free/Connect points in the FAST.Farm aggregate",
        )
        for claim in retired:
            self.assertNotIn(claim, text)


if __name__ == "__main__":
    unittest.main()
