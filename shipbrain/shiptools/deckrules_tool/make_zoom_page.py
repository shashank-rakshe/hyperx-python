"""Zoomable Rule 5 page for ONE built view: the real drawing (high-res) with the produced XML, missing and extra lines on top.
python make_zoom_page.py <pdf> <build_out_dir> "<view name>" out.html     (offline: PyMuPDF, PIL)"""
import sys, json, base64, io, html
sys.path.insert(0, '.')
from deckrules import verify5 as v5, pdfsrc
import pymupdf
from PIL import Image

pdf, out, name, dst = sys.argv[1:5]
decks, vert = v5.load_xml(glob_xml := __import__('glob').glob(out + '/*_complete_moulded.xml')[0])
v = next(w for w in v5.views_of_build(out) if w['name'] == name)
page = pdfsrc.load_page(pdf, v['page'])
res = v5.check_view(page, v, decks, vert)
c = v['calib']
if v['type'] == 'plan':                    # window = the deck outline + its labels
    d = next(d for d in decks if abs(d['z'] - c['z']) < 5)
    P = v5._proj_plan(c)
    pts = [P(a) for a, b, w in d['segs'] if w == 'plate']
    x0, x1 = min(p[0] for p in pts) - 70, max(p[0] for p in pts) + 110
    y0, y1 = min(p[1] for p in pts) - 60, max(p[1] for p in pts) + 50
else:
    x0, y0, x1, y1 = v['region']
ZOOM = 7.0
pm = pymupdf.open(pdf)[v['page']].get_pixmap(matrix=pymupdf.Matrix(ZOOM, ZOOM), clip=pymupdf.Rect(x0, y0, x1, y1), colorspace=pymupdf.csGRAY)
im = Image.frombytes('L', (pm.width, pm.height), pm.samples)
buf = io.BytesIO()
im.save(buf, 'PNG', optimize=True)
img = 'data:image/png;base64,' + base64.b64encode(buf.getvalue()).decode()

inwin = lambda p: x0 <= p[0] <= x1 and y0 <= p[1] <= y1
seg = lambda l: ((l[2], l[1]), (l[3], l[1])) if l[0] == 'h' else ((l[1], l[2]), (l[1], l[3]))
xml = [[a[0] - x0, a[1] - y0, b[0] - x0, b[1] - y0, w] for a, b, w in res['proj'] if inwin(a) or inwin(b)]
items = []
for tag, lst in (('M', res['missing']), ('E', res['extra'])):
    n = 0
    for l in sorted(lst, key=lambda l: l[2] - l[3]):
        a, b = seg(l)
        if not (inwin(a) or inwin(b)):
            continue
        n += 1
        items.append({'id': f'{tag}{n}', 'k': tag, 'a': [a[0] - x0, a[1] - y0], 'b': [b[0] - x0, b[1] - y0],
                      'len': round(l[3] - l[2], 1), 'at': v5._ship(v, *l)})
# 3D: this view's own XML (focus) + every deck outline and the other vertical panels as faint context (world mm)
S3 = []
r3 = lambda P: [round(P[0]), round(P[1]), round(P[2])]
def focus_vert(p):
    return (v['type'] == 'sec' and p['kind'] == 'frame' and abs(p['pos'] - c['X']) < 5) or \
           (v['type'] == 'elev' and p['kind'] == 'wall' and abs(p['pos'] - c['y']) < 5)
for d in decks:
    foc = v['type'] == 'plan' and abs(d['z'] - c['z']) < 5
    for a, b, w in d['segs']:
        if w == 'plate' or foc:
            S3.append(r3(a) + r3(b) + ['fplate' if foc else 'deck'])
    if foc:
        for m in d['mem']:
            for a, b in zip(m['pts'], m['pts'][1:]):
                S3.append(r3(a) + r3(b) + ['fmem'])
for p in vert:
    foc = focus_vert(p)
    for a, b, w in p['segs']:
        S3.append(r3(a) + r3(b) + ['fplate' if foc else 'vert'])
    if foc:
        for m in p['mem']:
            for a, b in zip(m['pts'], m['pts'][1:]):
                S3.append(r3(a) + r3(b) + ['fmem'])
D = {'s3': S3, 'w': x1 - x0, 'h': y1 - y0, 'img': img, 'xml': xml, 'items': items, 'name': name, 'cov': res['coverage'],
     'type': {'plan': 'Deck plan', 'elev': 'OFF C.L elevation', 'sec': 'Frame section'}[v['type']]}
title = html.escape(name.title().replace('Str.', 'STR.') + ' Rule 5 Zoom')

