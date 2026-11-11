#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Prepare no-fit CableDyn static cases for Holcombe et al. (2025, 2026).

The 2025 article contains conflicting line lengths and attachment stations.
Holcombe's 2026 thesis resolves the geometry in Tables 4.3 and 4.10:
the hang-off-to-tether material length is 3.67 m, marker 7 is at 3.67 m, and
the intermediate attachments use the revised stations below.

Buoyancy modules and Qualisys markers are represented by short,
section-aligned intervals that preserve their separately reported dry mass and
buoyant force.  Holcombe et al. label the latter quantity ``net buoyancy``, but
the marker value of 14.1 mN equals the Archimedes force of the reported 14 mm
sphere.  The dry weight is therefore subtracted once when the submerged load
is assembled.  The resulting diameter is a hydrostatic volume-equivalent
diameter; the geometrical diameter is not used to alter the published load.
This distinction has no drag consequence in the still-water comparison.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import dataclass
from pathlib import Path


G = 9.80665
RHO = 1000.0
CABLE_DRY_MASS_PER_M = 0.0127
CABLE_DIAMETER = 0.0023
EA = 65.5e3
EI = 625.0e-9 * 1.0e3  # Table 5: 625e-9 kN m^2 = 6.25e-4 N m^2.

HANGOFF_PIXEL = (163.5, 185.0)
X_SLOPE = 0.004127954146246126
X_INTERCEPT = -0.5993595372337448
Z_SLOPE = -0.001650552065103596
Z_INTERCEPT = 0.01524733632317236

MODULE_START = 2.14
MODULE_END = 3.23
MODULE_CENTRES = [
    MODULE_START + i * (MODULE_END - MODULE_START) / 19.0 for i in range(20)
]
MARKER_ARCS = [1.01, 1.44, 1.87, 2.30, 2.73, 3.16]
MARKER_DRY_MASS = 1.1e-3
MARKER_BUOYANT_FORCE = 14.1e-3
MODULE_PROPERTY_SETS = {
    # Source diagnostic: Holcombe (2026), Table 4.9.  Its listed dry mass is
    # approximately three orders of magnitude below the peer-reviewed value.
    "thesis2026": {"dry_mass_kg": 7.47e-7, "buoyant_force_N": 20.3e-3},
    # Primary comparison: measured attachment values reported in the
    # peer-reviewed experiment, Holcombe et al. (2025), Table 6.
    "article2025": {"dry_mass_kg": 1.36e-3, "buoyant_force_N": 27.3e-3},
    # Source-consistency diagnostic: measured dry mass from the article and
    # sphere-volume buoyancy reported in the later thesis.
    "cross_source": {"dry_mass_kg": 1.36e-3, "buoyant_force_N": 20.3e-3},
}
MODULE_PROPERTY_SOURCES = {
    "thesis2026": "Holcombe (2026), Table 4.9",
    "article2025": "Holcombe et al. (2025), Table 6",
    "cross_source": (
        "Holcombe et al. (2025), Table 6 dry mass; "
        "Holcombe (2026), Table 4.9 buoyant force"
    ),
}


@dataclass(frozen=True)
class Attachment:
    name: str
    centre: float
    width: float
    dry_mass: float
    buoyant_force: float


def load_marker_endpoint(marker_csv: Path) -> tuple[float, float]:
    rows = list(csv.DictReader(marker_csv.open(encoding="utf-8")))
    row = next(row for row in rows if int(row["marker"]) == 7)
    return float(row["x_m"]), float(row["z_m"])


def hangoff_coordinate() -> tuple[float, float]:
    px, pz = HANGOFF_PIXEL
    return X_SLOPE * px + X_INTERCEPT, Z_SLOPE * pz + Z_INTERCEPT


