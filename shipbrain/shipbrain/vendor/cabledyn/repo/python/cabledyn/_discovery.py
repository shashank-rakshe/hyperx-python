# SPDX-License-Identifier: Apache-2.0
"""Locate the CableDyn shared library without loading it.

The search order is:

1. ``CABLEDYN_LIBRARY``: an exact path, used as given.
2. The package directory, for a wheel or deployment that bundles the library.
3. The CMake build tree of a source checkout (``<repo>/build``).

In the build tree only linker products are considered: ``build/bin`` and
``build`` for a single-configuration generator, and ``build/bin/<Config>`` and
``build/<Config>`` for a multi-configuration generator. The self-contained
``build/runtime`` bundle is a copy and is never auto-selected, so it cannot
shadow a newer build. When more than one configuration holds a library,
``CABLEDYN_BUILD_CONFIG`` must name the intended one; discovery never guesses.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

CMAKE_CONFIGURATIONS = ("Release", "RelWithDebInfo", "MinSizeRel", "Debug")
_UNCONFIGURED = "single-configuration"


def library_basenames(os_name: str | None = None, platform: str | None = None) -> tuple[str, ...]:
    """Return the shared-library file names loadable by the given (or current) host."""
    host_os = os.name if os_name is None else os_name
    host_platform = sys.platform if platform is None else platform
    if host_os == "nt":
        # GNU prefixes the DLL name; IFX/MSVC use the unprefixed name.
        return ("libcabledyn.dll", "cabledyn.dll")
    if host_platform == "darwin":
        return ("libcabledyn.dylib",)
    return ("libcabledyn.so",)


def _existing(directory: Path, basenames: tuple[str, ...]) -> list[Path]:
    """Return the libraries present in one directory, rejecting ambiguous pairs."""
    found = [directory / name for name in basenames if (directory / name).is_file()]
    if len(found) > 1:
        names = ", ".join(path.name for path in found)
        raise OSError(
            f"cabledyn: several CableDyn shared libraries exist in {directory} ({names}). "
            "Remove the stale product or set CABLEDYN_LIBRARY to the exact library path."
        )
    return found


def build_tree_layouts(build: Path) -> dict[str, tuple[Path, ...]]:
    """Return the linker-product directories of each CMake layout, in search order."""
    layouts: dict[str, tuple[Path, ...]] = {_UNCONFIGURED: (build / "bin", build)}
    for configuration in CMAKE_CONFIGURATIONS:
        layouts[configuration] = (build / "bin" / configuration, build / configuration)
    return layouts


def selected_configuration(value: str | None = None) -> str | None:
    """Return the canonical ``CABLEDYN_BUILD_CONFIG`` value, or ``None`` when unset."""
    requested = (os.environ.get("CABLEDYN_BUILD_CONFIG", "") if value is None else value).strip()
    if not requested:
        return None
    for configuration in CMAKE_CONFIGURATIONS:
        if configuration.lower() == requested.lower():
            return configuration
    choices = ", ".join(CMAKE_CONFIGURATIONS)
    raise OSError(f"cabledyn: CABLEDYN_BUILD_CONFIG must be one of {choices}; got {requested!r}")


def find_in_build_tree(
    build: Path,
    basenames: tuple[str, ...],
    configuration: str | None,
) -> tuple[Path | None, list[Path]]:
    """Return ``(library, searched)`` for a CMake build tree.

    ``library`` is ``None`` when nothing was found. Several populated layouts
    without an explicit ``configuration`` raise :class:`OSError`.
    """
    layouts = build_tree_layouts(build)
    searched = [
        directory / name for dirs in layouts.values() for directory in dirs for name in basenames
    ]
    # An explicit configuration also accepts a single-configuration build whose
    # CMAKE_BUILD_TYPE is not encoded in the directory layout.
    chosen = [configuration, _UNCONFIGURED] if configuration is not None else list(layouts)
    populated: dict[str, Path] = {}
    for name in chosen:
        for directory in layouts[name]:
            found = _existing(directory, basenames)
            if found:
                populated[name] = found[0]
                break
    if configuration is not None:
        if configuration in populated:
            return populated[configuration], searched
        if _UNCONFIGURED in populated and not any(
            _existing(directory, basenames)
            for name in CMAKE_CONFIGURATIONS
            for directory in layouts[name]
        ):
            return populated[_UNCONFIGURED], searched
        return None, searched
    if len(populated) > 1:
        layouts_found = ", ".join(sorted(populated))
        raise OSError(
            f"cabledyn: {build} contains CableDyn libraries for several build layouts "
            f"({layouts_found}). "
            "Set CABLEDYN_BUILD_CONFIG to the intended configuration or CABLEDYN_LIBRARY to the "
            "exact library path."
        )
    return (next(iter(populated.values())) if populated else None), searched


def find_library(package_directory: Path | None = None) -> Path:
    """Return the CableDyn shared library to load, or raise :class:`OSError`."""
    exact = os.environ.get("CABLEDYN_LIBRARY", "").strip()
    if exact:
        path = Path(exact).expanduser()
        if not path.is_file():
            raise OSError(f"cabledyn: CABLEDYN_LIBRARY does not name an existing file: {exact}")
        return path.resolve()

    package = Path(__file__).resolve().parent if package_directory is None else package_directory
    basenames = library_basenames()
    bundled = _existing(package, basenames)
    if bundled:
        return bundled[0]

    # Source checkout: <repo>/python/cabledyn -> <repo>/build.
    build = package.parent.parent / "build"
    library, searched = find_in_build_tree(build, basenames, selected_configuration())
    if library is not None:
        return library.resolve()
    tried = [package / name for name in basenames] + searched
    raise OSError(
        "cabledyn: could not locate the CableDyn shared library. Set CABLEDYN_LIBRARY to its "
        "full path, or build it with `cmake --build build --target cabledyn_shared`. Tried:\n  "
        + "\n  ".join(str(path) for path in tried)
    )


def dependency_directories(library: Path) -> list[Path]:
    """Return directories that may hold the library's toolchain runtime DLLs.

    The library's own directory comes first. For a multi-configuration build
    tree the GNU/OpenBLAS runtime set is staged once in ``build/bin`` and
    ``build/runtime`` rather than beside each configuration's product.
    """
    directories = [library.parent]
    for ancestor in library.parents:
        if ancestor.name == "build":
            directories.extend(
                path for path in (ancestor / "bin", ancestor / "runtime") if path.is_dir()
            )
            break
    unique: list[Path] = []
    for directory in directories:
        if directory not in unique:
            unique.append(directory)
    return unique
