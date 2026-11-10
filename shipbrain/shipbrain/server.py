"""
ShipBrain desktop app: a local web page (http://127.0.0.1:7860) that talks to your local model.

  python -m shipbrain                                   # model already running (llama-server / Ollama / LM Studio / llamafile)
  python -m shipbrain --model shipbrain-q4_k_m.gguf     # starts llama-server for you (CPU), then the app
  python -m shipbrain --model shipbrain.llamafile       # single-file model: starts it, then the app
  python -m shipbrain --knowledge D:\\ship_src --plugin D:\\cad-llm-repo   # your rule book + your private ship tools

Nothing leaves the PC: the page, the model and the tools all run locally.
"""
import argparse, base64, json, os, re, shutil, subprocess, sys, threading, time, urllib.parse, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import agent, knowledge

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = {}


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype='application/json', extra=None):
        b = body if isinstance(body, bytes) else (json.dumps(body) if ctype == 'application/json' else body).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return json.loads(self.rfile.read(n) or b'{}')

    def _local_only(self):
        host = (self.headers.get('Host') or '').split(':')[0]
        if host not in ('127.0.0.1', 'localhost') and not STATE.get('lan'):
            self._send(403, {'error': 'local access only'})
            return False
        return True

    def do_GET(self):
        if not self._local_only():
            return
        u = urllib.parse.urlparse(self.path)
        if u.path == '/':
            self._send(200, open(os.path.join(HERE, 'ui.html'), encoding='utf-8').read(), 'text/html; charset=utf-8')
        elif u.path == '/api/status':
            llm, tools = STATE['llm'], STATE['tools']
            self._send(200, {'model_ok': bool(llm and llm.ok()), 'server': llm.base if llm else None, 'model': llm.model if llm else None,
                             'tools': list(tools.t), 'knowledge_chunks': len(tools.kb or []), 'workdir': tools.workdir})
        elif u.path == '/api/files':
            self._send(200, STATE['tools'].list_files())
        elif u.path.startswith('/files/'):
            name = os.path.basename(urllib.parse.unquote(u.path[7:]))
            p = os.path.join(STATE['tools'].workdir, name)
            if not os.path.isfile(p):
                return self._send(404, {'error': 'not found'})
            self._send(200, open(p, 'rb').read(), 'application/octet-stream', {'Content-Disposition': f'attachment; filename="{name}"'})
        else:
            self._send(404, {'error': 'not found'})

    def do_POST(self):
        if not self._local_only():
            return
        if self.path == '/api/upload':
            d = self._body()
            name = re.sub(r'[^A-Za-z0-9_\-\.]', '_', os.path.basename(d['name']))
            open(os.path.join(STATE['tools'].workdir, name), 'wb').write(base64.b64decode(d['data']))
            return self._send(200, {'saved': name})
        if self.path == '/api/settings':
            d = self._body()
            if d.get('server'):
                STATE['llm'] = agent.LLM(d['server'], d.get('model') or 'local', api_key=d.get('api_key') or None)
            return self._send(200, {'ok': True})
        if self.path != '/api/chat':
            return self._send(404, {'error': 'not found'})
        hist = [{'role': m['role'], 'content': m['content']} for m in self._body().get('messages', []) if m.get('content')]
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        llm, tools = STATE['llm'], STATE['tools']
        offline = not llm or not llm.ok() or hist[-1]['content'].lstrip().startswith('/')
        try:
            gen = agent.run_offline(tools, hist) if offline else agent.run(llm, tools, hist)
            for ev in gen:
                self.wfile.write(b'data: ' + json.dumps(ev, default=str).encode() + b'\n\n')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            self.wfile.write(b'data: ' + json.dumps({'type': 'error', 'message': f'{type(e).__name__}: {e}'}).encode() + b'\n\n')
        self.close_connection = True


