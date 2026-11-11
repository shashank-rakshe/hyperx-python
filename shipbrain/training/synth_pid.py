"""
Synthetic P&ID sheets with an exact answer key: teaches the vision model to read P&IDs into pid-to-kg's format.

Each sheet is a small random process drawn with ISA-style symbols (tanks, pumps, gate / ball / butterfly / check /
control valves, field and DCS instrument bubbles, dashed signal lines, off-page connectors, boundaries, title block).
The answer is the exact extraction (validated with pid-to-kg's own PageExtraction model). The question is the same one
`pid_kg read` asks at run time (agent.pid_read_prompt), so training matches use. Images are made at training time
(not stored in the repo).

    python training/synth_pid.py --n 300 --out data/synth_pid_train.jsonl --img-dir data/pid_images
"""
import argparse, json, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent, polyglot   # noqa: E402

W, H = 16.5, 11.7                           # A3 landscape, inches
PX = 1280                                   # long edge of the image = what `look` / `pid_kg read` send


def _bb(x, y, w, h):
    return [round(x - w / 2, 4), round(y - h / 2, 4), round(x + w / 2, 4), round(y + h / 2, 4)]


class Sheet:
    def __init__(self, r):
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        self.plt, self.r = plt, r
        self.fig = plt.figure(figsize=(W, H), dpi=PX / W)
        self.ax = self.fig.add_axes([0, 0, 1, 1])
        self.ax.set_xlim(0, 1)
        self.ax.set_ylim(1, 0)                     # y down: (0, 0) = top left, like the bboxes
        self.ax.axis('off')
        self.ax.add_patch(plt.Rectangle((0.01, 0.01), 0.98, 0.98, fill=False, lw=1.2))

    def text(self, x, y, s, size=8, **kw):
        self.ax.text(x, y, s, fontsize=size, ha='center', va='center', family='DejaVu Sans', **kw)

    def line(self, pts, dashed=False, arrow=False, lw=1.2):
        xs, ys = zip(*pts)
        self.ax.plot(xs, ys, color='k', lw=lw, ls=(0, (4, 3)) if dashed else '-')
        if arrow:
            (x0, y0), (x1, y1) = pts[-2], pts[-1]
            self.ax.annotate('', xy=(x1, y1), xytext=(x0 + (x1 - x0) * 0.6, y0 + (y1 - y0) * 0.6),
                             arrowprops=dict(arrowstyle='-|>', color='k', lw=lw))

    def tank(self, x, y, tag, name):
        w, h = 0.09, 0.22
        self.ax.add_patch(self.plt.Rectangle((x - w / 2, y - h / 2), w, h, fill=False, lw=1.5))
        self.text(x, y - 0.02, tag, 9, weight='bold')
        self.text(x, y + 0.02, name, 6)
        return _bb(x, y, w, h)

    def pump(self, x, y, tag):
        rx = 0.022
        self.ax.add_patch(self.plt.matplotlib.patches.Ellipse((x, y), 2 * rx, 2 * rx * W / H, fill=False, lw=1.5))
        self.ax.plot([x - rx * 0.7, x + rx, x - rx * 0.7, x - rx * 0.7], [y - rx * W / H * 0.7, y, y + rx * W / H * 0.7, y - rx * W / H * 0.7],
                     color='k', lw=1)
        self.text(x, y + 0.05, tag, 8)
        return _bb(x, y, 2 * rx, 2 * rx * W / H)

    def valve(self, x, y, kind, tag=None):
        a, b = 0.011, 0.012
        self.ax.fill([x - a, x + a, x + a, x - a], [y - b, y + b, y - b, y + b], fill=kind == 'check_valve', color='k' if kind == 'check_valve' else None,
                     edgecolor='k', lw=1.2)
        if kind == 'ball_valve':
            self.ax.add_patch(self.plt.matplotlib.patches.Ellipse((x, y), 0.006, 0.006 * W / H, color='k'))
        if kind == 'butterfly_valve':
            self.ax.plot([x, x], [y - b * 1.4, y + b * 1.4], color='k', lw=1)
        if kind == 'control_valve':
            self.ax.plot([x, x], [y, y - 0.035], color='k', lw=1)
            self.ax.add_patch(self.plt.matplotlib.patches.Arc((x, y - 0.035), 0.022, 0.03, theta1=180, theta2=360, lw=1.2))
            self.ax.plot([x - 0.011, x + 0.011], [y - 0.035, y - 0.035], color='k', lw=1)
        if tag:
            self.text(x, y + 0.03, tag, 7)
        return _bb(x, y, 2 * a, 2 * b + (0.05 if kind == 'control_valve' else 0))

    def bubble(self, x, y, tag, dcs=False):
        rx = 0.017
        ry = rx * W / H
        self.ax.add_patch(self.plt.matplotlib.patches.Ellipse((x, y), 2 * rx, 2 * ry, fill=False, lw=1))
        if dcs:
            self.ax.add_patch(self.plt.Rectangle((x - rx, y - ry), 2 * rx, 2 * ry, fill=False, lw=1))
        letters, num = tag.split('-', 1)
        self.text(x, y - ry * 0.35, letters, 6.5)
        self.text(x, y + ry * 0.4, num, 6.5)
        return _bb(x, y, 2 * rx, 2 * ry)

    def save(self, path):
        self.fig.savefig(path, dpi=PX / W)
        self.plt.close(self.fig)


