"""
Optimum-circulation propeller design (Epps lifting-line method) with PythonProp (https://github.com/ianbohannon/PythonProp, GPL-3, Python port of OpenProp; copied unchanged in vendor/pythonprop).
Given blades, rpm, diameter, required thrust and ship speed it finds the radial circulation, the section pitch and camber, and the thrust, torque and efficiency with viscous drag, with or without a duct;
then the off-design curve KT, KQ, efficiency against the advance ratio. The blade can be turned into a 3D surface with `bladex_bridge`.
"""
import contextlib, io, os, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.join(HERE, 'vendor', 'pythonprop')


def _load():
    if VENDOR not in sys.path:
        sys.path.insert(0, VENDOR)
    import matplotlib
    matplotlib.use('Agg')
    import Ducted_Prop_input, EppsOptimizer, Geometry, Analyze
    return Ducted_Prop_input.build_input, EppsOptimizer.EppsOptimizer, Geometry.Geometry, Analyze.Analyze


def design(Z, rpm, D, thrust_N, speed_ms, hub_d=None, duct=False, tau=0.9, rho=1025.0, Mp=20, Np=20, curve=True):
    """Design one propeller. Chord and thickness distributions are those of the PythonProp example, scaled to the diameter (c/D and t/c are kept)."""
    build, epps, geom, analyze = _load()
    if not (rpm > 0 and D > 0 and thrust_N > 0 and speed_ms > 0):
        raise ValueError('rpm, D, thrust_N and speed_ms must be positive')
    inp, pt = build()
    n = rpm / 60.0
    R = D / 2
    hub = hub_d if hub_d else 0.15 * D
    Js = speed_ms / (n * D)
    i = pt['input']
    i.update(Z=int(Z), N=rpm, D=D, Vs=speed_ms, Js=Js, L=np.pi / Js, R=R, Rhub=hub / 2, Rhub_oR=hub / D, rho=rho, Mp=int(Mp), Np=int(Np), Plot_flag=0,
             CTDES=thrust_N / (0.5 * rho * speed_ms ** 2 * np.pi * R ** 2), Duct_flag=1 if duct else 0, TAU=float(tau) if duct else 1.0, Rduct=R + 0.02 * D, Cduct=D)
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink):
        pt['design'] = epps(i)
        pt['geometry'] = geom(pt)
        out = {}
        if curve:
            Jc = np.round(np.arange(max(0.2, 0.5 * Js), 1.6 * Js + 1e-9, 0.1 * max(Js, 0.3)), 3)
            pt['states'] = analyze(pt, np.pi / Jc)
    d = pt['design']
    r = {'design_J': round(Js, 4), 'design_KT': float(np.ravel(d['KT'])[0]), 'design_KQ': float(np.ravel(d['KQ'])[0]), 'design_efficiency': float(np.ravel(d['EFFY'])[0]),
         'thrust_N': float(thrust_N), 'rpm': float(rpm), 'D': float(D), 'Z': int(Z), 'duct': bool(duct)}
    r['torque_Nm'] = r['design_KQ'] * rho * n ** 2 * D ** 5
    r['power_kW'] = 2 * np.pi * n * r['torque_Nm'] / 1000
    r['kt_from_thrust'] = thrust_N / (rho * n ** 2 * D ** 4)
    r['actuator_disk_efficiency'] = 2.0 / (1.0 + np.sqrt(1.0 + float(i['CTDES'])))
    r['radius_fraction'] = [round(float(x), 4) for x in np.ravel(d['RC'])]
    r['circulation_G'] = [round(float(x), 5) for x in np.ravel(d['G'])]
    r['geometry_keys'] = sorted(pt['geometry'].keys()) if isinstance(pt['geometry'], dict) else []
    if curve:
        s = pt['states']
        r['curve'] = [{'J': round(float(a), 3), 'KT': round(float(b), 4), 'KQ': round(float(c), 5), 'eta': round(float(e), 3)} for a, b, c, e in zip(np.ravel(s['Js']), np.ravel(s['KT']), np.ravel(s['KQ']), np.ravel(s['EFFY']))]
        r['curve'].sort(key=lambda x: x['J'])
    r['_pt'] = pt
    return r


def blade_from_design(pt, n_sections=10, n_points=50):
    """turn the designed radial distributions into BladeX input (NACA 4-digit sections with the designed camber and thickness) -> (up, down) surface points"""
    from . import bladex_bridge as BB
    g = pt['geometry']
    D = float(g['D'])
    RG = np.ravel(g['RG']); idx = np.unique(np.round(np.linspace(0, len(RG) - 1, n_sections)).astype(int))
    pick = lambda k: np.ravel(g[k])[idx]
    t = pick('t0oc'); f = pick('f0oc')
    digs = [f'{int(np.clip(round(fi * 100), 0, 9))}4{int(np.clip(round(ti * 100), 6, 40)):02d}' for fi, ti in zip(f, t)]
    sk = np.degrees(pick('skew')) if np.max(np.abs(pick('skew'))) < 3.2 else pick('skew')
    return BB.blade(RG[idx] * D / 2 if RG.max() <= 1.0 + 1e-9 else RG[idx], pick('CoD') * D, pick('PoD') * D, pick('rake') * D if np.max(np.abs(pick('rake'))) < 1 else pick('rake'), sk, nacas=digs, n_points=n_points)
