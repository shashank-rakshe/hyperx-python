"""
ship_xml_kit.py - everything the LLM needs around the deckrules XML work.

  1. xml_to_members / members_to_xml   moulded-line ship XML  <->  compact JSON (round-trip tested)
  2. check_panel / validate_file       rule checks (closed contours, unique names, NO-GAP, inside outline)
  3. RuleIndex                         BM25 retrieval over RULES.md / ONLINE_METHOD_RULES.md  (RAG at run time)
  4. make_ship_samples                 training data for the all-in-one trainer:
        ship_rule_lookup / ship_rule_find   rule book Q&A (text)
        ship_notes                          scanned sheet notes -> JSON (plate thk, beam/girder sections, frame space)
        ship_review                         compact member table -> rule violations (labels from the checker)
        + ship_online.py tasks              OCR fixes (R-T17..22), R2.1 number classes, line/label kinds, joint decisions,
                                            the 6-step method, member JSON from the online XML, review with PN1 / PN4
  5. run_deckrules                     subprocess wrapper around  python -m deckrules.build_ship

The LLM never writes raw XML. It reads drawings / notes, emits compact JSON, and members_to_xml() writes the XML
with the owner's convention (R-IM1: web Positive, flange origin = start + H*V, Waxis -V, Negative).

CLI:
  python ship_xml_kit.py roundtrip  FILE.xml
  python ship_xml_kit.py validate   FILE.xml
  python ship_xml_kit.py retrieve   "query" --src ship_src
  python ship_xml_kit.py build-data --src ship_src --out ship_data --n 300
"""
import argparse, json, math, os, random, re, subprocess, sys, zipfile
import xml.etree.ElementTree as ET

TOL_GAP = 3.0        # R-CN6: connected <= 3 mm
TOL_IN = 2.0         # C6: more than 2 mm outside the outline = fail


def _f(x):
    return f"{x:.10E}"


def _sub(a, b): return [a[i] - b[i] for i in range(3)]
def _cross(a, b): return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
def _dot(a, b): return sum(a[i] * b[i] for i in range(3))
def _unit(a):
    n = math.sqrt(_dot(a, a))
    return [x / n for x in a] if n > 1e-12 else list(a)


# ======================================================================= parse
def _uv(e): return [float(e.get("U")), float(e.get("V"))]


def _contour(c):
    return [_uv(c.find("StartPoint2d"))] + [_uv(s.find("Node2d")) for s in c.findall("Segment2d")]


def _cs(e):
    cs = e.find("CoordSys")
    g = lambda n: [float(cs.find(n).get(k)) for k in "XYZ"]
    return {"origin": g("Origin"), "waxis": g("Waxis"), "uaxis": g("Uaxis")}


def _section(bs):
    sid, bt = bs.get("BarSectionId"), bs.get("BarType")
    p = [float(x) for x in (bs.findtext("Parameters") or "").split()]
    if bt == "31" and len(p) == 4:
        return sid, {"type": "LBar", "H": p[0], "W": p[1], "tw": p[2], "tf": p[3]}
    if bt == "10" and len(p) == 2:
        return sid, {"type": "FlatBar", "H": p[0], "t": p[1]}
    if bt == "10" and len(p) == 4:      # T-bar: web H x t + flange wf x tf (R-TB1), stored as BarType 10 with 4 parameters
        return sid, {"type": "TBar", "H": p[0], "t": p[1], "wf": p[2], "tf": p[3]}
    return sid, {"type": "Other", "bar_type": bt, "params": p}


def _ext(contour):
    return max(p[0] for p in contour), max(p[1] for p in contour)


