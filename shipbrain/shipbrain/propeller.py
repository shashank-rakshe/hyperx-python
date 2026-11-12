"""
Propeller open-water performance by blade-element-momentum theory - ShipBrain's own teaching-level code (written from the textbook method; not derived from the unlicensed propeller repositories).

  actuator_disk(T, V, D)        momentum theory: thrust loading CT and the ideal efficiency  eta_i = 2 / (1 + sqrt(1 + CT))  (the upper limit of any propeller at that loading)
  bem(...)                      blade elements from hub to tip: induced axial (a) and tangential (a') factors by momentum with the Prandtl tip and hub loss, section lift
                                CL = 2 pi (alpha - alpha0) up to a stall angle, drag CD; thrust and torque coefficients KT, KQ and open-water efficiency eta0 against the advance ratio J = V / (n D)

Defaults: constant pitch, elliptical chord distribution scaled to the expanded area ratio, zero-lift angle -2 degrees, CD = 0.03 (section drag incl. thickness and roughness), 40 elements. This is NOT a propeller design program: real propellers
have radial pitch and camber distributions, skew and rake, and cavitation. Checked against closed forms (zero thrust at J = P/D for flat sections, the ideal-efficiency bound, momentum balance).
"""
import math

import numpy as np

RHO = 1025.0
G = 9.81


def actuator_disk(T, V, D, rho=RHO):
    A = math.pi * D * D / 4
    CT = T / (0.5 * rho * V * V * A) if V > 0 else float('inf')
    return {'CT': CT, 'ideal_efficiency': 2.0 / (1.0 + math.sqrt(1.0 + CT)), 'induced_velocity_ratio': 0.5 * (math.sqrt(1.0 + CT) - 1.0)}


def chord_distribution(ear, Z, hub_ratio, n):
    """elliptical chord c/R at x = r/R from hub to tip, scaled so that Z * integral(c) dr / (pi R^2) = EAR"""
    x = np.linspace(hub_ratio, 1.0, n + 2)[1:-1]
    shape = np.sqrt(np.clip(1.0 - ((x - hub_ratio) / (1.0 - hub_ratio)) ** 2, 1e-6, None))
    area = float(np.trapezoid(np.sqrt(np.clip(1.0 - ((np.linspace(hub_ratio, 1, 400) - hub_ratio) / (1 - hub_ratio)) ** 2, 0, None)), np.linspace(hub_ratio, 1, 400)))
    c0 = ear * math.pi / (Z * area)                                        # c / R at the widest point
    return x, c0 * shape


