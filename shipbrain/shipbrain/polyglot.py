"""
Use other people's code AS IT IS, in its own language: complete copies of open-source repos live in shipbrain/vendor/<name>/repo
(unchanged, with their licence), and any function in them can be called from ShipBrain - nothing is rewritten, so no core
function can go missing.

  Python      .py           imported and called directly
  TypeScript  .ts / .tsx    run by Node.js through tsx (no build step)
  JavaScript  .js / .mjs    run by Node.js
  C / C++ / Rust            through their compiled WebAssembly (.wasm) - e.g. Awatif's solver in shipbrain/awatif.py

    python -m shipbrain.polyglot add https://github.com/owner/repo     copy a repo in full (permissive licences only)
    python -m shipbrain.polyglot setup awatif                           install what its JS/TS code needs (npm, once)
    python -m shipbrain.polyglot list awatif [query]                    every function: file, name, language, signature
    python -m shipbrain.polyglot call awatif components/x.ts fnName '[args as JSON]'

JS Map objects travel as {"__map__": [[key, value], ...]} in both directions.
"""
import argparse, importlib.util, json, os, re, shutil, subprocess, sys

VENDOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor')
RUNNER = os.path.join(VENDOR, '_runner')
LANG = {'.py': 'python', '.ts': 'typescript', '.tsx': 'typescript', '.js': 'javascript', '.mjs': 'javascript',
        '.cpp': 'c++', '.cc': 'c++', '.h': 'c/c++', '.hpp': 'c++', '.c': 'c', '.rs': 'rust', '.f90': 'fortran', '.f': 'fortran'}
CALLABLE = {'python', 'typescript', 'javascript'}
_RUN_MJS = r"""
import { pathToFileURL } from 'node:url';
let input = '';
process.stdin.on('data', d => input += d);
process.stdin.on('end', async () => {
  try {
    const { file, fn, args } = JSON.parse(input, (k, v) =>
      v && typeof v === 'object' && !Array.isArray(v) && Array.isArray(v.__map__) ? new Map(v.__map__) : v);
    const mod = await import(pathToFileURL(file).href);
    const f = fn.split('.').reduce((o, k) => o[k], mod);
    if (typeof f !== 'function') throw new Error(fn + ' is not a function in ' + file);
    const r = await f(...(Array.isArray(args) ? args : [args]));
    const out = JSON.stringify(r === undefined ? null : r, (k, v) =>
      v instanceof Map ? { __map__: [...v.entries()] } : (ArrayBuffer.isView(v) ? Array.from(v) :
      (v && typeof v === 'object' && v.constructor && v.constructor.name === 'Matrix' && v.toArray ? v.toArray() : v)));
    process.stdout.write('\n@@RESULT@@' + out);
  } catch (e) {
    process.stdout.write('\n@@ERROR@@' + (e && e.stack || String(e)));
  }
});
"""


def repo_dir(name):
    d = os.path.join(VENDOR, name, 'repo')
    if not os.path.isdir(d):
        raise ValueError(f'no copied repo "{name}"; have: ' + ', '.join(repos()))
    return d


def repos():
    return sorted(n for n in os.listdir(VENDOR) if os.path.isdir(os.path.join(VENDOR, n, 'repo'))) if os.path.isdir(VENDOR) else []


# ------------------------------------------------------------------ copy a repo in full
MEDIA = re.compile(r'\.(gif|mp4|mov|webm|avi|mkv|png|jpe?g|webp|heic|tiff?|bmp|ico|icns|usdz|zip|tar|gz|7z|dmg|pkg|exe|dll|dylib|'
                   r'so|a|o|wasm-unused)$|(^|/)[^/]+\.app/', re.I)


