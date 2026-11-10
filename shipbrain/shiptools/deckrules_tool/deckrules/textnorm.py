"""Rule 1 amendment R-T17..R-T19 (Step 1, universal, offline): normalise written LABELS that Step 3 / Step 2 key on.
Idempotent; works on vector and scanned text rows; every change is logged to <name>_textnorm.csv.
 R-T17  'OFFCL', 'OFF CL', '* OFF C.L', '"OFF C.L', 'OFFC.L' -> 'OFF C.L'  (a leading number is kept)
 R-T18  height with a thousands separator '39,170 A/B' / '34.750 A/B' -> '39170 A/B'; a '(' left open before an A/B height is closed
 R-T19  one box that holds several frame labels ('FR.23 FR.24', 'FR.21+500FR.22+800') -> one row per label, box split along the text direction
"""
import csv, os, re, glob

OFF_RX = re.compile(r'^(\s*\d{3,6})?\s*[*"\']*\s*OFF[\s.]*C(?:[./]|\s)*L\.?[*"\']*\s*(.*)$', re.I)
HT_RX = re.compile(r'(?<![\d.,])(\d{1,2})[.,](\d{3})(?=\s*A\s*/\s*B)')
FR_RX = re.compile(r'FR\.\s?\d{1,3}(?:[+-]\d{1,4})?')


def fix_text(t):
    """-> (new_text, rule) ; rule '' when unchanged"""
    s = t
    m = OFF_RX.match(s)
    if m and s.strip().upper() not in ('OFF C.L',) and len(s) < 40:
        rest = m.group(2).strip()
        n = (m.group(1) or '').strip()
        s2 = (n + ' ' if n else '') + 'OFF C.L' + (' ' + rest if rest else '')
        if s2 != s:
            return s2, 'R-T17'
    if HT_RX.search(s):
        s2 = HT_RX.sub(lambda m: m.group(1) + m.group(2), s)
        if s2.count('(') > s2.count(')') and re.search(r'A\s*/\s*B\s*$', s2):
            s2 += ')'
        return s2, 'R-T18'
    if re.search(r'A\s*/\s*B\s*$', s) and s.count('(') > s.count(')'):
        return s + ')', 'R-T18'
    s2 = fix_rule_tokens(s)
    if s2 != s:
        return s2, 'R-T20'
    s2 = fix_note_line(s)
    if s2 != s:
        return s2, 'R-T22'
    return s, ''


# R-T22 (1007 scan): title-block note lines as OCR writes them: words glued ('FRAMESPACE;1600mm', 'DECKBEAM;150X90X9U.A') and ';' for ':'.
_GLUE = [(re.compile(r'FRAME\s*SPACE', re.I), 'FRAME SPACE'), (re.compile(r'DECK\s*BEAM', re.I), 'DECK BEAM'),
         (re.compile(r'DECK\s*PLATE', re.I), 'DECK PLATE'), (re.compile(r'PLATE\s*THK', re.I), 'PLATE THK'),
         (re.compile(r'DECK\s*HEIGHT', re.I), 'DECK HEIGHT'), (re.compile(r'DECK\s*LONGL', re.I), 'DECK LONGL'),
         (re.compile(r'(\d)(U\.A|I\.A|F\.B)\b'), r'\1 \2')]
_NOTE_KEY = re.compile(r'(FRAME SPACE|DECK BEAM|DECK PLATE|PLATE THK\.?|DECK HEIGHT|DECK LONGL\.?|GIR\.\s*&\s*WEB|STIFF\.?(?:\s*SIZE)?)\s*[;:]\s*', re.I)


def fix_note_line(t):
    if not t or len(t) > 70 or not re.search(r'[;:]', t):
        return t
    s = t
    for rx, rep in _GLUE:
        s = rx.sub(rep, s)
    s = _NOTE_KEY.sub(lambda m: m.group(1) + ' : ', s)
    return s


# R-T20 (owner 2026-11-05 'why rules fail offline vs online'): OCR spellings of the tokens the rules key on are normalised, so a rule that
# waits for 'K.L' also fires on 'K L' / 'KL.' / 'K,L'. Only whole short labels are touched (never sentences).
_TOK = [
    (re.compile(r'^\s*K\s*[.,\s]?\s*L\s*[.,]?\s*$', re.I), 'K.L'),
    (re.compile(r'^\s*S\s*[.,\s]?\s*W\s*[.,]?\s*$', re.I), 'S.W'),
    (re.compile(r'^\s*C\s*[.,\s]\s*L\s*[.,]?\s*$', re.I), 'C.L'),
    (re.compile(r'^\s*[#＃]\s*(\d?)\s*[.,]?\s*$'), r'#\1'),
    (re.compile(r'^\s*OFF\s*(?:C\.?|C\.?\s*[|lI1]|\(|C\s*\.\s*\()?\s*$', re.I), 'OFF C.L'),   # R-T21: OCR kept only 'OFF' / 'OFF C.' of 'OFF C.L'
]
_THK_OCR = re.compile(r'^\s*([IlO|\d])(\d)?\s*[.,]\s*([0-9OoD])\s*(("?\s*AH\s*"?)?)\s*$')
_DIG = str.maketrans({'I': '1', 'l': '1', '|': '1', 'O': '0', 'o': '0', 'D': '0'})


