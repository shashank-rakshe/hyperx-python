"""
Remove names before data goes into the shared model: company names, ship / hull numbers, people, user folders.

    python training/scrub.py --rules my_rules.json --src D:/my_code --dst D:/my_code_clean
    python training/scrub.py --rules my_rules.json --jsonl runs.jsonl --out runs_clean.jsonl

my_rules.json (keep it OUTSIDE the repo, it lists the very names to hide):
    [["(?i)my company", "Yard"], ["\\\\bH?1234\\\\b", "1001"], ...]      regex -> replacement, applied in order
Text files are rewritten, file and folder NAMES too; binary files are copied unchanged. A final check lists any rule that
still matches (exit code 1 then).
"""
import argparse, json, os, re, shutil, sys

TEXT = ('.py', '.cpp', '.h', '.hpp', '.c', '.cc', '.txt', '.md', '.json', '.jsonl', '.xml', '.cmd', '.bat', '.tcl', '.cmake', '.ui',
        '.qrc', '.ini', '.cfg', '.toml', '.yml', '.yaml', '.csv', '.html', '.js', '.rst', '.pro', '.pri', '.snippet', '.ts')


def load_rules(path):
    return [(re.compile(a), b) for a, b in json.load(open(path, encoding='utf-8'))]


def scrub_text(s, rules):
    for rx, rep in rules:
        s = rx.sub(rep, s)
    return s


def scrub_tree(src, dst, rules):
    n = 0
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        out_dir = os.path.join(dst, scrub_text(rel, rules)) if rel != '.' else dst
        os.makedirs(out_dir, exist_ok=True)
        for f in files:
            p = os.path.join(root, f)
            q = os.path.join(out_dir, scrub_text(f, rules))
            if f.lower().endswith(TEXT) or '.' not in f:
                try:
                    s = open(p, encoding='utf-8', errors='replace').read()
                    open(q, 'w', encoding='utf-8').write(scrub_text(s, rules))
                    n += 1
                    continue
                except Exception:
                    pass
            shutil.copy2(p, q)
    return n


def leftovers(path, rules):
    """rules that still match somewhere under path (file names included)"""
    hits = {}
    paths = [path] if os.path.isfile(path) else [os.path.join(r, f) for r, _, fs in os.walk(path) for f in fs]
    for p in paths:
        try:
            s = os.path.relpath(p, path) + '\n' + (open(p, encoding='utf-8', errors='ignore').read()
                                                   if p.lower().endswith(TEXT) or '.' not in os.path.basename(p) else '')
        except Exception:
            continue
        for rx, rep in rules:
            for m in rx.finditer(s):
                if rx.sub(rep, m.group(0)) != m.group(0):          # a match that is already the clean text is fine
                    hits.setdefault(rx.pattern, p)
                    break
    return hits


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rules', required=True)
    ap.add_argument('--src')
    ap.add_argument('--dst')
    ap.add_argument('--jsonl')
    ap.add_argument('--out')
    a = ap.parse_args(argv)
    rules = load_rules(a.rules)
    if a.src:
        n = scrub_tree(a.src, a.dst, rules)
        target = a.dst
        print(f'{n} text files cleaned -> {a.dst}')
    else:
        with open(a.out, 'w', encoding='utf-8') as fo:
            for line in open(a.jsonl, encoding='utf-8'):
                fo.write(scrub_text(line, rules))
        target = a.out
    left = leftovers(target, rules)
    for pat, p in left.items():
        print(f'STILL FOUND: {pat} in {p}')
    return 1 if left else 0


if __name__ == '__main__':
    sys.exit(main())
