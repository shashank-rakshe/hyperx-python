#!/usr/bin/env python3
"""
fetch_datasets.py — Construction/engineering-drawing dataset acquisition.

WHAT THIS DOES
--------------
1. Creates a consistent on-disk folder structure for every dataset in the catalog,
   organized by drawing-type lane (electrical / pid / architectural / structural /
   civil / general), each with raw/ and (empty) cir/ subfolders.
2. Downloads every dataset whose access can be automated (direct URL, public git
   repo, Hugging Face open repo, Kaggle via API, Zenodo record).
3. Writes a manifest.json into each dataset folder recording source, license, lane,
   modality, whether it has connectivity/graph ground truth, and acquisition status.
4. Prints a final report: what downloaded, what was skipped, and what needs manual
   acquisition (with a pointer to MANUAL_ACQUISITION.md for step-by-step directions).

DESIGN NOTES
------------
- Licensing is recorded, NEVER used to block a download (per project decision: the
  data layer decides lanes downstream). Every record is tagged so the research/
  commercial-lane split can be enforced later as a lookup, not a re-download.
- Idempotent: re-running skips datasets already present (unless --force).
- No dataset is converted to CIR here; this script only ACQUIRES and STRUCTURES.
  Conversion to the Canonical Intermediate Representation is a separate step in the
  repo's /datasets preparers.
- Tools are probed, not assumed. If `git`, `kaggle`, or `huggingface_hub` are
  missing, the relevant datasets are reported as SKIPPED with the reason, not failed.

USAGE
-----
    python fetch_datasets.py --root ./data                 # structure + auto-downloads
    python fetch_datasets.py --root ./data --dry-run       # show plan, download nothing
    python fetch_datasets.py --root ./data --only electrical pid   # subset of lanes
    python fetch_datasets.py --root ./data --list          # print catalog and exit
    python fetch_datasets.py --root ./data --force         # re-download present datasets

OPTIONAL CREDENTIALS / TOOLS (only needed for some datasets; absence is handled)
    - git            (apt-get install git)            -> git-based repos
    - kaggle         (pip install kaggle + ~/.kaggle/kaggle.json) -> Kaggle mirrors
    - huggingface_hub(pip install huggingface_hub)    -> Hugging Face repos
    - HF_TOKEN env   (for gated HF repos AFTER you accept their terms in the browser)
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path

# --------------------------------------------------------------------------------------
# Catalog
# --------------------------------------------------------------------------------------
# access methods:
#   "url_zip"   : direct URL to a zip/tar we can fetch + extract
#   "url_file"  : direct URL to a single file (csv/json/etc.)
#   "git"       : public git clone
#   "hf"        : huggingface_hub snapshot_download (open repos; gated need HF_TOKEN+accepted terms)
#   "kaggle"    : kaggle datasets download (needs kaggle CLI + token)
#   "manual"    : cannot be automated; see MANUAL_ACQUISITION.md
#
# graph_gt: True if the dataset ships connectivity / edge / scene-graph ground truth
#           (the differentiator we care about).


@dataclass
class Dataset:
    key: str
    name: str
    lane: str  # electrical|pid|architectural|structural|civil|general
    access: str  # url_zip|url_file|git|hf|kaggle|manual
    license: str
    modality: str  # raster|vector|raster+vector|pointcloud|rgbd|text|graph|mixed
    real: bool  # real-world drawings (vs synthetic)
    graph_gt: bool  # ships connectivity/graph ground truth
    note: str = ""
    url: str | None = None  # for url_zip / url_file
    repo: str | None = None  # for git (clone URL) / hf (repo id) / kaggle (owner/slug)
    hf_repo_type: str = "dataset"  # for hf: dataset|model


CATALOG: list[Dataset] = [
    # ----------------------------- ELECTRICAL / MEP (WEDGE) -----------------------------
    Dataset(
        key="cghd",
        name="CGHD — Handwritten Circuit Diagram Images (Zenodo 15333233)",
        lane="electrical",
        access="url_zip",
        license="CC BY 4.0",
        modality="raster",
        real=True,
        graph_gt=True,
        note="Handwritten circuit images w/ symbols+junctions+wire-hops -> full graph GT. "
        "Zenodo record 15333233 (cghd-zenodo-15.zip); the old DFKI-NLP git URL 404s.",
        url="https://zenodo.org/api/records/15333233/files/cghd-zenodo-15.zip/content",
    ),
    Dataset(
        key="eng_diagrams_elyan",
        name="Eng_Diagrams (Elyan) — cropped P&ID/engineering symbols",
        lane="electrical",
        access="git",
        license="Research only",
        modality="raster",
        real=True,
        graph_gt=False,
        note="~2,432 cropped 100x100 symbol instances for classification.",
        repo="https://github.com/heyad/Eng_Diagrams.git",
    ),
    # DELP / SkeySpot: public repo ships toolkit + sample only; full 45-plan set is on-request.
    Dataset(
        key="skeyspot_delp",
        name="SkeySpot / DELP — electrical layout plans (toolkit + sample)",
        lane="electrical",
        access="git",
        license="Code open; full dataset on-request",
        modality="raster",
        real=True,
        graph_gt=False,
        note="Public repo = YOLOv8 toolkit + sample + per-plot count CSVs. Full 45-plan, "
        "2450-instance, 34-class annotated set is gated -> see MANUAL_ACQUISITION.md.",
        repo="https://github.com/HAIx-Lab/Skeyspot.git",
    ),
    # ----------------------------- P&ID / PROCESS -----------------------------
    Dataset(
        key="digitize_pid_hf",
        name="Dataset-P&ID (Digitize-PID) — HF mirror, YOLO format",
        lane="pid",
        access="hf",
        license="Public (author-released)",
        modality="raster",
        real=False,
        graph_gt=False,
        note="500 synthetic P&IDs, 32 symbol classes, YOLO bboxes. Symbols only.",
        repo="hamzas/digitize-pid-yolo",
    ),
    Dataset(
        key="digitize_pid_symbols_hf",
        name="Dataset-P&ID symbols — HF mirror",
        lane="pid",
        access="hf",
        license="Public",
        modality="raster",
        real=False,
        graph_gt=False,
        note="Symbol crops companion to digitize-pid.",
        repo="hamzas/digitize-pid-symbols",
    ),
    Dataset(
        key="pid2graph",
        name="PID2Graph — real OPEN100 + synthetic P&IDs WITH FULL GRAPH GT",
        lane="pid",
        access="url_zip",
        license="CC BY-SA 4.0",
        modality="raster+graph",
        real=True,
        graph_gt=True,
        note="Zenodo 14803338. Per-patch GraphML (nodes+edges). One of the few REAL "
        "drawings with connectivity GT. If the direct URL 404s, see manual note.",
        url="https://zenodo.org/records/14803338/files/PID2Graph.zip?download=1",
    ),
    Dataset(
        key="pidqa",
        name="PIDQA — 64K Q&A over P&IDs (graph-grounded)",
        lane="pid",
        access="git",
        license="Code MIT; data inherits Dataset-P&ID",
        modality="mixed",
        real=False,
        graph_gt=True,
        note="64,000 graph-grounded QA pairs over 500 sheets. Already in your repo at 0.2; "
        "included here for completeness/re-fetch.",
        repo="https://github.com/mgupta70/PIDQA.git",
    ),
    Dataset(
        key="pfd_digitize_rwth",
        name="RWTH Aachen — chemical PFD digitization (1,005 real PFDs)",
        lane="pid",
        access="git",
        license="Research (paper-attached)",
        modality="raster",
        real=True,
        graph_gt=True,
        note="1,005 real process flow diagrams, unit-op symbols + line/arrow edges.",
        repo="https://github.com/process-intelligence-research/digitize_flowsheet.git",
    ),
    # ----------------------------- ARCHITECTURAL FLOOR PLANS -----------------------------
    Dataset(
        key="cubicasa5k",
        name="CubiCasa5K — 5,000 plans, 80+ classes (incl. Electrical Appliance icon)",
        lane="architectural",
        access="url_zip",
        license="CC BY-NC-SA 4.0",
        modality="raster+vector",
        real=True,
        graph_gt=False,
        note="Direct Zenodo zip. SVG + polygon seg. The 'Electrical Appliance' icon class "
        "is a useful bridge toward the electrical lane.",
        url="https://zenodo.org/record/2613548/files/cubicasa5k.zip?download=1",
    ),
    Dataset(
        key="cubigraph5k",
        name="CubiGraph5K — room-connectivity graphs over CubiCasa5K",
        lane="architectural",
        access="git",
        license="Research",
        modality="graph",
        real=True,
        graph_gt=True,
        note="Organizational/room-adjacency graphs (data.json) layered on CubiCasa5K. "
        "Needs CubiCasa5K present to be useful.",
        repo="https://github.com/luyueheng/CubiGraph5K.git",
    ),
    Dataset(
        key="r2v",
        name="Raster-to-Vector (Liu et al.) — 815 plans w/ junction graph GT",
        lane="architectural",
        access="git",
        license="MIT (code); annots inherit LIFULL",
        modality="raster+vector",
        real=True,
        graph_gt=True,
        note="FloorplanTransformation. Junction GT enables vectorization + graph.",
        repo="https://github.com/art-programmer/FloorplanTransformation.git",
    ),
    Dataset(
        key="msd",
        name="MSD — Modified Swiss Dwellings (5,372 multi-apartment plans + graphs)",
        lane="architectural",
        access="git",
        license="Open (4TU.ResearchData)",
        modality="raster+graph",
        real=True,
        graph_gt=True,
        note="Code/loader repo; the ML-ready data is a 4TU record (see manual note for the "
        "direct 4TU DOI if the loader doesn't auto-pull it).",
        repo="https://github.com/caspervanengelenburg/msd.git",
    ),
    Dataset(
        key="mlstructfp",
        name="MLStructFP — 954 large-scale plans, wall/slab polygons",
        lane="architectural",
        access="git",
        license="Public via request form",
        modality="raster+vector",
        real=True,
        graph_gt=False,
        note="PyPI package + repo. Large PNGs (6,500-9,500px) + JSON polygons.",
        repo="https://github.com/MLSTRUCT/MLStructFP.git",
    ),
    Dataset(
        key="floorplancad_hf",
        name="FloorPlanCAD — 15,663 vector CAD drawings, 30 categories (panoptic)",
        lane="architectural",
        access="hf",
        license="CC BY-NC (research)",
        modality="raster+vector",
        real=True,
        graph_gt=False,
        note="Voxel51 HF mirror. Vector SVG + raster, per-primitive class+instance.",
        repo="Voxel51/FloorPlanCAD",
    ),
    Dataset(
        key="waffle_hf",
        name="WAFFLE — 18,556 in-the-wild Wikimedia floor plans + metadata",
        lane="architectural",
        access="manual",
        license="Wikimedia per-image (mostly permissive)",
        modality="raster+text",
        real=True,
        graph_gt=False,
        note="HF repo tau-vailab/WAFFLE is 404. Real data: GitHub TAU-VAILab/WAFFLE README "
        "-> SharePoint/OneDrive folder (not scriptable). Per-image Wikimedia licenses.",
        repo="https://github.com/TAU-VAILab/WAFFLE",
    ),
    Dataset(
        key="archcad400k_hf",
        name="ArchCAD-400K — 413,062 chunks / 5,538 drawings (GATED CC BY-NC 4.0)",
        lane="architectural",
        access="hf",
        license="CC BY-NC 4.0 (gated form)",
        modality="raster+vector",
        real=True,
        graph_gt=False,
        note="GATED: accept terms on the HF page first (≈3 business days), then set HF_TOKEN. "
        "This script will attempt it; if access not yet granted it reports SKIPPED.",
        repo="jackluoluo/ArchCAD",
    ),
    Dataset(
        key="us_floorplan_sft_hf",
        name="us-architectural-floorplan-sft (LLM SFT, IRC compliance)",
        lane="architectural",
        access="hf",
        license="Apache-2.0",
        modality="text",
        real=False,
        graph_gt=False,
        note="12,000 ChatML conversations on US residential plans w/ code compliance.",
        repo="Nithins03/us-architectural-floorplan-sft",
    ),
    Dataset(
        key="pseudo_floorplan_12k_hf",
        name="pseudo-floor-plan-12k (ControlNet conditioning)",
        lane="architectural",
        access="hf",
        license="Open",
        modality="raster",
        real=False,
        graph_gt=False,
        note="12K pseudo plans, image-only.",
        repo="zimhe/pseudo-floor-plan-12k",
    ),
    # ----------------------------- STRUCTURAL / SCAN-TO-BIM -----------------------------
    Dataset(
        key="cv4aec",
        name="CV4AEC — Scan-to-BIM challenge (point clouds + plans + wall/col/door JSON)",
        lane="structural",
        access="git",
        license="Research/challenge",
        modality="pointcloud",
        real=True,
        graph_gt=True,
        note="Challenge repo = eval metrics + data pointers. Large LAZ point clouds may be "
        "hosted off-repo; see manual note if the clone doesn't include them.",
        repo="https://github.com/GradientSpaces/cv4aec-challenge.git",
    ),
    Dataset(
        key="scan2bim_lttm",
        name="Scan-to-BIM (LTTM) — HePIC heritage instance segmentation",
        lane="structural",
        access="git",
        license="Research",
        modality="pointcloud",
        real=True,
        graph_gt=False,
        note="Per-point semantic+instance annotations on heritage buildings.",
        repo="https://github.com/LTTM/Scan-to-BIM.git",
    ),
    # ----------------------------- CIVIL / ROAD -----------------------------
    Dataset(
        key="toulouse_road",
        name="Toulouse Road Network — image->graph (nodes+edges)",
        lane="civil",
        access="git",
        license="MIT",
        modality="raster+graph",
        real=True,
        graph_gt=True,
        note="OSM tiles + canonical-ordered graph GT. Clean precedent for image-conditioned "
        "graph generation (directly relevant to electrical connectivity).",
        repo="https://github.com/davide-belli/toulouse-road-network-dataset.git",
    ),
    # ----------------------------- GENERAL / TECHNICAL -----------------------------
    Dataset(
        key="eng_drawings_as1100_hf",
        name="engineering-drawings-as1100 — mechanical drawing VQA (tiny)",
        lane="general",
        access="hf",
        license="Unspecified",
        modality="raster+text",
        real=True,
        graph_gt=False,
        note="24 examples; AS1100 compliance VQA. Tiny but real.",
        repo="jcrzd/engineering-drawings-as1100",
    ),
    Dataset(
        key="cadllm_hf",
        name="CADLLM — text<->CAD command sequences",
        lane="general",
        access="hf",
        license="Apache-2.0",
        modality="text",
        real=False,
        graph_gt=False,
        note="DeepCAD-derived text-to-CAD pairs (mechanical).",
        repo="lanlanguai/CADLLM",
    ),
    # ----------------------------- MANUAL-ONLY (no automation) -----------------------------
    Dataset(
        key="archcad400k_form",
        name="(placeholder) ArchCAD-400K terms acceptance",
        lane="architectural",
        access="manual",
        license="CC BY-NC 4.0",
        modality="raster+vector",
        real=True,
        graph_gt=False,
        note="Covered by archcad400k_hf once terms accepted. See MANUAL_ACQUISITION.md #A1.",
    ),
    Dataset(
        key="zind",
        name="ZInD — Zillow Indoor Dataset (71,474 panoramas + vector plans)",
        lane="architectural",
        access="manual",
        license="Zillow Data Terms (gated)",
        modality="mixed",
        real=True,
        graph_gt=False,
        note="Bridge Platform registration + click-through. See MANUAL_ACQUISITION.md #A2.",
    ),
    Dataset(
        key="rplan",
        name="RPLAN — 80,788 real residential plans",
        lane="architectural",
        access="manual",
        license="By-request, no redistribution",
        modality="raster",
        real=True,
        graph_gt=False,
        note="Email request to authors (USTC). See MANUAL_ACQUISITION.md #A3.",
    ),
    Dataset(
        key="lifull",
        name="LIFULL HOME'S — 5.31M floor-plan images (~210GB)",
        lane="architectural",
        access="manual",
        license="NII IDR academic agreement",
        modality="raster",
        real=True,
        graph_gt=False,
        note="NII IDR application, academic-only. See MANUAL_ACQUISITION.md #A4.",
    ),
    Dataset(
        key="structured3d",
        name="Structured3D — 196,515 renderings / wireframe graphs",
        lane="architectural",
        access="manual",
        license="Research agreement form",
        modality="raster+graph",
        real=False,
        graph_gt=True,
        note="Google-form agreement -> download links. See MANUAL_ACQUISITION.md #A5.",
    ),
    Dataset(
        key="cvc_fp",
        name="CVC-FP — 122 scanned plans + structural relations",
        lane="architectural",
        access="manual",
        license="Research/academic",
        modality="raster",
        real=True,
        graph_gt=True,
        note="Request via CVC UAB DAG page. See MANUAL_ACQUISITION.md #A6.",
    ),
    Dataset(
        key="dataset_pid_drive",
        name="Dataset-P&ID — original Google Drive (500 synthetic)",
        lane="pid",
        access="manual",
        license="Public (author-hosted on Drive)",
        modality="raster",
        real=False,
        graph_gt=False,
        note="If the HF mirror (digitize_pid_hf) fails, pull from the authors' Google Drive. "
        "See MANUAL_ACQUISITION.md #P1.",
    ),
    Dataset(
        key="sld_mdpi",
        name="MDPI SLD dataset (Bhanbhro 2023) — 600 single-line diagrams",
        lane="electrical",
        access="manual",
        license="Request from authors",
        modality="raster",
        real=True,
        graph_gt=False,
        note="No formal download link; email authors. See MANUAL_ACQUISITION.md #E1.",
    ),
    Dataset(
        key="deeppatent2",
        name="DeepPatent2 — 2.7M technical drawings",
        lane="general",
        access="manual",
        license="CC BY-NC",
        modality="raster+text",
        real=True,
        graph_gt=False,
        note="OSF (fxws7) — large; staged download. See MANUAL_ACQUISITION.md #G1.",
    ),
    Dataset(
        key="roboflow_bundle",
        name="Roboflow Universe electrical/MEP/P&ID bundle (~25 projects)",
        lane="electrical",
        access="manual",
        license="Mostly CC BY 4.0 (per-project)",
        modality="raster",
        real=True,
        graph_gt=False,
        note="Roboflow needs a per-workspace API key + per-project export. A ready-to-run "
        "helper is generated as roboflow_fetch.py. See MANUAL_ACQUISITION.md #E2.",
    ),
]


# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------
LANES = ["electrical", "pid", "architectural", "structural", "civil", "general"]

C_OK = "\033[92m"
C_WARN = "\033[93m"
C_ERR = "\033[91m"
C_DIM = "\033[2m"
C_END = "\033[0m"


def color(s: str, c: str) -> str:
    return s if os.environ.get("NO_COLOR") else f"{c}{s}{C_END}"


def have(tool: str) -> bool:
    return shutil.which(tool) is not None


def have_py(mod: str) -> bool:
    try:
        __import__(mod)
        return True
    except Exception:
        return False


def run(cmd: list[str], cwd: Path | None = None, timeout: int = 3600) -> tuple[bool, str]:
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        ok = p.returncode == 0
        return ok, (p.stdout + p.stderr)[-2000:]
    except subprocess.TimeoutExpired:
        return False, f"timeout after {timeout}s"
    except Exception as e:
        return False, str(e)


def download_url(url: str, dest: Path, timeout: int = 60) -> tuple[bool, str]:
    """Stream a URL to disk with a basic progress dot every ~10MB."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (dataset-fetch)"})
        with urllib.request.urlopen(req, timeout=timeout) as r, dest.open("wb") as f:
            total = int(r.headers.get("Content-Length", 0))
            got = 0
            chunk = 1 << 20
            next_dot = 10 << 20
            while True:
                b = r.read(chunk)
                if not b:
                    break
                f.write(b)
                got += len(b)
                if got >= next_dot:
                    sys.stdout.write(".")
                    sys.stdout.flush()
                    next_dot += 10 << 20
            if total:
                sys.stdout.write("\n")
            return True, f"{got/1e6:.1f} MB"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code} {e.reason}"
    except Exception as e:
        return False, str(e)


