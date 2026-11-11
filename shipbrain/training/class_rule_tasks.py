"""
Class rules -> training samples, every answer in natural language with the rule it comes from.

  calculators   IACS UR S11 / S7 / S4 longitudinal strength and k factor for many ship sizes (class_rule tool)
  rule texts    every section with a formula in the class rule packs (packs/class_rules_*.private.sbpack, built from
                the societies' own rule books by `python -m shipbrain.classrules`): "what is the formula / requirement
                for ... in <society> rules?" -> class_rule search -> the requirement in words + the formula + where its
                symbols are defined + document, section, page
These packs are private (copyright of each society): the model trained on them is private too (the Kaggle run then
keeps it off GitHub).

    python training/class_rule_tasks.py --packs packs --out data/class_rule_train.jsonl
"""
import argparse, glob, json, os, random, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent, knowledge, repopack   # noqa: E402

ASK_S11 = ['Check the longitudinal strength of a ship L = {L} m, B = {B} m, Cb = {Cb}{extra}',
           'What is the IACS wave bending moment for L {L} m, B {B} m, block coefficient {Cb}?',
           'Minimum hull girder section modulus by IACS for a {L} m ship, breadth {B} m, Cb {Cb}{extra}?',
           'UR S11 check: L={L}, B={B}, Cb={Cb}{extra}']
ASK_RULE = ['What is the formula for {t} in the {s} rules?', 'According to {s}, what is required for {t}?',
            'How does {s} calculate {t}?', '{s} rule for {t}?', 'Give me the {s} requirement on {t} with its formula']


def tb(name, args):
    return '```tool\n' + json.dumps({'name': name, 'args': args}) + '\n```'


def res(name, out):
    return {'role': 'user', 'content': f'TOOL_RESULT {name}: ' + agent.compact_result(out)}


def _where(text, formula):
    i = text.find(formula)
    tail = text[i + len(formula):] if i >= 0 else ''
    m = re.search(r'\bwhere\b(.{20,400}?)(?:\n\s*\n|\Z|(?=\n\d+(\.\d+)*\s+[A-Z]))', tail, re.S | re.I)
    return re.sub(r'\s+', ' ', m.group(1)).strip(' :.') if m else ''


def _first_sentences(text, n=2):
    t = re.sub(r'\s+', ' ', text)
    t = re.sub(r'^[\d.]+\s+[A-Z][^.]{0,80}?\s(?=[A-Z])', '', t)
    return ' '.join(re.split(r'(?<=[.:])\s+', t)[:n])[:400]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--packs', default='packs')
    ap.add_argument('--out', default='data/class_rule_train.jsonl')
    ap.add_argument('--n-calc', type=int, default=120)
    ap.add_argument('--max-per-pack', type=int, default=600)
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    rk = knowledge.Knowledge()
    packs = sorted(glob.glob(os.path.join(a.packs, 'class_rules_*.sbpack')))
    for p in packs:
        repopack.load_pack(p, rk)
    T = agent.Tools(tempfile.mkdtemp(), repo_kb=rk if packs else None)
    sysmsg = {'role': 'system', 'content': agent.system_prompt(T)}
    rows = []
    for _ in range(a.n_calc):                                   # calculators
        L = r.choice([95, 120, 150, 180, 200, 225, 250, 280, 300, 330, 366, 400])
        B = round(L / r.uniform(5.2, 7.2), 1)
        Cb = round(r.uniform(0.6, 0.86), 2)
        args = {'action': 'longitudinal', 'L': L, 'B': B, 'Cb': Cb}
        extra = ''
        if r.random() < 0.5:
            ys = r.choice([235, 315, 355])
            args['yield_mpa'] = ys
            extra += f', steel {ys} MPa'
        if r.random() < 0.5:
            args['Ms_hog'] = round(r.uniform(0.3, 0.9) * 190 * L ** 2 * B * Cb * 1e-3 * 9)
            extra += f', still-water moment {args["Ms_hog"]:,} kN m hogging'
        if r.random() < 0.4:
            args['Z_deck'] = round(r.uniform(0.8, 1.6) * L ** 2 * B * 15)
            extra += f', deck section modulus {args["Z_deck"]:,} cm3'
        if r.random() < 0.15:
            args = {'action': 'k', 'yield_mpa': r.choice([235, 315, 355, 390])}
            ask = f'What is the material factor k for {args["yield_mpa"]} MPa steel?'
        else:
            ask = r.choice(ASK_S11).format(L=L, B=B, Cb=Cb, extra=extra)
        out = T.call('class_rule', args)
        rows.append({'task': 'class_calc', 'messages': [sysmsg, {'role': 'user', 'content': ask}, {'role': 'assistant', 'content': tb('class_rule', args)},
                                                        res('class_rule', out), {'role': 'assistant', 'content': out['plain_english']}]})
    for p in packs:                                             # rule texts with formulas
        pk = repopack.read_pack(p)
        soc = pk['name'].replace('class_rules_', '')
        cands = [c for c in pk['chunks'] if c.get('formulas') and c.get('title')]
        r.shuffle(cands)
        for c in cands[:a.max_per_pack]:
            topic = re.sub(r'\(p\. \d+\)', '', c['title']).replace(soc, '').replace(c.get('document', ''), '').strip(' -')
            topic = re.sub(r'^[\d.]+\s*', '', topic).strip() or c.get('document', '')
            if len(topic) < 4:
                continue
            args = {'action': 'search', 'query': topic, 'society': soc}
            out = T.call('class_rule', args)
            hits = out.get('results') or []
            if not hits or hits[0]['id'] != c['id']:
                continue                                        # only when the search really finds this section
            f = c['formulas'][0]
            where = _where(c['text'], f)
            intro = _first_sentences(c['text'])
            said = re.sub(r'\s+', ' ', f) in intro
            ans = (f"{soc} {c.get('document', '')}" + (f", section {c['section']}" if c.get('section') else '') + f" (page {c.get('page')}), "
                   f"'{topic}': {intro}" + ('' if said else f" The formula is {f}" + (f", where {where}" if where else '') + '.')
                   + ' Check the current edition of the rule before use.')
            rows.append({'task': 'class_rule_text', 'messages': [sysmsg, {'role': 'user', 'content': r.choice(ASK_RULE).format(t=topic.lower(), s=soc)},
                                                                 {'role': 'assistant', 'content': tb('class_rule', args)}, res('class_rule', out),
                                                                 {'role': 'assistant', 'content': ans}]})
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, 'w', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples', sum(x['task'] == 'class_rule_text' for x in rows), 'from rule texts of', len(packs), 'pack(s)')


if __name__ == '__main__':
    main()
