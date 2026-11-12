"""
Intake of any file the user uploads in the chat window: recognise the format, read what can be read (own readers, meshio, python-pptx / docx / openpyxl, CalculiX .frd,
OpenFOAM / Elmer case folders in a zip), turn foreign mesh formats into a ShipBrain mesh (.inp) so every mesh tool works on them, and say plainly what ShipBrain
cannot read (closed binary result formats of commercial solvers) and what to export instead. Nothing here fails on an unknown file: it is described, not refused.

    describe(path, workdir)  -> {'kind', 'format', 'readable', 'plain_english', ... details}
"""
import csv, io, os, re, struct, tarfile, zipfile

import numpy as np

# ext -> (category, what it is, how ShipBrain handles it)
FORMATS = {
    '.stl': ('cad mesh', 'STL triangle surface', 'read: size, closed?, volume; reverse_cad / stl_to_step turn it into a solid'),
    '.obj': ('cad mesh', 'Wavefront OBJ surface', 'read through meshio'), '.ply': ('cad mesh', 'PLY surface', 'read through meshio'),
    '.off': ('cad mesh', 'OFF surface', 'read through meshio'),
    '.msh': ('mesh', 'mesh file (Gmsh .msh format - read as a file format only, gmsh the program is never used)', 'read through meshio, converted to .inp'),
    '.vtk': ('mesh/result', 'VTK legacy mesh or result', 'read through meshio'), '.vtu': ('mesh/result', 'VTK unstructured grid (ParaView, Elmer, OpenFOAM)', 'read through meshio'),
    '.vtp': ('mesh/result', 'VTK polydata', 'read through meshio'), '.unv': ('mesh', 'I-DEAS / Salome UNV mesh', 'read through meshio, converted to .inp'),
    '.med': ('mesh/result', 'MED mesh / result (Salome, Code_Aster)', 'read through meshio (needs h5py)'), '.cgns': ('mesh/result', 'CGNS mesh / result', 'read through meshio (needs h5py)'),
    '.xdmf': ('mesh/result', 'XDMF mesh / result', 'read through meshio'), '.e': ('mesh/result', 'Exodus II (MOOSE, Cubit)', 'read through meshio (needs netCDF4)'),
    '.exo': ('mesh/result', 'Exodus II (MOOSE, Cubit)', 'read through meshio (needs netCDF4)'), '.cdb': ('mesh', 'ANSYS APDL mesh', 'read through meshio'),
    '.mesh': ('mesh', 'MEDIT mesh', 'read through meshio'), '.neu': ('mesh', 'Gambit neutral mesh', 'read through meshio'),
    '.bdf': ('mesh/deck', 'Nastran bulk data', 'read: FE model summary and checks'), '.nas': ('mesh/deck', 'Nastran bulk data', 'read: FE model summary and checks'),
    '.fem': ('mesh/deck', 'Nastran / OptiStruct / MYSTRAN model', 'read: FE model summary and checks'),
    '.inp': ('mesh/deck', 'CalculiX / Abaqus input deck', 'read: FE model summary and checks'),
    '.frd': ('result', 'CalculiX result file', 'read: nodes, displacement and stress maxima; show_result / probe_result use it'),
    '.dat': ('result/deck', 'CalculiX results table or Nastran deck', 'read as a deck or text'),
    '.f06': ('result', 'Nastran printed results', 'text: searched for maxima'), '.op2': ('result', 'Nastran binary results (OP2)', 'cannot read directly: export CSV / .vtu from your post-processor, or install pyNastran'),
    '.rst': ('result', 'ANSYS binary results', 'cannot read directly: export CSV / .vtu / .cdb from ANSYS'), '.rth': ('result', 'ANSYS thermal results', 'cannot read directly: export CSV'),
    '.odb': ('result', 'Abaqus results database', 'cannot read directly: export CSV / .vtu / .frd from Abaqus'), '.h3d': ('result', 'Altair HyperView results', 'cannot read directly: export CSV / .vtu'),
    '.d3plot': ('result', 'LS-DYNA results', 'cannot read directly: export CSV / .vtu'), '.k': ('deck', 'LS-DYNA keyword deck', 'recognised: text'),
    '.key': ('deck', 'LS-DYNA keyword deck', 'recognised: text'), '.sif': ('deck', 'Elmer solver input', 'recognised; needs its mesh folder (upload a .zip with it); elmer_flow writes its own'),
    '.i': ('deck', 'MOOSE input', 'moose_run runs it (needs MOOSE)'), '.comm': ('deck', 'Code_Aster command file', 'recognised: text; Code_Aster must be installed to run it'),
    '.fdb': ('deck', 'ANSYS Workbench / Mechanical database', 'cannot read: export the mesh as .cdb or .bdf'), '.cas': ('mesh/deck', 'Fluent case', 'recognised; export a .msh / .vtu to use it'),
    '.foam': ('case', 'OpenFOAM case marker', 'upload the case folder as a .zip'), '.ocx': ('model', 'OCX ship structure model', 'read: ocx_read, ocx_validate, ocx_to_step'),
    '.3docx': ('model', 'OCX ship structure model', 'read: ocx_read, ocx_validate, ocx_to_step'),
    '.pptx': ('document', 'PowerPoint presentation', 'read: slide titles, text, tables, pictures'), '.docx': ('document', 'Word document', 'read: headings, paragraphs, tables'),
    '.xlsx': ('document', 'Excel workbook', 'read: sheets, sizes, header rows'), '.xlsm': ('document', 'Excel workbook', 'read: sheets, sizes, header rows'),
    '.csv': ('table', 'comma-separated table', 'read: columns and size'), '.tsv': ('table', 'tab-separated table', 'read: columns and size'),
    '.txt': ('text', 'text file', 'read'), '.md': ('text', 'text file', 'read'), '.json': ('data', 'JSON', 'read'),
    '.zip': ('archive', 'zip archive', 'listed; an OpenFOAM or Elmer case inside is recognised and unpacked'), '.gz': ('archive', 'gzip file', 'listed'),
    '.tar': ('archive', 'tar archive', 'listed'), '.tgz': ('archive', 'tar.gz archive', 'listed; a case inside is recognised and unpacked'),
    '.ppt': ('document', 'old PowerPoint (binary)', 'needs LibreOffice to convert to .pptx'), '.doc': ('document', 'old Word (binary)', 'needs LibreOffice to convert to .docx'),
    '.xls': ('document', 'old Excel (binary)', 'read with pandas / xlrd if installed, else save as .xlsx'),
}
CASE_MARKERS = {'openfoam': ('system/controlDict', 'constant/polyMesh'), 'elmer': ('mesh.header',)}


