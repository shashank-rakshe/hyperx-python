"""Unit tests for drawing-independent rule pieces.  Run:  python -m pytest -q tests"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from deckrules import members, snap, view, run  # noqa: E402


def test_parse_full_sections():
    assert members.parse_section('250X90X12/16 I.A') == ('L', 250, 90, 12.0, 16.0)
    assert members.parse_section('100X75X7 U.A (EXC. AS SHOWN)') == ('L', 100, 75, 7.0, 7.0)
    assert members.parse_section('125X10 F.B') == ('F', 125, 10.0)
    assert members.parse_section('Ø16 R.B(A)') == ('R', 16)


def test_short_form_needs_alias():
    assert members.parse_section('250 I.A') is None
    al = {'250 I.A': ['L', 250, 90, 10, 15]}
    assert members.parse_section('250   I.A', al) == ('L', 250, 90, 10, 15)


def test_title_regex():
    for t, z in (('B - DECK PLAN (26,100 A/B)', 26100), ('NAV. - DECK PLAN (34,650 A/B)', 34650)):
        m = view.TITLE.match(t)
        assert m and int(m.group('z').replace(',', '')) == z


def test_deck_codes():
    assert run.deck_code('B - DECK') == 'B'
    assert run.deck_code('NAV. - DECK') == 'NAV'
    assert run.deck_code('COMP. - DECK') == 'COMP'


def test_printed_value_wins_over_trace():
    D = snap.Datums()
    D.add('Y', 0.0, 'C.L')
    D.add('Y', 730.0, 'C.L + printed 730')
    log = {'printed': 0, 'traced': 0}
    v, src = snap.snap_value(D, 'Y', 727.6, log)      # traced 727.6 -> printed 730
    assert v == 730.0 and 'printed' in src
    v, src = snap.snap_value(D, 'Y', 1500.0, log)     # nothing printed nearby -> stays traced
    assert v == 1500.0 and src == 'traced'


def test_member_snap_keeps_orientation():
    D = snap.Datums()
    for n in range(10, 20):
        D.add('X', n * 800.0, f'FR.{n}')
    D.add('Y', 2190.0, '2190 OFF C.L (P)')
    ms = [{'a': (14401.0, 2187.0), 'b': (18291.0, 2187.0)}]
    snap.snap_members(D, ms)
    assert ms[0]['a'] == (14400.0, 2190.0) and ms[0]['b'][1] == 2190.0
