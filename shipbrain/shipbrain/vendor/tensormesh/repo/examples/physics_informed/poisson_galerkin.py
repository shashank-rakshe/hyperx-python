"""Physics-informed learning of a Poisson solution via the Galerkin residual.

Instead of *solving* the FEM linear system ``K u = F``, we represent the
solution by a small fully-connected neural network ``u_theta(x, y)`` and
train it to drive the discrete **Galerkin residual** to zero:

    -Delta u = f   in (0, 1)^2,    u = 0 on the boundary,

    minimize_theta   || K u_theta - F ||^2 ,
        u_theta = the network evaluated at the (interior) mesh nodes.

TensorMesh assembles ``K`` (Laplace stiffness) and ``F`` (consistent load
``M @ f``) once; the boundary condition is handled by ``Condenser``, which
gives the interior system ``K_ u = F_``. Because ``SparseMatrix.__matmul__``
is autograd-traced, ``loss = ||K_ u_theta - F_||^2`` back-propagates
straight into the network weights -- no linear solve, no hand-coded
adjoint. The unique minimiser of the residual is the FEM solution itself,
so the network learns to reproduce it.

Training follows the usual recipe: an Adam warm-up, then an LBFGS refine.
With a manufactured solution ``u = sin(pi x) sin(pi y)`` we can score the
result against both the analytical field and the direct FEM solve.

Writes (next to this script by default):

  * ``poisson_galerkin_loss.png``   -- residual / error vs iteration
  * ``poisson_galerkin_fields.png`` -- exact / learned / error fields

Run, after activating the tensorgalerkin venv::

    python poisson_galerkin.py
    python poisson_galerkin.py --device cuda --adam-iters 12000
"""

import argparse
import math
import os
import time
import warnings

import numpy as np
import matplotlib.pyplot as plt
from matplotlib import tri as mtri
import torch

from tensormesh import Mesh, LaplaceElementAssembler, MassElementAssembler, Condenser

warnings.filterwarnings("ignore", message="Sparse CSR tensor support is in beta state")
warnings.filterwarnings("ignore", message="float64 recommended")

torch.set_default_dtype(torch.float64)


class MLP(torch.nn.Module):
    """Coordinate network ``(x, y) -> u``: a plain tanh MLP."""

    def __init__(self, width=64, depth=3):
        super().__init__()
        layers = [torch.nn.Linear(2, width), torch.nn.Tanh()]
        for _ in range(depth - 1):
            layers += [torch.nn.Linear(width, width), torch.nn.Tanh()]
        layers += [torch.nn.Linear(width, 1)]
        self.net = torch.nn.Sequential(*layers)

    def forward(self, xy):
        return self.net(xy).squeeze(-1)


def solve(device="cpu", h=0.05, adam_iters=8000, lbfgs_iters=300,
          width=64, depth=3, lr=1e-3, seed=0, record_every=25):
    mesh = Mesh.gen_rectangle(chara_length=h).to(device)
    pts = mesh.points
    x, y = pts[:, 0], pts[:, 1]
    print(f"mesh: {mesh.n_points} nodes on {device}")

    # Manufactured solution u = sin(pi x) sin(pi y)  =>  f = 2 pi^2 u.
    u_exact = torch.sin(math.pi * x) * torch.sin(math.pi * y)
    f_nodal = 2 * math.pi ** 2 * u_exact

    # Assemble once: stiffness K, consistent load F = M @ f, interior system.
    K = LaplaceElementAssembler.from_mesh(mesh)().double()
    M = MassElementAssembler.from_mesh(mesh)().double()
    F = M @ f_nodal
    cond = Condenser(mesh.boundary_mask)
    K_, F_ = cond(K, F)
    F_sq = (F_ ** 2).sum()

    # Reference FEM solve (the residual's exact minimiser).
    u_fem = cond.recover(K_.solve(F_))

    interior = ~mesh.boundary_mask
    coords = pts[interior].clone()           # network inputs (fixed)

    torch.manual_seed(seed)
    net = MLP(width, depth).double().to(device)

    def metrics():
        with torch.no_grad():
            U = net(coords)
            rel_resid = (((K_ @ U - F_) ** 2).sum() / F_sq).item()
            u_full = cond.recover(U)
            rel_l2 = (torch.norm(u_full - u_exact) / torch.norm(u_exact)).item()
        return rel_resid, rel_l2

    hist = {"iter": [], "resid": [], "l2": []}

    def record(it):
        rr, l2 = metrics()
        hist["iter"].append(it)
        hist["resid"].append(rr)
        hist["l2"].append(l2)
        return rr, l2

    # ---- Adam warm-up.
    opt = torch.optim.Adam(net.parameters(), lr=lr)
    t0 = time.time()
    for it in range(adam_iters):
        opt.zero_grad()
        loss = ((K_ @ net(coords) - F_) ** 2).sum() / F_sq
        loss.backward()
        opt.step()
        if it % record_every == 0:
            record(it)
        if it % 2000 == 0 or it == adam_iters - 1:
            rr, l2 = metrics()
            print(f"  adam  {it:5d}  rel_resid={rr:.3e}  rel_L2={l2:.3e}")
    print(f"  adam: {adam_iters} iters in {time.time() - t0:.1f}s")

    # ---- LBFGS refine.
    if lbfgs_iters > 0:
        opt2 = torch.optim.LBFGS(net.parameters(), lr=1.0, max_iter=lbfgs_iters,
                                 history_size=50, line_search_fn="strong_wolfe")

        def closure():
            opt2.zero_grad()
            loss = ((K_ @ net(coords) - F_) ** 2).sum() / F_sq
            loss.backward()
            return loss

        opt2.step(closure)
        rr, l2 = record(adam_iters)
        print(f"  lbfgs ({lbfgs_iters} max): rel_resid={rr:.3e}  rel_L2={l2:.3e}")

    with torch.no_grad():
        u_nn = cond.recover(net(coords))
    rel_fem = (torch.norm(u_nn - u_fem) / torch.norm(u_fem)).item()
    print(f"  final: rel_L2 vs exact = {hist['l2'][-1]:.3e}, "
          f"vs FEM = {rel_fem:.3e}")

    return dict(mesh=mesh, u_exact=u_exact, u_nn=u_nn, u_fem=u_fem, hist=hist)