def fix_rule_tokens(t):
    """R-T20: 'K L' -> 'K.L', 'S W' -> 'S.W', '# 2' -> '#2', thickness misreads 'I2,0' / '12.O' -> '12.0' (short labels only)"""
    if not t or len(t) > 14:
        return t
    for rx, rep in _TOK:
        if rx.match(t):
            return rx.sub(rep, t).strip()
    m = _THK_OCR.match(t)
    if m:
        a = (m.group(1) + (m.group(2) or '')).translate(_DIG)
        b = m.group(3).translate(_DIG)
        if a.isdigit() and b.isdigit() and 4 <= int(a) <= 60:
            return f'{int(a)}.{b}' + (' "AH"' if m.group(4) else '')
    return t


def split_frames(row):
    """R-T19 -> list of rows (>=2) or None"""
    t = row['text'].strip()
    parts = FR_RX.findall(t)
    if len(parts) < 2 or ''.join(parts).replace(' ', '') != re.sub(r'\s+', '', t):
        return None
    x0, y0, x1, y1 = (float(row[k]) for k in ('x0', 'y0', 'x1', 'y1'))
    dx, dy = float(row.get('dir_x') or 1), float(row.get('dir_y') or 0)
    horiz = abs(dx) >= abs(dy)
    lo, hi = (x0, x1) if horiz else (y0, y1)
    rev = (dx < 0) if horiz else (dy < 0)          # reading direction runs towards smaller coordinate
    n = sum(len(p) for p in parts)
    out, acc = [], 0
    for p in parts:
        a, b = acc / n, (acc + len(p)) / n
        acc += len(p)
        if rev:
            a, b = 1 - b, 1 - a
        r = dict(row)
        r['text'] = p.replace(' ', '')
        if horiz:
            r['x0'], r['x1'] = round(lo + (hi - lo) * a, 2), round(lo + (hi - lo) * b, 2)
        else:
            r['y0'], r['y1'] = round(lo + (hi - lo) * a, 2), round(lo + (hi - lo) * b, 2)
        r['source'] = (row.get('source') or '') + '+split'
        out.append(r)
    return out


def fix_rows(rows):
    out, log = [], []
    for r in rows:
        sp = split_frames(r)
        if sp:
            log.append((r['text'], '|'.join(x['text'] for x in sp), 'R-T19'))
            out += sp
            continue
        t2, rule = fix_text(r['text'])
        if rule:
            log.append((r['text'], t2, rule))
            r = dict(r, text=t2)
        out.append(r)
    return out, log


def fix_folder(folder, name):
    """rewrite every <name>_pN_text.csv in place; write <name>_textnorm.csv (page, before, after, rule). -> number of changes"""
    total = []
    for fp in sorted(glob.glob(os.path.join(folder, glob.escape(name) + '_p*_text.csv'))):
        m = re.search(r'_p(\d+)_text\.csv$', fp)
        if not m or os.path.basename(fp)[:-len(m.group(0))] != name:
            continue
        with open(fp, newline='', encoding='utf-8') as f:
            rd = csv.DictReader(f)
            cols = rd.fieldnames
            rows = list(rd)
        new, log = fix_rows(rows)
        if log:
            with open(fp, 'w', newline='', encoding='utf-8') as f:
                w = csv.DictWriter(f, cols)
                w.writeheader()
                w.writerows(new)
        total += [(m.group(1),) + l for l in log]
    with open(os.path.join(folder, name + '_textnorm.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['page', 'before', 'after', 'rule'])
        w.writerows(total)
    return len(total)


if __name__ == '__main__':
    import sys
    fol = sys.argv[1]
    names = sorted({re.sub(r'_p\d+_text\.csv$', '', os.path.basename(f)) for f in glob.glob(os.path.join(fol, '*_p*_text.csv')) if re.search(r'_p\d+_text\.csv$', f)})
    for n in names:
        print(n[:40], fix_folder(fol, n))
