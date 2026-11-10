"""Assemble the per-deck moulded-line XMLs into ONE complete ship file (R-AS).

  python -m deckrules.assemble out_p1 out_p2 --out DH_complete_moulded.xml
Decks are stacked by their own Z origin; materials and bar sections are unioned.
Thickness convention (decision): plates carry their nominal thickness as an attribute only;
geometry stays on the moulded line, no offset, no MaterialSide.
"""
import argparse, glob, os, copy
from lxml import etree


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dirs', nargs='+')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    files = sorted(f for d in a.dirs for f in glob.glob(os.path.join(d, '*_DECK_moulded.xml')))
    root = etree.Element('Ship', Version='pre 2.0', GeometryConvention='MouldedLine',
                         Source='deckrules assemble (PDF drawing only)')
    mats, bars, blocks = {}, {}, []
    for f in files:
        r = etree.parse(f).getroot()
        for m in r.findall('Material'):
            mats.setdefault(m.get('Grade'), m)
        for b in r.findall('BarSection'):
            bars.setdefault(b.get('BarSectionId'), b)
        for b in r.findall('Block'):
            if not b.findall('.//Stiffener'):          # R-AS2: degenerate extraction (no members) is not merged
                print('skipped (no members):', f)
                continue
            blocks.append(b)
    for e in list(mats.values()) + sorted(bars.values(), key=lambda b: b.get('BarSectionId')) + blocks:
        root.append(copy.deepcopy(e))
    def z(b):
        o = b.find('.//CoordSys/Origin'); return float(o.get('Z'))
    root[:] = [e for e in root if e.tag != 'Block'] + sorted([e for e in root if e.tag == 'Block'], key=z)
    etree.ElementTree(root).write(a.out, xml_declaration=True, encoding='utf-8', pretty_print=True)
    print(f'{len(files)} decks, {len(blocks)} blocks, {len(bars)} bar sections -> {a.out}')


if __name__ == '__main__':
    main()
