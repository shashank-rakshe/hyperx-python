"""FastAPI application for the ConstructDrawingAI platform.

The CIR is the wire format: requests and responses are CIR models, so the API and
the rest of the platform share one schema. Validation of the research/commercial
lane invariant happens for free — an incompatible :class:`~cir.DrawingSet` is
rejected by FastAPI/pydantic with a 422 before any handler runs.
"""

from __future__ import annotations

import os

from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, UploadFile
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

import cir
from agent.qa import answer as qa_answer
from agent.rfi import generate_rfis
from backend.detect import Detector, get_detector
from cir import DataLane, DrawingSet, make_example_drawing_set
from engines.takeoff import compute_takeoff
from grounding.ontology import ground_drawing_set


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    """Gate the product endpoints on ``X-API-Key`` when ``CDAI_API_KEY`` is set (open in dev)."""
    expected = os.environ.get("CDAI_API_KEY")
    if expected and x_api_key != expected:
        raise HTTPException(status_code=401, detail="missing or invalid API key")


app = FastAPI(
    title="ConstructDrawingAI API",
    version="0.1.0",
    description=(
        "Construction-drawing understanding over the Canonical Intermediate "
        "Representation (CIR). Scaffolding stage: health, version, and CIR "
        "validation/example endpoints."
    ),
)


class HealthResponse(BaseModel):
    """Liveness/version payload."""

    status: str = "ok"
    app_version: str
    cir_schema_version: str


class ValidationSummary(BaseModel):
    """Summary returned after validating a posted CIR document."""

    valid: bool = True
    schema_version: str
    sheet_count: int
    entity_count: int
    licenses_present: list[str] = Field(default_factory=list)
    is_commercial_safe: bool


@app.get("/healthz", response_model=HealthResponse, tags=["meta"])
def healthz() -> HealthResponse:
    """Liveness probe + reported versions."""
    return HealthResponse(app_version=app.version, cir_schema_version=cir.SCHEMA_VERSION)


@app.get("/cir/example", response_model=DrawingSet, tags=["cir"])
def cir_example(
    lane: DataLane = Query(
        default=DataLane.RESEARCH, description="Lane to stamp the example with."
    ),
) -> DrawingSet:
    """Return a representative example CIR document (handy for frontend development)."""
    return make_example_drawing_set(data_lane=lane)


@app.post("/cir/validate", response_model=ValidationSummary, tags=["cir"])
def cir_validate(drawing_set: DrawingSet) -> ValidationSummary:
    """Validate a posted CIR document and summarize it.

    The body is parsed against the :class:`~cir.DrawingSet` schema, so the
    license/lane invariant is enforced automatically (a 422 is returned for an
    invalid document, e.g. a commercial set containing non-commercial data).
    """
    return ValidationSummary(
        schema_version=drawing_set.schema_version,
        sheet_count=len(drawing_set.sheets),
        entity_count=drawing_set.entity_count(),
        licenses_present=sorted(lic.value for lic in drawing_set.licenses_present()),
        is_commercial_safe=drawing_set.is_commercial_safe,
    )


# ---------------------------------------------------------------------------
# L2–L4 product endpoints (CIR in → decision-support artifact out). Perception
# (L1, GPU) runs upstream/batch; these engines serve over the CIR on CPU.
# ---------------------------------------------------------------------------
class QARequest(BaseModel):
    """A CIR + a natural-language question for the Q&A engine."""

    drawing_set: DrawingSet
    question: str


@app.post("/ground", tags=["product"], dependencies=[Depends(require_api_key)])
def ground(drawing_set: DrawingSet) -> dict:
    """L2: fill IFC class + MasterFormat/UniFormat codes; report coverage."""
    ds, grounded, total = ground_drawing_set(drawing_set)
    return {"grounded": grounded, "total": total, "drawing_set": ds.model_dump(mode="json")}


