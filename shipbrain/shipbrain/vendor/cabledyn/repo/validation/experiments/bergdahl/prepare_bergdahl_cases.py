#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Prepare the Bergdahl et al. (2016) physical mooring-chain validation.

The 30 published cases prescribe a circular fairlead motion.  A smooth three-cycle
start is added only to remove the numerical start-up impulse; response statistics
are evaluated after full-amplitude periodic motion has been established.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path


G = 9.80665
RHO_WATER = 1000.0
WATER_DEPTH = 3.0
LENGTH = 33.0
HORIZONTAL_SPAN = 32.554
VERTICAL_SPAN = 3.3
FAIRLEAD_CENTRE = (HORIZONTAL_SPAN, 0.0, 0.3)
ANCHOR = (0.0, 0.0, -WATER_DEPTH)
MASS_PER_LENGTH = 0.0818
EA = 10000.0
STEEL_DIAMETER = 0.0022
STEEL_DENSITY = 7800.0
CD_NORMAL_ON_STEEL_DIAMETER = 2.5
CD_TANGENTIAL_ON_STEEL_DIAMETER = 0.5
CA_ON_MATERIAL_AREA = 3.8
GROUND_MODULUS = 3.0e9
GROUND_DAMPING_RATIO = 1.0

PERIODS = (1.25, 1.50, 2.00, 2.50, 3.00, 3.50)
RADII = (0.075, 0.100, 0.125, 0.150, 0.200)
MEASURED_MAXIMUM_N = {
    1.25: (42.5, 46.8, 54.1, 60.4, 70.3),
    1.50: (41.0, 45.3, 51.5, 59.0, 68.0),
    2.00: (36.0, 39.5, 47.5, 54.1, 62.3),
    2.50: (31.1, 35.4, 42.5, 49.0, 57.3),
    3.00: (29.5, 33.1, 39.3, 45.8, 54.0),
    3.50: (27.8, 31.5, 37.5, 42.5, 50.1),
}


def smoothstep5(value: float) -> tuple[float, float, float]:
    """Return a C2 quintic ramp and derivatives with respect to its argument."""
    if value <= 0.0:
        return 0.0, 0.0, 0.0
    if value >= 1.0:
        return 1.0, 0.0, 0.0
    r = 10.0 * value**3 - 15.0 * value**4 + 6.0 * value**5
    dr = 30.0 * value**2 - 60.0 * value**3 + 30.0 * value**4
    ddr = 60.0 * value - 180.0 * value**2 + 120.0 * value**3
    return r, dr, ddr