def xml_to_members(path):
    root = ET.parse(path).getroot()
    out = {"attrs": dict(root.attrib), "sections": {}, "blocks": [], "unsupported": {}}
    for blk in root.iter("Block"):
        b = {"id": blk.get("ObjId"), "panels": []}
        for pp in blk.findall("PlanePanel"):
            pan = {"id": pp.get("ObjId"), "attrs": {k: v for k, v in pp.attrib.items() if k != "ObjId"},
                   "cs": _cs(pp), "boundary": None, "plates": [], "holes": [], "stiffeners": [], "brackets": []}
            bd = pp.find("Boundary/SimpleContour")
            if bd is not None:
                pan["boundary"] = _contour(bd)
            for g in pp.findall("PlateGroup"):
                m = g.find("Material")
                thk = float(m.findtext("Thickness") or 0)
                for pl in g.findall("Plate"):
                    pan["plates"].append({"name": pl.get("Name"), "source": pl.get("Source", ""),
                                          "grade": m.get("Grade", "A"), "thk": thk,
                                          "contour": _contour(pl.find("SimpleContour"))})
            for g in pp.findall("HoleGroup"):
                for h in g.findall("Hole"):
                    pan["holes"].append({"rule": h.get("Rule", ""), "contour": _contour(h.find("Contour"))})
            for g in pp.findall("StiffenerGroup"):
                m = g.find("Material")
                sid, sec = _section(m.find("BarShape"))
                out["sections"][sid] = sec
                for st in g.findall("Stiffener"):
                    tr = _contour(st.find("Trace"))
                    iv = st.find("Inclination")[0]
                    d = {"name": st.get("Name"), "kind": st.get("Kind", ""), "sec": sid, "grade": m.get("Grade", "A"),
                         "evidence": st.get("Evidence", ""), "trace": [tr[0], tr[-1]],
                         "incl": [float(iv.get(k)) for k in "UVW"]}
                    w, fl = st.find("Web"), st.find("Flange1")
                    if w is not None:
                        d["_web"] = dict(_cs(w), ext=_ext(_contour(w.find("DetailedContour"))))
                    if fl is not None:
                        d["_flange"] = dict(_cs(fl), ext=_ext(_contour(fl.find("DetailedContour"))))
                    pan["stiffeners"].append(d)
            for g in pp.findall("BracketGroup"):
                m = g.find("Material")
                thk = float(m.findtext("Thickness") or 0)
                for br in g.findall("Bracket"):
                    ref = br.find("End2/ModelRef")
                    pan["brackets"].append({"name": br.get("Name"), "source": br.get("Source", ""), "grade": m.get("Grade", "A"),
                                            "thk": thk, "cs": _cs(br), "contour": _contour(br.find("SimpleContour")),
                                            "end2": dict(ref.attrib) if ref is not None else None})
            b["panels"].append(pan)
        out["blocks"].append(b)
    for tag in ("Pillar", "SupportLines", "PillarGroup"):
        n = sum(1 for _ in root.iter(tag))
        if n:
            out["unsupported"][tag] = n
    return out


# ======================================================================== emit
def _frame(cs):
    U = _unit(cs["uaxis"]); W = _unit(cs["waxis"]); V = _cross(W, U)
    return U, V, W


def _to_xyz(cs, u, v, w=0.0):
    U, V, W = _frame(cs)
    return [cs["origin"][i] + u * U[i] + v * V[i] + w * W[i] for i in range(3)]


def _vec_xyz(cs, u, v, w):
    U, V, W = _frame(cs)
    return [u * U[i] + v * V[i] + w * W[i] for i in range(3)]


def derive_web_flange(pan_cs, st, sec):
    """Owner convention (R-IM1). Returns dict(web=..., flange=... or None)."""
    a = _to_xyz(pan_cs, *st["trace"][0])
    b = _to_xyz(pan_cs, *st["trace"][-1])
    L = math.dist(a, b)
    T = _unit(_sub(b, a))
    V = _unit(_vec_xyz(pan_cs, *st["incl"]))
    d = _dot(V, T)
    if abs(d) > 1e-9:
        V = _unit([V[i] - d * T[i] for i in range(3)])
    Wn = _unit(_cross(T, V))
    H = sec["H"]
    res = {"web": {"origin": a, "waxis": Wn, "uaxis": T, "ext": (L, H)}, "flange": None}
    if sec["type"] == "LBar":
        res["flange"] = {"origin": [a[i] + V[i] * H for i in range(3)], "waxis": [-x for x in V], "uaxis": T,
                         "ext": (L, sec["W"]), "tw": sec["tw"]}
    elif sec["type"] == "TBar":
        res["flange"] = {"origin": [a[i] + V[i] * H for i in range(3)], "waxis": [-x for x in V], "uaxis": T,
                         "ext": (L, sec["wf"] / 2), "tf": sec["tf"]}
    return res


def _xyz(parent, tag, v):
    ET.SubElement(parent, tag, X=_f(v[0]), Y=_f(v[1]), Z=_f(v[2]))


def _coord(parent, cs):
    c = ET.SubElement(parent, "CoordSys")
    _xyz(c, "Origin", cs["origin"]); _xyz(c, "Waxis", cs["waxis"]); _xyz(c, "Uaxis", cs["uaxis"])


def _cont(parent, tag, pts):
    c = ET.SubElement(parent, tag)
    ET.SubElement(c, "StartPoint2d", U=_f(pts[0][0]), V=_f(pts[0][1]))
    for p in pts[1:]:
        s = ET.SubElement(c, "Segment2d")
        ET.SubElement(s, "Amplitude2d", U=_f(0), V=_f(0))
        ET.SubElement(s, "Node2d", U=_f(p[0]), V=_f(p[1]))
    return c


def _crossection(sec):
    if sec["type"] == "LBar":
        H, W, tw, tf = sec["H"], sec["W"], sec["tw"], sec["tf"]
        return [[0, 0], [tw, 0], [tw, H - tf], [W, H - tf], [W, H], [0, H], [0, 0]]
    H, t = sec["H"], sec["t"]
    return [[0, 0], [t, 0], [t, H], [0, H], [0, 0]]


