"""
One FE model in memory for 1D, 2D and 3D meshes, with readers, writers, conversions and editing.

Elements: bar (1D: CBAR/B31/BEAM188), tria, quad (2D shells: CTRIA3/CQUAD4, S3/S4, SHELL181),
          tetra, penta, hexa (3D solids: CTETRA/CPENTA/CHEXA, C3D4/C3D6/C3D8, SOLID185).
Read:     Nastran .bdf/.dat/.nas (pyNastran when installed, else built-in), Abaqus/CalculiX .inp, shipbrain meshes.
Write:    Nastran .bdf (large-field GRID* = full precision), OptiStruct / HyperMesh .fem, Abaqus/CalculiX .inp, ANSYS APDL .mac (runs in MAPDL or
          PyMAPDL: mapdl.input('x.mac')), plus small driver scripts for PyMAPDL and Abaqus/CAE (python).
Convert:  2D -> 3D (shell to solid through the thickness), 3D -> 2D (solid skin), 2D -> 1D (edges to beams),
          1D -> 2D (offset beams to shell webs), quad -> tria.
Edit:     equivalence (merge coincident nodes), delete by group / box / ids, remove free nodes, mirror, translate,
          refine (split every element in 4 / 8), renumber, merge two models, offset plates, set thickness.
Repair:   remove degenerate / duplicate elements, fix inside-out solids, consistent shell normals, delete small loose
          parts; repair() does all of them in one call.
Units: whatever the input uses (shipbrain: mm, N, MPa, t/mm3).
"""
import math, os
import numpy as np

NN = {'bar': 2, 'tria': 3, 'quad': 4, 'tetra': 4, 'penta': 6, 'hexa': 8}
DIM = {'bar': 1, 'tria': 2, 'quad': 2, 'tetra': 3, 'penta': 3, 'hexa': 3}
NAS = {'bar': 'CBAR', 'tria': 'CTRIA3', 'quad': 'CQUAD4', 'tetra': 'CTETRA', 'penta': 'CPENTA', 'hexa': 'CHEXA'}
NAS_IN = {'CBAR': 'bar', 'CBEAM': 'bar', 'CROD': 'bar', 'CTRIA3': 'tria', 'CQUAD4': 'quad', 'CTETRA': 'tetra',
          'CPENTA': 'penta', 'CHEXA': 'hexa'}
INP = {'bar': 'B31', 'tria': 'S3', 'quad': 'S4', 'tetra': 'C3D4', 'penta': 'C3D6', 'hexa': 'C3D8I'}   # C3D8I: good in bending
ANSYS_ET = {'bar': 188, 'tria': 181, 'quad': 181, 'tetra': 185, 'penta': 185, 'hexa': 185}
# solid faces (0-based local node numbers), outward for the standard node orders
FACES = {'tetra': [(0, 2, 1), (0, 1, 3), (1, 2, 3), (0, 3, 2)],
         'penta': [(0, 2, 1), (3, 4, 5), (0, 1, 4, 3), (1, 2, 5, 4), (0, 3, 5, 2)],
         'hexa': [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (0, 4, 7, 3)]}


