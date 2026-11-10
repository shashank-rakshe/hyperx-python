"""
One universal model, adapted to each user WITHOUT retraining: a small profile on the user's own PC
(<workdir>/profile.json) that is given to the model with every question, plus unit conversion.

  profile   units system, material (name, yield), design code / standard, field of work, answer language, free notes.
            Different users = different profiles; the model weights stay the same for everybody.
  units     the tools work in mm, N, MPa, tonne, s. convert() turns any user unit into the tool unit and back:
            lengths, forces, stress / pressure, mass, density, moment, area, section modulus, inertia, acceleration...
            Unit expressions: "in", "ft", "kip", "psi", "ksi", "kN.m", "lbf*ft", "N/mm2", "mm^4", "cm4", "kg/m3", "t/m3",
            "m/s2", "bar", "mH2O" (fresh water head), "msw" (sea water head).
"""
import json, os, re

# base: SI (m, kg, s); every unit -> (factor to SI, dimension vector [m, kg, s])
_BASE = {
    'm': (1.0, (1, 0, 0)), 'mm': (1e-3, (1, 0, 0)), 'cm': (1e-2, (1, 0, 0)), 'km': (1e3, (1, 0, 0)), 'in': (0.0254, (1, 0, 0)),
    'inch': (0.0254, (1, 0, 0)), 'ft': (0.3048, (1, 0, 0)), 'yd': (0.9144, (1, 0, 0)), 'mil': (2.54e-5, (1, 0, 0)),
    'kg': (1.0, (0, 1, 0)), 'g': (1e-3, (0, 1, 0)), 't': (1e3, (0, 1, 0)), 'tonne': (1e3, (0, 1, 0)), 'lb': (0.45359237, (0, 1, 0)),
    'lbm': (0.45359237, (0, 1, 0)), 'slug': (14.5939, (0, 1, 0)),
    's': (1.0, (0, 0, 1)), 'min': (60.0, (0, 0, 1)), 'h': (3600.0, (0, 0, 1)), 'hr': (3600.0, (0, 0, 1)),
    'N': (1.0, (1, 1, -2)), 'kN': (1e3, (1, 1, -2)), 'MN': (1e6, (1, 1, -2)), 'lbf': (4.4482216152605, (1, 1, -2)),
    'kip': (4448.2216152605, (1, 1, -2)), 'kgf': (9.80665, (1, 1, -2)), 'tf': (9806.65, (1, 1, -2)),
    'Pa': (1.0, (-1, 1, -2)), 'kPa': (1e3, (-1, 1, -2)), 'MPa': (1e6, (-1, 1, -2)), 'GPa': (1e9, (-1, 1, -2)),
    'psi': (6894.757293168, (-1, 1, -2)), 'ksi': (6894757.293168, (-1, 1, -2)), 'bar': (1e5, (-1, 1, -2)),
    'mbar': (100.0, (-1, 1, -2)), 'atm': (101325.0, (-1, 1, -2)),
    'mH2O': (9806.65, (-1, 1, -2)), 'msw': (1025 * 9.80665, (-1, 1, -2)),
    'J': (1.0, (2, 1, -2)), 'kJ': (1e3, (2, 1, -2)), 'W': (1.0, (2, 1, -3)), 'kW': (1e3, (2, 1, -3)),
    'Hz': (1.0, (0, 0, -1)), 'rpm': (1 / 60, (0, 0, -1)), 'deg': (1.0, (0, 0, 0)), 'rad': (57.29577951308232, (0, 0, 0)),
    'L': (1e-3, (3, 0, 0)), 'l': (1e-3, (3, 0, 0)),
}
_TOK = re.compile(r'([A-Za-z]+[A-Za-z0-9]*?)(?:\^?(-?\d+))?$')
TOOL_UNITS = {'length': 'mm', 'force': 'N', 'stress': 'MPa', 'mass': 't', 'moment': 'N.mm', 'density': 't/mm3'}


