"""R-DN1 (2026-10-26, 1004 ERM): one deck identity for plans, elevation / section labels and heights, read from the deck NAME as
written ('UPPER DECK', 'E/R 2ND DECK', '2ND DECK', 'NO.1 STR.', 'A - DECK', 'WEATHER SHIELD', 'TANK TOP', '4TH DECK ...').
The old code used the first letter of the name, which made 'E/R 2ND DECK', 'E/R 3RD DECK' and 'E/R 4TH DECK' one deck 'E' and
did not know '2ND DECK' / 'UPPER DECK' at all. Codes of the earlier drawings are unchanged (A, B, C, D, NAV, COMP, UPP, S1.., W)."""
import re

_SKIP = re.compile(r'PLATE|THK|LONGL|BEAM|GIR|HEIGHT|CAMBER|SEE |EXC|TRANS|STIFF|SPACE|PLAN HISTORY|ARR', re.I)
_DECKY = re.compile(r'DECK|STR\b|STR\.|STRINGER|SHIELD|TANK\s*TOP|\bFLAT\b|PLATFORM', re.I)


def key(text):
    """deck code of a deck name / label, or None when the text is not a deck name"""
    t = text.upper().strip()
    t = re.sub(r'\(\s*\d[\d,]*\s*A/B\s*\)|\d{4,6}\s*A/B', '', t)
    t = re.sub(r'\bPLAN\b.*$', '', t).strip(' .-()')
    if not t or len(t) > 32 or _SKIP.search(t) or not _DECKY.search(t):
        return None
    m = re.match(r'^NO\.?\s*(\d{1,2})\s*STR(?:INGER|\.)?$', t)
    if m:
        return 'S' + m.group(1)
    if re.match(r'^WEATHER\s*SHIELD$', t):
        return 'W'
    if re.match(r'^NAV(?:IGATION|\.)?\s*\.?\s*-?\s*(?:BRIDGE\s*)?DECK$', t):
        return 'NAV'
    if re.match(r'^COMP(?:ASS|\.)?\s*\.?\s*-?\s*DECK$', t):
        return 'COMP'
    if re.match(r'^UPP(?:ER|\.)?\s*\.?\s*-?\s*DECK$', t):
        return 'UPP'
    m = re.match(r'^([A-H])\s*\.?\s*-?\s*DECK$', t)
    if m:
        return m.group(1)
    if re.match(r'^E/C\s+MONORAIL', t):
        return 'E'
    k = re.sub(r'\bDECK\b', '', t)
    k = re.sub(r'[^A-Z0-9]', '', k)
    return k or None
