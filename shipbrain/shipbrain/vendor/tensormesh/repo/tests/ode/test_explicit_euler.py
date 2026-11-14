import sys
sys.path.append('../..')
import pytest
import torch

from tensormesh.ode import ExplicitEuler


class _MyExplicitEuler(ExplicitEuler):
    """du/dt = u"""
    def forward(self, t, u):
        return u


def test_explicit_euler():
    u0 = torch.rand(4).double()
    dt = 0.1
    ut_gt = u0 + dt * u0
    ut_my = _MyExplicitEuler().step(0, u0, dt)
    assert ut_my.dtype == torch.float64
    assert torch.allclose(ut_gt, ut_my)


@pytest.mark.skipif(not torch.cuda.is_available(), reason="CUDA required")
def test_explicit_euler_cuda():
    u0 = torch.rand(4, dtype=torch.float64, device='cuda')
    dt = 0.1
    ut_gt = u0 + dt * u0
    ut_my = _MyExplicitEuler().step(0, u0, dt)
    assert ut_my.device.type == 'cuda'
    assert ut_my.dtype == torch.float64
    assert torch.allclose(ut_gt, ut_my)
