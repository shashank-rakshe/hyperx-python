import pytest
from shipbrain import parts as P, connections as C


def test_ipe300_and_i_section_properties():
    r = P.get('ibeam_ipe', 'IPE 300')
    assert (r['h'], r['b'], r['tw'], r['tf'], r['r']) == (300, 150, 7.1, 10.7, 15)
    pr = P.section_properties(r)
    assert pr['A_mm2'] == pytest.approx(5381, rel=0.005)            # catalogue 53.8 cm2
    assert pr['Iy_mm4'] == pytest.approx(8356e4, rel=0.005)         # 8356 cm4
    assert pr['mass_kg_per_m'] == pytest.approx(42.2, rel=0.005)


def test_every_section_in_connections_matches_bolts():
    for name, (h, b, tw, tf) in C.SECTIONS.items():
        fam = ''.join(ch for ch in name if ch.isalpha()).lower()
        r = P.get('ibeam_' + fam, name)
        assert (r['h'], r['b'], r['tw'], r['tf']) == (h, b, tw, tf), name


def test_hex_bolt_dimensions_by_standard_name():
    r = P.get('ISO 4017', 'M20', l=60)
    assert (r['s'], r['k'], r['d1'], r['l']) == (30, 12.5, 20, 60)
    assert P.get('DIN 933', 'M20', l=60)['s'] == 30
    for d, v in C.BOLTS.items():                                    # across flats / head height used by the connection checks
        if d != 22:                                                 # ISO 272 reduced M22 to 32 mm; the old table has the DIN 34
            r = P.get('ISO 4017', f'M{d}', l=60)
            assert (r['s'], r['k']) == (v[0], v[1]), d


def test_nut_and_imperial_pipe():
    assert P.get('ISO 4032', 'M24')['s'] == 36
    p = P.get('ASME B36.10M', 'NPS 4')                              # NPS 4 schedule 40: 114.3 x 6.02 mm
    assert (p['od_mm'], p['wall_mm']) == (114.3, 6.02)


def test_missing_size_and_ambiguous_names_are_refused():
    with pytest.raises(KeyError, match='not in the table'):
        P.get('ISO 4017', 'M99', l=60)
    with pytest.raises(KeyError):
        P.get('ISO 4017')                                           # a size is needed
    with pytest.raises(KeyError, match='no standard part'):
        P.get('ISO 99999', 'M10')


def test_find_ranks_the_named_standard_first():
    assert P.find('hex bolt ISO 4017')[0]['class'] == 'hexscrew2'
    assert P.find('IPE 300')[0]['class'] == 'ibeam_ipe'


def test_tool(tmp_path):
    from shipbrain import agent, knowledge
    T = agent.Tools(str(tmp_path), knowledge.load(None))
    r = T.call('standard_part', {'query': 'IPE 300 dimensions'})
    assert r['h'] == 300 and 'Area' in r['plain_english']
    r = T.call('standard_part', {'query': 'hex bolt ISO 4017 M20 length 60'})
    assert r['s'] == 30 and r['l'] == 60
    assert 'error' in T.call('standard_part', {'query': 'M99 bolt ISO 4017'})
    assert 'size' in T.call('standard_part', {'query': 'plain washer ISO 7089'})['plain_english']
