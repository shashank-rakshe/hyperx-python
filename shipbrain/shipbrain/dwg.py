"""
DWG (AutoCAD's closed format) -> DXF with the free ODA File Converter (Open Design Alliance; free download from
opendesign.com, "ODA File Converter"). Its licence does not allow ShipBrain to ship it, so ShipBrain FINDS it on the PC:
PATH, the usual install folders, or the path given once (remember: ~/.shipbrain/oda.txt or SHIPBRAIN_ODA).

    to_dxf("deck_rev_B.dwg") -> ".../deck_rev_B.dxf"   (cached next to a hidden copy; redone when the DWG changes)
Every drawing tool calls drawing_file(path) first, so .dwg works wherever .dxf does.

ODA's command line: ODAFileConverter <input folder> <output folder> <version> <DWG|DXF> <recurse 0|1> <audit 0|1> [filter]
On Linux it is a Qt program: without a screen it runs with QT_QPA_PLATFORM=offscreen (or under xvfb-run).
"""
import glob, os, shutil, subprocess, tempfile

REMEMBER = os.path.join(os.path.expanduser('~'), '.shipbrain', 'oda.txt')
CACHE = os.path.join(os.path.expanduser('~'), '.cache', 'shipbrain', 'dwg')
PLACES = [r'C:\Program Files\ODA\ODAFileConverter*\ODAFileConverter.exe', r'C:\Program Files (x86)\ODA\ODAFileConverter*\ODAFileConverter.exe',
          '/usr/bin/ODAFileConverter', '/usr/local/bin/ODAFileConverter', '/opt/ODAFileConverter*/ODAFileConverter',
          '/Applications/ODAFileConverter.app/Contents/MacOS/ODAFileConverter', os.path.expanduser('~/Applications/ODAFileConverter*')]


def find():
    """path of ODA File Converter, or None"""
    for p in (os.environ.get('SHIPBRAIN_ODA'), open(REMEMBER).read().strip() if os.path.exists(REMEMBER) else None):
        if p and os.path.exists(p):
            return p
    for name in ('ODAFileConverter', 'ODAFileConverter.exe'):
        if shutil.which(name):
            return shutil.which(name)
    for pat in PLACES:
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[-1]                                  # newest version folder
    return None


def remember(path):
    if not os.path.exists(path):
        raise ValueError(f'{path} does not exist')
    os.makedirs(os.path.dirname(REMEMBER), exist_ok=True)
    open(REMEMBER, 'w').write(path)
    return path


def to_dxf(dwg, version='ACAD2018', exe=None, timeout=600):
    exe = exe or find()
    if not exe:
        raise RuntimeError('DWG needs the free ODA File Converter (free download: https://www.opendesign.com/guestfiles/oda_file_converter ). '
                           'Install it, or save the drawing as DXF in AutoCAD (SAVEAS -> DXF). If it is installed in an '
                           'unusual folder, tell ShipBrain once where ODAFileConverter is.')
    dwg = os.path.abspath(dwg)
    st = os.stat(dwg)
    key = f'{os.path.splitext(os.path.basename(dwg))[0]}_{st.st_size}_{int(st.st_mtime)}'
    out = os.path.join(CACHE, key, os.path.splitext(os.path.basename(dwg))[0] + '.dxf')
    if os.path.exists(out):
        return out
    src = tempfile.mkdtemp(prefix='sb_dwg_in_')              # ODA converts whole folders: one file per folder
    shutil.copy2(dwg, src)
    dst = os.path.dirname(out)
    os.makedirs(dst, exist_ok=True)
    env = dict(os.environ)
    cmd = [exe, src, dst, version, 'DXF', '0', '1']
    if os.name != 'nt' and not env.get('DISPLAY'):
        env.setdefault('QT_QPA_PLATFORM', 'offscreen')
        if shutil.which('xvfb-run') and not exe.endswith('.py'):
            cmd = ['xvfb-run', '-a'] + cmd
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
    shutil.rmtree(src, ignore_errors=True)
    if not os.path.exists(out):
        cand = glob.glob(os.path.join(dst, '*.dxf')) + glob.glob(os.path.join(dst, '*.DXF'))
        if cand:
            os.replace(cand[0], out)
    if not os.path.exists(out):
        raise RuntimeError('ODA File Converter made no DXF: ' + ((r.stderr or r.stdout) or f'exit {r.returncode}').strip()[-800:])
    return out


def drawing_file(path):
    """.dwg -> its DXF (converted once); anything else unchanged"""
    return to_dxf(path) if str(path).lower().endswith('.dwg') else path
