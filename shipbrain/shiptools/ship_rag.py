"""
ship_rag.py - run the ship model WITHOUT a GPU (PC CPU or phone), with the rule book as RAG and the rule checks around it.

The trained model is exported as GGUF (cad_vlm_all_in_one.py, MOBILE=1 -> Qwen3-VL-2B, q4_k_m, about 1.5 GB + vision projector).
Serve it on the CPU with any OpenAI-compatible local server, e.g.
    llama-server -m cad_gguf/model-q4_k_m.gguf --mmproj cad_gguf/mmproj.gguf --port 8080      (llama.cpp)
    ollama serve  (after 'ollama create shipmodel -f Modelfile')                               (Ollama, port 11434)
and point this script at it. With no server it still answers from the rule book (retrieval only) - useful offline.

  python ship_rag.py ask   "where does a carling start when it butts on a girder?"  [--server http://127.0.0.1:8080]
  python ship_rag.py panel plan_tile.png --x 15155 19955 --y 12219 17019 --z 28950 --out tile.xml [--server ...]
        -> model reads the tile -> member JSON -> checks C3-C6, PN1, PN4 -> errors back (3 tries) -> XML written by code
  python ship_rag.py index --src ship_src   (writes rules_index.json once; copy it to the phone with the model)
"""
import argparse, base64, json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def load_entries(src=None, index=None):
    from ship_xml_kit import parse_rules, _read_sources
    index = index or os.path.join(HERE, 'rules_index.json')
    if os.path.exists(index) and not src:
        return json.load(open(index))
    return parse_rules(_read_sources(src or os.path.join(HERE, 'ship_src')))


def chat(server, prompt, image=None, model='local', max_tokens=900, timeout=600):
    """OpenAI-compatible /v1/chat/completions (llama.cpp llama-server, Ollama, LM Studio). image: path to PNG/JPG."""
    content = [{'type': 'text', 'text': prompt}]
    if image:
        b64 = base64.b64encode(open(image, 'rb').read()).decode()
        content.insert(0, {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + b64}})
    body = {'model': model, 'messages': [{'role': 'user', 'content': content}], 'temperature': 0.2, 'max_tokens': max_tokens}
    req = urllib.request.Request(server.rstrip('/') + '/v1/chat/completions', data=json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())['choices'][0]['message']['content']


def ask(question, entries, server=None, image=None, k=5, model='local'):
    from ship_xml_kit import RuleIndex
    from ship_online import core_rules
    hits = RuleIndex(entries).search(question, k)
    ctx = '\n'.join(f"- {e['id']}: {e['text'][:500]}" for e in hits)
    prompt = f"{core_rules(entries)}\n\nRelevant rules:\n{ctx}\n\nQuestion: {question}"
    if not server:
        return {'answer': None, 'rules': hits, 'note': 'no model server given: retrieved rules only'}
    return {'answer': chat(server, prompt, image, model), 'rules': [h['id'] for h in hits]}


def table_to_xml(tab, z, path, name='TILE'):
    """member JSON (ship X/Y, mm) of one deck -> moulded-line ship XML by code (the model never writes XML).
    Deck panel: origin (0,0,z), U = X, V = Y, W = +Z; webs hang below the deck (Inclination W -1)."""
    from ship_xml_kit import members_to_xml
    import re
    secs, sts = {}, []
    for i, m in enumerate(tab.get('members', []), 1):
        sid = str(m.get('sec') or 'FlatBar100*10')
        if sid not in secs:
            nums = [float(x) for x in re.findall(r'\d+(?:\.\d+)?', sid)]
            if sid.startswith('LBar') and len(nums) >= 4:
                secs[sid] = {'type': 'LBar', 'H': nums[0], 'W': nums[1], 'tw': nums[2], 'tf': nums[3]}
            elif sid.startswith('TBar') and len(nums) >= 4:
                secs[sid] = {'type': 'TBar', 'H': nums[0], 't': nums[1], 'wf': nums[2], 'tf': nums[3]}
            else:
                secs[sid] = {'type': 'FlatBar', 'H': nums[0] if nums else 100.0, 't': nums[1] if len(nums) > 1 else 10.0}
        sts.append({'name': f"{name}/{m.get('id', 'S%d' % i)}", 'kind': m.get('kind', ''), 'sec': sid,
                    'evidence': 'ship_rag model + rule checks' + (' (ASSUMED)' if m.get('assumed') else ''),
                    'trace': [m['a'], m['b']], 'incl': [0, 0, -1]})
    pan = {'id': name, 'attrs': {'Tightness': 'NonTight'}, 'cs': {'origin': [0, 0, z], 'waxis': [0, 0, 1], 'uaxis': [1, 0, 0]},
           'boundary': tab.get('outline') or None, 'plates': [], 'holes': [{'contour': h} for h in tab.get('holes', [])],
           'stiffeners': sts, 'brackets': []}
    return members_to_xml({'attrs': {'Source': 'ship_rag'}, 'sections': secs, 'blocks': [{'id': name, 'panels': [pan]}]}, path)


