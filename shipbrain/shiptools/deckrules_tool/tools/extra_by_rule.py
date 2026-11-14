"""Which rule produced the output that is NOT in the reference (P1 diagnosis). python tools/extra_by_rule.py deck_moulded.xml REF.xml DECKCODE"""
import sys, math, re, collections
sys.path.insert(0, '.')
from lxml import etree
from shapely.geometry import LineString
from shapely.ops import unary_union
from deckrules import reference
xmlp, refp, code = sys.argv[1:4]
ref = reference.extract_deck(reference.load(refp), code)
R = [(LineString([s['a'], s['b']]), math.atan2(s['b'][1]-s['a'][1], s['b'][0]-s['a'][0]) % math.pi) for s in ref['stiffeners']]
root = etree.parse(xmlp).getroot()
agg = collections.defaultdict(lambda: [0.0, 0.0, 0])
for st in root.iter('Stiffener'):
    t = st.find('Trace'); s0 = t.find('StartPoint2d')
    p = [(float(s0.get('U')), float(s0.get('V')))] + [(float(n.get('U')), float(n.get('V'))) for n in t.iter('Node2d')]
    ol = LineString([p[0], p[-1]]); oa = math.atan2(p[-1][1]-p[0][1], p[-1][0]-p[0][0]) % math.pi
    near = [rl for rl, ra in R if min(abs(ra-oa) % math.pi, math.pi - abs(ra-oa) % math.pi) < 0.05 and rl.distance(ol) <= 60]
    real = ol.intersection(unary_union([r.buffer(60, cap_style=2) for r in near])).length if near else 0.0
    ev = st.get('Evidence') or ''
    key = (st.get('Kind'), re.split(r"[:;(]| ->", ev)[0][:40])
    a = agg[key]; a[0] += ol.length; a[1] += ol.length - real; a[2] += 1
for k, (L, ex, n) in sorted(agg.items(), key=lambda kv: -kv[1][1]):
    print(f"{k[0]:8s} {k[1]:42s} n={n:4d} out={L/1000:7.1f} m  NOT real={ex/1000:7.1f} m ({ex/max(L,1):.0%})")