def members_to_xml(m, path=None):
    root = ET.Element("Ship", Version="pre 2.0", GeometryConvention="MouldedLine",
                      Source=m.get("attrs", {}).get("Source", "ship_xml_kit"))
    ET.SubElement(root, "Material", Grade="A")
    for sid, sec in m["sections"].items():
        if sec["type"] == "LBar":
            bs = ET.SubElement(root, "BarSection", BarSectionId=sid)
            ET.SubElement(bs, "LBar", Height=f"{sec['H']:g}", Width=f"{sec['W']:g}",
                          WebThickness=f"{sec['tw']:g}", FlangeThickness=f"{sec['tf']:g}")
        elif sec["type"] in ("FlatBar", "TBar"):
            bs = ET.SubElement(root, "BarSection", BarSectionId=sid)
            ET.SubElement(bs, "FlatBar", Height=f"{sec['H']:g}", Width=f"{sec['t']:g}")
    gid = 0
    for b in m["blocks"]:
        blk = ET.SubElement(root, "Block", ObjId=b["id"])
        for p in b["panels"]:
            pp = ET.SubElement(blk, "PlanePanel", ObjId=p["id"], **p.get("attrs", {}))
            _coord(pp, p["cs"])
            if p.get("boundary"):
                _cont(ET.SubElement(pp, "Boundary"), "SimpleContour", p["boundary"])
            for pl in p["plates"]:
                gid += 1
                g = ET.SubElement(pp, "PlateGroup", GroupId=str(gid))
                mt = ET.SubElement(g, "Material", Grade=pl.get("grade", "A"))
                ET.SubElement(mt, "Thickness").text = f"{pl['thk']:g}"
                e = ET.SubElement(g, "Plate", CompId="1", Name=pl["name"], Source=pl.get("source", ""))
                _cont(e, "SimpleContour", pl["contour"])
            if p["holes"]:
                gid += 1
                g = ET.SubElement(pp, "HoleGroup", GroupId=str(gid))
                for i, h in enumerate(p["holes"], 1):
                    e = ET.SubElement(g, "Hole", CompId=str(i), Rule=h.get("rule", ""))
                    _cont(e, "Contour", h["contour"])
            for st in p["stiffeners"]:
                sec = m["sections"][st["sec"]]
                gid += 1
                g = ET.SubElement(pp, "StiffenerGroup", GroupId=str(gid), BendType="Straight")
                mt = ET.SubElement(g, "Material", Grade=st.get("grade", "A"))
                bs = ET.SubElement(mt, "BarShape", BarSectionId=st["sec"], BarType="31" if sec["type"] == "LBar" else "10")  # FlatBar / TBar = 10
                keys = {"LBar": ("H", "W", "tw", "tf"), "FlatBar": ("H", "t"), "TBar": ("H", "t", "wf", "tf")}[sec["type"]]
                ET.SubElement(bs, "Parameters").text = " ".join(f"{sec[k]:g}" for k in keys)
                _cont(bs, "Crossection", _crossection(sec))
                e = ET.SubElement(g, "Stiffener", CompId="1", Name=st["name"], Kind=st.get("kind", ""),
                                  Evidence=st.get("evidence", ""))
                _cont(e, "Trace", st["trace"])
                inc = ET.SubElement(e, "Inclination")
                for _ in range(2):
                    ET.SubElement(inc, "Vector3d", U=_f(st["incl"][0]), V=_f(st["incl"][1]), W=_f(st["incl"][2]))
                wf = derive_web_flange(p["cs"], st, sec)
                w = ET.SubElement(e, "Web", MaterialDirection="Positive")
                _coord(w, wf["web"])
                L, H = wf["web"]["ext"]
                _cont(w, "DetailedContour", [[0, 0], [L, 0], [L, H], [0, H], [0, 0]])
                if wf["flange"]:
                    f_ = wf["flange"]
                    fl = ET.SubElement(e, "Flange1", MaterialDirection="Negative",
                                       **({"Thickness": f"{f_['tf']:g}"} if sec["type"] == "TBar" else {}))
                    _coord(fl, f_)
                    L, Wd = f_["ext"]
                    if sec["type"] == "LBar":
                        tw = f_["tw"]
                        _cont(fl, "DetailedContour", [[0, tw], [L, tw], [L, Wd], [0, Wd], [0, tw]])
                    else:
                        _cont(fl, "DetailedContour", [[0, -Wd], [L, -Wd], [L, Wd], [0, Wd], [0, -Wd]])
            for br in p["brackets"]:
                gid += 1
                g = ET.SubElement(pp, "BracketGroup", GroupId=str(gid))
                mt = ET.SubElement(g, "Material", Grade=br.get("grade", "A"))
                ET.SubElement(mt, "Thickness").text = f"{br['thk']:g}"
                e = ET.SubElement(g, "Bracket", CompId="1", Name=br["name"], Source=br.get("source", ""))
                _coord(e, br["cs"])
                _cont(e, "SimpleContour", br["contour"])
                ET.SubElement(e, "End1")
                e2 = ET.SubElement(e, "End2")
                if br.get("end2"):
                    ET.SubElement(e2, "ModelRef", **br["end2"])
    ET.indent(root, space="  ")
    xml = ET.tostring(root, encoding="unicode", xml_declaration=False)
    xml = "<?xml version='1.0' encoding='utf-8'?>\n" + xml
    if path:
        open(path, "w", encoding="utf-8").write(xml)
    return xml


