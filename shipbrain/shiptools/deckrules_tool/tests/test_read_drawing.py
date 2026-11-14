from deckrules import read_drawing as r


def test_assign_note_nearest():
    v, d = r.assign_note((100, 100), [('A PLAN', 90, 50), ('B PLAN', 500, 100)])
    assert v == 'A PLAN' and d == 51
    assert r.assign_note((0, 0), []) == (None, None)