def attachments(
    length: float, discrete: bool, module_properties: dict[str, float]
) -> list[Attachment]:
    module_dry_mass = module_properties["dry_mass_kg"]
    module_buoyant_force = module_properties["buoyant_force_N"]
    if not discrete:
        # Preserve the sum of the 20 measured module forces over the reported
        # 1.10 m buoyancy-section extent.  Marker forces remain discrete because
        # they are part of the measurement system rather than the cable design.
        result = [
            Attachment(
                "distributed_modules",
                0.5 * (MODULE_START + MODULE_END),
                MODULE_END - MODULE_START,
                20.0 * module_dry_mass,
                20.0 * module_buoyant_force,
            )
        ]
    else:
        result = [
            Attachment(
                f"module_{index + 1:02d}",
                centre,
                0.016,
                module_dry_mass,
                module_buoyant_force,
            )
            for index, centre in enumerate(MODULE_CENTRES)
        ]
    result.extend(
        Attachment(
            f"marker_{index + 1}",
            centre,
            0.014,
            MARKER_DRY_MASS,
            MARKER_BUOYANT_FORCE,
        )
        for index, centre in enumerate(MARKER_ARCS)
    )
    # Marker 7 is centred at the tether endpoint.  Preserve its complete
    # measured load on the inboard half interval.
    result.append(
        Attachment(
            "marker_7",
            length - 0.0035,
            0.007,
            MARKER_DRY_MASS,
            MARKER_BUOYANT_FORCE,
        )
    )
    return result


def section_partition(
    length: float,
    discrete: bool,
    target_element: float,
    module_properties: dict[str, float],
) -> list[dict[str, float | str | int]]:
    items = attachments(length, discrete, module_properties)
    boundaries = {0.0, length}
    clipped: list[tuple[Attachment, float, float]] = []
    for item in items:
        start = max(0.0, item.centre - 0.5 * item.width)
        end = min(length, item.centre + 0.5 * item.width)
        if end <= start:
            continue
        clipped.append((item, start, end))
        boundaries.update((start, end))
    ordered = sorted(boundaries)
    sections: list[dict[str, float | str | int]] = []
    for index, (start, end) in enumerate(zip(ordered[:-1], ordered[1:]), start=1):
        span = end - start
        midpoint = 0.5 * (start + end)
        active = [(item, a, b) for item, a, b in clipped if a <= midpoint <= b]
        added_mass_per_m = sum(item.dry_mass / (b - a) for item, a, b in active)
        added_buoyant_force_per_m = sum(
            item.buoyant_force / (b - a) for item, a, b in active
        )
        dry_mass_per_m = CABLE_DRY_MASS_PER_M + added_mass_per_m
        cable_area = math.pi * CABLE_DIAMETER**2 / 4.0
        displaced_area = cable_area + added_buoyant_force_per_m / (RHO * G)
        equiv_diameter = math.sqrt(4.0 * displaced_area / math.pi)
        key = (
            "bare" if not active else "a" + "_".join(item.name for item, _, _ in active)
        )
        sections.append(
            {
                "index": index,
                "name": key,
                "start_m": start,
                "end_m": end,
                "length_m": span,
                "segments": max(1, int(math.ceil(span / target_element))),
                "dry_mass_per_m": dry_mass_per_m,
                "equivalent_diameter_m": equiv_diameter,
                "net_weight_per_m": (dry_mass_per_m - RHO * displaced_area) * G,
                "active_attachments": ";".join(item.name for item, _, _ in active)
                or "none",
            }
        )
    return sections


