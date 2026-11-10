import re
from deckrules import view, section, elevation, mirror
from deckrules.build_ship import _pages


def test_frame_space_thousands_separator():
    m = view.NOTE['frame_space'].search('FRAME SPACE : 1,540 (EXC.)')
    assert int(m.group(1).replace(',', '')) == 1540


def test_frame_label_forms():
    assert view.parse_frame_label('FR.84') == (84, 0.0, 0.0)
    assert view.parse_frame_label('FR.84+1/2') == (84, 0.5, 0.0)
    assert view.parse_frame_label('FR.12+2100') == (12, 0.0, 2100)


def test_section_title_and_deck_labels():
    m = section.TITLE.match('FR.24+300 SEC.(P)')
    assert m.group('n') == '24' and m.group('off') == '+300' and m.group('s') == 'P'
    for t, code in (('NAV. DECK', 'NAV'), ('C - DECK', 'C'), ('COMP. DECK', 'COMP')):
        assert section.DECK_LABEL.match(t).group(1) == code
    assert section.DECK_LABEL.match('NO.2 STR.').group(2) == '2'
    assert section.DECK_LABEL.match('WEATHER SHIELD').group(3).upper() == 'WEATHER'


def test_elevation_title():
    m = elevation.TITLE.match('5840 OFF C.L ELEV.(S)')
    assert m.group('n') == '5840' and m.group('s') == 'S'


def test_mirror_only_when_other_side_missing():
    p = lambda y: {'y': y, 'tier': ('A', 'B'), 'name': 'w', 'stiffeners': [{'evidence': 'x'}]}
    assert len(mirror.mirror_walls([p(1460)])) == 1
    assert mirror.mirror_walls([p(1460), p(-1460)]) == []


def test_page_spec():
    assert _pages('1-3,5', 9) == [1, 2, 3, 5]
    assert _pages('all', 4) == [1, 2, 3, 4]