def tile_alike(image, xr, yr, min_hit=0.5):
    """AL1 check: every member the model wrote must lie on drawn ink of its tile (share of its length on ink >= min_hit)"""
    import numpy as np, cv2
    g = cv2.imread(image, cv2.IMREAD_GRAYSCALE)
    ink = cv2.dilate((g < 140).astype(np.uint8), np.ones((5, 5), np.uint8))
    H, W = ink.shape
    sx, sy = W / (xr[1] - xr[0]), H / (yr[1] - yr[0])
    def check(js):
        bad = []
        for m in js.get('members', []):
            try:
                pts = [(m['a'][0] + t * (m['b'][0] - m['a'][0]), m['a'][1] + t * (m['b'][1] - m['a'][1])) for t in np.linspace(0.05, 0.95, 20)]
            except Exception:
                continue
            on = sum(1 for X, Y in pts if 0 <= int((X - xr[0]) * sx) < W and 0 <= int((yr[1] - Y) * sy) < H and ink[int((yr[1] - Y) * sy), int((X - xr[0]) * sx)])
            if on / len(pts) < min_hit:
                bad.append(('AL1', f"{m.get('id')} is not on a drawn line ({on}/{len(pts)} points on ink) - read its position again", m.get('id')))
        return bad
    return check


def panel(image, xr, yr, z, entries, server, out, notes=None, model='local'):
    from ship_online import solve_ship_panel, core_rules
    from ship_pairs import PAIR_Q
    q = PAIR_Q.format(core=core_rules(entries), name='deck plan', z=z, x0=xr[0], x1=xr[1], y0=yr[0], y1=yr[1], notes=json.dumps(notes or {}))
    fb = lambda p: p[p.find('\n\nYour'):] if '\n\nYour' in p else (p[p.find('\n\nThe JSON'):] if '\n\nThe JSON' in p else '')
    res = solve_ship_panel(lambda img, p: chat(server, q + fb(p), img, model), image, entries, codes={'C4', 'PN1', 'PN4'}, extra_check=tile_alike(image, xr, yr))   # a tile has no outline: C5/C6 do not apply
    if res.get('table'):
        table_to_xml(res['table'], z, out)
        res['xml'] = out
    return res


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['ask', 'panel', 'index'])
    ap.add_argument('arg', nargs='?')
    ap.add_argument('--server', help='http://127.0.0.1:8080 (llama-server) or http://127.0.0.1:11434 (Ollama)')
    ap.add_argument('--model', default='local')
    ap.add_argument('--src')
    ap.add_argument('--image')
    ap.add_argument('--x', nargs=2, type=float)
    ap.add_argument('--y', nargs=2, type=float)
    ap.add_argument('--z', type=float)
    ap.add_argument('--out', default='tile.xml')
    a = ap.parse_args()
    if a.cmd == 'index':
        E = load_entries(a.src or os.path.join(HERE, 'ship_src'))
        json.dump(E, open(os.path.join(HERE, 'rules_index.json'), 'w'))
        print(len(E), 'rules ->', os.path.join(HERE, 'rules_index.json'))
    elif a.cmd == 'ask':
        r = ask(a.arg, load_entries(a.src), a.server, a.image, model=a.model)
        if r['answer'] is None:
            for e in r['rules']:
                print(f"[{e['score']}] {e['id']}: {e['text'][:400]}\n")
        else:
            print(r['answer'], '\n\nrules used:', ', '.join(r['rules']))
    else:
        print(json.dumps(panel(a.arg, a.x, a.y, a.z, load_entries(a.src), a.server, a.out, model=a.model), indent=1)[:3000])
