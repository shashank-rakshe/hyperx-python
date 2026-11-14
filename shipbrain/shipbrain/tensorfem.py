"""
TensorMesh (https://github.com/camlab-ethz/TensorMesh, Apache-2.0, CAMLab ETH Zurich; copied as written in
vendor/tensormesh): a differentiable finite-element library on PyTorch - tensorised assembly, CPU or GPU, gradients of any
result with respect to any input through the solve (autograd). Meshes come from ShipBrain's own mesher (its Gmsh
generators are never called).

  solid_static(file, ...)     linear-elastic 3D solve of a solid mesh (tetra / hexa / wedge from cad_mesh,
                              fe_edit shell_to_solid, any .inp / .bdf), supports by coordinate planes, nodal forces
                              spread over a face; on the GPU when there is one
  topology(L, H, ...)         2D topology optimisation (SIMP + MMA, TensorMesh's own example code as written) of a plate
                              region - brackets, web frames, floors, lightening-hole layouts: where material carries the
                              load, as a picture and densities
Units: any consistent set (ShipBrain: mm, N, MPa).
"""
import math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, 'vendor', 'tensormesh', 'repo')
CELL = {'tetra': 'tetra', 'hexa': 'hexahedron', 'penta': 'wedge', 'tria': 'triangle', 'quad': 'quad'}


def _tm():
    try:
        import torch  # noqa: F401
    except ImportError:
        raise RuntimeError('TensorMesh needs PyTorch: pip install torch torch-sla meshio (free; see https://pytorch.org)')
    if ROOT not in sys.path:
        sys.path.insert(0, ROOT)
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', SyntaxWarning)
        import tensormesh
    return tensormesh


def _example(name):
    d = os.path.join(ROOT, 'examples', 'inverse_design')
    if d not in sys.path:
        sys.path.insert(0, d)
    import importlib
    return importlib.import_module(name)


def device():
    import torch
    return 'cuda' if torch.cuda.is_available() else 'cpu'


def to_mesh(model, dims=(3,)):
    """ShipBrain FEModel -> TensorMesh Mesh (standard node order converted with reorder=True); returns (mesh, node ids)"""
    tm = _tm()
    import numpy as np, meshio, torch
    from .femodel import DIM
    ids = sorted(model.nodes)
    pos = {n: i for i, n in enumerate(ids)}
    by = {}
    for e in model.elems.values():
        if DIM[e['type']] in dims and e['type'] in CELL:
            by.setdefault(CELL[e['type']], []).append([pos[n] for n in e['nodes']])
    if not by:
        raise ValueError('no ' + '/'.join(f'{d}D' for d in dims) + ' elements in the model (solids: cad_mesh, or fe_edit '
                         'shell_to_solid)')
    P = np.array([model.nodes[n] for n in ids], float)
    if 2 in dims and 3 not in dims:
        P = P[:, :2]
    torch.set_default_dtype(torch.float64)
    mesh = tm.Mesh(meshio.Mesh(P, [(k, np.array(v)) for k, v in by.items()]), reorder=True)
    return mesh, ids


def _select(points, where, tol):
    """node mask from {"x": 0} / {"x": [0, 10]} / {"y": ..., "z": ...} (all must hold)"""
    import torch
    m = torch.ones(points.shape[0], dtype=torch.bool)
    for ax, v in where.items():
        k = 'xyz'.index(ax)
        if isinstance(v, (list, tuple)):
            m &= (points[:, k] >= v[0] - tol) & (points[:, k] <= v[1] + tol)
        else:
            m &= torch.abs(points[:, k] - float(v)) <= tol
    return m


