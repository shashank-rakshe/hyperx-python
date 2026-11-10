"""Fourier tools for SCANNED drawings (owner 2026-11-05: 'fourier tracing on scanned drawing'). Universal, image only.

R-FT1 skew      2D FFT of the binarised page: the ruled lines of a drawing put their energy on two perpendicular spectral
                spokes; the spoke angle = page skew. Pages skewed 0.05-3 deg are rotated back before any line / text reading.
R-FT2 dashes    1D FFT of the ink profile along a line: a dashed / chain line has ONE strong period (dash + gap). Used when the
                dash gaps are too irregular for the gap test (faded / broken scan dashes).
R-FT3 shapes    Fourier descriptors of a closed outline (centroid distance r(s), FFT magnitudes / |c0|): invariant to position,
                size, rotation and start point. triangle -> strong 3rd harmonic, circle -> flat, revision cloud -> strong peak at
                a high harmonic (= number of bulges, >= 6) on top of a round outline."""
import numpy as np
import cv2


def estimate_skew(gray, max_deg=3.0, step=0.02, size=1024):
    """-> skew angle in degrees (positive = counter-clockwise content), 0.0 when no clear spoke"""
    h, w = gray.shape
    f = size / max(h, w)
    small = cv2.resize(gray, (max(8, int(w * f)), max(8, int(h * f))), interpolation=cv2.INTER_AREA)
    b = (small < 160).astype(np.float32)
    if b.mean() < 0.002:
        return 0.0
    n = size
    pad = np.zeros((n, n), np.float32)
    pad[:b.shape[0], :b.shape[1]] = b - b.mean()
    F = np.abs(np.fft.fftshift(np.fft.fft2(pad)))
    F = np.log1p(F)
    c = n // 2
    rr = np.arange(int(0.08 * n), int(0.45 * n))
    best, ba = -1.0, 0.0
    for a in np.arange(-max_deg, max_deg + 1e-9, step):
        e = 0.0
        for base in (0.0, 90.0):
            t = np.deg2rad(base + a)
            xs = (c + rr * np.cos(t)).astype(int); ys = (c - rr * np.sin(t)).astype(int)
            e += F[ys, xs].sum()
        if e > best:
            best, ba = e, a
    e0 = 0.0
    for base in (0.0, 90.0):
        t = np.deg2rad(base + max_deg + 2)
        xs = (c + rr * np.cos(t)).astype(int); ys = (c - rr * np.sin(t)).astype(int)
        e0 += F[ys, xs].sum()
    return float(ba) if best > 1.15 * e0 else 0.0


def deskew(gray, angle):
    if abs(angle) < 0.05:
        return gray
    h, w = gray.shape
    M = cv2.getRotationMatrix2D((w / 2, h / 2), -angle, 1.0)
    return cv2.warpAffine(gray, M, (w, h), flags=cv2.INTER_LINEAR, borderValue=255)


def line_period(profile, min_p=4, max_p=200):
    """profile: ink 0/1 along a line (pixels) -> (period_px, strength 0..1, ink_fraction); period None when no clear one"""
    p = np.asarray(profile, np.float32)
    if len(p) < 3 * min_p:
        return None, 0.0, float(p.mean()) if len(p) else 0.0
    ink = float(p.mean())
    x = p - p.mean()
    if not x.any():
        return None, 0.0, ink
    S = np.abs(np.fft.rfft(x)) ** 2
    fr = np.fft.rfftfreq(len(x))
    ok = (fr >= 1.0 / max_p) & (fr <= 1.0 / min_p)
    if not ok.any():
        return None, 0.0, ink
    k = np.argmax(np.where(ok, S, 0))
    strength = float(S[k] / S[1:].sum()) if S[1:].sum() > 0 else 0.0
    return (float(1.0 / fr[k]) if strength > 0.12 else None), strength, ink


def descriptors(contour, n=16, samples=128):
    """closed outline (N,2) -> normalised Fourier magnitudes |c_k| / |c_0|, k = 1..n of the centroid-distance signature"""
    c = np.asarray(contour, np.float64).reshape(-1, 2)
    if len(c) < 5:
        return None
    seg = np.r_[0, np.cumsum(np.hypot(*np.diff(np.vstack([c, c[:1]]), axis=0).T))]
    L = seg[-1]
    if L <= 0:
        return None
    s = np.linspace(0, L, samples, endpoint=False)
    cc = np.vstack([c, c[:1]])
    x = np.interp(s, seg, cc[:, 0]); y = np.interp(s, seg, cc[:, 1])
    r = np.hypot(x - x.mean(), y - y.mean())
    F = np.abs(np.fft.rfft(r))
    if F[0] <= 0:
        return None
    return F[1:n + 1] / F[0]


def turning_spectrum(contour, n=40, samples=256):
    """FFT magnitudes k = 1..n of the turning-angle function (tangent angle minus the mean turn): independent of elongation,
    so a long revision cloud and a round one give the same peak at k = number of bulges"""
    c = np.asarray(contour, np.float64).reshape(-1, 2)
    if len(c) < 6:
        return None
    cc = np.vstack([c, c[:1]])
    seg = np.r_[0, np.cumsum(np.hypot(*np.diff(cc, axis=0).T))]
    L = seg[-1]
    s = np.linspace(0, L, samples + 1)
    x = np.interp(s, seg, cc[:, 0]); y = np.interp(s, seg, cc[:, 1])
    kz = max(3, samples // 128) | 1                      # scan noise: circular moving average along the outline
    ker = np.ones(kz) / kz
    x = np.convolve(np.r_[x[-kz:-1], x, x[1:kz]], ker, 'same')[kz - 1:kz - 1 + len(x)]
    y = np.convolve(np.r_[y[-kz:-1], y, y[1:kz]], ker, 'same')[kz - 1:kz - 1 + len(y)]
    th = np.unwrap(np.arctan2(np.diff(y), np.diff(x)))
    th = th - np.linspace(0, th[-1] - th[0], len(th)) - th[0]
    F = np.abs(np.fft.rfft(th - th.mean())) / len(th)
    return F[1:n + 1]


def classify(contour):
    """-> 'circle' | 'triangle' | 'cloud' | None"""
    d = descriptors(contour, n=40, samples=256)
    if d is None:
        return None
    low = d[:5]
    T = turning_spectrum(contour, n=80, samples=1024)
    if T is not None:
        k = int(np.argmax(T[5:80])) + 6
        nb = [T[j - 1] for j in range(max(6, k - 4), min(80, k + 4) + 1) if j != k]
        c32 = np.asarray(contour, np.float32).reshape(-1, 1, 2)
        nv = len(cv2.approxPolyDP(c32, 0.005 * cv2.arcLength(c32, True), True))
        if T[k - 1] > 0.1 and T[k - 1] > 3.0 * (np.mean(nb) + 1e-6) and nv > 8:
            return 'cloud'                 # many equal bulges: one sharp high harmonic of the turning angle, not a polygon
    if d[:40].max() < 0.02:
        return 'circle'
    if d[2] > 0.06 and d[2] >= 0.8 * low.max() and d[1] < 0.6 * d[2] + 0.05:
        return 'triangle'
    return None
