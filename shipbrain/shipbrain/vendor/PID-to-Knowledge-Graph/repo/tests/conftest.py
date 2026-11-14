import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "skills" / "pid-to-kg" / "scripts"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
sys.path.insert(0, str(SCRIPTS))


@pytest.fixture(scope="session")
def mini_kg():
    from pidkg.build import build_graph, load_extractions

    pages = load_extractions(FIXTURES / "mini_plant" / "extract")
    return build_graph(pages, "mini", "Mini plant", "mini.pdf")


@pytest.fixture(scope="session")
def mini_graph(mini_kg):
    from pidkg.store import Graph

    return Graph(mini_kg)
