"""R2.1 (online rule book v2.3, owner 2026-11-03 'thickness finding shows welding thickness, not structure thickness').
Every number is classified before use. A WELD SIZE is never a plate / structure thickness. A thickness-looking number ('6.0', '12.0 "AH"')
is a weld size when:
  a) its own text carries a weld prefix / suffix: 'F6', 'F 6.0', 'L6', 'Z6', 'a6', 'FW6', '6.0F', 'D/F', 'S/F', 'F.P', 'TYP.' in the same word;
  b) a weld word stands close by on the sheet (WELD / WELDING / FILLET / F.P / PENETRATION / BEVEL / LEG / THROAT, or a weld-symbol text such as 'D/F'),
     within R pt of the number (weld callouts are short leader texts, so the radius is small);
  c) it sits inside a DETAIL / TYP. view box of welding (the view title holds WELD).
The check is geometric and textual only - it does not depend on one drawing."""
import re

WELD_IN_WORD = re.compile(r'^\s*(?:F\.?W?|L|Z|a|D/F|S/F)\s*\d|\d\s*(?:F|FW)\s*$|\bTYP\.?|D/F|S/F|F\.P\b|F/P\b', re.I)
WELD_NEAR = re.compile(r'WELD|FILLET|\bF\.P\b|F/P|PENETRATION|BEVEL|\bLEG\b|THROAT|D/F|S/F|\bGRIND', re.I)
R = 18.0          # pt at sheet scale (about two text heights)


def weld_word(w):
    return bool(WELD_IN_WORD.search(w.text or ''))


def is_weld_size(w, words, r=R):
    """True when word w (a number that looks like a thickness) is a weld size by rule R2.1 a/b."""
    if weld_word(w):
        return True
    for o in words:
        if o is w or not WELD_NEAR.search(o.text or ''):
            continue
        if re.search(r'THK|PLATE', o.text or '', re.I):
            continue                     # a plate-thickness note that also mentions welding is not a weld callout
        b = getattr(o, 'bbox', None) or (o.cx, o.cy, o.cx, o.cy)
        dx = max(b[0] - w.cx, 0, w.cx - b[2]); dy = max(b[1] - w.cy, 0, w.cy - b[3])
        if dx <= r and dy <= r:
            return True
    return False
