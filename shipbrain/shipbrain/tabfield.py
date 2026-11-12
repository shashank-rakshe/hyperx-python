"""
Result tables exported from other programs (ANSYS Fluent "Export > Solution Data" ASCII, STAR-CCM+ exported tables / plots, Abaqus / ANSYS reports, ParaView "Save Data" CSV):
a table with x, y, z columns and one column per field. Read here with column names recognised in the usual spellings (x-coordinate, X (m), Points:0, Position[X] ...), so that
probe_result gives the value at any place and show_result draws the field - for results of programs ShipBrain cannot run itself.
"""
import csv, io, os, re

import numpy as np

_AX = {'x': r'^(x|x[-_ ]?coord\w*|points?[:_ ]?0|position\W*\[?x\]?.*|x\s*\(.*\)|x\s*\[.*\]|coord\w*[-_ ]?x|.*\bx[-_ ]coordinate)$',
       'y': r'^(y|y[-_ ]?coord\w*|points?[:_ ]?1|position\W*\[?y\]?.*|y\s*\(.*\)|y\s*\[.*\]|coord\w*[-_ ]?y|.*\by[-_ ]coordinate)$',
       'z': r'^(z|z[-_ ]?coord\w*|points?[:_ ]?2|position\W*\[?z\]?.*|z\s*\(.*\)|z\s*\[.*\]|coord\w*[-_ ]?z|.*\bz[-_ ]coordinate)$'}


def read(path):
    """-> (columns, data n x m array); skips comment / unit lines; delimiter sniffed (comma, semicolon, tab, spaces)"""
    raw = open(path, encoding='utf-8', errors='replace').read()
    lines = [l for l in raw.splitlines() if l.strip() and not l.lstrip().startswith(('#', '//', '%'))]
    if not lines:
        raise ValueError('empty table')
    delim = max((',', ';', '\t'), key=lambda d: lines[0].count(d))
    if lines[0].count(delim) == 0:
        delim = None
    rows = [next(csv.reader([l], delimiter=delim)) if delim else l.split() for l in lines]
    rows = [[c.strip() for c in r] for r in rows]

    def isnum(c):
        try:
            float(c)
            return True
        except ValueError:
            return False
    k = 0
    while k < len(rows) and not all(isnum(c) for c in rows[k] if c != ''):
        k += 1
    if k == len(rows):
        raise ValueError('no numeric rows in the table')
    head = rows[max(0, k - 1)] if k > 0 else [f'col{i}' for i in range(len(rows[0]))]
    body = [r for r in rows[k:] if len(r) == len(rows[k])]
    data = np.array([[float(c) if c != '' else np.nan for c in r] for r in body])
    head = [h.strip().strip('"') for h in head]
    if len(head) != data.shape[1]:
        head = [f'col{i}' for i in range(data.shape[1])]
    return head, data


def coords(head):
    """index of the x, y, z columns (z may be missing for a 2D table)"""
    idx = {}
    for ax, rx in _AX.items():
        for i, h in enumerate(head):
            if re.match(rx, h.strip().lower()):
                idx[ax] = i
                break
    if 'x' not in idx or 'y' not in idx:
        raise ValueError('no x / y coordinate columns found (looked for x-coordinate, X (m), Points:0 ...)')
    return idx


def describe(path):
    head, data = read(path)
    ci = coords(head)
    fields = [h for i, h in enumerate(head) if i not in ci.values() and not re.match(r'^(node ?number|cell ?id|id|index|col\d+)$', h.strip().lower())]
    P = data[:, [ci['x'], ci['y']] + ([ci['z']] if 'z' in ci else [])]
    return {'points': int(len(data)), 'columns': head, 'fields': fields, 'bbox_min': P.min(0).round(5).tolist(), 'bbox_max': P.max(0).round(5).tolist(),
            'ranges': {h: [float(np.nanmin(data[:, head.index(h)])), float(np.nanmax(data[:, head.index(h)]))] for h in fields}}


def probe(path, x, y, z=0.0):
    head, data = read(path)
    ci = coords(head)
    cols = [ci['x'], ci['y']] + ([ci['z']] if 'z' in ci else [])
    P = data[:, cols]
    q = np.array([x, y, z][:len(cols)], float)
    j = int(np.argmin(np.linalg.norm(P - q, axis=1)))
    return {'row': j, 'at': [round(float(v), 6) for v in P[j]], 'distance': round(float(np.linalg.norm(P[j] - q)), 6),
            'values': {h: float(data[j, i]) for i, h in enumerate(head) if i not in cols}}


def render(path, out_png, field=None, plane=None, size=(10, 5.5), dpi=130, cmap='turbo', s=14):
    """scatter picture of a field of the table in the plane of its two widest coordinates (or plane='xy' | 'xz' | 'yz')"""
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    head, data = read(path)
    ci = coords(head)
    axes = [a for a in 'xyz' if a in ci]
    ext = {a: float(np.ptp(data[:, ci[a]])) for a in axes}
    if plane:
        a, b = plane[0], plane[1]
    else:
        a, b = sorted(axes, key=lambda t: -ext[t])[:2]
    info = describe(path)
    field = field or (info['fields'][0] if info['fields'] else None)
    if field is None:
        raise ValueError('the table has no field column to draw')
    v = data[:, head.index(field)]
    fig, ax = plt.subplots(figsize=size)
    sc = ax.scatter(data[:, ci[a]], data[:, ci[b]], c=v, s=s, cmap=cmap, linewidths=0)
    ax.set_aspect('equal'); ax.set_xlabel(a + ' [m]'); ax.set_ylabel(b + ' [m]')
    fig.colorbar(sc, ax=ax, shrink=0.8).set_label(field)
    ax.set_title(f'{os.path.basename(path)} - {field}')
    fig.tight_layout(); fig.savefig(out_png, dpi=dpi); plt.close(fig)
    return {'png': out_png, 'field': field, 'min': float(np.nanmin(v)), 'max': float(np.nanmax(v)), 'plane': a + b}
