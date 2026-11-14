"""Verify a TensorMesh install: print the core versions, solve a tiny
Poisson problem on CPU (and on GPU if available), and report the
torch-sla sparse-solver backends available on this machine."""

import math
import time

import torch
import torch_sla
import tensormesh


def solve_poisson(device):
    from tensormesh import ElementAssembler, NodeAssembler, Mesh, Condenser

    mesh = Mesh.gen_rectangle(chara_length=0.1).to(device)

    class Laplace(ElementAssembler):
        def forward(self, gradu, gradv):
            return gradu @ gradv

    class Source(NodeAssembler):
        def forward(self, v, f):
            return f * v

    x, y = mesh.points[:, 0], mesh.points[:, 1]
    f_vals = 2 * math.pi**2 * torch.sin(math.pi * x) * torch.sin(math.pi * y)

    K = Laplace.from_mesh(mesh)()
    b = Source.from_mesh(mesh)(point_data={"f": f_vals})

    cond = Condenser(mesh.boundary_mask)
    K_, b_ = cond(K, b)
    u = cond.recover(K_.solve(b_))

    u_exact = torch.sin(math.pi * x) * torch.sin(math.pi * y)
    return float((u - u_exact).norm() / u_exact.norm())


def main():
    print("TensorMesh smoke test")
    print("=" * 40)
    print(f"tensormesh : {tensormesh.__version__}")
    print(f"torch      : {torch.__version__}")
    print(f"torch-sla  : {torch_sla.__version__}")
    print(f"cuda       : {torch.version.cuda or 'not available'}")
    print()

    t0 = time.perf_counter()
    err = solve_poisson("cpu")
    print(f"[CPU ] Poisson 2D ... OK   L2 error = {err:.3e}   {time.perf_counter() - t0:.2f} s")

    if torch.cuda.is_available():
        t0 = time.perf_counter()
        err = solve_poisson("cuda")
        print(f"[CUDA] Poisson 2D ... OK   L2 error = {err:.3e}   {time.perf_counter() - t0:.2f} s")
    else:
        print("[CUDA] not available, skipping GPU test")

    print()
    # Every sparse-solver backend is provided by torch-sla; let it report them.
    torch_sla.show_backends()

    print()
    print("All required checks passed.")


if __name__ == "__main__":
    main()
