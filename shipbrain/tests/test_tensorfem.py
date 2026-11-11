import os
import pytest

torch = pytest.importorskip('torch')
pytest.importorskip('torch_sla')
pytest.importorskip('meshio')
import numpy as np
from shipbrain import tensorfem
from shipbrain.femodel import FEModel


def _beam(path, nx=40, ny=4, nz=4, L=2000.0, B=200.0, H=200.0):
    m = FEModel()
    xs, ys, zs = np.linspace(0, L, nx + 1), np.linspace(0, B, ny + 1), np.linspace(0, H, nz + 1)
    idx = lambda i, j, k: 1 + k * (ny + 1) * (nx + 1) + j * (nx + 1) + i
    for k in range(nz + 1):
        for j in range(ny + 1):
            for i in range(nx + 1):
                m.nodes[idx(i, j, k)] = np.array([xs[i], ys[j], zs[k]])
    e = 1
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                m.elems[e] = {'type': 'hexa', 'pid': 1, 'group': '1', 'nodes': [idx(i, j, k), idx(i + 1, j, k), idx(i + 1, j + 1, k),
                              idx(i, j + 1, k), idx(i, j, k + 1), idx(i + 1, j, k + 1), idx(i + 1, j + 1, k + 1), idx(i, j + 1, k + 1)]}
                e += 1
    m.props[1] = {'kind': 'solid', 'mid': 1}
    m.mats[1] = {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9}
    m.write(path)


def test_hex_cantilever_near_beam_theory(tmp_path):
    p = str(tmp_path / 'beam.inp')
    _beam(p)
    r = tensorfem.solid_static(p, [{'x': 0}], [{'at': {'x': 2000}, 'force': [0, -1e5, 0]}], dev='cpu')
    I = 200 * 200 ** 3 / 12
    theory = 1e5 * 2000 ** 3 / (3 * 206000 * I) + 1e5 * 2000 / (5 / 6 * 200 * 200 * 206000 / 2.6)
    assert 0.9 * theory < r['max_displacement'] < 1.02 * theory          # linear hexahedra: slightly stiff, never soft
    with pytest.raises(ValueError, match='select no node'):
        tensorfem.solid_static(p, [{'x': -5}], [{'at': {'x': 2000}, 'force': [0, -1, 0]}], dev='cpu')


def test_topology_cantilever(tmp_path):
    r = tensorfem.topology(60, 30, 30, 15, iters=15, force=(0, -100), E=70e3, png=str(tmp_path / 't.png'), dev='cpu')
    assert r['history'][-1] < 0.5 * r['history'][0]                    # the optimiser lowers the compliance
    assert abs(r['volume_fraction'] - 0.5) < 0.03 and os.path.exists(r['png'])
    assert 40 < r['stiffness_kept_percent'] <= 100
