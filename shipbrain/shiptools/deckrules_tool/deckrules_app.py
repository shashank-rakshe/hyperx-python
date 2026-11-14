"""deckrules - offline desktop app. Double-click 'Start deckrules.bat'.
Opens a page in your browser (served only on this computer, 127.0.0.1; nothing leaves the PC):
drop a drawing PDF -> the offline tool builds the moulded-line XML -> see decks / walls / frames built, the questions the
drawing does not answer, Rule 5 coverage, and the model in 3D; write your answers / new rule notes for Claude.
Only the Python standard library + the tool's own packages."""
import json, os, sys, time, threading, subprocess, webbrowser, socket, re, datetime, shutil
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, unquote

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, 'app_work')
CFG = os.path.join(WORK, 'app_settings.json')
JOBS = {}
os.makedirs(WORK, exist_ok=True)


def cfg():
    try:
        return json.load(open(CFG, encoding='utf-8'))
    except Exception:
        return {'drawing_folders': ''}


def save_cfg(c):
    json.dump(c, open(CFG, 'w', encoding='utf-8'), indent=1)


def settings_files():
    fs = sorted(f for f in os.listdir(HERE) if f.startswith('settings') and f.endswith('.json'))
    if 'settings_new_drawing.json' in fs:
        fs.remove('settings_new_drawing.json')
        fs.insert(0, 'settings_new_drawing.json')
    return fs


def scan_kind(pdf):
    """'' for a vector PDF; text for a scan (every checked page: almost no text words and almost no drawn lines, but images)."""
    try:
        import pymupdf
        d = pymupdf.open(pdf)
        n = min(len(d), 3)
        words = sum(len(d[i].get_text('words')) for i in range(n))
        lines = sum(len(d[i].get_drawings()) for i in range(n))
        imgs = sum(len(d[i].get_images()) for i in range(n))
        if words < 30 and lines < 50 and imgs:
            return f'{words} text words, {lines} drawn lines, {imgs} images on the first {n} pages'
    except Exception:
        pass
    return ''


OCR_WHY = []


def ocr_backend():
    """R-APP2: the engine that really starts (the same code the build uses), not only one that imports; the reason of every failed engine is kept."""
    OCR_WHY.clear()
    try:
        from deckrules.ocr import OCR
        return OCR('auto').backend or ''
    except Exception as e:
        OCR_WHY.append(str(e))
        return ''