def add(url, name=None, skip_media=True, separate_program=False, exclude=()):
    """clone a repo and copy every tracked file into vendor/<name>/repo (MIT / BSD / Apache / ISC / CC0 only).
    skip_media: pictures, videos, archives and app bundles stay out (they teach the model nothing and only add weight);
    all code, docs text, examples and data files are kept.
    separate_program: also accept LGPL / GPL code, copied UNCHANGED with its licence and only built and run as its own
    program (never imported into ShipBrain's code, never trained on - NOT_FOR_TRAINING.md). AGPL is never accepted.
    exclude: path prefixes left out (e.g. sample models that carry ship or company names)"""
    from .repopack import classify_licence
    name = name or re.sub(r'\.git$', '', url.rstrip('/').split('/')[-1])
    tmp = os.path.join(VENDOR, '_clone_' + name)
    shutil.rmtree(tmp, ignore_errors=True)
    subprocess.run(['git', 'clone', '-q', '--depth', '1', url, tmp], check=True)
    lic = next((os.path.join(tmp, f) for f in os.listdir(tmp) if re.match(r'(?i)^(licen[cs]e|copying)', f)), None)
    spdx, kind = classify_licence(open(lic, errors='replace').read()) if lic else ('none', 'unknown')
    from .repopack import copyleft_training_ok
    gpl_ok = separate_program and kind == 'copyleft' and (not re.search(r'AGPL', spdx, re.I) or copyleft_training_ok())
    from .repopack import noncommercial_ok
    nc_ok = kind == 'noncommercial' and noncommercial_ok()
    if kind not in ('permissive', 'conditional') and not gpl_ok and not nc_ok:
        shutil.rmtree(tmp, ignore_errors=True)
        raise ValueError(f'{name}: licence {spdx} ({kind}) - only permissive licences are copied into ShipBrain; '
                         'use repopack (search-only knowledge) for it')
    files = subprocess.run(['git', '-C', tmp, 'ls-files'], capture_output=True, text=True, check=True).stdout.split('\n')
    commit = subprocess.run(['git', '-C', tmp, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    dst = os.path.join(VENDOR, name, 'repo')
    shutil.rmtree(dst, ignore_errors=True)
    skipped = 0
    for f in filter(None, files):
        if any(f.startswith(x) for x in exclude):
            skipped += 1
            continue
        if skip_media and MEDIA.search(f):
            skipped += 1
            continue
        if os.path.isdir(os.path.join(tmp, f)):          # a git submodule: another project, fetched by its build when needed
            continue
        os.makedirs(os.path.dirname(os.path.join(dst, f)), exist_ok=True)
        shutil.copy2(os.path.join(tmp, f), os.path.join(dst, f))
    shutil.rmtree(tmp, ignore_errors=True)
    if kind == 'conditional':
        with open(os.path.join(VENDOR, name, 'DO_NOT_MODIFY.md'), 'w') as fh:
            fh.write(f'# Do not modify {name}\n\nIts licence ({spdx}) allows use and sharing of the UNCHANGED code with its notice, but '
                     'adds conditions on modifications (see repo/LICENSE*). ShipBrain uses it as it is: never patch these files; '
                     'fixes go to the author as a pull request.\n')
    if nc_ok:
        with open(os.path.join(VENDOR, name, 'NONCOMMERCIAL.md'), 'w') as fh:
            fh.write(f'# {name}: non-commercial use only\n\nLicence {spdx} (see repo/). Used because ShipBrain is declared '
                     'non-commercial (shipbrain/licence_mode.json): run, searched and trained on for a non-commercial model. '
                     'Before any commercial use of ShipBrain or of a model trained with it: remove this folder, its pack and '
                     'its training data, and train again (or get a commercial licence from the author).\n')
    if gpl_ok:
        from .repopack import copyleft_training_ok
        trained = copyleft_training_ok()
        with open(os.path.join(VENDOR, name, 'COPYLEFT.md' if trained else 'NOT_FOR_TRAINING.md'), 'w') as fh:
            fh.write(f'# {name}: separate program\n\nLicence {spdx} (see repo/). ShipBrain copies it unchanged, builds it and runs '
                     'it as its own program; it is never imported into ShipBrain\'s code and never modified (changes go to its '
                     'author). ' + ('Its code is searched and trained on, allowed by the owner (shipbrain/licence_mode.json); '
                                    'ShipBrain and its models stay open under the same terms.\n' if trained else
                                    'It is not used as training data.\n'))
    with open(os.path.join(VENDOR, name, 'SOURCE.md'), 'w') as fh:
        fh.write(f'# {name} (copied unchanged)\n\nFrom {url}, commit {commit}. Licence: {spdx} (see repo/).\n'
                 + (f'{skipped} media / binary / excluded files left out'
                    + (f' (excluded: {", ".join(exclude)})' if exclude else '') + '.\n' if skipped else ''))
    return {'name': name, 'files': len([f for f in files if f]) - skipped, 'media_left_out': skipped, 'licence': spdx, 'commit': commit}


# ------------------------------------------------------------------ what is in there
_PAT = {
    'python': re.compile(r'^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(([^)]*)\)', re.M),
    'typescript': re.compile(r'^export\s+(?:async\s+)?(?:function\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\(([^)]*)\)|'
                             r'const\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\(([^)]*)\)\s*=>)', re.M | re.S),
    'c++': re.compile(r'^[A-Za-z_][\w:<>,\s*&]*?\s+([A-Za-z_]\w*)\s*\(([^;{)]*)\)\s*(?:const\s*)?\{', re.M),
    'rust': re.compile(r'^\s*pub\s+fn\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(([^)]*)\)', re.M),
}
_PAT['javascript'] = _PAT['typescript']
_PAT['c'] = _PAT['c/c++'] = _PAT['c++']


def list_functions(name, query=None, limit=200):
    root = repo_dir(name)
    out = []
    for dp, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ('node_modules', '.git', 'built', 'dist')]
        for f in sorted(files):
            lang = LANG.get(os.path.splitext(f)[1].lower())
            if not lang or lang not in _PAT:
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, root).replace('\\', '/')
            text = open(p, encoding='utf-8', errors='replace').read()
            for m in _PAT[lang].finditer(text):
                g = [x for x in m.groups() if x is not None]
                fn, sig = g[0], re.sub(r'\s+', ' ', g[1] if len(g) > 1 else '').strip()
                if lang in ('c++', 'c', 'c/c++') and fn in ('if', 'for', 'while', 'switch', 'return', 'catch'):
                    continue
                item = {'file': rel, 'function': fn, 'language': lang, 'signature': f'{fn}({sig[:160]})',
                        'callable': lang in CALLABLE and not rel.endswith(('.test.ts', '.spec.ts', '.d.ts'))}
                if not query or re.search(query, rel + ' ' + fn, re.I):
                    out.append(item)
    return out[:limit]


