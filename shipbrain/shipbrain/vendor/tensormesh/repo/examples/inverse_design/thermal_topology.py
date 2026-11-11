"""Thermal-compliance topology optimization with the built-in OCOptimizer.

Distribute a fixed amount of conductive material on the unit square so as to
remove heat from a central source to the cold boundary as efficiently as
possible -- i.e. minimise the thermal compliance ``J = b^T u`` under a hard
volume constraint:

    minimize    J(rho) = b^T u
    subject to  K(rho) u = b,     mean(rho) <= V,     rho_min <= rho <= 1,

with a SIMP conductivity law ``kappa(rho) = kappa_min + (1 - kappa_min) rho^p``
and a per-element density ``rho``. The compliance gradient ``dJ/drho`` comes
straight from PyTorch autograd through the FEM solve (the adjoint backward of
``SparseMatrix.solve``); the density update is the classical Optimality
Criteria step provided by :class:`tensormesh.optimizer.OCOptimizer`.

This is the scalar/heat counterpart to the structural cantilever in
``compliance_topology.py``: same "autograd sensitivity + density update"
pattern, different physics and a different optimiser.

Writes ``thermal_topology.png`` (density-evolution snapshots + convergence).

Run, after activating the tensorgalerkin venv::

    python thermal_topology.py
    python thermal_topology.py --device cuda --n-iter 80
"""

import argparse
import os
import time
import warnings

import numpy as np
import matplotlib.pyplot as plt
from matplotlib import tri as mtri
import torch

from tensormesh import Mesh, ElementAssembler, NodeAssembler, Condenser
from tensormesh.optimizer import OCOptimizer

warnings.filterwarnings("ignore", message="Sparse CSR tensor support is in beta state")
warnings.filterwarnings("ignore", message="float64 recommended")

torch.set_default_dtype(torch.float64)


class SIMPLaplace(ElementAssembler):
    """Heat-conduction stiffness with a per-element SIMP conductivity."""

    def forward(self, gradu, gradv, kappa):
        return kappa * (gradu @ gradv)


class Source(NodeAssembler):
    """Load vector for a nodal heat source ``f``."""

    def forward(self, v, f):
        return v * f


def optimize(device="cpu", n_iter=60, h=0.025,
             V=0.4, p_simp=3.0, kmin=1e-3, move_limit=0.15, sigma=0.08):
    mesh = Mesh.gen_rectangle(chara_length=h).to(device)
    cond = Condenser(mesh.boundary_mask)
    elements = mesh.cells["triangle"]
    n_elem = elements.shape[0]
    print(f"mesh: {mesh.n_points} nodes, {n_elem} elements on {device}")

    # Localised hot pad in the centre; u = 0 ("cold sink") on the boundary.
    pts = mesh.points
    x, y = pts[:, 0], pts[:, 1]
    f_field = torch.exp(-((x - 0.5) ** 2 + (y - 0.5) ** 2) / (2 * sigma ** 2))

    rho = torch.full((n_elem,), V, dtype=torch.float64,
                     device=device, requires_grad=True)
    optim = OCOptimizer(rho, vf=V, move_limit=move_limit)

    def fem_solve(rho):
        kappa = kmin + (1.0 - kmin) * rho ** p_simp          # SIMP, [n_elem]
        K = SIMPLaplace.from_mesh(mesh)(element_data={"kappa": kappa}).double()
        b = Source.from_mesh(mesh)(point_data={"f": f_field}).double()
        K_, b_ = cond(K, b)
        return cond.recover(K_.solve(b_)), b

    snap_iters = sorted({0, 2, 5, n_iter - 1})
    snapshots, compliances, volumes = {}, [], []
    t0 = time.time()
    for step in range(n_iter):
        optim.zero_grad()
        u, b = fem_solve(rho)
        compliance = (b * u).sum()        # J = b^T u
        compliance.backward()             # autograd populates rho.grad
        info = optim.step()               # OC update + volume bisection
        compliances.append(compliance.item())
        volumes.append(info["volume"])
        if step in snap_iters:
            snapshots[step] = rho.detach().clone().cpu().numpy()
        if step % 10 == 0 or step == n_iter - 1:
            print(f"  step {step:3d}  C={compliance.item():.4e}  "
                  f"V={info['volume']:.3f}  lambda={info['lambda']:.3e}")
    print(f"  {n_iter} steps in {time.time() - t0:.1f}s; "
          f"compliance {compliances[0]:.3e} -> {compliances[-1]:.3e} "
          f"({compliances[0] / compliances[-1]:.1f}x)")

    return dict(mesh=mesh, elements=elements, snap_iters=snap_iters,
                snapshots=snapshots, compliances=compliances, volumes=volumes)


def plot(result, out_dir):
    mesh = result["mesh"]
    pts = mesh.points.cpu().numpy()
    triang = mtri.Triangulation(pts[:, 0], pts[:, 1],
                                result["elements"].cpu().numpy())
    snap_iters = result["snap_iters"]
    compliances = result["compliances"]

    fig = plt.figure(figsize=(15, 3.6), constrained_layout=True)
    gs = fig.add_gridspec(1, len(snap_iters) + 1)

    for col, k in enumerate(snap_iters):
        ax = fig.add_subplot(gs[0, col])
        cs = ax.tripcolor(triang, facecolors=result["snapshots"][k],
                          cmap="gray_r", vmin=0, vmax=1, shading="flat")
        ax.set_aspect("equal")
        ax.set_xticks([0, 0.5, 1])
        ax.set_yticks([0, 0.5, 1])
        ax.set_title(f"iter {k}\n$C={compliances[k]:.2e}$, "
                     f"$V={result['volumes'][k]:.2f}$", fontsize=10)
    cbar = fig.colorbar(cs, ax=fig.axes, shrink=0.7, ticks=[0, 0.5, 1.0],
                        location="right", pad=0.02)
    cbar.set_label(r"density $\rho$")

    ax = fig.add_subplot(gs[0, -1])
    ax.semilogy(np.arange(len(compliances)), compliances,
                color="#c0392b", linewidth=2)
    ax.set_xlabel("OC iteration")
    ax.set_ylabel("compliance $J = b^T u$")
    ax.set_title("convergence", fontsize=10)
    ax.grid(True, which="both", alpha=0.3)

    fig.suptitle("Thermal topology optimization: compliance "
                 r"$\downarrow$ under a volume constraint (OCOptimizer)",
                 fontsize=12)
    out = os.path.join(out_dir, "thermal_topology.png")
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  -> {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu",
                        choices=["cpu", "cuda"])
    parser.add_argument("--n-iter", type=int, default=60)
    parser.add_argument("--chara-length", type=float, default=0.025)
    parser.add_argument("--vf", type=float, default=0.4, help="volume fraction")
    parser.add_argument("--out-dir", default=os.path.dirname(os.path.abspath(__file__)))
    args = parser.parse_args()

    result = optimize(device=args.device, n_iter=args.n_iter,
                      h=args.chara_length, V=args.vf)
    os.makedirs(args.out_dir, exist_ok=True)
    plot(result, args.out_dir)


if __name__ == "__main__":
    main()
