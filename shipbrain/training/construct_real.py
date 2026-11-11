"""
Real construction / process drawings -> vision training samples (answers from the datasets' own ground truth).

  PID2Graph   (CC BY-SA 4.0, Zenodo 14803338): real OPEN100 P&IDs + Dataset-P&ID + synthetic sheets, every symbol box
              and every line connection annotated. Converted with ConstructDrawingAI's own converter (GraphML -> CIR).
              Questions: valves / instruments / other symbols, line connections, line types.
  CubiCasa5K  (CC BY-NC 4.0, Zenodo 2613548; non-commercial - ShipBrain is declared non-commercial): 5,000 real floor
              plans with every room (type), door and window annotated in model.svg.
              Questions: rooms by type, bedrooms, bathrooms, doors, windows.

The data is downloaded during training (Kaggle), never stored in the repo; only the pictures needed are kept, resized.
Local copies can be given instead: --pid2graph-dir / --cubicasa-dir.

    python training/construct_real.py --out data/construct_real_train.jsonl --img-dir data/construct_real_images
"""
import argparse, collections, json, os, random, re, shutil, sys, tempfile, urllib.request, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from shipbrain import agent, construct   # noqa: E402

PID2GRAPH_URL = 'https://zenodo.org/records/14803338/files/PID2Graph.zip?download=1'
CUBICASA_URL = 'https://zenodo.org/record/2613548/files/cubicasa5k.zip?download=1'
PX = 1280


def download(url, dst, log=print):
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return dst
    log(f'downloading {url} ...')
    req = urllib.request.Request(url, headers={'User-Agent': 'shipbrain-training'})
    with urllib.request.urlopen(req, timeout=120) as r, open(dst + '.part', 'wb') as f:
        shutil.copyfileobj(r, f, 1 << 22)
    os.replace(dst + '.part', dst)
    return dst


def _img(src, dst):
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    im = Image.open(src).convert('RGB')
    s = PX / max(im.size)
    if s < 1:
        im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
    im.save(dst, optimize=True)
    return dst


def _plural(n, word):
    return f'{n} {word}' + ('' if n == 1 else ('es' if word.endswith(('s', 'x', 'ch')) else 's'))


# ---------------------------------------------------------------------- PID2Graph
_SYM = {'valve': 'valve', 'instrumentation': 'instrument', 'general': 'other symbol'}


def pid2graph_samples(raw_root, img_dir, out_dir, r, cap, sysmsg):
    """raw_root holds PID2Graph/ (Complete/..., Patched/...)"""
    work = tempfile.mkdtemp(prefix='sb_p2g_')
    cirs = construct.convert_pid2graph(raw_root, work, cap=cap)
    rows = []
    for k, c in enumerate(cirs):
        info = construct.info(c)
        src = info['metadata'].get('src_image')
        if not src or not os.path.exists(src):
            continue
        tk = construct.takeoff(c)
        counts = {ln['item']: ln['qty'] for ln in tk['lines']}
        sym = {v: counts.get(k_, 0) for k_, v in _SYM.items()}
        conns = tk.get('connections', {})
        total_conn = sum(conns.values())
        real = info['metadata'].get('real')
        what = 'P&ID' if 'complete' in str(info['metadata'].get('slice')) else 'part of a P&ID'
        img = os.path.relpath(_img(src, os.path.join(img_dir, f'p2g_{k:05d}.png')), out_dir)
        qs = [(f'How many valves are on this {what}?', f'{_plural(sym["valve"], "valve")}.'),
              (f'How many instruments are on this {what}?', f'{_plural(sym["instrument"], "instrument")}.'),
              ('Count the symbols on this drawing by type.',
               f'Valves: {sym["valve"]}, instruments: {sym["instrument"]}, other symbols (equipment, fittings): {sym["other symbol"]}; '
               f'{sum(sym.values())} symbols in total.'),
              ('How many line connections does this drawing have?',
               f'{total_conn} connections between symbols and line points'
               + (': ' + ', '.join(f'{v} {t}' for t, v in sorted(conns.items(), key=lambda x: -x[1])) if conns else '') + '.')]
        for q, a in r.sample(qs, 2):
            rows.append({'task': 'p2g_look' + ('_real' if real else ''), 'images': [img],
                         'messages': [sysmsg, {'role': 'user', 'content': q}, {'role': 'assistant', 'content': a}]})
    shutil.rmtree(work, ignore_errors=True)
    return rows


