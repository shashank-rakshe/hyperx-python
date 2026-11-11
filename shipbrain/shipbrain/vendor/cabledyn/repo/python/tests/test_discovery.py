# SPDX-License-Identifier: Apache-2.0
"""Shared-library discovery gates; these never load a native library."""

from __future__ import annotations

from pathlib import Path

import pytest

from cabledyn import _discovery as discovery


def _touch(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"library")
    return path


@pytest.fixture
def clean_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CABLEDYN_LIBRARY", raising=False)
    monkeypatch.delenv("CABLEDYN_BUILD_CONFIG", raising=False)


def _checkout(tmp_path: Path) -> tuple[Path, Path]:
    """Return (package directory, build directory) of a fake source checkout."""
    package = tmp_path / "repo" / "python" / "cabledyn"
    package.mkdir(parents=True)
    return package, tmp_path / "repo" / "build"


def test_library_basenames_are_host_specific() -> None:
    assert discovery.library_basenames("nt", "win32") == ("libcabledyn.dll", "cabledyn.dll")
    assert discovery.library_basenames("posix", "linux") == ("libcabledyn.so",)
    assert discovery.library_basenames("posix", "darwin") == ("libcabledyn.dylib",)


@pytest.mark.parametrize("relative", ["bin", "."])
def test_single_configuration_linker_product_is_found(
    tmp_path: Path,
    clean_environment: None,
    relative: str,
) -> None:
    package, build = _checkout(tmp_path)
    name = discovery.library_basenames()[0]
    product = _touch(build / relative / name)
    assert discovery.find_library(package) == product.resolve()


def test_runtime_bundle_is_never_auto_selected(tmp_path: Path, clean_environment: None) -> None:
    package, build = _checkout(tmp_path)
    name = discovery.library_basenames()[0]
    _touch(build / "runtime" / name)
    with pytest.raises(OSError, match="could not locate"):
        discovery.find_library(package)
    product = _touch(build / "bin" / name)
    assert discovery.find_library(package) == product.resolve()


def test_package_bundled_library_takes_precedence(tmp_path: Path, clean_environment: None) -> None:
    package, build = _checkout(tmp_path)
    name = discovery.library_basenames()[0]
    _touch(build / "bin" / name)
    bundled = _touch(package / name)
    assert discovery.find_library(package) == bundled


def test_exact_override_wins_and_must_exist(
    tmp_path: Path,
    clean_environment: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    package, build = _checkout(tmp_path)
    _touch(build / "bin" / discovery.library_basenames()[0])
    exact = _touch(tmp_path / "elsewhere" / "custom.so")
    monkeypatch.setenv("CABLEDYN_LIBRARY", f"  {exact}  ")
    assert discovery.find_library(package) == exact.resolve()
    monkeypatch.setenv("CABLEDYN_LIBRARY", str(tmp_path / "missing.so"))
    with pytest.raises(OSError, match="does not name an existing file"):
        discovery.find_library(package)


def test_several_configurations_require_an_explicit_choice(
    tmp_path: Path,
    clean_environment: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    package, build = _checkout(tmp_path)
    name = discovery.library_basenames()[0]
    _touch(build / "bin" / "Release" / name)
    debug = _touch(build / "Debug" / name)
    with pytest.raises(OSError, match="several build layouts"):
        discovery.find_library(package)
    monkeypatch.setenv("CABLEDYN_BUILD_CONFIG", "debug")
    assert discovery.find_library(package) == debug.resolve()


def test_explicit_configuration_accepts_a_single_configuration_build(
    tmp_path: Path,
    clean_environment: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    package, build = _checkout(tmp_path)
    product = _touch(build / "bin" / discovery.library_basenames()[0])
    monkeypatch.setenv("CABLEDYN_BUILD_CONFIG", "Release")
    assert discovery.find_library(package) == product.resolve()


def test_explicit_configuration_that_was_not_built_fails(
    tmp_path: Path,
    clean_environment: None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    package, build = _checkout(tmp_path)
    _touch(build / "Release" / discovery.library_basenames()[0])
    monkeypatch.setenv("CABLEDYN_BUILD_CONFIG", "Debug")
    with pytest.raises(OSError, match="could not locate"):
        discovery.find_library(package)


def test_unknown_configuration_is_rejected() -> None:
    with pytest.raises(OSError, match="must be one of"):
        discovery.selected_configuration("profile")
    assert discovery.selected_configuration(" relwithdebinfo ") == "RelWithDebInfo"
    assert discovery.selected_configuration("") is None


def test_two_library_names_in_one_directory_fail_closed(tmp_path: Path) -> None:
    build = tmp_path / "build"
    _touch(build / "bin" / "libcabledyn.dll")
    _touch(build / "bin" / "cabledyn.dll")
    with pytest.raises(OSError, match="several CableDyn shared libraries"):
        discovery.find_in_build_tree(build, ("libcabledyn.dll", "cabledyn.dll"), None)


def test_build_tree_is_the_checkout_build_directory(
    tmp_path: Path,
    clean_environment: None,
) -> None:
    package, _ = _checkout(tmp_path)
    outside = _touch(tmp_path / "build" / "bin" / discovery.library_basenames()[0])
    with pytest.raises(OSError, match="could not locate"):
        discovery.find_library(package)
    assert outside.is_file()


def test_dependency_directories_include_staged_runtime_sets(tmp_path: Path) -> None:
    build = tmp_path / "build"
    product = _touch(build / "bin" / "Release" / "libcabledyn.dll")
    (build / "runtime").mkdir()
    assert discovery.dependency_directories(product) == [
        product.parent,
        build / "bin",
        build / "runtime",
    ]
