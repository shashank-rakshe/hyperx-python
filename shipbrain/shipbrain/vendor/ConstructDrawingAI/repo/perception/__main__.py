"""``python -m perception`` — train and evaluate the wedge perception models.

Subcommands (each takes ``--profile {local_debug,h200_full}`` and optional ``-o k=v``
OmegaConf overrides)::

    python -m perception export        --profile local_debug
    python -m perception train-detector --profile local_debug
    python -m perception eval-detector  --profile local_debug [--weights P] [--real-root D]
    python -m perception eval-detector  --profile local_debug --oracle   # wiring check, no GPU

``eval-detector`` runs BOTH scoreboards (synthetic-validation smoke test + the
real-drawing slot, which reports UNVALIDATED until real data exists) and prints the
framed report. ``--oracle`` scores the ground-truth oracle instead of a trained model —
a fast way to verify the harness wiring without training (a perfect prediction scores 1.0
on the synthetic board).
"""

from __future__ import annotations

import argparse
import logging
from collections.abc import Sequence

from .config import load_config, resolve


def _add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--profile", default="local_debug", help="config profile name")
    parser.add_argument(
        "-o",
        "--override",
        action="append",
        default=[],
        help="OmegaConf dotlist override, e.g. -o train.epochs=5",
    )


def cmd_export(args: argparse.Namespace) -> int:
    from .dataset import export_from_config

    cfg = load_config("detector", args.profile, overrides=args.override)
    result = export_from_config(cfg)
    print(
        f"exported YOLO dataset -> {result.export_root}\n"
        f"  {result.n_train_images} train / {result.n_val_images} val tiles, "
        f"{result.n_boxes} boxes; {result.n_train_samples}/{result.n_val_samples} samples (train/val)"
    )
    return 0


def cmd_train_detector(args: argparse.Namespace) -> int:
    from .detector import train_detector

    cfg = load_config("detector", args.profile, overrides=args.override)
    outcome = train_detector(cfg, export=True)
    print(
        f"trained detector -> {outcome.weights}\n"
        f"  ultralytics tile-level val: mAP50={outcome.map50:.3f} mAP50-95={outcome.map50_95:.3f} "
        f"(internal smoke signal; the reported synthetic number comes from eval-detector)"
    )
    return 0


def cmd_eval_detector(args: argparse.Namespace) -> int:
    from eval.adapters import PerfectAdapter

    from .adapter import DetectorAdapter
    from .scoreboard import run_detector_scoreboards

    cfg = load_config("detector", args.profile, overrides=args.override)
    if args.oracle:
        adapter: object = PerfectAdapter()
    else:
        adapter = DetectorAdapter.from_config(cfg, weights=args.weights)

    # A foreign real set (e.g. DELP's UK service keys) needs its labels mapped into our
    # class space before scoring; --real-crosswalk selects that transform (see crosswalk.py).
    real_gt_transform = None
    if args.real_crosswalk == "delp":
        from .crosswalk import remap_labels

        real_gt_transform = remap_labels

    split_json = resolve(cfg.data.export_root) / "split.json"
    report = run_detector_scoreboards(
        adapter,  # type: ignore[arg-type]
        synthetic_root=resolve(cfg.data.synthetic_root),
        split_json=split_json if split_json.is_file() else None,
        real_root=args.real_root,
        real_gt_transform=real_gt_transform,
        limit=args.limit,
        db_path=(args.db or ":memory:"),
    )
    print(report)
    return 0


def cmd_train_connectivity(args: argparse.Namespace) -> int:
    from .connectivity import train_connectivity

    cfg = load_config("connectivity", args.profile, overrides=args.override)
    result = train_connectivity(cfg)
    print(
        f"trained connectivity -> {result.weights}\n"
        f"  intrinsic (given GT nodes) val: {result.metrics}\n"
        f"  (the reported end-to-end graph AP comes from eval-connectivity)"
    )
    return 0


def cmd_eval_connectivity(args: argparse.Namespace) -> int:
    from eval.adapters import PerfectAdapter

    from .adapter import DetectorAdapter
    from .connectivity import ConnectivityAdapter
    from .scoreboard import run_connectivity_scoreboards

    cfg = load_config("connectivity", args.profile, overrides=args.override)
    split_json = None
    if args.oracle:
        adapter: object = PerfectAdapter()
    else:
        det_cfg = load_config("detector", str(cfg.detector.profile))
        detector_adapter = DetectorAdapter.from_config(det_cfg, weights=args.detector_weights)
        adapter = ConnectivityAdapter.from_config(
            cfg, detector_adapter=detector_adapter, weights=args.weights
        )
        split = resolve(det_cfg.data.export_root) / "split.json"
        split_json = split if split.is_file() else None

    report = run_connectivity_scoreboards(
        adapter,  # type: ignore[arg-type]
        synthetic_root=resolve(cfg.data.synthetic_root),
        split_json=split_json,
        real_root=args.real_root,
        limit=args.limit,
        db_path=(args.db or ":memory:"),
    )
    print(report)
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    parser = argparse.ArgumentParser(prog="python -m perception", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_export = sub.add_parser("export", help="Export the synthetic data to a YOLO dataset.")
    _add_common(p_export)
    p_export.set_defaults(func=cmd_export)

    p_train = sub.add_parser("train-detector", help="Train Model 1 (symbol detector).")
    _add_common(p_train)
    p_train.set_defaults(func=cmd_train_detector)

    p_eval = sub.add_parser("eval-detector", help="Run BOTH scoreboards for Model 1.")
    _add_common(p_eval)
    p_eval.add_argument(
        "--weights", default=None, help="detector weights (default: latest best.pt)."
    )
    p_eval.add_argument(
        "--real-root", default=None, help="dir of real annotated plans (else UNVALIDATED)."
    )
    p_eval.add_argument(
        "--real-crosswalk",
        choices=["delp"],
        default=None,
        help="map a foreign real taxonomy into our class space before scoring (e.g. delp).",
    )
    p_eval.add_argument(
        "--limit", type=int, default=None, help="cap held-out synthetic samples (fast demo)."
    )
    p_eval.add_argument(
        "--oracle", action="store_true", help="score the GT oracle (wiring check, no GPU)."
    )
    p_eval.add_argument("--db", default=None, help="persist results to this SQLite leaderboard.")
    p_eval.set_defaults(func=cmd_eval_detector)

    p_ctrain = sub.add_parser("train-connectivity", help="Train Model 2 (connectivity edges).")
    _add_common(p_ctrain)
    p_ctrain.set_defaults(func=cmd_train_connectivity)

    p_ceval = sub.add_parser("eval-connectivity", help="Run BOTH scoreboards for Model 2.")
    _add_common(p_ceval)
    p_ceval.add_argument("--weights", default=None, help="connectivity weights (default: latest).")
    p_ceval.add_argument(
        "--detector-weights", default=None, help="detector weights for nodes (default: latest)."
    )
    p_ceval.add_argument(
        "--real-root", default=None, help="dir of real annotated plans (else UNVALIDATED)."
    )
    p_ceval.add_argument("--limit", type=int, default=None, help="cap held-out synthetic samples.")
    p_ceval.add_argument(
        "--oracle", action="store_true", help="score the GT oracle (wiring check, no GPU)."
    )
    p_ceval.add_argument("--db", default=None, help="persist results to this SQLite leaderboard.")
    p_ceval.set_defaults(func=cmd_eval_connectivity)

    ns = parser.parse_args(argv)
    return int(ns.func(ns))


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