# ---------------------------------------------------------------------- CubiCasa5K
_ROOM = {'LivingRoom': 'living room', 'Bedroom': 'bedroom', 'Bath': 'bathroom', 'Kitchen': 'kitchen', 'Entry': 'entrance / hall',
         'Outdoor': 'outdoor space (balcony / terrace)', 'Storage': 'storage', 'Garage': 'garage', 'Room': 'room', 'Sauna': 'sauna',
         'Fireplace': 'fireplace', 'Railing': None, 'Undefined': 'other space', 'Space': 'space'}


def cubicasa_counts(svg_path):
    """rooms by type, doors, windows from a CubiCasa5K model.svg (its <g class="Space Bedroom" / "Door ..." / "Window ...">)"""
    txt = open(svg_path, encoding='utf-8', errors='replace').read()
    rooms, doors, windows = collections.Counter(), 0, 0
    for cls in re.findall(r'<g[^>]*\bclass="([^"]+)"', txt):
        parts = cls.split()
        if not parts:
            continue
        if parts[0] == 'Space':
            t = parts[1] if len(parts) > 1 else 'Space'
            name = _ROOM.get(t, t.lower())
            if name:
                rooms[name] += 1
        elif parts[0] == 'Door':
            doors += 1
        elif parts[0] == 'Window':
            windows += 1
    return rooms, doors, windows


def cubicasa_samples(root, img_dir, out_dir, r, cap, sysmsg):
    plans = []
    for dp, _, files in os.walk(root):
        if 'model.svg' in files:
            img = next((f for f in ('F1_scaled.png', 'F1_original.png') if f in files), None)
            if img:
                plans.append((os.path.join(dp, 'model.svg'), os.path.join(dp, img)))
    r.shuffle(plans)
    rows = []
    for k, (svg, png) in enumerate(plans[:cap]):
        rooms, doors, windows = cubicasa_counts(svg)
        if not rooms:
            continue
        n = sum(rooms.values())
        img = os.path.relpath(_img(png, os.path.join(img_dir, f'cc5k_{k:05d}.png')), out_dir)
        listing = ', '.join(f'{t}: {v}' for t, v in sorted(rooms.items(), key=lambda x: (-x[1], x[0])))
        qs = [('How many rooms does this floor plan have, and what are they?', f'{n} spaces: {listing}.'),
              ('How many bedrooms are there?', f'{_plural(rooms.get("bedroom", 0), "bedroom")}.'),
              ('How many bathrooms are there?', f'{_plural(rooms.get("bathroom", 0), "bathroom")}.'),
              ('How many doors and windows are on this plan?', f'{_plural(doors, "door")} and {_plural(windows, "window")}.'),
              ('Describe this floor plan.', f'A floor plan with {n} spaces ({listing}), {_plural(doors, "door")} and {_plural(windows, "window")}.')]
        for q, a in r.sample(qs, 2):
            rows.append({'task': 'cc5k_look', 'images': [img], 'messages': [sysmsg, {'role': 'user', 'content': q},
                                                                            {'role': 'assistant', 'content': a}]})
    return rows


# ---------------------------------------------------------------------- PIDQA (questions) on Dataset-P&ID sheets (pictures)
PIDQA_REPO = 'https://github.com/mgupta70/PIDQA.git'
_PIDQA_CSV = ['Simple Counting/simple_counting.csv', 'Spatial Counting/spatial_counting.csv',
              'Spatial Connections/spatial_connectivity.csv', 'Value/value_based.csv']


def _norm(t):
    return re.sub(r'[^A-Z0-9]', '', str(t).upper())


