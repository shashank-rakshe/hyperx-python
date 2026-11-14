"""R5.10 detection report (owner 2026-11-05 'why rules fail offline vs online'): a rule can only act on what Step 1/2 FOUND.
For every rule that keys on a printed token, count the tokens on the sheet and the places the built XML used that rule.
Printed > 0 and used = 0 means the rule never fired: the token was not linked to geometry (too far, wrong view, OCR spelling) ->
it becomes a QUESTION with the page and position, so it is checked instead of being lost silently."""
import re
from lxml import etree

TOKENS = {   # rule: (printed-token regex on a short word, regex of the rule tag written in the XML Source / Evidence)
    'R2.13 S.W line = other wall': (r'^\s*S\.W\.?\s*$', None),
    'R3.6 K.L knuckle': (r'^\s*K\.L\.?\s*$', r'R3\.6'),
    'R2.17 door AxB(xR)': (r'^\s*\d{3,4}\s*[Xx]\s*\d{3,4}(\s*[Xx]\s*R?\s*\d{2,3})?\s*$', r'R2\.17|R4\.11'),
    'R2.18 #n carling': (r'^\s*#\s*\d?\s*$', r"R2\.18|carling"),
    'R4.14 corner bracket AxB/t': (r'^\s*\d{2,4}\s*[Xx]\s*\d{2,4}\s*/\s*\d{1,2}(\.\d)?', r'R4\.14'),
    'R2.8 PROVISION FOR / FUTURE': (r'\bPROVISION\s+FOR\b|^\s*FUTURE\b', r'R2\.8'),
    'R2.19 face bar F.B': (r'\d{2,3}\s*[Xx]\s*\d{1,2}(\.\d)?\s*F\.?B', r'R2\.19|F\.B|FlatBar'),
}


def count_sheet(pdf, pages=None):
    import fitz
    from . import pdfsrc
    n = len(fitz.open(pdf))
    out = {k: [] for k in TOKENS}
    for i in range(n) if pages is None else pages:
        try:
            pg = pdfsrc.load_page(pdf, i)
        except Exception:
            continue
        for w in pg.words:
            if len(w.text or '') > 40:
                continue
            for k, (rx, _) in TOKENS.items():
                if re.search(rx, w.text or '', re.I if 'PROVISION' in rx else 0):
                    out[k].append((i + 1, round(w.cx), round(w.cy), w.text.strip()))
    return out


def count_xml(xml_path):
    t = etree.parse(xml_path)
    txt = ' '.join((e.get('Source') or '') + ' ' + (e.get('Evidence') or '') + ' ' + (e.get('BarSectionId') or '') for e in t.iter())
    return {k: (len(re.findall(rx, txt)) if rx else None) for k, (_, rx) in TOKENS.items()}


def report(pdf, xml_path):
    sheet = count_sheet(pdf)
    used = count_xml(xml_path)
    rows, questions = [], []
    for k in TOKENS:
        n, u = len(sheet[k]), used[k]
        rows.append({'rule': k, 'printed': n, 'used_in_xml': u})
        if n and u == 0:
            p, x, y, s = sheet[k][0]
            questions.append(f"R5.10 {k}: printed {n}x on the sheet (first: page {p} at ({x},{y}) '{s}') but never used in the XML - check the link")
    return {'rows': rows, 'questions': questions, 'scan_note': 'scanned pages count only after OCR (raster front end)'}
