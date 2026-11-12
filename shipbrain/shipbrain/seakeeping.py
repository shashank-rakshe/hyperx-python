"""
Natural periods and a simple regular-wave response of a generated hull - ShipBrain's own teaching-level estimates (closed-form, no strip theory, no forward-speed effects). Written from the standard
textbook expressions; NOT a seakeeping program and not checked against model tests.

  roll   IMO IS Code 2008 (2.3.4) roll period  T = 2 C B / sqrt(GM),  C = 0.373 + 0.023 B/d - 0.043 L/100 ;  and the radius-of-gyration form  T = 2 pi k / sqrt(g GM),  k = 0.4 B
  heave  T = 2 pi sqrt((M + A33) / (rho g Awp)),  A33 = sum over the length of rho (pi / 8) b(x)^2   (a semi-circular section's added mass; about +-20 % for real sections)
  pitch  T = 2 pi sqrt((Iyy + A55) / (rho g IL)),  Iyy = M (0.25 L)^2,  A55 = Iyy,  IL = longitudinal waterplane inertia

  response (one degree of freedom, regular waves, beam waves for roll and head waves for heave):
      heave  RAO = f(ratio) e^{-k T_d},  ratio = encounter / natural frequency   f = 1 / sqrt((1 - ratio^2)^2 + (2 zeta ratio)^2)
      roll   RAO (in units of the wave slope) = f(ratio),  wave slope amplitude = k a
Damping ratios are inputs (defaults heave 0.2, pitch 0.2, roll 0.07 - bare hull, no bilge keels). Resonance is flagged: the answers near it are dominated by the damping you assume.
"""
import math

import numpy as np

from . import hullgen as H

G = 9.81


def periods(p, kg, draft=None, rho=1025.0, nx=401, nz=121):
    """roll, heave and pitch natural periods (s) with the numbers they came from"""
    T = float(draft or p['T'])
    c = H.coefficients(p, T=T, nx=nx, nz=nz)
    V = c['volume_m3']
    M = rho * V
    f = H.make_surface(p)
    x = np.linspace(0, H.loa(p), nx)
    z = np.linspace(0, T, nz)
    Y = f(x[:, None], z[None, :])
    b = 2 * Y[:, -1]                                                        # waterline breadth along the length
    Awp = c['Awp_m2']
    xf = c['LCF_m']
    IL = float(np.trapezoid(b * (x - xf) ** 2, x))                          # longitudinal waterplane inertia about the centre of flotation
    It = float(np.trapezoid(b ** 3 / 12.0, x))                              # transverse
    KB, BM = c['KB_m'], It / V
    GM = KB + BM - kg
    out = {'draft_m': T, 'displacement_t': M / 1000.0, 'KB_m': KB, 'BMt_m': BM, 'GMt_m': GM, 'Awp_m2': Awp}
    B, L = p['B'], p['L']
    if GM > 0:
        C = 0.373 + 0.023 * B / T - 0.043 * L / 100.0
        out['roll_period_imo_s'] = 2 * C * B / math.sqrt(GM)
        out['roll_period_k04B_s'] = 2 * math.pi * 0.4 * B / math.sqrt(G * GM)
    else:
        out['roll_period_imo_s'] = out['roll_period_k04B_s'] = None
    A33 = rho * float(np.trapezoid(math.pi / 8.0 * b ** 2, x))
    out['added_mass_heave_t'] = A33 / 1000.0
    out['heave_period_s'] = 2 * math.pi * math.sqrt((M + A33) / (rho * G * Awp))
    Iyy = M * (0.25 * L) ** 2
    out['pitch_period_s'] = 2 * math.pi * math.sqrt((Iyy + Iyy) / (rho * G * IL))
    out['assumptions'] = 'heave added mass of semi-circular sections; pitch radius of gyration 0.25 L and added inertia equal to the hull inertia; no forward speed'
    return out


def _amp(ratio, zeta):
    return 1.0 / math.sqrt((1 - ratio ** 2) ** 2 + (2 * zeta * ratio) ** 2)


def response(p, kg, wave_period_s, wave_amplitude_m=1.0, draft=None, rho=1025.0, zeta_heave=0.2, zeta_roll=0.07):
    """heave amplitude (head waves) and roll amplitude (beam waves) in a regular wave of the given period: one degree of freedom each"""
    per = periods(p, kg, draft, rho)
    w = 2 * math.pi / wave_period_s
    k = w * w / G
    T = per['draft_m']
    out = {'wave_period_s': wave_period_s, 'wavelength_m': 2 * math.pi / k, 'wave_amplitude_m': wave_amplitude_m, 'periods': per}
    wh = 2 * math.pi / per['heave_period_s']
    r = w / wh                                                                # zero speed: encounter = wave frequency
    out['heave'] = {'frequency_ratio': r, 'rao': _amp(r, zeta_heave) * math.exp(-k * T), 'amplitude_m': wave_amplitude_m * _amp(r, zeta_heave) * math.exp(-k * T), 'near_resonance': abs(r - 1) < 0.15}
    if per['roll_period_imo_s']:
        wr = 2 * math.pi / per['roll_period_imo_s']
        rr = w / wr
        slope = k * wave_amplitude_m
        out['roll'] = {'frequency_ratio': rr, 'rao': _amp(rr, zeta_roll), 'amplitude_deg': math.degrees(slope * _amp(rr, zeta_roll)), 'wave_slope_deg': math.degrees(slope), 'near_resonance': abs(rr - 1) < 0.15}
    return out
