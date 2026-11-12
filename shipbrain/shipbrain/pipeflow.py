"""
Pipe hydraulics for ship piping (seawater cooling, ballast, bilge, fire main, fuel, lube oil, fresh water) with ProcessPi's
pipeline engine (https://github.com/varma666/ProcessPi, MIT, copied as written in vendor/processpi): Darcy-Weisbach with
Colebrook-White (64/Re when laminar), valve / bend losses from its K and Le/D tables, elevation, series lines and
parallel branches; pump power added here (rho g Q H / efficiency).

Two things ShipBrain does around it (both found by checking its results by hand):
  * fluids: ShipBrain's own Component subclasses with FIXED density and viscosity - ProcessPi's Water class ignores a
    density override, and it has no seawater or marine fuels. Typical values are below; give your own when known
    (viscosity of fuel oils changes strongly with temperature).
  * fittings are put on the pipe they belong to (ProcessPi skips fittings placed at a network node, by design).
Units in: m3/h, mm, m. Out: Pa / bar, m of head, m/s, kW.
"""
import math, os, sys, warnings

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, 'vendor', 'processpi', 'repo')
G = 9.80665

# name -> (density kg/m3, kinematic viscosity cSt, note)
FLUIDS = {
    'fresh water': (998.2, 1.004, '20 C'),
    'seawater': (1024.8, 1.054, '20 C, salinity 35 g/kg (ITTC)'),
    'mgo': (850.0, 3.5, 'marine gas oil, typical at 40 C (ISO 8217 DMA: 2-6 cSt)'),
    'hfo': (980.0, 380.0, 'heavy fuel oil RMG 380 at 50 C - heated for transfer it is far thinner'),
    'lube oil': (890.0, 100.0, 'SAE 30 / ISO VG 100 at 40 C'),
    'hydraulic oil': (870.0, 46.0, 'ISO VG 46 at 40 C'),
}
ALIASES = {'water': 'fresh water', 'freshwater': 'fresh water', 'sea water': 'seawater', 'sw': 'seawater',
           'diesel': 'mgo', 'marine gas oil': 'mgo', 'heavy fuel oil': 'hfo', 'fuel oil': 'hfo', 'lubricating oil': 'lube oil',
           'lo': 'lube oil'}


def _pp():
    if ROOT not in sys.path:
        sys.path.insert(0, ROOT)
    warnings.filterwarnings('ignore', category=SyntaxWarning)
    import processpi  # noqa: F401
    return processpi


def fluid_props(fluid='seawater', density=None, viscosity_cst=None):
    key = ALIASES.get(str(fluid).lower().strip(), str(fluid).lower().strip())
    if key not in FLUIDS and not (density and viscosity_cst):
        raise ValueError(f'unknown fluid {fluid}: one of {", ".join(FLUIDS)}, or give density (kg/m3) and viscosity_cst')
    rho, nu, note = FLUIDS.get(key, (None, None, 'given by the user'))
    rho = float(density or rho)
    nu = float(viscosity_cst or nu)
    return {'name': key if key in FLUIDS else str(fluid), 'density': rho, 'nu_cst': nu, 'mu_pas': rho * nu * 1e-6,
            'note': note if not (density or viscosity_cst) else 'values given by the user'}


def _component(fp):
    _pp()
    from processpi.components.base import Component, PropertyMethod
    from processpi.units import Density, Viscosity
    rho, mu = fp['density'], fp['mu_pas']

    class ShipFluid(Component):
        name = fp['name']
        formula = '-'
        molecular_weight = 100.0
        _default_phase = 'liquid'

        @PropertyMethod
        def density(self):
            return Density(rho, 'kg/m3')

        @PropertyMethod
        def viscosity(self):
            return Viscosity(mu, 'Pa·s')
    return ShipFluid(phase='liquid')


def fitting_types():
    _pp()
    from processpi.pipelines import standards as s
    return sorted(set(s.K_FACTORS) | set(s.EQUIVALENT_LENGTHS))


def _v(x):
    return float(getattr(x, 'value', x))


def _velocity_note(fp, rows):
    oil = fp['nu_cst'] > 2.0                                   # fuels and oils; water is about 1 cSt
    lim = 2.0 if oil else 3.0
    fast = [f"{x['name']} {x['velocity_m_s']:.1f} m/s" for x in rows if x['velocity_m_s'] > lim]
    if not fast:
        return ''
    return (f" High velocity in {', '.join(fast)}: {'oil' if oil else 'water'} lines are usually kept below about {lim:g} m/s "
            "(erosion, noise, pressure loss growing with the square of the velocity) - a larger bore lowers it.")