def pidqa_samples(p2g_root, img_dir, out_dir, r, cap, sysmsg, log=print):
    """PIDQA's question / answer pairs (CC0) on the Dataset-P&ID sheet pictures inside PID2Graph. The pairing (sheet number
    -> picture) is CHECKED first: the tags PIDQA lists for a sheet must be readable (OCR) on that picture."""
    import csv, subprocess
    base = _find(p2g_root, 'Complete')
    d = os.path.join(base, 'Complete', 'Dataset PID') if base else None
    if not d or not os.path.isdir(d):
        log('PIDQA: no Dataset PID sheets in PID2Graph - skipped')
        return []
    pics = {}
    for f in os.listdir(d):
        stem, ext = os.path.splitext(f)
        m = re.fullmatch(r'\D*(\d+)', stem)
        if ext.lower() in ('.png', '.jpg', '.jpeg') and m:
            pics[int(m.group(1))] = os.path.join(d, f)
    tmp = tempfile.mkdtemp(prefix='sb_pidqa_')
    subprocess.run(['git', 'clone', '-q', '--depth', '1', PIDQA_REPO, tmp], check=True, timeout=600)
    by = collections.defaultdict(list)
    for rel in _PIDQA_CSV:
        for row in csv.DictReader(open(os.path.join(tmp, rel), encoding='utf-8')):
            try:
                n = int(row['P&ID_number'])
            except (KeyError, ValueError):
                continue
            if n in pics and row.get('Question') and row.get('GT') not in (None, ''):
                by[n].append((rel.split('/')[0], row['Question'].strip(), row['GT'].strip()))
    if not by:
        log('PIDQA: no sheet numbers match the pictures - skipped')
        return []
    try:
        from rapidocr_onnxruntime import RapidOCR
        ocr = RapidOCR()
    except Exception:
        log('PIDQA: no OCR to check the pairing (pip install rapidocr-onnxruntime) - skipped, nothing is assumed')
        return []
    sheets = sorted(by)
    probe = r.sample(sheets, min(10, len(sheets)))
    hits = tried = 0
    for n in probe:
        tags = [t for cat, q, a in by[n] if cat == 'Value' for t in re.findall(r"'([^']+)'", a)]
        if not tags:
            continue
        txt = _norm(' '.join(x[1] for x in (ocr(pics[n])[0] or [])))
        tried += 1
        hits += sum(_norm(t) in txt for t in tags[:6]) >= 1
    if tried < 4 or hits < 0.6 * tried:
        log(f'PIDQA: pairing NOT confirmed (tags found on {hits} of {tried} checked sheets) - skipped')
        return []
    log(f'PIDQA: pairing confirmed (tags found on {hits} of {tried} checked sheets)')
    rows = []
    for k, n in enumerate(r.sample(sheets, min(cap, len(sheets)))):
        img = os.path.relpath(_img(pics[n], os.path.join(img_dir, f'pidqa_{n:04d}.png')), out_dir)
        for cat, q, a in r.sample(by[n], min(3, len(by[n]))):
            if a in ('True', 'False'):
                ans = ('Yes. ' if a == 'True' else 'No. ') + ('There is such a connection on this P&ID.' if a == 'True' else 'There is no such connection on this P&ID.')
            elif a.startswith('['):
                items = re.findall(r"'([^']+)'", a)
                ans = (f"{len(items)} tag(s): {', '.join(items)}." if items else 'None on this P&ID.')
            else:
                ans = f'{a}.'
            rows.append({'task': 'pidqa_look', 'images': [img], 'messages': [
                sysmsg, {'role': 'user', 'content': q + ' (symbol classes as in the Dataset-P&ID legend)'}, {'role': 'assistant', 'content': ans}]})
    return rows


# ---------------------------------------------------------------------- FloorPlanCAD (if it can be fetched)
FLOORPLANCAD_PAGE = 'https://floorplancad.github.io/'