def write_deck(
    path: Path,
    length: float,
    discrete: bool,
    target_element: float,
    marker_csv: Path,
    end_condition: str,
    module_properties: dict[str, float],
    solver_tolerance: float,
) -> list[dict[str, float | str | int]]:
    sections = section_partition(length, discrete, target_element, module_properties)
    x_a, z_a = hangoff_coordinate()
    x_b, z_b = load_marker_endpoint(marker_csv)
    unique_types: dict[str, dict[str, float | str | int]] = {}
    for section in sections:
        unique_types.setdefault(str(section["name"]), section)

    lines = [
        "--------------------- CableDyn Input File ------------------------------------",
        "Holcombe et al. (2025, 2026) 1:70 tethered-wave cable; static physical comparison",
        "--------------------- LINE TYPES ---------------------------------------------",
        "TypeName Diam MassDenInAir EA BA EI Cd_n Cd_t Ca_n Ca_t",
        "(-) (m) (kg/m) (N) (-) (N-m2) (-) (-) (-) (-)",
    ]
    for name, item in unique_types.items():
        lines.append(
            f"{name} {float(item['equivalent_diameter_m']):.10g} "
            f"{float(item['dry_mass_per_m']):.10g} {EA:.10g} 0.0 {EI:.10g} 0.0 0.0 0.0 0.0"
        )
    lines.extend(
        [
            "--------------------- POINTS -------------------------------------------------",
            "ID Type X Y Z",
            "(-) (-) (m) (m) (m)",
            f"1 Coupled {x_a:.9f} 0.0 {z_a:.9f}",
            f"2 Fixed {x_b:.9f} 0.0 {z_b:.9f}",
            "--------------------- LINES --------------------------------------------------",
            "ID NodeA NodeB Outputs",
            "(-) (-) (-) (-)",
            "1 1 2 -",
            "--------------------- SECTIONS -----------------------------------------------",
            "LineID LineType Length NumSegs",
            "(-) (-) (m) (-)",
        ]
    )
    for item in sections:
        lines.append(
            f"1 {item['name']} {float(item['length_m']):.12g} {int(item['segments'])}"
        )
    if end_condition == "rigid":
        lines.extend(
            [
                "--------------------- END CONNECTIONS ----------------------------------------",
                "LineID End Stiffness EzX EzY EzZ",
                "(-) (-) (N-m/rad) (-) (-) (-)",
                "1 A Rigid 0.0 0.0 -1.0",
            ]
        )
    elif end_condition != "pinned":
        raise ValueError(f"unsupported end condition: {end_condition}")
    lines.extend(
        [
            "--------------------- OPTIONS ------------------------------------------------",
            f"{G:.8g} g",
            f"{RHO:.8g} rhoW",
            "0.4 rhoInf",
            "False modified_newton",
            "0.01 dtM",
            "0.0 TMax",
            "False adaptive_mesh",
            "True tensile_safety",
            f"dynamic_solver {solver_tolerance:.8g} 1.0e-14 60 14",
            "none frictionMu",
            "none current",
            "none waves",
            "0 WaterKin",
            "--------------------- OUTPUTS -----------------------------------------------",
            '"FairTen1"',
            '"AnchTen1"',
            "--------------------- need this line ----------------------------------------",
        ]
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    with path.with_suffix(".sections.csv").open(
        "w", newline="", encoding="utf-8"
    ) as stream:
        writer = csv.DictWriter(stream, fieldnames=list(sections[0].keys()))
        writer.writeheader()
        writer.writerows(sections)
    return sections


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("marker_csv", type=Path)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--element-length", type=float, default=0.01)
    parser.add_argument(
        "--module-properties",
        choices=sorted(MODULE_PROPERTY_SETS),
        default="thesis2026",
    )
    parser.add_argument("--solver-tolerance", type=float, default=1.0e-7)
    args = parser.parse_args()
    if not math.isfinite(args.solver_tolerance) or args.solver_tolerance <= 0.0:
        parser.error("--solver-tolerance must be finite and positive")
    module_properties = MODULE_PROPERTY_SETS[args.module_properties]

    manifest = []
    for length in (3.67,):
        for representation in ("discrete", "distributed"):
            for end_condition in ("rigid", "pinned"):
                stem = f"holcombe_L{length:.2f}_{representation}_{end_condition}_h{args.element_length:.3f}".replace(
                    ".", "p"
                )
                deck = args.output_directory / f"{stem}.dat"
                sections = write_deck(
                    deck,
                    length,
                    representation == "discrete",
                    args.element_length,
                    args.marker_csv,
                    end_condition,
                    module_properties,
                    args.solver_tolerance,
                )
                manifest.append(
                    {
                        "case": stem,
                        "deck": str(deck),
                        "length_m": length,
                        "representation": representation,
                        "end_condition": end_condition,
                        "nominal_element_length_m": args.element_length,
                        "geometry_source": "Holcombe (2026), Tables 4.3 and 4.10",
                        "attachment_source": MODULE_PROPERTY_SOURCES[
                            args.module_properties
                        ],
                        "module_property_set": args.module_properties,
                        "module_dry_mass_kg": module_properties["dry_mass_kg"],
                        "module_buoyant_force_N": module_properties["buoyant_force_N"],
                        "solver_tolerance": args.solver_tolerance,
                        "attachment_hydrostatic_interpretation": "reported force is Archimedes buoyancy; dry weight subtracted separately",
                        "number_of_sections": len(sections),
                        "number_of_elements": sum(
                            int(item["segments"]) for item in sections
                        ),
                        "total_section_length_m": sum(
                            float(item["length_m"]) for item in sections
                        ),
                        "integrated_net_weight_N": sum(
                            float(item["net_weight_per_m"]) * float(item["length_m"])
                            for item in sections
                        ),
                    }
                )
    (args.output_directory / "case_manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    for item in manifest:
        print(
            f"{item['case']}: {item['number_of_elements']} elements, "
            f"net weight {item['integrated_net_weight_N']:.6f} N"
        )


if __name__ == "__main__":
    main()