page_html = """<title>%s</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>
/* layout: toolbar on top, zoomable drawing left, numbered list right (stacks under the drawing on phones) */
:root { --bg:#eef1f4; --panel:#ffffff; --fg:#18222c; --mut:#5c6b79; --line:#d3dae2; --acc:#1f5fb0; --miss:#d61f1f; --extra:#e58e00; --xml:#2560d8;
  --body: system-ui, -apple-system, 'Segoe UI', sans-serif; --mono: ui-monospace, 'SFMono-Regular', Menlo, monospace; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#141a20; --panel:#1d252d; --fg:#e3e9ef; --mut:#94a3b1; --line:#303b46; --acc:#86b4f0; color-scheme:dark; } }
:root[data-theme="dark"] { --bg:#141a20; --panel:#1d252d; --fg:#e3e9ef; --mut:#94a3b1; --line:#303b46; --acc:#86b4f0; color-scheme:dark; }
html, body { height:100%%; }
body { background:var(--bg); color:var(--fg); font-family:var(--body); display:flex; flex-direction:column;
  padding-left:max(12px, env(safe-area-inset-left, 0px)); padding-right:max(12px, env(safe-area-inset-right, 0px)); padding-block:10px; box-sizing:border-box; }
.bar { display:flex; flex-wrap:wrap; gap:8px 14px; align-items:center; padding-bottom:8px; }
.bar h1 { font-size:1.05rem; margin:0; font-weight:600; }
.bar .mut { color:var(--mut); font-size:.85rem; }
.bar label { font-size:.88rem; display:flex; gap:5px; align-items:center; }
.bar button { font:inherit; font-size:.85rem; padding:4px 10px; border:1px solid var(--line); background:var(--panel); color:var(--fg); border-radius:5px; cursor:pointer; }
.sw { width:16px; height:4px; border-radius:2px; display:inline-block; }
.wrap { flex:1; display:flex; gap:10px; min-height:0; }
#stage { flex:1; position:relative; overflow:hidden; background:#ffffff; border:1px solid var(--line); border-radius:6px; touch-action:none; cursor:grab; min-width:0; }
#stage.drag { cursor:grabbing; }
#world { position:absolute; left:0; top:0; transform-origin:0 0; }
#world img { display:block; width:100%%; height:100%%; image-rendering:auto; user-select:none; -webkit-user-drag:none; }
#world svg { position:absolute; inset:0; overflow:visible; }
aside { width:290px; overflow:auto; background:var(--panel); border:1px solid var(--line); border-radius:6px; font-size:.84rem; }
aside h2 { font-size:.9rem; margin:10px 12px 6px; }
aside ol { list-style:none; margin:0; padding:0 6px 10px; }
aside li { display:flex; gap:8px; align-items:baseline; padding:4px 6px; border-radius:4px; cursor:pointer; }
aside li:hover, aside li.on { background:var(--bg); }
aside li b { min-width:34px; font-variant-numeric:tabular-nums; }
aside li .at { font-family:var(--mono); font-size:.78rem; }
aside li .ln { color:var(--mut); margin-left:auto; font-variant-numeric:tabular-nums; }
.m b { color:var(--miss); } .e b { color:var(--extra); }
#tip { position:absolute; pointer-events:none; background:var(--panel); color:var(--fg); border:1px solid var(--line); border-radius:4px; padding:3px 7px; font-size:.8rem; display:none; white-space:nowrap; }
#c3 { flex:1; min-width:0; background:var(--panel); border:1px solid var(--line); border-radius:6px; touch-action:none; cursor:grab; }
@media (max-width:760px) { .wrap { flex-direction:column; } aside { width:auto; max-height:34vh; } #stage { min-height:58vh; } }
</style>
<div class="bar">
  <h1 id="ttl"></h1><span class="mut" id="sub"></span>
  <label><input type="checkbox" id="lxml" checked><span class="sw" style="background:var(--xml)"></span>XML</label>
  <label><input type="checkbox" id="lmiss" checked><span class="sw" style="background:var(--miss)"></span>missing</label>
  <label><input type="checkbox" id="lext" checked><span class="sw" style="background:var(--extra)"></span>extra</label>
  <label><input type="checkbox" id="lnum" checked>numbers</label>
  <label>drawing <input type="range" id="dim" min="20" max="100" value="100"></label>
  <button id="mode" aria-pressed="false">3D view</button><button id="fit">Fit</button><button id="zin">+</button><button id="zout">&minus;</button>
  <span class="mut">wheel or pinch = zoom, drag = pan, click a number = zoom to it</span>
</div>
<div class="wrap">
  <canvas id="c3" hidden></canvas>
  <div id="stage"><div id="world"><img id="im" alt="drawing"><svg id="sv" xmlns="http://www.w3.org/2000/svg"></svg></div><div id="tip"></div></div>
  <aside><h2>Missing (drawn, not in XML)</h2><ol id="lm"></ol><h2>Extra (in XML, not drawn)</h2><ol id="le"></ol></aside>
</div>
<script>
const D = %s;
const $ = id => document.getElementById(id);
$('ttl').textContent = D.name + ' - ' + D.type;
$('sub').textContent = 'Rule 5 coverage ' + Math.round(D.cov * 100) + ' %%, ' + D.items.filter(i => i.k == 'M').length + ' missing, ' + D.items.filter(i => i.k == 'E').length + ' extra in this window';
const W = D.w, H = D.h, NS = 'http://www.w3.org/2000/svg';
$('im').src = D.img; const world = $('world'), sv = $('sv'), stage = $('stage');
world.style.width = W + 'px'; world.style.height = H + 'px'; sv.setAttribute('viewBox', `0 0 ${W} ${H}`); sv.setAttribute('width', W); sv.setAttribute('height', H);
const gx = document.createElementNS(NS, 'g'), gm = document.createElementNS(NS, 'g'), ge = document.createElementNS(NS, 'g'), gn = document.createElementNS(NS, 'g');
[gx, ge, gm, gn].forEach(g => sv.appendChild(g));
function ln(g, a, b, col, w, data) { const l = document.createElementNS(NS, 'line'); l.setAttribute('x1', a[0]); l.setAttribute('y1', a[1]); l.setAttribute('x2', b[0]); l.setAttribute('y2', b[1]);
  l.setAttribute('stroke', col); l.dataset.w = w; l.setAttribute('stroke-linecap', 'round'); if (data) l.dataset.t = data; g.appendChild(l); return l; }
D.xml.forEach(s => ln(gx, [s[0], s[1]], [s[2], s[3]], '#2560d8', 1.6, 'XML: ' + s[4]));
D.items.forEach(it => {
  const col = it.k == 'M' ? '#d61f1f' : '#e58e00';
  ln(it.k == 'M' ? gm : ge, it.a, it.b, col, 3, it.id + '  ' + it.at + '  (' + it.len + ' pt)');
  const c = [(it.a[0] + it.b[0]) / 2, (it.a[1] + it.b[1]) / 2];
  const g = document.createElementNS(NS, 'g'); g.dataset.id = it.id; g.dataset.cx = c[0]; g.dataset.cy = c[1]; g.style.cursor = 'pointer';
  const r = document.createElementNS(NS, it.k == 'M' ? 'circle' : 'rect');
  if (it.k == 'M') { r.setAttribute('cx', c[0]); r.setAttribute('cy', c[1]); r.setAttribute('r', 3.2); } else { r.setAttribute('x', c[0] - 3.2); r.setAttribute('y', c[1] - 3.2); r.setAttribute('width', 6.4); r.setAttribute('height', 6.4); }
  r.setAttribute('fill', col); const t = document.createElementNS(NS, 'text'); t.setAttribute('x', c[0]); t.setAttribute('y', c[1] + 1.4);
  t.setAttribute('text-anchor', 'middle'); t.setAttribute('font-size', 3.6); t.setAttribute('font-family', 'system-ui, sans-serif'); t.setAttribute('font-weight', '700'); t.setAttribute('fill', it.k == 'M' ? '#fff' : '#000');
  t.textContent = it.id.slice(1); g.appendChild(r); g.appendChild(t); g.addEventListener('click', e => { e.stopPropagation(); focusItem(it.id); }); gn.appendChild(g);
  const li = document.createElement('li'); li.className = it.k == 'M' ? 'm' : 'e'; li.id = 'li-' + it.id;
  li.innerHTML = `<b>${it.id}</b><span class="at">${it.at}</span><span class="ln">${it.len} pt</span>`; li.onclick = () => focusItem(it.id);
  (it.k == 'M' ? $('lm') : $('le')).appendChild(li); });
let s = 1, tx = 0, ty = 0;
function apply() { world.style.transform = `translate(${tx}px,${ty}px) scale(${s})`;
  sv.querySelectorAll('line').forEach(l => l.setAttribute('stroke-width', l.dataset.w / s));          // constant screen width at every zoom
  const k = 3 / s; gn.querySelectorAll('g').forEach(g => g.setAttribute('transform',
    `translate(${g.dataset.cx} ${g.dataset.cy}) scale(${k}) translate(${-g.dataset.cx} ${-g.dataset.cy})`)); }
function fit() { const r = stage.getBoundingClientRect(); s = Math.min(r.width / W, r.height / H) * 0.97; tx = (r.width - W * s) / 2; ty = (r.height - H * s) / 2; apply(); }
function zoomAt(k, cx, cy) { const ns = Math.max(0.2, Math.min(60, s * k)); k = ns / s; tx = cx - (cx - tx) * k; ty = cy - (cy - ty) * k; s = ns; apply(); }
function focusItem(id) { const it = D.items.find(i => i.id == id); const r = stage.getBoundingClientRect(); const c = [(it.a[0] + it.b[0]) / 2, (it.a[1] + it.b[1]) / 2];
  s = Math.max(s, 8); tx = r.width / 2 - c[0] * s; ty = r.height / 2 - c[1] * s; apply();
  document.querySelectorAll('aside li.on').forEach(x => x.classList.remove('on')); const li = $('li-' + id); li.classList.add('on'); li.scrollIntoView({block: 'nearest'}); }
stage.addEventListener('wheel', e => { e.preventDefault(); const r = stage.getBoundingClientRect(); zoomAt(Math.exp(-e.deltaY * 0.0015), e.clientX - r.left, e.clientY - r.top); }, {passive: false});
const pts = new Map(); let last = null, pinch = null;
stage.addEventListener('pointerdown', e => { stage.setPointerCapture(e.pointerId); pts.set(e.pointerId, [e.clientX, e.clientY]); stage.classList.add('drag');
  if (pts.size == 2) { const [p, q] = [...pts.values()]; pinch = Math.hypot(p[0] - q[0], p[1] - q[1]); } last = [e.clientX, e.clientY]; });
stage.addEventListener('pointermove', e => { if (!pts.has(e.pointerId)) { tip(e); return; } pts.set(e.pointerId, [e.clientX, e.clientY]);
  if (pts.size == 2 && pinch) { const [p, q] = [...pts.values()]; const d = Math.hypot(p[0] - q[0], p[1] - q[1]); const r = stage.getBoundingClientRect();
    zoomAt(d / pinch, (p[0] + q[0]) / 2 - r.left, (p[1] + q[1]) / 2 - r.top); pinch = d; return; }
  tx += e.clientX - last[0]; ty += e.clientY - last[1]; last = [e.clientX, e.clientY]; apply(); });
['pointerup', 'pointercancel'].forEach(t => stage.addEventListener(t, e => { pts.delete(e.pointerId); if (pts.size < 2) pinch = null; if (!pts.size) stage.classList.remove('drag'); if (pts.size) last = [...pts.values()][0]; }));
function tip(e) { const el = document.elementFromPoint(e.clientX, e.clientY); const t = $('tip'); const d = el && el.dataset && el.dataset.t;
  if (d) { const r = stage.getBoundingClientRect(); t.textContent = d; t.style.left = (e.clientX - r.left + 12) + 'px'; t.style.top = (e.clientY - r.top + 12) + 'px'; t.style.display = 'block'; } else t.style.display = 'none'; }
$('zin').onclick = () => { const r = stage.getBoundingClientRect(); zoomAt(1.5, r.width / 2, r.height / 2); };
$('zout').onclick = () => { const r = stage.getBoundingClientRect(); zoomAt(1 / 1.5, r.width / 2, r.height / 2); };
$('lxml').onchange = e => gx.style.display = e.target.checked ? '' : 'none'; $('lmiss').onchange = e => gm.style.display = e.target.checked ? '' : 'none';
$('lext').onchange = e => ge.style.display = e.target.checked ? '' : 'none'; $('lnum').onchange = e => gn.style.display = e.target.checked ? '' : 'none';
$('dim').oninput = e => $('im').style.opacity = e.target.value / 100;
addEventListener('resize', () => { fit(); if (!$('c3').hidden) draw3(); }); $('im').onload = fit; fit();
// ---- 3D view of the produced XML (focus = this view's own panels / members, thick; the rest faint)
const c3 = $('c3'); const V3 = {az: -50, el: 28, s: 1, tx: 0, ty: 0};
let cx3 = 0, cy3 = 0, cz3 = 0; { const f = D.s3.filter(q => q[6][0] == 'f'); const A = f.length ? f : D.s3; const xs = [], ys = [], zs = [];
  A.forEach(q => { xs.push(q[0], q[3]); ys.push(q[1], q[4]); zs.push(q[2], q[5]); }); const mid = a => (Math.min(...a) + Math.max(...a)) / 2; cx3 = mid(xs); cy3 = mid(ys); cz3 = mid(zs); }
function P3(x, y, z) { const a = V3.az * Math.PI / 180, e = V3.el * Math.PI / 180; x -= cx3; y -= cy3; z -= cz3;
  const X = x * Math.cos(a) - y * Math.sin(a), Y = x * Math.sin(a) + y * Math.cos(a); return [X, -(z * Math.cos(e) + Y * Math.sin(e))]; }
function fit3() { const dp = devicePixelRatio || 1; const w = c3.clientWidth * dp, h = c3.clientHeight * dp; let mx = 1;
  D.s3.filter(q => q[6][0] == 'f').forEach(q => { const p = P3(q[0], q[1], q[2]); mx = Math.max(mx, Math.abs(p[0]) / w, Math.abs(p[1]) / h); }); V3.s = 0.45 / mx; V3.tx = w / 2; V3.ty = h / 2; }
const COL3 = {fplate: '#2560d8', fmem: '#d61f1f', deck: 'rgba(37,96,216,.22)', vert: 'rgba(120,130,140,.22)'};
function draw3() { const dp = devicePixelRatio || 1; c3.width = c3.clientWidth * dp; c3.height = c3.clientHeight * dp; const g = c3.getContext('2d');
  g.clearRect(0, 0, c3.width, c3.height); ['deck', 'vert', 'fplate', 'fmem'].forEach(k => { g.strokeStyle = COL3[k]; g.lineWidth = (k == 'fmem' ? 2.2 : k == 'fplate' ? 1.6 : 1) * dp; g.beginPath();
    D.s3.forEach(q => { if (q[6] != k) return; const a = P3(q[0], q[1], q[2]), b = P3(q[3], q[4], q[5]);
      g.moveTo(V3.tx + a[0] * V3.s, V3.ty + a[1] * V3.s); g.lineTo(V3.tx + b[0] * V3.s, V3.ty + b[1] * V3.s); }); g.stroke(); });
  g.fillStyle = getComputedStyle(document.body).color; g.font = (12 * dp) + 'px system-ui, sans-serif';
  g.fillText('blue = this view in the XML (plates / panels), red = its members, faint = rest of the model.  Drag = rotate, shift-drag = pan, wheel = zoom', 10 * dp, 18 * dp);
  const ax = [[1500, 0, 0, 'X fwd'], [0, 1500, 0, 'Y port'], [0, 0, 1500, 'Z up']]; const o = P3(cx3, cy3, cz3);
  ax.forEach(([x, y, z, t]) => { const p = P3(cx3 + x, cy3 + y, cz3 + z); g.fillText(t, 20 * dp + (p[0] - o[0]) * 0.03 * dp + 30 * dp, c3.height - 30 * dp + (p[1] - o[1]) * 0.03 * dp); }); }
let d3 = null; c3.addEventListener('pointerdown', e => { c3.setPointerCapture(e.pointerId); d3 = [e.clientX, e.clientY, V3.az, V3.el, V3.tx, V3.ty, e.shiftKey || e.button == 2]; });
c3.addEventListener('pointermove', e => { if (!d3) return; const dp = devicePixelRatio || 1, dx = e.clientX - d3[0], dy = e.clientY - d3[1];
  if (d3[6]) { V3.tx = d3[4] + dx * dp; V3.ty = d3[5] + dy * dp; } else { V3.az = d3[2] + dx * 0.4; V3.el = Math.max(-89, Math.min(89, d3[3] + dy * 0.4)); } draw3(); });
c3.addEventListener('pointerup', () => d3 = null); c3.addEventListener('contextmenu', e => e.preventDefault());
c3.addEventListener('wheel', e => { e.preventDefault(); const dp = devicePixelRatio || 1, r = c3.getBoundingClientRect(), x = (e.clientX - r.left) * dp, y = (e.clientY - r.top) * dp, k = Math.exp(-e.deltaY * 0.0015);
  V3.tx = x - (x - V3.tx) * k; V3.ty = y - (y - V3.ty) * k; V3.s *= k; draw3(); }, {passive: false});
$('mode').onclick = () => { const on = c3.hidden; c3.hidden = !on; stage.hidden = on; $('mode').textContent = on ? 'Drawing' : '3D view'; $('mode').setAttribute('aria-pressed', on);
  if (on) { fit3(); draw3(); } else fit(); };
$('fit').onclick = () => { if (!c3.hidden) { fit3(); draw3(); } else fit(); };
</script>
""" % (title, json.dumps(D))
open(dst, 'w', encoding='utf-8').write(page_html)
print('wrote', dst, round(len(page_html) / 1e6, 2), 'MB', len(items), 'items')
