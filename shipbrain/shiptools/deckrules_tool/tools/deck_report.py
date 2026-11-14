"""Deck report: zoomable 2D plans (SVG, pan / zoom, layers) of every deck of a ship moulded-line XML + a 3D view page.
usage: python tools/deck_report.py MODEL.xml OUT_DIR [BUILD_REPORT.md]   (offline, no network)"""
import json, os, sys, html
from lxml import etree

def vec(e):
    return tuple(float(e.get(k)) for k in 'XYZ')

def cross(a, b):
    return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])

def contour(c):
    sp = c.find('StartPoint2d')
    pts = [(float(sp.get('U')), float(sp.get('V')))]
    for n in c.iter('Node2d'):
        pts.append((float(n.get('U')), float(n.get('V'))))
    return pts

def main(xml, out, rep=None):
    os.makedirs(out, exist_ok=True)
    root = etree.parse(xml).getroot()
    decks = []
    for b in root.findall('Block'):
        d = {'name': b.get('ObjId').replace('PDF-', ''), 'plates': [], 'holes': [], 'stiff': [], 'z': None}
        for pp in b.findall('PlanePanel'):
            cs = pp.find('CoordSys')
            O, W, U = vec(cs.find('Origin')), vec(cs.find('Waxis')), vec(cs.find('Uaxis'))
            if abs(W[2]) < 0.9:
                continue                                  # vertical panels are not part of a deck plan
            V = cross(W, U)
            tr = lambda u, v: (O[0]+u*U[0]+v*V[0], O[1]+u*U[1]+v*V[1])
            d['z'] = O[2] if d['z'] is None else d['z']
            for pl in pp.iter('Plate'):
                t = pl.getparent().find('Material/Thickness')
                d['plates'].append(([tr(*p) for p in contour(pl.find('SimpleContour'))], float(t.text) if t is not None else 0.0, pl.get('Name', '')))
            for h in pp.iter('Hole'):
                c = h.find('Contour')
                if c is not None:
                    d['holes'].append([tr(*p) for p in contour(c)])
            for st in pp.iter('Stiffener'):
                t = st.find('Trace')
                if t is None:
                    continue
                pts = contour(t)
                sec = st.getparent().find('.//BarShape')
                d['stiff'].append(([tr(*p) for p in pts], st.get('Kind', ''), st.get('Name', ''), sec.get('BarSectionId') if sec is not None else ''))
        if d['plates'] or d['stiff']:
            decks.append(d)
    xs = [p[0] for d in decks for pl in d['plates'] for p in pl[0]]
    ys = [p[1] for d in decks for pl in d['plates'] for p in pl[0]]
    data = [{'name': d['name'], 'z': d['z'], 'plates': [{'p': [[round(a, 1), round(-b, 1)] for a, b in pl[0]], 't': pl[1], 'n': pl[2]} for pl in d['plates']],
             'holes': [[[round(a, 1), round(-b, 1)] for a, b in h] for h in d['holes']],
             'stiff': [{'p': [[round(a, 1), round(-b, 1)] for a, b in s[0]], 'k': s[1], 'n': s[2], 's': s[3]} for s in d['stiff']]} for d in decks]
    tpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'deck_report_tpl.html'), encoding='utf-8').read()
    summary = ''
    if rep and os.path.exists(rep):
        summary = html.escape(open(rep, encoding='utf-8').read()[:6000])
    page = tpl.replace('/*DATA*/', 'const DECKS=' + json.dumps(data) + ';').replace('<!--SUMMARY-->', summary)
    open(os.path.join(out, 'deck_report.html'), 'w', encoding='utf-8').write(page)
    # 3D view: the tool's own viewer with the XML injected
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    vw = os.path.join(here, 'ship_xml_viewer.html')
    v = open(vw, encoding='utf-8').read()
    txt = json.dumps(open(xml, encoding='utf-8').read()).replace('</', '<\\/')
    inj = ("<script>addEventListener('load',()=>{const T=" + txt + ";load([{name:" + json.dumps(os.path.basename(xml)) + ",text:async()=>T}])});</script></body>")
    open(os.path.join(out, 'view_3d.html'), 'w', encoding='utf-8').write(v.replace('</body>', inj, 1))
    print('decks', len(data), '->', out)

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