def solid_static(file, fixed, loads, E=206000.0, nu=0.3, dev=None):
    """fixed: list of selectors (all 3 translations held); loads: [{"at": selector, "force": [Fx, Fy, Fz]}] - the total
    force is spread equally over the selected nodes"""
    tm = _tm()
    import torch
    from .femodel import FEModel
    from tensormesh.assemble import LinearElasticityElementAssembler
    m = FEModel.read(file)
    mesh, ids = to_mesh(m)
    dev = dev or device()
    if dev == 'cuda':
        mesh = mesh.to('cuda')
    pts = mesh.points
    span = float((pts.max(0).values - pts.min(0).values).max())
    tol = 1e-6 * span + 1e-9
    fix = torch.zeros(pts.shape[0], dtype=torch.bool, device=pts.device)
    for f in fixed:
        fix |= _select(pts.cpu(), f, tol).to(pts.device)
    if not fix.any():
        raise ValueError('the supports select no node: check the coordinates (model bounding box '
                         f"{[round(v, 3) for v in pts.min(0).values.tolist()]} - {[round(v, 3) for v in pts.max(0).values.tolist()]})")
    rhs = torch.zeros((pts.shape[0], 3), device=pts.device)
    for ld in loads:
        sel = torch.where(_select(pts.cpu(), ld['at'], tol))[0].to(pts.device)
        if len(sel) == 0:
            raise ValueError(f"the load at {ld['at']} selects no node")
        rhs[sel] += torch.tensor([float(c) for c in ld['force']], device=pts.device) / len(sel)
    K = LinearElasticityElementAssembler.from_mesh(mesh, E=float(E), nu=float(nu))()
    cond = tm.Condenser(torch.repeat_interleave(fix, 3))
    Kc, Fc = cond(K, rhs.flatten())
    u = cond.recover(Kc.solve(Fc)).reshape(-1, 3)
    mag = torch.linalg.norm(u, dim=1)
    i = int(torch.argmax(mag))
    out = {'nodes': len(ids), 'elements': mesh.n_elements, 'device': dev, 'fixed_nodes': int(fix.sum()),
           'max_displacement': round(float(mag[i]), 6), 'at_node': ids[i], 'at': [round(v, 3) for v in pts[i].tolist()],
           'displacement_max_node': [round(v, 6) for v in u[i].tolist()],
           'compliance': float(u.flatten() @ rhs.flatten())}
    out['plain_english'] = (f"TensorMesh solved {os.path.basename(file)} ({out['nodes']} nodes, {out['elements']} solid elements, "
                            f"on the {dev.upper()}): the largest displacement is {out['max_displacement']:.4g} (model length unit) "
                            f"at node {ids[i]} ({', '.join(f'{v:g}' for v in out['at'])}); {out['fixed_nodes']} nodes held.")
    return out


def _quad_mesh(L, H, nx, ny):
    tm = _tm()
    import numpy as np, meshio, torch
    xs, ys = np.linspace(0, L, nx + 1), np.linspace(0, H, ny + 1)
    P = np.array([[x, y] for y in ys for x in xs])
    q = [[j * (nx + 1) + i, j * (nx + 1) + i + 1, (j + 1) * (nx + 1) + i + 1, (j + 1) * (nx + 1) + i]
         for j in range(ny) for i in range(nx)]
    torch.set_default_dtype(torch.float64)
    return tm.Mesh(meshio.Mesh(P, [('quad', np.array(q))]), reorder=True)


