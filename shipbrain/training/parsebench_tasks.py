"""
ParseBench (https://github.com/run-llama/ParseBench, Apache-2.0; dataset llamaindex/ParseBench on Hugging Face) ->
document-reading training samples: a real document page (insurance, finance, government ...) as a picture -> its
human-verified markdown (tables, headings, formatting, reading order) from the dataset's expected_markdown.json.

The dataset is downloaded with ParseBench's own command (`parse-bench download`) where the internet is open (the
GitHub data job), and used only if its licence on Hugging Face allows it (checked first, written to the manifest).

    python training/parsebench_tasks.py --data <folder with expected_markdown.json + docs/> --out x.jsonl --img-dir imgs
"""
import argparse, json, os, random, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

PX = 1280
OK_LICENCES = re.compile(r'^(apache-2\.0|mit|bsd.*|cc0.*|cc-by(-nc)?(-sa)?(-\d.*)?|odc-by|cdla-permissive.*)$', re.I)   # no -nd
ASK = ['Convert this page to markdown, keeping its tables and headings.', 'Read this document page exactly, as markdown.',
       'Transcribe this page: text, tables (as markdown tables) and headings in reading order.',
       'What does this page say? Give the full content as markdown.']


def licence(repo='llamaindex/ParseBench'):
    """(licence id from the Hugging Face card, allowed?)"""
    try:
        from huggingface_hub import HfApi
        cd = HfApi().dataset_info(repo).card_data
        lic = (cd or {}).get('license') if isinstance(cd, dict) else getattr(cd, 'license', None)
        lic = lic[0] if isinstance(lic, list) and lic else lic
    except Exception as e:
        return f'unknown ({type(e).__name__})', False
    return str(lic), bool(lic and OK_LICENCES.match(str(lic)))


def _render(pdf, page, dst):
    import pypdfium2
    from PIL import Image
    doc = pypdfium2.PdfDocument(pdf)
    try:
        pg = doc[max(0, page - 1)]
        im = pg.render(scale=150 / 72).to_pil().convert('RGB')
    finally:
        doc.close()
    k = PX / max(im.size)
    if k < 1:
        im = im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    im.save(dst, optimize=True)
    return dst


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--data', required=True)
    ap.add_argument('--out', default='data/parsebench_train.jsonl')
    ap.add_argument('--img-dir', default='data/parsebench_images')
    ap.add_argument('--cap', type=int, default=700)
    ap.add_argument('--max-chars', type=int, default=3500, help='longer verified markdown is left out (token budget)')
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    r = random.Random(a.seed)
    em = json.load(open(os.path.join(a.data, 'expected_markdown.json'), encoding='utf-8'))
    pdfs = {}
    for dp, _, fs in os.walk(a.data):
        for f in fs:
            if f.lower().endswith('.pdf'):
                pdfs.setdefault(os.path.splitext(f)[0], os.path.join(dp, f))
    items = list(em.items()) if isinstance(em, dict) else [(x.get('id') or x.get('file'), x.get('markdown')) for x in em]
    r.shuffle(items)
    out_dir = os.path.dirname(os.path.abspath(a.out))
    rows, missing = [], 0
    for key, md in items:
        if len(rows) >= a.cap:
            break
        if not isinstance(md, str) or not md.strip() or len(md) > a.max_chars:
            continue
        stem = os.path.splitext(os.path.basename(str(key)))[0]
        m = re.search(r'(?:_p|page[_-]?)(\d+)$', stem)
        pdf = pdfs.get(stem) or (pdfs.get(stem[:m.start()]) if m else None)
        if not pdf:
            missing += 1
            continue
        page = int(m.group(1)) if m and not pdfs.get(stem) else 1
        try:
            img = _render(pdf, page, os.path.join(a.img_dir, f'pb_{len(rows):05d}.png'))
        except Exception:
            continue
        rows.append({'task': 'parsebench_read', 'images': [os.path.relpath(img, out_dir)],
                     'messages': [{'role': 'user', 'content': r.choice(ASK)}, {'role': 'assistant', 'content': md.strip()}]})
    with open(a.out, 'w', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples;', missing, 'expected pages without their PDF')


if __name__ == '__main__':
    main()
