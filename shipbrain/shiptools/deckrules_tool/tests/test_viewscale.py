import csv
from deckrules import viewscale

HDR = ['text', 'x0', 'y0', 'x1', 'y1', 'size', 'font', 'color', 'dir_x', 'dir_y', 'flags', 'source', 'score']


def _w(tmp, rows):
    with open(tmp / 'd_p1_text.csv', 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(HDR)
        for t, x, y in rows:
            w.writerow([t, x, y, x + 40, y + 10, 9, 'A', 0, 1, 0, 0, 'vector', 1])
    with open(tmp / 'd_p1_views.csv', 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['view', 'x0', 'y0', 'x1', 'y1', 'title', 'denominator', 'mm_per_pt', 'scale_source', 'status', 'chains', 'measured_denominator'])
        w.writerow([0, 0, 0, 3000, 3000, 'ALL', 50, 17.64, 'written(view)', 'DIFFERENT', 0, ''])          # the old merged-region error
        w.writerow([1, 2000, 100, 2300, 300, 'tb', 100, 35.28, 'written(sheet)', 'no chain', 0, ''])


def test_scale_belongs_to_its_own_title(tmp_path):
    _w(tmp_path, [('"1B1-1" SEC.', 100, 100), ('(S : 1/50)', 100, 125), ('B - DECK PLAN (26100 A/B)', 1200, 1500)])
    out = {r['id'] or r['type']: r for r in viewscale.build(str(tmp_path), 'd')}
    assert float(out['1B1-1']['mm_per_pt']) == 17.64 and out['1B1-1']['source'].startswith('written(view')
    assert float(out['deck-plan']['mm_per_pt']) == 35.28 and out['deck-plan']['source'] == 'written(sheet)'      # not 1/50
    assert '1/50' not in ''.join(r['written_text'] for r in out.values() if r['type'] == 'deck-plan')