def floorplancad_samples(root, img_dir, out_dir, r, cap, sysmsg, log=print):
    """FloorPlanCAD SVGs (CC BY-NC): every element carries semantic-id; used ONLY if the class-name list is in the
    download (no guessed names). Counts per class -> picture questions."""
    names = None
    for dp, _, files in os.walk(root):
        for f in files:
            if f.lower().endswith(('.json', '.txt')) and re.search(r'class|categor|label', f, re.I):
                try:
                    t = open(os.path.join(dp, f), encoding='utf-8', errors='ignore').read()
                    if f.endswith('.json'):
                        j = json.loads(t)
                        if isinstance(j, dict) and all(str(k).isdigit() for k in list(j)[:5]):
                            names = {int(k): str(v) for k, v in j.items()}
                    else:
                        ls = [x.strip() for x in t.splitlines() if x.strip()]
                        if 20 <= len(ls) <= 60:
                            names = {i + 1: x for i, x in enumerate(ls)}
                except Exception:
                    pass
    if not names:
        log('FloorPlanCAD: no class-name list in the download - skipped (class names are never guessed)')
        return []
    svgs = [os.path.join(dp, f) for dp, _, fs in os.walk(root) for f in fs if f.lower().endswith('.svg')]
    r.shuffle(svgs)
    rows = []
    for k, svg in enumerate(svgs[:cap]):
        png = next((os.path.splitext(svg)[0] + e for e in ('.png', '.jpg') if os.path.exists(os.path.splitext(svg)[0] + e)), None)
        if not png:
            continue
        ids = collections.Counter(int(x) for x in re.findall(r'semantic-id="(\d+)"', open(svg, encoding='utf-8', errors='ignore').read()))
        cnt = {names[i]: n for i, n in ids.items() if i in names and not re.search(r'wall|railing|curtain', names[i], re.I)}
        if not cnt:
            continue
        img = os.path.relpath(_img(png, os.path.join(img_dir, f'fpcad_{k:05d}.png')), out_dir)
        listing = ', '.join(f'{v} x {t}' for t, v in sorted(cnt.items(), key=lambda x: -x[1]))
        rows.append({'task': 'fpcad_look', 'images': [img], 'messages': [sysmsg, {'role': 'user', 'content': r.choice(
            ['Which symbols are on this CAD floor plan and how many of each?', 'Count the doors, windows, furniture and fixtures on this plan.'])},
            {'role': 'assistant', 'content': f'Annotated drawing elements (each line piece of a symbol counts once): {listing}.'}]})
    return rows


def _fetch_floorplancad(dst, log=print):
    """the download links on the FloorPlanCAD page (Google Drive via gdown) -> dst"""
    import subprocess
    page = urllib.request.urlopen(urllib.request.Request(FLOORPLANCAD_PAGE, headers={'User-Agent': 'shipbrain-training'}), timeout=60).read().decode('utf-8', 'ignore')
    links = sorted(set(re.findall(r'https://drive\.google\.com/[^"\'<> ]+', page)))
    if not links:
        raise RuntimeError('no download links on the FloorPlanCAD page')
    subprocess.run([sys.executable, '-m', 'pip', '-q', 'install', 'gdown'], check=False)
    for u in links[:6]:
        subprocess.run([sys.executable, '-m', 'gdown', '--fuzzy', '-q', u, '-O', dst + '/'], check=False, timeout=3600)
    for z in [os.path.join(dst, f) for f in os.listdir(dst) if f.endswith('.zip')]:
        zipfile.ZipFile(z).extractall(dst)
    return dst


