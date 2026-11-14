"""Acquire + index REAL construction plan sets (the sim-to-real test-set pipeline).

The project's synthetic engine makes training data cheap, but real success is measured on
*real* drawings (ADR-0011). The only public source of full, real, downloadable plan sets —
with the electrical **and** architectural/structural/mechanical/plumbing sheets we need —
is government procurement. This module turns those public bid postings into an indexed,
discipline-bucketed corpus that the annotation pipeline (Build Playbook A9) then samples
into the held-out real scoreboard.

Pipeline (each step idempotent / resumable):

1. **scrape**  — read a source's public listing, keep the *drawing-set* PDFs (names with
   "plan"/"drawing"; specs/IFB/addenda excluded), parse the project code.
2. **download** — fetch the PDFs into ``data/real/plansets/<source>/`` (git-ignored),
   skipping any already present.
3. **index**   — a light, text-only pass: per page, recover the sheet number + discipline
   with the L0 title-block parser (:mod:`ingest.sheets`) — no rasterization — and write
   ``index.json`` bucketed by discipline letter (A/S/M/P/E/…).
4. **rasterize** — on demand, render selected pages at ≥300 DPI (the L0 rasterizer,
   :func:`ingest.raster.rasterize_pdf_page`) to PNGs the annotator can label.

Provenance: government bid drawings are public records but the A/E firm's copyright
persists, so everything here is **research-lane / evaluation use** (never redistributed,
never commercial-lane training) — recorded in each source's manifest.
"""

from __future__ import annotations

import argparse
import html
import json
import logging
import re
import shutil
import time
import urllib.parse
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from ingest.sheets import discipline_for_letter, parse_sheet_number

logger = logging.getLogger(__name__)

_UA = "Mozilla/5.0 (X11; Linux x86_64) ConstructDrawingAI research/academic (shojaei@vt.edu)"
_DEFAULT_ROOT = Path("data/real/plansets")
_PROJECT_RE = re.compile(r"([A-Z]\d{4}-\d{2})")  # Missouri FMDC project code, e.g. T2612-01
_PLAN_KEYWORDS = ("plan", "drawing")  # a drawing set (vs specs/IFB/addenda)
_EXCLUDE_KEYWORDS = ("spec", "addend", "ifb", "invitation", "proposal", "instructions")


@dataclass(frozen=True)
class Source:
    """A public plan-set source. ``listing_url`` is scraped for drawing-set PDFs."""

    name: str
    listing_url: str
    #: How every record from this source is licensed (public record; A/E copyright persists).
    license: str = "public-record (A/E copyright persists) — research/eval only"
    data_lane: str = "research"


#: The A1 source. Verified 2026-07-02: 1,154 PDFs, ~140 plan-set drawings, no login.
MISSOURI = Source(
    name="missouri",
    listing_url="https://oa.mo.gov/facilities/bid-opportunities/bid-listing-electronic-plans",
)


@dataclass(frozen=True)
class SingleFile:
    """A directly-linked single plan-set PDF (A2 secondary sources)."""

    source: str
    project: str
    url: str


#: A2 secondary real sources (verified 2026-07-02). Each is one full set; indexed together
#: under the "secondary" source. Public records, A/E copyright persists → research/eval.
SECONDARY_FILES: list[SingleFile] = [
    SingleFile(
        "uccs",
        "UCCS-2021-0525",
        "https://pdc.uccs.edu/sites/g/files/kjihxj1346/files/inline-files/"
        "2021-0525_UCCS%20BID%20SET%20-%20Drawings.pdf",
    ),
    SingleFile(
        "unc-charlotte",
        "UNCC-SGO",
        "https://facilities.charlotte.edu/wp-content/uploads/sites/1297/2024/06/"
        "1131001000-SGO_BID-SET-032320_ELEC_0.pdf",
    ),
    SingleFile(
        "idaho-dpw",
        "ID-FM32219",
        "https://apps.itd.idaho.gov/Apps/NonHwyConstructionProjects/PDFS/FM32219_Drawings.pdf",
    ),
]


