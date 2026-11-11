"""
OCX (Open Class 3D Exchange, *.3docx) - the open XML standard for ship structure models.

Uses, as written (copied whole into shipbrain/vendor):
  OCX_Schema  (https://github.com/OCXStandard/OCX_Schema, Apache-2.0): the official schema of every version 2.8.6 ... 3.2.0
              as XSD and as Python classes (xsdata bindings) - all the library syntax: every element, type, attribute,
              child, enumeration and its documentation.
  OCXReader   (https://github.com/skfcz/OCXReader, LGPL-2.1): C++ / OpenCascade reader that turns an OCX file into
              STEP. Built and run as its own program, unchanged (see ocx_reader_build / to_step).

What ShipBrain does with them:
  versions()                     the schema versions it knows (all 12)
  syntax(name, version)          one element / type: what it is, attributes (required?), children in order with how many,
                                 enumeration values, where it is used, which versions have it, and an XML example
  find(query, version)           search the library by name or meaning ("thickness", "bulb", "watertight")
  changes(a, b)                  what changed between two schema versions
  new(name, version, **values)   an OCX object of any class, required parts filled (the Python class of that version)
  read(path)                     an OCX file (any version) -> summary + ShipBrain structure model (compare / mesh / STEP)
  write(model, path)             ShipBrain structure model -> OCX 3.2.0 file (built with the official classes)
  validate(path)                 against the official XSD of its version (when that version ships its XSD) + a check
                                 of every element against the library
Lengths inside ShipBrain are mm.
"""
import dataclasses, datetime, enum, glob, importlib.util, json, math, os, re, sys, typing, uuid
import xml.etree.ElementTree as ET

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_ROOT = os.path.join(HERE, 'vendor', 'OCX_Schema', 'repo')
READER_ROOT = os.path.join(HERE, 'vendor', 'OCXReader', 'repo')
CACHE = os.path.join(os.path.expanduser('~'), '.cache', 'shipbrain', 'ocx')
UNITSML_NS = 'urn:oasis:names:tc:unitsml:schema:xsd:UnitsMLSchema_lite-0.9.18'
LATEST = '3.2.0'
_MODS, _CATS = {}, {}


# ====================================================================== versions and the Python classes
def _tag(v):
    """'3.2.0rc6' <-> 'ocx_320rc6'"""
    m = re.match(r'(\d)\.(\d)\.(\d)(.*)$', v)
    return f'ocx_{m.group(1)}{m.group(2)}{m.group(3)}{m.group(4)}' if m else v


def _ver(tag):
    m = re.match(r'ocx_(\d)(\d)(\d)(.*)$', tag)
    return f'{m.group(1)}.{m.group(2)}.{m.group(3)}{m.group(4)}'


def _vkey(v):
    m = re.match(r'(\d+)\.(\d+)\.(\d+)(?:rc(\d+))?', v)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)) if m.group(4) else 99) if m else (0,)


def versions():
    """schema versions with Python classes, oldest first (release candidates before their release)"""
    tags = [os.path.basename(d) for d in glob.glob(os.path.join(SCHEMA_ROOT, 'ocx', 'ocx_*')) if os.path.isdir(d)]
    return sorted((_ver(t) for t in tags), key=_vkey)


def _resolve(version):
    vs = versions()
    if not vs:
        raise RuntimeError('the OCX schema is not in shipbrain/vendor/OCX_Schema')
    if not version or version == 'latest':
        return LATEST if LATEST in vs else vs[-1]
    v = str(version).strip().lstrip('vV')
    if re.fullmatch(r'\d{3}(rc\d+)?', v):
        v = f'{v[0]}.{v[1]}.{v[2:]}'
    if v in vs:
        return v
    near = [x for x in vs if x.startswith(v)] or [x for x in vs if _vkey(x)[:2] == _vkey(v + '.0' if v.count('.') == 1 else v)[:2]]
    if near:
        return sorted(near, key=_vkey)[-1]
    older = [x for x in vs if _vkey(x) <= _vkey(v)]
    return (older or vs)[-1]


def module(version=None):
    """the official Python classes (xsdata bindings) of one schema version"""
    v = _resolve(version)
    if v not in _MODS:
        try:
            import xsdata  # noqa: F401
        except ImportError:
            raise ModuleNotFoundError("No module named 'xsdata'")
        t = _tag(v)
        p = os.path.join(SCHEMA_ROOT, 'ocx', t, t + '.py')
        name = 'shipbrain_ocx_' + t
        spec = importlib.util.spec_from_file_location(name, p)
        m = importlib.util.module_from_spec(spec)
        sys.modules[name] = m
        spec.loader.exec_module(m)
        _MODS[v] = m
    return _MODS[v]


def namespace(version=None):
    m = module(version)
    return getattr(m.OcxXml.Meta, 'namespace', None) or _first_ns(m)


def _first_ns(m):
    for c in vars(m).values():
        ns = getattr(getattr(c, 'Meta', None), 'namespace', None) or getattr(getattr(c, 'Meta', None), 'target_namespace', None)
        if ns and '3docx' in ns:
            return ns
    return ''


# ====================================================================== the library (catalogue of all syntax)
def _xml_name(c):
    meta = c.__dict__.get('Meta')
    return getattr(meta, 'name', None) if meta is not None and 'name' in vars(meta) else c.__name__


def _field_docs(c):
    doc = c.__doc__ or ''
    head = doc.split('Attributes:')[0].strip()
    out = {}
    if 'Attributes:' in doc:
        cur = None
        for line in doc.split('Attributes:', 1)[1].splitlines():
            m = re.match(r'\s{4}(\w+):\s*(.*)$', line)
            if m:
                cur = m.group(1)
                out[cur] = m.group(2).strip()
            elif cur and line.strip():
                out[cur] += ' ' + line.strip()
    for k in out:
        out[k] = re.sub(r'\s+', ' ', out[k]).strip()
    return re.sub(r'\s+', ' ', head), out


def _inner(tp):
    """typing annotation -> (python class or primitive, is_list)"""
    is_list = False
    args = typing.get_args(tp)
    origin = typing.get_origin(tp)
    if origin in (list, typing.List):
        is_list, tp = True, args[0]
        args, origin = typing.get_args(tp), typing.get_origin(tp)
    if args and type(None) in args:
        rest = [a for a in args if a is not type(None)]
        tp = rest[0] if len(rest) == 1 else tp
        if typing.get_origin(tp) in (list, typing.List):
            is_list, tp = True, typing.get_args(tp)[0]
    return tp, is_list


def _plain(x):
    """enum value / QName '{namespace}Panel' -> 'ocx:Panel'"""
    x = getattr(x, 'value', x)
    x = getattr(x, 'text', x)
    x = str(x)
    m_ = re.match(r'\{([^}]*)\}(.+)$', x)
    return (('ocx:' if '3docx' in m_.group(1) else '') + m_.group(2)) if m_ else x


def _tname(tp):
    if isinstance(tp, type):
        if issubclass(tp, enum.Enum):
            return tp.__name__
        return {str: 'string', float: 'double', int: 'integer', bool: 'boolean'}.get(tp, _xml_name(tp) if dataclasses.is_dataclass(tp) else tp.__name__)
    return str(tp)