# ------------------------------------------------------------------ run JS / TS code
def node_ok():
    return shutil.which('node') is not None


def setup(name):
    """npm install for every package.json in the repo (dependencies only) + tsx for running TypeScript"""
    if not node_ok():
        raise RuntimeError('Node.js is needed for JavaScript / TypeScript code: install it from nodejs.org (LTS)')
    root = repo_dir(name)
    done = []
    os.makedirs(RUNNER, exist_ok=True)
    with open(os.path.join(RUNNER, 'run.mjs'), 'w') as fh:
        fh.write(_RUN_MJS)
    if not os.path.exists(os.path.join(RUNNER, 'node_modules', 'tsx')):
        subprocess.run(['npm', 'install', '--no-audit', '--no-fund', '--silent', '--prefix', RUNNER, 'tsx@4.20.3'], check=True,
                       shell=(os.name == 'nt'))
        done.append('tsx')
    deps = {}
    for dp, dirs, files in os.walk(root):                   # every package.json (workspaces too); not the repo's own packages
        dirs[:] = [d for d in dirs if d not in ('node_modules', '.git')]
        if 'package.json' in files:
            pkg = json.load(open(os.path.join(dp, 'package.json')))
            own = pkg.get('name', '')
            for k, v in (pkg.get('dependencies') or {}).items():
                if not (k.startswith(own.split('/')[0] + '/') and own.startswith('@')) and v not in ('*', 'workspace:*'):
                    deps.setdefault(k, v)
    if deps and not os.path.isdir(os.path.join(root, 'node_modules')):
        tmp = os.path.join(VENDOR, '_npm_' + name)               # a clean folder: the repo's workspace set-up can confuse npm
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(tmp)
        json.dump({'name': 'deps', 'private': True, 'type': 'module'}, open(os.path.join(tmp, 'package.json'), 'w'))
        subprocess.run(['npm', 'install', '--no-audit', '--no-fund', '--silent'] + [f'{k}@{v}' for k, v in deps.items()],
                       check=True, cwd=tmp, shell=(os.name == 'nt'))
        shutil.move(os.path.join(tmp, 'node_modules'), os.path.join(root, 'node_modules'))
        shutil.rmtree(tmp, ignore_errors=True)
        done += sorted(deps)
    return {'repo': name, 'installed_in': done}


