"""
Hand-calculation checks the assistant can call (answers come from formulas, not from the model's memory).
Units: mm, N, MPa.
"""
import math
from .mesh import with_plate, profile_props

# Roark (7th ed., Table 11.4): rectangular plate, uniform pressure q, short side b, long side a, thickness t
#   sigma_max = beta * q * b^2 / t^2 ;  w_max = alpha * q * b^4 / (E t^3)   (nu = 0.3)
_SS = [(1.0, .2874, .0444), (1.2, .3762, .0616), (1.4, .4530, .0770), (1.6, .5172, .0906), (1.8, .5688, .1017),
       (2.0, .6102, .1110), (3.0, .7134, .1335), (4.0, .7410, .1400), (5.0, .7476, .1417), (1e9, .7500, .1421)]
_CL = [(1.0, .3078, .0138), (1.2, .3834, .0188), (1.4, .4356, .0226), (1.6, .4680, .0251), (1.8, .4872, .0267),
       (2.0, .4974, .0277), (1e9, .5000, .0284)]


def _interp(tab, r):
    for (r0, b0, a0), (r1, b1, a1) in zip(tab, tab[1:]):
        if r <= r1:
            f = (r - r0) / (r1 - r0) if r1 < 1e8 else min(1.0, (r - r0) / (r0 * 2))
            return b0 + f * (b1 - b0), a0 + f * (a1 - a0)
    return tab[-1][1], tab[-1][2]


def plate_pressure(a, b, t, q, boundary='simply', E=206000.0, yield_MPa=235.0):
    """max bending stress and deflection of a rectangular plate field under uniform lateral pressure"""
    a, b = max(a, b), min(a, b)
    beta, alpha = _interp(_SS if boundary == 'simply' else _CL, a / b)
    sig = beta * q * b ** 2 / t ** 2
    w = alpha * q * b ** 4 / (E * t ** 3)
    return {'sigma_max_MPa': round(sig, 2), 'w_max_mm': round(w, 3), 'aspect': round(a / b, 3), 'beta': round(beta, 4),
            'alpha': round(alpha, 4), 'utilisation': round(sig / yield_MPa, 3), 'boundary': boundary,
            'w_over_t': round(w / t, 3),
            'note': 'Roark Table 11.4 small-deflection theory' + ('; w/t > 0.5: membrane action, real stress is lower' if w / t > 0.5 else ''),
            'evidence': f'sigma = {beta:.4f}*q*b^2/t^2, w = {alpha:.4f}*q*b^4/(E t^3), a/b = {a / b:.3f}'}


def stiffener_check(span, spacing, t_plate, profile, q, end='clamped', E=206000.0, yield_MPa=235.0, b_eff=None):
    """stiffener + attached plating as a beam under q*spacing line load"""
    be = b_eff or min(spacing, span / 3)                # simple effective breadth (fixed/clamped beam)
    sec = with_plate(profile, t_plate, be)
    w = q * spacing                                    # N/mm
    if end == 'clamped':
        M, d = w * span ** 2 / 12, w * span ** 4 / (384 * E * sec['I'])
    else:
        M, d = w * span ** 2 / 8, 5 * w * span ** 4 / (384 * E * sec['I'])
    s_toe, s_pl = M / sec['Z_toe'], M / sec['Z_plate']
    return {'M_Nmm': round(M), 'Z_toe_cm3': round(sec['Z_toe'] / 1e3, 2), 'Z_plate_cm3': round(sec['Z_plate'] / 1e3, 2),
            'I_cm4': round(sec['I'] / 1e4, 1), 'sigma_toe_MPa': round(s_toe, 1), 'sigma_plate_MPa': round(s_pl, 1),
            'deflection_mm': round(d, 3), 'utilisation': round(max(s_toe, s_pl) / yield_MPa, 3),
            'effective_breadth_mm': round(be, 1), 'end': end,
            'evidence': f"M = q*s*l^2/{12 if end == 'clamped' else 8}, Z from profile + {be:.0f} mm plating"}


def section(profile, t_plate=None, b_eff=None):
    out = {k: round(v, 3) for k, v in profile_props(profile).items()}
    if t_plate and b_eff:
        out['with_plate'] = {k: round(v, 3) for k, v in with_plate(profile, t_plate, b_eff).items()}
    return out


def beam(L, E, I, load, support='simply', kind='udl', c=None):
    """classic beams. load: N/mm for udl, N for point. returns M_max, deflection"""
    if support == 'cantilever':
        M, d = (load * L ** 2 / 2, load * L ** 4 / (8 * E * I)) if kind == 'udl' else (load * L, load * L ** 3 / (3 * E * I))
    elif support == 'clamped':
        M, d = (load * L ** 2 / 12, load * L ** 4 / (384 * E * I)) if kind == 'udl' else (load * L / 8, load * L ** 3 / (192 * E * I))
    else:
        M, d = (load * L ** 2 / 8, 5 * load * L ** 4 / (384 * E * I)) if kind == 'udl' else (load * L / 4, load * L ** 3 / (48 * E * I))
    out = {'M_max': M, 'deflection': d, 'support': support, 'kind': kind}
    if c:
        out['sigma_max'] = M * c / I
    return out


def plate_buckling(a, b, t, E=206000.0, nu=0.3, k=4.0, yield_MPa=235.0):
    """elastic buckling of a plate field in uniaxial compression (k=4 simply supported, long plate), Johnson-Ostenfeld correction"""
    se = k * math.pi ** 2 * E / (12 * (1 - nu ** 2)) * (t / b) ** 2
    sc = se if se <= yield_MPa / 2 else yield_MPa * (1 - yield_MPa / (4 * se))
    return {'sigma_E_MPa': round(se, 1), 'sigma_cr_MPa': round(sc, 1), 'k': k, 'b_over_t': round(b / t, 1),
            'evidence': 'sigma_E = k pi^2 E/(12(1-nu^2)) (t/b)^2; Johnson-Ostenfeld above yield/2'}
