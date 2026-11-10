"""P7: runstate.reset() empties every module cache / run table, so no drawing inherits another drawing's state."""
from deckrules import runstate, crossverify, run, view, pdfsrc


def test_reset_clears_state():
    crossverify.ELEV_LONGS.append({'x': 1})
    crossverify._CACHE['k'] = 1
    run._SEC_TITLES['p'] = []
    view.PLAN_HEIGHTS['A'] = 1.0
    view.FRAME_ROW_NEAREST = True
    pdfsrc._PAGES['x'] = 1
    runstate.reset()
    assert not crossverify.ELEV_LONGS and not crossverify._CACHE and not run._SEC_TITLES
    assert not view.PLAN_HEIGHTS and view.FRAME_ROW_NEAREST is False and not pdfsrc._PAGES
