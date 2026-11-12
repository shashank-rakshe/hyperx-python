// ShipBrain runner for Vessel.js (MIT, shiplab / NTNU): reads {spec, drafts, heel...} as JSON on stdin, writes one JSON object on stdout.
// The library's own console output goes to stderr so the answer stays clean.
import * as Vessel from "./jsm/vessel.js";
const log = console.log; console.log = (...a) => console.error(...a);
let inp = ""; for await (const c of process.stdin) inp += c;
const req = JSON.parse(inp);
const out = {};
try {
  const ship = new Vessel.Ship(req.spec);
  const hull = ship.structure.hull;
  if (req.action === "stability" || !req.action) {
    const st = ship.calculateStability();
    out.stability = { T: st.T, trim_deg: st.trim, GMt: st.GMt, GMl: st.GMl, KB: st.KB, BMt: st.BMt, BMl: st.BMl, KG: st.KG, draftfp: st.draftfp, draftap: st.draftap, heel_m: st.heel,
                      mass_kg: st.w.mass, cg: st.w.cg };
  }
  if (req.drafts) {
    out.hydrostatics = req.drafts.map(T => { const h = hull.calculateAttributesAtDraft(T); const r = { T }; for (const k of Object.keys(h)) if (typeof h[k] === "number") r[k] = h[k]; return r; });
  }
  if (req.mass_kg !== undefined) out.draft_at_mass = hull.calculateDraftAtMass(req.mass_kg);
} catch (e) { out.error = String(e && e.message || e); }
log(JSON.stringify(out));