def _size(n):
    for u in ('bytes', 'KB', 'MB', 'GB'):
        if n < 1024 or u == 'GB':
            return f'{n:.0f} {u}' if u == 'bytes' else f'{n:.1f} {u}'
        n /= 1024


# ------------------------------------------------------------------ readers
def read_stl(path):
    data = open(path, 'rb').read()
    if data[:5] == b'solid' and b'facet' in data[:600]:
        V = np.array([[float(x) for x in l.split()[1:4]] for l in data.decode('ascii', 'replace').splitlines() if l.strip().startswith('vertex')]).reshape(-1, 3, 3)
    else:
        n = struct.unpack('<I', data[80:84])[0]
        rec = np.frombuffer(data[84:84 + 50 * n], dtype=np.dtype([('n', '<f4', 3), ('v', '<f4', (3, 3)), ('a', '<u2')]))
        V = rec['v'].astype(float)
    return V


def describe_stl(path):
    V = read_stl(path)
    lo, hi = V.reshape(-1, 3).min(0), V.reshape(-1, 3).max(0)
    vol = float(np.einsum('ij,ij->i', V[:, 0], np.cross(V[:, 1], V[:, 2])).sum() / 6)
    key = np.round(V.reshape(-1, 3), 5)
    pts, inv = np.unique(key, axis=0, return_inverse=True)
    F = np.asarray(inv).reshape(-1, 3)
    edges = np.sort(np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]]), axis=1)
    _, cnt = np.unique(edges, axis=0, return_counts=True)
    closed = bool(np.all(cnt == 2))
    return {'triangles': int(len(V)), 'points': int(len(pts)), 'size': [round(float(x), 3) for x in hi - lo], 'closed': closed, 'volume': round(abs(vol), 3) if closed else None}, (
        f"STL surface with {len(V):,} triangles, {hi[0] - lo[0]:.4g} x {hi[1] - lo[1]:.4g} x {hi[2] - lo[2]:.4g} (file units). "
        + (f"It is a closed surface enclosing {abs(vol):,.4g} cubic units." if closed else 'It is NOT watertight (open edges), so it has no volume yet.')
        + ' reverse_cad / stl_to_step can turn it into a STEP solid.')