def make(r, n, png):
    """draw one sheet -> its exact extraction (dict)"""
    s = Sheet(r)
    u = r.choice([1, 2, 3, 4, 5, 6, 7])
    k = lambda i: f'{u}{i:02d}'
    eq, comp, ins, lines, sig, opc, bnd = [], [], [], [], [], [], []
    y = round(r.uniform(0.5, 0.62), 3)
    names = [('RAW WATER SUPPLY', 'FROM CLARIFIER', 'FROM WELL PUMPS', 'FROM SUMP'), ('FEED TANK', 'BUFFER TANK', 'EQUALIZATION TANK'),
             ('TO FILTERS', 'TO PRODUCT TANK', 'TO DISCHARGE', 'TO REACTOR')]
    src_name = r.choice(names[0])
    if r.random() < 0.5:
        bnd.append({'id': 'B1', 'name': src_name, 'direction': 'source', 'bbox': _bb(0.045, y - 0.0, 0.06, 0.03)})
        s.text(0.045, y - 0.03, src_name, 6)
        s.ax.add_patch(s.plt.Polygon([(0.02, y - 0.012), (0.06, y - 0.012), (0.07, y), (0.06, y + 0.012), (0.02, y + 0.012)], fill=False))
        src = 'B1'
    else:
        dwg = f'PID-{u}0{max(1, n - 1)}'
        opc.append({'id': 'OPC1', 'direction': 'in', 'name': src_name, 'other_drawing': dwg, 'bbox': _bb(0.045, y, 0.06, 0.03)})
        s.ax.add_patch(s.plt.Polygon([(0.02, y - 0.012), (0.06, y - 0.012), (0.07, y), (0.06, y + 0.012), (0.02, y + 0.012)], fill=False))
        s.text(0.045, y, dwg, 6)
        s.text(0.045, y - 0.03, src_name, 6)
        src = 'OPC1'
    tk = f'TK-{k(1)}'
    tname = r.choice(names[1])
    eq.append({'id': tk, 'tag': tk, 'kind': 'tank', 'name': tname, 'bbox': s.tank(0.2, y - 0.05, tk, tname)})
    s.line([(0.07, y), (0.155, y)], arrow=True)
    lines.append({'id': 'L1', 'from': src, 'to': tk, 'path': []})
    pv = f'P-{k(1)}'
    eq.append({'id': pv, 'tag': pv, 'kind': 'centrifugal_pump', 'name': None, 'bbox': s.pump(0.46, y + 0.02, pv)})
    eq[-1].pop('name')
    v1k = r.choice(['gate_valve', 'ball_valve', 'butterfly_valve'])
    comp.append({'id': 'V1', 'kind': v1k, 'bbox': s.valve(0.33, y + 0.02, v1k)})
    s.line([(0.245, y + 0.02), (0.438, y + 0.02)], arrow=True)
    lines.append({'id': 'L2', 'from': tk, 'to': pv, 'path': ['V1']})
    path3, x = [], 0.53
    comp.append({'id': 'V2', 'kind': 'check_valve', 'bbox': s.valve(x, y + 0.02, 'check_valve')})
    path3.append('V2')
    loop_f = r.random() < 0.8
    fv = f'FV-{k(2)}'
    if r.random() < 0.5:
        pi = f'PI-{k(3)}'
        ins.append({'id': pi, 'tag': pi, 'location': 'field', 'measures': {'line': 'L3', 'after': 'V2'}, 'bbox': s.bubble(0.575, y - 0.07, pi)})
        s.line([(0.575, y + 0.02), (0.575, y - 0.07 + 0.024)], lw=0.8)
    if loop_f:
        ft, fic = f'FT-{k(2)}', f'FIC-{k(2)}'
        s.ax.add_patch(s.plt.Rectangle((0.64 - 0.012, y + 0.02 - 0.012), 0.024, 0.024, fill=False, lw=1))
        ins.append({'id': ft, 'tag': ft, 'location': 'field', 'bbox': [round(0.628, 4), round(y + 0.008, 4), round(0.652, 4), round(y + 0.032, 4)]})
        s.text(0.64, y + 0.05, ft, 7)
        path3.append(ft)
        ins.append({'id': fic, 'tag': fic, 'location': 'dcs', 'bbox': s.bubble(0.7, y - 0.17, fic, dcs=True)})
        comp.append({'id': fv, 'tag': fv, 'kind': 'control_valve', 'actuator': 'pneumatic', 'fail_position': r.choice(['FC', 'FO']),
                     'bbox': s.valve(0.76, y + 0.02, 'control_valve', fv)})
        path3.append(fv)
        s.line([(0.64, y + 0.008), (0.64, y - 0.17), (0.683, y - 0.17)], dashed=True, lw=0.8)
        s.line([(0.717, y - 0.17), (0.76, y - 0.17), (0.76, y + 0.02 - 0.05)], dashed=True, lw=0.8)
        sig += [{'from': ft, 'to': fic, 'type': 'electrical', 'purpose': 'measurement'},
                {'from': fic, 'to': fv, 'type': 'electrical', 'purpose': 'control'}]
    else:
        vk = r.choice(['gate_valve', 'globe_valve' if False else 'ball_valve'])
        comp.append({'id': 'V3', 'kind': vk, 'bbox': s.valve(0.76, y + 0.02, vk)})
        path3.append('V3')
    if r.random() < 0.6:
        lt, lic = f'LT-{k(4)}', f'LIC-{k(4)}'
        ins.append({'id': lt, 'tag': lt, 'location': 'field', 'measures': {'item': tk}, 'bbox': s.bubble(0.29, y - 0.2, lt)})
        ins.append({'id': lic, 'tag': lic, 'location': 'dcs', 'bbox': s.bubble(0.29, y - 0.33, lic, dcs=True)})
        s.line([(0.245, y - 0.12), (0.29, y - 0.12), (0.29, y - 0.2 + 0.024)], lw=0.8)
        s.line([(0.29, y - 0.2 - 0.024), (0.29, y - 0.33 + 0.024)], dashed=True, lw=0.8)
        sig.append({'from': lt, 'to': lic, 'type': 'electrical', 'purpose': 'measurement'})
        if loop_f and r.random() < 0.6:
            fic = f'FIC-{k(2)}'
            s.line([(0.307, y - 0.33), (0.7, y - 0.33), (0.7, y - 0.17 - 0.024)], dashed=True, lw=0.8)
            sig.append({'from': lic, 'to': fic, 'type': 'software', 'purpose': 'control'})
    if r.random() < 0.35:
        ls = f'LSLL-{k(5)}'
        ins.append({'id': ls, 'tag': ls, 'location': 'field', 'measures': {'item': tk}, 'bbox': s.bubble(0.12, y + 0.16, ls)})
        s.line([(0.155, y + 0.04), (0.12, y + 0.04), (0.12, y + 0.16 - 0.024)], lw=0.8)
        s.line([(0.137, y + 0.16), (0.46, y + 0.16), (0.46, y + 0.02 + 0.031)], dashed=True, lw=0.8)
        sig.append({'from': ls, 'to': pv, 'type': 'electrical', 'purpose': 'trip'})
    dst_name = r.choice(names[2])
    if r.random() < 0.5:
        dwg = f'PID-{u}0{n + 1}'
        opc.append({'id': 'OPC2', 'direction': 'out', 'name': dst_name, 'other_drawing': dwg, 'bbox': _bb(0.92, y + 0.02, 0.06, 0.03)})
        s.ax.add_patch(s.plt.Polygon([(0.89, y + 0.008), (0.94, y + 0.008), (0.95, y + 0.02), (0.94, y + 0.032), (0.89, y + 0.032)], fill=False))
        s.text(0.92, y + 0.02, dwg, 6)
        s.text(0.92, y - 0.012, dst_name, 6)
        dst = 'OPC2'
    else:
        bnd.append({'id': 'B2', 'name': dst_name, 'direction': 'sink', 'bbox': _bb(0.92, y + 0.02, 0.06, 0.03)})
        s.ax.add_patch(s.plt.Polygon([(0.89, y + 0.008), (0.94, y + 0.008), (0.95, y + 0.02), (0.94, y + 0.032), (0.89, y + 0.032)], fill=False))
        s.text(0.92, y - 0.012, dst_name, 6)
        dst = 'B2'
    s.line([(0.482, y + 0.02), (0.89, y + 0.02)], arrow=True)
    line_no = f'{r.choice([2, 3, 4, 6])}"-{r.choice(["PW", "RW", "TW", "SL"])}-{k(3)}'
    s.text(0.83, y + 0.005, line_no, 6)
    lines.append({'id': 'L3', 'line_number': line_no, 'from': pv, 'to': dst, 'path': path3})
    dno, title, rev = f'PID-{u}0{n}', r.choice(['FEED AND TRANSFER', 'TANK AND PUMP STATION', 'TRANSFER SYSTEM']), r.choice(['A', 'B', '0', '1'])
    s.ax.add_patch(s.plt.Rectangle((0.7, 0.88), 0.28, 0.1, fill=False, lw=1))
    s.text(0.84, 0.905, title, 8, weight='bold')
    s.text(0.84, 0.94, f'DRAWING {dno}    REV {rev}', 7)
    s.save(png)
    ext = {'schema_version': '1.0', 'page': n, 'sheet': {'drawing_number': dno, 'title': title, 'revision': rev, 'drawing_type': 'pid', 'rotation': 0},
           'equipment': eq, 'components': comp, 'instruments': ins, 'lines': lines, 'signals': sig, 'off_page_connectors': opc,
           'boundaries': bnd}
    sys.path.insert(0, os.path.join(polyglot.repo_dir('PID-to-Knowledge-Graph'), 'skills', 'pid-to-kg', 'scripts'))
    from pidkg.models import PageExtraction
    PageExtraction.model_validate(ext)                     # the answer key is valid pid-to-kg data
    return ext


