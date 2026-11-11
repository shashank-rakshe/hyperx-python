"""
Bolted joints - metric ISO coarse threads, ISO 898-1 property classes, VDI 2230 Part 1 tightening formulas.

  stress area     A_s = pi/4 * ((d2 + d3)/2)^2,  d2 = d - 0.649519 P,  d3 = d - 1.226869 P              (ISO 898-1)
  assembly preload (VDI 2230, R7 / eq. 5.5/1): equivalent stress during tightening = nu * Rp0.2
                  F_M,zul = nu * Rp0.2 * A0 / sqrt(1 + 3 * (3/2 * d2/d0 * (P/(pi d2) + 1.155 mu_G))^2),  d0 = (d2+d3)/2
  tightening torque  M_A = F_M * (0.16 P + 0.58 d2 mu_G + D_Km/2 * mu_K),  D_Km = (d_w + d_h)/2           (VDI 2230)
  with an axial working load F_A and load factor Phi (from the joint stiffness; ~0.1-0.3 for stiff clamped parts):
      bolt extra load F_SA = Phi F_A, residual clamp F_KR = F_M,min - (1 - Phi) F_A - F_Z
      max bolt stress (F_M + F_SA) / A_s vs Rp0.2;  alternating stress Phi F_A / (2 A_s) vs the endurance limit of
      bolts rolled before heat treatment sigma_ASV = 0.85 * (150/d + 45) MPa                                (VDI 2230)
  scatter of the tightening method (alpha_A): F_M,min = F_M,zul / alpha_A
Units: mm, N, N m, MPa. These are the standard formulas written out here; check the current standard before use.
"""
import math

PITCH = {3: 0.5, 4: 0.7, 5: 0.8, 6: 1.0, 8: 1.25, 10: 1.5, 12: 1.75, 14: 2.0, 16: 2.0, 18: 2.5, 20: 2.5, 22: 2.5, 24: 3.0,
         27: 3.0, 30: 3.5, 33: 3.5, 36: 4.0, 42: 4.5, 48: 5.0}
HEAD_S = {3: 5.5, 4: 7, 5: 8, 6: 10, 8: 13, 10: 16, 12: 18, 14: 21, 16: 24, 18: 27, 20: 30, 22: 34, 24: 36, 27: 41, 30: 46,
          33: 50, 36: 55, 42: 65, 48: 75}              # hexagon width across flats (ISO 4014 / 4017)
HOLE_MEDIUM = {3: 3.4, 4: 4.5, 5: 5.5, 6: 6.6, 8: 9, 10: 11, 12: 13.5, 14: 15.5, 16: 17.5, 18: 20, 20: 22, 22: 24, 24: 26,
               27: 30, 30: 33, 33: 36, 36: 39, 42: 45, 48: 52}   # ISO 273 medium clearance hole
CLASSES = {   # property class -> (Rp0.2 or ReL, Rm) MPa, ISO 898-1 (8.8: d <= 16 / d > 16) and ISO 3506 (stainless)
    '4.6': (240, 400), '5.6': (300, 500), '8.8': (640, 800), '8.8>16': (660, 830), '10.9': (940, 1040), '12.9': (1100, 1220),
    'A2-70': (450, 700), 'A4-70': (450, 700), 'A4-80': (600, 800)}
ALPHA_A = {'torque wrench': 1.6, 'torque': 1.6, 'impact': 2.5, 'yield': 1.0, 'angle': 1.0, 'hydraulic tensioner': 1.4,
           'ultrasonic': 1.2}


def thread(d, pitch=None):
    P = pitch or PITCH.get(int(d)) if float(d).is_integer() else pitch
    if not P:
        raise ValueError(f'give the pitch for M{d:g} (not a standard coarse size)')
    d2, d3 = d - 0.649519 * P, d - 1.226869 * P
    d0 = (d2 + d3) / 2
    return {'d': d, 'P': P, 'd2': d2, 'd3': d3, 'd0': d0, 'As': math.pi / 4 * d0 ** 2}