def catalogue(version=None):
    """{xml name: entry} for every element, type and enumeration of one version (cached on disk)"""
    v = _resolve(version)
    if v in _CATS:
        return _CATS[v]
    cp = os.path.join(CACHE, f'catalogue_{_tag(v)}.json')
    src = os.path.join(SCHEMA_ROOT, 'ocx', _tag(v), _tag(v) + '.py')
    if os.path.exists(cp) and os.path.getmtime(cp) >= os.path.getmtime(src):
        try:
            _CATS[v] = json.load(open(cp, encoding='utf-8'))
            return _CATS[v]
        except ValueError:
            pass
    m = module(v)
    cat = {}
    for c in vars(m).values():
        if not isinstance(c, type) or c.__module__ != m.__name__:
            continue
        if issubclass(c, enum.Enum):
            cat.setdefault(c.__name__, {'name': c.__name__, 'kind': 'enumeration', 'class': c.__name__,
                                        'doc': re.sub(r'\s+', ' ', (c.__doc__ or '').split('Attributes:')[0]).strip(),
                                        'values': [_plain(e) for e in c]})
            continue
        if not dataclasses.is_dataclass(c):
            continue
        name = _xml_name(c)
        head, fdocs = _field_docs(c)
        try:
            hints = typing.get_type_hints(c, globalns=vars(m))
        except Exception:
            hints = {}
        attrs, kids = [], []
        for f in dataclasses.fields(c):
            md = dict(f.metadata)
            req = f.default is dataclasses.MISSING and f.default_factory is dataclasses.MISSING
            tp, is_list = _inner(hints.get(f.name, f.type))
            if md.get('type') == 'Attribute':
                a = {'name': md.get('name') or f.name, 'type': _tname(tp), 'required': bool(req or md.get('required')),
                     'doc': fdocs.get(f.name, '')}
                if '3docx' in str(md.get('namespace', '')):
                    a['prefix'] = 'ocx'
                if isinstance(tp, type) and issubclass(tp, enum.Enum):
                    a['values'] = [_plain(e) for e in tp]
                if md.get('pattern'):
                    a['pattern'] = md['pattern']
                if f.default is not dataclasses.MISSING and f.default is not None:
                    dv = f.default
                    a['default'] = dv if isinstance(dv, (int, float, bool)) else _plain(dv)
                attrs.append(a)
            elif md.get('type') == 'Elements':
                for ch in md.get('choices', ()):
                    kids.append({'name': ch.get('name'), 'type': _tname(ch.get('type')), 'min': 0,
                                 'max': 'unbounded', 'choice': True, 'doc': ''})
            elif md.get('type') in ('Element', None) and not (md.get('type') is None and f.name == 'value'):
                lo = md.get('min_occurs', 1 if req else 0)
                hi = md.get('max_occurs', 'unbounded' if is_list else 1)
                kids.append({'name': md.get('name') or f.name, 'type': _tname(tp), 'min': lo, 'max': hi,
                             'doc': fdocs.get(f.name, ''), **({'namespace': 'unitsml'} if 'unitsml' in str(md.get('namespace', '')) else {})})
            elif f.name == 'value':
                attrs.append({'name': '(text)', 'type': _tname(tp), 'required': req, 'doc': 'element text'})
        base = next((_xml_name(b) for b in c.__mro__[1:] if dataclasses.is_dataclass(b)), None)
        kind = 'type' if name.endswith('_T') or name.lower().endswith('type') else 'element'
        entry = {'name': name, 'kind': kind, 'class': c.__name__, 'doc': head, 'base': base, 'attributes': attrs, 'children': kids,
                 'abstract': 'abstract' in head.lower()[:60]}
        if name in cat and cat[name]['kind'] == 'element' and kind == 'element':
            continue
        cat[name] = entry
    for e in cat.values():                                    # element -> its type's documentation when it has none
        if e['kind'] == 'element' and not e['doc'] and e.get('base') in cat:
            e['doc'] = cat[e['base']]['doc']
    used = {}
    for e in cat.values():
        for k in e.get('children', []):
            used.setdefault(k['name'], []).append(e['name'])
    for n, e in cat.items():
        e['used_in'] = sorted({p for p in used.get(n, []) if not p.endswith('_T')})[:25]
        for k in e.get('children', []):
            if not k['doc'] and k['name'] in cat:
                k['doc'] = cat[k['name']]['doc'][:200]
    os.makedirs(CACHE, exist_ok=True)
    with open(cp + '.tmp', 'w', encoding='utf-8') as fh:
        json.dump(cat, fh, default=str)
    os.replace(cp + '.tmp', cp)
    _CATS[v] = cat
    return cat


def _lookup(cat, name):
    if name in cat:
        return cat[name]
    low = {k.lower(): k for k in cat}
    for cand in (name, name + '_T', name.replace('ocx:', '')):
        if cand.lower() in low:
            return cat[low[cand.lower()]]
    by_class = {e['class'].lower(): e for e in cat.values()}
    return by_class.get(name.lower())


def find(query, version=None, limit=15):
    """names and short meaning of the classes that match (name first, then documentation)"""
    cat = catalogue(version)
    q = query.lower().replace('ocx:', '').strip()
    words = [w for w in re.split(r'\W+', q) if w]
    scored = []
    for n, e in cat.items():
        ln = n.lower()
        s = 0
        if ln == q or ln == q + '_t':
            s = 100
        elif q and q in ln:
            s = 50 - len(ln) / 10
        else:
            text = (n + ' ' + e.get('doc', '') + ' ' + ' '.join(a['name'] for a in e.get('attributes', []))
                    + ' ' + ' '.join(map(str, e.get('values', [])))).lower()
            hit = sum(w in text for w in words)
            s = (10 * hit / max(1, len(words)) + 3 * sum(w in ln for w in words)) if hit else 0
        if s and not (e['kind'] == 'type' and n[:-2] in cat):     # show the element, not its _T twin
            scored.append((s, n))
    scored.sort(key=lambda x: (-x[0], x[1]))
    return [{'name': n, 'kind': cat[n]['kind'], 'doc': cat[n].get('doc', '')[:160]} for _, n in scored[:limit]]


def _occ(k):
    lo, hi = k['min'], k['max']
    if hi == 'unbounded':
        return f'{lo}..n'
    return f'{lo}' if lo == hi else f'{lo}..{hi}'


def example_xml(name, version=None, depth=3, _lvl=0, _seen=None):
    """an XML example of one element with its required attributes and children"""
    cat = catalogue(version)
    e = _lookup(cat, name)
    if not e:
        raise ValueError(f'{name} is not in OCX {_resolve(version)}')
    if e['kind'] == 'type':
        el = next((x for x in cat.values() if x['kind'] == 'element' and x.get('base') == e['name']), None)
        e = el or e
    ind = '  ' * _lvl
    tagname = ('unitsml:' if e['name'] in ('UnitsML',) else 'ocx:') + e['name']
    if e['kind'] == 'enumeration':
        return f"{ind}<!-- one of: {', '.join(map(str, e['values'][:12]))} -->"
    attrs = []
    for a in e.get('attributes', []):
        if not a['required'] or a['name'] == '(text)':
            continue
        n = a['name']
        if a.get('values'):
            val = a.get('default') or a['values'][0]
        elif n.lower() == 'guidref':
            val = '00000000-0000-0000-0000-000000000000'
        elif n == 'id':
            val = 'id1'
        elif n == 'unit':
            val = 'Um' if re.search(r'(?i)thick|height|width|length|radius|distance|position|location|gravity|offset|diameter|point|origin',
                                    e['name'] + ' ' + e.get('doc', '')) else 'U...'
        elif a['type'] in ('double', 'integer'):
            val = '0'
        elif n == 'coordinates':
            val = '0 0 0'
        else:
            val = '...'
        attrs.append(f'{"ocx:" if a.get("prefix") else ""}{n}="{val}"')
    if any(a['name'] == 'coordinates' for a in e.get('attributes', [])) and not any('coordinates' in x for x in attrs):
        attrs.insert(0, 'coordinates="0 0 0"')
    req = [k for k in e.get('children', []) if k['min'] and not k.get('choice')]
    head = f'{ind}<{tagname}' + ''.join(' ' + a for a in attrs)
    _seen = (_seen or set()) | {e['name']}
    if not req or _lvl >= depth:
        more = [k['name'] for k in e.get('children', []) if not k['min']]
        if more and not req and all(k['max'] == 'unbounded' for k in e['children']) and _lvl:
            return head + f'>  <!-- one or more of: {", ".join(more[:8])} --></{tagname}>'
        return head + '/>' + (f'  <!-- optional: {", ".join(more[:6])} -->' if more and _lvl == 0 else '')
    body = []
    for k in req:
        if k['name'] in _seen:
            body.append(f"{ind}  <ocx:{k['name']}>...</ocx:{k['name']}>")
            continue
        try:
            body.append(example_xml(k['name'], version, depth, _lvl + 1, _seen))
        except ValueError:
            body.append(f"{ind}  <ocx:{k['name']}/>")
    return head + '>\n' + '\n'.join(body) + f'\n{ind}</{tagname}>'


