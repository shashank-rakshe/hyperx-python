from pidkg.ocr import dedupe_runs, join_bubbles, tag_candidates, to_norm


def test_join_bubble_lines():
    runs = [
        {"text": "FIT", "bbox": [0.500, 0.300, 0.520, 0.310], "conf": 0.9},
        {"text": "0502", "bbox": [0.498, 0.312, 0.522, 0.322], "conf": 0.95},
        {"text": "PI", "bbox": [0.700, 0.300, 0.712, 0.310], "conf": 0.9},
        {"text": "0501", "bbox": [0.300, 0.312, 0.322, 0.322], "conf": 0.9},  # far away: no join
    ]
    out = join_bubbles(runs)
    texts = {r["text"] for r in out}
    assert "FIT-0502" in texts
    assert "PI-0501" not in texts


def test_tag_candidates_filters_and_dedupes():
    runs = [
        {"text": "660-TK-004 2ND STAGE CLEARWELL", "bbox": [0.1, 0.1, 0.2, 0.12], "conf": 0.9},
        {"text": "FIT-0502", "bbox": [0.5, 0.3, 0.52, 0.32], "conf": 0.8},
        {"text": "FIT 0502", "bbox": [0.5, 0.3, 0.52, 0.32], "conf": 0.95},
        {"text": "PHASE 0 1200 GPM", "bbox": [0.1, 0.9, 0.3, 0.92], "conf": 0.9},
    ]
    cands = {c["text"]: c for c in tag_candidates(runs)}
    assert "660-TK-004" in cands and cands["660-TK-004"]["equipment_like"]
    assert cands["FIT-0502"]["isa"] and cands["FIT-0502"]["conf"] == 0.95
    assert not any(t.startswith("GPM") for t in cands)


def test_dedupe_runs_from_overlapping_tiles():
    runs = [{"text": "P-101", "bbox": [0.5, 0.5, 0.52, 0.51], "conf": 0.8},
            {"text": "P-101", "bbox": [0.501, 0.5, 0.521, 0.51], "conf": 0.9},
            {"text": "P-101", "bbox": [0.9, 0.9, 0.92, 0.91], "conf": 0.9}]
    assert len(dedupe_runs(runs)) == 2


def test_to_norm():
    assert to_norm([100, 50, 200, 100], [1000, 500, 2400, 1900], 5000, 4000) == \
        [0.22, 0.1375, 0.24, 0.15]
