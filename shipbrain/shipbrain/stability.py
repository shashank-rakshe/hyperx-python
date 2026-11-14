"""
Righting-lever (GZ) curve and the IMO intact-stability criteria of a generated hull - ShipBrain's own code, the algorithm of the classical hydrostatics method (and of the Ship workbench of
FreeCAD, LGPL, whose code is in the knowledge pack freecad_ship): for every heel angle the waterline plane is moved until the submerged volume equals the displacement, the centre of buoyancy
of the heeled hull is integrated, and  GZ = yB cos(phi) + (zB - KG) sin(phi)  (minus the free-surface loss of the slack tanks).

Level keel (no trim change with heel), hull shape from hullgen up to the deck (nothing above the deck is buoyant), fixed displacement. The angle at which the lee deck edge goes under is
reported; beyond it the curve is that of the hull without the deck house and is not used for the criteria (a real ship has its own down-flooding angle - openings the hull model does not know).
"""
import math

import numpy as np

from . import hullgen as H


def _section_arrays(p, nx, nz):
    f = H.make_surface(p)
    x = np.linspace(0, p['L'], nx)
    z = np.linspace(0, p['D'], nz)
    Y = f(x[:, None], z[None, :])
    return x, z, Y


def _volume_and_buoyancy(x, z, Y, phi, h):
    """submerged volume and its centre (y, z) for a heel angle and a waterline offset h (plane  z cos(phi) - y sin(phi) = h)"""
    c, s = math.cos(phi), math.sin(phi)
    if abs(s) < 1e-9:
        lo = -Y
        dz = z[1] - z[0]
        width = 2 * Y * np.clip((h - z[None, :]) / dz + 0.5, 0.0, 1.0)         # a ramp over one cell: the volume is then continuous in h
        ycen = np.zeros_like(Y)
    else:
        ylo = (z[None, :] * c - h) / s
        lo = np.maximum(-Y, np.minimum(ylo, Y))
        width = np.clip(Y - lo, 0.0, None)
        ycen = 0.5 * (Y + lo)
    A = np.trapezoid(width, z, axis=1)
    My = np.trapezoid(width * ycen, z, axis=1)
    Mz = np.trapezoid(width * z[None, :], z, axis=1)
    V = np.trapezoid(A, x)
    if V <= 0:
        return 0.0, 0.0, 0.0
    return V, np.trapezoid(My, x) / V, np.trapezoid(Mz, x) / V


def gz_curve(p, kg, mass_t=None, draft=None, heels=None, free_surface_m=0.0, rho=1025.0, nx=121, nz=241):
    """GZ at heel angles (degrees); displacement from mass_t, or from the volume at `draft`, or from the design draft"""
    x, z, Y = _section_arrays(p, nx, nz)
    if mass_t is None:
        T = float(draft or p['T'])
        mass_t = H.coefficients(p, T=T, nx=401, nz=121)['volume_m3'] * rho / 1000.0
    V0 = mass_t * 1000.0 / rho
    Vmax = float(np.trapezoid(np.trapezoid(2 * Y, z, axis=1), x))
    if V0 >= Vmax * 0.999:
        raise ValueError('the displacement is larger than the volume of the hull up to the deck: the hull sinks')
    heels = list(heels if heels is not None else np.arange(0.0, 90.1, 2.5))
    out = []
    D = p['D']
    Yd = Y[:, -1]
    for deg in heels:
        sgn = -1.0 if deg < 0 else 1.0                                       # the hull is symmetric: GZ(-phi) = -GZ(phi)
        phi = math.radians(abs(deg))
        lo, hi = -D * 4.0, D * 4.0 + p['B']
        for _ in range(60):                                                  # bisection on the waterline offset
            h = 0.5 * (lo + hi)
            V, yB, zB = _volume_and_buoyancy(x, z, Y, phi, h)
            if V < V0:
                lo = h
            else:
                hi = h
        V, yB, zB = _volume_and_buoyancy(x, z, Y, phi, h)
        gz = sgn * (yB * math.cos(phi) + (zB - kg) * math.sin(phi) - free_surface_m * math.sin(phi))
        edge = float((D * math.cos(phi) - Yd * math.sin(phi)).min() - h)    # <= 0: the lee deck edge is under water somewhere along the length
        out.append({'heel_deg': float(deg), 'GZ_m': float(gz), 'KN_m': float(sgn * (yB * math.cos(phi) + zB * math.sin(phi))), 'deck_edge_clearance_m': edge, 'volume_error_percent': float(abs(V - V0) / V0 * 100)})
    # metacentric height from the slope at the upright position
    gm = None
    if len(out) > 1 and out[0]['heel_deg'] == 0.0 and out[1]['heel_deg'] > 0:
        gm = out[1]['GZ_m'] / math.sin(math.radians(out[1]['heel_deg']))
    return {'mass_t': mass_t, 'volume_m3': V0, 'KG_m': kg, 'free_surface_m': free_surface_m, 'curve': out, 'GM_from_slope_m': gm}