class FEModel:
    def __init__(self):
        self.nodes = {}      # id -> np.array(3)
        self.elems = {}      # id -> {'type', 'nodes', 'pid', 'group'}
        self.props = {}      # pid -> {'kind': 'shell'|'bar'|'solid', 'mid', 't' | A I1 I2 J offset orient, 'name'}
        self.mats = {}       # mid -> {'E', 'nu', 'rho', 'name'}
        self.spc = {}        # nid -> dof string
        self.loads = []      # {'type': 'pressure', 'elems': [...], 'p'} | {'type': 'force', 'node', 'dir': [x,y,z], 'value'}
        self.name = 'model'

    # ------------------------------------------------------------------ basics
    def summary(self):
        cnt = {}
        for e in self.elems.values():
            cnt[e['type']] = cnt.get(e['type'], 0) + 1
        groups = {}
        for e in self.elems.values():
            groups[e.get('group') or '-'] = groups.get(e.get('group') or '-', 0) + 1
        X = np.array(list(self.nodes.values())) if self.nodes else np.zeros((1, 3))
        return {'name': self.name, 'nodes': len(self.nodes), 'elements': len(self.elems), 'by_type': cnt,
                'by_dimension': {f'{d}D': sum(v for k, v in cnt.items() if DIM[k] == d) for d in (1, 2, 3)},
                'groups': dict(sorted(groups.items(), key=lambda kv: -kv[1])[:20]), 'properties': len(self.props),
                'materials': len(self.mats), 'constrained_nodes': len(self.spc), 'loads': len(self.loads),
                'bbox_min': X.min(0).round(3).tolist(), 'bbox_max': X.max(0).round(3).tolist()}

    def next_nid(self):
        return max(self.nodes, default=0) + 1

    def next_eid(self):
        return max(self.elems, default=0) + 1

    def add_node(self, xyz, nid=None):
        nid = nid or self.next_nid()
        self.nodes[nid] = np.asarray(xyz, float)
        return nid

    def add_elem(self, typ, nodes, pid, group='', eid=None):
        eid = eid or self.next_eid()
        self.elems[eid] = {'type': typ, 'nodes': list(nodes), 'pid': pid, 'group': group}
        return eid

    def copy(self):
        import copy
        return copy.deepcopy(self)

    # ------------------------------------------------------------------ from shipbrain meshes
    @classmethod
    def from_mesh(cls, m):
        f = cls()
        f.name = m.spec.get('name', 'model') if hasattr(m, 'spec') else 'model'
        mat = (getattr(m, 'spec', {}) or {}).get('material', {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9})
        f.mats[1] = {'E': mat['E'], 'nu': mat['nu'], 'rho': mat.get('rho', 7.85e-9), 'name': mat.get('name', 'STEEL')}
        for i, p in enumerate(m.xyz, 1):
            f.nodes[i] = np.array(p, float)
        for pid, p in m.props.items():
            f.props[pid] = dict(p, mid=1)
        for e in m.elems:
            typ = {'quad': 'quad', 'tri': 'tria', 'bar': 'bar'}[e['type']]
            f.elems[e['id']] = {'type': typ, 'nodes': list(e['nodes']), 'pid': e['pid'], 'group': e['group']}
            if typ == 'bar':
                f.props[e['pid']].setdefault('orient', list(e.get('orient', (0, 0, 1))))
        f.spc = dict(getattr(m, 'spc', {}) or {})
        from .mesh import _loads
        for ids, p in _loads(m):
            f.loads.append({'type': 'pressure', 'elems': list(ids), 'p': float(p)})
        return f

    # ================================================================== readers
    @classmethod
    def read(cls, path):
        low = path.lower()
        if low.endswith(('.bdf', '.dat', '.nas', '.fem', '.blk')):
            try:
                return cls._read_bdf_pynastran(path)
            except Exception:                          # pyNastran missing or incompatible: built-in reader
                return cls._read_bdf_own(path)
        if low.endswith('.inp'):
            return cls._read_inp(path)
        raise ValueError('read: .bdf/.dat/.nas or .inp')

    @classmethod
    def _read_bdf_pynastran(cls, path):
        if not hasattr(np, 'in1d'):                    # numpy 2.x removed in1d; pyNastran 1.4 still calls it
            np.in1d = np.isin
        from pyNastran.bdf.bdf import BDF
        b = BDF(debug=None, log=None)
        head = open(path, errors='replace').read(20000).upper()
        if 'BEGIN BULK' in head and 'CEND' not in head:   # OptiStruct .fem: case control without the Nastran CEND line
            import tempfile
            fd, tmp = tempfile.mkstemp(suffix='.bdf')
            with os.fdopen(fd, 'w') as fh:
                fh.write('CEND\n' + open(path, errors='replace').read())
            try:
                b.read_bdf(tmp, xref=False)
            finally:
                os.remove(tmp)
        else:
            b.read_bdf(path, xref=False, punch=_is_punch(path))
        f = cls()
        f.name = os.path.splitext(os.path.basename(path))[0]
        for nid, n in b.nodes.items():
            f.nodes[nid] = np.array(n.get_position() if n.cp else n.xyz, float)
        for eid, e in b.elements.items():
            t = NAS_IN.get(e.type)
            if t:
                ns = [n for n in e.node_ids if n is not None]
                if t in ('tetra', 'penta', 'hexa'):
                    ns = ns[:NN[t]]                       # corner nodes only
                f.elems[eid] = {'type': t, 'nodes': ns, 'pid': getattr(e, 'pid', 1) or 1, 'group': str(getattr(e, 'pid', ''))}
        for pid, p in b.properties.items():
            if p.type == 'PSHELL':
                f.props[pid] = {'kind': 'shell', 't': float(p.t or 0), 'mid': p.mid1 or 1, 'name': f'PSHELL {pid}'}
            elif p.type == 'PSOLID':
                f.props[pid] = {'kind': 'solid', 'mid': p.mid, 'name': f'PSOLID {pid}'}
            elif p.type == 'PBAR':
                f.props[pid] = {'kind': 'bar', 'mid': p.mid, 'A': p.A, 'I1': p.i1, 'I2': p.i2, 'J': p.j, 'name': f'PBAR {pid}'}
            elif p.type in ('PBARL', 'PBEAML', 'PBEAM'):
                try:
                    f.props[pid] = {'kind': 'bar', 'mid': p.mid, 'A': p.Area(), 'I1': p.I11(), 'I2': p.I22(), 'J': p.J(), 'name': f'{p.type} {pid}'}
                except Exception:
                    f.props[pid] = {'kind': 'bar', 'mid': p.mid, 'A': 1.0, 'I1': 1.0, 'I2': 1.0, 'J': 1.0, 'name': f'{p.type} {pid} (section not read)'}
        for mid, mt in b.materials.items():
            if mt.type == 'MAT1':
                f.mats[mid] = {'E': mt.e, 'nu': mt.nu, 'rho': mt.rho or 0.0, 'name': f'MAT1 {mid}'}
        for sid, spcs in b.spcs.items():
            for s in spcs:
                comp = str(getattr(s, 'components', '123456'))
                for nid in getattr(s, 'node_ids', getattr(s, 'nodes', [])):
                    f.spc[nid] = ''.join(sorted(set(f.spc.get(nid, '') + comp)))
        press = {}
        for sid, lds in b.loads.items():
            for l in lds:
                if l.type == 'PLOAD4':
                    ids = list(l.eids) if hasattr(l, 'eids') else [l.eid]
                    press.setdefault(-float(l.pressures[0]), []).extend(ids)
                elif l.type == 'FORCE':
                    f.loads.append({'type': 'force', 'node': l.node, 'dir': list(map(float, l.xyz)), 'value': float(l.mag)})
        f.loads = [{'type': 'pressure', 'elems': ids, 'p': p} for p, ids in press.items()] + f.loads
        return f

    @classmethod
    def _read_bdf_own(cls, path):
        from .meshcheck import read_bdf
        nodes, elems, groups = read_bdf(path)
        f = cls()
        f.name = os.path.splitext(os.path.basename(path))[0]
        f.nodes = {k: np.array(v, float) for k, v in nodes.items()}
        for i, (e, g) in enumerate(zip(elems, groups), 1):
            f.elems[i] = {'type': 'quad' if len(e) == 4 else 'tria', 'nodes': e, 'pid': int(g) if str(g).isdigit() else 1, 'group': g}
        return f

    @classmethod
    def _read_inp(cls, path):
        f = cls()
        f.name = os.path.splitext(os.path.basename(path))[0]
        typemap = {'S4': 'quad', 'S4R': 'quad', 'S3': 'tria', 'S3R': 'tria', 'B31': 'bar', 'B32': 'bar', 'T3D2': 'bar',
                   'C3D8': 'hexa', 'C3D8R': 'hexa', 'C3D8I': 'hexa', 'C3D4': 'tetra', 'C3D6': 'penta', 'C3D10': 'tetra', 'C3D20': 'hexa'}
        mode, etype, eset, sets, sections, mat, mats_by_name = None, None, '', {}, [], None, {}
        cont = []
        pipe_notes = {}                                   # ** SHIPBRAIN PIPE ELSET=P1 OD=114.3 WALL=6.02
        for raw in open(path, errors='replace'):
            s = raw.strip()
            if s.upper().startswith('** SHIPBRAIN PIPE'):
                kv = dict(x.split('=', 1) for x in s.split()[3:] if '=' in x)
                try:
                    pipe_notes[kv['ELSET'].upper()] = (float(kv['OD']), float(kv['WALL']))
                except (KeyError, ValueError):
                    pass
                continue
            if not s or s.startswith('**'):
                continue
            if s.startswith('*'):
                u = s.upper().replace(' ', '')
                kw = u.split(',')[0]
                opts = dict(x.split('=', 1) for x in u.split(',')[1:] if '=' in x)
                mode = None
                if kw == '*NODE':
                    mode = 'node'
                elif kw == '*ELEMENT':
                    etype = typemap.get(opts.get('TYPE', ''))
                    eset = opts.get('ELSET', opts.get('TYPE', ''))
                    mode = 'elem' if etype else None
                elif kw == '*ELSET':
                    eset = opts['ELSET']
                    sets.setdefault(eset, [])
                    mode = 'elset_gen' if 'GENERATE' in u else 'elset'
                elif kw == '*MATERIAL':
                    mat = opts.get('NAME', 'MAT')
                    mats_by_name[mat] = {'E': 0.0, 'nu': 0.3, 'rho': 0.0, 'name': mat}
                elif kw == '*ELASTIC':
                    mode = 'elastic'
                elif kw == '*DENSITY':
                    mode = 'density'
                elif kw in ('*SHELLSECTION', '*SOLIDSECTION', '*BEAMSECTION'):
                    sections.append({'kind': {'*SHELLSECTION': 'shell', '*SOLIDSECTION': 'solid', '*BEAMSECTION': 'bar'}[kw],
                                     'elset': opts.get('ELSET'), 'mat': opts.get('MATERIAL'), 'section': opts.get('SECTION'), 'data': None})
                    mode = 'section'
                elif kw == '*BOUNDARY':
                    mode = 'bc'
                elif kw == '*DLOAD':
                    mode = 'dload'
                elif kw == '*CLOAD':
                    mode = 'cload'
                continue
            p = [x.strip() for x in s.split(',') if x.strip() != '']
            if mode == 'node':
                f.nodes[int(p[0])] = np.array([float(x) for x in (p[1:4] + ['0', '0'])[:3]])
            elif mode == 'elem':
                cont += [int(x) for x in p]
                if s.endswith(','):
                    continue
                eid, ns = cont[0], cont[1:]
                cont = []
                f.elems[eid] = {'type': etype, 'nodes': ns[:NN[etype]], 'pid': 0, 'group': eset}
                sets.setdefault(eset, []).append(eid)
            elif mode == 'elset':
                sets[eset] += [int(x) for x in p if x.isdigit()]
            elif mode == 'elset_gen':
                a, b, c = (int(x) for x in (p + ['1'])[:3])
                sets[eset] += list(range(a, b + 1, c))
            elif mode == 'elastic' and mat:
                mats_by_name[mat].update(E=float(p[0]), nu=float(p[1]) if len(p) > 1 else 0.3)
            elif mode == 'density' and mat:
                mats_by_name[mat]['rho'] = float(p[0])
            elif mode == 'section' and sections[-1]['data'] is None:
                sections[-1]['data'] = [float(x) for x in p if _isnum(x)]
            elif mode == 'bc':
                nid = p[0]
                ids = [int(nid)] if nid.isdigit() else []
                if len(p) >= 2 and p[1].isdigit():
                    a = int(p[1])
                    b = int(p[2]) if len(p) > 2 and p[2].isdigit() else a
                    dof = ''.join(str(k) for k in range(a, b + 1))
                else:
                    dof = {'ENCASTRE': '123456', 'PINNED': '123'}.get(p[1].upper() if len(p) > 1 else '', '123456')
                for i in ids:
                    f.spc[i] = ''.join(sorted(set(f.spc.get(i, '') + dof)))
            elif mode == 'dload' and len(p) >= 3 and p[1].upper().startswith('P'):
                tgt = sets.get(p[0].upper(), [int(p[0])] if p[0].isdigit() else [])
                f.loads.append({'type': 'pressure', 'elems': list(tgt), 'p': -float(p[2])})
            elif mode == 'cload' and len(p) >= 3 and p[0].isdigit():
                d = [0.0, 0.0, 0.0]
                k = int(p[1])
                if k <= 3:
                    d[k - 1] = 1.0
                    f.loads.append({'type': 'force', 'node': int(p[0]), 'dir': d, 'value': float(p[2])})
        mids = {}
        for k, (n, mt) in enumerate(mats_by_name.items(), 1):
            f.mats[k] = mt
            mids[n] = k
        for pid, sec in enumerate(sections, 1):
            pr = {'kind': sec['kind'], 'mid': mids.get(sec['mat'], 1), 'name': sec['elset'] or f'SEC{pid}'}
            if sec['kind'] == 'shell':
                pr['t'] = (sec['data'] or [1.0])[0]
            elif sec['kind'] == 'bar':
                d = sec['data'] or [1.0, 1.0]
                pipe = pipe_notes.get((sec['elset'] or '').upper())
                if pipe or ((sec['section'] or '').startswith('PIPE') and len(d) >= 2):    # ShipBrain pipe note / PIPE section
                    D, t = pipe if pipe else (2 * d[0], d[1])
                    di = max(D - 2 * t, 0.0)
                    I = math.pi / 64 * (D ** 4 - di ** 4)
                    pr.update(A=math.pi / 4 * (D ** 2 - di ** 2), I1=I, I2=I, J=2 * I, od=D, wall=t)
                elif (sec['section'] or '').startswith('RECT') and len(d) >= 2:
                    h, b = d[0], d[1]
                    pr.update(A=b * h, I1=b * h ** 3 / 12, I2=h * b ** 3 / 12, J=b * h ** 3 / 3 if b > h else h * b ** 3 / 3)
                else:
                    pr.update(A=d[0], I1=d[1] if len(d) > 1 else 1.0, I2=d[3] if len(d) > 3 else 1.0, J=d[4] if len(d) > 4 else 1.0)
            f.props[pid] = pr
            for eid in sets.get((sec['elset'] or '').upper(), []):
                if eid in f.elems:
                    f.elems[eid]['pid'] = pid
        if not f.mats:
            f.mats[1] = {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9, 'name': 'STEEL'}
        for e in f.elems.values():
            if not e['pid']:
                kind = 'bar' if e['type'] == 'bar' else ('shell' if DIM[e['type']] == 2 else 'solid')
                pid = next((k for k, p in f.props.items() if p['kind'] == kind and p['name'] == 'DEFAULT'), None)
                if pid is None:
                    pid = max(f.props, default=0) + 1
                    f.props[pid] = {'kind': kind, 'mid': 1, 'name': 'DEFAULT', 't': 1.0, 'A': 1.0, 'I1': 1.0, 'I2': 1.0, 'J': 1.0}
                e['pid'] = pid
        return f

    # ================================================================== writers
    def write(self, path):
        low = path.lower()
        if low.endswith(('.bdf', '.dat', '.nas')):
            return self.write_bdf(path)
        if low.endswith('.inp'):
            return self.write_inp(path)
        if low.endswith(('.mac', '.apdl', '.cdb.mac')):
            return self.write_apdl(path)
        if low.endswith('.fem'):
            return self.write_fem(path)
        raise ValueError('write: .bdf / .inp / .mac / .fem')

    def write_fem(self, path):
        """OptiStruct / HyperMesh input: the same bulk data as the .bdf, without the Nastran-only executive lines
        (an OptiStruct subcase with SPC and LOAD is a linear static run)"""
        self.write_bdf(path)
        L = [l for l in open(path).read().splitlines() if l.strip() not in ('SOL 101', 'CEND') and not l.startswith('PARAM   POST')]
        L[0] = f'$ shipbrain FEModel: {self.name} (OptiStruct .fem; HyperMesh opens it with the OptiStruct profile)'
        open(path, 'w').write('\n'.join(L) + '\n')
        return path

    def _mat(self, mid):
        return self.mats.get(mid) or next(iter(self.mats.values()), {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9})

    def write_bdf(self, path):
        from .mesh import _card
        L = [f'$ shipbrain FEModel: {self.name}', 'SOL 101', 'CEND', f'TITLE = {self.name}', 'SUBCASE 1']
        if self.spc:
            L.append('  SPC = 1')
        if self.loads:
            L.append('  LOAD = 1')
        L += ['  DISPLACEMENT = ALL', '  STRESS = ALL', 'BEGIN BULK', 'PARAM   POST    -1']
        for mid, m in sorted(self.mats.items()):
            L.append(_card('MAT1', mid, float(m['E']), '', float(m['nu']), float(m.get('rho', 0.0))))
        used = {e['pid'] for e in self.elems.values()}
        for pid, p in sorted(self.props.items()):
            if pid not in used:
                continue
            L.append(f"$ {p.get('name', '')}")
            if p['kind'] == 'shell':
                L.append(_card('PSHELL', pid, p.get('mid', 1), float(p['t']), p.get('mid', 1), '', p.get('mid', 1)))
            elif p['kind'] == 'solid':
                L.append(_card('PSOLID', pid, p.get('mid', 1)))
            else:
                L.append(_card('PBAR', pid, p.get('mid', 1), float(p['A']), float(p['I1']), float(p['I2']), float(p['J'])))
        for nid, x in sorted(self.nodes.items()):
            L.append(_grid16(nid, x))
        for eid, e in sorted(self.elems.items()):
            if e['type'] == 'bar':
                p = self.props.get(e['pid'], {})
                o = p.get('orient') or _bar_orient(self.nodes[e['nodes'][0]], self.nodes[e['nodes'][1]])
                w = p.get('offset_vec') or ([0.0, 0.0, float(p['offset'])] if p.get('offset') else None)
                L.append(_card('CBAR', eid, e['pid'], *e['nodes'], *map(float, o), *([''] * 3 + list(map(float, w)) * 2 if w else [])))
            else:
                L.append(_card(NAS[e['type']], eid, e['pid'], *e['nodes']))
        by = {}
        for nid, d in self.spc.items():
            by.setdefault(d, []).append(nid)
        for d, ids in sorted(by.items()):
            for k in range(0, len(ids), 6):
                L.append(_card('SPC1', 1, d, *sorted(ids)[k:k + 6]))
        for ld in self.loads:
            if ld['type'] == 'pressure':
                for eid in ld['elems']:
                    if eid in self.elems and DIM[self.elems[eid]['type']] == 2:
                        L.append(_card('PLOAD4', 1, eid, -float(ld['p'])))
            elif ld['type'] == 'force':
                L.append(_card('FORCE', 1, ld['node'], 0, float(ld['value']), *map(float, ld['dir'])))
        L.append('ENDDATA')
        open(path, 'w').write('\n'.join(L) + '\n')
        return path

    def write_inp(self, path):
        L = [f'** shipbrain FEModel: {self.name}', '*HEADING', self.name, '*NODE']
        L += [f'{nid}, {x[0]:.6f}, {x[1]:.6f}, {x[2]:.6f}' for nid, x in sorted(self.nodes.items())]
        by = {}
        for eid, e in sorted(self.elems.items()):
            by.setdefault((e['pid'], e['type']), []).append(eid)
        for (pid, typ), ids in sorted(by.items()):
            L.append(f'*ELEMENT, TYPE={INP[typ]}, ELSET=P{pid}')
            L += [f"{eid}, " + ', '.join(map(str, self.elems[eid]['nodes'])) for eid in ids]
        for mid, m in sorted(self.mats.items()):
            L += [f'*MATERIAL, NAME=M{mid}', '*ELASTIC', f"{m['E']}, {m['nu']}", '*DENSITY', f"{m.get('rho', 0.0) or 1e-12}"]
        for pid in sorted({k[0] for k in by}):
            p = self.props.get(pid, {'kind': 'shell', 't': 1.0, 'mid': 1})
            mid = p.get('mid', 1)
            if p['kind'] == 'shell':
                L += [f'*SHELL SECTION, ELSET=P{pid}, MATERIAL=M{mid}', f"{p['t']}"]
            elif p['kind'] == 'solid':
                L += [f'*SOLID SECTION, ELSET=P{pid}, MATERIAL=M{mid}', '']
            else:
                if p.get('od') and p.get('wall'):               # CalculiX's PIPE needs B32R: keep B31 + RECT, remember the pipe
                    L.append(f"** SHIPBRAIN PIPE ELSET=P{pid} OD={p['od']:.5f} WALL={p['wall']:.5f}")
                h = math.sqrt(12 * p['I1'] / p['A'])
                L += [f'*BEAM SECTION, ELSET=P{pid}, MATERIAL=M{mid}, SECTION=RECT', f"{h:.5f}, {p['A'] / h:.5f}",
                      ', '.join(f'{v:.4f}' for v in (p.get('orient') or [0, 0, 1]))]
        for k, ld in enumerate([l for l in self.loads if l['type'] == 'pressure'], 1):
            ids = [e for e in ld['elems'] if e in self.elems]
            L.append(f'*ELSET, ELSET=LOAD{k}')
            L += [', '.join(map(str, ids[j:j + 16])) for j in range(0, len(ids), 16)]
        L += ['*STEP', '*STATIC']
        if self.spc:
            L.append('*BOUNDARY')
            for nid, d in sorted(self.spc.items()):
                for a, b in _runs(sorted(int(c) for c in d)):
                    L.append(f'{nid}, {a}, {b}')
        pk = 0
        for ld in self.loads:
            if ld['type'] == 'pressure':
                pk += 1
                L += ['*DLOAD', f"LOAD{pk}, P, {-float(ld['p'])}"]
            else:
                L.append('*CLOAD')
                L += [f"{ld['node']}, {k + 1}, {ld['value'] * c}" for k, c in enumerate(ld['dir']) if c]
        L += ['*NODE FILE', 'U', '*EL FILE', 'S', '*END STEP']
        open(path, 'w').write('\n'.join(L) + '\n')
        return path

    def write_apdl(self, path):
        """ANSYS MAPDL input (runs as-is in MAPDL: /INPUT, or PyMAPDL: mapdl.input(path))"""
        L = [f'! shipbrain FEModel: {self.name}', '/PREP7']
        types = {}
        for e in self.elems.values():
            types.setdefault(e['type'], len(types) + 1)
        for typ, k in types.items():
            L.append(f'ET,{k},{ANSYS_ET[typ]}')
        for mid, m in sorted(self.mats.items()):
            L += [f"MP,EX,{mid},{m['E']}", f"MP,PRXY,{mid},{m['nu']}", f"MP,DENS,{mid},{m.get('rho', 0.0)}"]
        for pid, p in sorted(self.props.items()):
            if p['kind'] == 'shell':
                L += [f'SECTYPE,{pid},SHELL', f"SECDATA,{p['t']},{p.get('mid', 1)}"]
            elif p['kind'] == 'bar':
                h = math.sqrt(12 * p['I1'] / p['A'])
                L += [f'SECTYPE,{pid},BEAM,RECT', f"SECDATA,{p['A'] / h:.5f},{h:.5f}"]
        for nid, x in sorted(self.nodes.items()):
            L.append(f'N,{nid},{x[0]:.6f},{x[1]:.6f},{x[2]:.6f}')
        if any(e['type'] == 'bar' for e in self.elems.values()):
            orient = self.next_nid() + 1000                       # beam orientation node
            L.append(f'N,{orient},0,0,1.0e9')
        for eid, e in sorted(self.elems.items()):
            p = self.props.get(e['pid'], {'mid': 1})
            L += [f"TYPE,{types[e['type']]}", f"MAT,{p.get('mid', 1)}", f"SECNUM,{e['pid']}" if p.get('kind') != 'solid' else 'SECNUM,0']
            ns = list(e['nodes'])
            if e['type'] == 'tria':
                ns = [ns[0], ns[1], ns[2], ns[2]]
            elif e['type'] == 'tetra':
                ns = [ns[0], ns[1], ns[2], ns[2], ns[3], ns[3], ns[3], ns[3]]
            elif e['type'] == 'penta':
                ns = [ns[0], ns[1], ns[2], ns[2], ns[3], ns[4], ns[5], ns[5]]
            elif e['type'] == 'bar':
                ns = ns + [orient]
            if len(ns) > 8:
                L.append(f'EN,{eid},' + ','.join(map(str, ns[:8])))
                L.append('EMORE,' + ','.join(map(str, ns[8:])))
            else:
                L.append(f'EN,{eid},' + ','.join(map(str, ns)))
        names = {'1': 'UX', '2': 'UY', '3': 'UZ', '4': 'ROTX', '5': 'ROTY', '6': 'ROTZ'}
        for nid, d in sorted(self.spc.items()):
            L += [f'D,{nid},{names[c]},0' for c in d]
        for ld in self.loads:
            if ld['type'] == 'pressure':
                for eid in ld['elems']:
                    if eid in self.elems and DIM[self.elems[eid]['type']] == 2:
                        L.append(f"SFE,{eid},1,PRES,,{ld['p']}")      # shell face 1 = top: positive pushes against the normal
            else:
                L += [f"F,{ld['node']},{'FX FY FZ'.split()[k]},{ld['value'] * c}" for k, c in enumerate(ld['dir']) if c]
        L += ['FINISH', '/SOLU', 'ANTYPE,STATIC', 'SOLVE', 'FINISH']
        open(path, 'w').write('\n'.join(L) + '\n')
        return path

    def write_drivers(self, base):
        """small scripts that run the model in PyMAPDL and in Abaqus/CAE (both need their own licensed software)"""
        b = os.path.basename(base)
        pymapdl = (f'# run in Python with ANSYS installed:  pip install ansys-mapdl-core ; python {b}_pymapdl.py\n'
                   'from ansys.mapdl.core import launch_mapdl\n'
                   'mapdl = launch_mapdl()\n'
                   f'mapdl.input("{b}.mac")\n'
                   'mapdl.post1()\n'
                   'print("max |U| =", max(abs(mapdl.post_processing.nodal_displacement("NORM"))))\n'
                   'mapdl.exit()\n')
        abaqus = (f'# run with:  abaqus cae noGUI={b}_abaqus.py\n'
                  'from abaqus import mdb\nfrom abaqusConstants import *\nimport job\n'
                  f'mdb.ModelFromInputFile(name="{b}", inputFileName="{b}.inp")\n'
                  f'j = mdb.Job(name="{b}_job", model="{b}")\nj.submit()\nj.waitForCompletion()\n')
        open(base + '_pymapdl.py', 'w').write(pymapdl)
        open(base + '_abaqus.py', 'w').write(abaqus)
        return [base + '_pymapdl.py', base + '_abaqus.py']

    # ================================================================== editing
    def equivalence(self, tol=0.01):
        """merge nodes closer than tol (keeps the lowest id)"""
        cell, grid, rep = tol * 4, {}, {}
        for nid in sorted(self.nodes):
            p = self.nodes[nid]
            k = tuple(np.floor(p / cell).astype(int))
            hit = None
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for dz in (-1, 0, 1):
                        for j in grid.get((k[0] + dx, k[1] + dy, k[2] + dz), ()):
                            if hit is None and np.linalg.norm(self.nodes[j] - p) <= tol:
                                hit = j
            if hit is None:
                grid.setdefault(k, []).append(nid)
            else:
                rep[nid] = hit
        for e in self.elems.values():
            e['nodes'] = [rep.get(n, n) for n in e['nodes']]
        for a, b in rep.items():
            if a in self.spc:
                self.spc[b] = ''.join(sorted(set(self.spc.get(b, '') + self.spc.pop(a))))
            del self.nodes[a]
        for ld in self.loads:
            if ld['type'] == 'force':
                ld['node'] = rep.get(ld['node'], ld['node'])
        for e in self.elems.values():                      # quad with one collapsed edge -> triangle
            if e['type'] == 'quad' and _collapsed_quad(e['nodes']):
                e['type'], e['nodes'] = 'tria', _collapsed_quad(e['nodes'])
        bad = [eid for eid, e in self.elems.items() if len(set(e['nodes'])) < len(e['nodes']) and e['type'] in ('bar', 'quad', 'hexa')]
        for eid in bad:                                    # collapsed elements
            del self.elems[eid]
        return {'merged_nodes': len(rep), 'collapsed_elements_removed': len(bad)}

    def remove_free_nodes(self):
        used = {n for e in self.elems.values() for n in e['nodes']} | {l['node'] for l in self.loads if l['type'] == 'force'}
        free = [n for n in self.nodes if n not in used]
        for n in free:
            del self.nodes[n]
            self.spc.pop(n, None)
        return {'removed_free_nodes': len(free)}

    def _drop_elems(self, kill):
        for eid in kill:
            self.elems.pop(eid, None)
        for ld in self.loads:
            if ld['type'] == 'pressure':
                ld['elems'] = [e for e in ld['elems'] if e in self.elems]

    def remove_degenerate(self, tol=1e-6):
        """remove zero-length bars, zero-area shells, zero-volume solids, collapsed and duplicate elements;
        solids with negative volume (inside-out node order) are turned the right way"""
        kill, seen, flipped = [], {}, 0
        for eid in sorted(self.elems):
            e = self.elems[eid]
            ns = e['nodes']
            if any(n not in self.nodes for n in ns):
                kill.append(eid)
                continue
            P = [self.nodes[n] for n in ns]
            d = DIM[e['type']]
            if d == 1:
                size = np.linalg.norm(P[1] - P[0])
            elif d == 2:
                c = np.mean(P, 0)
                size = 0.5 * np.linalg.norm(sum(np.cross(P[k] - c, P[(k + 1) % len(P)] - c) for k in range(len(P))))
            else:
                size = _solid_volume(e['type'], P)
                if size < -tol:
                    e['nodes'] = _reverse(e['type'], ns)
                    flipped += 1
                    size = -size
            if e['type'] == 'quad' and _collapsed_quad(ns) and abs(size) > tol:
                e['type'], e['nodes'] = 'tria', _collapsed_quad(ns)          # quad with one collapsed edge -> triangle
                ns = e['nodes']
            if len(set(ns)) < len(ns) or abs(size) <= tol:
                kill.append(eid)
                continue
            key = (DIM[e['type']], tuple(sorted(ns)))
            if key in seen:
                kill.append(eid)                        # same nodes as an earlier element = duplicate
            else:
                seen[key] = eid
        self._drop_elems(kill)
        return {'degenerate_or_duplicate_removed': len(kill), 'inverted_solids_fixed': flipped, **self.remove_free_nodes()}

    def orient_normals(self, ref=None):
        """make neighbouring shell elements point the same way (pressure and top/bottom stress need it).
        Walks each connected plate field over edges shared by exactly two shells; the first element of each field
        (or the one nearest ref [x,y,z] direction) sets the side."""
        sh = [eid for eid, e in self.elems.items() if DIM[e['type']] == 2]
        edge = {}
        for eid in sh:
            ns = self.elems[eid]['nodes']
            for k in range(len(ns)):
                edge.setdefault(frozenset((ns[k], ns[(k + 1) % len(ns)])), []).append(eid)

        def dirn(eid, a, b):                         # +1 if the element runs a->b along its node loop
            ns = self.elems[eid]['nodes']
            i = ns.index(a)
            return 1 if ns[(i + 1) % len(ns)] == b else -1

        def normal(eid):
            P = [self.nodes[n] for n in self.elems[eid]['nodes']]
            c = np.mean(P, 0)
            return sum(np.cross(P[k] - c, P[(k + 1) % len(P)] - c) for k in range(len(P)))
        done, flipped, fields = set(), 0, 0
        for start in sh:
            if start in done:
                continue
            fields += 1
            if ref is not None and normal(start) @ np.asarray(ref, float) < 0:
                self.elems[start]['nodes'] = _reverse(self.elems[start]['type'], self.elems[start]['nodes'])
                flipped += 1
            done.add(start)
            stack = [start]
            while stack:
                eid = stack.pop()
                ns = self.elems[eid]['nodes']
                for k in range(len(ns)):
                    a, b = ns[k], ns[(k + 1) % len(ns)]
                    nb = edge.get(frozenset((a, b)), [])
                    if len(nb) != 2:                     # free edge or plate joint (3+ plates): stop there
                        continue
                    o = nb[0] if nb[1] == eid else nb[1]
                    if o in done:
                        continue
                    if dirn(o, a, b) == 1:               # neighbour runs the shared edge the same way -> opposite normal
                        self.elems[o]['nodes'] = _reverse(self.elems[o]['type'], self.elems[o]['nodes'])
                        flipped += 1
                    done.add(o)
                    stack.append(o)
        return {'shell_fields': fields, 'shells_flipped': flipped}

    def remove_small_parts(self, min_elements=5):
        """delete loose pieces (not connected to the main model) that have fewer than min_elements elements"""
        parent = {n: n for n in self.nodes}

        def find(a):
            while parent[a] != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a
        for e in self.elems.values():
            r = find(e['nodes'][0])
            for n in e['nodes'][1:]:
                parent[find(n)] = r
        parts = {}
        for eid, e in self.elems.items():
            parts.setdefault(find(e['nodes'][0]), []).append(eid)
        if len(parts) < 2:
            return {'parts': len(parts), 'small_parts_removed': 0}
        biggest = max(len(v) for v in parts.values())
        kill = [eid for v in parts.values() if len(v) < min_elements and len(v) < biggest for eid in v]
        self._drop_elems(kill)
        return {'parts': len(parts), 'small_parts_removed': sum(1 for v in parts.values() if len(v) < min_elements and len(v) < biggest),
                'elements_removed': len(kill), **self.remove_free_nodes()}

    def repair(self, tol=0.01, min_elements=5):
        """one-call mesh repair: merge coincident nodes, remove degenerate / duplicate elements, fix inside-out solids,
        make shell normals consistent, delete small loose parts and free nodes"""
        out = {'equivalence': self.equivalence(tol), 'degenerate': self.remove_degenerate(),
               'normals': self.orient_normals(), 'small_parts': self.remove_small_parts(min_elements)}
        out['free_nodes'] = self.remove_free_nodes()
        return out

    def delete(self, group=None, box=None, ids=None, types=None):
        """delete elements by group name, box [[xmin,ymin,zmin],[xmax,ymax,zmax]] (centroid inside), ids or types"""
        kill = set(ids or [])
        for eid, e in self.elems.items():
            if group and str(e.get('group')) == str(group):
                kill.add(eid)
            if types and e['type'] in types:
                kill.add(eid)
            if box:
                c = np.mean([self.nodes[n] for n in e['nodes']], 0)
                if np.all(c >= np.array(box[0])) and np.all(c <= np.array(box[1])):
                    kill.add(eid)
        for eid in kill:
            self.elems.pop(eid, None)
        for ld in self.loads:
            if ld['type'] == 'pressure':
                ld['elems'] = [e for e in ld['elems'] if e in self.elems]
        return {'deleted_elements': len(kill), **self.remove_free_nodes()}

    def translate(self, d):
        d = np.asarray(d, float)
        for k in self.nodes:
            self.nodes[k] = self.nodes[k] + d
        return {'moved_nodes': len(self.nodes)}

    def mirror(self, axis='y', value=0.0, keep=True, tol=0.01):
        """mirror about the plane axis=value (e.g. centre line y=0 -> full breadth model); keep=True keeps the original"""
        k = 'xyz'.index(axis)
        off = max(self.nodes, default=0)
        eoff = max(self.elems, default=0)
        src_nodes, src_elems = dict(self.nodes), dict(self.elems)
        if not keep:
            self.nodes, self.elems = {}, {}
            off = eoff = 0
        for nid, p in src_nodes.items():
            q = p.copy()
            q[k] = 2 * value - q[k]
            self.nodes[nid + off] = q
            if nid in self.spc and keep:
                self.spc[nid + off] = self.spc[nid]
        for eid, e in src_elems.items():
            ns = [n + off for n in e['nodes']]
            ns = _reverse(e['type'], ns)                       # keep a right-handed node order
            self.elems[eid + eoff] = {**e, 'nodes': ns}
        new_loads = []
        for ld in self.loads:
            if ld['type'] == 'pressure':
                new_loads.append({**ld, 'elems': [x + eoff for x in ld['elems']]})
        self.loads += new_loads if keep else []
        r = self.equivalence(tol) if keep else {}
        return {'mirrored_about': f'{axis}={value}', 'nodes': len(self.nodes), 'elements': len(self.elems), **r}

    def refine(self):
        """split every bar in 2, tria in 4, quad in 4, hexa in 8 (mid-nodes shared between neighbours)"""
        mids = {}
        def mid(*ns):
            key = tuple(sorted(ns))
            if key not in mids:
                mids[key] = self.add_node(np.mean([self.nodes[n] for n in ns], 0))
                common = set('123456')                     # a new node keeps the supports all its parents share
                for n in ns:
                    common &= set(self.spc.get(n, ''))
                if common:
                    self.spc[mids[key]] = ''.join(sorted(common))
            return mids[key]
        old = dict(self.elems)
        self.elems, new_ids, n0 = {}, {}, 0
        for eid, e in old.items():
            n, t, out = e['nodes'], e['type'], []
            if t == 'bar':
                m = mid(n[0], n[1])
                out = [[n[0], m], [m, n[1]]]
            elif t == 'tria':
                a, b, c = n
                ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
                out = [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]]
            elif t == 'quad':
                a, b, c, d = n
                ab, bc, cd, da, o = mid(a, b), mid(b, c), mid(c, d), mid(d, a), mid(a, b, c, d)
                out = [[a, ab, o, da], [ab, b, bc, o], [o, bc, c, cd], [da, o, cd, d]]
            elif t == 'hexa':
                v = n
                # corner sub-hexas via trilinear lattice
                lat = {}
                for i, (x, y, z) in enumerate([(0, 0, 0), (2, 0, 0), (2, 2, 0), (0, 2, 0), (0, 0, 2), (2, 0, 2), (2, 2, 2), (0, 2, 2)]):
                    lat[(x, y, z)] = v[i]
                corner = {(0, 0, 0): 0, (2, 0, 0): 1, (2, 2, 0): 2, (0, 2, 0): 3, (0, 0, 2): 4, (2, 0, 2): 5, (2, 2, 2): 6, (0, 2, 2): 7}
                def L(x, y, z):
                    if (x, y, z) in lat:
                        return lat[(x, y, z)]
                    cs = [corner[(cx, cy, cz)] for (cx, cy, cz) in corner if (x == 1 or cx == x) and (y == 1 or cy == y) and (z == 1 or cz == z)]
                    lat[(x, y, z)] = mid(*[v[i] for i in cs])
                    return lat[(x, y, z)]
                for x in (0, 1):
                    for y in (0, 1):
                        for z in (0, 1):
                            out.append([L(x, y, z), L(x + 1, y, z), L(x + 1, y + 1, z), L(x, y + 1, z),
                                        L(x, y, z + 1), L(x + 1, y, z + 1), L(x + 1, y + 1, z + 1), L(x, y + 1, z + 1)])
            else:
                out = [n]                                      # tetra / penta: kept as they are
            new_ids[eid] = []
            for ns in out:
                n0 += 1
                self.elems[n0] = {**e, 'nodes': ns}
                new_ids[eid].append(n0)
        for ld in self.loads:
            if ld['type'] == 'pressure':
                ld['elems'] = [k for x in ld['elems'] for k in new_ids.get(x, [])]
        return {'nodes': len(self.nodes), 'elements': len(self.elems)}

    def renumber(self, node_start=1, elem_start=1):
        nmap = {old: node_start + i for i, old in enumerate(sorted(self.nodes))}
        emap = {old: elem_start + i for i, old in enumerate(sorted(self.elems))}
        self.nodes = {nmap[k]: v for k, v in self.nodes.items()}
        self.elems = {emap[k]: {**e, 'nodes': [nmap[n] for n in e['nodes']]} for k, e in self.elems.items()}
        self.spc = {nmap[k]: v for k, v in self.spc.items() if k in nmap}
        for ld in self.loads:
            if ld['type'] == 'pressure':
                ld['elems'] = [emap[x] for x in ld['elems'] if x in emap]
            else:
                ld['node'] = nmap.get(ld['node'], ld['node'])
        return {'nodes': f'{node_start}..{node_start + len(nmap) - 1}', 'elements': f'{elem_start}..{elem_start + len(emap) - 1}'}

    def merge(self, other, tol=0.01):
        """add another model (ids offset), then equivalence so shared boundaries join"""
        no, eo = max(self.nodes, default=0), max(self.elems, default=0)
        po, mo = max(self.props, default=0), max(self.mats, default=0)
        for k, m in other.mats.items():
            self.mats[k + mo] = dict(m)
        for k, p in other.props.items():
            self.props[k + po] = {**p, 'mid': p.get('mid', 1) + mo}
        for k, x in other.nodes.items():
            self.nodes[k + no] = x.copy()
        for k, e in other.elems.items():
            self.elems[k + eo] = {**e, 'nodes': [n + no for n in e['nodes']], 'pid': e['pid'] + po}
        for k, d in other.spc.items():
            self.spc[k + no] = d
        for ld in other.loads:
            self.loads.append({**ld, 'elems': [x + eo for x in ld['elems']]} if ld['type'] == 'pressure' else {**ld, 'node': ld['node'] + no})
        return self.equivalence(tol)

    def split_quads(self):
        """quad -> 2 trias (shorter diagonal)"""
        n = 0
        for eid in list(self.elems):
            e = self.elems[eid]
            if e['type'] != 'quad':
                continue
            a, b, c, d = e['nodes']
            P = self.nodes
            if np.linalg.norm(P[a] - P[c]) <= np.linalg.norm(P[b] - P[d]):
                t1, t2 = [a, b, c], [a, c, d]
            else:
                t1, t2 = [a, b, d], [b, c, d]
            self.elems[eid] = {**e, 'type': 'tria', 'nodes': t1}
            new = self.next_eid()
            self.elems[new] = {**e, 'type': 'tria', 'nodes': t2}
            for ld in self.loads:
                if ld['type'] == 'pressure' and eid in ld['elems']:
                    ld['elems'].append(new)
            n += 1
        return {'quads_split': n}

    def set_thickness(self, pid, t):
        self.props[int(pid)]['t'] = float(t)
        return {'pid': pid, 't': t}

    # ================================================================== element-type conversion
    def shell_normals(self):
        acc = {}
        for e in self.elems.values():
            if DIM[e['type']] != 2:
                continue
            P = [self.nodes[n] for n in e['nodes']]
            c = np.mean(P, 0)
            nv = sum(np.cross(P[k] - c, P[(k + 1) % len(P)] - c) for k in range(len(P)))
            nv = nv / (np.linalg.norm(nv) or 1)
            for n in e['nodes']:
                acc[n] = acc.get(n, 0) + nv
        return {n: v / (np.linalg.norm(v) or 1) for n, v in acc.items()}

    def shell_to_solid(self, layers=1, pids=None):
        """2D -> 3D: every quad -> hexa(s), tria -> penta(s), through the shell thickness (mid-surface +- t/2 along the
        element normal). Nodes on a plate joint get one normal per plate, so plates do NOT merge at T-joints: the solid
        plates meet face to face there; use it for local / fatigue models of one plate field or with tie contacts."""
        layers = max(1, int(layers))
        sel = [eid for eid, e in self.elems.items() if DIM[e['type']] == 2 and (not pids or e['pid'] in pids)]
        if not sel:
            return {'converted': 0}
        nbytypeplate = {}
        for eid in sel:                                          # one normal per (node, plate group)
            e = self.elems[eid]
            P = [self.nodes[n] for n in e['nodes']]
            c = np.mean(P, 0)
            nv = sum(np.cross(P[k] - c, P[(k + 1) % len(P)] - c) for k in range(len(P)))
            nv = nv / (np.linalg.norm(nv) or 1)
            for n in e['nodes']:
                key = (n, e['pid'], e.get('group'))
                nbytypeplate[key] = nbytypeplate.get(key, 0) + nv
        cache = {}
        def layer_node(n, pid, grp, k, t):
            key = (n, pid, grp, k)
            if key not in cache:
                nv = nbytypeplate[(n, pid, grp)]
                nv = nv / (np.linalg.norm(nv) or 1)
                cache[key] = self.add_node(self.nodes[n] + nv * t * (k / layers - 0.5))
            return cache[key]
        solid_pid = {}
        for eid in sel:
            e = self.elems.pop(eid)
            p = self.props.get(e['pid'], {'t': 1.0, 'mid': 1})
            if e['pid'] not in solid_pid:
                solid_pid[e['pid']] = max(self.props) + 1
                self.props[solid_pid[e['pid']]] = {'kind': 'solid', 'mid': p.get('mid', 1), 'name': f"solid of {p.get('name', e['pid'])}"}
            for k in range(layers):
                bot = [layer_node(n, e['pid'], e.get('group'), k, p['t']) for n in e['nodes']]
                top = [layer_node(n, e['pid'], e.get('group'), k + 1, p['t']) for n in e['nodes']]
                typ = 'hexa' if len(bot) == 4 else 'penta'
                self.add_elem(typ, bot + top, solid_pid[e['pid']], e.get('group', ''), eid if k == 0 else None)
        for ld in self.loads:
            if ld['type'] == 'pressure':
                ld['elems'] = [x for x in ld['elems'] if x in self.elems and DIM[self.elems[x]['type']] == 2]
        self.remove_free_nodes()
        return {'converted_shells': len(sel), 'layers': layers, 'solids': sum(1 for e in self.elems.values() if DIM[e['type']] == 3),
                'note': 'pressure loads on converted shells are dropped: re-apply them on solid faces'}

    def solid_skin(self, t=1.0):
        """3D -> 2D: outer faces of the solids become shell elements (e.g. a coating / skin mesh, or to view a solid model)"""
        cnt = {}
        for eid, e in self.elems.items():
            if e['type'] in FACES:
                for f in FACES[e['type']]:
                    ns = [e['nodes'][i] for i in f]
                    key = tuple(sorted(ns))
                    cnt.setdefault(key, [0, ns])[0] += 1
        pid = max(self.props, default=0) + 1
        self.props[pid] = {'kind': 'shell', 't': float(t), 'mid': next(iter(self.mats), 1), 'name': 'SKIN'}
        n = 0
        for key, (c, ns) in cnt.items():
            if c == 1:
                self.add_elem('quad' if len(ns) == 4 else 'tria', ns, pid, 'SKIN')
                n += 1
        return {'skin_shells': n, 'pid': pid}

    def edges_to_beams(self, profile_A=100.0, I1=1e4, I2=1e4, J=1e3, which='free'):
        """2D -> 1D: shell free edges ('free') or plate joint lines ('joints') become bar elements"""
        cnt = {}
        for e in self.elems.values():
            if DIM[e['type']] == 2:
                ns = e['nodes']
                for k in range(len(ns)):
                    key = tuple(sorted((ns[k], ns[(k + 1) % len(ns)])))
                    cnt[key] = cnt.get(key, 0) + 1
        pick = [k for k, c in cnt.items() if (c == 1 if which == 'free' else c >= 3)]
        pid = max(self.props, default=0) + 1
        self.props[pid] = {'kind': 'bar', 'A': profile_A, 'I1': I1, 'I2': I2, 'J': J, 'mid': next(iter(self.mats), 1), 'name': f'{which} edge bars'}
        for a, b in pick:
            self.add_elem('bar', [a, b], pid, f'{which.upper()}_EDGE')
        return {'bars_added': len(pick), 'pid': pid}

    def beams_to_shells(self, height, t, direction=(0, 0, -1), n_web=2, pids=None):
        """1D -> 2D: each bar becomes a shell web strip of the given height hanging along direction (stiffener webs)"""
        d = np.asarray(direction, float)
        d = d / np.linalg.norm(d)
        sel = [eid for eid, e in self.elems.items() if e['type'] == 'bar' and (not pids or e['pid'] in pids)]
        pid = max(self.props, default=0) + 1
        self.props[pid] = {'kind': 'shell', 't': float(t), 'mid': next(iter(self.mats), 1), 'name': 'WEB from beams'}
        cache = {}
        def nd(n, k):
            if k == 0:
                return n
            if (n, k) not in cache:
                cache[(n, k)] = self.add_node(self.nodes[n] + d * height * k / n_web)
            return cache[(n, k)]
        for eid in sel:
            e = self.elems.pop(eid)
            a, b = e['nodes']
            for k in range(n_web):
                self.add_elem('quad', [nd(a, k), nd(b, k), nd(b, k + 1), nd(a, k + 1)], pid, e.get('group', 'WEB'))
        return {'beams_converted': len(sel), 'web_shells': len(sel) * n_web, 'pid': pid}

    # ================================================================== checks
    def check(self):
        from .meshcheck import check
        sh = {eid: e for eid, e in self.elems.items() if DIM[e['type']] == 2}
        out = check({k: tuple(v) for k, v in self.nodes.items()}, [e['nodes'] for e in sh.values()]) if sh else {}
        used = {n for e in self.elems.values() for n in e['nodes']}
        parent = {n: n for n in self.nodes}
        def find(a):
            while parent[a] != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a
        for e in self.elems.values():
            r = find(e['nodes'][0])
            for n in e['nodes'][1:]:
                parent[find(n)] = r
        parts = len({find(e['nodes'][0]) for e in self.elems.values()})
        bad_solids = 0
        for e in self.elems.values():
            if e['type'] in ('hexa', 'penta', 'tetra'):
                if _solid_volume(e['type'], [self.nodes[n] for n in e['nodes']]) <= 0:
                    bad_solids += 1
        out.update({'all_elements_parts': parts, 'free_nodes_all': len(self.nodes) - len(used), 'inverted_solids': bad_solids,
                    'by_dimension': self.summary()['by_dimension']})
        return out