def roundtrip(path, quiet=False):
    """parse -> emit -> parse; compares compact data and the derived Web/Flange with the original XML."""
    import tempfile
    A = xml_to_members(path)
    tmp = tempfile.mktemp(suffix=".xml")
    members_to_xml(A, tmp)
    B = xml_to_members(tmp)
    os.remove(tmp)

    def canon(o):
        if isinstance(o, float): return round(o, 4)
        if isinstance(o, dict): return {k: canon(v) for k, v in o.items() if not k.startswith("_")}
        if isinstance(o, list): return [canon(x) for x in o]
        return o
    same = canon(A["blocks"]) == canon(B["blocks"])
    ok = bad = 0
    bad_list = []
    for b in A["blocks"]:
        for p in b["panels"]:
            for st in p["stiffeners"]:
                d = derive_web_flange(p["cs"], st, A["sections"][st["sec"]])
                w = st["_web"]
                good = all(abs(d["web"][k][i] - w[k][i]) < 1e-3 for k in ("origin", "waxis", "uaxis") for i in range(3))
                good = good and abs(d["web"]["ext"][0] - w["ext"][0]) < 1.0 and abs(d["web"]["ext"][1] - w["ext"][1]) < 1e-3
                if d["flange"] and "_flange" in st:
                    f = st["_flange"]
                    good = good and all(abs(d["flange"][k][i] - f[k][i]) < 1e-3 for k in ("origin", "uaxis") for i in range(3))
                    good = good and all(abs(abs(d["flange"]["waxis"][i]) - abs(f["waxis"][i])) < 1e-3 for i in range(3))
                if good: ok += 1
                else:
                    bad += 1
                    if len(bad_list) < 5: bad_list.append(st["name"])
    res = {"file": os.path.basename(path), "compact_roundtrip_equal": same, "web_flange_match": ok,
           "web_flange_mismatch": bad, "mismatch_examples": bad_list, "unsupported_elements": A["unsupported"]}
    if not quiet:
        print(json.dumps(res, indent=2))
    return res


# ================================================================== validation
def _closed(pts):
    return len(pts) >= 4 and math.dist(pts[0], pts[-1]) < 1e-6 and all(math.isfinite(c) for p in pts for c in p)


def _pt_seg(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    L2 = dx * dx + dy * dy
    t = 0.0 if L2 < 1e-12 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L2))
    q = (a[0] + t * dx, a[1] + t * dy)
    return math.dist(p, q), q


def _inside(p, poly):
    c = False
    for i in range(len(poly) - 1):
        (x1, y1), (x2, y2) = poly[i], poly[i + 1]
        if (y1 > p[1]) != (y2 > p[1]) and p[0] < (x2 - x1) * (p[1] - y1) / (y2 - y1) + x1:
            c = not c
    return c


def check_table(t, tol=TOL_GAP):
    """t = compact table {"outline": [[u,v]..], "members": [{"id","a","b",...}], "holes": optional}. Returns findings."""
    out = []
    outline = t.get("outline") or []
    if outline and not _closed(outline):
        out.append(("C3", "outline is not closed / has non-finite values", None))
    ids = [m["id"] for m in t["members"]]
    for i in sorted({x for x in ids if ids.count(x) > 1}):
        out.append(("C4", f"duplicate id {i}", i))
    segs = []
    if outline and _closed(outline):
        segs += [(outline[i], outline[i + 1]) for i in range(len(outline) - 1)]
    for h in t.get("holes", []):
        segs += [(h[i], h[i + 1]) for i in range(len(h) - 1)]
    for m in t["members"]:
        for end, p in (("a", m["a"]), ("b", m["b"])):
            best, bq = 1e18, None
            for s, e in segs:
                d, q = _pt_seg(p, s, e)
                if d < best: best, bq = d, q
            for o in t["members"]:
                if o is m: continue
                d, q = _pt_seg(p, o["a"], o["b"])
                if d < best: best, bq = d, q
            if best > tol:
                out.append(("C5", f"gap {m['id']} end {end}: nearest support {best:.1f} mm away at ({bq[0]:.0f}, {bq[1]:.0f})" if bq else f"gap {m['id']} end {end}: no support", m["id"]))
            if outline and _closed(outline) and not _inside(p, outline):
                dd = min(_pt_seg(p, s, e)[0] for s, e in segs[:len(outline) - 1])
                if dd > TOL_IN:
                    out.append(("C6", f"{m['id']} end {end} is {dd:.1f} mm outside the outline", m["id"]))
    return out


