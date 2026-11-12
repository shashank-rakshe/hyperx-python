import math, os, random, pytest
import numpy as np
from shipbrain import algohex as AH

CYL = None
for p in (os.path.join(os.path.dirname(AH.__file__), 'vendor', 'algohex', 'cylinder.ovm'),):
    if os.path.exists(p):
        CYL = p

# C3D8 faces, outward normals (right hand) for a positive hexahedron
FACES = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]


def write_ovm_hex(X, H, path, seed=0):
    """OpenVolumeMesh ASCII with hexahedra; faces stored with random orientation and cells listing halffaces in random order"""
    r = random.Random(seed)
    E, eid, F, fid, C = [], {}, [], {}, []

    def he(a, b):
        k = (min(a, b), max(a, b))
        if k not in eid:
            eid[k] = len(E); E.append(k)
        e = eid[k]
        return 2 * e + (0 if (a, b) == E[e] else 1)
    for h in H:
        hfs = []
        for f in FACES:
            loop = [int(h[i]) for i in f]
            key = frozenset(loop)
            if key not in fid:
                stored = loop if r.random() < 0.5 else loop[::-1]
                fid[key] = len(F)
                F.append([he(stored[k], stored[(k + 1) % 4]) for k in range(4)])
                F[-1] = (F[-1], stored)
            f_i = fid[key]
            stored = F[f_i][1]
            same = any(stored[k:] + stored[:k] == loop for k in range(4))
            hfs.append(2 * f_i + (0 if same else 1))
        r.shuffle(hfs)
        C.append(hfs)
    with open(path, 'w') as f:
        f.write(f'OVM ASCII\nVertices\n{len(X)}\n' + ''.join(f'{x[0]} {x[1]} {x[2]}\n' for x in X))
        f.write(f'Edges\n{len(E)}\n' + ''.join(f'{a} {b}\n' for a, b in E))
        f.write(f'Faces\n{len(F)}\n' + ''.join('4 ' + ' '.join(map(str, hes)) + '\n' for hes, _ in F))
        f.write(f'Polyhedra\n{len(C)}\n' + ''.join('6 ' + ' '.join(map(str, c)) + '\n' for c in C))


def grid(nx, ny, nz, h=1.0, warp=0.0):
    X = np.array([[i * h + warp * math.sin(j + k), j * h, k * h] for k in range(nz + 1) for j in range(ny + 1) for i in range(nx + 1)], float)
    n = lambda i, j, k: k * (ny + 1) * (nx + 1) + j * (nx + 1) + i
    H = [[n(i, j, k), n(i + 1, j, k), n(i + 1, j + 1, k), n(i, j + 1, k), n(i, j, k + 1), n(i + 1, j, k + 1), n(i + 1, j + 1, k + 1), n(i, j + 1, k + 1)]
         for k in range(nz) for j in range(ny) for i in range(nx)]
    return X, H


def test_tets_from_hexes_conserve_volume_and_are_positive():
    X, H = grid(3, 2, 2, 2.0, warp=0.2)
    T, v, bad = AH.tets_from_hexes(X, H)
    assert bad == 0 and len(T) == 6 * len(H)
    assert float(np.sum(v)) == pytest.approx(AH.hex_volume(X, H), rel=1e-12) == pytest.approx(6 * 4 * 4, rel=1e-12)
    # conforming: every interior triangle is shared by exactly two tets
    from collections import Counter
    tri = Counter(tuple(sorted(f)) for t in T for f in ((t[0], t[1], t[2]), (t[0], t[1], t[3]), (t[0], t[2], t[3]), (t[1], t[2], t[3])))
    assert set(tri.values()) <= {1, 2}
    boundary = sum(1 for c in tri.values() if c == 1)
    assert boundary == 2 * 2 * (3 * 2 + 3 * 2 + 2 * 2)                         # 2 triangles per boundary quad


def test_ovm_hexes_back_in_c3d8_order(tmp_path):
    from shipbrain.hexmesh import scaled_jacobian
    X, H = grid(3, 3, 2, 1.5, warp=0.3)
    for seed in range(4):
        p = str(tmp_path / f'h{seed}.ovm')
        write_ovm_hex(X, H, p, seed)
        r = AH.report(p, exact_volume=AH.hex_volume(X, H))
        assert r['hexahedra'] == len(H) and r['tetrahedra'] == 0 and r['other_cells'] == 0
        assert r['inverted'] == 0 and r['volume_error_percent'] == pytest.approx(0, abs=1e-9)
        assert r['min_scaled_jacobian'] == pytest.approx(float(np.min(scaled_jacobian(X, H))), abs=1e-4)
    inp = AH.to_inp(p, str(tmp_path / 'h.inp'))
    assert open(inp).read().count('C3D8') >= 1


@pytest.mark.skipif(CYL is None, reason='AlgoHex demo file not available')
def test_reads_algohex_demo_tet_mesh():
    r = AH.report(CYL)
    assert r['tetrahedra'] == 9764 and r['hexahedra'] == 0
    assert r['volume'] == pytest.approx(math.pi * 100 * 30, rel=0.005)          # faceted cylinder r 10, h 30


def test_prepare_from_a_part(tmp_path):
    cq = pytest.importorskip('cadquery')
    part = cq.Workplane('XY').box(60, 40, 20).faces('>Z').workplane().hole(16)
    step = str(tmp_path / 'block.step')
    cq.exporters.export(part, step)
    r = AH.prepare(step, 4.0, str(tmp_path / 'block_tets.vtk'))
    exact = 60 * 40 * 20 - math.pi * 8 ** 2 * 20
    assert r['tets'] > 1000 and r['volume'] == pytest.approx(exact, rel=0.02)
    txt = open(r['tet_file']).read()
    assert txt.startswith('# vtk DataFile Version 2.0') and f"CELLS {r['tets']}" in txt


def test_not_installed_gives_install_card(tmp_path, monkeypatch):
    monkeypatch.setattr(AH, 'exe', lambda: None)
    with pytest.raises(RuntimeError, match='not installed'):
        AH.run(str(tmp_path / 'x.vtk'), str(tmp_path / 'x.ovm'))


def test_tool_without_algohex_gives_install_card(tmp_path, monkeypatch):
    cq = pytest.importorskip('cadquery')
    from shipbrain import agent, knowledge
    monkeypatch.setattr(AH, 'exe', lambda: None)
    cq.exporters.export(cq.Workplane('XY').box(30, 20, 10), str(tmp_path / 'b.step'))
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('hex_mesh_algohex', {'file': 'b.step', 'size': 3})
    assert r.get('install', {}).get('key') == 'algohex' and os.path.exists(tmp_path / 'b_tets.vtk')


def test_orientation_comes_from_the_volume_not_one_bad_corner(tmp_path):
    from shipbrain.hexmesh import scaled_jacobian
    X, H = grid(2, 2, 1, 1.0)
    X = X.copy()
    X[H[0][6]] = X[H[0][0]] + np.array([0.15, 0.15, 0.15])         # fold one corner of hex 0 inside: positive volume, one inverted corner
    own = scaled_jacobian(X, H)
    assert own[0] < 0 and AH.hex_volume(X, [H[0]]) > 0
    for seed in range(3):
        p = str(tmp_path / f'f{seed}.ovm')
        write_ovm_hex(X, H, p, seed)
        r = AH.report(p)
        assert r['hexahedra'] == len(H) and r['inverted'] == int(np.sum(own <= 0))
        assert r['min_scaled_jacobian'] == pytest.approx(float(np.min(own)), abs=1e-4)