def syntax(name, version=None):
    """everything about one OCX element / type / enumeration in one version"""
    v = _resolve(version)
    cat = catalogue(v)
    e = _lookup(cat, name)
    if not e:
        hits = find(name, v, 8)
        return {'error': f'{name} is not an OCX {v} class', 'did_you_mean': [h['name'] for h in hits],
                'plain_english': f'OCX {v} has no {name}. Closest: ' + ', '.join(h['name'] for h in hits) + '.'}
    have = [x for x in versions() if _lookup(catalogue(x), e['name'])]
    out = {'version': v, **{k: e[k] for k in ('name', 'kind', 'doc') if k in e}}
    if e['kind'] == 'enumeration':
        out['values'] = e['values']
        pe = f"ocx:{e['name']} (OCX {v}) is a list of allowed values: {', '.join(map(str, e['values']))}."
    else:
        out['type'] = e.get('base') if e['kind'] == 'element' else e['name']
        out['attributes'] = e['attributes']
        out['children'] = [{**k, 'occurs': _occ(k)} for k in e['children']]
        out['used_in'] = e.get('used_in', [])
        out['example'] = example_xml(e['name'], v)
        ra = [a['name'] for a in e['attributes'] if a['required'] and a['name'] != '(text)']
        rc = [k['name'] for k in e['children'] if k['min']]
        oc = [k['name'] for k in e['children'] if not k['min']]
        pe = (f"ocx:{e['name']} (OCX {v}): {e.get('doc') or 'no description in the schema'} "
              f"Required attributes: {', '.join(ra) or 'none'}. Required children (in this order): {', '.join(rc) or 'none'}. "
              f"Optional children: {', '.join(oc[:15]) or 'none'}{' ...' if len(oc) > 15 else ''}."
              + (f" Used inside: {', '.join(out['used_in'][:10])}." if out['used_in'] else ''))
    out['versions'] = have
    if have and len(have) < len(versions()):
        pe += f" Present in OCX {', '.join(have)} only."
    out['plain_english'] = pe
    return out


def changes(a, b):
    """what changed in the library from version a to version b"""
    va, vb = _resolve(a), _resolve(b)
    A, B = catalogue(va), catalogue(vb)
    el = lambda C: {n for n, e in C.items() if e['kind'] != 'type'}
    added, removed = sorted(el(B) - el(A)), sorted(el(A) - el(B))
    changed = []
    for n in sorted(el(A) & el(B)):
        ea, eb = A[n], B[n]
        if ea['kind'] == 'enumeration':
            if ea['values'] != eb['values']:
                changed.append({'name': n, 'values_added': sorted(set(map(str, eb['values'])) - set(map(str, ea['values']))),
                                'values_removed': sorted(set(map(str, ea['values'])) - set(map(str, eb['values'])))})
            continue
        ta, tb = (A.get(ea.get('base')) or ea), (B.get(eb.get('base')) or eb)
        ka, kb = {k['name']: _occ(k) for k in ta['children']}, {k['name']: _occ(k) for k in tb['children']}
        aa, ab = {x['name']: x['required'] for x in ta['attributes']}, {x['name']: x['required'] for x in tb['attributes']}
        d = {}
        if set(kb) - set(ka):
            d['children_added'] = sorted(set(kb) - set(ka))
        if set(ka) - set(kb):
            d['children_removed'] = sorted(set(ka) - set(kb))
        occ = [f'{k} {ka[k]} -> {kb[k]}' for k in set(ka) & set(kb) if ka[k] != kb[k]]
        if occ:
            d['occurs_changed'] = sorted(occ)
        if set(ab) - set(aa):
            d['attributes_added'] = sorted(set(ab) - set(aa))
        if set(aa) - set(ab):
            d['attributes_removed'] = sorted(set(aa) - set(ab))
        req = [k for k in set(aa) & set(ab) if aa[k] != ab[k]]
        if req:
            d['now_required'] = sorted(k for k in req if ab[k])
        if d:
            changed.append({'name': n, **d})
    pe = (f'OCX {va} -> {vb}: {len(added)} element(s) added' + (f" ({', '.join(added[:12])}{' ...' if len(added) > 12 else ''})" if added else '')
          + f', {len(removed)} removed' + (f" ({', '.join(removed[:12])}{' ...' if len(removed) > 12 else ''})" if removed else '')
          + f', {len(changed)} changed' + (f" (e.g. {', '.join(c['name'] for c in changed[:10])})" if changed else '') + '.')
    return {'from': va, 'to': vb, 'added': added, 'removed': removed, 'changed': changed, 'plain_english': pe}


# ====================================================================== objects of any class
def _defaults(cls, m, ctx, depth):
    hints = typing.get_type_hints(cls, globalns=vars(m))
    kw = {}
    for f in dataclasses.fields(cls):
        if not f.init:
            continue
        md = dict(f.metadata)
        req = f.default is dataclasses.MISSING and f.default_factory is dataclasses.MISSING
        tp, is_list = _inner(hints.get(f.name, f.type))
        need_list = is_list and (md.get('min_occurs') or 0) >= 1
        if not (req or need_list):
            continue
        if md.get('type') == 'Elements':
            continue
        kw[f.name] = [_value(tp, f.name, m, ctx, depth)] if is_list else _value(tp, f.name, m, ctx, depth)
    return kw


def _value(tp, fname, m, ctx, depth):
    from xsdata.models.datatype import XmlDate, XmlDateTime
    if isinstance(tp, type) and dataclasses.is_dataclass(tp):
        if depth > 14:
            raise ValueError(f'{tp.__name__}: required parts nest too deep')
        return tp(**_defaults(tp, m, ctx, depth + 1))
    if isinstance(tp, type) and issubclass(tp, enum.Enum):
        return list(tp)[0]
    if tp is XmlDateTime:
        return XmlDateTime.from_datetime(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0))
    if tp is XmlDate:
        return XmlDate.today()
    if tp is float:
        return [0.0, 0.0, 0.0] if fname == 'coordinates' else 0.0
    if tp is int:
        return 0
    if tp is bool:
        return False
    if fname == 'guidref':
        return str(uuid.uuid4())
    if fname == 'id':
        ctx['n'] = ctx.get('n', 0) + 1
        return f"{ctx.get('prefix', 'id')}{ctx['n']}"
    if fname == 'unit':
        return 'Um'
    return ''


def new(cls_name, version=None, **values):
    """an object of any OCX class (by XML or class name), its required parts filled with neutral values
    (GUIDs, ids, zeros); values= override fields by their Python names"""
    m = module(version)
    e = _lookup(catalogue(version), cls_name)
    if not e:
        raise ValueError(f'{cls_name} is not an OCX class')
    cls = getattr(m, e['class'])
    kw = _defaults(cls, m, values.pop('_ctx', {}), 0)
    kw.update(values)
    return cls(**kw)


def to_xml(obj, version=None, path=None):
    from xsdata.formats.dataclass.serializers import XmlSerializer
    from xsdata.formats.dataclass.serializers.config import SerializerConfig
    try:
        cfg = SerializerConfig(indent='  ')
    except TypeError:
        cfg = SerializerConfig(pretty_print=True)
    s = XmlSerializer(config=cfg).render(obj, ns_map={'ocx': namespace(version), 'unitsml': UNITSML_NS})
    if path:
        open(path, 'w', encoding='utf-8').write(s)
    return s


def load(path, version=None):
    """the whole file as objects of the official classes of its version (every element, nothing dropped)"""
    from xsdata.formats.dataclass.parsers import XmlParser
    from xsdata.formats.dataclass.parsers.config import ParserConfig
    v = version or detect_version(path)['version']
    m = module(v)
    return XmlParser(config=ParserConfig(fail_on_unknown_properties=False)).parse(path, m.OcxXml)