# ====================================================================== helpers
def _is_punch(path):
    try:
        head = open(path, errors='replace').read(4000).upper()
        return 'BEGIN BULK' not in head and 'CEND' not in head
    except OSError:
        return False


def _isnum(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


def _runs(dd):
    out, st = [], dd[0]
    for a, b in zip(dd, dd[1:] + [None]):
        if b != a + 1:
            out.append((st, a))
            st = b
    return out


def _grid16(nid, x):
    """GRID* large field: 16-character fields, full coordinate precision"""
    def f(v):
        s = f'{v:.9g}'
        if 'e' in s or 'E' in s:
            s = f'{v:.8E}'
        elif '.' not in s:
            s += '.'                                   # Nastran: a real must have a decimal point
        return f'{s:>16s}'[:16]
    return f"GRID*   {nid:<16d}{'':16s}{f(float(x[0]))}{f(float(x[1]))}\n*       {f(float(x[2]))}"


def _bar_orient(a, b):
    d = (np.asarray(b) - np.asarray(a))
    d = d / (np.linalg.norm(d) or 1)
    v = np.array([0.0, 0.0, 1.0]) if abs(d[2]) < 0.9 else np.array([1.0, 0.0, 0.0])
    return v.tolist()


def _collapsed_quad(ns):
    """triangle nodes if exactly one edge of the quad has collapsed (two neighbouring nodes the same), else None"""
    if len(set(ns)) != 3:
        return None
    for k in range(4):
        if ns[k] == ns[(k + 1) % 4]:
            return [ns[i] for i in range(4) if i != k]
    return None


def _reverse(typ, ns):
    if typ in ('tria', 'quad'):
        return [ns[0]] + ns[1:][::-1]
    if typ == 'hexa':
        return [ns[0], ns[3], ns[2], ns[1], ns[4], ns[7], ns[6], ns[5]]
    if typ == 'penta':
        return [ns[0], ns[2], ns[1], ns[3], ns[5], ns[4]]
    if typ == 'tetra':
        return [ns[0], ns[2], ns[1], ns[3]]
    return ns


def _solid_volume(typ, P):
    P = [np.asarray(p) for p in P]
    tet = lambda a, b, c, d: np.dot(np.cross(b - a, c - a), d - a) / 6
    if typ == 'tetra':
        return tet(*P)
    if typ == 'penta':
        return tet(P[0], P[1], P[2], P[3]) + tet(P[1], P[2], P[3], P[4]) + tet(P[2], P[3], P[4], P[5])
    c = np.mean(P, 0)
    v = 0.0
    for f in FACES['hexa']:
        q = [P[i] for i in f]
        v += tet(c, q[0], q[1], q[2]) + tet(c, q[0], q[2], q[3])
    return v
