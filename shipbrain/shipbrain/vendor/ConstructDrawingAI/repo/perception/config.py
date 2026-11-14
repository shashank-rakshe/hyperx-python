"""Configuration for the perception training/eval pipelines (Hydra-style profiles).

Each model (the detector, the connectivity extractor) has two profiles, loaded from
``perception/conf/<kind>/<profile>.yaml``:

* ``local_debug`` — a tiny subset on one GPU, for proving the training loop on the
  local RTX 4090/3090 fast;
* ``h200_full`` — the full data, multi-GPU/FSDP, multi-seed run for VT ARC / H200.

Configs are plain YAML loaded with OmegaConf (the library Hydra is built on), so they
are equally consumable by a Hydra app and by our own thin CLI, and are trivially
overridable from the command line with dotlist overrides
(``train.epochs=5 data.limit_samples=10``). Keeping the two profiles in version control
— not buried in argparse defaults — is what makes a run reproducible months later.
"""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

from omegaconf import DictConfig, OmegaConf

#: Repo root (``perception/config.py`` -> repo). Used to resolve relative config paths.
REPO_ROOT = Path(__file__).resolve().parent.parent
#: Where the YAML profiles live.
CONF_DIR = Path(__file__).resolve().parent / "conf"

#: The model kinds that have config profiles.
VALID_KINDS = ("detector", "connectivity")


def config_path(kind: str, profile: str) -> Path:
    """Path to the YAML for ``(kind, profile)``."""
    return CONF_DIR / kind / f"{profile}.yaml"


def available_profiles(kind: str) -> list[str]:
    """The profile names available for ``kind`` (e.g. ``["h200_full", "local_debug"]``)."""
    directory = CONF_DIR / kind
    return sorted(p.stem for p in directory.glob("*.yaml")) if directory.is_dir() else []


def load_config(kind: str, profile: str, *, overrides: Sequence[str] | None = None) -> DictConfig:
    """Load ``perception/conf/<kind>/<profile>.yaml`` with optional dotlist overrides.

    Args:
        kind: ``"detector"`` or ``"connectivity"``.
        profile: ``"local_debug"`` or ``"h200_full"`` (see :func:`available_profiles`).
        overrides: OmegaConf dotlist overrides, e.g. ``["train.epochs=5", "data.limit_samples=10"]``.
    """
    if kind not in VALID_KINDS:
        raise ValueError(f"unknown config kind {kind!r}; expected one of {VALID_KINDS}")
    path = config_path(kind, profile)
    if not path.is_file():
        raise FileNotFoundError(
            f"no config for kind={kind!r} profile={profile!r} at {path} "
            f"(available profiles: {available_profiles(kind)})"
        )
    cfg = OmegaConf.load(path)
    if overrides:
        cfg = OmegaConf.merge(cfg, OmegaConf.from_dotlist(list(overrides)))
    assert isinstance(cfg, DictConfig)  # a profile is always a mapping
    return cfg


def resolve(path_str: str) -> Path:
    """Resolve a (possibly relative) config path against the repo root."""
    p = Path(path_str)
    return p if p.is_absolute() else (REPO_ROOT / p)