def panel_to_table(p, sections=None, names=True):
    r = lambda pt: [round(pt[0]), round(pt[1])]
    outline = p["boundary"] or (p["plates"][0]["contour"] if p["plates"] else [])
    mem = []
    for i, s in enumerate(p["stiffeners"], 1):
        nm = s["name"] or ""
        sid = nm.split("/")[-1] if "/" in nm else (nm or f"S{i}")
        mem.append({"id": sid, "kind": s["kind"], "sec": s["sec"], "a": r(s["trace"][0]), "b": r(s["trace"][1])})
    return {"outline": [r(q) for q in outline], "holes": [[r(q) for q in h["contour"]] for h in p["holes"]],
            "members": mem}


def validate_file(path, verbose=True):
    M = xml_to_members(path)
    rep = {"file": os.path.basename(path), "hard": [], "gaps": 0, "members": 0, "panels": 0}
    if M["attrs"].get("GeometryConvention") != "MouldedLine":
        rep["hard"].append("C1 GeometryConvention is not MouldedLine")
    if "MaterialSide" in open(path, encoding="utf-8").read():
        rep["hard"].append("C2 MaterialSide element present")
    names = set()
    for b in M["blocks"]:
        for p in b["panels"]:
            rep["panels"] += 1
            for c in [p["boundary"]] + [pl["contour"] for pl in p["plates"]] + [h["contour"] for h in p["holes"]]:
                if c and not _closed(c):
                    rep["hard"].append(f"C3 open contour in {p['id']}")
            for n in [pl["name"] for pl in p["plates"]] + [s["name"] for s in p["stiffeners"]]:
                if n in names: rep["hard"].append(f"C4 duplicate name {n}")
                names.add(n)
            if p["stiffeners"] and not p["attrs"].get("Kind"):
                t = panel_to_table(p)
                rep["members"] += len(t["members"])
                for code, msg, _ in check_table(t):
                    if code == "C5": rep["gaps"] += 1
                    elif code in ("C6",): rep["hard"].append(f"{p['id']}: {msg}")
    rep["ok"] = not rep["hard"]
    if verbose:
        print(json.dumps(rep, indent=2))
    return rep


# ===================================================================== rules
ID_RE = re.compile(r"^\s*[-*]\s*\**((?:R-?[A-Z]*\d+[\w.\-]*|P\d+)(?:\s*[/,]\s*(?:R-?)?[A-Z]*\d+[\w.]*)*)\**[:\s]\s*(.+)$")
ROW_RE = re.compile(r"^\|\s*(R-[^|]+?)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$")


def _read_sources(src):
    texts = {}
    for f in os.listdir(src):
        p = os.path.join(src, f)
        if f.lower().endswith(".md"):
            texts[f] = open(p, encoding="utf-8", errors="ignore").read()
        elif f.lower().endswith(".zip"):
            with zipfile.ZipFile(p) as z:
                for n in z.namelist():
                    base = os.path.basename(n)
                    if base in ("RULES.md", "ONLINE_METHOD_RULES.md") and base not in texts:
                        texts[base] = z.read(n).decode("utf-8", "ignore")
    return texts


def parse_rules(texts):
    entries, seen = [], set()
    for fname, txt in texts.items():
        sec, cur = "", None
        def flush():
            nonlocal cur
            if cur and len(cur["text"]) >= 25 and (cur["id"], cur["text"][:80]) not in seen:
                seen.add((cur["id"], cur["text"][:80]))
                cur["text"] = cur["text"][:1500]
                entries.append(cur)
            cur = None
        for line in txt.splitlines():
            if line.startswith("#"):
                flush(); sec = line.lstrip("# ").strip()[:90]; continue
            m = ROW_RE.match(line)
            if m and not m.group(1).startswith("Rule"):
                flush()
                cur = {"id": m.group(1).strip(), "section": sec, "file": fname, "text": f"{m.group(2)} (implemented in: {m.group(3)})"}
                flush(); continue
            m = ID_RE.match(line)
            if m:
                flush(); cur = {"id": re.sub(r"\s+", "", m.group(1)), "section": sec, "file": fname, "text": m.group(2).strip()}
                continue
            if cur and line.startswith("  ") and line.strip() and not line.lstrip().startswith(("-", "*", "|")):
                cur["text"] += " " + line.strip()
            else:
                flush()
        flush()
    return clean_rules(entries)