# ---------------------------------------------------------------------- local model launcher
def start_model(path, port, threads=None, ctx=8192, mmproj=None, bin_=None):
    """start llama-server (for .gguf) or the llamafile itself; returns the base URL once /health answers"""
    path = os.path.abspath(path)
    if path.endswith('.gguf'):
        exe = bin_ or shutil.which('llama-server') or shutil.which('llama-server.exe')
        if not exe:
            sys.exit('llama-server not found. Download llama.cpp (CPU build) and put llama-server on PATH, or pass --llama-bin, '
                     'or use a .llamafile model.')
        cmd = [exe, '-m', path, '--port', str(port), '-c', str(ctx), '--host', '127.0.0.1']
        if mmproj:
            cmd += ['--mmproj', mmproj]
    else:                                                            # llamafile: model + server in one executable
        if os.name != 'nt' and not os.access(path, os.X_OK):
            os.chmod(path, 0o755)
        cmd = ([path] if os.name == 'nt' else ['sh', path]) if not path.endswith('.exe') else [path]
        cmd += ['--server', '--nobrowser', '--port', str(port), '-c', str(ctx), '--host', '127.0.0.1']
    if threads:
        cmd += ['-t', str(threads)]
    print('starting model:', ' '.join(cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    url = f'http://127.0.0.1:{port}'
    llm = agent.LLM(url)
    for _ in range(600):
        if proc.poll() is not None:
            sys.exit('the model server stopped while loading (not enough RAM? wrong file?)')
        if llm.ok():
            return url, proc
        time.sleep(1)
    sys.exit('the model server did not start within 10 minutes')


def main(argv=None):
    ap = argparse.ArgumentParser(prog='shipbrain', description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--server', default=os.environ.get('SHIPBRAIN_SERVER', 'http://127.0.0.1:8080'),
                    help='OpenAI-compatible server: llama-server :8080, Ollama :11434, LM Studio :1234')
    ap.add_argument('--model-name', default=os.environ.get('SHIPBRAIN_MODEL', 'local'), help='model name for Ollama/LM Studio')
    ap.add_argument('--model', help='.gguf (starts llama-server) or .llamafile (starts itself)')
    ap.add_argument('--mmproj', help='vision projector .gguf (image input)')
    ap.add_argument('--llama-bin', help='path to llama-server')
    ap.add_argument('--threads', type=int)
    ap.add_argument('--ctx', type=int, default=8192)
    ap.add_argument('--knowledge', action='append', default=[], help='folder or file to learn from (repeatable)')
    ap.add_argument('--plugin', action='append', default=[], help='python file / folder with TOOLS = {...} (e.g. your ship_mcp.py)')
    ap.add_argument('--workdir', default='shipbrain_work')
    ap.add_argument('--allow-code', action='store_true', help='let the model run CadQuery scripts on this PC (cadquery_build tool)')
    ap.add_argument('--port', type=int, default=7860)
    ap.add_argument('--lan', action='store_true', help='allow other PCs on the network to open the page (default: this PC only)')
    ap.add_argument('--no-browser', action='store_true')
    a = ap.parse_args(argv)

    proc = None
    if a.model:
        a.server, proc = start_model(a.model, 8081, a.threads, a.ctx, a.mmproj, a.llama_bin)
    kb = knowledge.load(a.knowledge)
    tools = agent.Tools(a.workdir, kb, allow_code=a.allow_code)
    for p in a.plugin:
        try:
            print(f'plugin {p}: {tools.load_plugin(p)} tools')
        except Exception as e:
            print(f'plugin {p} not loaded: {e}')
    STATE.update(llm=agent.LLM(a.server, a.model_name), tools=tools, lan=a.lan)
    print(f'knowledge: {len(kb)} chunks' + (f' ({len(kb.skipped)} files skipped)' if kb.skipped else ''))
    print(f'model server: {a.server} ({"connected" if STATE["llm"].ok() else "NOT reachable - tools and knowledge search still work"})')
    srv = ThreadingHTTPServer(('0.0.0.0' if a.lan else '127.0.0.1', a.port), H)
    url = f'http://127.0.0.1:{a.port}'
    print('ShipBrain running at', url)
    if not a.no_browser:
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if proc:
            proc.terminate()


if __name__ == '__main__':
    main()