# ====================================================================== version of a file, validation
def detect_version(path):
    head = open(path, 'rb').read(6000).decode('utf-8', 'ignore')
    sv = re.search(r'schemaVersion="([^"]+)"', head)
    ns = re.search(r'xmlns:ocx="([^"]+)"', head)
    v = sv.group(1) if sv else None
    if not v and ns:
        mm = re.search(r'V(\d)(\d)(\d)(rc\d+)?', ns.group(1))
        v = f'{mm.group(1)}.{mm.group(2)}.{mm.group(3)}{mm.group(4) or ""}' if mm else None
    return {'schema_version': v, 'namespace': ns.group(1) if ns else None, 'version': _resolve(v)}


def xsd_for(version):
    """local XSD file of a version, or None (some versions only ship their Python classes)"""
    v = _resolve(version)
    cands = [os.path.join(SCHEMA_ROOT, 'ocx', _tag(v), 'OCX_Schema.xsd')]
    if v == LATEST:
        cands.append(os.path.join(SCHEMA_ROOT, 'ocx', 'OCX_Schema.xsd'))
    if v.startswith('2.8'):
        cands += [os.path.join(SCHEMA_ROOT, 'schemas', v, 'OCX_Schema.xsd'), os.path.join(READER_ROOT, 'libs', 'ocx', 'OCXSchema.xsd')]
    return next((c for c in cands if os.path.exists(c)), None)


def _local(t):
    return t.rsplit('}', 1)[-1] if isinstance(t, str) else ''


def validate(path, max_errors=30):
    info = detect_version(path)
    v = info['version']
    errs, how = [], []
    xsd = xsd_for(v)
    xsd_ran = False
    if xsd:
        tns = re.search(r'targetNamespace="([^"]+)"', open(xsd, encoding='utf-8', errors='ignore').read(4000))
        if info['namespace'] and tns and tns.group(1) != info['namespace']:
            how.append(f"XSD check not possible: the file uses namespace {info['namespace']}, the bundled {v} XSD uses {tns.group(1)}")
            xsd = None
    if xsd:
        try:
            import xmlschema
            unitsml = next((c for c in (os.path.join(os.path.dirname(xsd), 'unitsmlSchema_lite-0.9.18.xsd'),
                                        os.path.join(SCHEMA_ROOT, 'ocx', 'unitsmlSchema_lite-0.9.18.xsd'),
                                        os.path.join(SCHEMA_ROOT, 'schemas', '2.8.6', 'unitsmlSchema_lite-0.9.18.xsd'))
                            if os.path.exists(c) and f'targetNamespace="{UNITSML_NS}"' in open(c, encoding='utf-8', errors='ignore').read(5000)), None)
            cls = xmlschema.XMLSchema11 if 'minVersion="1.1"' in open(xsd, encoding='utf-8', errors='ignore').read(3000) else xmlschema.XMLSchema
            sch = cls(xsd, locations=[(UNITSML_NS, unitsml)] if unitsml else None, allow='local', defuse='always')
            for er in sch.iter_errors(path):
                errs.append(re.sub(r'\s+', ' ', str(er.reason or er.message))[:300] + (f' (at {er.path})' if er.path else ''))
                if len(errs) >= max_errors:
                    break
            how.append(f'official XSD {v}')
            xsd_ran = True
        except ImportError:
            how.append('XSD check skipped: pip install xmlschema')
        except Exception as ex:
            how.append(f'XSD check could not run ({type(ex).__name__}: {str(ex)[:160]})')
    elif not any('not possible' in h for h in how):
        how.append(f'no XSD file is bundled for {v} (its Python classes are)')
    cat = catalogue(v)
    unknown, seen = {}, 0
    for _, el in ET.iterparse(path, events=('start',)):
        n = _local(el.tag)
        seen += 1
        if el.tag.startswith('{' + UNITSML_NS) or n in cat or n == 'ocxXML':
            continue
        unknown[n] = unknown.get(n, 0) + 1
    how.append(f'every element name checked against the OCX {v} library')
    if unknown:
        errs += [f'unknown element ocx:{n} ({c}x) - not in OCX {v}' for n, c in sorted(unknown.items())[:10]]
    ok = not errs
    verdict = (('Valid against the official XSD' if xsd_ran else 'All element names are known OCX elements (full XSD check not run)')
               if ok else f'{len(errs)} problem(s), first: {errs[0]}')
    pe = f"{os.path.basename(path)}: OCX {info['schema_version'] or '?'} ({seen} elements). {verdict}. Checks: {'; '.join(how)}."
    return {'valid': ok, 'xsd_checked': xsd_ran, 'errors': errs, 'version': v, 'checks': how, 'plain_english': pe}


# ====================================================================== reading a model (any version) -> ShipBrain structure
_LEN = {'m': 1000.0, 'mm': 1.0, 'cm': 10.0, 'dm': 100.0, 'km': 1e6, 'in': 25.4, 'ft': 304.8, 'meter': 1000.0, 'metre': 1000.0,
        'millimeter': 1.0, 'millimetre': 1.0, 'centimeter': 10.0, 'centimetre': 10.0, 'inch': 25.4, 'foot': 304.8, 'feet': 304.8}


class _Units:
    def __init__(self, root):
        self.sym = {}
        for el in root.iter():
            if _local(el.tag) == 'Unit':
                uid = next((v for k, v in el.attrib.items() if k.endswith('}id') or k == 'id'), None)
                cand = []
                for c in el.iter():
                    if _local(c.tag) == 'UnitSymbol':
                        cand += [c.text, c.get('type')]           # symbol as text, or (some exporters) in its type attribute
                    elif _local(c.tag) == 'UnitName':
                        cand.append(c.text)
                hit = next((x.strip() for x in cand if x and x.strip() in _LEN), None) or \
                    next((x.strip().lower() for x in cand if x and x.strip().lower() in _LEN), None)
                if uid and hit:
                    self.sym[uid] = hit

    def mm(self, unit):
        u = unit or 'm'
        s = self.sym.get(u) or re.sub(r'^U', '', u)
        return _LEN.get(s, _LEN.get(s.lower(), 1000.0))


def _num(el, U, length=True):
    if el is None:
        return None
    try:
        v = float(el.get('numericvalue'))
    except (TypeError, ValueError):
        return None
    return v * U.mm(el.get('unit')) if length else v


def _kid(el, name):
    if el is None:
        return None
    for c in el:
        if _local(c.tag) == name:
            return c
    return None


def _kids(el, name):
    return [c for c in el if _local(c.tag) == name] if el is not None else []


def _point(el, U):
    if el is None:
        return None
    if el.get('coordinates'):
        f = U.mm(el.get('unit'))
        return [float(x) * f for x in el.get('coordinates').split()[:3]]
    xs = [_kid(el, k) for k in 'XYZ']
    if all(x is not None for x in xs):
        return [_num(x, U) for x in xs]
    for c in el:                                             # wrapper (StartPoint > Point3D ...)
        p = _point(c, U)
        if p:
            return p
    return None


def _vector(el):
    if el is None:
        return None
    for k in ('direction', 'coordinates'):
        if el.get(k):
            return [float(x) for x in el.get(k).split()[:3]]
    xs = [_kid(el, k) for k in 'XYZ']
    if all(x is not None for x in xs):
        return [float(x.get('numericvalue')) for x in xs]
    for c in el:
        v = _vector(c)
        if v:
            return v
    return None


_PTS = {'StartPoint', 'IntermediatePoint', 'EndPoint', 'Point3D', 'ControlPoint'}
_CIRCLE = {'Circle3D', 'CircumCircle3D'}


def _curve_points(el, U, out=None):
    out = [] if out is None else out
    for c in el:
        n = _local(c.tag)
        if n in _PTS:
            p = _point(c, U)
            if p and (not out or np.linalg.norm(np.subtract(out[-1], p)) > 1e-6):
                out.append(p)
        elif n in _CIRCLE:
            ctr, nrm = _point(_kid(c, 'Center'), U), _vector(_kid(c, 'Normal'))
            d = _num(_kid(c, 'Diameter'), U) or (2 * (_num(_kid(c, 'Radius'), U) or 0))
            if ctr and nrm and d:
                n3 = np.array(nrm, float) / (np.linalg.norm(nrm) or 1)
                a = np.cross(n3, [1, 0, 0] if abs(n3[0]) < 0.9 else [0, 1, 0])
                a /= np.linalg.norm(a)
                b = np.cross(n3, a)
                out += [list(np.array(ctr) + d / 2 * (math.cos(t) * a + math.sin(t) * b)) for t in np.linspace(0, 2 * math.pi, 17)[:-1]]
            else:
                _curve_points(c, U, out)
        elif n not in ('Normal', 'Center', 'KnotVector', 'NURBSproperties', 'CurveLength'):
            _curve_points(c, U, out)
    return out


