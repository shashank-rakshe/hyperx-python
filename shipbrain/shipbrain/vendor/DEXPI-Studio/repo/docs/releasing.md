# Releasing DEXPI Studio

This page documents how to build, sign, and publish release artifacts for DEXPI Studio.

---

## Overview

Releases are produced by `scripts/release.py`, a cross-platform Python script that:

1. Cleans previous outputs
2. Runs the test suite (unless `--skip-tests` is passed)
3. Writes `LICENSE.txt`, `NOTICE.txt`, `CITATION.bib`, `README_RELEASE.txt`, and `THIRD_PARTY_NOTICES.md`
4. Packages the application with **PyInstaller**
5. Optionally **code-signs** the artifact (Windows / macOS / Linux)
6. Creates a `.zip` archive and a `SHA256` checksum file

Each OS must build its own artifact; cross-compilation is not supported.

---

## Prerequisites

```bash
pip install -e ".[dev]"   # installs pyinstaller and pip-licenses
```

---

## Building Locally

```bash
# Minimum: provide a version tag
python scripts/release.py --version 0.2.0

# Skip tests during iteration
python scripts/release.py --version 0.2.0 --skip-tests

# Override platform detection (rarely needed)
python scripts/release.py --version 0.2.0 --platform windows
```

Outputs land in `release/DEXPI-Studio-<version>-<platform>/`.

---

## Triggering a CI Release

The GitHub Actions workflow at `.github/workflows/release.yml` runs automatically
when a tag matching `v*` is pushed:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The matrix builds Windows, macOS, and Linux artifacts in parallel and uploads
them as workflow artifacts. To build without a tag, run the workflow by hand and
name the version:

```bash
gh workflow run release.yml --ref main -f version=0.2.0
```

Attach the artifacts of the tag's run to the GitHub release, so that each download
is built from the source the release names.

---

## Code Signing

Signing is **optional and best-effort**: the build succeeds even when signing
credentials are absent. Configure signing via **GitHub repository secrets**
(`Settings → Secrets and variables → Actions`).

### Windows — SignTool

| Secret | Description |
|---|---|
| `WINDOWS_CERT_FILE` | Path (or base64 content) of a PFX/P12 certificate |
| `WINDOWS_CERT_PASSWORD` | Password protecting the PFX file |

Requirements:
- A code-signing certificate issued by a trusted CA (e.g. DigiCert, Sectigo)
- `signtool.exe` available — it is pre-installed on `windows-latest` runners via the Windows SDK

### macOS — codesign + Notarisation

| Secret | Description |
|---|---|
| `MACOS_SIGNING_IDENTITY` | Developer ID string, e.g. `Developer ID Application: ACME (TEAMID)` |
| `MACOS_NOTARIZATION_APPLE_ID` | Apple ID used for notarisation |
| `MACOS_NOTARIZATION_TEAM_ID` | Apple Developer Team ID |
| `MACOS_NOTARIZATION_PASSWORD` | App-specific password for notarisation |

Requirements:
- An Apple Developer account with a **Developer ID Application** certificate
- The certificate must be imported into the runner's keychain (add a CI step to
  import it from a base64-encoded secret before the build step)
- Notarisation requires all four variables above; if any is missing only
  `codesign` is run and stapling is skipped

### Linux — GPG Detached Signature

| Secret | Description |
|---|---|
| `GPG_KEY_ID` | GPG key fingerprint or email address |

Requirements:
- A GPG key imported into the runner: add a step to import your key from a
  secret before the build step
- `gpg` is pre-installed on `ubuntu-latest` runners
- The script creates `.sig` files alongside each binary in the release folder

---

## Release Checklist

Before tagging a release:

- [ ] Update the version in `pyproject.toml`
- [ ] Update `CHANGELOG.md`
- [ ] Run `pytest -q` — all tests pass
- [ ] Run `ruff check . && ruff format .` — no lint errors
- [ ] Verify signing credentials are configured in repository secrets
- [ ] Push the release's source to the public repository: the AGPL requires it to be available to
      anyone who receives the binary
- [ ] Build locally on at least one platform with `scripts/release.py --version <version>`

---

## Artifact Structure

```
release/
  DEXPI-Studio-<version>-<platform>/
    DEXPI Studio/          # PyInstaller bundle (folder mode)
    LICENSE.txt
    NOTICE.txt
    CITATION.bib
    README_RELEASE.txt
    THIRD_PARTY_NOTICES.md
    docs/
    examples/
  DEXPI-Studio-<version>-<platform>.zip
  DEXPI-Studio-<version>-<platform>.sha256
```

---

## Troubleshooting

| Symptom | Resolution |
|---|---|
| `PyInstaller is not installed` | Run `pip install pyinstaller` or `pip install -e ".[dev]"` |
| `signtool` not found on Windows | Install the Windows SDK or use the pre-installed version on CI runners |
| Notarisation fails with `invalid credentials` | Regenerate the app-specific password in Apple ID account settings |
| GPG signing fails with `secret key not available` | Import your private key into the runner before the build step |
