"""
ShipBrain tools as an MCP server (stdio, JSON-RPC 2.0), so Claude Code or any MCP client can use the same tools
(meshers, FE conversion/editing, drawings, structure compare, knowledge + memory search):

    claude mcp add shipbrain -- python -m shipbrain.mcp_server --workdir D:\\work --knowledge D:\\ship_src --plugin D:\\cad-llm-repo
"""
import argparse, json, os, sys

from . import agent, knowledge
from .memory import Memory


def build(a):
    kb = knowledge.load(a.knowledge, cache_dir=os.path.join(a.workdir, '.index'))
    from .examples import Examples
    t = agent.Tools(a.workdir, kb, allow_code=a.allow_code, examples=Examples(), memory=Memory(os.path.join(a.workdir, '.memory')),
                    repo_kb=_repo_kb(a.packs))
    for p in a.plugin:
        try:
            t.load_plugin(p)
        except Exception as e:
            print(f'plugin {p} not loaded: {e}', file=sys.stderr)
    return t


def handle(tools, msg):
    mid, method, p = msg.get('id'), msg.get('method'), msg.get('params') or {}
    if mid is None:
        return None                                          # notification
    try:
        if method == 'initialize':
            res = {'protocolVersion': p.get('protocolVersion', '2024-11-05'), 'capabilities': {'tools': {}},
                   'serverInfo': {'name': 'shipbrain', 'version': '0.2'}}
        elif method == 'tools/list':
            res = {'tools': [{'name': n, 'description': d, 'inputSchema': s} for n, (_, d, s) in tools.t.items()]}
        elif method == 'tools/call':
            out = tools.call(p['name'], p.get('arguments') or {})
            res = {'content': [{'type': 'text', 'text': json.dumps(out, default=str)}], 'isError': 'error' in out if isinstance(out, dict) else False}
        elif method == 'ping':
            res = {}
        else:
            return {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32601, 'message': f'unknown method {method}'}}
        return {'jsonrpc': '2.0', 'id': mid, 'result': res}
    except Exception as e:
        return {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32000, 'message': str(e)}}


DEFAULT_PACKS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'packs')


def _repo_kb(folder):
    """knowledge packs of shared repos, in their own index"""
    if not folder or not os.path.isdir(folder):
        return None
    from .repopack import load_packs
    rk = knowledge.Knowledge()
    n = load_packs(folder, rk)
    print(f'repo packs: {n} chunks from {len(getattr(rk, "packs", []) or [])} repos', file=sys.stderr)
    return rk


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--workdir', default='shipbrain_work')
    ap.add_argument('--packs', default=DEFAULT_PACKS, help='folder of repo knowledge packs (.sbpack); "" = none')
    ap.add_argument('--knowledge', action='append', default=[])
    ap.add_argument('--plugin', action='append', default=[])
    ap.add_argument('--allow-code', action='store_true')
    a = ap.parse_args(argv)
    tools = build(a)
    for line in sys.stdin:
        if not line.strip():
            continue
        out = handle(tools, json.loads(line))
        if out is not None:
            sys.stdout.write(json.dumps(out) + '\n')
            sys.stdout.flush()


if __name__ == '__main__':
    main()