def _plane_cs(pts, origin=None, normal=None):
    P = np.array(pts, float)
    o = np.array(origin, float) if origin is not None else P.mean(0)
    c = P - P.mean(0)
    _, _, vt = np.linalg.svd(c, full_matrices=False) if len(P) >= 3 else (None, None, np.eye(3))
    w = np.array(normal, float) if normal is not None else vt[2]
    w = w / (np.linalg.norm(w) or 1)
    u = vt[0] - np.dot(vt[0], w) * w
    if np.linalg.norm(u) < 1e-9:
        u = np.cross(w, [0, 0, 1]) if abs(w[2]) < 0.9 else np.cross(w, [0, 1, 0])
    u = u / np.linalg.norm(u)
    return {'origin': [round(float(x), 3) for x in o], 'uaxis': [round(float(x), 6) for x in u], 'waxis': [round(float(x), 6) for x in w]}


def _to2(cs, pts):
    o, u, w = (np.array(cs[k], float) for k in ('origin', 'uaxis', 'waxis'))
    v = np.cross(w, u)
    return [[round(float(np.dot(np.subtract(p, o), u)), 2), round(float(np.dot(np.subtract(p, o), v)), 2)] for p in pts]


def _flat_err(cs, pts):
    o, w = np.array(cs['origin'], float), np.array(cs['waxis'], float)
    return max((abs(float(np.dot(np.subtract(p, o), w))) for p in pts), default=0.0)


def _section(bs, U):
    for c in bs:
        n = _local(c.tag)
        if n in ('Description', 'CustomProperties'):
            continue
        dims = {_local(d.tag): _num(d, U) for d in c if d.get('numericvalue') is not None}
        H = dims.get('Height')
        if n == 'FlatBar':
            return {'type': 'FlatBar', 'H': H, 't': dims.get('Width') or dims.get('WebThickness'), 'ocx': n, 'dims': dims}
        if n in ('LBar', 'LBarOW', 'LBarOF'):
            return {'type': 'LBar', 'H': H, 'W': dims.get('FlangeWidth') or dims.get('Width'), 'tw': dims.get('WebThickness'),
                    'tf': dims.get('FlangeThickness') or dims.get('WebThickness'), 'ocx': n, 'dims': dims}
        if n in ('TBar', 'IBar'):
            return {'type': 'TBar', 'H': H, 't': dims.get('WebThickness'), 'wf': dims.get('FlangeWidth') or dims.get('Width'),
                    'tf': dims.get('FlangeThickness'), 'ocx': n, 'dims': dims}
        return {'type': n, 'params': [x for x in (H, dims.get('WebThickness') or dims.get('Width')) if x], 'ocx': n, 'dims': dims}
    return {'type': 'unknown'}


def _name(el):
    return el.get('name') or el.get('id')