def run_job(jid):
    j = JOBS[jid]
    env = dict(os.environ)
    env['DECKRULES_DRAWING_FOLDERS'] = os.pathsep.join(x.strip() for x in re.split(r'[;\n]', cfg().get('drawing_folders', '')) if x.strip())
    env['PYTHONIOENCODING'] = 'utf-8'
    cmd = [sys.executable, '-u', '-m', 'deckrules.build_ship', j['pdf'], '--settings', os.path.join(HERE, j['settings']), '--out', j['out']]
    if j.get('pages'):
        cmd += ['--pages', j['pages']]
    j['t0'] = time.time()
    scan = scan_kind(j['pdf'])
    if scan:
        # R-APP1: a PDF with no text and no vector lines is a SCAN (8366 Deck House): it needs the local OCR front end (--raster)
        ocr = ocr_backend()
        if not ocr:
            msg = ('This drawing is a SCANNED image (no text, no vector lines in the PDF). It needs the offline OCR front end, which is not installed: '
                   'run  python -m pip install rapidocr-onnxruntime opencv-python-headless  once, then drop the PDF again.  ' + ' | '.join(OCR_WHY))
            j['log'].append('ERROR: ' + msg)
            with open(os.path.join(j['out'], 'app_log.txt'), 'w', encoding='utf-8') as lf:
                lf.write('ERROR: ' + msg + '\n')
            j['rc'] = 2; j['seconds'] = 0; j['state'] = 'failed'; j['error'] = msg
            return
        j['log'].append(f'scanned drawing detected ({scan}) -> OCR front end ({ocr}); this is slower than a vector PDF')
        cmd += ['--raster']
    with open(os.path.join(j['out'], 'app_log.txt'), 'w', encoding='utf-8') as lf:
        p = subprocess.Popen(cmd, cwd=HERE, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
        j['proc'] = p
        for line in p.stdout:
            j['log'].append(line.rstrip())
            lf.write(line)
        p.wait()
    j['rc'] = p.returncode
    j['seconds'] = round(time.time() - j['t0'])
    j['state'] = 'done' if p.returncode == 0 else 'failed'
    try:
        make_viewer(j)
    except Exception as e:
        j['log'].append(f'(3D view not made: {e})')


def xml_of(j):
    xs = [f for f in os.listdir(j['out']) if f.endswith('_complete_moulded.xml')]
    return os.path.join(j['out'], xs[0]) if xs else None


def make_viewer(j):
    x = xml_of(j)
    if not x:
        return
    if '<Plate' not in open(x, encoding='utf-8', errors='replace').read():
        j['log'].append('The XML holds no plates / stiffeners: nothing to show in 3D (see BUILD_REPORT.md for the reason).')
        return
    v = open(os.path.join(HERE, 'ship_xml_viewer.html'), encoding='utf-8').read()
    data = json.dumps(open(x, encoding='utf-8').read()).replace('</', '<\\/')
    inj = ("<script>addEventListener('load',()=>{const T=" + data + ";load([{name:" + json.dumps(os.path.basename(x)) +
           ",text:async()=>T}])});</script></body>")
    open(os.path.join(j['out'], 'view_3d.html'), 'w', encoding='utf-8').write(v.replace('</body>', inj, 1))


def result(j):
    r = {'state': j['state'], 'seconds': j.get('seconds'), 'out': j['out'], 'pdf': os.path.basename(j['pdf']), 'error': j.get('error', '')}
    rp = os.path.join(j['out'], 'BUILD_REPORT.json')
    if os.path.exists(rp):
        R = json.load(open(rp, encoding='utf-8'))
        r['questions'] = R.get('questions', [])
        r['rule_errors'] = R.get('rule_errors', [])
        st = R.get('stages', {})
        r['stages'] = st
        x = R.get('xml') or {}
        r['xml'] = x if isinstance(x, dict) else {'info': x}
        r5 = R.get('rule5') or {}
        r['rule5'] = r5 if isinstance(r5, dict) else {'info': r5}
        r['validation'] = R.get('validation')
    md = os.path.join(j['out'], 'BUILD_REPORT.md')
    r['report_md'] = open(md, encoding='utf-8').read() if os.path.exists(md) else ''
    rv = os.path.join(j['out'], 'rule5.json')
    if os.path.exists(rv):
        V = [v for v in json.load(open(rv, encoding='utf-8')).get('views', []) if 'coverage' in v]
        r['coverage'] = {'mean': round(sum(v['coverage'] for v in V) / len(V), 3) if V else None,
                         'views': [{'view': v['view'], 'type': v.get('type'), 'coverage': round(v['coverage'], 3)} for v in sorted(V, key=lambda v: v['coverage'])]}
    x = xml_of(j)
    r['xml_file'] = x
    r['has_view'] = os.path.exists(os.path.join(j['out'], 'view_3d.html'))
    tn = os.path.join(j['out'], 'teach_notes.json')
    r['notes'] = json.load(open(tn, encoding='utf-8')) if os.path.exists(tn) else {}
    return r


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, ctype='application/json', code=200, extra=None):
        b = body if isinstance(body, bytes) else (json.dumps(body) if ctype == 'application/json' else body).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype + ('; charset=utf-8' if not ctype.startswith('application/octet') else ''))
        self.send_header('Content-Length', str(len(b)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == '/':
            return self._send(PAGE, 'text/html')
        if u.path == '/info':
            return self._send({'settings': settings_files(), 'cfg': cfg(),
                               'jobs': [{'id': k, 'pdf': os.path.basename(v['pdf']), 'state': v['state']} for k, v in JOBS.items()]})
        j = JOBS.get(q.get('job', ''))
        if u.path == '/log' and j:
            n = int(q.get('from', 0))
            return self._send({'state': j['state'], 'lines': j['log'][n:], 'n': len(j['log']),
                               'elapsed': round(time.time() - j.get('t0', time.time()))})
        if u.path == '/result' and j:
            return self._send(result(j))
        if u.path == '/view' and j:
            p = os.path.join(j['out'], 'view_3d.html')
            return self._send(open(p, 'rb').read(), 'text/html') if os.path.exists(p) else self._send('no model', 'text/plain', 404)
        if u.path == '/file' and j:
            f = os.path.basename(q.get('f', ''))
            p = os.path.join(j['out'], f)
            if os.path.isfile(p):
                return self._send(open(p, 'rb').read(), 'application/octet-stream', extra={'Content-Disposition': f'attachment; filename="{f}"'})
        self._send({'error': 'not found'}, code=404)

    def do_POST(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n) if n else b''
        if u.path == '/build':
            name = os.path.basename(unquote(q.get('name', 'drawing.pdf')))
            if not name.lower().endswith('.pdf'):
                return self._send({'error': 'please drop a PDF drawing'}, code=400)
            jid = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
            jd = os.path.join(WORK, jid + '_' + re.sub(r'[^\w.-]+', '_', os.path.splitext(name)[0]))
            os.makedirs(jd, exist_ok=True)
            pdf = os.path.join(jd, name)
            open(pdf, 'wb').write(body)
            JOBS[jid] = {'pdf': pdf, 'out': os.path.join(jd, 'output'), 'settings': q.get('settings') or settings_files()[0],
                         'pages': q.get('pages', '').strip(), 'log': [], 'state': 'running'}
            os.makedirs(JOBS[jid]['out'], exist_ok=True)
            threading.Thread(target=run_job, args=(jid,), daemon=True).start()
            return self._send({'job': jid})
        if u.path == '/cfg':
            c = cfg(); c.update(json.loads(body or b'{}')); save_cfg(c)
            return self._send(c)
        j = JOBS.get(q.get('job', ''))
        if u.path == '/notes' and j:
            d = json.loads(body or b'{}')
            d['_saved'] = datetime.datetime.now().isoformat(timespec='seconds')
            d['_drawing'] = os.path.basename(j['pdf'])
            json.dump(d, open(os.path.join(j['out'], 'teach_notes.json'), 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
            return self._send({'ok': True, 'file': os.path.join(j['out'], 'teach_notes.json')})
        if u.path == '/open' and j:
            try:
                os.startfile(j['out']) if hasattr(os, 'startfile') else subprocess.Popen(['xdg-open', j['out']])
            except Exception as e:
                return self._send({'error': str(e)})
            return self._send({'ok': True})
        if u.path == '/stop' and j and j.get('proc'):
            j['proc'].kill(); j['state'] = 'failed'
            return self._send({'ok': True})
        self._send({'error': 'not found'}, code=404)


PAGE = r'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>deckrules - drawing to XML</title>
<style>
:root{--bg:#f3f5f7;--panel:#fff;--fg:#17222d;--mut:#5b6a78;--line:#d5dde5;--acc:#1e5aa8;--ok:#1d7a46;--warn:#a86a00;--bad:#c0392b}
@media (prefers-color-scheme:dark){:root{--bg:#141a20;--panel:#1c242c;--fg:#e4eaf0;--mut:#93a2b0;--line:#2e3a45;--acc:#7fb0ef;--ok:#6fd39a;--warn:#f2b84b;--bad:#ff8a7a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 "Segoe UI",system-ui,sans-serif}
header{padding:14px 20px;background:var(--panel);border-bottom:1px solid var(--line);display:flex;gap:16px;align-items:baseline;flex-wrap:wrap}
h1{font-size:1.25rem;margin:0}h2{font-size:1.05rem;margin:0 0 8px}.mut{color:var(--mut)}
main{max-width:1250px;margin:0 auto;padding:16px 20px;display:grid;gap:14px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px 16px}
#drop{border:2px dashed var(--acc);border-radius:10px;padding:34px;text-align:center;cursor:pointer;background:var(--panel)}
#drop.over{background:rgba(30,90,168,.08)}#drop b{font-size:1.15rem}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
select,input,textarea,button{font:inherit;color:var(--fg);background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:6px 10px}
button{cursor:pointer}button.pri{background:var(--acc);color:#fff;border-color:var(--acc)}
#log{height:260px;overflow:auto;background:#0f1418;color:#cfe3d4;font:12px/1.4 Consolas,monospace;padding:8px;border-radius:6px;white-space:pre-wrap}
.stats{display:flex;gap:10px;flex-wrap:wrap}.stat{border:1px solid var(--line);border-radius:6px;padding:8px 12px;min-width:140px}
.stat b{display:block;font-size:1.4rem}
table{border-collapse:collapse;width:100%;font-size:.9rem}td,th{border-bottom:1px solid var(--line);padding:5px 8px;text-align:left;vertical-align:top}
.q textarea{width:100%;min-height:38px}.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}
.tabs button[aria-pressed=true]{background:var(--acc);color:#fff;border-color:var(--acc)}
iframe{width:100%;height:72vh;border:1px solid var(--line);border-radius:6px;background:#fff}
.hidden{display:none}
</style></head><body>
<header><h1>deckrules - drawing PDF to moulded-line XML</h1><span class="mut">offline · runs only on this computer · rules v2.155</span></header>
<main>
<section class="card">
 <div id="drop" tabindex="0"><b>Drop a drawing PDF here</b><div class="mut">or click to choose a file</div><input id="file" type="file" accept=".pdf" hidden></div>
 <div class="row" style="margin-top:10px">
  <label>Project settings <select id="settings"></select></label>
  <label>Pages <input id="pages" placeholder="all (e.g. 1,2)" size="12"></label>
  <label style="flex:1;min-width:280px">Folder(s) with the other drawings of the same hull (bracket table etc.)
   <input id="folders" style="width:100%" placeholder="e.g. E:\LLM\claude approch\Drawing"></label>
 </div>
</section>
<section class="card hidden" id="runcard">
 <div class="row" style="justify-content:space-between"><h2 id="runtitle">Building ...</h2><span id="elapsed" class="mut"></span><button id="stop">Stop</button></div>
 <div id="log"></div>
</section>
<section class="card hidden" id="rescard">
 <div class="row" style="justify-content:space-between"><h2 id="restitle">Result</h2>
  <div class="row"><button id="open">Open output folder</button><a id="dlxml"><button class="pri">Download XML</button></a><a id="dlrep"><button>Download report</button></a></div></div>
 <div class="stats" id="stats"></div>
 <div class="row tabs" style="margin:12px 0" id="tabs">
  <button data-t="q" aria-pressed="true">Questions &amp; teaching</button><button data-t="v" aria-pressed="false">3D model</button>
  <button data-t="c" aria-pressed="false">Coverage by view</button><button data-t="r" aria-pressed="false">Full report</button></div>
 <div id="t_q"><p class="mut">What the drawing did not answer. Write your answer or the rule to teach next to any line, add free notes, then Save. The file teach_notes.json is written into the output folder - send it to Claude to turn into universal rules.</p>
  <table id="qtab"></table>
  <h2 style="margin-top:14px">New rule / correction (free text)</h2><textarea id="free" style="width:100%;min-height:90px" placeholder="e.g. 'NO.3L at 2640 is not a member' or 'B15 = 150x9'"></textarea>
  <div class="row" style="margin-top:8px"><button class="pri" id="save">Save teaching notes</button><span id="saved" class="mut"></span></div></div>
 <div id="t_v" class="hidden"><iframe id="viewer" title="3D model"></iframe><div class="mut">Drag to rotate · wheel to zoom · click a part for its data.</div></div>
 <div id="t_c" class="hidden"><table id="ctab"></table></div>
 <div id="t_r" class="hidden"><pre id="rep" style="white-space:pre-wrap;font-size:.82rem"></pre></div>
</section>
</main>
<script>
const $=s=>document.querySelector(s);let JOB=null,N=0,TIMER=null;
async function info(){const r=await (await fetch('/info')).json();$('#settings').innerHTML=r.settings.map(s=>`<option>${s}</option>`).join('');$('#folders').value=r.cfg.drawing_folders||''}
info();
$('#folders').addEventListener('change',()=>fetch('/cfg',{method:'POST',body:JSON.stringify({drawing_folders:$('#folders').value})}));
const drop=$('#drop');drop.onclick=()=>$('#file').click();$('#file').onchange=e=>e.target.files[0]&&start(e.target.files[0]);
['dragenter','dragover'].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.add('over')}));
['dragleave','drop'].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.remove('over')}));
drop.addEventListener('drop',e=>{const f=e.dataTransfer.files[0];if(f)start(f)});
addEventListener('dragover',e=>e.preventDefault());addEventListener('drop',e=>e.preventDefault());
async function start(f){
 await fetch('/cfg',{method:'POST',body:JSON.stringify({drawing_folders:$('#folders').value})});
 $('#rescard').classList.add('hidden');$('#runcard').classList.remove('hidden');$('#log').textContent='';N=0;
 $('#runtitle').textContent='Building '+f.name+' ...';
 const r=await (await fetch(`/build?name=${encodeURIComponent(f.name)}&settings=${encodeURIComponent($('#settings').value)}&pages=${encodeURIComponent($('#pages').value)}`,{method:'POST',body:f})).json();
 if(r.error){$('#log').textContent=r.error;return}JOB=r.job;poll()}
async function poll(){const r=await (await fetch(`/log?job=${JOB}&from=${N}`)).json();N=r.n;
 if(r.lines.length){const L=$('#log');L.textContent+=r.lines.join('\n')+'\n';L.scrollTop=L.scrollHeight}
 $('#elapsed').textContent=r.elapsed+' s';
 if(r.state==='running'){TIMER=setTimeout(poll,1000)}else{$('#runtitle').textContent=(r.state==='done'?'Finished':'FAILED - see the log')+' ('+r.elapsed+' s)';if(r.state==='done')$('#log').style.height='110px';show();$('#rescard').scrollIntoView({behavior:'smooth'})}}
$('#stop').onclick=()=>JOB&&fetch(`/stop?job=${JOB}`,{method:'POST'});
const esc=s=>String(s??'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
async function show(){const r=await (await fetch(`/result?job=${JOB}`)).json();$('#rescard').classList.remove('hidden');
 $('#restitle').textContent='Result - '+r.pdf;const X=r.xml||{};const cov=r.coverage||{};
 const st=[['XML',r.xml_file?'written':'none',r.xml_file?'ok':'bad'],['Blocks',X.blocks??'-',''],['Bar sections',X.bar_sections??'-',''],
  ['Rule 5 coverage',cov.mean!=null?Math.round(cov.mean*100)+' %':'-',cov.mean>=.8?'ok':cov.mean>=.6?'warn':'bad'],['Questions',(r.questions||[]).length,(r.questions||[]).length?'warn':'ok'],
  ['Rule errors',(r.rule_errors||[]).length,(r.rule_errors||[]).length?'bad':'ok'],['Time',(r.seconds??'-')+' s','']];
 $('#stats').innerHTML=st.map(s=>`<div class="stat"><span class="mut">${s[0]}</span><b class="${s[2]}">${esc(s[1])}</b></div>`).join('');
 const xf=r.xml_file?r.xml_file.split(/[\\/]/).pop():'';$('#dlxml').href=xf?`/file?job=${JOB}&f=${encodeURIComponent(xf)}`:'#';$('#dlrep').href=`/file?job=${JOB}&f=BUILD_REPORT.md`;
 const notes=r.notes||{};const ans=notes.answers||{};
 const qs=(r.questions||[]).concat((r.rule_errors||[]).map(e=>'RULE ERROR '+e.where+': '+e.error));
 $('#qtab').innerHTML='<tr><th style="width:52%">Question from the tool</th><th>Your answer / rule</th></tr>'+(qs.length?qs.map((q,i)=>`<tr class="q"><td>${esc(q)}</td><td><textarea data-q="${esc(q)}">${esc(ans[q]||'')}</textarea></td></tr>`).join(''):'<tr><td colspan=2 class="mut">No open questions.</td></tr>');
 $('#free').value=notes.free||'';
 $('#ctab').innerHTML='<tr><th>View</th><th>Type</th><th>Coverage</th></tr>'+(cov.views||[]).map(v=>`<tr><td>${esc(v.view)}</td><td>${esc(v.type)}</td><td class="${v.coverage>=.8?'ok':v.coverage>=.6?'warn':'bad'}">${Math.round(v.coverage*100)} %</td></tr>`).join('');
 $('#rep').textContent=r.report_md||'';$('#viewer').src=r.has_view?`/view?job=${JOB}`:'about:blank'}
$('#tabs').onclick=e=>{const b=e.target.closest('button');if(!b)return;document.querySelectorAll('#tabs button').forEach(x=>x.setAttribute('aria-pressed',x===b));['q','v','c','r'].forEach(t=>$('#t_'+t).classList.toggle('hidden',t!==b.dataset.t))};
$('#open').onclick=()=>fetch(`/open?job=${JOB}`,{method:'POST'});
$('#save').onclick=async()=>{const answers={};document.querySelectorAll('#qtab textarea').forEach(t=>{if(t.value.trim())answers[t.dataset.q]=t.value.trim()});
 const r=await (await fetch(`/notes?job=${JOB}`,{method:'POST',body:JSON.stringify({answers,free:$('#free').value})})).json();$('#saved').textContent=r.ok?'Saved: '+r.file:'Not saved'};
</script></body></html>'''


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p


if __name__ == '__main__':
    port = int(os.environ.get('DECKRULES_PORT') or free_port())
    srv = ThreadingHTTPServer(('127.0.0.1', port), H)
    url = f'http://127.0.0.1:{port}/'
    print('deckrules app running at', url, '- keep this window open; close it to stop.')
    if not os.environ.get('DECKRULES_NO_BROWSER'):
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    srv.serve_forever()
