#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Plot the tension range graph of one line of a CableDyn run.

Reads ``<out_root>.Line<L>.range.out`` (written for a line with the LINES ``Outputs`` flag
``r``) and plots the minimum, maximum, and mean tension along the arc length from End A.

usage: python plot_range_envelope.py <out_root> [--line L] [--save figure.png]
"""

from __future__ import annotations

import argparse

import matplotlib.pyplot as plt
from cabledyn import read_range_graphs


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("out_root", help="output root given to the solver")
    parser.add_argument("--line", type=int, default=1, help="deck line id (default 1)")
    parser.add_argument("--save", help="write the figure to this file instead of showing it")
    args = parser.parse_args()

    tension = read_range_graphs(f"{args.out_root}.Line{args.line}.range.out")["tension"]
    s = tension.location
    t0, t1 = tension.time_window
    peak = tension.maximum.argmax()
    print(
        f"line {args.line}: {t0:g} s to {t1:g} s, "
        f"peak tension {tension.maximum[peak] / 1e3:.1f} kN at s = {s[peak]:.1f} m"
    )

    fig, ax = plt.subplots(figsize=(7.0, 4.0))
    ax.fill_between(
        s,
        tension.minimum / 1e3,
        tension.maximum / 1e3,
        color="tab:blue",
        alpha=0.2,
        label="min to max",
    )
    ax.plot(s, tension.maximum / 1e3, color="tab:blue", lw=1.0)
    ax.plot(s, tension.minimum / 1e3, color="tab:blue", lw=1.0)
    ax.plot(s, tension.mean / 1e3, color="tab:blue", lw=2.0, label="mean")
    ax.set_xlabel("Arc length from End A (m)")
    ax.set_ylabel("Effective tension (kN)")
    ax.set_title(f"Line {args.line} tension range graph, t = {t0:g} to {t1:g} s")
    ax.grid(alpha=0.3)
    ax.legend()
    fig.tight_layout()
    if args.save:
        fig.savefig(args.save, dpi=150)
    else:
        plt.show()


if __name__ == "__main__":
    main()