def bem(J, Z=4, pitch_ratio=1.0, ear=0.6, hub_ratio=0.2, n=40, alpha0_deg=-2.0, cd=0.03, stall_deg=12.0, a_pitch=None):
    """KT, KQ, eta0 at the advance ratio J (one value); a_pitch = optional function x -> P/D for a radial pitch distribution.
    Velocities in units of omega R: lam = V / (omega R) = J / pi; u = axial induced velocity, ut = tangential induced velocity; momentum (with the Prandtl loss F):
        u (lam + u) = S cn,   ut (lam + u) = S ct,   S = Z c w^2 / (8 pi x F),   w^2 = (lam + u)^2 + (x - ut)^2     (c = chord / R, x = r / R)"""
    x, c = chord_distribution(ear, Z, hub_ratio, n)
    lam = J / math.pi
    dx = (1.0 - hub_ratio) / n
    a0 = math.radians(alpha0_deg)
    ast = math.radians(stall_deg)
    dKT = dKQ = 0.0
    for xi, ci in zip(x, c):
        pd = a_pitch(xi) if a_pitch else pitch_ratio
        theta = math.atan(pd / (math.pi * xi))                               # tan(theta) = P / (2 pi r) = pd D / (2 pi x R) = pd / (pi x)
        u, ut = 0.0, 0.0
        for _ in range(300):
            Va, Vt = lam + u, xi - ut
            phi = math.atan2(Va, Vt)
            sphi = max(math.sin(phi), 1e-4)
            f_tip = (Z / 2) * (1 - xi) / (xi * sphi)
            f_hub = (Z / 2) * (xi - hub_ratio) / (xi * sphi)
            F = max((2 / math.pi) ** 2 * math.acos(min(1.0, math.exp(-f_tip))) * math.acos(min(1.0, math.exp(-f_hub))), 0.05)
            alpha_c = max(-ast, min(ast, theta - phi - a0))
            CL = 2 * math.pi * alpha_c
            CD = cd + 0.5 * alpha_c ** 2
            cn = CL * math.cos(phi) - CD * math.sin(phi)
            ct = CL * math.sin(phi) + CD * math.cos(phi)
            S = Z * ci * (Va * Va + Vt * Vt) / (8 * math.pi * xi * F)
            disc = lam * lam + 4 * S * cn
            u_new = 0.5 * (-lam + math.sqrt(disc)) if disc > 0 else -0.5 * lam
            ut_new = S * ct / max(lam + u_new, 1e-9)
            u_new = min(max(u_new, -0.45 * lam), 4.0)
            ut_new = min(max(ut_new, -0.2 * xi), 0.8 * xi)                                  # keeps the inflow geometry finite at the hub and tip elements
            un, utn = 0.5 * u + 0.5 * u_new, 0.5 * ut + 0.5 * ut_new
            done = abs(un - u) < 1e-9 and abs(utn - ut) < 1e-9
            u, ut = un, utn
            if done:
                break
        Va, Vt = lam + u, xi - ut
        phi = math.atan2(Va, Vt)
        alpha_c = max(-ast, min(ast, theta - phi - a0))
        CL = 2 * math.pi * alpha_c
        CD = cd + 0.5 * alpha_c ** 2
        W2 = Va * Va + Vt * Vt
        dKT += Z * 0.5 * W2 * ci * (CL * math.cos(phi) - CD * math.sin(phi)) * dx            # in rho omega^2 R^4
        dKQ += Z * 0.5 * W2 * ci * (CL * math.sin(phi) + CD * math.cos(phi)) * xi * dx       # in rho omega^2 R^5
    KT = float(dKT) * (4 * math.pi ** 2) / 16.0                                              # T = rho n^2 D^4 KT, omega = 2 pi n, R = D / 2
    KQ = float(dKQ) * (4 * math.pi ** 2) / 32.0
    eta = (J / (2 * math.pi)) * KT / KQ if KQ > 1e-12 and KT > 0 else 0.0
    return {'J': J, 'KT': KT, 'KQ': KQ, 'eta0': float(eta)}


def curve(Js, **kw):
    return [bem(J, **kw) for J in Js]


def performance(D, rpm, speed_kn, Z=4, pitch_ratio=1.0, ear=0.6, hub_ratio=0.2, immersion_m=None, rho=RHO, **kw):
    """thrust, torque, power and the cavitation number at a speed and rpm"""
    n = rpm / 60.0
    V = speed_kn * 0.514444
    J = V / (n * D)
    r = bem(J, Z=Z, pitch_ratio=pitch_ratio, ear=ear, hub_ratio=hub_ratio, **kw)
    T = r['KT'] * rho * n * n * D ** 4
    Q = r['KQ'] * rho * n * n * D ** 5
    out = {'J': J, 'KT': r['KT'], 'KQ': r['KQ'], 'eta0': r['eta0'], 'thrust_kN': T / 1000, 'torque_kNm': Q / 1000, 'power_kW': 2 * math.pi * n * Q / 1000, 'delivered_efficiency_check': (T * V) / (2 * math.pi * n * Q) if Q > 0 else None}
    if V > 0 and T > 0:
        out['actuator_disk'] = actuator_disk(T, V, D, rho)
    if immersion_m is not None:
        pv = 1700.0
        sigma = (101325.0 + rho * G * immersion_m - pv) / (0.5 * rho * (V * V + (0.7 * math.pi * n * D) ** 2))
        out['cavitation_number_07R'] = sigma
    return out