def describe_meshio(path, workdir):
    import meshio
    m = meshio.read(path)
    cells = {c.type: len(c.data) for c in m.cells}
    pts = np.asarray(m.points)
    pts3 = np.pad(pts, ((0, 0), (0, 3 - pts.shape[1]))) if pts.shape[1] < 3 else pts
    lo, hi = pts3.min(0), pts3.max(0)
    fields = list(m.point_data) + list(m.cell_data)
    info = {'points': int(len(pts)), 'cells': cells, 'bbox_min': lo.round(4).tolist(), 'bbox_max': hi.round(4).tolist(), 'fields': fields}
    say = (f"Mesh with {len(pts):,} points and cells " + ', '.join(f'{n:,} {t}' for t, n in cells.items()) + f", spanning {hi[0] - lo[0]:.4g} x {hi[1] - lo[1]:.4g} x {hi[2] - lo[2]:.4g}."
           + (f" It carries result fields: {', '.join(fields[:12])}." if fields else ''))
    out = convert_to_inp(m, os.path.join(workdir, os.path.splitext(os.path.basename(path))[0] + '_converted.inp'))
    if out:
        info['inp'] = os.path.basename(out)
        say += f" I converted it to {info['inp']} so the mesh checks, analysis and picture tools work on it (units unchanged)."
    return info, say


def convert_to_inp(m, out):
    """a meshio mesh -> ShipBrain / CalculiX .inp (shells for surface cells, solids for volume cells); None if there is nothing to convert"""
    from .femodel import FEModel
    kind = {'triangle': 'tria', 'quad': 'quad', 'tetra': 'tetra', 'hexahedron': 'hexa', 'wedge': 'penta', 'line': 'bar'}
    f = FEModel()
    f.name = os.path.splitext(os.path.basename(out))[0]
    pts = np.asarray(m.points)
    ids = [f.add_node(list(p) + [0.0] * (3 - len(p))) for p in pts]
    f.props[1] = {'kind': 'shell', 'mid': 1, 'name': 'P1', 't': 10.0}
    f.props[2] = {'kind': 'solid', 'mid': 1, 'name': 'S1'}
    f.mats[1] = {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9, 'name': 'STEEL'}
    n = 0
    vol = any(c.type in ('tetra', 'hexahedron', 'wedge') for c in m.cells)
    for c in m.cells:
        t = kind.get(c.type)
        if not t or (vol and t in ('tria', 'quad')):
            continue
        for row in c.data:
            f.add_elem(t, [ids[i] for i in row], 2 if t in ('tetra', 'hexa', 'penta') else 1, 'S1' if t in ('tetra', 'hexa', 'penta') else 'P1')
            n += 1
    if not n:
        return None
    f.write(out)
    return out


def describe_frd(path):
    from .solver import read_frd_full, read_frd
    xyz, S, U = read_frd_full(path)
    r = read_frd(path)
    info = {'nodes': len(xyz), 'has_displacement': bool(U), 'has_stress': bool(S), **{k: v for k, v in r.items() if k.startswith('max_')}}
    say = (f"CalculiX result file with {len(xyz):,} nodes. " + (f"Largest displacement {r['max_displacement_mm']} mm. " if 'max_displacement_mm' in r else '')
           + (f"Largest von Mises stress {r['max_von_mises_MPa']} MPa. " if 'max_von_mises_MPa' in r else '') + 'Upload the .inp it came from too, then show_result gives pictures and probe_result the value at any place.')
    return info, say