@app.post("/takeoff", tags=["product"], dependencies=[Depends(require_api_key)])
def takeoff(
    drawing_set: DrawingSet,
    min_confidence: float = Query(0.0),
    review_threshold: float = Query(0.5),
) -> dict:
    """L3: quantity takeoff (spec-coded, confidence + review flags) over the CIR."""
    ground_drawing_set(drawing_set)  # spec-code entities before aggregating
    return compute_takeoff(
        drawing_set, min_confidence=min_confidence, review_threshold=review_threshold
    ).to_dict()


@app.post("/qa", tags=["product"], dependencies=[Depends(require_api_key)])
def qa(req: QARequest) -> dict:
    """L4: a grounded, evidence-linked answer to a drawing question."""
    a = qa_answer(req.drawing_set, req.question)
    return {"question": a.question, "text": a.text, "value": a.value, "evidence": a.evidence}


@app.post("/rfi", tags=["product"], dependencies=[Depends(require_api_key)])
def rfi(drawing_set: DrawingSet, review_threshold: float = Query(0.5)) -> list[dict]:
    """L4: drafted RFIs (low-confidence quantities + connectivity discrepancies)."""
    return [
        {
            "id": r.id,
            "discipline": r.discipline,
            "sheet": r.sheet,
            "severity": r.severity,
            "subject": r.subject,
            "body": r.body,
            "evidence": r.evidence,
        }
        for r in generate_rfis(drawing_set, review_threshold=review_threshold)
    ]


@app.post("/detect", tags=["product"], dependencies=[Depends(require_api_key)])
async def detect(
    file: UploadFile = File(...),
    discipline: str = Query("architectural"),
    conf: float = Query(0.25),
    detector: Detector | None = Depends(get_detector),
) -> dict:
    """L1: run the trained detector on an uploaded drawing image → CIR."""
    if detector is None:
        raise HTTPException(503, "no detector configured — set CDAI_DETECTOR_WEIGHTS")
    ds = detector.detect(await file.read(), discipline, conf=conf)
    return ds.model_dump(mode="json")


@app.post("/takeoff-from-image", tags=["product"], dependencies=[Depends(require_api_key)])
async def takeoff_from_image(
    file: UploadFile = File(...),
    discipline: str = Query("architectural"),
    conf: float = Query(0.25),
    review_threshold: float = Query(0.5),
    detector: Detector | None = Depends(get_detector),
) -> dict:
    """End-to-end: uploaded drawing → detect → ground → quantity takeoff."""
    if detector is None:
        raise HTTPException(503, "no detector configured — set CDAI_DETECTOR_WEIGHTS")
    ds = detector.detect(await file.read(), discipline, conf=conf)
    ground_drawing_set(ds)
    return compute_takeoff(ds, review_threshold=review_threshold).to_dict()


@app.get("/", response_class=HTMLResponse, tags=["meta"])
def home() -> str:
    """A minimal same-origin demo console: paste/load a CIR, run takeoff / Q&A / RFI."""
    return _UI_HTML