def download_secondary(
    *, root: Path = _DEFAULT_ROOT, timeout: int = 120, retries: int = 3
) -> dict[str, int]:
    """Download the A2 secondary single-file plan sets into ``root/secondary/`` (resumable)."""
    dest_dir = root / "secondary"
    dest_dir.mkdir(parents=True, exist_ok=True)
    tally: Counter[str] = Counter()
    for sf in SECONDARY_FILES:
        raw = sf.url.rsplit("/", 1)[-1]
        ref = PlanSetRef(sf.source, sf.project, sf.url, _sanitize(f"{sf.project}_{raw}"))
        outcome = _download_one(ref, dest_dir, timeout=timeout, retries=retries)
        tally[outcome.split(":")[0]] += 1
        if outcome.startswith("fail"):
            logger.warning("secondary download failed: %s (%s)", sf.project, outcome)
    logger.info("download secondary: %s", dict(tally))
    return dict(tally)


@dataclass(frozen=True)
class PlanSetRef:
    """One drawing-set PDF discovered on a listing."""

    source: str
    project: str  # parsed code (e.g. "T2612-01") or the filename stem
    url: str
    filename: str  # sanitized local filename


@dataclass
class PageRecord:
    """One indexed page: its recovered sheet number + discipline (text-only pass)."""

    page: int  # 0-based index in the PDF
    sheet_no: str | None
    discipline_letter: str | None  # leading letter of the sheet number, e.g. "E"
    discipline: str | None  # cir.Discipline value, e.g. "electrical"
    width_pt: float
    height_pt: float


@dataclass
class SetRecord:
    """One indexed plan set (PDF) and its per-discipline page counts."""

    source: str
    project: str
    filename: str
    n_pages: int
    pages: list[PageRecord] = field(default_factory=list)
    by_discipline: dict[str, int] = field(default_factory=dict)
    error: str | None = None


# ---------------------------------------------------------------------------
# 1. scrape
# ---------------------------------------------------------------------------
def _sanitize(filename: str) -> str:
    """A filesystem-friendly local name (spaces/quirks → underscore), extension kept."""
    name = urllib.parse.unquote(filename)
    name = re.sub(r"[^\w.\-]+", "_", name).strip("_")
    return name


def _is_drawing_set(filename: str) -> bool:
    low = filename.lower()
    if any(k in low for k in _EXCLUDE_KEYWORDS):
        return False
    return any(k in low for k in _PLAN_KEYWORDS)


def _fetch(url: str, *, timeout: int = 60) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": _UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return bytes(resp.read())


def scrape(source: Source, *, timeout: int = 60) -> list[PlanSetRef]:
    """Discover drawing-set PDFs on ``source``'s listing (deduped, plan/drawing only)."""
    page = _fetch(source.listing_url, timeout=timeout).decode("utf-8", errors="replace")
    hrefs = [html.unescape(h) for h in re.findall(r'href="([^"]+\.pdf)"', page, flags=re.I)]
    refs: dict[str, PlanSetRef] = {}
    for href in hrefs:
        url = urllib.parse.urljoin(source.listing_url, href)
        raw_name = url.rsplit("/", 1)[-1]
        decoded = urllib.parse.unquote(raw_name)
        if not _is_drawing_set(decoded):
            continue
        match = _PROJECT_RE.search(decoded)
        project = match.group(1) if match else Path(decoded).stem
        refs[url] = PlanSetRef(source.name, project, url, _sanitize(raw_name))
    logger.info(
        "scrape %s: %d drawing-set PDFs (%d projects)",
        source.name,
        len(refs),
        len({r.project for r in refs.values()}),
    )
    return sorted(refs.values(), key=lambda r: r.filename)


# ---------------------------------------------------------------------------
# 2. download (resumable)
# ---------------------------------------------------------------------------
def _download_one(ref: PlanSetRef, dest_dir: Path, *, timeout: int, retries: int) -> str:
    dest = dest_dir / ref.filename
    if dest.exists() and dest.stat().st_size > 0:
        return "skip"
    tmp = dest.with_suffix(dest.suffix + ".part")
    last: Exception | None = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(ref.url, headers={"User-Agent": _UA})
            with urllib.request.urlopen(req, timeout=timeout) as resp, tmp.open("wb") as fh:
                shutil.copyfileobj(resp, fh, length=1 << 20)
            tmp.replace(dest)
            return "ok"
        except Exception as exc:
            last = exc
            time.sleep(2 * (attempt + 1))
    tmp.unlink(missing_ok=True)
    return f"fail: {last}"


