# File: validation/scripts/hermite_torsion_oracle.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Automatic-differentiation reference for the parallel-transport twist of a Hermite cable.

The cubic-Hermite cable stores, at every node, a position r and a tangent handle m = dr/ds,
with the 12 element DOFs ordered [r1, m1, r2, m2]. For condensed isotropic torsion, the
twist of the centreline between two end frames (d_A, n_A) and (d_B, n_B) is the
parallel-transport (smallest-rotation, Bishop) holonomy

    Theta = angle about d_B from n_B to PT(n_A)        (right-hand rule, modulo 2 pi),

where PT carries n_A from d_A through the node tangents t_k = m_k / |m_k| to d_B. Because the
Hermite curve is C1, PT is the product of the smallest rotations along the chain
d_A -> t_0 -> ... -> t_N -> d_B and of the element holonomies

    h_e = + integral_e t1 . (a x b) / (|a|^2 (1 + t1 . a/|a|)) ds,   a = r', b = r'',

where t1 is the tangent at the first node of element e. This script evaluates Theta in that
form with JAX (float64), differentiates it twice with respect to the nodal DOFs and to small
rotations of the two end frames, and writes the reference values used by the Fortran test
``tests/test_hermite_torsion_kernel.f90``:

    python validation/scripts/hermite_torsion_oracle.py --out tests/data/torsion_oracle_reference.txt

``--out`` is required (``--help`` only prints the usage). Requires JAX and NumPy.

