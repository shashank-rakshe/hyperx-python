"""``python -m eval`` — run the demo gap report or print the leaderboard.

``demo`` runs the synthetic eval matrix (oracle vs a frontier-stub vs published-SOTA)
across multiple seeds and prints the leaderboard — the first, illustrative gap report.
``leaderboard`` prints the comparison tables from a stored SQLite leaderboard.
"""

from __future__ import annotations

import argparse
from collections.abc import Sequence

from .adapters import PerfectAdapter
from .fixtures import demo_tasks, published_frontier, published_sota
from .harness import run_matrix
from .leaderboard import Leaderboard


def cmd_demo(args: argparse.Namespace) -> int:
    leaderboard = Leaderboard(args.db)
    # Three real rows: our upper bound (measured), specialist SOTA + frontier (cited).
    # No external APIs, no simulation, no random seeds.
    adapters = [PerfectAdapter(), published_sota(), published_frontier()]
    run_matrix(adapters, demo_tasks(), seeds=tuple(range(args.seeds)), leaderboard=leaderboard)
    print(leaderboard.render_report())
    leaderboard.close()
    return 0


def cmd_leaderboard(args: argparse.Namespace) -> int:
    leaderboard = Leaderboard(args.db)
    print(leaderboard.render_report())
    leaderboard.close()
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m eval", description="Matrix evaluation harness."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    demo = sub.add_parser("demo", help="Run the synthetic gap-report demo + print the leaderboard.")
    demo.add_argument("--db", default=":memory:", help="SQLite path (default in-memory).")
    demo.add_argument("--seeds", type=int, default=3, help="Number of seeds.")
    demo.set_defaults(func=cmd_demo)

    board = sub.add_parser("leaderboard", help="Print the leaderboard from a stored DB.")
    board.add_argument("--db", default="eval/leaderboard.db", help="SQLite path.")
    board.set_defaults(func=cmd_leaderboard)

    ns = parser.parse_args(argv)
    return int(ns.func(ns))


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