def describe_pptx(path):
    from pptx import Presentation
    p = Presentation(path)
    slides = []
    for i, s in enumerate(p.slides, 1):
        title = s.shapes.title.text if s.shapes.title is not None and s.shapes.title.has_text_frame else ''
        text = ' '.join(sh.text_frame.text.strip() for sh in s.shapes if sh.has_text_frame and sh.text_frame.text.strip())
        slides.append({'n': i, 'title': title, 'text': text[:300], 'tables': sum(1 for sh in s.shapes if sh.has_table), 'pictures': sum(1 for sh in s.shapes if sh.shape_type == 13)})
    say = f"PowerPoint with {len(slides)} slides. " + ' '.join(f"Slide {s['n']}: {s['title'] or s['text'][:60]}." for s in slides[:8])
    return {'slides': slides[:60]}, say + (' (more slides not listed)' if len(slides) > 8 else '') + ' Ask me about any slide; pictures of drawings or results on slides can be looked at.'


def describe_docx(path):
    import docx
    d = docx.Document(path)
    heads = [p.text for p in d.paragraphs if p.style.name.lower().startswith('heading') and p.text.strip()]
    words = sum(len(p.text.split()) for p in d.paragraphs)
    return {'paragraphs': len(d.paragraphs), 'tables': len(d.tables), 'headings': heads[:30], 'words': words}, (
        f"Word document of about {words:,} words with {len(d.tables)} table(s)." + (f" Headings: {'; '.join(heads[:8])}." if heads else ''))


def describe_xlsx(path):
    import openpyxl
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    sheets = []
    for ws in wb.worksheets:
        rows = list(ws.iter_rows(min_row=1, max_row=3, values_only=True))
        sheets.append({'name': ws.title, 'rows': ws.max_row, 'cols': ws.max_column, 'header': [str(c) for c in (rows[0] if rows else [])][:12]})
    return {'sheets': sheets}, 'Excel workbook: ' + '; '.join(f"sheet '{s['name']}' {s['rows']} x {s['cols']} (columns: {', '.join(s['header'][:6])})" for s in sheets[:6]) + '.'


def describe_csv(path):
    raw = open(path, encoding='utf-8', errors='replace').read(400000)
    dia = csv.Sniffer().sniff(raw[:4096], delimiters=',;\t') if raw else csv.excel
    rows = list(csv.reader(io.StringIO(raw), dia))
    head = rows[0] if rows else []
    return {'rows': len(rows), 'columns': head[:30]}, f"Table with {len(rows):,} rows and {len(head)} columns: {', '.join(head[:10])}."


def _case_kind(names):
    s = set(n.strip('/') for n in names)
    low = {n.lower() for n in s}
    if any(n.endswith('system/controldict') for n in low) and any('polymesh' in n for n in low):
        return 'OpenFOAM case'
    if any(n.endswith('mesh.header') for n in low) or any(n.endswith('.sif') for n in low) and any(n.endswith('mesh.nodes') for n in low):
        return 'Elmer case'
    if any(n.endswith('.inp') for n in low):
        return 'CalculiX / Abaqus input'
    return None


def describe_archive(path, workdir):
    base = re.sub(r'(\.tar\.gz|\.tgz|\.zip|\.tar|\.gz)$', '', os.path.basename(path), flags=re.I)
    if path.lower().endswith('.zip'):
        z = zipfile.ZipFile(path)
        names = z.namelist()
        opener = lambda dest: z.extractall(dest)
    else:
        t = tarfile.open(path)
        names = t.getnames()
        opener = lambda dest: t.extractall(dest, filter='data')
    kind = _case_kind(names)
    info = {'files': len(names), 'examples': names[:15], 'case': kind}
    say = f"Archive with {len(names)} files" + (f": it contains {'an' if kind[0] in 'AEIOU' else 'a'} {kind}." if kind else '.')
    if kind:
        dest = os.path.join(workdir, base)
        opener(dest)
        info['unpacked_to'] = base
        say += f" I unpacked it to the folder {base}."
        if kind == 'OpenFOAM case':
            say += ' probe_result reads values from a ShipBrain-made case; for yours, run it where OpenFOAM is installed and upload the result.'
    return info, say