def download(
    source: Source,
    *,
    root: Path = _DEFAULT_ROOT,
    limit: int | None = None,
    workers: int = 4,
    timeout: int = 120,
    retries: int = 3,
) -> dict[str, int]:
    """Download ``source``'s drawing-set PDFs into ``root/<source>/`` (resumable)."""
    refs = scrape(source, timeout=timeout)
    if limit is not None:
        refs = refs[:limit]
    dest_dir = root / source.name
    dest_dir.mkdir(parents=True, exist_ok=True)
    (dest_dir / "_manifest.json").write_text(
        json.dumps(
            {"source": asdict(source), "n_refs": len(refs), "refs": [asdict(r) for r in refs]},
            indent=2,
        ),
        encoding="utf-8",
    )
    tally: Counter[str] = Counter()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(_download_one, r, dest_dir, timeout=timeout, retries=retries): r
            for r in refs
        }
        for i, fut in enumerate(as_completed(futures), 1):
            outcome = fut.result()
            tally[outcome.split(":")[0]] += 1
            if outcome.startswith("fail"):
                logger.warning("download failed: %s (%s)", futures[fut].filename, outcome)
            if i % 20 == 0 or i == len(futures):
                logger.info("download %s: %d/%d (%s)", source.name, i, len(futures), dict(tally))
    return dict(tally)


# ---------------------------------------------------------------------------
# 3. index (light, text-only)
# ---------------------------------------------------------------------------
def index_pdf(path: Path) -> SetRecord:
    """Index one plan-set PDF: per page recover sheet number + discipline (no rasterize)."""
    import fitz  # PyMuPDF

    match = _PROJECT_RE.search(path.name)
    record = SetRecord(
        source=path.parent.name,
        project=match.group(1) if match else path.stem,
        filename=path.name,
        n_pages=0,
    )
    try:
        doc = fitz.open(str(path))
    except Exception as exc:
        record.error = f"open: {exc}"
        return record
    try:
        record.n_pages = doc.page_count
        for i in range(doc.page_count):
            page = doc.load_page(i)
            text = page.get_text("text")
            sheet_no = parse_sheet_number(text)
            letter = sheet_no.split("-")[0][:2] if sheet_no else None
            disc = discipline_for_letter(letter[0]) if letter else None
            record.pages.append(
                PageRecord(
                    page=i,
                    sheet_no=sheet_no,
                    discipline_letter=letter,
                    discipline=disc.value if disc else None,
                    width_pt=float(page.rect.width),
                    height_pt=float(page.rect.height),
                )
            )
    except Exception as exc:
        record.error = f"index: {exc}"
    finally:
        doc.close()
    record.by_discipline = dict(
        Counter(p.discipline_letter for p in record.pages if p.discipline_letter)
    )
    return record


def build_index(source_name: str = MISSOURI.name, *, root: Path = _DEFAULT_ROOT) -> dict[str, Any]:
    """Index every downloaded PDF for a source; write + return ``index.json``."""
    src_dir = root / source_name
    # Case-insensitive: some sources serve ``.PDF``. A plain glob("*.pdf") would miss them.
    pdfs = sorted(p for p in src_dir.iterdir() if p.suffix.lower() == ".pdf")
    if not pdfs:
        raise FileNotFoundError(f"no PDFs under {src_dir} — run `download` first")
    sets = [index_pdf(p) for p in pdfs]
    by_disc: Counter[str] = Counter()
    for s in sets:
        by_disc.update(s.by_discipline)
    index = {
        "source": source_name,
        "n_sets": len(sets),
        "n_sets_ok": sum(1 for s in sets if s.error is None),
        "n_projects": len({s.project for s in sets}),
        "totals_by_discipline": dict(by_disc.most_common()),
        "sets": [asdict(s) for s in sets],
    }
    (src_dir / "index.json").write_text(json.dumps(index, indent=2), encoding="utf-8")
    logger.info(
        "index %s: %d sets, %d projects, disciplines=%s",
        source_name,
        len(sets),
        index["n_projects"],
        index["totals_by_discipline"],
    )
    return index


