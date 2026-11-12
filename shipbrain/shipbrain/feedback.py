"""
From 👍 / 👎 in the app to a better model, safely (all on the user's side; nothing is published):

  python -m shipbrain.feedback export  --workdir <app work folder> --out feedback_export/        collect + scrub
  python -m shipbrain.feedback upload  --dataset <kaggle-user>/shipbrain-feedback                 private Kaggle dataset
  python -m shipbrain.feedback retrain --dataset <kaggle-user>/shipbrain-feedback                 export + upload + request

What happens to the data:
  * export   reads the app's feedback.jsonl (and memory.jsonl corrections), drops records that cannot teach anything
             (a thumbs-down without a correction, empty or one-turn records), removes duplicates, and SCRUBS private
             details: e-mail addresses, folder paths with user names, and every word / phrase listed in
             --scrub-file (one per line: ship names, hull numbers, company names - the standing rule is that none of
             these may reach any model or repository).
  * upload   a PRIVATE Kaggle dataset (kaggle CLI, your own credentials); never GitHub.
  * retrain  writes training/TRAIN_REQUEST.json with the dataset attached; committing / pushing it starts the Kaggle run
             (.github/workflows/shipbrain-train.yml). The run turns the feedback into DPO pairs and training samples, and
             training/accept_gate.py accepts the new model only if the scorecard did not get worse.
"""
import argparse, json, os, re, subprocess, sys, time

EMAIL = re.compile(r'[\w.+-]+@[\w-]+(\.[\w-]+)+')
PATH = re.compile(r'([A-Za-z]:\\Users\\[^\\\s"\']+|/home/[^/\s"\']+|/Users/[^/\s"\']+)')


def scrub_text(text, words=()):
    text = EMAIL.sub('<email>', text)
    text = PATH.sub('<user-folder>', text)
    for w in words:
        if w.strip():
            text = re.sub(re.escape(w.strip()), '<name>', text, flags=re.I)
    return text


def _scrub(obj, words):
    if isinstance(obj, str):
        return scrub_text(obj, words)
    if isinstance(obj, list):
        return [_scrub(x, words) for x in obj]
    if isinstance(obj, dict):
        return {k: _scrub(v, words) for k, v in obj.items()}
    return obj


def export(workdir, out, scrub_words=(), min_turns=2):
    """feedback.jsonl -> out/feedback.jsonl (scrubbed, de-duplicated, useful records only) + out/manifest.json"""
    src = os.path.join(workdir, 'feedback.jsonl')
    if not os.path.exists(src):
        raise FileNotFoundError(f'no feedback.jsonl in {workdir}: give a 👍 or a 👎 with a correction in the app first')
    os.makedirs(out, exist_ok=True)
    seen, rows, dropped = set(), [], {'no correction': 0, 'too short': 0, 'duplicate': 0, 'unreadable': 0}
    for line in open(src, encoding='utf-8'):
        try:
            r = json.loads(line)
        except ValueError:
            dropped['unreadable'] += 1
            continue
        msgs = r.get('messages') or []
        if len(msgs) < min_turns or msgs[-1].get('role') != 'assistant':
            dropped['too short'] += 1
            continue
        if not r.get('good') and not str(r.get('comment', '')).strip():
            dropped['no correction'] += 1                      # a bare 👎 tells what is wrong, not what is right
            continue
        key = json.dumps([r.get('good'), r.get('comment'), msgs[-1].get('content'), msgs[0].get('content')], sort_keys=True)
        if key in seen:
            dropped['duplicate'] += 1
            continue
        seen.add(key)
        rows.append(_scrub({'time': r.get('time'), 'good': bool(r.get('good')), 'comment': r.get('comment', ''), 'messages': msgs},
                           scrub_words))
    with open(os.path.join(out, 'feedback.jsonl'), 'w', encoding='utf-8') as f:
        for r in rows:
            f.write(json.dumps(r) + '\n')
    man = {'exported': time.strftime('%Y-%m-%d %H:%M'), 'records': len(rows), 'liked': sum(r['good'] for r in rows),
           'corrections': sum(not r['good'] for r in rows), 'dropped': dropped, 'scrub_words': len(list(scrub_words))}
    json.dump(man, open(os.path.join(out, 'manifest.json'), 'w'), indent=1)
    return man


def upload(out, dataset, kaggle='kaggle'):
    """private Kaggle dataset: created the first time, a new version afterwards"""
    meta = {'title': dataset.split('/')[-1], 'id': dataset, 'licenses': [{'name': 'other'}], 'isPrivate': True}
    json.dump(meta, open(os.path.join(out, 'dataset-metadata.json'), 'w'), indent=1)
    try:
        r = subprocess.run([kaggle, 'datasets', 'version', '-p', out, '-m', 'feedback ' + time.strftime('%Y-%m-%d'), '--dir-mode', 'zip'],
                           capture_output=True, text=True)
        if r.returncode:
            r = subprocess.run([kaggle, 'datasets', 'create', '-p', out, '--dir-mode', 'zip'], capture_output=True, text=True)
    except FileNotFoundError:
        raise RuntimeError('the kaggle program is not installed: pip install kaggle, then set KAGGLE_USERNAME and KAGGLE_KEY '
                           '(Kaggle > Settings > API > Create New Token). The exported files are in ' + out)
    text = (r.stdout + r.stderr).strip()
    if r.returncode:
        raise RuntimeError('Kaggle upload failed (is the kaggle CLI installed and KAGGLE_USERNAME / KAGGLE_KEY set?): ' + text[-400:])
    return text


def request(dataset, path):
    """training/TRAIN_REQUEST.json with the feedback dataset attached (other fields kept)"""
    req = json.load(open(path)) if os.path.exists(path) else {}
    ds = [d for d in (req.get('datasets') or []) if d != dataset] + [dataset]
    req['datasets'] = ds
    req['requested'] = time.strftime('%Y-%m-%d %H:%M')
    json.dump(req, open(path, 'w'), indent=1)
    return req


def main(argv=None):
    ap = argparse.ArgumentParser(prog='python -m shipbrain.feedback', description=__doc__.split('\n\n')[0])
    ap.add_argument('cmd', choices=['export', 'upload', 'retrain'])
    ap.add_argument('--workdir', default='.', help="the app's work folder (holds feedback.jsonl)")
    ap.add_argument('--out', default='feedback_export')
    ap.add_argument('--dataset', help='your PRIVATE Kaggle dataset, e.g. myname/shipbrain-feedback')
    ap.add_argument('--scrub-file', help='text file: one name / phrase per line to remove (ships, hull numbers, companies)')
    ap.add_argument('--request', default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'training', 'TRAIN_REQUEST.json'))
    a = ap.parse_args(argv)
    words = [l.strip() for l in open(a.scrub_file, encoding='utf-8')] if a.scrub_file else []
    if a.cmd in ('export', 'retrain'):
        man = export(a.workdir, a.out, words)
        print(f"exported {man['records']} records ({man['liked']} liked, {man['corrections']} corrections) to {a.out}; dropped {man['dropped']}")
        if not man['records']:
            sys.exit('nothing useful to train on yet')
    if a.cmd in ('upload', 'retrain'):
        if not a.dataset:
            sys.exit('give --dataset <kaggle-user>/<name>')
        print(upload(a.out, a.dataset))
    if a.cmd == 'retrain':
        req = request(a.dataset, a.request)
        print(f'wrote {a.request}: {req}\nCommit and push it to start the Kaggle run; the new model is accepted only if the scorecard did not get worse.')


if __name__ == '__main__':
    main()
