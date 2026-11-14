"""Read the sample Ship XML as an ANSWER KEY only (never used by the rules).

Produces global-coordinate plates, openings and stiffener traces for the
deck plating panels of one deck (e.g. DHS-BDK_*), so rule output can be
scored.  Nothing here is imported by the extraction pipeline.
"""
import math
import re
import xml.etree.ElementTree as ET


def _v(e):
    return [float(e.get(k)) for k in ('X', 'Y', 'Z')]


def _uv(e):
    return float(e.get('U')), float(e.get('V'))


def _contour(c):
    if c is None:
        return []
    pts = [_uv(c.find('StartPoint2d'))]
    for s in c.findall('Segment2d'):
        pts.append(_uv(s.find('Node2d')))
    return pts


class Frame:
    def __init__(self, cs):
        self.o = _v(cs.find('Origin'))
        self.w = _v(cs.find('Waxis'))
        self.u = _v(cs.find('Uaxis'))
        w, u = self.w, self.u
        self.vv = [w[1] * u[2] - w[2] * u[1], w[2] * u[0] - w[0] * u[2], w[0] * u[1] - w[1] * u[0]]

    def g(self, uv):
        U, V = uv
        return tuple(self.o[i] + U * self.u[i] + V * self.vv[i] for i in range(3))


def load(xml_path):
    return ET.parse(xml_path).getroot()


def deck_panels(root, deck_letter):
    pat = re.compile(rf'^DHS-{deck_letter}DK_')
    return [p for p in root.iter('PlanePanel') if pat.match(p.get('ObjId'))]


def extract_deck(root, deck_letter):
    plates, stiffeners, holes = [], [], []
    for p in deck_panels(root, deck_letter):
        fr = Frame(p.find('CoordSys'))
        for pg in p.findall('PlateGroup'):
            t = float(pg.find('Material/Thickness').text)
            for pl in pg.findall('Plate'):
                poly = [fr.g(q)[:2] for q in _contour(pl.find('SimpleContour'))]
                plates.append({'panel': p.get('ObjId'), 'name': pl.get('Name'),
                               't': t, 'poly': poly, 'z': fr.o[2]})
        for h in p.iter('Hole'):
            poly = [fr.g(q)[:2] for q in _contour(h.find('Contour'))]
            box = h.find('Box')
            holes.append({'panel': p.get('ObjId'), 'poly': poly,
                          'box': (float(box.get('Length')), float(box.get('Width'))) if box is not None else None})
        for sg in p.findall('StiffenerGroup'):
            bs = sg.find('Material/BarShape')
            sec = bs.get('BarSectionId') if bs is not None else None
            for st in sg.findall('Stiffener'):
                tr = _contour(st.find('Trace'))
                if len(tr) < 2:
                    continue
                a, b = fr.g(tr[0])[:2], fr.g(tr[-1])[:2]
                stiffeners.append({'panel': p.get('ObjId'), 'name': st.get('Name'),
                                   'section': sec, 'a': a, 'b': b})
    return {'plates': plates, 'stiffeners': stiffeners, 'holes': holes}


def section_key(sec):
    """'LBar250*90*12*16' -> ('L',250,90,12,16); 'FlatBar100*7' -> ('F',100,7)."""
    if not sec:
        return None
    m = re.match(r'([A-Za-z]+?)(\d[\d.*]*)$', sec)
    if not m:
        return (sec,)
    kind = {'LBar': 'L', 'FlatBar': 'F', 'TBar': 'T', 'IBar': 'I', 'BulbBar': 'B'}.get(m.group(1), m.group(1))
    return (kind,) + tuple(float(v) for v in m.group(2).split('*') if v)