def line(flow_m3h, segments, fluid='seawater', density=None, viscosity_cst=None, pump_efficiency=0.7, branches=None):
    """segments: [{"d_mm": inner diameter, "length_m", "rise_m" (end minus start height), "material" (CS, SS, Copper, PVC,
    Glass, Concrete), "fittings": {"standard_elbow_90_deg": 4, "gate_valve": 1, ...}}] in series; branches (optional): a
    list of such segment lists between the end of the line and a common outlet, run in parallel."""
    _pp()
    from processpi.pipelines.engine import PipelineEngine
    from processpi.pipelines.network import PipelineNetwork
    from processpi.pipelines.pipes import Pipe
    from processpi.pipelines.fittings import Fitting
    from processpi.units import VolumetricFlowRate, Diameter, Length
    fp = fluid_props(fluid, density, viscosity_cst)
    known = set(fitting_types())
    Q = float(flow_m3h) / 3600.0

    def pipe(i, s, prefix):
        for ft in (s.get('fittings') or {}):
            if ft not in known:
                raise ValueError(f'unknown fitting {ft}; known: {", ".join(sorted(known))}')
        p = Pipe(f'{prefix}{i + 1}', internal_diameter=Diameter(float(s['d_mm']), 'mm'), length=Length(float(s['length_m']), 'm'),
                 material=s.get('material', 'CS'))
        p.fittings = [Fitting(fitting_type=ft, quantity=int(n)) for ft, n in (s.get('fittings') or {}).items() if int(n) > 0]
        return p

    net = PipelineNetwork('line')
    z = 0.0
    net.add_node('N0', elevation=0.0)
    for i, s in enumerate(segments):
        z += float(s.get('rise_m', 0.0))
        net.add_node(f'N{i + 1}', elevation=z)
        net.add_edge(pipe(i, s, 'S'), f'N{i}', f'N{i + 1}')
    if branches:
        par = PipelineNetwork('branches', connection_type='parallel')
        end = f'N{len(segments)}'
        par.add_node(end, elevation=z)
        zb = z + float((branches[0][0] if branches[0] else {}).get('rise_m', 0.0))
        par.add_node('OUT', elevation=zb)
        for b, segs in enumerate(branches):
            if len(segs) != 1:
                raise ValueError('each parallel branch is one pipe (d_mm, length_m, fittings) here')
            par.add_edge(pipe(0, segs[0], f'B{b + 1}.'), end, 'OUT')
        net.add_subnetwork(par)
    e = PipelineEngine()
    e.fit(flowrate=VolumetricFlowRate(Q, 'm3/s'), network=net, fluid=_component(fp))
    r = e.run()
    dp = float(r.total_pressure_drop_Pa)
    H = dp / (fp['density'] * G)
    hyd = Q * dp / 1000.0
    rows = []
    for c in r.results.get('components', []):
        if c.get('type') == 'fitting':
            continue
        rows.append({'name': c.get('name'), 'velocity_m_s': round(_v(c.get('velocity', 0)), 3),
                     'reynolds': round(_v(c.get('reynolds', 0))), 'friction_factor': round(_v(c.get('friction_factor', 0)), 5),
                     'friction_Pa': round(_v(c.get('major_dp', 0)), 1), 'fittings_Pa': round(_v(c.get('minor_dp', 0)), 1),
                     'elevation_Pa': round(_v(c.get('elevation_dp', 0)), 1), 'total_Pa': round(_v(c.get('total_dp', 0)), 1)})
    out = {'fluid': fp, 'flow_m3h': float(flow_m3h), 'pressure_drop_bar': round(dp / 1e5, 4), 'pressure_drop_Pa': round(dp, 1),
           'head_m': round(H, 3), 'hydraulic_power_kW': round(hyd, 3), 'pump_efficiency': pump_efficiency,
           'shaft_power_kW': round(hyd / pump_efficiency, 3), 'segments': rows}
    vmax = max((x['velocity_m_s'] for x in rows), default=0)
    lam = [x['name'] for x in rows if 0 < x['reynolds'] < 2000]
    out['plain_english'] = (
        f"{float(flow_m3h):g} m3/h of {fp['name']} ({fp['density']:g} kg/m3, {fp['nu_cst']:g} cSt; {fp['note']}) through "
        f"{len(rows)} pipe(s): total pressure drop {dp / 1e5:.3f} bar = {H:.2f} m head (friction, fittings and "
        f"elevation), highest velocity {vmax:.2f} m/s. The pump needs {hyd:.2f} kW hydraulic, {hyd / pump_efficiency:.2f} kW at "
        f"the shaft with {pump_efficiency * 100:.0f} % efficiency." + (f" Flow is laminar in {', '.join(lam)} (64/Re)." if lam else '')
        + _velocity_note(fp, rows)
        + ' (Darcy-Weisbach / Colebrook with ProcessPi; add a margin for fouling and check the pump curve.)')
    return out
