"""
Missing software -> tell the user what to install, why, and the download link.

Every tool error goes through explain(error): if the cause is a program or Python package that is not on this PC,
the result gets an "install" block {name, why, link, steps, then} and a plain-English message with the link, the chat
shows it as a card with a clickable link, and the model is told to repeat it. setup_check() lists everything with
"installed / not installed" so the user can prepare a PC in one go.

Only free software is listed (no paid programs): the links are the official download pages.
"""
import importlib.util, os, re, shutil, sys

WIN, MAC = os.name == 'nt', sys.platform == 'darwin'


def _have_exe(*names):
    return lambda: any(shutil.which(n) for n in names)


def _have_mod(mod):
    return lambda: importlib.util.find_spec(mod) is not None


def _oda():
    from . import dwg
    return dwg.find() is not None


def _ccx():
    return bool(os.environ.get('CCX') and os.path.exists(os.environ['CCX'])) or _have_exe('ccx', 'ccx.exe', 'ccx_static')()


def _mystran():
    from . import solvers
    try:
        return any(x['solver'] == 'mystran' for x in solvers.find())
    except Exception:
        return False


def _pip(pkg, why, mod=None, match=None):
    return {'name': f'Python package {pkg}', 'why': why, 'link': f'https://pypi.org/project/{pkg}/',
            'steps': {'all': f'pip install {pkg}'}, 'check': _have_mod(mod or pkg), 'module': mod or pkg,
            'match': match, 'free': True}