def read(path, keep_names=True):
    """OCX file (any version) -> {'summary', 'model' (ShipBrain structure JSON), 'plain_english'}"""
    root = ET.parse(path).getroot()
    U = _Units(root)
    ver = detect_version(path)
    by_id = {}
    for el in root.iter():
        i = el.get('id')
        if i:
            by_id[i] = el
    guid = {}
    for el in root.iter():
        g = next((v for k, v in el.attrib.items() if k.endswith('GUIDRef')), None)
        if g and el.get('id') and _local(el.tag) in ('BarSection', 'Material', 'Steel', 'Aluminium'):
            guid[g] = el.get('id')

    def ref(el):
        if el is None:
            return None
        lr = next((v for k, v in el.attrib.items() if k.endswith('localRef')), None)
        if lr:
            return lr
        g = next((v for k, v in el.attrib.items() if k.endswith('GUIDRef')), None)
        return guid.get(g, g)
    sections, materials = {}, {}
    for bs in root.iter():
        n = _local(bs.tag)
        if n == 'BarSection':
            s = _section(bs, U)
            s['name'] = bs.get('name') or bs.get('id')
            sections[bs.get('id')] = s
        elif n in ('Material', 'Steel', 'Aluminium') and bs.get('id'):
            ys = next((c for c in bs.iter() if _local(c.tag) in ('YieldStress', 'YieldStrength')), None)
            materials[bs.get('id')] = {'name': bs.get('name') or bs.get('grade') or bs.get('id'), 'grade': bs.get('grade'),
                                       'kind': n, 'yield': float(ys.get('numericvalue')) if ys is not None and ys.get('numericvalue') else None}
    frames = {}
    for ax in ('XRefPlanes', 'YRefPlanes', 'ZRefPlanes'):
        locs = []
        for el in root.iter():
            if _local(el.tag) == ax:
                for rp in _kids(el, 'RefPlane'):
                    x = _num(_kid(rp, 'ReferenceLocation'), U)
                    if x is not None:
                        locs.append({'name': rp.get('name'), 'mm': round(x, 2)})
        if locs:
            frames[ax[0]] = sorted(locs, key=lambda d: d['mm'])
    pp = {}
    for el in root.iter():
        if _local(el.tag) == 'PrincipalParticulars':
            for c in el:
                if c.get('numericvalue') is not None:
                    pp[_local(c.tag)] = (round(_num(c, U) / 1000, 3) if (c.get('unit') or '').lower() in ('um', 'm') else float(c.get('numericvalue')))
            break
    panels, notes = [], []
    counts = {'Panel': 0, 'Plate': 0, 'Stiffener': 0, 'Bracket': 0, 'Pillar': 0, 'Seam': 0, 'Hole': 0, 'EdgeReinforcement': 0}
    for el in root.iter():
        n = _local(el.tag)
        if n in counts and el.get('id'):
            counts[n] += 1
        if n in ('Hole2D', 'SlotContour') or (n == 'InnerContour'):
            counts['Hole'] += 1
    thk_list, plate_area, steel_kg = [], 0.0, 0.0
    sec_count = {}

    def plate_like(pl):
        pm = _kid(pl, 'PlateMaterial')
        t = _num(_kid(pm, 'Thickness'), U) if pm is not None else None
        mref = ref(pm) or ref(_kid(pm, 'MaterialRef') if pm is not None else None)
        oc = _kid(pl, 'OuterContour')
        pts = _curve_points(oc, U) if oc is not None else []
        holes = [_curve_points(ic, U) for ic in _kids(pl, 'InnerContour')]
        return t, mref, pts, [h for h in holes if len(h) >= 3]

    def panel_entry(pid, name, ftype, plane_el, plates, stiffs, brackets):
        allp = [p for pl in plates for p in pl['pts']] + [p for s in stiffs for p in s['pts']] + [p for b in brackets for p in b['pts']]
        if len(allp) < 3:
            return None
        origin = normal = None
        if plane_el is not None:
            origin = _point(_kid(plane_el, 'Origin') or _kid(plane_el, 'PointOnSurface'), U)
            normal = _vector(_kid(plane_el, 'Normal'))
        cs = _plane_cs(allp, origin, normal)
        err = _flat_err(cs, allp)
        if err > 50:
            cs = _plane_cs(allp)
            err = _flat_err(cs, allp)
            if err > 50:
                notes.append(f'{name}: curved ({err:.0f} mm out of plane) - flattened onto its best plane for comparing / meshing')
        P = {'id': pid, 'name': name, 'function': ftype, 'cs': cs, 'plates': [], 'holes': [], 'stiffeners': [], 'brackets': []}
        for pl in plates:
            P['plates'].append({'name': pl['name'], 'thk': pl['t'], 'grade': pl['grade'], 'contour': _to2(cs, pl['pts'])})
            for h in pl['holes']:
                P['holes'].append({'contour': _to2(cs, h)})
        o, u, w = (np.array(cs[k]) for k in ('origin', 'uaxis', 'waxis'))
        v = np.cross(w, u)
        for s in stiffs:
            tr = _to2(cs, [s['pts'][0], s['pts'][-1]])
            d = s['web'] or list(w)
            P['stiffeners'].append({'name': s['name'], 'sec': s['sec'], 'grade': s['grade'], 'trace': tr,
                                    'incl': [round(float(np.dot(d, u)), 4), round(float(np.dot(d, v)), 4), round(float(np.dot(d, w)), 4)]})
        for b in brackets:
            bcs = _plane_cs(b['pts'])
            P['brackets'].append({'name': b['name'], 'thk': b['t'], 'grade': b['grade'], 'cs': bcs, 'contour': _to2(bcs, b['pts'])})
        return P

    def grade(mref):
        return (materials.get(mref) or {}).get('name') or mref

    def collect(container, pid, name, ftype, plane_el):
        nonlocal plate_area, steel_kg
        plates, stiffs, brackets = [], [], []
        comp = _kid(container, 'ComposedOf')
        for pl in (_kids(comp, 'Plate') if comp is not None else []):
            t, mref, pts, holes = plate_like(pl)
            if len(pts) >= 3:
                plates.append({'name': _name(pl), 't': t, 'grade': grade(mref), 'pts': pts, 'holes': holes})
                if t:
                    thk_list.append(round(t, 2))
                    a = _area_poly(pts)
                    plate_area += a
                    steel_kg += a * t * 7.85e-6
        for br in (_kids(comp, 'Bracket') if comp is not None else []):
            t, mref, pts, _ = plate_like(br)
            if len(pts) >= 3:
                brackets.append({'name': _name(br), 't': t, 'grade': grade(mref), 'pts': pts})
        sb = _kid(container, 'StiffenedBy')
        for st in (_kids(sb, 'Stiffener') if sb is not None else []):
            tl = _kid(st, 'TraceLine')
            pts = _curve_points(tl, U) if tl is not None else []
            if len(pts) < 2:
                continue
            sid = ref(_kid(st, 'SectionRef'))
            sid = (sections.get(sid) or {}).get('name') or sid          # the section's name (same in every export)
            inc = _kid(st, 'Inclination')
            stiffs.append({'name': _name(st), 'sec': sid, 'grade': grade(ref(_kid(st, 'MaterialRef'))), 'pts': pts,
                           'web': _vector(_kid(inc, 'WebDirection')) if inc is not None else None})
            sec_count[sid] = sec_count.get(sid, 0) + 1
        return panel_entry(pid, name, ftype, plane_el, plates, stiffs, brackets)

    for pan in root.iter():
        if _local(pan.tag) != 'Panel' or not pan.get('id'):
            continue
        ug = _kid(pan, 'UnboundedGeometry')
        plane = _kid(ug, 'Plane3D') if ug is not None else None
        ftype = next((v for k, v in pan.attrib.items() if k.endswith('functionType')), None)
        e = collect(pan, pan.get('id'), _name(pan), ftype, plane)
        if e:
            panels.append(e)
    model = {'source': 'OCX', 'schema_version': ver['schema_version'],
             'sections': {(s.get('name') or k): {kk: vv for kk, vv in s.items() if kk != 'dims'} for k, s in sections.items()},
             'materials': materials, 'frames': frames, 'blocks': [{'id': 'OCX', 'panels': panels}]}
    hdr = next((el for el in root.iter() if _local(el.tag) == 'Header'), None)
    ves = next((el for el in root.iter() if _local(el.tag) == 'Vessel'), None)
    top = sorted(sec_count.items(), key=lambda x: -x[1])[:6]
    summ = {'schema_version': ver['schema_version'], 'panels': counts['Panel'], 'plates': counts['Plate'], 'stiffeners': counts['Stiffener'],
            'brackets': counts['Bracket'], 'pillars': counts['Pillar'], 'seams': counts['Seam'], 'holes': counts['Hole'],
            'edge_reinforcements': counts['EdgeReinforcement'], 'sections': len(sections), 'materials': len(materials),
            'thickness_mm': {'min': min(thk_list), 'max': max(thk_list),
                             'most_used': max(set(thk_list), key=thk_list.count)} if thk_list else None,
            'plate_area_m2': round(plate_area / 1e6, 2), 'plate_steel_t': round(steel_kg / 1000, 2),
            'frames': {k: {'count': len(v), 'from_mm': v[0]['mm'], 'to_mm': v[-1]['mm']} for k, v in frames.items()},
            'principal_particulars': pp, 'sections_most_used': [{'section': k, 'stiffeners': n} for k, n in top],
            'materials_used': sorted({m['name'] for m in materials.values()})[:12], 'notes': notes[:20]}
    if keep_names:
        summ['vessel'] = ves.get('name') if ves is not None else None
        summ['originating_system'] = hdr.get('originating_system') if hdr is not None else None
    t = summ['thickness_mm']
    pe = (f"OCX {ver['schema_version'] or '?'} model: {summ['panels']} panels, {summ['plates']} plates, {summ['stiffeners']} stiffeners, "
          f"{summ['brackets']} brackets, {summ['pillars']} pillars, {summ['seams']} seams, {summ['holes']} holes/cut-outs; "
          f"{summ['sections']} cross sections and {summ['materials']} materials in its catalogues."
          + (f" Plate thickness {t['min']:g}-{t['max']:g} mm (most used {t['most_used']:g} mm); plate area {summ['plate_area_m2']:g} m2, "
             f"about {summ['plate_steel_t']:g} t of plate steel." if t else '')
          + (' Frames: ' + ', '.join(f"{k} {d['count']}" for k, d in summ['frames'].items()) + '.' if summ['frames'] else '')
          + (' Most used sections: ' + ', '.join(f"{x['section']} ({x['stiffeners']})" for x in summ['sections_most_used'][:4]) + '.'
             if summ['sections_most_used'] else '')
          + (f" {len(notes)} curved panel(s) flattened for comparing." if notes else ''))
    return {'summary': summ, 'model': model, 'plain_english': pe}


def _area_poly(pts):
    P = np.array(pts, float)
    n = np.zeros(3)
    for i in range(len(P)):
        n += np.cross(P[i], P[(i + 1) % len(P)])
    return float(np.linalg.norm(n) / 2)


def to_members(path):
    """for members.load / compare_structures"""
    return read(path, keep_names=False)['model']