def extract(archive: Path, into: Path) -> tuple[bool, str]:
    try:
        if archive.suffix == ".zip" or zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as z:
                z.extractall(into)
            return True, "unzipped"
        # tar fallback
        import tarfile

        if tarfile.is_tarfile(archive):
            with tarfile.open(archive) as t:
                t.extractall(into)
            return True, "untarred"
        return False, "unknown archive type"
    except Exception as e:
        return False, str(e)


# --------------------------------------------------------------------------------------
# Per-access acquisition
# --------------------------------------------------------------------------------------
def acquire(ds: Dataset, raw: Path, dry: bool) -> tuple[str, str]:
    """Returns (status, detail). status in {DOWNLOADED, SKIPPED, MANUAL, FAILED, EXISTS}."""
    # already populated?
    if any(raw.iterdir()) if raw.exists() else False:
        return "EXISTS", "already populated (use --force to redo)"

    if ds.access == "manual":
        return "MANUAL", "see MANUAL_ACQUISITION.md"

    if dry:
        return "PLAN", f"would fetch via {ds.access}"

    raw.mkdir(parents=True, exist_ok=True)

    if ds.access in ("url_zip", "url_file"):
        assert ds.url
        fname = ds.url.split("?")[0].split("/")[-1] or "download.bin"
        dest = raw / fname
        ok, detail = download_url(ds.url, dest)
        if not ok:
            return "FAILED", f"download: {detail}"
        if ds.access == "url_zip":
            ok2, d2 = extract(dest, raw)
            if ok2:
                dest.unlink(missing_ok=True)
                return "DOWNLOADED", f"{detail}; {d2}"
            return "FAILED", f"extract: {d2}"
        return "DOWNLOADED", detail

    if ds.access == "git":
        if not have("git"):
            return "SKIPPED", "git not installed (apt-get install git)"
        ok, detail = run(["git", "clone", "--depth", "1", ds.repo, str(raw)])
        return ("DOWNLOADED", "cloned") if ok else ("FAILED", detail)

    if ds.access == "hf":
        if not have_py("huggingface_hub"):
            return "SKIPPED", "pip install huggingface_hub"
        try:
            from huggingface_hub import snapshot_download

            token = os.environ.get("HF_TOKEN")
            snapshot_download(
                repo_id=ds.repo,
                repo_type=ds.hf_repo_type,
                local_dir=str(raw),
                token=token,
                local_dir_use_symlinks=False,
            )
            return "DOWNLOADED", "hf snapshot"
        except Exception as e:
            msg = str(e)
            if "gated" in msg.lower() or "403" in msg or "awaiting" in msg.lower():
                return "SKIPPED", "GATED — accept terms on HF page + set HF_TOKEN (see manual)"
            return "FAILED", msg[-300:]

    if ds.access == "kaggle":
        if not have("kaggle"):
            return "SKIPPED", "pip install kaggle + place ~/.kaggle/kaggle.json"
        ok, detail = run(
            ["kaggle", "datasets", "download", "-d", ds.repo, "-p", str(raw), "--unzip"]
        )
        return ("DOWNLOADED", "kaggle") if ok else ("FAILED", detail)

    return "FAILED", f"unknown access method {ds.access}"


