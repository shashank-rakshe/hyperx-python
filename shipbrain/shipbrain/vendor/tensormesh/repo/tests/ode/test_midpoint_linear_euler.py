import sys
sys.path.append('../..')
import pytest
import torch

from tensormesh.ode import MidPointLinearEuler


def test_midpoint_linear_euler():
    u0 = torch.rand(4).double()
    dt = 0.1
    ut_gt = ((dt + 2) / (2 - dt)) * u0
    ut_my = MidPointLinearEuler().step(0, u0, dt)
    assert ut_my.dtype == torch.float64
    assert torch.allclose(ut_gt, ut_my), f"expected {ut_gt}, got {ut_my}"


@pytest.mark.skipif(not torch.cuda.is_available(), reason="CUDA required")
def test_midpoint_linear_euler_cuda():
    u0 = torch.rand(4, dtype=torch.float64, device='cuda')
    dt = 0.1
    ut_gt = ((dt + 2) / (2 - dt)) * u0
    ut_my = MidPointLinearEuler().step(0, u0, dt)
    assert ut_my.device.type == 'cuda'
    assert ut_my.dtype == torch.float64
    assert torch.allclose(ut_gt, ut_my), f"expected {ut_gt}, got {ut_my}"