# ====================================================================== writing OCX 3.2.0 from a ShipBrain structure
def write(model, path, name='ShipBrain model', version=LATEST, density=7.85e-9):
    """structure JSON (members format) -> OCX file built with the official classes of `version` (3.x)"""
    v = _resolve(version)
    m = module(v)
    ctx = {'n': 0}
    nid = lambda p: (ctx.__setitem__(p, ctx.get(p, 0) + 1), f'{p}{ctx[p]}')[1]
    gid = lambda: str(uuid.uuid4())
    M = 'm'
    cat = catalogue(v)
    C = lambda xml: getattr(m, _lookup(cat, xml)['class'])

    def q(cls, val, unit=M):
        return C(cls)(numericvalue=float(val), unit=_UNIT_ID.get(unit, unit))

    def p3(cls, xyz):
        return C(cls)(coordinates=[round(float(c) / 1000, 6) for c in xyz], unit=_UNIT_ID[M])

    def vec(cls, d):
        d = np.array(d, float)
        d = d / (np.linalg.norm(d) or 1)
        kw = {f.name: [round(float(x), 6) for x in d] for f in dataclasses.fields(C(cls)) if f.name in ('direction', 'coordinates')}
        return C(cls)(**kw)

    def poly_curve(cls, pts3):
        segs = []
        L = 0.0
        for a, b in zip(pts3, pts3[1:] + pts3[:1]):
            ln = float(np.linalg.norm(np.subtract(b, a)))
            L += ln
            segs.append(m.Line3D(id=nid('L'), curve_length=q('CurveLength', ln / 1000), start_point=p3('StartPoint', a), end_point=p3('EndPoint', b)))
        cc = m.CompositeCurve3D(id=nid('C'), curve_length=q('CurveLength', L / 1000), line3_d=segs)
        if not cls:
            return cc
        kw = {'composite_curve3_d': [cc]}
        if _has(C(cls), 'curve_length'):
            kw.update(id=nid('C'), curve_length=q('CurveLength', L / 1000))
        return C(cls)(**kw)

    def mass(area_mm2, t, centre):
        return m.MassProperties(moulded_dry_weight=q('MouldedDryWeight', area_mm2 * (t or 0) * density * 1000, 'kg'),
                                moulded_center_of_gravity=p3('MouldedCenterOfGravity', centre))

    from .members import _to3, _open
    mats, secs = {}, {}
    for b in model.get('blocks', []):
        for p in b.get('panels', []):
            for x in p.get('plates', []) + p.get('brackets', []) + p.get('stiffeners', []):
                mats.setdefault(x.get('grade') or 'STEEL', None)
    for g in mats:
        mats[g] = nid('MAT')
    YS = {'A': 235, 'B': 235, 'D': 235, 'E': 235, 'AH32': 315, 'DH32': 315, 'EH32': 315, 'AH36': 355, 'DH36': 355, 'EH36': 355,
          'AH40': 390, 'DH40': 390, 'EH40': 390}
    steel = []
    for g, i in mats.items():
        gm = re.match(r'([A-Za-z]+)', str(g))
        gr = gm.group(1).upper() if gm else 'A'
        allowed = (_lookup(cat, 'Steel') or {}).get('attributes', [])
        allowed = next((a.get('values') for a in allowed if a['name'] == 'grade'), None)
        if allowed and gr not in allowed:
            gr = allowed[0]
        st = new('Steel', v, id=i, name=g, grade=gr)
        ys = YS.get(str(g).upper(), 235)
        for f, val, unit in (('density', 7850, 'kg/m3'), ('youngs_modulus', 2.06e11, 'Pa'), ('poisson_ratio', 0.3, 'dimensionless'),
                             ('yield_stress', ys * 1e6, 'Pa'), ('ultimate_stress', (400 if ys == 235 else 490) * 1e6, 'Pa'),
                             ('thermal_expansion_coefficient', 1.2e-5, '1/K')):
            if _has(type(st), f):
                tp, _ = _inner(typing.get_type_hints(type(st), globalns=vars(m))[f])
                setattr(st, f, tp(numericvalue=float(val), unit=_UNIT_ID.get(unit, unit)))
        if _has(type(st), 'guidref'):
            st.guidref = gid()
        steel.append(st)
    for sid, s in (model.get('sections') or {}).items():
        H = s.get('H') or (s.get('params') or [100, 10])[0]
        kind = s.get('type')
        if kind == 'FlatBar':
            body = {'flat_bar': m.FlatBar(height=q('Height', H / 1000), width=q('Width', (s.get('t') or 10) / 1000))}
        elif kind == 'LBar':
            body = {'lbar': m.Lbar(height=q('Height', H / 1000), width=q('Width', (s.get('W') or 90) / 1000),
                                   web_thickness=q('WebThickness', (s.get('tw') or 10) / 1000),
                                   flange_thickness=q('FlangeThickness', (s.get('tf') or s.get('tw') or 10) / 1000))}
        elif kind == 'TBar':
            body = {'tbar': m.Tbar(height=q('Height', H / 1000), web_thickness=q('WebThickness', (s.get('t') or 10) / 1000),
                                   flange_width=q('FlangeWidth', (s.get('wf') or 100) / 1000),
                                   flange_thickness=q('FlangeThickness', (s.get('tf') or 10) / 1000))}
        else:
            pp = s.get('params') or [H, 10]
            body = {'flat_bar': m.FlatBar(height=q('Height', pp[0] / 1000), width=q('Width', pp[-1] / 1000))}
        secs[sid] = nid('SEC')
        secs[sid + '__obj'] = m.BarSection(id=secs[sid], name=str(s.get('name') or sid), **body)
    panels = []
    ftv = m.FunctionTypeValue if hasattr(m, 'FunctionTypeValue') else None
    tv = m.TightnessValue if hasattr(m, 'TightnessValue') else None
    for b in model.get('blocks', []):
        for p in b.get('panels', []):
            cs = p['cs']
            o, u, w = (np.array(cs[k], float) for k in ('origin', 'uaxis', 'waxis'))
            plates, allpts = [], []
            for k, pl in enumerate(p.get('plates', [])):
                P3 = [list(map(float, x)) for x in _to3(cs, _open(pl['contour']))]
                allpts += P3
                A = _area_poly(P3)
                t = float(pl.get('thk') or 10)
                plates.append(m.Plate(id=nid('PL'), name=str(pl.get('name') or f"{p['id']}-{k + 1}"), guidref=gid(),
                                      mass_properties=mass(A, t, np.mean(P3, 0)), net_area=q('NetArea', A / 1e6, 'm2'),
                                      plate_material=m.PlateMaterial(local_ref=mats[pl.get('grade') or 'STEEL'], thickness=q('Thickness', t / 1000)),
                                      outer_contour=[poly_curve('OuterContour', P3)]))
            if not plates:
                continue
            stiffs = []
            for k, s in enumerate(p.get('stiffeners', [])):
                a, bb = (list(map(float, x)) for x in _to3(cs, s['trace'][:1] + s['trace'][-1:]))
                inc = s.get('incl') or [0, 0, 1]
                d = inc[0] * u + inc[1] * np.cross(w, u) + inc[2] * w
                sid = s.get('sec')
                if sid not in secs:
                    secs[sid] = nid('SEC')
                    secs[sid + '__obj'] = m.BarSection(id=secs[sid], name=str(sid), flat_bar=m.FlatBar(height=q('Height', 0.1), width=q('Width', 0.01)))
                L = float(np.linalg.norm(np.subtract(bb, a)))
                line = m.Line3D(id=nid('L'), curve_length=q('CurveLength', L / 1000), start_point=p3('StartPoint', a), end_point=p3('EndPoint', bb))
                stiffs.append(m.Stiffener(id=nid('ST'), name=str(s.get('name') or f"{p['id']}-S{k + 1}"), guidref=gid(),
                                          mass_properties=mass(0, 0, np.mean([a, bb], 0)),
                                          trace_line=m.TraceLine(composite_curve3_d=m.CompositeCurve3D(id=nid('C'), curve_length=q('CurveLength', L / 1000), line3_d=[line])),
                                          material_ref=m.MaterialRef(local_ref=mats[s.get('grade') or 'STEEL']),
                                          section_ref=m.SectionRef(local_ref=secs[sid], offset_u=q('OffsetU', 0), offset_v=q('OffsetV', 0)),
                                          inclination=[m.Inclination(web_direction=vec('WebDirection', d), flange_direction=vec('FlangeDirection', u),
                                                                     position=p3('Position', a))]))
            P2 = np.array([_to2(cs, [x])[0] for x in allpts])
            lo, hi = P2.min(0), P2.max(0)
            box = [list(map(float, x)) for x in _to3(cs, [[lo[0], lo[1]], [hi[0], lo[1]], [hi[0], hi[1]], [lo[0], hi[1]]])]
            plane = m.Plane3D(id=nid('S'), point_on_surface=p3('PointOnSurface', o), normal=vec('Normal', w), udirection=vec('UDirection', u))
            kw = dict(id=nid('PA'), name=str(p.get('name') or p['id']), guidref=gid(), unbounded_geometry=m.UnboundedGeometry(plane3_d=[plane]),
                      limited_by=m.LimitedBy(free_edge_curve3_d=[poly_curve('FreeEdgeCurve3D', box)]),
                      composed_of=m.ComposedOf(plate=plates))
            if ftv is not None:
                kw['function_type'] = _enum_pick(ftv, p.get('function'), w)
            if tv is not None:
                kw['tightness'] = _enum_pick(tv, 'NonTight')
            if stiffs:
                kw['stiffened_by'] = m.StiffenedBy(stiffener=stiffs)
            panels.append(m.Panel(**kw))
    from xsdata.models.datatype import XmlDateTime
    hdr = m.Header(time_stamp=XmlDateTime.from_datetime(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)),
                   name=name, author='ShipBrain', originating_system='ShipBrain', organization='', application_version='1')
    vessel = new('Vessel', v, id='VESSEL1', name=name, panel=panels, _ctx={'prefix': 'V'})
    try:                                                      # frame tables: given frames, else the planes of the panels
        fr = model.get('frames') or {}
        planes = {}
        for ax, k in (('X', 0), ('Y', 1), ('Z', 2)):
            locs = [f['mm'] for f in fr.get(ax, [])]
            if not locs:
                locs = sorted({round(float(p['cs']['origin'][k]), 1) for b in model.get('blocks', []) for p in b.get('panels', [])
                               if abs(float(np.array(p['cs']['waxis'], float)[k])) > 0.9})
            planes[ax] = locs
        cs0 = vessel.coordinate_system[0]
        for ax, attr in (('X', 'xref_planes'), ('Y', 'yref_planes'), ('Z', 'zref_planes')):
            if not planes[ax] or not _has(type(cs0), attr):
                continue
            tp, _ = _inner(typing.get_type_hints(type(cs0), globalns=vars(m))[attr])
            rps = [new('RefPlane', v, id=nid('RP'), name=f'{ax}{x:g}', reference_location=q('ReferenceLocation', x / 1000))
                   for x in planes[ax]]
            setattr(cs0, attr, tp(ref_plane=rps))
    except Exception:
        pass
    for f, val, unit in (('distance_tolerance', 0.001, 'm'), ('angle_tolerance', 0.001, 'rad')):
        if _has(type(vessel), f):
            tp, _ = _inner(typing.get_type_hints(type(vessel), globalns=vars(m))[f])
            setattr(vessel, f, tp(numericvalue=val, unit=_UNIT_ID[unit]))
    cc = new('ClassCatalogue', v, id='CAT1', _ctx={'prefix': 'CC'})
    cc.material_catalogue = m.MaterialCatalogue(id='MATCAT1', steel=steel)
    xs = [o_ for k_, o_ in secs.items() if k_.endswith('__obj')]
    if xs:
        cc.xsection_catalogue = m.XsectionCatalogue(id='XSEC1', name='sections', bar_section=xs)
    root = new('OcxXml', v, header=hdr, vessel=vessel, class_catalogue=cc, units_ml=_units_ml(m))
    to_xml(root, v, path)
    return {'file': path, 'version': v, 'panels': len(panels), 'plates': sum(len(x.composed_of.plate) for x in panels),
            'stiffeners': sum(len(x.stiffened_by.stiffener) if x.stiffened_by else 0 for x in panels), 'sections': len(xs), 'materials': len(steel)}


