# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Step a cable in-process while the host supplies the water and moves the top end.

The host owns the time loop. Before each step it reads the node positions, evaluates its own
current and wave at them, hands the field over, and passes the motion of the top end. Replace
``sea`` and ``top_end`` with your own models. Run it with::

    python step_in_moving_water.py
"""

from __future__ import annotations

import math
import tempfile
from pathlib import Path

import numpy as np

import cabledyn

DT = 0.05
DEPTH, GRAVITY = 60.0, 9.80665
AMPLITUDE, PERIOD, CURRENT = 1.0, 8.0, 0.4
TOP = np.array([0.0, 0.0, -10.0])

DECK = """--------------------- CableDyn Input File ------------------------------------
A cable from a moving top end to an anchor. The steady current of the deck sets the static start.
--------------------- LINE TYPES ---------------------------------------------
TypeName  Diam   MassDenInAir  EA       BA   EI       Cd_n Cd_t Ca_n Ca_t
(-)       (m)    (kg/m)        (N)      (-)  (N-m2)   (-)  (-)  (-)  (-)
cable     0.16   36.7          4.69e8   -1.0 1.99e4   1.2  0.1  1.0  0.0
--------------------- POINTS ------------------------------------------------
ID  Type     X       Y    Z
(-) (-)      (m)     (m)  (m)
1   Coupled  0.0     0.0  -10.0
2   Fixed    70.0    0.0  -60.0
--------------------- LINES -------------------------------------------------
ID  NodeA  NodeB  Outputs
(-) (-)    (-)    (-)
1   1      2      -
--------------------- SECTIONS ----------------------------------------------
LineID  LineType  Length   NumSegs
(-)     (-)       (m)      (-)
1       cable     100.0    50
--------------------- OPTIONS -----------------------------------------------
9.80665  g
1025.0   rhoW
60.0     WtrDpth
0.05     dtM
uniform 0.4 0 0 current
--------------------- OUTPUTS -----------------------------------------------
"FairTen1"
--------------------- need this line ----------------------------------------
"""


def wave_number(omega: float) -> float:
    k = omega * omega / GRAVITY
    for _ in range(50):
        k = omega * omega / (GRAVITY * math.tanh(k * DEPTH))
    return k


OMEGA = 2.0 * math.pi / PERIOD
K = wave_number(OMEGA)


def sea(xyz: np.ndarray, t: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Whole ambient velocity, fluid acceleration and surface elevation at the nodes ``(3, n)``."""
    theta = K * xyz[0] - OMEGA * t
    decay = np.exp(K * np.minimum(xyz[2], 0.0))  # deep-water profile, for brevity
    velocity = np.zeros_like(xyz)
    acceleration = np.zeros_like(xyz)
    velocity[0] = CURRENT + AMPLITUDE * OMEGA * decay * np.cos(theta)
    velocity[2] = AMPLITUDE * OMEGA * decay * np.sin(theta)
    acceleration[0] = AMPLITUDE * OMEGA**2 * decay * np.sin(theta)
    acceleration[2] = -AMPLITUDE * OMEGA**2 * decay * np.cos(theta)
    return velocity, acceleration, AMPLITUDE * np.cos(theta)


def top_end(t: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Position, velocity and acceleration of the coupled point: a slow surge, from rest."""
    rate = 2.0 * math.pi / 10.0
    s, c = math.sin(rate * t), math.cos(rate * t)
    q = TOP + np.array([0.5 * s**3, 0.0, 0.0])
    v = np.array([1.5 * rate * s * s * c, 0.0, 0.0])
    a = np.array([1.5 * rate**2 * (2.0 * s * c * c - s**3), 0.0, 0.0])
    return q, v, a


def main(duration: float = 20.0) -> list[float]:
    """March for ``duration`` seconds and return the top tension of every step."""
    tensions = []
    with tempfile.TemporaryDirectory() as folder:
        deck = Path(folder) / "cable.dat"
        deck.write_text(DECK, encoding="utf-8")
        with cabledyn.CableDyn() as model:
            model.set_host_fluid()  # before the initialization
            model.init_deck(deck)

            def give_field(t: float) -> None:
                # the field of a step: at its end time, at the step-start positions
                model.update_fluid_fields(*sea(model.fluid_node_positions(), t))

            give_field(0.0)  # the start acceleration
            for i in range(1, round(duration / DT) + 1):
                t = i * DT
                give_field(t)
                model.step(DT, *top_end(t))
                model.calc_output()
                tensions.append(float(model.channel("FairTen1")))
                if i % round(1.0 / DT) == 0:
                    print(f"t = {t:5.1f} s   top tension {tensions[-1]:10.1f} N")
    return tensions


if __name__ == "__main__":
    main()