def write_motion(path: Path, period: float, radius: float, dt: float, cycles: int, ramp_cycles: int) -> None:
    omega = 2.0 * math.pi / period
    ramp_time = ramp_cycles * period
    tmax = cycles * period
    count = int(round(tmax / dt))
    if not math.isclose(count * dt, tmax, rel_tol=0.0, abs_tol=1.0e-10):
        raise ValueError(f"TMax={tmax:g} is not an integer multiple of dt={dt:g}")
    lines = [
        "# Bergdahl et al. (2016), circular fairlead motion with a C2 numerical start.",
        "# time point x y z vx vy vz ax ay az",
    ]
    for index in range(count + 1):
        time = index * dt
        ramp, ramp_u, ramp_uu = smoothstep5(time / ramp_time)
        ramp_t = ramp_u / ramp_time
        ramp_tt = ramp_uu / ramp_time**2
        phase = omega * time
        sin_phase = math.sin(phase)
        cos_phase = math.cos(phase)
        x_offset = radius * ramp * sin_phase
        z_offset = radius * ramp * cos_phase
        vx = radius * (ramp_t * sin_phase + ramp * omega * cos_phase)
        vz = radius * (ramp_t * cos_phase - ramp * omega * sin_phase)
        ax = radius * (ramp_tt * sin_phase + 2.0 * ramp_t * omega * cos_phase - ramp * omega**2 * sin_phase)
        az = radius * (ramp_tt * cos_phase - 2.0 * ramp_t * omega * sin_phase - ramp * omega**2 * cos_phase)
        lines.append(
            f"{time:.8f} 1 {FAIRLEAD_CENTRE[0] + x_offset:.12e} 0.0 "
            f"{FAIRLEAD_CENTRE[2] + z_offset:.12e} {vx:.12e} 0.0 {vz:.12e} "
            f"{ax:.12e} 0.0 {az:.12e}"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_deck(
    path: Path,
    period: float,
    radius: float,
    dt: float,
    element_length: float,
    cycles: int,
    rho_inf: float,
    kbot: float,
    cbot: float,
    ba: float,
    solver_tolerance: float,
    friction_mu: float,
) -> int:
    number_of_elements = int(math.ceil(LENGTH / element_length))
    element_length = LENGTH / number_of_elements
    equivalent_diameter = math.sqrt(4.0 * MASS_PER_LENGTH / (math.pi * STEEL_DENSITY))
    cd_normal = CD_NORMAL_ON_STEEL_DIAMETER * STEEL_DIAMETER / equivalent_diameter
    cd_tangential = CD_TANGENTIAL_ON_STEEL_DIAMETER * STEEL_DIAMETER / equivalent_diameter
    motion_name = path.with_suffix(".motion.txt").name
    lines = [
        "--------------------- CableDyn Input File ------------------------------------",
        "Bergdahl et al. (2016) dynamically scaled 33 m mooring-chain experiment",
        "--------------------- LINE TYPES ---------------------------------------------",
        "TypeName Diam MassDenInAir EA BA EI Cd_n Cd_t Ca_n Ca_t",
        "(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)",
        f"chain {equivalent_diameter:.12g} {MASS_PER_LENGTH:.12g} {EA:.12g} {ba:.12g} 0.0 "
        f"{cd_normal:.12g} {cd_tangential:.12g} {CA_ON_MATERIAL_AREA:.12g} 0.0",
        "--------------------- POINTS -------------------------------------------------",
        "ID Type X Y Z",
        "(-) (-) (m) (m) (m)",
        f"1 Coupled {FAIRLEAD_CENTRE[0]:.12g} 0.0 {FAIRLEAD_CENTRE[2]:.12g}",
        f"2 Fixed {ANCHOR[0]:.12g} 0.0 {ANCHOR[2]:.12g}",
        "--------------------- LINES --------------------------------------------------",
        "ID NodeA NodeB Outputs",
        "(-) (-) (-) (-)",
        "1 1 2 -",
        "--------------------- SECTIONS -----------------------------------------------",
        "LineID LineType Length NumSegs",
        "(-) (-) (m) (-)",
        f"1 chain {LENGTH:.12g} {number_of_elements}",
        "--------------------- OPTIONS ------------------------------------------------",
        f"{G:.12g} g",
        f"{RHO_WATER:.12g} rhoW",
        f"{WATER_DEPTH:.12g} WtrDpth",
        f"{kbot:.12g} kBot",
        f"{cbot:.12g} cBot",
        f"{rho_inf:.12g} rhoInf",
        "False modified_newton",
        f"{dt:.12g} dtM",
        f"{cycles * period:.12g} TMax",
        f"{motion_name} motionFile",
        "False adaptive_mesh",
        "False tensile_safety",
        f"dynamic_solver {solver_tolerance:.12g} 1.0e-12 100 16",
        f"{friction_mu:.12g} frictionMu",
        "none current",
        "none waves",
        "0 WaterKin",
        "--------------------- OUTPUTS -----------------------------------------------",
        '"FairTen1"',
        '"AnchTen1"',
        '"FairIncl1"',
        '"Point1px"',
        '"Point1pz"',
        "--------------------- need this line ----------------------------------------",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return number_of_elements


def mapped_contact_coefficients(
    equivalent_diameter: float,
    ground_modulus: float,
    ground_damping_ratio: float,
) -> tuple[float, float]:
    """Map the published MooDy ground law to CableDyn without fitting.

    Bergdahl et al. specify a ground modulus ``Kg`` and damping factor ``xi``.
    MooDy's contact law per unit unstretched length is

        Kg * d * penetration - 2*xi*sqrt(Kg*d*gamma0) * vertical_velocity.

    CableDyn applies ``kBot*d_eq`` and ``cBot*d_eq`` per unit length.  The
    equivalent solid diameter is needed to preserve the independently reported
    material volume, so both coefficients are rescaled to retain the published
    contact force per unit length based on the 2.2 mm steel-link diameter.
    """
    kbot = ground_modulus * STEEL_DIAMETER / equivalent_diameter
    damping_per_length = 2.0 * ground_damping_ratio * math.sqrt(
        ground_modulus * STEEL_DIAMETER * MASS_PER_LENGTH
    )
    cbot = damping_per_length / equivalent_diameter
    return kbot, cbot


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--dt", type=float, default=0.0003125)
    parser.add_argument("--element-length", type=float, default=0.20)
    parser.add_argument("--cycles", type=int, default=12)
    parser.add_argument("--ramp-cycles", type=int, default=3)
    parser.add_argument("--rho-inf", type=float, default=0.4)
    parser.add_argument("--ground-modulus", type=float, default=GROUND_MODULUS)
    parser.add_argument("--ground-damping-ratio", type=float, default=GROUND_DAMPING_RATIO)
    parser.add_argument(
        "--kbot",
        type=float,
        default=None,
        help="Optional direct CableDyn kBot override; the default preserves the published MooDy contact force per length.",
    )
    parser.add_argument(
        "--cbot",
        type=float,
        default=None,
        help="Optional direct CableDyn cBot override; the default maps the published critical-damping factor exactly.",
    )
    parser.add_argument("--ba", type=float, default=0.0)
    parser.add_argument(
        "--friction-mu",
        type=float,
        default=0.3,
        help="Seabed friction coefficient; 0.3 is the value reported by Bergdahl et al.",
    )
    parser.add_argument(
        "--period",
        type=float,
        action="append",
        dest="selected_periods",
        help="Prepare only this published period; repeat to select more than one.",
    )
    parser.add_argument(
        "--radius",
        type=float,
        action="append",
        dest="selected_radii",
        help="Prepare only this published radius; repeat to select more than one.",
    )
    parser.add_argument("--solver-tolerance", type=float, default=1.0e-8)
    args = parser.parse_args()
    if not math.isfinite(args.friction_mu) or args.friction_mu < 0.0:
        parser.error("--friction-mu must be finite and non-negative")
    selected_periods = PERIODS if args.selected_periods is None else tuple(args.selected_periods)
    selected_radii = RADII if args.selected_radii is None else tuple(args.selected_radii)
    unsupported_periods = [value for value in selected_periods if value not in PERIODS]
    unsupported_radii = [value for value in selected_radii if value not in RADII]
    if unsupported_periods:
        parser.error(f"unsupported --period value(s): {unsupported_periods}; choose from {PERIODS}")
    if unsupported_radii:
        parser.error(f"unsupported --radius value(s): {unsupported_radii}; choose from {RADII}")
    args.output_directory.mkdir(parents=True, exist_ok=True)
    equivalent_diameter = math.sqrt(4.0 * MASS_PER_LENGTH / (math.pi * STEEL_DENSITY))
    mapped_kbot, mapped_cbot = mapped_contact_coefficients(
        equivalent_diameter,
        args.ground_modulus,
        args.ground_damping_ratio,
    )
    resolved_kbot = mapped_kbot if args.kbot is None else args.kbot
    resolved_cbot = mapped_cbot if args.cbot is None else args.cbot
    manifest = []
    for period in PERIODS:
        if period not in selected_periods:
            continue
        for radius, measured_maximum in zip(RADII, MEASURED_MAXIMUM_N[period]):
            if radius not in selected_radii:
                continue
            stem = f"bergdahl_T{period:.2f}_R{radius:.3f}_h{args.element_length:.3f}_dt{args.dt:.4f}".replace(
                ".", "p"
            )
            deck = args.output_directory / f"{stem}.dat"
            number_of_elements = write_deck(
                deck,
                period,
                radius,
                args.dt,
                args.element_length,
                args.cycles,
                args.rho_inf,
                resolved_kbot,
                resolved_cbot,
                args.ba,
                args.solver_tolerance,
                args.friction_mu,
            )
            motion = deck.with_suffix(".motion.txt")
            write_motion(motion, period, radius, args.dt, args.cycles, args.ramp_cycles)
            manifest.append(
                {
                    "case": stem,
                    "period_s": period,
                    "radius_m": radius,
                    "measured_maximum_N": measured_maximum,
                    "dt_s": args.dt,
                    "number_of_elements": number_of_elements,
                    "element_length_m": LENGTH / number_of_elements,
                    "total_cycles": args.cycles,
                    "ramp_cycles": args.ramp_cycles,
                    "rho_inf": args.rho_inf,
                    "published_ground_modulus_Pa_per_m": args.ground_modulus,
                    "published_ground_damping_ratio": args.ground_damping_ratio,
                    "published_contact_diameter_m": STEEL_DIAMETER,
                    "equivalent_volume_diameter_m": equivalent_diameter,
                    "kbot_Pa_per_m": resolved_kbot,
                    "cbot_Pa_s_per_m": resolved_cbot,
                    "contact_coefficients_overridden": args.kbot is not None or args.cbot is not None,
                    "ba_N_s": args.ba,
                    "friction_mu": args.friction_mu,
                    "solver_relative_tolerance": args.solver_tolerance,
                    "analysis_start_s": (args.cycles - 5) * period,
                    "deck_sha256": hashlib.sha256(deck.read_bytes()).hexdigest(),
                    "motion_sha256": hashlib.sha256(motion.read_bytes()).hexdigest(),
                }
            )
    (args.output_directory / "case_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {len(manifest)} cases in {args.output_directory}")


if __name__ == "__main__":
    main()