def call(name, file, function, args=None, timeout=300):
    """call function(*args) from file of a copied repo, in its own language -> result (JSON-like)"""
    root = repo_dir(name)
    path = os.path.normpath(os.path.join(root, file))
    if not path.startswith(os.path.normpath(root) + os.sep) or not os.path.isfile(path):
        raise ValueError(f'{file} is not a file of {name}')
    lang = LANG.get(os.path.splitext(path)[1].lower())
    args = [] if args is None else args
    if lang == 'python':
        sys.path.insert(0, os.path.dirname(path))
        sys.path.insert(0, root)
        spec = importlib.util.spec_from_file_location(f'vendor_{name}_' + re.sub(r'\W', '_', file), path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        fn = mod
        for part in function.split('.'):
            fn = getattr(fn, part)
        return fn(**args) if isinstance(args, dict) else fn(*args)
    if lang in ('typescript', 'javascript'):
        if not node_ok():
            raise RuntimeError('Node.js is needed for this code: install it from nodejs.org, then: python -m shipbrain.polyglot setup ' + name)
        if not os.path.exists(os.path.join(RUNNER, 'run.mjs')) or (lang == 'typescript' and
                                                                  not os.path.exists(os.path.join(RUNNER, 'node_modules', 'tsx'))):
            setup(name)
        cmd = ['node'] + (['--import', 'tsx'] if lang == 'typescript' else []) + [os.path.join(RUNNER, 'run.mjs')]
        r = subprocess.run(cmd, input=json.dumps({'file': path, 'fn': function, 'args': args}), capture_output=True, text=True,
                           timeout=timeout, cwd=RUNNER)
        out = r.stdout
        if '@@RESULT@@' in out:
            return json.loads(out.split('@@RESULT@@', 1)[1])
        err = out.split('@@ERROR@@', 1)[1] if '@@ERROR@@' in out else (r.stderr or out)[-1500:]
        if 'Cannot find package' in err or 'ERR_MODULE_NOT_FOUND' in err:
            setup(name)
            return call(name, file, function, args, timeout)
        raise RuntimeError(err.strip()[:1500])
    raise ValueError(f'{lang or "this"} code is not called directly; C/C++/Rust run through their compiled .wasm '
                     '(see shipbrain/awatif.py) or are read as knowledge')


def run_script(name, script, args=(), cwd=None, timeout=3600):
    """run a script of a copied repo as its authors wrote it (its own command line) -> {'returncode', 'stdout', 'stderr'}"""
    root = repo_dir(name)
    path = os.path.normpath(os.path.join(root, script))
    if not path.startswith(os.path.normpath(root) + os.sep) or not os.path.isfile(path):
        raise ValueError(f'{script} is not a file of {name}')
    lang = LANG.get(os.path.splitext(path)[1].lower())
    if lang == 'python':
        cmd = [sys.executable, path]
    elif lang in ('typescript', 'javascript'):
        if not node_ok():
            raise RuntimeError('Node.js is needed: install it from nodejs.org')
        cmd = ['node'] + (['--import', 'tsx'] if lang == 'typescript' else []) + [path]
    else:
        raise ValueError(f'{lang or "this"} script is not run directly')
    env = dict(os.environ, PYTHONIOENCODING='utf-8')
    r = subprocess.run(cmd + [str(a) for a in args], capture_output=True, text=True, timeout=timeout, cwd=cwd or os.getcwd(),
                       env=env, encoding='utf-8', errors='replace')
    return {'returncode': r.returncode, 'stdout': r.stdout[-20000:], 'stderr': r.stderr[-4000:]}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('add').add_argument('url')
    sub.add_parser('setup').add_argument('name')
    p = sub.add_parser('list')
    p.add_argument('name')
    p.add_argument('query', nargs='?')
    p = sub.add_parser('call')
    for a_ in ('name', 'file', 'function'):
        p.add_argument(a_)
    p.add_argument('args', nargs='?', default='[]')
    a = ap.parse_args(argv)
    if a.cmd == 'add':
        print(add(a.url))
    elif a.cmd == 'setup':
        print(setup(a.name))
    elif a.cmd == 'list':
        for f in list_functions(a.name, a.query):
            print(f"{f['language']:11s} {f['file']}: {f['signature']}{'' if f['callable'] else '   (knowledge only)'}")
    else:
        print(json.dumps(call(a.name, a.file, a.function, json.loads(a.args)), indent=1)[:5000])


if __name__ == '__main__':
    main()