def topology(L, H, nx=60, ny=30, fixed=('left',), load_at=None, force=(0.0, -1000.0), volfrac=0.5, iters=40,
             E=206000.0, nu=0.3, png=None, dev=None):
    """2D SIMP topology optimisation (TensorMesh's compliance_topology example, as written: SIMPStiffnessAssembler +
    MMAOptimizer) on a plate L x H. fixed: edges 'left' / 'right' / 'bottom' / 'top' held; load_at: [x, y] point load
    (default: bottom-right corner); force: [Fx, Fy] total. Returns the density field, the compliance history and a PNG."""
    tm = _tm()
    import numpy as np, torch
    ct = _example('compliance_topology')
    mma = _example('mma_optimizer')
    dev = dev or device()
    mesh = _quad_mesh(float(L), float(H), int(nx), int(ny)).double()
    if dev == 'cuda':
        mesh = mesh.to('cuda')
    pts = mesh.points
    tol = 1e-9 * max(L, H)
    edge = {'left': pts[:, 0] <= tol, 'right': pts[:, 0] >= L - tol, 'bottom': pts[:, 1] <= tol, 'top': pts[:, 1] >= H - tol}
    fix = torch.zeros(pts.shape[0], dtype=torch.bool, device=pts.device)
    for f in fixed:
        if f not in edge:
            raise ValueError("fixed edges: left | right | bottom | top")
        fix |= edge[f]
    cond = tm.Condenser(fix.repeat_interleave(2))
    lx, ly = load_at or (L, 0.0)
    k = int(torch.argmin((pts[:, 0] - lx) ** 2 + (pts[:, 1] - ly) ** 2))
    F = torch.zeros(pts.shape[0] * 2, dtype=mesh.dtype, device=pts.device)
    F[2 * k], F[2 * k + 1] = float(force[0]), float(force[1])
    K_asm = ct.SIMPStiffnessAssembler.from_mesh(mesh, E_max=float(E), E_min=1e-3 * float(E), nu=float(nu), penal=3.0)
    n = mesh.n_elements
    rho = torch.full((n,), float(volfrac), dtype=mesh.dtype, device=pts.device)
    opt = mma.MMAOptimizer(rho, vf=float(volfrac), move_limit=0.1, rho_min=1e-3, rho_max=1.0, use_filter=True, mesh=mesh)
    hist = []
    for _ in range(int(iters)):
        rv = rho.clone().requires_grad_(True)
        K = K_asm(mesh.points, element_data={'rho': rv})
        Kc, Fc = cond(K, F)
        u = cond.recover(Kc.solve(Fc, backend='scipy'))
        c = u @ F
        c.backward()
        opt.step(dc=rv.grad.clone(), dv=torch.ones_like(rho) / n)
        rho = opt.rho if hasattr(opt, 'rho') else rho
        hist.append(float(c.detach()))
    K = K_asm(mesh.points, element_data={'rho': torch.ones(n, dtype=mesh.dtype, device=pts.device)})
    Kc, Fc = cond(K, F)
    full = float(cond.recover(Kc.solve(Fc, backend='scipy')) @ F)
    dens = rho.detach().cpu().numpy().reshape(int(ny), int(nx))
    if png:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(8, 8 * H / L + 0.6))
        ax.imshow(1 - dens, cmap='gray', origin='lower', extent=[0, L, 0, H], vmin=0, vmax=1)
        ax.set_title(f'Material layout, {volfrac * 100:.0f} % of the plate (black = keep)')
        for f in fixed:
            xy = {'left': ([0, 0], [0, H]), 'right': ([L, L], [0, H]), 'bottom': ([0, L], [0, 0]), 'top': ([0, L], [H, H])}[f]
            ax.plot(*xy, color='tab:blue', lw=4)
        p = pts[k].tolist()
        ax.annotate('', xy=(p[0], p[1]), xytext=(p[0] - 0.08 * L * np.sign(force[0] or 0), p[1] - 0.15 * H * np.sign(force[1] or 1)),
                    arrowprops=dict(color='tab:red', width=2))
        fig.tight_layout()
        fig.savefig(png, dpi=110)
        plt.close(fig)
    keep = float((dens > 0.5).mean())
    out = {'mesh': [int(nx), int(ny)], 'device': dev, 'volume_fraction': float(dens.mean()), 'solid_share': round(keep, 3),
           'compliance_start': hist[0], 'compliance_end': hist[-1], 'compliance_full_plate': full,
           'stiffness_kept_percent': round(100 * full / hist[-1], 1), 'history': [round(h, 6) for h in hist], 'png': png,
           'density': dens.round(3).tolist()}
    out['plain_english'] = (f"Topology optimisation of a {L:g} x {H:g} plate ({nx} x {ny} elements, TensorMesh SIMP + MMA, "
                            f"{iters} steps on the {dev.upper()}), held at the {' and '.join(fixed)} edge(s), "
                            f"load {tuple(float(f) for f in force)} at ({p_str(pts[k])}): keeping {volfrac * 100:.0f} % of the "
                            f"material gives {out['stiffness_kept_percent']:.0f} % of the full plate's stiffness (compliance "
                            f"{hist[-1]:.4g} vs {full:.4g}). The dark areas are where material carries the load; the light "
                            "areas can become lightening holes or be cut away (check buckling and local strength after).")
    return out


def p_str(p):
    return ', '.join(f'{v:g}' for v in p.tolist())