def joint(d, cls='8.8', mu_G=0.12, mu_K=0.12, nu=0.9, pitch=None, d_w=None, d_h=None, method='torque wrench',
          F_A=None, Phi=0.2, F_Z=0.0, F_Kerf=None):
    t = thread(float(d), pitch)
    key = '8.8>16' if str(cls) == '8.8' and d > 16 else str(cls)
    if key not in CLASSES:
        raise ValueError(f'unknown property class {cls}; known: {", ".join(k for k in CLASSES if ">" not in k)}')
    Rp, Rm = CLASSES[key]
    P, d2 = t['P'], t['d2']
    k = 3 / 2 * d2 / t['d0'] * (P / (math.pi * d2) + 1.155 * mu_G)
    F_M = nu * Rp * t['As'] / math.sqrt(1 + 3 * k ** 2)
    dw = d_w or HEAD_S.get(int(d), 1.5 * d)
    dh = d_h or HOLE_MEDIUM.get(int(d), 1.1 * d)
    D_Km = (dw + dh) / 2
    M_A = F_M * (0.16 * P + 0.58 * d2 * mu_G + D_Km / 2 * mu_K) / 1000          # N m
    alpha = ALPHA_A.get(str(method).lower(), float(method) if str(method).replace('.', '', 1).isdigit() else 1.6)
    F_Mmin = F_M / alpha
    out = {'size': f'M{d:g}x{P:g}', 'class': str(cls), 'Rp02_MPa': Rp, 'Rm_MPa': Rm, 'As_mm2': round(t['As'], 2),
           'd2_mm': round(d2, 3), 'd3_mm': round(t['d3'], 3), 'mu_G': mu_G, 'mu_K': mu_K, 'nu': nu,
           'F_M_zul_kN': round(F_M / 1000, 2), 'M_A_Nm': round(M_A, 1), 'D_Km_mm': round(D_Km, 2),
           'tightening': str(method), 'alpha_A': alpha, 'F_M_min_kN': round(F_Mmin / 1000, 2)}
    lines = [f"An {out['size']} bolt of class {cls} (yield {Rp} MPa) has a stress area of {t['As']:.1f} mm2. Tightened to "
             f"{nu * 100:.0f} % of its yield (VDI 2230) with thread friction {mu_G:g} and head friction {mu_K:g}, it carries an "
             f"assembly preload of {F_M / 1000:.1f} kN, reached with a tightening torque of {M_A:.0f} N m."]
    if alpha > 1:
        lines.append(f"With {method} tightening the preload scatters by a factor {alpha:g}, so plan with at least "
                     f"{F_Mmin / 1000:.1f} kN.")
    if F_A:
        F_SA = Phi * F_A
        F_KR = F_Mmin - (1 - Phi) * F_A - F_Z
        s_max = (F_M + F_SA) / t['As']
        s_a = F_SA / (2 * t['As'])
        s_ASV = 0.85 * (150 / d + 45)
        out.update(F_A_kN=round(F_A / 1000, 2), Phi=Phi, F_SA_kN=round(F_SA / 1000, 2), F_KR_kN=round(F_KR / 1000, 2),
                   sigma_max_MPa=round(s_max, 1), sigma_a_MPa=round(s_a, 1), sigma_ASV_MPa=round(s_ASV, 1),
                   static_ok=s_max <= Rp, fatigue_ok=s_a <= s_ASV, clamp_ok=F_KR >= (F_Kerf or 0))
        lines.append(f"Under an axial working load of {F_A / 1000:g} kN (load factor {Phi:g}) the bolt takes {F_SA / 1000:.2f} kN "
                     f"more: its highest stress is {s_max:.0f} MPa ({'below' if s_max <= Rp else 'ABOVE'} the yield {Rp} MPa); "
                     f"the alternating stress {s_a:.1f} MPa is {'within' if s_a <= s_ASV else 'ABOVE'} the endurance limit "
                     f"{s_ASV:.0f} MPa; the joint keeps {F_KR / 1000:.1f} kN of clamping force"
                     + (f" ({'enough' if F_KR >= F_Kerf else 'NOT enough'} for the required {F_Kerf / 1000:g} kN)" if F_Kerf else
                        (' (it opens - preload too low)' if F_KR <= 0 else '')) + '.')
    lines.append('(Formulas of VDI 2230 Part 1 and ISO 898-1 as written in ShipBrain; check the current standard and the '
                 'friction values of your parts.)')
    out['plain_english'] = ' '.join(lines)
    return out