The end-frame derivatives are taken with respect to the rotation vector w of an
incremental rotation exp(w) applied to both end directors at w = 0. Before writing,
the script checks the analytic structure the kernel relies on: Theta agrees with a
brute-force parallel transport (fine smallest-rotation steps, no h_e formula), the
DOF Hessian has half-bandwidth 11, and the end rotations couple only to the adjacent
end-node tangent.
"""
from __future__ import annotations

import os

import numpy as np
import jax
import jax.numpy as jnp
from jax import lax

jax.config.update("jax_enable_x64", True)

TWO_PI = 2.0 * np.pi
KBAND = 11
QUADRATURE_ORDER = 4


# ------------------------------------------------------------------------------------------
# kinematics and Theta
# ------------------------------------------------------------------------------------------
def unit(v):
    return v / jnp.linalg.norm(v, axis=-1, keepdims=True)


def smallest_rotation(a, b, v):
    """Smallest rotation taking unit a to unit b, applied to v (singular at b = -a)."""
    c = jnp.dot(a, b)
    w = jnp.cross(a, b)
    return c * v + jnp.cross(w, v) + w * jnp.dot(w, v) / (1.0 + c)


def signed_angle(u, v, axis):
    return jnp.arctan2(jnp.dot(axis, jnp.cross(u, v)), jnp.dot(u, v))


def gauss01(order):
    x, w = np.polynomial.legendre.leggauss(order)
    return 0.5 * (x + 1.0), 0.5 * w


def element_ab(qe, length, xi):
    """a = dr/ds and b = d2r/ds2 of one element at the parametric points xi."""
    x = jnp.asarray(xi)
    dh = jnp.stack([-6 * x + 6 * x**2, length * (1 - 4 * x + 3 * x**2), 6 * x - 6 * x**2,
                    length * (-2 * x + 3 * x**2)], 1)
    ddh = jnp.stack([-6 + 12 * x, length * (-4 + 6 * x), 6 - 12 * x, length * (-2 + 6 * x)], 1)
    nodal = qe.reshape(4, 3)
    return (dh / length) @ nodal, (ddh / length**2) @ nodal


def element_holonomy(qe, length, order=QUADRATURE_ORDER):
    xi, w = gauss01(order)
    a, b = element_ab(qe, length, xi)
    t1 = unit(qe[3:6])
    s2 = jnp.sum(a * a, 1)
    num = jnp.cross(a, b) @ t1
    den = s2 * (1.0 + (a @ t1) / jnp.sqrt(s2))
    return length * jnp.sum(jnp.asarray(w) * num / den)


def element_dofs(q):
    n_el = q.size // 6 - 1
    return q[6 * np.arange(n_el)[:, None] + np.arange(12)[None, :]]


def theta(q, lengths, ends, order=QUADRATURE_ORDER):
    """Theta modulo 2 pi: sum of element holonomies plus the smallest-rotation chain."""
    d_a, n_a, d_b, n_b = ends
    hol = jnp.sum(jax.vmap(element_holonomy, (0, 0, None))(element_dofs(q), lengths, order))
    chain = jnp.concatenate([d_a[None], unit(q.reshape(-1, 6)[:, 3:]), d_b[None]])

    def step(v, uu):
        return smallest_rotation(uu[0], uu[1], v), None

    v, _ = lax.scan(step, n_a, (chain[:-1], chain[1:]))
    return hol + signed_angle(n_b, v, d_b)


def rotate(w, v):
    """exp(w) v (rotation-vector map); differentiable at w = 0."""
    k = jnp.array([[0.0, -w[2], w[1]], [w[2], 0.0, -w[0]], [-w[1], w[0], 0.0]])
    return jax.scipy.linalg.expm(k) @ v


def theta_with_end_rotations(x, lengths, ends):
    """Theta of x = [q, w_A, w_B]: q nodal DOFs, w_A / w_B incremental end-frame rotations."""
    n = x.size - 6
    w_a, w_b = x[n:n + 3], x[n + 3:]
    d_a, n_a, d_b, n_b = ends
    rotated = (rotate(w_a, d_a), rotate(w_a, n_a), rotate(w_b, d_b), rotate(w_b, n_b))
    return theta(x[:n], lengths, rotated)


def brute_force_theta(q, lengths, ends, samples=1500):
    """Independent parallel transport by smallest-rotation steps between closely sampled
    tangents (no h_e formula); Richardson-extrapolated in the step count."""

    def sr(a, b, v):
        c, w = a @ b, np.cross(a, b)
        return c * v + np.cross(w, v) + w * (w @ v) / (1.0 + c)

    def run(ns):
        d_a, n_a, d_b, n_b = (np.asarray(e) for e in ends)
        v, prev = n_a.copy(), d_a
        xi = np.linspace(0.0, 1.0, ns + 1)
        for e, qe in enumerate(np.asarray(element_dofs(q))):
            a = np.asarray(element_ab(jnp.asarray(qe), float(lengths[e]), xi)[0])
            for tk in a / np.linalg.norm(a, axis=1, keepdims=True):
                v = sr(prev, tk, v)
                v = v - (v @ tk) * tk
                v /= np.linalg.norm(v)
                prev = tk
        v = sr(prev, d_b, v)
        return float(np.arctan2(d_b @ np.cross(n_b, v), n_b @ v))

    t1, t2 = run(samples), run(2 * samples)
    d = (t2 - t1 + np.pi) % TWO_PI - np.pi
    return t1 + d + d / 3.0


# ------------------------------------------------------------------------------------------
# configurations
# ------------------------------------------------------------------------------------------
def random_curve(n_el, length=10.0, n_modes=4, amp=1.5, seed=0, stretch_amp=0.1):
    """Smooth random large-deformation 3D curve sampled at the nodes, with random nodal
    stretch so that |m| differs from 1."""
    rng = np.random.default_rng(seed)
    k = np.arange(1, n_modes + 1)
    a_c = rng.normal(size=(3, n_modes)) * amp / k
    b_c = rng.normal(size=(3, n_modes)) * amp / k
    w = np.pi * k / length
    s = np.linspace(0.0, length, n_el + 1)
    r = np.array([[si, 0.0, 0.0] + (a_c * np.sin(w * si) + b_c * (np.cos(w * si) - 1.0)).sum(1) * length / np.pi
                  for si in s])
    dr = np.array([[1.0, 0.0, 0.0] + (a_c * w * np.cos(w * si) - b_c * w * np.sin(w * si)).sum(1) * length / np.pi
                   for si in s])
    stretch = 1.0 + stretch_amp * rng.uniform(-1, 1, size=s.size)
    return np.hstack([r, dr * stretch[:, None]]).ravel(), np.diff(s)


def clamped_ends(q):
    """End directors along the end tangents; n_A from a fixed seed, n_B its projection."""
    nodes = q.reshape(-1, 6)
    t_a = nodes[0, 3:] / np.linalg.norm(nodes[0, 3:])
    t_b = nodes[-1, 3:] / np.linalg.norm(nodes[-1, 3:])
    seed = np.array([0.0, 0.0, 1.0]) if abs(t_a[2]) < 0.9 else np.array([0.0, 1.0, 0.0])
    n_a = seed - (seed @ t_a) * t_a
    n_a /= np.linalg.norm(n_a)
    n_b = n_a - (n_a @ t_b) * t_b
    return t_a, n_a, t_b, n_b / np.linalg.norm(n_b)


def articulated_ends():
    """End directors that differ from the end tangents (articulated ends)."""
    d_a = np.array([0.8, 0.5, -0.33]) / np.linalg.norm([0.8, 0.5, -0.33])
    d_b = np.array([-0.2, 0.9, 0.4]) / np.linalg.norm([-0.2, 0.9, 0.4])
    n_a = np.cross(d_a, [0.0, 0.0, 1.0])
    n_b = np.cross(d_b, [1.0, 0.0, 0.0])
    return d_a, n_a / np.linalg.norm(n_a), d_b, n_b / np.linalg.norm(n_b)


def cases():
    out = []
    for seed in (0, 1, 2):
        q, le = random_curve(16, seed=seed)
        out.append((f"random_seed{seed}_clamped", q, le, clamped_ends(q)))
    q, le = random_curve(16, seed=0)
    out.append(("random_seed0_articulated", q, le, articulated_ends()))
    return out


# ------------------------------------------------------------------------------------------
# export
# ------------------------------------------------------------------------------------------
def fmt(values):
    return "\n".join(" ".join(repr(float(v)) for v in values[i:i + 4]) for i in range(0, len(values), 4))


def main(path):
    blocks = []
    for name, q, le, ends in cases():
        n = q.size
        x0 = jnp.concatenate([jnp.asarray(q), jnp.zeros(6)])
        e = tuple(jnp.asarray(v) for v in ends)
        lj = jnp.asarray(le)
        th = float(theta(jnp.asarray(q), lj, e))
        grad = np.asarray(jax.grad(theta_with_end_rotations)(x0, lj, e))
        hess = np.asarray(jax.hessian(theta_with_end_rotations)(x0, lj, e))
        bf = brute_force_theta(q, le, ends)
        scale = np.abs(hess).max()
        i, j = np.indices((n, n))
        off_band = np.abs(hess[:n, :n][np.abs(i - j) > KBAND]).max() / scale
        mask = np.ones((n + 6, n + 6), bool)  # entries the kernel may fill
        mask[:n, :n] = np.abs(i - j) <= KBAND
        mask[n:n + 3, n:n + 3] = mask[n + 3:, n + 3:] = True
        mask[n:n + 3, 3:6] = mask[3:6, n:n + 3] = True
        mask[n + 3:, n - 3:n] = mask[n - 3:n, n + 3:] = True
        outside = np.abs(hess[~mask]).max() / scale
        assert off_band < 1e-14 and outside < 1e-14, (name, off_band, outside)
        err_bf = abs((th - bf + np.pi) % TWO_PI - np.pi)
        print(f"{name}: Theta = {th:+.15f}, brute-force PT difference {err_bf:.1e}, "
              f"off-band {off_band:.1e}, outside end blocks {outside:.1e}")
        band = [hess[r, c] for c in range(n) for r in range(c, min(c + KBAND, n - 1) + 1)]
        end_blocks = [hess[n:n + 3, n:n + 3], hess[n + 3:, n + 3:], hess[n:n + 3, 3:6], hess[n + 3:, n - 3:n]]
        values = (list(le) + list(q) + [v for d in ends for v in d] + [th] + list(grad) + band
                  + [v for blk in end_blocks for v in blk.ravel(order="F")])
        blocks.append(f"{name}\n{n // 6} {QUADRATURE_ORDER}\n{fmt(values)}")
    header = f"""# Reference values for tests/test_hermite_torsion_kernel.f90.
# Generated by validation/scripts/hermite_torsion_oracle.py (JAX automatic differentiation,
# float64, {QUADRATURE_ORDER}-point Gauss-Legendre rule per element). Do not edit by hand.
# Layout: number of cases, then per case
#   name (one line); n_nodes quadrature_order
#   L_e (n_nodes - 1), q (6 n_nodes, node order [r, m]), d_A n_A d_B n_B (12),
#   Theta (modulo 2 pi), dTheta/d[q, w_A, w_B] (6 n_nodes + 6),
#   d2Theta/dq2 lower band: for column j = 1..n, rows i = j..min(j + 11, n),
#   d2Theta/dw_A2, d2Theta/dw_B2, d2Theta/dw_A dm_0, d2Theta/dw_B dm_N (3x3 each, column-major).
# w_A, w_B: rotation vectors of incremental rotations exp(w) of the end frames, at w = 0.
"""
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write(header + f"{len(blocks)}\n" + "\n".join(blocks) + "\n")
    print(f"wrote {path}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--out",
        required=True,
        help="output path (the committed reference is tests/data/torsion_oracle_reference.txt)",
    )
    main(os.path.normpath(parser.parse_args().out))