def write_manifest(ds: Dataset, folder: Path, status: str, detail: str) -> None:
    m = asdict(ds)
    m.update(
        {
            "status": status,
            "detail": detail,
            "acquired_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "cir_converted": False,  # conversion happens in the repo's /datasets preparers
        }
    )
    (folder / "manifest.json").write_text(json.dumps(m, indent=2))


# --------------------------------------------------------------------------------------
# Roboflow helper generator
# --------------------------------------------------------------------------------------
ROBOFLOW_HELPER = '''#!/usr/bin/env python3
"""
roboflow_fetch.py — pull the electrical/MEP/P&ID Roboflow Universe projects.

Roboflow exports need (a) a free account + API key, and (b) per-project consent to
the export. This script automates the download ONCE you paste your API key below.

    pip install roboflow
    export ROBOFLOW_API_KEY=xxxx-your-key-xxxx
    python roboflow_fetch.py --root ./data

Get your key: https://app.roboflow.com  -> Settings -> Roboflow API -> Private API Key
"""
import argparse, os, sys
from pathlib import Path

# (workspace, project, version) — version 1 is a safe default; bump if a project has more.
PROJECTS = [
    # ---- electrical ----
    ("hand-drawn-electrical-circuits", "anotations-tryn9", 1, "electrical"),
    ("keerthi-edrbd", "electrical-symbols-ly64s", 1, "electrical"),
    ("tfg-reconocimiento-simbolos-electricos-unifilares", "detection-electric-symbols", 1, "electrical"),
    ("shashank-ymwns", "electrical-components", 1, "electrical"),
    ("conti-z14wj", "blueprint-symbol-detection-br", 1, "electrical"),
    ("class-swogf", "fire-alarm-system", 1, "electrical"),
    ("electric-circuit", "handdrawn-circuit-recognition", 1, "electrical"),
    ("electric-circuit", "circuit-recognition-juvor", 1, "electrical"),
    ("circuit-components", "labeled-circuit-schematic", 1, "electrical"),
    ("deep-learning-in-computer-vision", "handwritten-circuit-diagram", 1, "electrical"),
    ("deeplearning-l1bq5", "circuit-diagram-eo4kn", 1, "electrical"),
    # ---- MEP ----
    ("chulalongkorn-university-jlvzr", "thesis-mep-testing", 1, "electrical"),
    ("plumbing", "plumbing-model", 1, "pid"),
    ("dataset-hvac", "hvac", 1, "pid"),
    # ---- P&ID ----
    ("pid-connect", "p-id-symbols", 1, "pid"),
    ("pid-connect", "p-id-symbols-r2", 1, "pid"),
    ("sameer-hsj9v", "p-id-diagram-8ayu9", 1, "pid"),
    ("pid-vcaab", "p-id-dlayt", 1, "pid"),
    ("pid-ksv2b", "p-id-4w5qy", 1, "pid"),
    ("traindatasetcolab", "pid-symbols-ki2yj", 1, "pid"),
    # ---- engineering / architectural ----
    ("engineering-drawing-yixc7", "symbols-l8rn4-yez2q", 1, "general"),
    ("floor-plan-rendering", "floor-plan-ai-object-detection", 1, "architectural"),
    ("estima-zza1m", "architectural-blueprint", 1, "architectural"),
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="./data")
    ap.add_argument("--fmt", default="yolov8", help="export format: yolov8|coco|voc|...")
    args = ap.parse_args()
    key = os.environ.get("ROBOFLOW_API_KEY")
    if not key:
        print("ERROR: set ROBOFLOW_API_KEY (https://app.roboflow.com -> Settings -> API)"); sys.exit(1)
    try:
        from roboflow import Roboflow
    except ImportError:
        print("ERROR: pip install roboflow"); sys.exit(1)
    rf = Roboflow(api_key=key)
    ok, bad = [], []
    for ws, proj, ver, lane in PROJECTS:
        dest = Path(args.root) / lane / f"roboflow__{proj}" / "raw"
        dest.mkdir(parents=True, exist_ok=True)
        try:
            p = rf.workspace(ws).project(proj).version(ver)
            p.download(args.fmt, location=str(dest))
            ok.append(proj); print(f"  [OK]   {ws}/{proj}")
        except Exception as e:
            bad.append((proj, str(e)[:120])); print(f"  [FAIL] {ws}/{proj}: {str(e)[:120]}")
    print(f"\\nRoboflow done: {len(ok)} ok, {len(bad)} failed.")
    for p, e in bad: print(f"  - {p}: {e}")

if __name__ == "__main__":
    main()
'''


# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description="Acquire construction/engineering drawing datasets.")
    ap.add_argument("--root", default="./data", help="root data dir (default ./data)")
    ap.add_argument("--only", nargs="*", choices=LANES, help="restrict to these lanes")
    ap.add_argument("--dry-run", action="store_true", help="plan only, download nothing")
    ap.add_argument("--force", action="store_true", help="re-acquire even if present")
    ap.add_argument("--list", action="store_true", help="print catalog and exit")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    sel = [d for d in CATALOG if (not args.only or d.lane in args.only)]

    if args.list:
        print(f"\n{len(sel)} datasets in catalog:\n")
        for lane in LANES:
            ds_in = [d for d in sel if d.lane == lane]
            if not ds_in:
                continue
            print(color(f"== {lane.upper()} ==", C_DIM))
            for d in ds_in:
                g = color("graph-GT", C_OK) if d.graph_gt else "        "
                r = "real " if d.real else "synth"
                print(f"  {d.key:24s} {r} {g} [{d.access:7s}] {d.name}")
            print()
        return

    print(color(f"\nDataset acquisition -> {root}", C_DIM))
    print(
        color(
            f"tools: git={have('git')} hf={have_py('huggingface_hub')} "
            f"kaggle={have('kaggle')} HF_TOKEN={'set' if os.environ.get('HF_TOKEN') else 'unset'}\n",
            C_DIM,
        )
    )

    # 1. structure
    for lane in LANES:
        (root / lane).mkdir(parents=True, exist_ok=True)
    (root / "_reports").mkdir(parents=True, exist_ok=True)

    # 2/3. acquire + manifest
    results: list[tuple[Dataset, str, str]] = []
    for ds in sel:
        folder = root / ds.lane / ds.key
        raw = folder / "raw"
        (folder / "cir").mkdir(parents=True, exist_ok=True)  # empty target for later conversion
        if args.force and raw.exists():
            shutil.rmtree(raw, ignore_errors=True)
        raw.mkdir(parents=True, exist_ok=True)

        label = f"[{ds.lane}] {ds.key}"
        print(f"-> {label:34s} ", end="", flush=True)
        status, detail = acquire(ds, raw, args.dry_run)
        write_manifest(ds, folder, status, detail)
        results.append((ds, status, detail))

        tag = {
            "DOWNLOADED": color("DOWNLOADED", C_OK),
            "EXISTS": color("EXISTS", C_OK),
            "SKIPPED": color("SKIPPED", C_WARN),
            "MANUAL": color("MANUAL", C_WARN),
            "PLAN": color("PLAN", C_DIM),
            "FAILED": color("FAILED", C_ERR),
        }.get(status, status)
        print(f"{tag}  {color(detail, C_DIM)}")

    # 4. roboflow helper
    helper = root / "roboflow_fetch.py"
    helper.write_text(ROBOFLOW_HELPER)
    helper.chmod(0o755)

    # 5. report
    print(color("\n================= REPORT =================", C_DIM))
    by = lambda s: [r for r in results if r[1] == s]  # noqa: E731
    auto_ok = by("DOWNLOADED") + by("EXISTS")
    print(color(f"\nAUTOMATED OK ({len(auto_ok)}):", C_OK))
    for ds, _st, d in auto_ok:
        print(f"  ✓ {ds.key:24s} {d}")
    if by("FAILED"):
        print(color(f"\nFAILED ({len(by('FAILED'))}) — retriable:", C_ERR))
        for ds, _st, d in by("FAILED"):
            print(f"  ✗ {ds.key:24s} {d}")
    if by("SKIPPED"):
        print(color(f"\nSKIPPED ({len(by('SKIPPED'))}) — install a tool / accept terms:", C_WARN))
        for ds, _st, d in by("SKIPPED"):
            print(f"  • {ds.key:24s} {d}")
    if by("MANUAL"):
        print(color(f"\nMANUAL ({len(by('MANUAL'))}) — see MANUAL_ACQUISITION.md:", C_WARN))
        for ds, _st, _d in by("MANUAL"):
            print(f"  ↪ {ds.key:24s} {ds.name}")

    # graph-GT highlight
    g = [ds for ds, st, _ in results if ds.graph_gt and st in ("DOWNLOADED", "EXISTS")]
    if g:
        print(
            color(
                f"\nCONNECTIVITY/GRAPH-GT datasets now on disk ({len(g)}) — the differentiator:",
                C_OK,
            )
        )
        for ds in g:
            print(f"  ◆ {ds.key:24s} {ds.name}")

    # machine-readable summary
    summ = {
        "root": str(root),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "counts": {
            k: len(by(k)) for k in ["DOWNLOADED", "EXISTS", "SKIPPED", "MANUAL", "FAILED", "PLAN"]
        },
        "datasets": [
            {
                "key": ds.key,
                "lane": ds.lane,
                "status": st,
                "license": ds.license,
                "real": ds.real,
                "graph_gt": ds.graph_gt,
                "detail": d,
            }
            for ds, st, d in results
        ],
    }
    (root / "_reports" / "acquisition_summary.json").write_text(json.dumps(summ, indent=2))
    print(
        color(f"\nMachine-readable summary -> {root/'_reports'/'acquisition_summary.json'}", C_DIM)
    )
    print(color(f"Roboflow helper          -> {helper}", C_DIM))
    print(color("Manual steps             -> MANUAL_ACQUISITION.md\n", C_DIM))


if __name__ == "__main__":
    main()