def _parse(expr):
    """'kN.m', 'N/mm2', 'mm^4', 'lbf*ft' -> (factor to SI, dimension)"""
    e = str(expr).strip().replace(' ', '').replace('²', '2').replace('³', '3').replace('·', '.')
    if e in _BASE:
        return _BASE[e]
    num, den = (e.split('/', 1) + [''])[:2]
    f, dim = 1.0, [0, 0, 0]
    for part, sign in ((num, 1), (den, -1)):
        for tok in filter(None, re.split(r'[.*]', part)):
            if tok in _BASE:
                u, p = tok, 1
            else:
                m = _TOK.match(tok)
                if not m:
                    raise ValueError(f'unknown unit "{tok}" in "{expr}"')
                u, p = m.group(1), int(m.group(2) or 1)
                if u not in _BASE:                           # 'mm4' -> 'mm' + 4 when the regex took a digit into the name
                    mm = re.match(r'([A-Za-z]+)(\d+)$', tok)
                    if not mm or mm.group(1) not in _BASE:
                        raise ValueError(f'unknown unit "{tok}" in "{expr}"')
                    u, p = mm.group(1), int(mm.group(2))
            uf, ud = _BASE[u]
            f *= uf ** (p * sign)
            dim = [a + b * p * sign for a, b in zip(dim, ud)]
    return f, tuple(dim)


def convert(value, from_unit, to_unit):
    f1, d1 = _parse(from_unit)
    f2, d2 = _parse(to_unit)
    if d1 != d2:
        raise ValueError(f'cannot convert {from_unit} to {to_unit}: different quantities')
    return float(value) * f1 / f2


def convert_many(values):
    """[{'value', 'from', 'to'}] -> list with 'result' (rounded to 6 significant digits)"""
    out = []
    for v in values:
        r = convert(v['value'], v['from'], v['to'])
        out.append({'value': v['value'], 'from': v['from'], 'to': v['to'], 'result': float(f'{r:.6g}')})
    return out


# ------------------------------------------------------------------ profile
SYSTEMS = {'mm-N-MPa': 'mm, N, MPa (tool units)', 'm-kN-kPa': 'm, kN, kPa', 'in-lbf-psi': 'inch, lbf, psi',
           'ft-kip-ksi': 'ft, kip, ksi', 'mm-kN-MPa': 'mm, kN, MPa'}
FIELDS = ('units', 'material', 'yield_MPa', 'E_MPa', 'design_code', 'field', 'language', 'notes')


class Profile:
    def __init__(self, folder):
        self.path = os.path.join(folder, 'profile.json')
        self.data = {}
        if os.path.exists(self.path):
            try:
                self.data = json.load(open(self.path, encoding='utf-8'))
            except Exception:
                self.data = {}

    def update(self, **kw):
        changed = {}
        for k, v in kw.items():
            if k in FIELDS and v not in (None, ''):
                if k == 'units' and v not in SYSTEMS:
                    raise ValueError('units: one of ' + ', '.join(SYSTEMS))
                self.data[k] = v
                changed[k] = v
        os.makedirs(os.path.dirname(self.path) or '.', exist_ok=True)
        json.dump(self.data, open(self.path, 'w', encoding='utf-8'), indent=1)
        return changed

    def context(self):
        """one short line for the model, or '' (nothing set = defaults)"""
        d = self.data
        if not d:
            return ''
        parts = []
        if d.get('units') and d['units'] != 'mm-N-MPa':
            parts.append(f"units {SYSTEMS[d['units']]} (tools use mm, N, MPa: convert with convert_units in and out)")
        if d.get('material') or d.get('yield_MPa'):
            parts.append('material ' + ' '.join(x for x in (str(d.get('material', '')),
                                                            f"yield {d['yield_MPa']} MPa" if d.get('yield_MPa') else '') if x))
        for k, lab in (('E_MPa', 'E'), ('design_code', 'design code'), ('field', 'field'), ('language', 'answer in')):
            if d.get(k):
                parts.append(f'{lab} {d[k]}')
        if d.get('notes'):
            parts.append(str(d['notes'])[:200])
        return 'User profile: ' + '; '.join(parts) + '.'
