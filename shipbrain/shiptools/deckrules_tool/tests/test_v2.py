from deckrules.pdfsrc import Word
from deckrules.raster_front import merge_pieces


def test_offcl_pieces_merge():
    a = Word('OFF', (2711, 4409, 2736, 4462), 18, True)
    b = Word('C.L', (2713, 4374, 2735, 4414), 18, True)
    n = Word('13910', (2690, 4194, 2714, 4256), 18, True)
    out = merge_pieces([a, b, n])
    assert sorted(w.text for w in out) == ['13910', 'OFF C.L']