# ====================================================================== inch bolts (UNC / UNF), US practice
# tensile stress area A_t = 0.7854 (D - 0.9743 / n)^2 in2 (ASME B1.1); preload F_i = c A_t S_p with c = 0.75 for reused,
# 0.90 for permanent joints; torque T = K D F_i with the nut factor K (0.20 plain, 0.15 lubricated) (Shigley)
INCH = {   # size -> (major diameter in, UNC threads per inch, UNF threads per inch)
    '#2': (0.086, 56, 64), '#4': (0.112, 40, 48), '#5': (0.125, 40, 44), '#6': (0.138, 32, 40), '#8': (0.164, 32, 36),
    '#10': (0.190, 24, 32), '1/4': (0.25, 20, 28), '5/16': (0.3125, 18, 24), '3/8': (0.375, 16, 24), '7/16': (0.4375, 14, 20),
    '1/2': (0.5, 13, 20), '9/16': (0.5625, 12, 18), '5/8': (0.625, 11, 18), '3/4': (0.75, 10, 16), '7/8': (0.875, 9, 14),
    '1': (1.0, 8, 12), '1-1/8': (1.125, 7, 12), '1-1/4': (1.25, 7, 12), '1-3/8': (1.375, 6, 12), '1-1/2': (1.5, 6, 12),
    '1-3/4': (1.75, 5, None), '2': (2.0, 4.5, None)}
GRADES = {  # grade -> list of (largest diameter in, proof strength ksi) (SAE J429, ASTM F3125)
    '2': [(0.75, 55), (1.5, 33)], '5': [(1.0, 85), (1.5, 74)], '8': [(1.5, 120)], 'A325': [(1.5, 85)], 'A490': [(1.5, 120)]}


def inch_joint(size, thread='UNC', grade='5', c=0.75, K=0.20, F_ext_lbf=None):
    s = str(size).strip().replace('"', '').replace(' in', '')
    if s not in INCH:
        raise ValueError(f'unknown inch size {size}; known: {", ".join(INCH)}')
    D, unc, unf = INCH[s]
    n = unc if str(thread).upper() == 'UNC' else unf
    if not n:
        raise ValueError(f'{s} has no {thread} thread in the table')
    At = 0.7854 * (D - 0.9743 / n) ** 2
    g = str(grade).upper().replace('GRADE', '').strip()
    rows = GRADES.get(g)
    if not rows:
        raise ValueError(f'unknown grade {grade}; known: {", ".join(GRADES)}')
    Sp = next((p for dmax, p in rows if D <= dmax + 1e-9), None)
    if Sp is None:
        raise ValueError(f'grade {g} is not listed for {s} in')
    Fi = c * At * Sp * 1000
    T = K * D * Fi
    out = {'size': f'{s}-{n:g} {str(thread).upper()}', 'grade': g, 'D_in': D, 'At_in2': round(At, 4), 'proof_ksi': Sp, 'c': c, 'K': K,
           'preload_lbf': round(Fi), 'preload_kN': round(Fi * 4.44822 / 1000, 2), 'torque_in_lbf': round(T), 'torque_ft_lbf': round(T / 12, 1),
           'torque_Nm': round(T * 0.112985, 1)}
    pe = (f"A {out['size']} bolt, grade {g} (proof strength {Sp} ksi), has a tensile stress area of {At:.4f} in2. Preloaded to "
          f"{c * 100:.0f} % of its proof load it carries {Fi:,.0f} lbf ({out['preload_kN']} kN), which needs a torque of "
          f"{T / 12:,.1f} ft-lbf ({out['torque_Nm']} N m) with a nut factor of {K:g}.")
    if F_ext_lbf:
        out['external_lbf'] = F_ext_lbf
        out['separates'] = F_ext_lbf >= Fi
        pe += f" An external load of {F_ext_lbf:,.0f} lbf {'is MORE than' if F_ext_lbf >= Fi else 'stays below'} the preload."
    pe += ' (ASME B1.1 stress area, SAE J429 / ASTM F3125 proof strengths, Shigley preload and nut-factor torque.)'
    out['plain_english'] = pe
    return out
