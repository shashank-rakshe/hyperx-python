import glob, os
from deckrules import overlap

def test_bracket_prism_apart(tmp_path):
    # a bracket far from every member must give no hit; function must run on an XML without brackets
    x = tmp_path / 'e.xml'; x.write_text('<Ship><Block ObjId="b"/></Ship>')
    n, h = overlap.check_brackets(str(x))
    assert n == 0 and h == []
