"""
DEXPI P&IDs (pyDEXPI, copied whole; its real example P&IDs: the DEXPI reference P&ID, the 36 DEXPI training test cases,
a CO2 terminal and the Tennessee Eastman plant) -> training samples, answers from pyDEXPI's own reading:

  tools     summary / validate of each file (dexpi tool)
  pictures  the P&ID drawn by pyDEXPI -> "which equipment / instruments are on this P&ID?" -> the exact tags and classes
            (only files that carry drawing data)

    python training/dexpi_tasks.py --out data/dexpi_train.jsonl --img-dir data/dexpi_images
"""
import argparse, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent, dexpi   # noqa: E402

PX = 1280
ASK_SUM = ['What is on the P&ID {f}?', 'List the equipment and instruments in {f}', 'Summarise the DEXPI file {f}',
           'Which pumps, tanks and heat exchangers are in {f}?']
ASK_VAL = ['Is {f} a valid DEXPI file?', 'Check {f} against the DEXPI rules', 'Validate the P&ID {f}']
ASK_PIC = ['Which equipment is on this P&ID? Give the tags.', 'Read the equipment tags and instrument tags from this P&ID.',
           'What does this P&ID show?', 'List every tagged item on this drawing.']


def tb(name, args):
    return '```tool\n' + json.dumps({'name': name, 'args': args}) + '\n```'


def res(name, out):
    return {'role': 'user', 'content': f'TOOL_RESULT {name}: ' + agent.compact_result(out)}


def _img(src, dst):
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    im = Image.open(src).convert('RGB')
    k = PX / max(im.size)
    if k < 1:
        im = im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    im.save(dst, optimize=True)
    return dst


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='data/dexpi_train.jsonl')
    ap.add_argument('--img-dir', default='data/dexpi_images')
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_dexpi_')
    T = agent.Tools(work)
    sysmsg = {'role': 'system', 'content': agent.system_prompt(T)}
    out_dir = os.path.dirname(os.path.abspath(a.out))
    rows = []
    for i, f in enumerate(dexpi.examples()):
        fname = os.path.basename(f).replace(' ', '_')
        if os.path.exists(os.path.join(work, fname)):
            fname = f'{i}_{fname}'
        shutil.copy(f, os.path.join(work, fname))
        s = T.call('dexpi', {'action': 'summary', 'file': fname})
        if 'error' in s:
            print('skip', fname, s['error'][:150])
            continue
        rows.append({'task': 'dexpi_summary', 'messages': [sysmsg, {'role': 'user', 'content': r.choice(ASK_SUM).format(f=fname)},
                                                           {'role': 'assistant', 'content': tb('dexpi', {'action': 'summary', 'file': fname})},
                                                           res('dexpi', s), {'role': 'assistant', 'content': s['plain_english']}]})
        v = T.call('dexpi', {'action': 'validate', 'file': fname})
        if 'error' not in v:
            v['plain_english'] = v['plain_english'].replace(work + os.sep, '')
            rows.append({'task': 'dexpi_validate', 'messages': [sysmsg, {'role': 'user', 'content': r.choice(ASK_VAL).format(f=fname)},
                                                                {'role': 'assistant', 'content': tb('dexpi', {'action': 'validate', 'file': fname})},
                                                                res('dexpi', v), {'role': 'assistant', 'content': v['plain_english']}]})
        if s['equipment'] or s['instruments']:
            try:
                png = dexpi.png(os.path.join(work, fname), os.path.join(work, os.path.splitext(fname)[0] + '.png'), scale=3.0)
            except Exception as e:
                print('no drawing', fname, str(e)[:100])
                continue
            img = os.path.relpath(_img(png, os.path.join(a.img_dir, f'dexpi_{i:03d}.png')), out_dir)
            for q in r.sample(ASK_PIC, 2):
                rows.append({'task': 'dexpi_look', 'images': [img], 'messages': [sysmsg, {'role': 'user', 'content': q},
                                                                                {'role': 'assistant', 'content': s['plain_english']}]})
        print(fname, 'ok', flush=True)
    with open(a.out, 'w', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x).replace(work + os.sep, '').replace(work, '') + '\n')   # no temporary paths
    shutil.rmtree(work, ignore_errors=True)
    print(a.out, len(rows), 'samples', sum(1 for x in rows if x.get('images')), 'with pictures')


if __name__ == '__main__':
    main()
