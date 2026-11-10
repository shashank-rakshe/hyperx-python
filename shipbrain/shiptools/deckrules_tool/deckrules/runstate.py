"""P7 (review 2026-10-26): no state may carry over from one drawing / run to the next in the same process. Every module-level cache
and run table is listed here and emptied by reset(), which deckrules.run and deckrules.build_ship call at the start of a run.
Settings are read per run (run.load_settings); module switches set from them (view.FRAME_ROW_NEAREST, view.PLAN_HEIGHTS) are
reset to their defaults here first, so a drawing never inherits another drawing's settings."""
import importlib

STATE = {
    'crossverify': ['_CACHE', 'ELEV_LONGS', 'ELEV_BKTS', 'SEC_SIDEON', 'SEC_WEBS', 'ELEV_WALLS', 'DECKS', '_IDX', 'WALLPLANS'],
    'deckplan': ['_LT'],
    'details': ['_CACHE', 'USED', 'ALL'],
    'elevation': ['_CALLOUT_CACHE', 'BKT_TABLE'],
    'bkttable': ['_CACHE'],
    'members': ['GLOBAL_CARL', '_SHEET_CARL', '_MARK_TAB'],
    'pdfsrc': ['_PAGES'],
    'read_drawing': ['RAW', 'OCRR', 'SCANSEG'],
    'rule2': ['VIEWS', 'INDEX'],
    'run': ['_LONGI_CACHE', '_SEC_TITLES'],
    'run_elev': ['DECK_Z_SOURCE', '_DH'],
    'section': ['DERIVED', 'REBASE'],
    'view': ['PLAN_HEIGHTS', '_CAMBER', 'ASK', 'DETAILS'],
    'openitems': ['ERRORS'],
    'longlno': ['_CACHE'],
}


def reset():
    n = 0
    for mod, names in STATE.items():
        try:
            m = importlib.import_module('deckrules.' + mod)
        except Exception:
            continue
        for nm in names:
            obj = getattr(m, nm, None)
            if hasattr(obj, 'clear'):
                obj.clear()
                n += 1
    try:
        from . import view
        view.FRAME_ROW_NEAREST = False
    except Exception:
        pass
    try:
        from . import connect
        connect.TABLE.update({'beams': [], 'brackets': [], 'links': [], 'girders': [], 'n_snapped': 0, 'log': []})
    except Exception:
        pass
    return n