# rules that a later owner decision replaced: never retrieved, never trained (the model must not learn both)
SUPERSEDED = {
    "R-G1b": "R-PN1 (v2.149): members penetrate girders; cutting only as the option penetrate=False",
    "R-APP3": "R-APP3b / R-APP4 (the grey-image cause was wrong; real cause Paddle oneDNN)",
}


def clean_rules(entries):
    """keep only the CURRENT text of every rule: superseded ids are dropped, and when one file states the same id several times
    (versions v2.145 -> v2.148 ...) only the last statement in that file is kept"""
    last = {}
    for i, e in enumerate(entries):
        last[(e["file"], e["id"])] = i
    out = [e for i, e in enumerate(entries) if last[(e["file"], e["id"])] == i and e["id"] not in SUPERSEDED]
    return out


_tok = lambda s: re.findall(r"[a-z0-9][a-z0-9.\-]*", s.lower())


class RuleIndex:
    """Tiny BM25 over rule entries. Use at run time: put the top-k rules into the model's prompt (RAG)."""
    def __init__(self, entries):
        self.e = entries
        self.tf = [self._count(_tok(x["id"] + " " + x["section"] + " " + x["text"])) for x in entries]
        self.len = [sum(t.values()) for t in self.tf]
        self.avg = sum(self.len) / max(1, len(self.len))
        df = {}
        for t in self.tf:
            for w in t: df[w] = df.get(w, 0) + 1
        n = len(entries)
        self.idf = {w: math.log(1 + (n - d + 0.5) / (d + 0.5)) for w, d in df.items()}

    @staticmethod
    def _count(ws):
        c = {}
        for w in ws: c[w] = c.get(w, 0) + 1
        return c

    def search(self, q, k=5):
        qs = _tok(q)
        sc = []
        for i, t in enumerate(self.tf):
            s = 0.0
            for w in qs:
                if w in t:
                    f = t[w]
                    s += self.idf.get(w, 0) * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * self.len[i] / self.avg))
            sc.append((s, i))
        return [self.e[i] | {"score": round(s, 3)} for s, i in sorted(sc, reverse=True)[:k] if s > 0]


# ================================================================ note reading
def parse_angle(s):
    """'150X90X9 U.A' -> LBar150*90*9*9 ; '300X90X11X16 I.A' / '200X90X10/14 I.A' -> LBar300*90*11*16 ; '150X10 F.B' -> FlatBar150*10"""
    s = s.upper().replace(" ", "")
    m = re.match(r"(\d+)X(\d+)X(\d+)(?:[X/](\d+))?(?:U\.A|I\.A)$", s)
    if m:
        H, W, tw = int(m.group(1)), int(m.group(2)), int(m.group(3))
        tf = int(m.group(4)) if m.group(4) else tw
        return f"LBar{H}*{W}*{tw}*{tf}"
    m = re.match(r"(\d+)X(\d+)F\.B$", s)
    if m:
        return f"FlatBar{m.group(1)}*{m.group(2)}"
    return None


ANGLES = [("150X90X9", "U.A"), ("125X75X7", "U.A"), ("200X90X10/14", "I.A"), ("300X90X11X16", "I.A"), ("150X90X9", "U.A")]
FLATS = ["100X10", "150X10", "75X10", "75X12", "125X10", "200X10", "450X10"]
TEES = [("500", "10", "150", "12"), ("435", "10", "150", "12"), ("450", "10", "150", "12")]


def note_case(r):
    lines, js = [], {}
    t = r.choice([6, 7, 8, 9, 10, 12])
    lines.append(f"DECK PLATE THK. : {t}.0 (EXC. AS SHOWN)"); js["plate_thk_mm"] = t
    if r.random() < 0.9:
        a = r.choice(ANGLES); lines.append(f"DECK BEAM : {a[0]} {a[1]}"); js["deck_beam"] = parse_angle(f"{a[0]}{a[1]}")
    if r.random() < 0.6:
        a = r.choice(ANGLES[2:4]); lines.append(f"DECK GIR. & WEB : {a[0]} {a[1]}"); js["girder_web"] = parse_angle(f"{a[0]}{a[1]}")
    if r.random() < 0.5:
        w, tw, f, tf = r.choice(TEES)
        lines.append(f"DEEP GIR. : {w}X{tw}+{f}X{tf} F.B(T)")
        js["deep_girder"] = {"web": f"FlatBar{w}*{tw}", "flange": f"FlatBar{f}*{tf}"}
    if r.random() < 0.5:
        n = r.choice([1, 2, 3, 4]); fb = r.choice(FLATS)
        lines.append(f"CARLING #{n} : {fb} F.B"); js.setdefault("carling_table", {})[f"#{n}"] = parse_angle(f"{fb}F.B")
    sp = r.choice([800, 800, 800, 650, 1540, 1600])
    lines.append(f"FRAME SPACE : {sp}mm"); js["frame_space_mm"] = sp
    if r.random() < 0.3:
        c = r.choice([50, 100]); lines.append(f"(CAMBER : {c})"); js["camber_mm"] = c
    return lines, js