# ---------------------------------------------------------------------------
# 4. rasterize a selection (proves the L0 raster path; feeds the annotator)
# ---------------------------------------------------------------------------
def rasterize_sheet(pdf_path: Path, page_index: int, out_path: Path, *, dpi: int = 300) -> Path:
    """Render one PDF page to a PNG at ``dpi`` via the L0 rasterizer."""
    import fitz

    from ingest.raster import rasterize_pdf_page

    doc = fitz.open(str(pdf_path))
    try:
        image = rasterize_pdf_page(doc.load_page(page_index), dpi=dpi)
    finally:
        doc.close()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(out_path)
    return out_path


def rasterize_selection(
    source_name: str = MISSOURI.name,
    *,
    root: Path = _DEFAULT_ROOT,
    disciplines: tuple[str, ...] = ("E", "A"),
    per_discipline_cap: int = 40,
    dpi: int = 300,
) -> dict[str, int]:
    """Rasterize a capped selection of sheets per discipline into ``<source>/_raster/<D>/``."""
    src_dir = root / source_name
    index = json.loads((src_dir / "index.json").read_text())
    counts: Counter[str] = Counter()
    for s in index["sets"]:
        for p in s["pages"]:
            letter = p["discipline_letter"]
            if letter and letter[0] in disciplines and counts[letter[0]] < per_discipline_cap:
                out = (
                    src_dir
                    / "_raster"
                    / letter[0]
                    / f"{s['project']}_{p['sheet_no']}_p{p['page']}.png"
                )
                if not out.exists():
                    rasterize_sheet(src_dir / s["filename"], p["page"], out, dpi=dpi)
                counts[letter[0]] += 1
    logger.info("rasterized selection %s: %s", source_name, dict(counts))
    return dict(counts)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    parser = argparse.ArgumentParser(prog="python -m datasets.realsets", description=__doc__)
    parser.add_argument(
        "cmd", choices=["scrape", "download", "index", "rasterize", "all", "secondary"]
    )
    parser.add_argument("--root", default=str(_DEFAULT_ROOT))
    parser.add_argument("--limit", type=int, default=None, help="cap number of PDFs (download).")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--disciplines", default="E,A", help="rasterize: comma letters, e.g. E,A")
    parser.add_argument("--cap", type=int, default=40, help="rasterize: max sheets per discipline")
    parser.add_argument("--dpi", type=int, default=300)
    ns = parser.parse_args(argv)
    root = Path(ns.root)

    if ns.cmd == "scrape":
        refs = scrape(MISSOURI)
        print(f"{len(refs)} drawing-set PDFs, {len({r.project for r in refs})} projects")
    elif ns.cmd in ("download", "all"):
        print("download:", download(MISSOURI, root=root, limit=ns.limit, workers=ns.workers))
        if ns.cmd == "all":
            idx = build_index(root=root)
            print(
                f"index: {idx['n_sets']} sets, {idx['n_projects']} projects, "
                f"{idx['totals_by_discipline']}"
            )
    elif ns.cmd == "secondary":
        print("download secondary:", download_secondary(root=root))
        idx = build_index("secondary", root=root)
        print(f"index(secondary): {idx['n_sets']} sets, {idx['totals_by_discipline']}")
    elif ns.cmd == "index":
        idx = build_index(root=root)
        print(
            f"index: {idx['n_sets']} sets, {idx['n_projects']} projects, "
            f"{idx['totals_by_discipline']}"
        )
    elif ns.cmd == "rasterize":
        counts = rasterize_selection(
            root=root,
            disciplines=tuple(ns.disciplines.split(",")),
            per_discipline_cap=ns.cap,
            dpi=ns.dpi,
        )
        print("rasterized:", counts)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