def _find(root, marker):
    for dp, dirs, files in os.walk(root):
        if marker in dirs:
            return dp
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='data/construct_real_train.jsonl')
    ap.add_argument('--img-dir', default='data/construct_real_images')
    ap.add_argument('--pid2graph-dir', help='a local copy (folder holding PID2Graph/) instead of downloading')
    ap.add_argument('--cubicasa-dir', help='a local copy of cubicasa5k instead of downloading')
    ap.add_argument('--pid2graph-cap', type=int, default=60, help='sheets per PID2Graph slice (4 slices)')
    ap.add_argument('--cubicasa-cap', type=int, default=250)
    ap.add_argument('--skip', action='append', default=[], choices=['pid2graph', 'cubicasa', 'pidqa', 'floorplancad'])
    ap.add_argument('--pidqa-cap', type=int, default=150, help='Dataset-P&ID sheets with PIDQA questions')
    ap.add_argument('--floorplancad-dir', help='a local copy of FloorPlanCAD instead of downloading')
    ap.add_argument('--floorplancad-cap', type=int, default=250)
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    os.makedirs(a.img_dir, exist_ok=True)
    out_dir = os.path.dirname(os.path.abspath(a.out))
    sysmsg = {'role': 'system', 'content': agent.system_prompt(agent.Tools(tempfile.mkdtemp()))}
    tmp = tempfile.mkdtemp(prefix='sb_real_')
    rows = []
    if 'pid2graph' not in a.skip:
        try:
            root = a.pid2graph_dir
            if not root:
                z = download(PID2GRAPH_URL, os.path.join(tmp, 'PID2Graph.zip'))
                zipfile.ZipFile(z).extractall(os.path.join(tmp, 'p2g'))
                os.remove(z)
                root = os.path.join(tmp, 'p2g')
            base = _find(root, 'Complete')                         # the folder that holds Complete/ and Patched/
            if base and os.path.basename(base) != 'PID2Graph':
                os.makedirs(os.path.join(tmp, 'p2g_root'), exist_ok=True)
                os.symlink(base, os.path.join(tmp, 'p2g_root', 'PID2Graph'))
                root = os.path.join(tmp, 'p2g_root')
            elif base:
                root = os.path.dirname(base)
            got = pid2graph_samples(root, a.img_dir, out_dir, r, a.pid2graph_cap, sysmsg)
            rows += got
            print('PID2Graph:', len(got), 'samples')
            if 'pidqa' not in a.skip:
                try:
                    got = pidqa_samples(root, a.img_dir, out_dir, r, a.pidqa_cap, sysmsg)
                    rows += got
                    print('PIDQA:', len(got), 'samples')
                except Exception as e:
                    print('PIDQA skipped:', type(e).__name__, str(e)[:300])
        except Exception as e:
            print('PID2Graph skipped:', type(e).__name__, str(e)[:300])
    if 'cubicasa' not in a.skip:
        try:
            root = a.cubicasa_dir
            if not root:
                z = download(CUBICASA_URL, os.path.join(tmp, 'cubicasa5k.zip'))
                with zipfile.ZipFile(z) as zf:                  # only the plans needed: svg + scaled picture
                    names = [n for n in zf.namelist() if n.endswith(('/model.svg', '/F1_scaled.png'))]
                    dirs = sorted({os.path.dirname(n) for n in names})
                    r.shuffle(dirs)
                    keep = set(dirs[:a.cubicasa_cap * 2])
                    for n in names:
                        if os.path.dirname(n) in keep:
                            zf.extract(n, os.path.join(tmp, 'cc5k'))
                os.remove(z)
                root = os.path.join(tmp, 'cc5k')
            got = cubicasa_samples(root, a.img_dir, out_dir, r, a.cubicasa_cap, sysmsg)
            rows += got
            print('CubiCasa5K:', len(got), 'samples')
        except Exception as e:
            print('CubiCasa5K skipped:', type(e).__name__, str(e)[:300])
    if 'floorplancad' not in a.skip:
        try:
            root = a.floorplancad_dir or _fetch_floorplancad(os.makedirs(os.path.join(tmp, 'fpcad'), exist_ok=True) or os.path.join(tmp, 'fpcad'))
            got = floorplancad_samples(root, a.img_dir, out_dir, r, a.floorplancad_cap, sysmsg)
            rows += got
            print('FloorPlanCAD:', len(got), 'samples')
        except Exception as e:
            print('FloorPlanCAD skipped:', type(e).__name__, str(e)[:300])
    with open(a.out, 'w', encoding='utf-8') as f:
        for x in rows:
            f.write(json.dumps(x) + '\n')
    shutil.rmtree(tmp, ignore_errors=True)
    print(a.out, len(rows), 'samples with pictures')


if __name__ == '__main__':
    main()
