"""Coefficient-field identification by differentiable FEM.

Recover an unknown, spatially varying diffusion coefficient ``kappa(x)`` in

    -div( kappa(x) grad u ) = f      in (0, 1)^2,
                          u = 0       on the boundary,

from a *single* observed solution ``u_obs``, purely by gradient descent
through the FEM solve. The forward map is "assemble the kappa-weighted
stiffness, condense, solve"; the loss is the L2 distance between the FEM
solution and the observation; PyTorch autograd supplies ``dLoss/dkappa``
via the adjoint backward of ``SparseMatrix.solve`` -- there is no
hand-coded sensitivity equation anywhere.

We parametrise ``kappa = 1 + tanh(theta)`` so ``kappa`` stays in (0, 2)
-- strictly positive, hence the FEM matrix is SPD on every iteration --
with ``theta`` unconstrained.

Writes (next to this script by default):

  * ``coefficient_id_loss.png``   -- optimisation history (loss + obs error)
  * ``coefficient_id_fields.png`` -- true / recovered / error coefficient fields

Run, after activating the tensorgalerkin venv::

    python coefficient_identification.py                 # CPU/GPU auto, 5000 steps
    python coefficient_identification.py --n-iter 2000   # quicker, coarser recovery
    python coefficient_identification.py --device cuda
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

warnings.filterwarnings("ignore", message="Sparse CSR tensor support is in beta state")
warnings.filterwarnings("ignore", message="float64 recommended")

torch.set_default_dtype(torch.float64)


class WeightedLaplace(ElementAssembler):
    """Stiffness for ``-div(kappa grad u)`` with a per-node coefficient."""

    def forward(self, gradu, gradv, kappa):
        return kappa * (gradu @ gradv)


class Source(NodeAssembler):
    """Load vector for a nodal source ``f``."""

    def forward(self, v, f):
        return v * f


def identify(device="cpu", n_iter=5000, h=0.04, lr=3e-2):
    """Run the identification loop; return everything the figures need."""
    mesh = Mesh.gen_rectangle(chara_length=h).to(device)
    cond = Condenser(mesh.boundary_mask)
    pts = mesh.points
    x, y = pts[:, 0], pts[:, 1]
    print(f"mesh: {mesh.n_points} nodes on {device}")

    # Ground-truth coefficient: smooth, strictly positive, four-lobe pattern.
    kappa_true = 1.0 + 0.6 * torch.sin(2 * torch.pi * x) * torch.cos(2 * torch.pi * y)
    f_vals = torch.ones(mesh.n_points, dtype=torch.float64, device=device)

    def fem_solve(kappa):
        K = WeightedLaplace.from_mesh(mesh)(point_data={"kappa": kappa}).double()
        b = Source.from_mesh(mesh)(point_data={"f": f_vals}).double()
        K_, b_ = cond(K, b)
        return cond.recover(K_.solve(b_))

    # Synthetic observation from the true coefficient.
    with torch.no_grad():
        u_obs = fem_solve(kappa_true)
    u_norm = u_obs.abs().max().item()

    # Recover kappa from u_obs by Adam on the unconstrained theta.
    theta = torch.zeros(mesh.n_points, dtype=torch.float64,
                        device=device, requires_grad=True)
    optim = torch.optim.Adam([theta], lr=lr)

    losses, u_errs = [], []
    t0 = time.time()
    for step in range(n_iter):
        optim.zero_grad()
        kappa = 1.0 + torch.tanh(theta)
        u = fem_solve(kappa)
        loss = ((u - u_obs) ** 2).sum()
        loss.backward()
        optim.step()
        with torch.no_grad():
            losses.append(loss.item())
            u_errs.append(((u - u_obs).abs().max() / u_norm).item())
        if step % 500 == 0 or step == n_iter - 1:
            print(f"  step {step:5d}  loss={losses[-1]:.3e}  "
                  f"u_rel={u_errs[-1]:.3e}")
    print(f"  {n_iter} steps in {time.time() - t0:.1f}s")

    with torch.no_grad():
        kappa_final = 1.0 + torch.tanh(theta)

    return dict(mesh=mesh, kappa_true=kappa_true, kappa_final=kappa_final,
                losses=np.array(losses), u_errs=np.array(u_errs))


def _triangles(mesh):
    cells = mesh.cells
    keys = list(cells.keys())
    for key in ("triangle", "tri"):
        if key in keys:
            return cells[key].cpu().numpy()
    return cells[keys[0]].cpu().numpy()


def plot(result, out_dir):
    mesh = result["mesh"]
    losses, u_errs = result["losses"], result["u_errs"]
    n_iter = len(losses)

    # --- Figure 1: optimisation history.
    fig, ax = plt.subplots(figsize=(6.2, 4.2))
    iters = np.arange(1, n_iter + 1)
    ax.semilogy(iters, losses, color="#c0392b", linewidth=2,
                label=r"data loss  $\|u_\theta - u_{\rm obs}\|_2^2$")
    ax2 = ax.twinx()
    ax2.semilogy(iters, u_errs, color="#2980b9", linewidth=2, linestyle="--",
                 label=r"$\|u_\theta - u_{\rm obs}\|_\infty / \|u_{\rm obs}\|_\infty$")
    ax.set_xlabel("Adam iteration")
    ax.set_ylabel("data loss", color="#c0392b")
    ax.tick_params(axis="y", labelcolor="#c0392b")
    ax2.set_ylabel("relative max-norm error in $u$", color="#2980b9")
    ax2.tick_params(axis="y", labelcolor="#2980b9")
    ax.set_title("Coefficient identification: gradient flow through FEM solve")
    ax.grid(True, which="both", alpha=0.3)
    lines, labels = ax.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax.legend(lines + lines2, labels + labels2, loc="upper right",
              fontsize=9, framealpha=0.95)
    fig.tight_layout()
    out = os.path.join(out_dir, "coefficient_id_loss.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    print(f"  -> {out}")

    # --- Figure 2: three-panel coefficient fields.
    pts = mesh.points.cpu().numpy()
    triang = mtri.Triangulation(pts[:, 0], pts[:, 1], _triangles(mesh))
    k_true = result["kappa_true"].cpu().numpy()
    k_rec = result["kappa_final"].cpu().numpy()
    err = np.abs(k_rec - k_true)

    fig, axes = plt.subplots(1, 3, figsize=(12, 3.8), constrained_layout=True)
    vmin, vmax = 0.4, 1.6
    levels = np.linspace(vmin, vmax, 21)
    panels = [
        (k_true, r"true $\kappa(x)$", "viridis"),
        (k_rec, r"recovered $\kappa(x)$", "viridis"),
        (err, r"$|\kappa_{\rm rec} - \kappa_{\rm true}|$", "Reds"),
    ]
    for ax, (data, title, cmap) in zip(axes, panels):
        if cmap == "Reds":
            cs = ax.tricontourf(triang, data, levels=21, cmap=cmap)
        else:
            cs = ax.tricontourf(triang, data, levels=levels, cmap=cmap,
                                vmin=vmin, vmax=vmax)
        ax.set_aspect("equal")
        ax.set_xticks([0, 0.5, 1])
        ax.set_yticks([0, 0.5, 1])
        ax.set_title(title)
        fig.colorbar(cs, ax=ax, shrink=0.82)
    fig.suptitle(
        f"After {n_iter} Adam steps:  data loss {losses[-1]:.1e},  "
        f"max-rel error in $u$  {u_errs[-1]:.1e}",
        fontsize=11, y=1.02,
    )
    out = os.path.join(out_dir, "coefficient_id_fields.png")
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  -> {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu",
                        choices=["cpu", "cuda"])
    parser.add_argument("--n-iter", type=int, default=5000)
    parser.add_argument("--chara-length", type=float, default=0.04)
    parser.add_argument("--lr", type=float, default=3e-2)
    parser.add_argument("--out-dir", default=os.path.dirname(os.path.abspath(__file__)))
    args = parser.parse_args()

    result = identify(device=args.device, n_iter=args.n_iter,
                      h=args.chara_length, lr=args.lr)
    os.makedirs(args.out_dir, exist_ok=True)
    plot(result, args.out_dir)


if __name__ == "__main__":
    main()