def criteria(res, flooding_angle_deg=None):
    """IMO intact-stability criteria (IS Code 2.2, Res. A.749(18)): areas under GZ 0-30 and 0-40 degrees (or to the flooding angle) and 30-40, GZ at 30 degrees or more, the angle of
    maximum GZ, and the initial GM. flooding_angle_deg defaults to the angle at which the deck edge goes under (the hull model has no openings)."""
    c = res['curve']
    ang = np.array([r['heel_deg'] for r in c])
    gz = np.array([r['GZ_m'] for r in c])
    imm = [r['heel_deg'] for r in c if r['deck_edge_clearance_m'] <= 0]
    deck = min(imm) if imm else None
    fl = flooding_angle_deg or deck
    top = min(40.0, fl) if fl else 40.0

    def area(a0, a1):
        if a1 <= a0:
            return 0.0
        g = np.interp(np.linspace(a0, a1, 400), ang, gz)
        return float(np.trapezoid(g, np.radians(np.linspace(a0, a1, 400))))
    i = int(np.argmax(gz))
    # first angle at which the curve returns to zero (the angle of vanishing stability)
    vanish = None
    for k in range(1, len(gz)):
        if gz[k] <= 0 < gz[k - 1]:
            vanish = float(ang[k - 1] + (ang[k] - ang[k - 1]) * gz[k - 1] / (gz[k - 1] - gz[k]))
            break
    gm0 = res['GM_from_slope_m']
    tests = [
        ('area 0-30 deg >= 0.055 m rad', area(0, 30), 0.055, '>='),
        (f'area 0-{top:g} deg >= 0.090 m rad', area(0, top), 0.090, '>='),
        (f'area 30-{top:g} deg >= 0.030 m rad', area(30, top), 0.030, '>='),
        ('GZ at 30 deg or more >= 0.20 m', float(np.interp(30.0, ang, gz)) if fl is None or fl >= 30 else float(gz[ang <= fl].max()), 0.20, '>='),
        ('angle of maximum GZ >= 25 deg', float(ang[i]), 25.0, '>='),
        ('initial GM >= 0.15 m', float(gm0) if gm0 is not None else float('nan'), 0.15, '>=')]
    rows = [{'criterion': n, 'value': round(v, 4), 'limit': lim, 'pass': bool(v >= lim)} for n, v, lim, _ in tests]
    return {'criteria': rows, 'all_pass': all(r['pass'] for r in rows), 'max_GZ_m': float(gz[i]), 'angle_of_max_GZ_deg': float(ang[i]), 'deck_edge_immersion_deg': deck,
            'angle_of_vanishing_stability_deg': vanish, 'applied_up_to_deg': top}


def plot(res, crit, path, title='GZ curve'):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    ang = [r['heel_deg'] for r in res['curve']]
    gz = [r['GZ_m'] for r in res['curve']]
    fig, ax = plt.subplots(figsize=(8, 4.6))
    ax.plot(ang, gz, 'b-', lw=2, label='GZ')
    ax.axhline(0, color='k', lw=0.6)
    ax.axhline(0.20, color='r', ls=':', lw=1, label='0.20 m at 30 deg')
    ax.axvline(30, color='gray', ls=':', lw=0.8)
    if crit['deck_edge_immersion_deg'] is not None:
        ax.axvline(crit['deck_edge_immersion_deg'], color='orange', ls='--', lw=1, label=f"deck edge under at {crit['deck_edge_immersion_deg']:g} deg")
    ax.set_xlabel('heel [deg]'); ax.set_ylabel('GZ [m]'); ax.grid(alpha=0.3); ax.legend(); ax.set_title(title)
    fig.tight_layout(); fig.savefig(path, dpi=130); plt.close(fig)
    return path