def describe(ext):
    """the answer to 'what does this drawing show' from the answer key"""
    eq = ', '.join(f"{e['tag']} ({e['kind'].replace('_', ' ')}{', ' + e['name'].lower() if e.get('name') else ''})" for e in ext['equipment'])
    flow = ' -> '.join([ext['lines'][0]['from']] + [ln['to'] for ln in ext['lines']])
    names = {x['id']: x.get('name') or x['id'] for x in ext['boundaries'] + ext['off_page_connectors']}
    flow = ' -> '.join(names.get(p, p) for p in flow.split(' -> '))
    loops = [f"{x['from']} -> {x['to']} ({x['purpose']})" for x in ext['signals']]
    return (f"P&ID {ext['sheet']['drawing_number']} rev {ext['sheet']['revision']}, '{ext['sheet']['title'].lower()}'. Equipment: {eq}. "
            f"Flow: {flow}. Instruments: {', '.join(i['tag'] for i in ext['instruments']) or 'none'}. "
            f"Signals: {'; '.join(loops) or 'none'}.")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--n', type=int, default=300)
    ap.add_argument('--out', default='data/synth_pid_train.jsonl')
    ap.add_argument('--img-dir', default='data/pid_images')
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    os.makedirs(a.img_dir, exist_ok=True)
    example = open(os.path.join(polyglot.repo_dir('PID-to-Knowledge-Graph'), 'tests', 'fixtures', 'mini_plant', 'extract', 'page_01.json'),
                   encoding='utf-8').read()
    out_dir = os.path.dirname(os.path.abspath(a.out))
    sysmsg = {'role': 'system', 'content': agent.system_prompt(agent.Tools(out_dir))}
    n_ok = 0
    with open(a.out, 'w', encoding='utf-8') as f:
        for i in range(a.n):
            page = r.randint(1, 9)
            png = os.path.join(a.img_dir, f'pid_{i:04d}.png')
            ext = make(r, page, png)
            rel = os.path.relpath(png, out_dir)
            tags = ', '.join(x['tag'] for x in ext['equipment'] + ext['components'] + ext['instruments'] if x.get('tag'))
            if r.random() < 0.75:                           # read the sheet into the pid-to-kg format
                msgs = [{'role': 'user', 'content': agent.pid_read_prompt(page, tags if r.random() < 0.7 else '', example)},
                        {'role': 'assistant', 'content': json.dumps(ext, separators=(',', ':'))}]
            else:                                           # look: what does the drawing show
                msgs = [sysmsg, {'role': 'user', 'content': r.choice(['What does this drawing show?', 'Describe this P&ID.',
                                                                     'Explain this sheet: equipment, flow, instruments and loops.'])},
                        {'role': 'assistant', 'content': describe(ext)}]
            f.write(json.dumps({'task': 'synth_pid', 'images': [rel], 'messages': msgs}) + '\n')
            n_ok += 1
    print(a.out, n_ok, 'samples with images in', a.img_dir)


if __name__ == '__main__':
    main()