SOFTWARE = {
    'oda': {'name': 'ODA File Converter (free)', 'why': 'to open AutoCAD DWG drawings (converts DWG to DXF)',
            'link': 'https://www.opendesign.com/guestfiles/oda_file_converter',
            'steps': {'windows': 'download the Windows installer from the link and run it; ShipBrain finds it by itself',
                      'linux': 'download the .deb or .rpm from the link and install it (sudo apt install ./ODAFileConverter*.deb)',
                      'mac': 'download the .dmg from the link and drag it to Applications'},
            'other': 'save the drawing as DXF in AutoCAD (SAVEAS -> DXF) and use that file',
            'check': _oda, 'match': r'ODA File Converter'},
    'calculix': {'name': 'CalculiX (free FE solver)', 'why': 'to run finite-element analyses (stress, frequencies, buckling)',
                 'link': 'http://www.calculix.de/',
                 'steps': {'windows': 'download ccx for Windows from the link (or: conda install -c conda-forge calculix), '
                                      'then tell ShipBrain where ccx.exe is (set CCX=C:\\path\\to\\ccx.exe)',
                           'linux': 'sudo apt install calculix-ccx   (or: conda install -c conda-forge calculix)',
                           'mac': 'brew install calculix-ccx   (or: conda install -c conda-forge calculix)'},
                 'check': _ccx, 'match': r'CalculiX|\bccx\b'},
    'fortran': {'name': 'gfortran + CMake (free compilers)', 'why': 'to build MYSTRAN from its source code',
                'link': 'https://fortran-lang.org/learn/os_setup/install_gfortran/',
                'steps': {'windows': 'easier: download the ready mystran.exe (https://github.com/MystranSolver/MYSTRANSolver/releases)',
                          'linux': 'sudo apt install gfortran cmake ninja-build git', 'mac': 'brew install gcc cmake ninja'},
                'check': _have_exe('gfortran'), 'match': r'gfortran|cmake|ninja.*needed to build MYSTRAN|needed to build MYSTRAN'},
    'mystran': {'name': 'MYSTRAN (free Nastran-compatible solver)', 'why': 'to run the Nastran .bdf files ShipBrain writes',
                'link': 'https://github.com/MystranSolver/MYSTRANSolver/releases',
                'steps': {'windows': 'download mystran.exe from the Releases page, then tell ShipBrain its path once (remember_solver)',
                          'linux': 'ShipBrain can build it: sudo apt install gfortran cmake ninja-build git, then python -c "from shipbrain import mystran; mystran.build()"',
                          'mac': 'brew install gcc cmake ninja, then python -c "from shipbrain import mystran; mystran.build()"'},
                'check': _mystran, 'match': r'mystran'},
    'rust': {'name': 'Rust (free)', 'why': 'to build the STL -> exact STEP converter (stl2step) once',
             'link': 'https://rustup.rs',
             'steps': {'windows': 'download rustup-init.exe from the link and run it',
                       'linux': "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh",
                       'mac': "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"},
             'then': 'python -c "from shipbrain import brep; brep.build()"   (about 5 minutes, once)',
             'check': _have_exe('cargo', 'cargo.exe'), 'match': r'Rust is needed|cargo'},
    'node': {'name': 'Node.js LTS (free)', 'why': 'to run JavaScript / TypeScript code that ShipBrain uses as written',
             'link': 'https://nodejs.org/en/download',
             'steps': {'windows': 'download the Windows installer (LTS) from the link and run it',
                       'linux': 'sudo apt install nodejs npm   (or the LTS from the link)', 'mac': 'brew install node'},
             'check': _have_exe('node', 'node.exe'), 'match': r'Node\.js'},
    'cc': {'name': 'C compiler + make (free)', 'why': 'to build the physics lab (OpenPhysicsAI) once',
           'link': 'https://learn.microsoft.com/windows/wsl/install' if WIN else ('https://developer.apple.com/xcode/resources/' if MAC
                                                                                  else 'https://packages.ubuntu.com/build-essential'),
           'steps': {'windows': 'the physics lab runs in WSL: open PowerShell as admin, run  wsl --install , then inside Ubuntu: '
                                'sudo apt install build-essential clang',
                     'linux': 'sudo apt install build-essential clang', 'mac': 'xcode-select --install'},
           'check': _have_exe('make'), 'match': r'C compiler and make|builds on Linux and macOS'},
    'tesseract': {'name': 'Tesseract OCR (free)', 'why': 'to read text from scanned drawings (pictures, not vector PDFs)',
                  'link': 'https://github.com/UB-Mannheim/tesseract/wiki' if WIN else 'https://tesseract-ocr.github.io/tessdoc/Installation.html',
                  'steps': {'windows': 'download the installer from the link and run it; tick "add to PATH"',
                            'linux': 'sudo apt install tesseract-ocr && pip install pytesseract',
                            'mac': 'brew install tesseract && pip install pytesseract'},
                  'check': _have_exe('tesseract', 'tesseract.exe'), 'match': r'tesseract'},
    'llama': {'name': 'llama.cpp (free model server)', 'why': 'to run the ShipBrain model on this PC',
              'link': 'https://github.com/ggml-org/llama.cpp/releases',
              'steps': {'windows': 'download llama-*-bin-win-cpu-x64.zip (or the CUDA one for an NVIDIA card), unzip, '
                                   'add the folder to PATH or pass --llama-bin',
                        'linux': 'download llama-*-bin-ubuntu-x64.zip, unzip, add to PATH', 'mac': 'brew install llama.cpp'},
              'check': _have_exe('llama-server', 'llama-server.exe'), 'match': r'llama-server'},
    'wasmtime': _pip('wasmtime', 'to run the Awatif frame solver (WebAssembly)', match=r'wasmtime'),
    'cadquery': _pip('cadquery', 'for 3D CAD: STEP files, solids, repair, mid-surfaces, pipes', match=r"No module named '(cadquery|OCP)"),
    'ezdxf': _pip('ezdxf', 'to read and write DXF drawings'),
    'pdfplumber': _pip('pdfplumber', 'to read lines and text in PDF drawings'),
    'pypdfium2': _pip('pypdfium2', 'to turn PDF pages into pictures'),
    'pytesseract': _pip('pytesseract', 'to call Tesseract OCR from Python'),
    'PIL': dict(_pip('pillow', 'to read and draw pictures', mod='PIL')),
    'psutil': _pip('psutil', 'to read CPU / memory of this PC'),
    'numpy': _pip('numpy', 'for all calculations'),
    'langchain': dict(_pip('langchain<1', 'for drawing_to_step (cad3dify runs on LangChain 0.3)', mod='langchain'),
                      link='https://pypi.org/project/langchain/',
                      steps={'all': 'pip install "langchain<1" "langchain-openai<1" "langchain-experimental<1" svglib rlPyCairo loguru'}),
    'ultralytics': _pip('ultralytics', 'to run the trained drawing symbol detector (drawing_detect; AGPL - fine for open, non-commercial use)'),
    'msgpack': _pip('msgpack', 'for construction drawing sets (CIR files, ConstructDrawingAI)'),
    'pydantic': _pip('pydantic', 'for construction drawing sets (CIR) and P&ID knowledge graphs'),
    'xsdata': _pip('xsdata', 'for OCX ship models: the official OCX classes of every schema version'),
    'xmlschema': _pip('xmlschema', 'to check OCX files against the official OCX schema (XSD)'),
    'vcpkg': {'name': 'CMake + vcpkg (free)', 'why': 'to build OCXReader once (OCX -> exact STEP; vcpkg brings OpenCascade)',
              'link': 'https://learn.microsoft.com/vcpkg/get_started/get-started',
              'steps': {'windows': 'install Visual Studio Build Tools and CMake (https://cmake.org/download/), then: git clone '
                                   'https://github.com/microsoft/vcpkg && vcpkg\\bootstrap-vcpkg.bat, set VCPKG_ROOT to that folder',
                        'linux': 'no vcpkg needed: sudo apt install cmake ninja-build g++ git libocct-data-exchange-dev '
                                 'libocct-modeling-algorithms-dev libocct-modeling-data-dev libocct-foundation-dev libocct-ocaf-dev '
                                 'libocct-visualization-dev libocct-draw-dev libspdlog-dev libboost-system-dev libboost-filesystem-dev '
                                 'libboost-program-options-dev libgtest-dev libfreetype-dev libtbb-dev libgl-dev libxi-dev libxmu-dev tk-dev tcl-dev',
                        'mac': 'brew install cmake ninja, then: git clone https://github.com/microsoft/vcpkg && ./vcpkg/bootstrap-vcpkg.sh '
                               '&& export VCPKG_ROOT=$PWD/vcpkg'},
              'then': 'python -c "from shipbrain import ocx; ocx.reader_build()"   (Linux: about 1 minute; with vcpkg longer)',
              'check': lambda: bool(os.environ.get('VCPKG_ROOT')) or not WIN and bool(shutil.which('cmake')),
              'match': r'vcpkg|CMake is needed to build OCXReader|OpenCascade C\+\+ files are needed'},
    'scipy': _pip('scipy', 'for solvers and fitting'),
    # free engines the router may name (guided set-up); no paid programs here
    'openfoam': {'name': 'OpenFOAM (free CFD)', 'why': 'for CFD runs (resistance, wind loads, sloshing)',
                 'link': 'https://openfoam.org/download/',
                 'steps': {'windows': 'install it inside WSL (Ubuntu) following the link', 'linux': 'follow the Ubuntu steps on the link',
                           'mac': 'use the Docker image from the link'}, 'check': _have_exe('simpleFoam', 'blockMesh')},
    'elmer': {'name': 'Elmer FEM (free multiphysics)', 'why': 'for heat, flow and coupled analyses', 'link': 'https://www.elmerfem.org/blog/binaries/',
              'steps': {'all': 'download the installer for your system from the link'}, 'check': _have_exe('ElmerSolver')},
    'code_aster': {'name': 'Code_Aster (free FE)', 'why': 'for non-linear, contact and fatigue analyses', 'link': 'https://code-aster.org/V2/spip.php?article272',
                   'steps': {'all': 'download it (or the salome_meca bundle) from the link'}, 'check': _have_exe('run_aster', 'as_run')},
    'openradioss': {'name': 'OpenRadioss (free explicit dynamics)', 'why': 'for collision, grounding, drop and impact',
                    'link': 'https://github.com/OpenRadioss/OpenRadioss/releases',
                    'steps': {'all': 'download the release for your system from the link and unzip it'},
                    'check': _have_exe('starter_linux64_gf', 'starter_win64.exe')},
}