def _triangles(mesh):
    cells = mesh.cells
    keys = list(cells.keys())
    for key in ("triangle", "tri"):
        if key in keys:
            return cells[key].cpu().numpy()
    return cells[keys[0]].cpu().numpy()


def plot(result, out_dir):
    mesh = result["mesh"]
    hist = result["hist"]

    # ---- Figure 1: residual + error history.
    fig, ax = plt.subplots(figsize=(6.2, 4.2))
    ax.semilogy(hist["iter"], hist["resid"], color="#c0392b", linewidth=2,
                label=r"relative Galerkin residual  $\|K u_\theta - F\|^2 / \|F\|^2$")
    ax.semilogy(hist["iter"], hist["l2"], color="#2980b9", linewidth=2,
                linestyle="--",
                label=r"relative $L^2$ error vs exact  $\|u_\theta - u\|/\|u\|$")
    ax.set_xlabel("iteration  (Adam, then one LBFGS block)")
    ax.set_ylabel("relative magnitude")
    ax.set_title("Physics-informed Poisson: minimising the Galerkin residual")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="upper right", fontsize=9, framealpha=0.95)
    fig.tight_layout()
    out = os.path.join(out_dir, "poisson_galerkin_loss.png")
    fig.savefig(out, dpi=150)
    plt.close(fig)
    print(f"  -> {out}")

    # ---- Figure 2: exact / learned / error fields.
    pts = mesh.points.cpu().numpy()
    triang = mtri.Triangulation(pts[:, 0], pts[:, 1], _triangles(mesh))
    u_exact = result["u_exact"].cpu().numpy()
    u_nn = result["u_nn"].cpu().numpy()
    err = np.abs(u_nn - u_exact)

    fig, axes = plt.subplots(1, 3, figsize=(12, 3.8), constrained_layout=True)
    vmin, vmax = 0.0, 1.0
    levels = np.linspace(vmin, vmax, 21)
    panels = [
        (u_exact, r"exact $u = \sin\pi x\,\sin\pi y$", "viridis"),
        (u_nn, r"learned $u_\theta(x, y)$", "viridis"),
        (err, r"$|u_\theta - u|$", "Reds"),
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
        f"Galerkin-residual NN: rel. residual {hist['resid'][-1]:.1e},  "
        f"rel. $L^2$ error {hist['l2'][-1]:.1e}",
        fontsize=11, y=1.02,
    )
    out = os.path.join(out_dir, "poisson_galerkin_fields.png")
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  -> {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu",
                        choices=["cpu", "cuda"])
    parser.add_argument("--chara-length", type=float, default=0.05)
    parser.add_argument("--adam-iters", type=int, default=8000)
    parser.add_argument("--lbfgs-iters", type=int, default=300)
    parser.add_argument("--width", type=int, default=64)
    parser.add_argument("--depth", type=int, default=3)
    parser.add_argument("--out-dir", default=os.path.dirname(os.path.abspath(__file__)))
    args = parser.parse_args()

    result = solve(device=args.device, h=args.chara_length,
                   adam_iters=args.adam_iters, lbfgs_iters=args.lbfgs_iters,
                   width=args.width, depth=args.depth)
    os.makedirs(args.out_dir, exist_ok=True)
    plot(result, args.out_dir)


if __name__ == "__main__":
    main()
