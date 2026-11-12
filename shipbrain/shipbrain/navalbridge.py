"""
Hydrostatics, GZ curve and intact-stability criteria of ANY hull given as an STL (a generated hull, an uploaded surface) with NavalToolbox (AGPL-3.0, Rust library, `pip install navaltoolbox`):
trim-optimised equilibrium at every heel angle, free-surface correction, and the criteria scripts of the library (IS Code 2008, HSC 2000, ...) copied in vendor/navaltoolbox/rules.

The STL is in metres, x along the hull, y across, z up with the baseline (keel) at z = 0 - the frame of hullgen. Other units: scale.
"""
import math, os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
RULES = os.path.join(HERE, 'vendor', 'navaltoolbox', 'rules')


def available():
    try:
        import navaltoolbox  # noqa: F401
        return True
    except ImportError:
        return False


def _nt():
    try:
        import navaltoolbox as nt
    except ImportError:
        raise RuntimeError('the NavalToolbox library is not installed: pip install navaltoolbox (free), then ask again')
    return nt


# these two scripts of the library (version 0.9.3) do not compile in its own script engine (a function defined inside a block): refused instead of failing in the middle
BROKEN = {'hsc_2000_monohull_intact', 'is_code_2008_passenger'}


def rule_names():
    return sorted(f[:-5] for f in os.listdir(RULES) if f.endswith('.rhai') and f != 'template.rhai' and f[:-5] not in BROKEN)


def analyse(stl, kg, draft=None, displacement_t=None, lcg=None, tcg=0.0, heels=None, rho=1025.0, rule='is_code_2008_general', scale=1.0, flooding_angle_deg=None):
    """hydrostatics at a draft or displacement, the GZ curve with trim optimisation, and a criteria set"""
    nt = _nt()
    if (draft is None) == (displacement_t is None):
        raise ValueError('give either the draft or the displacement (tonnes)')
    if rule not in rule_names():
        raise ValueError('rule must be one of ' + ', '.join(rule_names()))
    hull = nt.Hull(stl)
    if scale != 1.0:
        hull.scale_uniform(float(scale)) if hasattr(hull, 'scale_uniform') else hull.scale(float(scale), float(scale), float(scale))
    vessel = nt.Vessel(hull)
    calc = nt.HydrostaticsCalculator(vessel, water_density=rho)
    st = calc.from_draft(draft=float(draft), vcg=float(kg)) if draft is not None else calc.from_displacement(float(displacement_t) * 1000.0)
    lcg = float(lcg) if lcg is not None else float(st.cob[0])
    mass = st.displacement
    heels = list(heels or range(0, 91, 5))
    sc = nt.StabilityCalculator(vessel, rho)
    res = sc.complete_stability(mass, (lcg, float(tcg), float(kg)), [float(h) for h in heels])
    curve = res.gz_curve if hasattr(res, 'gz_curve') else None
    gz = list(curve.values()) if curve is not None else None
    ang = list(curve.heels()) if curve is not None else heels
    ctx = nt.CriteriaContext.from_result(res, 'ShipBrain hull', 'loading condition')
    cr = nt.ScriptEngine().run_script_file(os.path.join(RULES, rule + '.rhai'), ctx)
    rows = [{'criterion': c.name, 'status': str(c.status), 'actual': round(float(c.actual_value), 4), 'required': float(c.required_value) if hasattr(c, 'required_value') else None,
             'unit': c.unit} for c in cr.criteria]
    hyd = {'draft_m': st.draft, 'displacement_t': mass / 1000.0, 'volume_m3': st.volume, 'cob': [round(float(v), 3) for v in st.cob], 'waterplane_area_m2': st.waterplane_area, 'LCF_m': st.lcf,
           'BMt_m': st.bmt, 'BMl_m': st.bml, 'GMt_m': st.gmt, 'GMl_m': st.gml, 'Cb': st.cb, 'Cm': st.cm, 'Cp': st.cp, 'LWL_m': st.lwl, 'BWL_m': st.bwl, 'trim_m': st.trim, 'freeboard_m': st.freeboard}
    return {'hydrostatics': hyd, 'heels_deg': [float(a) for a in ang], 'GZ_m': [float(g) for g in gz] if gz else None, 'rule': rule, 'criteria': rows, 'overall_pass': bool(cr.overall_pass)}


def plot(res, path, title='GZ curve'):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(8, 4.6))
    ax.plot(res['heels_deg'], res['GZ_m'], 'b-', lw=2, label='GZ (trim optimised)')
    ax.axhline(0, color='k', lw=0.6)
    ax.set_xlabel('heel [deg]'); ax.set_ylabel('GZ [m]'); ax.grid(alpha=0.3); ax.legend(); ax.set_title(title)
    fig.tight_layout(); fig.savefig(path, dpi=130); plt.close(fig)
    return path