ENGINE_KEYS = {'CalculiX': 'calculix', 'ShipBrain fatigue': 'calculix', 'ShipBrain AI surrogate': 'calculix', 'MYSTRAN': 'mystran',
               'OpenFOAM': 'openfoam', 'Elmer': 'elmer', 'Code_Aster': 'code_aster', 'OpenCourant': 'openradioss',
               'OpenPhysicsAI': 'cc', 'Awatif': 'wasmtime'}


def os_key():
    return 'windows' if WIN else ('mac' if MAC else 'linux')


def info(key):
    """the install block for one item (for this PC's system)"""
    s = SOFTWARE[key]
    steps = s['steps'].get(os_key()) or s['steps'].get('all') or next(iter(s['steps'].values()))
    out = {'key': key, 'name': s['name'], 'why': s['why'], 'link': s['link'], 'steps': steps}
    if s.get('then'):
        out['then'] = s['then']
    if s.get('other'):
        out['other'] = s['other']
    return out


def message(i):
    """plain English for the user, link included"""
    t = f"To do this, please install {i['name']} - it is needed {i['why']}. Download: {i['link']} . How: {i['steps']}."
    if i.get('then'):
        t += f" Then run once: {i['then']}."
    if i.get('other'):
        t += f" Other way: {i['other']}."
    return t + ' After installing, ask me again.'