def render_notes(lines, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle
    fig = plt.figure(figsize=(5.2, 0.55 + 0.42 * len(lines)), dpi=100)
    ax = fig.add_axes([0.01, 0.02, 0.98, 0.96]); ax.axis("off")
    ax.add_patch(Rectangle((0, 0), 1, 1, fill=False, lw=1.1, transform=ax.transAxes))
    ax.text(0.03, 0.95, "NOTES", fontsize=8, va="top", fontweight="bold", transform=ax.transAxes)
    for i, l in enumerate(lines):
        ax.text(0.04, 0.84 - i * (0.78 / max(6, len(lines))), l, fontsize=8, va="top", transform=ax.transAxes, family="DejaVu Sans")
    fig.savefig(path); plt.close(fig)


# ======================================================= review table builder
def _clusters(p, r, kmax=10):
    st = p["stiffeners"]
    if len(st) < 3: return None
    t = panel_to_table(p)
    mem = t["members"]
    seed = r.randrange(len(mem)); chosen = [seed]
    def touch(i, j):
        return any(_pt_seg(q, mem[j]["a"], mem[j]["b"])[0] <= TOL_GAP for q in (mem[i]["a"], mem[i]["b"])) or \
               any(_pt_seg(q, mem[i]["a"], mem[i]["b"])[0] <= TOL_GAP for q in (mem[j]["a"], mem[j]["b"]))
    k = r.randint(3, kmax)
    frontier = [seed]
    while frontier and len(chosen) < k:
        c = frontier.pop(0)
        for j in range(len(mem)):
            if j not in chosen and touch(c, j):
                chosen.append(j); frontier.append(j)
                if len(chosen) >= k: break
    if len(chosen) < 3: return None
    return {"outline": t["outline"], "holes": t["holes"], "members": [dict(mem[i]) for i in chosen]}


def _inject(t, r):
    kind = r.choice(["shift", "shift", "dup", "outside", "open", "none", "none"])
    m = t["members"]
    if kind == "shift":
        x = r.choice(m); e = r.choice("ab"); o = x["b" if e == "a" else "a"]
        dx, dy = x[e][0] - o[0], x[e][1] - o[1]; L = math.hypot(dx, dy) or 1
        d = r.choice([8, 12, 20, 35, 60]); x[e] = [round(x[e][0] - dx / L * d), round(x[e][1] - dy / L * d)]
    elif kind == "dup" and len(m) > 1:
        a, b = r.sample(m, 2); b["id"] = a["id"]
    elif kind == "outside":
        x = r.choice(m); s = r.choice([300, 500, -300]); 
        x["a"] = [x["a"][0] + s, x["a"][1]]; x["b"] = [x["b"][0] + s, x["b"][1]]
    elif kind == "open" and len(t["outline"]) > 4:
        t["outline"] = t["outline"][:-1]
    return kind


def review_answer(findings):
    if not findings:
        return "No violations: outline closed, ids unique, every end is supported within 3 mm and inside the outline."
    lines = [f"{c}: {msg}" for c, msg, _ in sorted(findings, key=lambda f: (f[0], f[1]))]
    if len(lines) > 10:
        lines = lines[:10] + [f"(+{len(lines) - 10} more)"]
    return "\n".join(lines)


# ============================================================= sample writer
RULE_Q1 = ["What does rule {id} say?", "Explain universal rule {id} of the deckrules rule book.", "Rule {id}: what is the requirement?"]
RULE_Q2 = ["Which rule of the rule book covers this: \"{s}\"? Give the rule id and its text."]
REVIEW_Q = ("Check this member table (units mm, panel UV) against the rules: closed outline (C3), unique ids (C4), "
            "no gap - every member end within 3 mm of the outline, a hole, or another member (C5), inside the outline (C6). "
            "List the violations.\n")
NOTE_Q = "Read the sheet notes and return JSON: plate thickness, deck beam, girder/web, deep girder, carling table, frame space, camber (only what is printed)."


def make_ship_samples(src, out, r, n=300, scan_fn=None, scan_p=0.4):
    from pathlib import Path
    out = Path(out); (out / "images").mkdir(parents=True, exist_ok=True)
    counts = {}
    texts = _read_sources(src)
    entries = parse_rules(texts)
    idx = RuleIndex(entries)
    json.dump(entries, open(out / "rules_index.json", "w"))
    with open(out / "dataset.jsonl", "a") as f:
        def rec(kind, img, prompt, ans):
            if len(prompt) + len(ans) > 5000:           # would be cut by max_length 2048 tokens in training -> not written
                counts["skipped_too_long"] = counts.get("skipped_too_long", 0) + 1
                return False
            content = ([{"type": "image"}] if img else []) + [{"type": "text", "text": prompt}]
            f.write(json.dumps({"image": img, "part": kind, "messages": [
                {"role": "user", "content": content},
                {"role": "assistant", "content": [{"type": "text", "text": ans}]}]}) + "\n")
            counts[kind] = counts.get(kind, 0) + 1
            return True
        # --- rules
        # EVERY rule of the rule book is asked at least once in both directions (id -> text, text -> id); then random repeats up to n
        pool = list(entries)
        r.shuffle(pool)
        look = pool + [r.choice(pool) for _ in range(max(0, n - len(pool)))]
        find = pool + [r.choice(pool) for _ in range(max(0, n - len(pool)))]
        for e in look:
            rec("ship_rule_lookup", None, r.choice(RULE_Q1).format(id=e["id"]), f"{e['id']} ({e['section']}): {e['text']}")
        for e in find:
            s = e["text"][:140].rsplit(" ", 1)[0]
            rec("ship_rule_find", None, RULE_Q2[0].format(s=s), f"{e['id']} ({e['section']}): {e['text']}")
        # --- notes (image)
        for i in range(n):
            lines, js = note_case(r)
            img = f"images/n{i:05d}.png"
            render_notes(lines, out / img)
            if scan_fn: scan_fn(out / img, r, scan_p)
            rec("ship_notes", img, NOTE_Q, json.dumps(js))
        # --- review tables
        panels = []
        for fn in sorted(os.listdir(src)):
            if fn.lower().endswith(".xml"):
                M = xml_to_members(os.path.join(src, fn))
                panels += [p for b in M["blocks"] for p in b["panels"] if len(p["stiffeners"]) >= 3 and not p["attrs"].get("Kind")]
        made = tries = 0
        while panels and made < n and tries < n * 20:
            tries += 1
            t = _clusters(r.choice(panels), r)
            if not t: continue
            _inject(t, r)
            rec("ship_review", None, REVIEW_Q + json.dumps(t, separators=(",", ":")), review_answer(check_table(t)))
            made += 1
        # --- online method: OCR fixes, R2.1 numbers, labels, joints, 6 steps, member JSON, review incl. PN1/PN4 (ship_online.py)
        try:
            from ship_online import make_online_samples
            xmls = [os.path.join(src, fn) for fn in sorted(os.listdir(src)) if fn.lower().endswith(".xml")]
            make_online_samples(rec, r, n, xmls, entries)
        except ImportError:
            print("ship_online.py not found - online-method tasks skipped")
        # --- REAL drawing tiles paired with the reference XML members (ship_pairs.py, needs ship_src/views.json + PDFs + pymupdf)
        try:
            from ship_pairs import load_views, make_pair_samples
            from ship_online import core_rules
            views = load_views(src)
            if views:
                make_pair_samples(rec, r, views, str(out), max(n, 5000), core_rules(entries))   # every registered tile is used (real drawings are the scarce data)
        except ImportError as e:
            print("drawing pairs skipped:", e)
    print(f"Ship: {counts}  ({len(entries)} rules indexed)")
    return counts


# ================================================================ run deckrules
def run_deckrules(pdf, out, settings=None, tool_dir=".", extra=()):
    """Runs the offline tool:  python -m deckrules.build_ship PDF --settings S --out OUT   (needs the deckrules folder + pymupdf, shapely, lxml)."""
    cmd = [sys.executable, "-m", "deckrules.build_ship", pdf, "--out", out]
    if settings: cmd += ["--settings", settings]
    cmd += list(extra)
    return subprocess.run(cmd, cwd=tool_dir, capture_output=True, text=True)


# ========================================================================= CLI
if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["roundtrip", "validate", "retrieve", "build-data"])
    ap.add_argument("arg", nargs="?")
    ap.add_argument("--src", default="ship_src")
    ap.add_argument("--out", default="ship_data")
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--k", type=int, default=5)
    a = ap.parse_args()
    if a.cmd == "roundtrip": roundtrip(a.arg)
    elif a.cmd == "validate": validate_file(a.arg)
    elif a.cmd == "retrieve":
        for e in RuleIndex(parse_rules(_read_sources(a.src))).search(a.arg, a.k):
            print(f"[{e['score']}] {e['id']} ({e['section']}): {e['text'][:300]}\n")
    else:
        os.makedirs(a.out, exist_ok=True)
        open(os.path.join(a.out, "dataset.jsonl"), "w").close()
        make_ship_samples(a.src, a.out, random.Random(0), a.n)