_UNIT_NAMES = {'m': 'metre', 'kg': 'kilogram', 'm2': 'square metre', 'Pa': 'pascal', 'kg/m3': 'kilogram per cubic metre',
               'dimensionless': 'dimensionless', '1/K': 'per kelvin', 'rad': 'radian'}
_UNIT_ID = {'m': 'Um', 'kg': 'Ukg', 'm2': 'Um2', 'Pa': 'UPa', 'kg/m3': 'Ukg_m3', 'dimensionless': 'UDimless', '1/K': 'U1_K', 'rad': 'URad'}


def _enum_pick(E, want=None, normal=None):
    vals = list(E)
    if want:
        for e in vals:
            if str(e.value).lower() == str(want).lower():
                return e
        for e in vals:
            if str(want).lower() in str(e.value).lower():
                return e
    if normal is not None:
        n = np.abs(np.array(normal, float))
        key = ['bulkhead', 'girder', 'deck'][int(n.argmax())] if n.max() > 0.9 else 'shell'
        for e in vals:
            if key in str(e.value).lower():
                return e
    return vals[0]


def _units_ml(m):
    """UnitsML block that declares every unit the writer uses (the unit attributes refer to these ids)"""
    um = m.UnitsMl() if hasattr(m, 'UnitsMl') else None
    if um is None:
        return None
    try:
        unit_cls = typing.get_type_hints(type(um), globalns=vars(m))['unit_set']
        unit_cls, _ = _inner(unit_cls)
        uhint, _ = _inner(typing.get_type_hints(unit_cls, globalns=vars(m))['unit'])
        sh, _ = _inner(typing.get_type_hints(uhint, globalns=vars(m))['unit_name'])
        sym, _ = _inner(typing.get_type_hints(uhint, globalns=vars(m))['unit_symbol'])
        units = []
        for symbol, nm in _UNIT_NAMES.items():
            uid = _UNIT_ID[symbol]
            kw = {'id': uid, 'unit_name': [sh(value=nm)]} if _has(uhint, 'id') else {'unit_name': [sh(value=nm)]}
            u_ = uhint(**kw)
            try:
                u_.unit_symbol = [sym(value=symbol, type_value='ASCII')]
            except Exception:
                pass
            units.append(u_)
        um.unit_set = unit_cls(unit=units)
    except Exception:
        pass
    return um


def _has(cls, f):
    return f in {x.name for x in dataclasses.fields(cls)}


# ====================================================================== OCXReader (C++, separate program) -> STEP
def reader_exe():
    for c in (os.environ.get('SHIPBRAIN_OCXREADER'), os.path.join(CACHE, 'build', 'ocxreader', 'ocxreader'),
              os.path.join(CACHE, 'build', 'ocxreader', 'Release', 'ocxreader.exe'), os.path.join(CACHE, 'build', 'bin', 'ocxreader')):
        if c and os.path.exists(c):
            return c
    import shutil
    return shutil.which('ocxreader') or shutil.which('ocxreader.exe')


def reader_build(log=print):
    """build OCXReader once with its own CMake + vcpkg set-up (it fetches OpenCascade; long: ~1 h the first time)"""
    import shutil, subprocess
    for tool in ('cmake', 'git'):
        if not shutil.which(tool):
            raise RuntimeError(f'CMake is needed to build OCXReader ({tool} not found)')
    vcpkg = os.environ.get('VCPKG_ROOT')
    if not vcpkg or not os.path.exists(vcpkg):
        raise RuntimeError('vcpkg is needed to build OCXReader (it brings OpenCascade): install vcpkg and set VCPKG_ROOT')
    b = os.path.join(CACHE, 'build')
    os.makedirs(b, exist_ok=True)
    tc = os.path.join(vcpkg, 'scripts', 'buildsystems', 'vcpkg.cmake')
    for cmd in (['cmake', '-S', READER_ROOT, '-B', b, f'-DCMAKE_TOOLCHAIN_FILE={tc}', '-DCMAKE_BUILD_TYPE=Release'],
                ['cmake', '--build', b, '--config', 'Release', '-j', str(os.cpu_count() or 4)]):
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError('OCXReader build failed: ' + (r.stderr or r.stdout)[-1500:])
    log and log('OCXReader built: ' + str(reader_exe()))
    return reader_exe()


def to_step(path, out=None):
    """OCX -> STEP: OCXReader (exact OpenCascade geometry, all its features) when built, else ShipBrain's own plates/beams solids"""
    import subprocess
    out = out or os.path.splitext(path)[0] + '.step'
    exe = reader_exe()
    if exe:
        r = subprocess.run([exe, '--input-file', path, '--export-format', 'STEP', '--output-file', os.path.splitext(out)[0]],
                           capture_output=True, text=True, timeout=3600)
        cand = [c for c in (out, os.path.splitext(out)[0] + '.stp', os.path.splitext(out)[0] + '.step') if os.path.exists(c)]
        if cand:
            return {'step': cand[0], 'by': 'OCXReader'}
        raise RuntimeError('OCXReader made no STEP: ' + (r.stderr or r.stdout)[-800:])
    from .members import to_plates
    from .drawings import plates_to_step
    sp = to_plates(read(path, keep_names=False)['model'])
    plates_to_step(sp['plates'], out, sp['beams'])
    return {'step': out, 'by': 'ShipBrain (plates as thin solids, stiffeners as beams; build OCXReader for its exact geometry)'}