def detect(error):
    """error text (or exception) -> install key, or None"""
    e = error if isinstance(error, str) else f'{type(error).__name__}: {error}'
    m = re.search(r"No module named '([\w.]+)'", e)
    if m:
        top = m.group(1).split('.')[0]
        if top == 'OCP':
            return 'cadquery'
        if top in ('langchain_openai', 'langchain_experimental', 'langchain_core', 'svglib', 'loguru', 'reportlab', 'rlPyCairo'):
            return 'langchain'
        for k, s in SOFTWARE.items():
            if s.get('module') == top:
                return k
        return 'pip:' + top
    for k, s in SOFTWARE.items():
        if s.get('match') and re.search(s['match'], e, re.I) and re.search(
                r'not found|needed|needs|install|No module|no such file|cannot find|could not find|is not recognized|not on this PC', e, re.I):
            return k
    return None


def explain(error):
    """error -> install block (dict with 'message') or None"""
    k = detect(error)
    if not k:
        return None
    if k.startswith('pip:'):
        pkg = k[4:]
        i = {'key': k, 'name': f'Python package {pkg}', 'why': 'for this tool', 'link': f'https://pypi.org/project/{pkg}/',
             'steps': f'pip install {pkg}'}
    else:
        i = info(k)
    i['message'] = message(i)
    return i


def attach(res):
    """add the install block to a tool result that failed because something is missing (in place; returns res)"""
    if isinstance(res, dict) and res.get('error') and 'install' not in res:
        i = explain(str(res['error']))
        if i:
            res['install'] = i
            res['plain_english'] = i['message']
    return res


def for_engine(engine_name):
    for frag, k in ENGINE_KEYS.items():
        if frag.lower() in engine_name.lower():
            return info(k)
    return None


def setup_check(only_missing=False):
    """everything ShipBrain can use, installed or not, with links"""
    rows = []
    for k, s in SOFTWARE.items():
        try:
            ok = bool(s['check']())
        except Exception:
            ok = False
        if only_missing and ok:
            continue
        rows.append(dict(info(k), installed=ok))
    miss = [r for r in rows if not r['installed']]
    pe = (f"{len(rows) - len(miss)} of {len(rows)} installed. " if not only_missing else '') + (
        'Missing (install only what you need): ' + '; '.join(f"{r['name']} - {r['why']} - {r['link']}" for r in miss)
        if miss else 'Everything is installed.')
    return {'software': rows, 'missing': len(miss), 'plain_english': pe}


if __name__ == '__main__':
    for r in setup_check()['software']:
        print(('[ok]      ' if r['installed'] else '[missing] ') + f"{r['name']:45s} {r['link']}")
