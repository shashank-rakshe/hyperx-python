"""Automated release/packaging helper for DEXPI Studio.

This script is designed to run natively on each target OS (Windows/macOS/Linux).
It does not cross-compile.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

APP_NAME = "DEXPI Studio"
PROJECT_NAME = "DEXPI-Studio"

SOURCE_URL = "https://github.com/process-intelligence-research/DEXPI-Studio"

CITATION_BIB = """@InProceedings{pyDEXPI,
  author    = {Goldstein, Dominik P. and Schulze Balhorn, Lukas and Alimin, Achmad Anggawirya and Schweidtmann, Artur M.},
  booktitle = {Proceedings of the 35th European Symposium on Computer Aided Process Engineering (ESCAPE35)},
  title     = {pyDEXPI: A Python framework for piping and instrumentation diagrams using the DEXPI information model},
  year      = {2025},
  address   = {Ghent, Belgium},
  month     = {July},
  doi       = {https://doi.org/10.69997/sct.139043},
}
"""


@dataclass(frozen=True)
class ReleaseContext:
    version: str
    os_name: str
    platform_tag: str
    project_root: Path
    build_dir: Path
    dist_dir: Path
    release_root: Path
    release_dir: Path
    zip_path: Path
    sha256_path: Path


def log(message: str) -> None:
    """Print a release progress message."""
    print(f"[release] {message}")


def run_command(command: list[str], *, cwd: Path, required: bool = True) -> int:
    """Run a subprocess command with friendly logging."""
    pretty = " ".join(command)
    log(f"Running: {pretty}")
    result = subprocess.run(command, cwd=str(cwd), check=False)
    if required and result.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {result.returncode}: {pretty}")
    return result.returncode


def normalize_version(raw_version: str) -> str:
    """Normalize release version (accepts optional leading 'v')."""
    cleaned = raw_version.strip()
    if cleaned.lower().startswith("v"):
        cleaned = cleaned[1:]
    if not cleaned:
        raise ValueError("Version must not be empty.")
    return cleaned


def detect_platform(platform_arg: str | None) -> tuple[str, str]:
    """Return (os_name, platform_tag)."""
    probe = (platform_arg or sys.platform).lower()
    if probe.startswith("win"):
        os_name = "windows"
    elif probe.startswith("darwin") or probe.startswith("mac"):
        os_name = "macos"
    elif probe.startswith("linux"):
        os_name = "linux"
    else:
        raise ValueError(f"Unsupported platform: {probe}")

    arch_raw = platform.machine().lower()
    arch_map = {
        "x86_64": "x64",
        "amd64": "x64",
        "aarch64": "arm64",
        "arm64": "arm64",
        "i386": "x86",
        "i686": "x86",
        "x86": "x86",
    }
    arch = arch_map.get(arch_raw, arch_raw.replace(" ", "-"))
    return os_name, f"{os_name}-{arch}"


def make_context(
    version: str, os_name: str, platform_tag: str, project_root: Path
) -> ReleaseContext:
    """Create release path context."""
    release_root = project_root / "release"
    release_dir = release_root / f"{PROJECT_NAME}-{version}-{platform_tag}"
    zip_path = release_root / f"{release_dir.name}.zip"
    sha256_path = release_root / f"{release_dir.name}.sha256"
    return ReleaseContext(
        version=version,
        os_name=os_name,
        platform_tag=platform_tag,
        project_root=project_root,
        build_dir=project_root / "build",
        dist_dir=project_root / "dist",
        release_root=release_root,
        release_dir=release_dir,
        zip_path=zip_path,
        sha256_path=sha256_path,
    )


def clean_previous_outputs(ctx: ReleaseContext) -> None:
    """Remove previous build/release artifacts for deterministic reruns."""
    log("Cleaning previous build and release outputs")
    for path in [ctx.build_dir, ctx.dist_dir, ctx.release_dir]:
        if path.exists():
            shutil.rmtree(path)

    spec_path = ctx.project_root / f"{APP_NAME}.spec"
    if spec_path.exists():
        spec_path.unlink()

    if ctx.zip_path.exists():
        ctx.zip_path.unlink()
    if ctx.sha256_path.exists():
        ctx.sha256_path.unlink()


def maybe_run_tests(project_root: Path) -> None:
    """Run tests if pytest is available."""
    if importlib.util.find_spec("pytest") is None:
        log("pytest not available; skipping tests")
        return
    log("Running test suite")
    run_command([sys.executable, "-m", "pytest", "-q"], cwd=project_root, required=True)


def write_license(ctx: ReleaseContext) -> None:
    """Copy the licence and the third-party attribution into the release folder."""
    shutil.copy2(ctx.project_root / "LICENSE", ctx.release_dir / "LICENSE.txt")
    shutil.copy2(ctx.project_root / "NOTICE", ctx.release_dir / "NOTICE.txt")


def write_citation(ctx: ReleaseContext) -> None:
    """Generate CITATION.bib into the release folder."""
    (ctx.release_dir / "CITATION.bib").write_text(CITATION_BIB, encoding="utf-8")


def write_release_readme(ctx: ReleaseContext) -> None:
    """Generate README_RELEASE.txt into the release folder."""
    build_ts = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S UTC")
    start = {
        "windows": (
            f'Start "{APP_NAME}\\{APP_NAME}.exe". The build is not code-signed yet: if Windows\n'
            'warns, choose "More info", then "Run anyway".\n'
        ),
        "macos": (
            f'Start "{APP_NAME}.app"; you may move it to Applications first. The build is not\n'
            'code-signed yet: the first time, right-click it and choose "Open". If macOS still\n'
            "refuses, allow it under System Settings > Privacy & Security.\n"
        ),
        "linux": f'Start "{APP_NAME}/{APP_NAME}".\n',
    }[ctx.os_name]
    text = (
        f"{APP_NAME} {ctx.version}\n"
        f"Platform: {ctx.platform_tag}\n"
        f"Build date: {build_ts}\n\n"
        f"{start}\n"
        "Try it with the DEXPI reference P&ID in data/reference_pid.xml.\n\n"
        "DEXPI Studio is a free academic tool from Process Intelligence Research (TU Delft).\n"
        "Local-first: the core application runs locally by default.\n"
        "Optional ChatP&ID features may send user-selected context to the configured external API provider.\n\n"
        "Please cite pyDEXPI if this software supports academic work.\n"
        "See CITATION.bib for the BibTeX entry.\n\n"
        "Contact: a.schweidtmann@tudelft.nl\n\n"
        "This program comes with ABSOLUTELY NO WARRANTY. It is free software under the GNU Affero\n"
        "General Public License v3 (see LICENSE.txt); third-party material is in NOTICE.txt.\n"
        f"Source code: {SOURCE_URL}\n"
    )
    (ctx.release_dir / "README_RELEASE.txt").write_text(text, encoding="utf-8")


def generate_third_party_notices(ctx: ReleaseContext) -> None:
    """Generate THIRD_PARTY_NOTICES.md using pip-licenses.

    pip-licenses must be installed (it is listed under [project.optional-dependencies] dev
    in pyproject.toml).  Run ``pip install -e ".[dev]"`` if it is missing.
    """
    output_path = ctx.release_dir / "THIRD_PARTY_NOTICES.md"

    # Prefer the console-script entry point, fall back to module invocation.
    tool_path = shutil.which("pip-licenses")
    if tool_path:
        base_cmd = [tool_path]
    else:
        # Check whether the module is importable before trying to use it.
        try:
            import importlib.util

            if importlib.util.find_spec("piplicenses") is None:
                raise ImportError
        except ImportError:
            log(
                "WARNING: pip-licenses is not installed. "
                'Install dev dependencies with: pip install -e ".[dev]"\n'
                "THIRD_PARTY_NOTICES.md will be a placeholder."
            )
            output_path.write_text(
                "# Third-party notices\n\n"
                "Automatic notice generation was skipped because `pip-licenses` is not "
                "installed in this build environment.\n"
                'Install dev dependencies with: `pip install -e ".[dev]"`\n',
                encoding="utf-8",
            )
            return
        base_cmd = [sys.executable, "-m", "piplicenses"]

    command = base_cmd + [
        "--format=markdown",
        "--with-urls",
        "--with-license-file",
        "--with-notice-file",
        "--no-license-path",
    ]
    log(f"Generating THIRD_PARTY_NOTICES.md via: {' '.join(command)}")
    try:
        completed = subprocess.run(
            command,
            cwd=str(ctx.project_root),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        log(f"Could not execute pip-licenses: {exc}")
        completed = None

    if completed is not None and completed.returncode == 0 and completed.stdout.strip():
        output_path.write_text(completed.stdout, encoding="utf-8")
        return

    exit_code = completed.returncode if completed is not None else "N/A"
    log(f"WARNING: pip-licenses exited with code {exit_code}. Writing placeholder.")
    output_path.write_text(
        "# Third-party notices\n\n"
        f"pip-licenses exited with code {exit_code}.\n"
        'Re-run after installing dev dependencies: `pip install -e ".[dev]"`\n',
        encoding="utf-8",
    )


def copy_release_docs_and_examples(ctx: ReleaseContext) -> None:
    """Copy example data into release folder.

    Developer docs (docs/) and the placeholder examples/README.md are intentionally
    omitted — they are source-tree artefacts not relevant to exe users.
    """
    data_src = ctx.project_root / "data" / "reference_pid.xml"
    if data_src.exists():
        data_dst_dir = ctx.release_dir / "data"
        data_dst_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(data_src, data_dst_dir / "reference_pid.xml")


def get_icon_path(ctx: ReleaseContext) -> Path | None:
    """Return the pre-built icon file for this OS from the resources folder.

    Icons are committed to source and require no runtime conversion:
      Windows / macOS → app.ico
      Linux           → app_icon.png
    """
    resources = ctx.project_root / "src" / "dexpi_studio" / "gui" / "resources"
    if ctx.os_name == "linux":
        candidate = resources / "app_icon.png"
    else:
        candidate = resources / "app.ico"

    if candidate.exists():
        log(f"Using icon: {candidate.name}")
        return candidate

    log(f"Icon file not found at {candidate} – PyInstaller will use its default icon")
    return None


def build_with_pyinstaller(ctx: ReleaseContext) -> None:
    """Build app bundle with PyInstaller."""
    if importlib.util.find_spec("PyInstaller") is None:
        raise RuntimeError(
            "PyInstaller is not installed. Install it first (e.g. pip install pyinstaller)."
        )

    add_data_sep = ";" if ctx.os_name == "windows" else ":"
    entry_script = ctx.project_root / "src" / "dexpi_studio" / "app.py"
    if not entry_script.exists():
        raise FileNotFoundError(f"Entry point not found: {entry_script}")

    data_entries: list[tuple[Path, str]] = []

    resources_main = ctx.project_root / "src" / "dexpi_studio" / "resources"
    if resources_main.exists():
        data_entries.append((resources_main, "dexpi_studio/resources"))

    resources_gui = ctx.project_root / "src" / "dexpi_studio" / "gui" / "resources"
    if resources_gui.exists():
        data_entries.append((resources_gui, "dexpi_studio/gui/resources"))

    reference_file = ctx.project_root / "data" / "reference_pid.xml"
    if reference_file.exists():
        data_entries.append((reference_file, "data"))

    command = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--noconfirm",
        "--windowed",
        "--clean",
        "--name",
        APP_NAME,
        # Collect all pyDEXPI data files (symbol libraries, shape definitions, etc.)
        # so that SVG rendering works correctly in the bundled executable.
        "--collect-data",
        "pydexpi",
        # DrawDiagram is imported via a local `from` import inside _import_draw_diagram,
        # but PyInstaller's static analysis still needs an explicit hint because the
        # function is only called at runtime. Belt-and-suspenders alongside the direct
        # import in pydexpi_adapter.py.
        "--hidden-import",
        "pydexpi.exports.svg_export",
    ]

    icon_path = get_icon_path(ctx)
    if icon_path is not None:
        command.extend(["--icon", str(icon_path)])

    for source, destination in data_entries:
        command.extend(["--add-data", f"{source}{add_data_sep}{destination}"])

    command.append(str(entry_script))
    run_command(command, cwd=ctx.project_root, required=True)


def copy_built_app_to_release(ctx: ReleaseContext) -> None:
    """Copy PyInstaller output into release folder.

    On macOS, ``--windowed`` writes both the ``.app`` bundle and the plain folder it is
    made from; the bundle is what a user starts from Finder, so it is taken first.
    """
    candidates = [
        ctx.dist_dir / f"{APP_NAME}.app",
        ctx.dist_dir / APP_NAME,
        ctx.dist_dir / f"{APP_NAME}.exe",
    ]
    if ctx.os_name != "macos":
        candidates = candidates[1:]

    built_path: Path | None = None
    for candidate in candidates:
        if candidate.exists():
            built_path = candidate
            break

    if built_path is None:
        raise FileNotFoundError(
            f"Could not find PyInstaller output in {ctx.dist_dir}. "
            "Expected one of: " + ", ".join(str(p.name) for p in candidates)
        )

    destination = ctx.release_dir / built_path.name
    if built_path.is_dir():
        # Keep symlinks: the Qt frameworks in a macOS bundle are made of them, and
        # copying their targets breaks the bundle's code signature.
        shutil.copytree(built_path, destination, symlinks=True, dirs_exist_ok=True)
    else:
        shutil.copy2(built_path, destination)


def sign_artifacts(ctx: ReleaseContext) -> None:
    """Optionally code-sign the built application artifact.

    Signing is best-effort: if the required environment variables are absent
    the step is skipped with a warning.  Configure the variables in CI via
    repository secrets (see docs/releasing.md).

    Windows
    -------
    Required env vars:
        WINDOWS_CERT_FILE     – path to a PFX/P12 certificate file
        WINDOWS_CERT_PASSWORD – password protecting the PFX file

    macOS
    -----
    Required env vars:
        MACOS_SIGNING_IDENTITY – Developer-ID string, e.g.
                                 "Developer ID Application: ACME Corp (TEAMID)"

    Optional notarisation env vars (all three required together):
        MACOS_NOTARIZATION_APPLE_ID
        MACOS_NOTARIZATION_TEAM_ID
        MACOS_NOTARIZATION_PASSWORD

    Linux
    -----
    Required env var:
        GPG_KEY_ID – key fingerprint or email used for detached signing
    """
    import os

    log("Code signing: checking environment")

    if ctx.os_name == "windows":
        cert_file = os.environ.get("WINDOWS_CERT_FILE")
        cert_pass = os.environ.get("WINDOWS_CERT_PASSWORD")
        if not cert_file or not cert_pass:
            log("  Windows signing skipped – WINDOWS_CERT_FILE / WINDOWS_CERT_PASSWORD not set")
            return

        exe_candidates = list(ctx.release_dir.glob("**/*.exe"))
        if not exe_candidates:
            log("  Windows signing skipped – no .exe found in release folder")
            return

        signtool = shutil.which("signtool") or "signtool"
        for exe in exe_candidates:
            log(f"  Signing {exe.name}")
            run_command(
                [
                    signtool,
                    "sign",
                    "/f",
                    cert_file,
                    "/p",
                    cert_pass,
                    "/tr",
                    "http://timestamp.digicert.com",
                    "/td",
                    "sha256",
                    "/fd",
                    "sha256",
                    str(exe),
                ],
                cwd=ctx.project_root,
                required=True,
            )

    elif ctx.os_name == "macos":
        identity = os.environ.get("MACOS_SIGNING_IDENTITY")
        if not identity:
            log("  macOS signing skipped – MACOS_SIGNING_IDENTITY not set")
            return

        app_candidates = list(ctx.release_dir.glob("**/*.app"))
        if not app_candidates:
            log("  macOS signing skipped – no .app bundle found in release folder")
            return

        for app in app_candidates:
            log(f"  Signing {app.name}")
            run_command(
                [
                    "codesign",
                    "--deep",
                    "--force",
                    "--verify",
                    "--timestamp",
                    "--options",
                    "runtime",
                    "--sign",
                    identity,
                    str(app),
                ],
                cwd=ctx.project_root,
                required=True,
            )

        # Optional notarisation
        apple_id = os.environ.get("MACOS_NOTARIZATION_APPLE_ID")
        team_id = os.environ.get("MACOS_NOTARIZATION_TEAM_ID")
        notary_pass = os.environ.get("MACOS_NOTARIZATION_PASSWORD")
        if apple_id and team_id and notary_pass:
            log("  Notarising with Apple notary tool")
            for app in app_candidates:
                run_command(
                    [
                        "xcrun",
                        "notarytool",
                        "submit",
                        str(app),
                        "--apple-id",
                        apple_id,
                        "--team-id",
                        team_id,
                        "--password",
                        notary_pass,
                        "--wait",
                    ],
                    cwd=ctx.project_root,
                    required=True,
                )
                run_command(
                    ["xcrun", "stapler", "staple", str(app)],
                    cwd=ctx.project_root,
                    required=True,
                )
        else:
            log("  Notarisation skipped – MACOS_NOTARIZATION_* vars not set")

    elif ctx.os_name == "linux":
        gpg_key = os.environ.get("GPG_KEY_ID")
        if not gpg_key:
            log("  Linux signing skipped – GPG_KEY_ID not set")
            return

        gpg = shutil.which("gpg") or "gpg"
        # Sign the archive itself (created after this step, so sign the release dir instead)
        # We create a detached signature of each binary in the release dir.
        bin_candidates = [
            p
            for p in ctx.release_dir.rglob("*")
            if p.is_file() and not p.suffix and p.stat().st_size > 0
        ]
        if not bin_candidates:
            log("  Linux signing: no ELF binaries found; signing skipped")
            return

        for binary in bin_candidates:
            sig_path = binary.with_suffix(".sig")
            log(f"  GPG-signing {binary.name}")
            run_command(
                [
                    gpg,
                    "--batch",
                    "--yes",
                    "--detach-sign",
                    "--armor",
                    "-u",
                    gpg_key,
                    "--output",
                    str(sig_path),
                    str(binary),
                ],
                cwd=ctx.project_root,
                required=True,
            )


def create_archive_and_checksum(ctx: ReleaseContext) -> None:
    """Create ZIP archive and SHA256 checksum file."""
    ctx.release_root.mkdir(parents=True, exist_ok=True)

    archive_base = ctx.release_root / ctx.release_dir.name
    if ctx.zip_path.exists():
        ctx.zip_path.unlink()

    log(f"Creating archive: {ctx.zip_path.name}")
    if ctx.os_name == "macos":
        # ditto keeps the bundle's symlinks, permissions and extended attributes, which
        # Python's zipfile does not; without them macOS reports the app as damaged.
        run_command(
            [
                "ditto",
                "-c",
                "-k",
                "--sequesterRsrc",
                "--keepParent",
                str(ctx.release_dir),
                str(ctx.zip_path),
            ],
            cwd=ctx.project_root,
        )
    else:
        shutil.make_archive(
            base_name=str(archive_base),
            format="zip",
            root_dir=str(ctx.release_root),
            base_dir=ctx.release_dir.name,
        )

    digest = hashlib.sha256(ctx.zip_path.read_bytes()).hexdigest()
    # "\n" on every platform: written in text mode on Windows, the line ended in "\r\n",
    # and `shasum -c` / `sha256sum -c` then looked for a file named "...zip\r".
    ctx.sha256_path.write_text(f"{digest}  {ctx.zip_path.name}\n", encoding="utf-8", newline="\n")


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(description="Build release artifacts for DEXPI Studio")
    parser.add_argument("--version", required=True, help="Release version, e.g. 0.1.0 or v0.1.0")
    parser.add_argument(
        "--platform",
        default=None,
        help="Target platform override: windows | macos | linux (optional)",
    )
    parser.add_argument(
        "--skip-tests",
        action="store_true",
        help="Skip pytest execution before packaging",
    )
    parser.add_argument(
        "--sign",
        action="store_true",
        default=False,
        help="Enable code signing (requires platform-specific env vars; see docs/releasing.md)",
    )
    return parser.parse_args()


def main() -> None:
    """Run release workflow."""
    args = parse_args()

    project_root = Path(__file__).resolve().parents[1]
    version = normalize_version(args.version)
    os_name, platform_tag = detect_platform(args.platform)
    ctx = make_context(version, os_name, platform_tag, project_root)

    log(f"Preparing release {version} for {platform_tag}")

    ctx.release_root.mkdir(parents=True, exist_ok=True)
    ctx.release_dir.mkdir(parents=True, exist_ok=True)

    clean_previous_outputs(ctx)
    ctx.release_dir.mkdir(parents=True, exist_ok=True)

    if not args.skip_tests:
        maybe_run_tests(project_root)

    write_license(ctx)
    write_citation(ctx)
    write_release_readme(ctx)
    generate_third_party_notices(ctx)

    copy_release_docs_and_examples(ctx)

    build_with_pyinstaller(ctx)
    copy_built_app_to_release(ctx)

    if args.sign:
        sign_artifacts(ctx)
    else:
        log("Code signing skipped (pass --sign to enable)")

    create_archive_and_checksum(ctx)

    log(f"Release folder: {ctx.release_dir}")
    log(f"Archive: {ctx.zip_path}")
    log(f"Checksum: {ctx.sha256_path}")


if __name__ == "__main__":
    main()
