import math, os, pytest
import numpy as np
from shipbrain import propdesign as PD, bladex_bridge as BB


@pytest.fixture(scope='module')
def dsg():
    return PD.design(4, 300, 3.0, 200e3, 6.0, curve=True)


def test_design_delivers_the_requested_thrust(dsg):
    assert dsg['design_KT'] == pytest.approx(dsg['kt_from_thrust'], rel=0.01)        # KT from the optimiser = thrust / (rho n2 D4)


def test_efficiency_below_actuator_disk_and_curve_shape(dsg):
    assert 0.3 < dsg['design_efficiency'] < dsg['actuator_disk_efficiency']
    c = dsg['curve']
    kts = [x['KT'] for x in c]
    assert all(a < b + 1e-9 for b, a in zip(kts, kts[1:]))                           # J ascending: KT falls
    assert any(x['J'] <= dsg['design_J'] for x in c)


def test_duct_changes_thrust_split_but_still_converges():
    r = PD.design(4, 300, 3.0, 200e3, 6.0, duct=True, tau=0.9, curve=False)
    assert 0.0 < r['design_efficiency'] < 1.0


def test_blade_stl_is_closed_with_the_right_volume(tmp_path):
    r = np.linspace(0.12, 0.5, 8)
    up, dn = BB.blade(r, np.full(8, 0.2), np.full(8, 0.9), np.zeros(8), np.zeros(8), naca='0012', n_points=60)
    p = BB.write_stl(up, dn, str(tmp_path / 'b.stl'))
    import re
    v = np.array([[float(x) for x in m] for m in re.findall(r'vertex (\S+) (\S+) (\S+)', open(p).read())]).reshape(-1, 3, 3)
    vol = np.einsum('ij,ij->', v[:, 0], np.cross(v[:, 1], v[:, 2])) / 6                 # signed: positive means every triangle faces outwards
    d = {'volume': vol}
    # untwisted constant 12 % NACA blade: volume ~ 0.685 * t * c^2 ... area of NACA 0012 = 0.0822 c^2, span 0.38 (pitch twist lengthens it slightly)
    assert d['volume'] == pytest.approx(0.0822 * 0.2 ** 2 * 0.38, rel=0.03)


def test_blade_checks_lengths():
    with pytest.raises(ValueError):
        BB.blade([0.1, 0.2], [0.1], [0.5, 0.5], [0, 0], [0, 0])
