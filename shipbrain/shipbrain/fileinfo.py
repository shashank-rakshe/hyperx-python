"""
file_info: describe any uploaded file in plain English (what it is, what is inside, anything that looks wrong).
FE models (.bdf/.dat/.nas/.inp), CAD (.step/.stp/.brep), drawings (.dxf/.pdf/.png/.jpg), data (.json/.xml/.csv/.txt/.md).
"""
import json, os
from collections import Counter


def _size(n):
    return f'{n / 1e6:.1f} MB' if n > 1e6 else f'{n / 1e3:.0f} kB'


def file_info(path):
    name, low = os.path.basename(path), path.lower()
    size = os.path.getsize(path)
    info, say = {'file': name, 'size': _size(size)}, []
    if low.endswith(('.bdf', '.dat', '.nas', '.inp', '.fem')):
        from .femodel import FEModel
        m = FEModel.read(path)
        s = m.summary()
        c = m.check()
        info.update(summary=s, check={k: c.get(k) for k in ('verdict', 'parts', 'free_nodes', 'duplicate_nodes', 'quality', 'inverted_solids') if k in c})
        dims = ', '.join(f"{v} {k}" for k, v in s['by_dimension'].items() if v)
        say.append(f"{name} is a finite element model with {s['nodes']} nodes and {s['elements']} elements ({dims} elements).")
        span = [round(b - a) for a, b in zip(s['bbox_min'], s['bbox_max'])]
        say.append(f"It spans {span[0]} x {span[1]} x {span[2]} (model units, usually mm) and uses {s['properties']} properties "
                   f"and {s['materials']} material(s); {s['constrained_nodes']} nodes are supported and there are {s['loads']} load set(s).")
        if c.get('verdict'):
            say.append('Mesh check: ' + ('no problems found.' if c['verdict'] == 'ok' else c['verdict'] + '.'))
        if c.get('all_elements_parts', 1) > 1:
            say.append(f"Warning: the model falls apart into {c['all_elements_parts']} unconnected pieces.")
    elif low.endswith(('.step', '.stp', '.brep')):
        from .cadplates import import_cad, shape_to_plates
        shp = import_cad(path)
        bb = shp.BoundingBox()
        plates, rep = shape_to_plates(shp)
        kinds = Counter(f.geomType() for f in shp.Faces())
        info.update(solids=len(shp.Solids()), faces=len(shp.Faces()), face_types=dict(kinds), bbox=[round(bb.xlen), round(bb.ylen), round(bb.zlen)],
                    plate_like=rep['solids_to_plates'] + rep['faces_to_plates'], not_meshable=rep['skipped'][:10], valid=shp.isValid())
        say.append(f"{name} is a 3D CAD model with {len(shp.Solids())} solid(s) and {len(shp.Faces())} faces, "
                   f"{round(bb.xlen)} x {round(bb.ylen)} x {round(bb.zlen)} mm.")
        say.append(f"{info['plate_like']} part(s) are flat plates that the shell mesher can use directly"
                   + (f"; {len(rep['skipped'])} part(s)/face(s) are not (curved or thick)." if rep['skipped'] else '.'))
        if not info['valid']:
            say.append('The geometry is not valid: run the cleaning step before meshing.')
    elif low.endswith('.3dm') and __import__('importlib.util').util.find_spec('rhino3dm'):
        from . import rhino
        r = rhino.to_step(path, os.path.splitext(path)[0] + '_rhino.step')
        info.update(native='Rhino model', step=os.path.basename(r['file']), units=r['units'], size_mm=r['size_mm'],
                    objects=r['objects'][:30])
        say.append(r['plain_english'])
    elif __import__('shipbrain.cadmpeg', fromlist=['x']).is_native(path):
        from . import cadmpeg
        r = cadmpeg.to_step(path, os.path.splitext(path)[0] + '_cadmpeg.step')
        info.update(native=cadmpeg.NATIVE[os.path.splitext(low)[1]], step=os.path.basename(r['file']),
                    geometry_transferred=r['geometry_transferred'])
        say.append(r['plain_english'])
        if r['geometry_transferred'] is not False:
            sub = file_info(r['file'])
            info['cad'] = {k: sub.get(k) for k in ('solids', 'faces', 'face_types', 'bbox', 'valid')}
            say.append(sub['plain_english'].replace(os.path.basename(r['file']), 'The model'))
    elif low.endswith('.dxf'):
        import ezdxf
        doc = ezdxf.readfile(path)
        ents = Counter((e.dxf.layer, e.dxftype()) for e in doc.modelspace())
        layers = Counter()
        for (lay, _), n in ents.items():
            layers[lay] += n
        texts = [e.dxf.text for e in doc.modelspace() if e.dxftype() == 'TEXT'][:10]
        info.update(layers=dict(layers.most_common(30)), entity_types=dict(Counter(t for (_, t) in ents.elements())), sample_texts=texts)
        say.append(f"{name} is a CAD drawing (DXF) with {sum(layers.values())} drawn items on {len(layers)} layer(s): "
                   + ', '.join(f'{k} ({v})' for k, v in layers.most_common(8)) + '.')
        say.append('It can be compared with another drawing, or turned into a 3D plate model if its layers name the members '
                   '(outline, openings, girders/webs, stiffeners).')
    elif low.endswith('.pdf'):
        import pypdfium2
        pdf = pypdfium2.PdfDocument(path)
        n = len(pdf)
        txt = ' '.join(pdf[0].get_textpage().get_text_range().split())[:400]
        w, h = pdf[0].get_size()
        pdf.close()
        info.update(pages=n, first_page_text=txt, page_size_mm=[round(w * 25.4 / 72), round(h * 25.4 / 72)])
        say.append(f"{name} is a PDF with {n} page(s); page 1 is {info['page_size_mm'][0]} x {info['page_size_mm'][1]} mm.")
        say.append('It has a text layer.' if txt else 'It has no text layer (probably a scan): numbers must be read from the image.')
    elif low.endswith(('.png', '.jpg', '.jpeg', '.tif', '.tiff', '.bmp')):
        from PIL import Image
        im = Image.open(path)
        info.update(pixels=list(im.size), mode=im.mode)
        say.append(f"{name} is an image of {im.size[0]} x {im.size[1]} pixels. It can be compared with another drawing or with an FE mesh "
                   'if you tell me which ship coordinates (mm) it shows.')
    elif low.endswith('.json'):
        d = json.load(open(path, encoding='utf-8'))
        if isinstance(d, list):
            keys = Counter(k for x in d[:500] if isinstance(x, dict) for k in x)
            info.update(kind='list', items=len(d), common_keys=dict(keys.most_common(10)))
            say.append(f"{name} is a JSON list of {len(d)} items" + (f" with fields {', '.join(k for k, _ in keys.most_common(6))}." if keys else '.'))
        else:
            info.update(kind='object', keys=list(d)[:30])
            say.append(f"{name} is a JSON object with the fields {', '.join(list(d)[:10])}.")
        if isinstance(d, dict) and 'plates' in d:
            say.append(f"It looks like a plate-assembly spec with {len(d['plates'])} plates: it can be meshed directly.")
    elif low.endswith(('.3docx', '.ocx')) or (low.endswith('.xml') and b'ocxXML' in open(path, 'rb').read(3000)):
        from . import ocx
        r = ocx.read(path)
        info.update(kind='OCX ship structure model', **{k: v for k, v in r['summary'].items() if k in (
            'schema_version', 'panels', 'plates', 'stiffeners', 'brackets', 'pillars', 'seams', 'holes', 'thickness_mm', 'plate_area_m2')})
        say.append(f"{name} ({_size(size)}) is an OCX ship structure model (open 3D class exchange standard). " + r['plain_english']
                   + ' I can check it against its schema (ocx_validate), compare it with another model (compare_structures), '
                     'mesh it (structure_to_mesh) or make STEP (ocx_to_step).')
    elif low.endswith('.xml'):
        import xml.etree.ElementTree as ET
        tags, root = Counter(), None
        for ev, el in ET.iterparse(path, events=('start',)):
            root = root or el.tag
            tags[el.tag] += 1
        info.update(root=root, elements=sum(tags.values()), common_tags=dict(tags.most_common(15)))
        say.append(f"{name} is an XML file ({_size(size)}) with {sum(tags.values())} elements under <{root}>; the most common are "
                   + ', '.join(f'<{k}> x{v}' for k, v in tags.most_common(6)) + '.')
    else:
        from . import intake
        r = intake.describe(path, os.path.dirname(os.path.abspath(path)))
        info.update({k: v for k, v in r.items() if k not in ('plain_english', 'file', 'size')})
        say.append(r['plain_english'].split('): ', 1)[-1])
    info['plain_english'] = ' '.join(say)
    return info
