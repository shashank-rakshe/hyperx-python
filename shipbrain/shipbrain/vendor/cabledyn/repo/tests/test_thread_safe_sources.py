#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Source audit of the storage that concurrent models could share.

Separate models (C API handles, Python objects) may step on several threads at once, so
the Fortran sources of the library and the driver (src/, app/) must keep every model's data
in the model. Compiler-independent checks, so that a gfortran build catches what only an
ifx build would show at run time (test_c_api_threads):

* no internal procedure is a procedure value (an actual argument, a keyword argument or a
  pointer target): ifx calls such a closure through a trampoline kept in memory that every
  thread shares;
* no local variable is initialised in its declaration (an implicit SAVE: one copy for every
  thread), and no DATA or COMMON;
* every variable in static storage (SAVE, module variables) is one of the reviewed
  process-wide entries below, with the reason it is not per-model state;
* the build makes every other local automatic (CMakeLists.txt: /Qauto, -auto, -frecursive;
  the OpenFAST Visual Studio project: LocalVariableStorage in every configuration).
"""

from __future__ import annotations

import re
import unittest
from collections.abc import Iterator
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = sorted(
    list((ROOT / "src").rglob("*.f90")) + list((ROOT / "app").rglob("*.f90")),
)

# (file, variable): why the process-wide storage is not model state.
REVIEWED_STATIC = {
    ("CableDyn_CAPI.f90", "g_handle_registry"): "live-handle registry, under the registry lock",
    ("CableDyn_CAPI.f90", "g_handle_count"): "live-handle registry, under the registry lock",
    ("CableDyn_OF.f90", "Inst"): "OpenFAST instance registry, resized at initialisation only",
    ("CableDyn_OF.f90", "g_serial"): "OpenFAST instance generation counter, at initialisation only",
    ("CableDyn_DeckDriver.f90", "body_static_pass_limit"): "test hook of the standalone body statics",
    ("CableDyn_DeckDriver.f90", "probe_armed"): "test hook of the standalone multibody march",
    ("CableDyn_DeckDriver.f90", "capture_notes"): "set only under the C API's process-wide input lock",
    ("CableDyn_DeckDriver.f90", "captured_notes"): "written only under the C API's process-wide input lock",
    ("CableDyn_DeckDriver.f90", "probe_v0"): "test hook of the standalone multibody march",
    ("CableDyn_DeckDriver.f90", "probe_w0"): "test hook of the standalone multibody march",
    ("CableDyn_DeckDriver.f90", "probe_rec"): "test hook of the standalone multibody march",
    ("CableDyn_DeckDriver.f90", "warned"): "warn-once flag of a message, under an OpenMP critical",
    ("CableDyn_Profile.f90", "*"): "opt-in run profile (CABLEDYN_PROFILE), written only when armed",
    ("CableDyn_HermiteCableDynamic.f90", "prof_*"): "opt-in step profile, written only when armed",
    ("cabledyn.f90", "printed"): "the driver program prints its profile once",
}

DECL = re.compile(
    r"^(integer|real|logical|character|complex|double\s+precision|type\s*\(|class\s*\(|procedure\s*\()",
    re.I,
)
UNIT = re.compile(
    r"^(?:(?:pure|elemental|impure|recursive|non_recursive|module)\s+)*"
    r"(?:(?:integer|real|logical|character|complex|double\s+precision|type\s*\([^)]*\))"
    r"(?:\s*\([^)]*\))?\s+)?(?:(?:pure|elemental|impure|recursive)\s+)*"
    r"(subroutine|function)\s+(\w+)",
    re.I,
)


def statements(path: Path) -> Iterator[tuple[int, str]]:
    """(line number, statement) with comments, continuations and semicolons resolved."""
    buf, start = "", 0
    for no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if raw.lstrip().startswith("#"):
            continue
        out: list[str] = []
        quote: str | None = None
        for ch in raw:
            if quote:
                out.append(ch)
                if ch == quote:
                    quote = None
            elif ch in "'\"":
                quote = ch
                out.append(ch)
            elif ch == "!":
                break
            else:
                out.append(ch)
        text = "".join(out).strip()
        if not text:
            continue
        if buf and text.startswith("&"):
            text = text[1:]
        if not buf:
            start = no
        if text.endswith("&"):
            buf += text[:-1] + " "
            continue
        line, buf, line_no = buf + text, "", start
        for stmt in split_top(line, ";"):
            if stmt.strip():
                yield line_no, stmt.strip()


def split_top(text: str, sep: str) -> list[str]:
    parts: list[str] = []
    cur: list[str] = []
    depth = 0
    quote: str | None = None
    for ch in text:
        if quote:
            cur.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
        elif ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
            continue
        cur.append(ch)
    parts.append("".join(cur))
    return parts


def without_strings(text: str) -> str:
    return re.sub(r"'[^']*'|\"[^\"]*\"", "''", text)


class Scope:
    def __init__(self, kind: str, name: str) -> None:
        self.kind, self.name = kind, name
        self.contains = False
        self.internal: list[str] = []
        self.declared: set[str] = set()
        self.body: list[tuple[int, str, Scope]] = []


def scan(path: Path) -> Iterator[tuple[str, int, str, str]]:
    """Yield (kind, line, scope name, detail) findings of one file."""
    stack: list[Scope] = []
    in_type = in_interface = 0
    hosts: list[Scope] = []
    for no, stmt in statements(path):
        low = stmt.lower()
        if in_interface:
            if re.match(r"^end\s*interface\b", low):
                in_interface -= 1
            continue
        if re.match(r"^(abstract\s+)?interface\b", low):
            in_interface += 1
            continue
        if in_type:
            if re.match(r"^end\s*type\b", low):
                in_type -= 1
            continue
        if re.match(r"^type\b(?!\s*\()(?!\s+is\b)", low):
            in_type += 1
            continue
        if re.match(r"^(module|submodule\s*\([^)]*\))\s+\w+\s*$", low) and not re.match(
            r"^module\s+(procedure|subroutine|function)\b", low
        ):
            stack.append(Scope("module", low.split()[-1]))
            continue
        if re.match(r"^program\s+\w+", low):
            stack.append(Scope("program", low.split()[1]))
            continue
        m = UNIT.match(stmt)
        if m and not low.startswith("end"):
            if stack and stack[-1].kind in ("unit", "program") and stack[-1].contains:
                stack[-1].internal.append(m.group(2).lower())
            stack.append(Scope("unit", m.group(2)))
            continue
        if re.match(r"^end\s*(subroutine|function|module|program|submodule)\b|^end$", low):
            if stack:
                done = stack.pop()
                if done.kind in ("unit", "program") and done.internal:
                    hosts.append(done)
            continue
        if low == "contains":
            if stack:
                stack[-1].contains = True
            continue
        unit = next((s for s in reversed(stack) if s.kind in ("unit", "program")), None)
        if unit is not None:
            for scope in stack:
                if scope.kind in ("unit", "program"):
                    scope.body.append((no, stmt, unit))
        where = unit.name if unit else (stack[-1].name if stack else "?")
        if re.match(r"^(data\s+\w|common\b)", low):
            yield "DATA/COMMON", no, where, stmt
            continue
        if re.match(r"^save\b(?!\s*=)", low):
            yield "SAVE statement", no, where, stmt
            continue
        if not DECL.match(stmt) or "::" not in stmt:
            continue
        attrs, names = stmt.split("::", 1)
        attrs_low = attrs.lower()
        variables = [m.group(1) for n in split_top(names, ",") if (m := re.match(r"\s*(\w+)", n))]
        if unit is not None:
            unit.declared.update(v.lower() for v in variables)
        if "parameter" in attrs_low:
            continue
        if unit is not None and unit.kind == "program":
            continue  # a main program's variables: one program, one thread
        if unit is None or re.search(r"\bsave\b", attrs_low):
            for name in variables:
                yield "STATIC", no, where, name
            continue
        if "intent" in attrs_low or re.search(r"\bvalue\b", attrs_low):
            continue
        for item in split_top(names, ","):
            body = item.replace("==", "")
            if "=" in body:  # an initialiser, "=> NULL()" included, implies SAVE
                yield "INITIALISED LOCAL", no, where, stmt
                break
    for host in hosts:
        internal_names = set(host.internal)
        for no, stmt, inside in host.body:
            code = without_strings(stmt).lower()
            # in its own body the name is the result; a local declaration hides it
            for name in internal_names - {inside.name.lower()} - inside.declared:
                for m in re.finditer(r"(?<![\w%])" + name + r"(?!\w)", code):
                    before = code[: m.start()].rstrip()
                    after = code[m.end() :].lstrip()
                    if after.startswith("("):
                        continue  # a call or a reference
                    if re.search(r"(^|[(,]|=>|\w\s*=)$", before) and not re.match(r"^\s*$", before):
                        yield "CLOSURE", no, host.name, f"{name}: {stmt[:120]}"


def reviewed(file: str, name: str) -> bool:
    for (f, pattern), _ in REVIEWED_STATIC.items():
        if f != file:
            continue
        if pattern == "*" or name == pattern:
            return True
        if pattern.endswith("*") and name.lower().startswith(pattern[:-1].lower()):
            return True
    return False


class ThreadSafeSources(unittest.TestCase):
    def setUp(self) -> None:
        self.findings = [(p.name, *f) for p in SOURCES for f in scan(p)]
        self.assertGreater(len(SOURCES), 40)

    def test_no_closures(self) -> None:
        bad = [f for f in self.findings if f[1] == "CLOSURE"]
        self.assertEqual(bad, [], "internal procedures passed as procedure values")

    def test_no_implicit_static_storage(self) -> None:
        bad = [
            f
            for f in self.findings
            if f[1] in ("INITIALISED LOCAL", "DATA/COMMON", "SAVE statement")
        ]
        self.assertEqual(bad, [], "locals in static storage")

    def test_static_storage_is_reviewed(self) -> None:
        bad = [f for f in self.findings if f[1] == "STATIC" and not reviewed(f[0], f[4])]
        self.assertEqual(bad, [], "static storage not in REVIEWED_STATIC")
        n = sum(1 for f in self.findings if f[1] == "STATIC")
        print(f"{n} reviewed variables in static storage in {len(SOURCES)} files")

    def test_build_makes_locals_automatic(self) -> None:
        cmake = (ROOT / "CMakeLists.txt").read_text(encoding="utf-8")
        for flag in ("-frecursive>", "/Qauto>", "-auto>"):
            self.assertTrue(flag in cmake, f"CMakeLists.txt does not pass {flag[:-1]}")
        # the OpenFAST Visual Studio project compiles the adapter: every configuration too
        vfproj = (ROOT / "integration/openfast/vs-build/CableDyn.vfproj.in").read_text(
            encoding="utf-8"
        )
        tools = re.findall(r"<Tool Name=\"VFFortranCompilerTool\"[^>]*>", vfproj)
        self.assertGreater(len(tools), 0)
        for tool in tools:
            self.assertIn('LocalVariableStorage="localStorageAutomatic"', tool)

    def test_audit_sees_a_closure_and_an_initialised_local(self) -> None:
        # the checks themselves: a closure and an implicit SAVE in a scratch source
        probe = Path(__file__).with_name("thread_safe_probe.f90.tmp")
        probe.write_text(
            "MODULE m\nCONTAINS\n  SUBROUTINE host(x)\n    REAL :: x\n    INTEGER :: calls = 0\n"
            "    CALL apply(f, x)\n    CALL apply(g=f)\n  CONTAINS\n    REAL FUNCTION f(y)\n"
            "      REAL :: y\n      f = y + x\n    END FUNCTION f\n  END SUBROUTINE host\nEND MODULE m\n",
            encoding="utf-8",
        )
        try:
            kinds = [f[0] for f in scan(probe)]
        finally:
            probe.unlink()
        self.assertEqual(kinds.count("CLOSURE"), 2, kinds)
        self.assertEqual(kinds.count("INITIALISED LOCAL"), 1, kinds)


if __name__ == "__main__":
    unittest.main()
