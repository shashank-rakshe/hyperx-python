"""
Construction drawings -> training samples, with ConstructDrawingAI (copied whole, run as written; PolyForm
Noncommercial - ShipBrain is declared non-commercial, see shipbrain/licence_mode.json).

Its synthetic engine draws electrical drawing sets - power & lighting plan, single-line diagram, panel schedule - in
many styles and with scan-like damage, together with the exact answer key (CIR) and question / answer pairs that are
correct by construction (its validator checks every set). From them:
  pictures   the vision model reads the sheet itself: symbol counts, takeoff with MasterFormat codes, panel voltage /
             circuits from the schedule, home-run panel, panels on the single-line diagram
  tools      drawing_takeoff / drawing_qa on the CIR file (real engine output)

    python training/construct_tasks.py --n 250 --out data/construct_train.jsonl --img-dir data/construct_images
"""
import argparse, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent, construct   # noqa: E402

PX = 1280


def tb(name, args):
    return '```tool\n' + json.dumps({'name': name, 'args': args}) + '\n```'


def res(name, out):
    return {'role': 'user', 'content': f'TOOL_RESULT {name}: ' + agent.compact_result(out)}


def _img(src, dst):
    from PIL import Image
    im = Image.open(src).convert('RGB')
    s = PX / max(im.size)
    if s < 1:
        im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    im.save(dst, optimize=True)
    return dst


def _say(q, a, sheet):
    ql = q.lower()
    if ql.startswith('how many'):
        what = q[8:].split(' are ')[0].split(' in ')[0].strip(" ?'")
        return f'{a} {what.replace(chr(39), "")} - counted on the {sheet}.'
    if 'voltage' in ql:
        return f'The panel is {a} (from the {sheet}).'
    if 'home-run' in ql or 'home run' in ql:
        return f'The home-run circuits return to panel {a}.'
    return f'{a} (from the {sheet}).'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--n', type=int, default=250, help='drawing sets to generate')
    ap.add_argument('--out', default='data/construct_train.jsonl')
    ap.add_argument('--img-dir', default='data/construct_images')
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    tmp = tempfile.mkdtemp(prefix='sb_cdai_')
    sets = construct.generate(os.path.join(tmp, 'gen'), n=a.n, seed=a.seed)
    os.makedirs(a.img_dir, exist_ok=True)
    out_dir = os.path.dirname(os.path.abspath(a.out))
    work = os.path.join(tmp, 'work')
    os.makedirs(work)
    T = agent.Tools(work)
    sysmsg = {'role': 'system', 'content': agent.system_prompt(T)}
    rows = []
    for k, d in enumerate(sets):
        info = construct.info(os.path.join(d, 'ground_truth.cir'))
        tk = construct.takeoff(os.path.join(d, 'ground_truth.cir'))
        titles = {s['number']: (s['title'] or s['number']) for s in info['sheets']}
        by_title = {v.lower(): n for n, v in titles.items()}
        plan_no = next((n for t, n in by_title.items() if 'plan' in t), None)
        sched_no = next((n for t, n in by_title.items() if 'schedule' in t), None)
        sl_no = next((n for t, n in by_title.items() if 'single' in t), None)
        deg = r.random() < 0.6                                       # mostly the scan-damaged copy, sometimes clean

        def pic(stem):
            src = os.path.join(d, stem + ('.deg.png' if deg and os.path.exists(os.path.join(d, stem + '.deg.png')) else '.png'))
            dst = os.path.join(a.img_dir, f'cdai_{k:04d}_{stem}.png')
            return os.path.relpath(_img(src, dst), out_dir)
        codes = {ln['item']: ln.get('masterformat') for ln in tk['lines']}
        qa = info['qa_pairs']
        # 1. plan picture: counts / takeoff
        if plan_no:
            img = pic('plan')
            sheet = f'{titles[plan_no]} ({plan_no})'
            plan_q = [p for p in qa if 'plan' in p['question'].lower() or 'home-run' in p['question'].lower()]
            for p in r.sample(plan_q, min(2, len(plan_q))):
                rows.append({'task': 'cdai_look', 'images': [img], 'messages': [sysmsg, {'role': 'user', 'content': p['question']},
                                                                                 {'role': 'assistant', 'content': _say(p['question'], p['answer'], sheet)}]})
            counts = tk['by_sheet'].get(plan_no, {})
            if counts:
                lines = '\n'.join(f'- {item}: {n} EA' + (f' (MasterFormat {codes[item]})' if codes.get(item) else '')
                                  for item, n in sorted(counts.items(), key=lambda x: -x[1]))
                rows.append({'task': 'cdai_takeoff_look', 'images': [img], 'messages': [
                    sysmsg, {'role': 'user', 'content': r.choice(['Do a quantity takeoff of this plan.', 'Count the symbols on this drawing by type.',
                                                                  'What devices are on this electrical plan and how many of each?'])},
                    {'role': 'assistant', 'content': f'{sheet}, counted symbol by symbol:\n{lines}\nTotal: {sum(counts.values())} devices.'}]})
        # 2. panel schedule picture
        if sched_no:
            sq = [p for p in qa if 'panel' in p['question'].lower() and 'home-run' not in p['question'].lower()]
            if sq:
                img = pic('schedule')
                p = r.choice(sq)
                rows.append({'task': 'cdai_look', 'images': [img], 'messages': [sysmsg, {'role': 'user', 'content': p['question']},
                                                                                 {'role': 'assistant', 'content': _say(p['question'], p['answer'], f'{titles[sched_no]} ({sched_no})')}]})
        # 3. single-line picture
        if sl_no and tk['by_sheet'].get(sl_no):
            img = pic('single_line')
            c = tk['by_sheet'][sl_no]
            rows.append({'task': 'cdai_look', 'images': [img], 'messages': [sysmsg, {'role': 'user', 'content': r.choice(
                ['What is on this single-line diagram?', 'Which equipment does this single-line diagram show?'])},
                {'role': 'assistant', 'content': f'{titles[sl_no]} ({sl_no}): ' + ', '.join(f'{n} x {item}' for item, n in c.items()) + '.'}]})
        # 4. tools on the CIR file (every 3rd set: the tool calls are the same shape every time)
        if k % 3 == 0:
            fname = f'set_{k}.cir'
            shutil.copy(os.path.join(d, 'ground_truth.cir'), os.path.join(work, fname))
            if r.random() < 0.5:
                args = {'file': fname}
                out = T.call('drawing_takeoff', args)
                ask = r.choice([f'Takeoff of {fname}', f'Give me the quantities in {fname} with spec sections', f'Count everything in {fname}'])
                tool = 'drawing_takeoff'
            else:
                q = r.choice(['How many receptacles are there?', 'List the panels', 'How many light fixtures are there?',
                              'How many switches are there?', 'What disciplines are in this set?'])
                args = {'file': fname, 'question': q}
                out = T.call('drawing_qa', args)
                ask, tool = f'{q} ({fname})', 'drawing_qa'
            if 'error' not in out:
                rows.append({'task': 'cdai_tool', 'messages': [sysmsg, {'role': 'user', 'content': ask}, {'role': 'assistant', 'content': tb(tool, args)},
                                                               res(tool, out), {'role': 'assistant', 'content': out['plain_english']}]})
    with open(a.out, 'w', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    shutil.rmtree(tmp, ignore_errors=True)
    print(a.out, len(rows), 'samples,', sum(1 for x in rows if x.get('images')), 'with pictures in', a.img_dir)


if __name__ == '__main__':
    main()