def describe_text(path):
    txt = open(path, encoding='utf-8', errors='replace').read(200000)
    lines = txt.splitlines()
    return {'lines': len(lines), 'first_lines': lines[:6]}, f"Text file with {len(lines):,} lines."


def sniff_binary(path):
    head = open(path, 'rb').read(64)
    sig = {b'\x89HDF': 'HDF5 file (MED / CGNS / some result files)', b'PK\x03\x04': 'zip-based file', b'%PDF': 'PDF', b'\x89PNG': 'PNG image', b'\x7fELF': 'program (not opened)',
           b'MZ': 'Windows program (not opened)', b'\xd0\xcf\x11\xe0': 'old Microsoft Office file'}
    for k, v in sig.items():
        if head.startswith(k):
            return v
    return None


# ------------------------------------------------------------------ entry
def describe(path, workdir=None):
    """returns None when the format belongs to the main file_info (CAD, FE decks, DXF, PDF, images, OCX); else a dict"""
    workdir = workdir or os.path.dirname(os.path.abspath(path))
    name = os.path.basename(path)
    low = name.lower()
    ext = '.tar.gz' if low.endswith('.tar.gz') else os.path.splitext(low)[1]
    cat, what, how = FORMATS.get('.tgz' if ext == '.tar.gz' else ext, (None, None, None))
    size = os.path.getsize(path)
    out = {'file': name, 'size': _size(size), 'format': what or 'unknown', 'category': cat or 'unknown', 'handling': how or '', 'readable': True}
    try:
        if ext == '.stl':
            d, say = describe_stl(path)
        elif ext in ('.msh', '.vtk', '.vtu', '.vtp', '.unv', '.med', '.cgns', '.xdmf', '.e', '.exo', '.cdb', '.mesh', '.neu', '.obj', '.ply', '.off'):
            d, say = describe_meshio(path, workdir)
        elif ext == '.frd':
            d, say = describe_frd(path)
        elif ext == '.pptx':
            d, say = describe_pptx(path)
        elif ext == '.docx':
            d, say = describe_docx(path)
        elif ext in ('.xlsx', '.xlsm'):
            d, say = describe_xlsx(path)
        elif ext in ('.csv', '.tsv'):
            d, say = describe_csv(path)
        elif ext in ('.zip', '.tar', '.tgz', '.tar.gz'):
            d, say = describe_archive(path, workdir)
        elif ext in ('.op2', '.rst', '.rth', '.odb', '.h3d', '.d3plot', '.fdb'):
            d, say = {}, f"{what}: a closed binary format that ShipBrain cannot open. {how}."
            out['readable'] = False
        elif ext in ('.sif', '.i', '.comm', '.k', '.key', '.f06', '.cas', '.foam'):
            d, say = describe_text(path) if ext not in ('.cas', '.foam') else ({}, '')
            say = f"{what}. " + say
        elif ext in ('.ppt', '.doc', '.xls'):
            d, say = {}, f"{what}: {how}."
            out['readable'] = False
        else:
            kind = sniff_binary(path)
            if kind:
                d, say = {}, f"Not a format I know by its name; it looks like a {kind}."
                out['readable'] = False
            else:
                d, say = describe_text(path)
                say = 'Unknown file type, read as text. ' + say
                out['format'] = out['format'] if what else 'text'
    except Exception as e:
        d, say = {}, f"I recognised {what or 'the file'} but could not read it ({type(e).__name__}: {str(e)[:150]})."
        out['readable'] = False
    out.update(d)
    if how:
        say += f" [{how}]" if not say.endswith(']') else ''
    out['plain_english'] = f"{name} ({out['size']}): " + say
    return out
