"""
ship_mcp.py - the ship tools as ONE command line + MCP server (idea taken from Craft Anything: every tool is a CLI command and an MCP
tool, so any agent - Claude Code on the office PC, a local model, the app - drives the same engine; checks decide on a measured
similarity, never on the model's own words; every result carries its evidence).

Tools (all read-only except xml_from_members, which writes the file you name):
  rules_search       rule book RAG (current rules only; superseded ones removed)          evidence: rule ids + file
  check_members      C3-C6 + PN1 / PN4 on a member table                                  evidence: rule code per finding
  alike_score        how alike an XML deck is to the drawing: share of the XML member length on drawn ink, best shift,
                     pass >= 0.6 with no shift (needs a views.json entry)                     evidence: view, hit ratio, shift
  drawing_tile       render one deck-plan tile (image + its ship X/Y box) for a model to read
  xml_from_members   member JSON -> moulded-line ship XML (written by code, R4.x)
  xml_validate       C1-C6 schema / geometry checks of an XML file
  ocr_fix            R-T17..R-T22 correction of one OCR label
  classify_number    R2.1 class of a printed number
CLI:   python ship_mcp.py call rules_search '{"query": "beam crosses girder"}'
       python ship_mcp.py list
MCP:   python ship_mcp.py serve      (stdio, JSON-RPC 2.0; add it as an MCP server in Claude Code: command "python", args ["ship_mcp.py","serve"])
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
SRC = os.environ.get('SHIP_SRC', os.path.join(HERE, 'ship_src'))
_E = None


def _entries():
    global _E
    if _E is None:
        from ship_rag import load_entries
        _E = load_entries(SRC if os.path.isdir(SRC) else None)
    return _E


# ------------------------------------------------------------------ tools
def rules_search(query, k=5):
    from ship_xml_kit import RuleIndex
    hits = RuleIndex(_entries()).search(query, int(k))
    return {'rules': [{'id': h['id'], 'text': h['text'][:600], 'file': h['file'], 'score': h['score']} for h in hits]}


def check_members(table):
    from ship_xml_kit import check_table
    from ship_online import check_plus
    t = table if isinstance(table, dict) else json.loads(table)
    f = (check_table(t) if t.get('outline') else []) + check_plus(t)
    return {'ok': not f, 'findings': [{'rule': c, 'message': m, 'member': x} for c, m, x in f]}


def _view(pdf, name):
    from ship_pairs import load_views
    for v in load_views(SRC):
        if os.path.basename(v['pdf']) == os.path.basename(pdf) and v['name'].replace(' ', '') == name.replace(' ', ''):
            return v
    raise ValueError(f'no calibrated view {name} of {pdf} in views.json')


def alike_score(xml, pdf, view):
    """two-way similarity of an XML deck with the drawing (no shift allowed: a shift is reported as a calibration error)"""
    from ship_pairs import deck_members, register
    v = _view(pdf, view)
    mem = deck_members(xml if os.path.isabs(xml) or os.path.exists(xml) else os.path.join(SRC, xml), v['z_mm'])
    h0, dx, dy = register(v, mem)
    return {'view': v['name'], 'pdf': os.path.basename(v['pdf']), 'members': len(mem), 'xml_on_drawing': round(h0, 3),
            'best_shift_mm': [round(dx), round(dy)], 'pass': h0 >= 0.6 and (dx, dy) == (0.0, 0.0),
            'evidence': 'xml_on_drawing = share of the XML member length that lies on drawn ink (no shift); pass needs >= 0.6. '
                        'A best shift other than 0 (searched +-250 mm) means the XML or the view calibration is off by that much.'}


def drawing_tile(pdf, view, x0, y0, size=4800, out='tile.png'):
    from ship_pairs import render_tile
    v = _view(pdf, view)
    box = (float(x0), float(x0) + size, float(y0), float(y0) + size)
    render_tile(v, box, out)
    return {'image': os.path.abspath(out), 'box_mm': box, 'z_mm': v['z_mm'], 'notes': v.get('notes', {})}


def xml_from_members(table, z, out):
    from ship_rag import table_to_xml
    t = table if isinstance(table, dict) else json.loads(table)
    table_to_xml(t, float(z), out)
    return {'xml': os.path.abspath(out), 'members': len(t.get('members', []))}


def xml_validate(xml):
    from ship_xml_kit import validate_file
    return validate_file(xml, verbose=False)


def ocr_fix(text):
    from ship_online import fix_text
    t, r = fix_text(text)
    return {'text': t, 'rule': r or 'unchanged'}


def classify_number(text, near=''):
    from ship_online import classify_number as c
    return {'class': c(text, near), 'rule': 'R2.1'}


S = lambda **p: {'type': 'object', 'properties': {k: {'type': t} for k, t in p.items()}, 'required': list(p)}
TOOLS = {
    'rules_search': (rules_search, 'Search the ship rule book (current rules only).', S(query='string')),
    'check_members': (check_members, 'Rule checks C3-C6, PN1, PN4 on a member table {outline?, members:[{id,sec,a,b}]}.', S(table='object')),
    'alike_score': (alike_score, 'How alike an XML deck is to its drawing (share on ink, best shift, pass).', S(xml='string', pdf='string', view='string')),
    'drawing_tile': (drawing_tile, 'Render a deck-plan tile (ship X/Y mm box) for reading.', S(pdf='string', view='string', x0='number', y0='number')),
    'xml_from_members': (xml_from_members, 'Write moulded-line ship XML from member JSON (code, not the model).', S(table='object', z='number', out='string')),
    'xml_validate': (xml_validate, 'Validate a ship XML file (C1-C6).', S(xml='string')),
    'ocr_fix': (ocr_fix, 'Correct an OCR label (R-T17..R-T22).', S(text='string')),
    'classify_number': (classify_number, 'R2.1 class of a printed number (weld size is never a thickness).', S(text='string')),
}


def call(name, args):
    fn = TOOLS[name][0]
    return fn(**args)


def serve():
    """minimal MCP server over stdio (JSON-RPC 2.0, newline-delimited)"""
    for line in sys.stdin:
        if not line.strip():
            continue
        req = json.loads(line)
        mid, method, p = req.get('id'), req.get('method'), req.get('params') or {}
        if mid is None:
            continue                                     # notification
        try:
            if method == 'initialize':
                res = {'protocolVersion': p.get('protocolVersion', '2024-11-05'), 'capabilities': {'tools': {}},
                       'serverInfo': {'name': 'ship-tools', 'version': '1.0'}}
            elif method == 'tools/list':
                res = {'tools': [{'name': n, 'description': d, 'inputSchema': s,
                                  'annotations': {'readOnlyHint': n != 'xml_from_members'}} for n, (_, d, s) in TOOLS.items()]}
            elif method == 'tools/call':
                out = call(p['name'], p.get('arguments') or {})
                res = {'content': [{'type': 'text', 'text': json.dumps(out)}], 'isError': False}
            else:
                raise ValueError('unknown method ' + str(method))
            msg = {'jsonrpc': '2.0', 'id': mid, 'result': res}
        except Exception as e:
            msg = {'jsonrpc': '2.0', 'id': mid, 'result': {'content': [{'type': 'text', 'text': f'error: {e}'}], 'isError': True}} \
                if method == 'tools/call' else {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32601, 'message': str(e)}}
        sys.stdout.write(json.dumps(msg) + '\n'); sys.stdout.flush()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'serve':
        serve()
    elif len(sys.argv) > 1 and sys.argv[1] == 'list':
        for n, (_, d, _s) in TOOLS.items():
            print(f'{n:18s} {d}')
    elif len(sys.argv) > 3 and sys.argv[1] == 'call':
        print(json.dumps(call(sys.argv[2], json.loads(sys.argv[3])), indent=1)[:4000])
    else:
        print(__doc__)