_UI_HTML = """<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>ConstructDrawingAI — console</title><style>
:root{--bg:#0e1519;--panel:#15212a;--line:#26363f;--ink:#e7eef1;--mut:#8ea3ad;--acc:#57b6d8;--good:#5ec08f;--bad:#d98a72}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 system-ui,sans-serif}
.wrap{max-width:1000px;margin:0 auto;padding:24px}
h1{font:600 20px ui-monospace,monospace;margin:0 0 4px}h1 b{color:var(--acc)}
.sub{color:var(--mut);margin:0 0 18px;font-size:13px}
.row{display:flex;gap:16px;flex-wrap:wrap}.col{flex:1 1 380px;min-width:300px}
label{font:600 11px ui-monospace,monospace;letter-spacing:.08em;text-transform:uppercase;color:var(--mut)}
textarea{width:100%;height:230px;background:#0b1216;color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:10px;font:12px ui-monospace,monospace;resize:vertical}
input[type=text]{width:100%;background:#0b1216;color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:9px 11px;font-size:14px}
button{background:var(--acc);color:#04222d;border:0;border-radius:6px;padding:9px 14px;font:600 13px system-ui;cursor:pointer;margin:6px 6px 0 0}
button.ghost{background:transparent;color:var(--acc);border:1px solid var(--line)}
#out{margin-top:16px;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px;min-height:80px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:5px 9px;border-bottom:1px solid var(--line)}
th{color:var(--mut);font:600 11px ui-monospace,monospace;text-transform:uppercase}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;font-family:ui-monospace,monospace}
.pill{font:600 11px ui-monospace,monospace;padding:2px 7px;border-radius:3px}
.rev{color:var(--bad)}.disc{color:var(--bad)}.ok{color:var(--good)}
h3{font:600 13px ui-monospace,monospace;color:var(--acc);margin:14px 0 6px;text-transform:uppercase;letter-spacing:.06em}
.err{color:var(--bad)}
</style></head><body><div class=wrap>
<h1>Construct<b>Drawing</b>AI · console</h1>
<p class=sub>Paste or load a CIR drawing set, then run the L2–L4 product engines over it (same-origin API).</p>
<div class=row>
<div class=col>
<label>CIR drawing set (JSON)</label>
<textarea id=cir placeholder="Paste a CIR DrawingSet, or click Load example"></textarea>
<div><button class=ghost onclick=loadExample()>Load example</button>
<button onclick=runTakeoff()>Takeoff</button>
<button onclick=runRfi()>RFIs</button></div>
</div>
<div class=col>
<label>Ask a question</label>
<input id=q type=text value="how many entities are in this set" placeholder="e.g. how many receptacles on E-101">
<div><button onclick=ask()>Ask</button></div>
<label style=display:block;margin-top:10px>Result</label>
<div id=out>—</div>
</div></div></div>
<script>
const out=document.getElementById('out'), cir=document.getElementById('cir');
function ds(){try{return JSON.parse(cir.value)}catch(e){out.innerHTML='<span class=err>Invalid JSON in the CIR box.</span>';throw e}}
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
async function loadExample(){const r=await fetch('/cir/example');cir.value=JSON.stringify(await r.json(),null,2);out.textContent='Example loaded.'}
async function runTakeoff(){const r=await fetch('/takeoff',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(ds())});const t=await r.json();
let h=`<h3>Takeoff · ${t.total_count} components · ${t.total_needs_review} flagged</h3><table><tr><th>Item</th><th>MasterFormat</th><th class=n>Qty</th><th>Unit</th><th class=n>Conf</th><th class=n>⚠</th></tr>`;
for(const l of t.lines){h+=`<tr><td>${esc(l.item)}</td><td class=n>${l.masterformat||'—'}</td><td class=n>${l.qty}</td><td>${l.unit}</td><td class=n>${Math.round(l.avg_confidence*100)}%</td><td class="n rev">${l.needs_review||'—'}</td></tr>`}
h+='</table>';if(t.linear&&t.linear.length){h+='<h3>Linear</h3><table><tr><th>Run</th><th class=n>Count</th><th class=n>Length</th><th>Unit</th></tr>';for(const q of t.linear)h+=`<tr><td>${esc(q.category)}</td><td class=n>${q.count}</td><td class=n>${q.quantity}</td><td>${q.unit}</td></tr>`;h+='</table>'}
out.innerHTML=h}
async function runRfi(){const r=await fetch('/rfi',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(ds())});const rf=await r.json();
if(!rf.length){out.innerHTML='<h3>RFIs</h3>No RFIs — nothing flagged.';return}
let h='<h3>RFIs · '+rf.length+'</h3>';for(const r of rf)h+=`<div style=margin-bottom:10px><span class="pill ${r.severity=='discrepancy'?'disc':'rev'}">${r.severity}</span> <b>${esc(r.subject)}</b><br><span style=color:var(--mut)>${esc(r.body)}</span></div>`;out.innerHTML=h}
async function ask(){const r=await fetch('/qa',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({drawing_set:ds(),question:document.getElementById('q').value})});const a=await r.json();out.innerHTML=`<h3>Q&amp;A</h3><b>${esc(a.text)}</b><br><span style=color:var(--mut)>value: ${esc(JSON.stringify(a.value))} · ${a.evidence.length} evidence link(s)</span>`}
</script></body></html>"""
