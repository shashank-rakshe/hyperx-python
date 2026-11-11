"""
Use any MCP server's tools from ShipBrain (MCP over stdio, JSON-RPC 2.0), so other people's engines are used as written:
their own server, their own operations, nothing rewritten.

Servers: OpenPhysicsAI (built in, once compiled) + any listed in <workdir>/mcp_servers.json:
    {"myserver": {"command": ["python", "server.py"], "cwd": "C:/tools/x", "env": {"KEY": "..."}}}
"""
import json, os, subprocess, threading

PROTOCOL = '2025-06-18'
_LIVE = {}


class MCPClient:
    def __init__(self, command, cwd=None, env=None, timeout=600):
        self.p = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                  cwd=cwd, env=dict(os.environ, **(env or {})), bufsize=1, encoding='utf-8', errors='replace')
        self.lock, self.n, self.timeout, self._tools = threading.Lock(), 0, timeout, None
        r = self.request('initialize', {'protocolVersion': PROTOCOL, 'capabilities': {},
                                        'clientInfo': {'name': 'shipbrain', 'version': '1'}})
        self.info = r.get('serverInfo', {})
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def _send(self, msg):
        self.p.stdin.write(json.dumps(msg) + '\n')
        self.p.stdin.flush()

    def request(self, method, params=None):
        with self.lock:
            self.n += 1
            i = self.n
            self._send({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params or {}})
            while True:
                line = self.p.stdout.readline()
                if not line:
                    raise RuntimeError('the MCP server stopped')
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get('id') == i:
                    if 'error' in d:
                        raise RuntimeError(f"{method}: {d['error'].get('message', d['error'])}")
                    return d.get('result', {})

    def tools(self):
        if self._tools is None:
            out, cursor = [], None
            while True:
                r = self.request('tools/list', {'cursor': cursor} if cursor else {})
                out += r.get('tools', [])
                cursor = r.get('nextCursor')
                if not cursor:
                    break
            self._tools = out
        return self._tools

    def call(self, name, arguments=None):
        r = self.request('tools/call', {'name': name, 'arguments': arguments or {}})
        texts = [c.get('text', '') for c in r.get('content', []) if c.get('type') == 'text']
        out = r.get('structuredContent')
        if out is None and len(texts) == 1:
            try:
                out = json.loads(texts[0])
            except ValueError:
                out = texts[0]
        return {'result': out if out is not None else '\n'.join(texts), 'is_error': bool(r.get('isError'))}

    def close(self):
        try:
            self.p.kill()
        except Exception:
            pass


def solidcraft_cli():
    """SolidCraft's command-line program (its MCP server is `solidcraft-cli mcp`): PATH, SHIPBRAIN_SOLIDCRAFT, usual installs"""
    import glob, shutil
    for c in [os.environ.get('SHIPBRAIN_SOLIDCRAFT'), shutil.which('solidcraft-cli'), shutil.which('solidcraft-cli.exe')] + \
            sorted(glob.glob(r'C:\Program Files\SolidCraft*\solidcraft-cli.exe')) + \
            sorted(glob.glob(os.path.expanduser('~/AppData/Local/Programs/SolidCraft*/solidcraft-cli.exe'))) + \
            ['/Applications/SolidCraft.app/Contents/MacOS/solidcraft-cli', '/snap/bin/solidcraft.solidcraft-cli']:
        if c and os.path.exists(c):
            return c
    return None


def servers(workdir=None):
    """name -> {command, cwd, env}"""
    out = {}
    from . import openphysics
    if openphysics.available():
        out['openphysics'] = {'command': None, 'cwd': openphysics.ROOT, 'builtin': True}
    sc = solidcraft_cli()
    if sc:                                             # SolidCraft parametric CAD (MIT / Apache), installed from solidcraft.io
        out['solidcraft'] = {'command': [sc, 'mcp']}
    from . import dwsim
    if dwsim.exe():                                    # DWSIM process simulator (GPL), built with dwsim.build()
        out['dwsim'] = {'command': [dwsim.exe(), '--stdio']}
    try:
        import importlib.util
        if importlib.util.find_spec('pydexpi'):        # pyDEXPI (AGPL): DEXPI P&ID models
            import sys as _s
            out['dexpi'] = {'command': [_s.executable, '-c', 'from pydexpi.mcp_server.server import main; main()']}
    except Exception:
        pass
    p = os.path.join(workdir or '.', 'mcp_servers.json')
    if os.path.exists(p):
        out.update(json.load(open(p, encoding='utf-8')))
    return out


def client(name, workdir=None):
    if name in _LIVE and _LIVE[name].p.poll() is None:
        return _LIVE[name]
    cfg = servers(workdir).get(name)
    if not cfg and name.lower() == 'solidcraft':
        raise RuntimeError('SolidCraft is not installed on this PC (it is needed for its MCP server: solidcraft-cli mcp)')
    if not cfg and name.lower() == 'dwsim':
        raise RuntimeError('DWSIM is not built yet: the .NET 10 SDK is needed to build the DWSIM MCP server')
    if not cfg:
        raise ValueError(f'unknown MCP server {name}; known: ' + ', '.join(servers(workdir)))
    cmd = cfg.get('command')
    if cfg.get('builtin') and name == 'openphysics':
        from . import openphysics
        cmd = openphysics.server_command()
    _LIVE[name] = MCPClient(cmd, cfg.get('cwd'), cfg.get('env'))
    return _LIVE[name]
