"""
cadmpeg training samples from real runs: the public specimens of cadmpeg's corpus (CC0 donations and NIST public-domain
PMI models, listed with their licence in corpus/manifest.toml) are inspected, converted to STEP, measured and compared
by the real cadmpeg program through ShipBrain's native_cad tool, and each question -> tool call -> result -> plain answer
is written. Needs the cadmpeg program and a clone of its repo (run where they exist; the result is committed).

    python training/cadmpeg_tasks.py --corpus <cadmpeg clone>/corpus --out training/data/cadmpeg_train.jsonl.gz
"""
import argparse, gzip, json, os, random, re, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

OK = ('CC0-1.0', 'LicenseRef-NIST-PD')
ASK = {
    'convert': ['Convert {f} to STEP', 'I have {f} but no {app}. Make a STEP from it.', '{f} ko STEP me badlo',
                'Open {f} and give me a neutral CAD file', 'Can you read {f}? Export it as STEP.'],
    'inspect': ['What is inside {f}?', 'Which version / format is {f}?', 'Inspect {f}', 'Tell me about the file {f}'],
    'measure': ['Volume and mass of {f} in steel (7850 kg/m3)?', 'Measure the bodies in {f}, density {d} kg/m3',
                'How big is the part in {f}?', '{f}: weight in aluminium (2700 kg/m3)?'],
    'diff': ['Did the STEP export of {f} keep the geometry? Compare them.', 'Compare {f} with {s}'],
}


def entries(manifest):
    try:
        import tomllib
    except ImportError:
        import tomli as tomllib
    return [e for e in tomllib.load(open(manifest, 'rb')).get('file', []) if e.get('license') in OK]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', required=True)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'cadmpeg_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge, cadmpeg
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_cm_')
    T = agent.Tools(work, knowledge.load(None))
    rows, skipped = [], 0
    try:
        for e in entries(os.path.join(a.corpus, 'manifest.toml')):
            src = os.path.join(a.corpus, e['filename'])
            if not os.path.exists(src) or os.path.getsize(src) > 60e6:
                skipped += 1
                continue
            f = os.path.basename(src)
            shutil.copy(src, os.path.join(work, f))
            app = cadmpeg.NATIVE.get(os.path.splitext(f)[1].lower(), 'the CAD program')
            native = cadmpeg.is_native(f)
            ops = (['inspect', 'convert', 'measure'] + (['diff'] if native else [])) if native else ['inspect', 'measure']
            step = None
            for op in ops:
                args = {'file': f, 'op': op}
                q = r.choice(ASK[op])
                d = r.choice([7850, 2700, 1240])
                if op == 'measure':
                    args['density'] = 2700 if 'aluminium' in q else (7850 if 'steel' in q else d if '{d}' in q else None)
                    if args['density'] is None:
                        args.pop('density')
                if op == 'diff':
                    if not step:
                        continue
                    args['other'] = step
                out = T.call('native_cad', args)
                if 'error' in out:
                    skipped += 1
                    continue
                if op == 'convert':
                    step = out.get('file')
                if op == 'inspect':
                    out = {'ok': out.get('ok'), 'text': out.get('text', '')[:2500], 'plain_english': out.get('plain_english')}
                    ans = out['plain_english'] + ' I can convert it to STEP, measure it or compare it with another file.'
                else:
                    ans = out.get('plain_english')
                if not ans:
                    continue
                rows.append({'task': 'native_cad', 'messages': [
                    {'role': 'user', 'content': q.format(f=f, app=app.split()[0], d=d, s=step or '')},
                    {'role': 'assistant', 'content': tool_block('native_cad', args)},
                    result_msg('native_cad', out), {'role': 'assistant', 'content': ans}]})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    s = json.dumps(rows)
    assert work not in s and '/tmp/' not in s and '/home/' not in s, 'local paths leaked into the samples'
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples;', skipped, 'skipped')


if __name__ == '__main__':
    main()
