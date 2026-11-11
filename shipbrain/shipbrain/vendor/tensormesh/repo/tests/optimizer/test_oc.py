import torch
import sys
import os

# Add project root to path so we can import tensormesh
sys.path.append(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tensormesh.optimizer import OCOptimizer

def test_oc_optimizer_initialization():
    """Test OCOptimizer initialization."""
    print("Testing initialization...")
    params = torch.rand(10, 10, requires_grad=True)
    vf = 0.5
    optimizer = OCOptimizer(params, vf=vf)
    
    assert optimizer.vf == vf
    assert len(optimizer.params) == 1
    assert optimizer.params[0].shape == (10, 10)
    print("Initialization passed.")

def test_oc_optimizer_step_basic():
    """Test basic update step."""
    print("Testing basic step...")
    # Create dummy design variables (density)
    n_elem = 100
    rho = torch.ones(n_elem, requires_grad=True) * 0.5
    
    # Target volume fraction
    vf = 0.4 
    
    optimizer = OCOptimizer(rho, vf=vf, move_limit=0.2)
    
    # Fake sensitivity (compliance gradient)
    # Negative gradient implies we want to increase density in these areas to minimize compliance
    # Let's say elements 0-50 are important (high sensitivity)
    dc = torch.zeros(n_elem)
    dc[:50] = -2.0  # High sensitivity
    dc[50:] = -0.1  # Low sensitivity
    
    # Uniform volume sensitivity
    dv = torch.ones(n_elem) / n_elem
    
    # Perform step
    info = optimizer.step(dc=dc, dv=dv)
    
    # Check if lambda was found
    assert 'lambda' in info
    assert info['lambda'] > 0
    
    # Check volume constraint satisfaction
    # The optimized volume should be close to target vf
    current_vol = rho.mean().item()
    # Note: OC with bisection should satisfy volume constraint very strictly
    assert abs(current_vol - vf) < 1e-3
    
    # Check if densities moved in correct direction
    # First half should increase (high sensitivity), second half decrease (to meet volume constraint)
    assert rho[:50].mean() > 0.5
    assert rho[50:].mean() < 0.5
    print("Basic step passed.")

def test_oc_optimizer_move_limit():
    """Test move limit constraint."""
    print("Testing move limit...")
    n_elem = 100
    rho_init = 0.5
    rho = torch.ones(n_elem, requires_grad=True) * rho_init
    move_limit = 0.1
    vf = 0.5 # Same volume, but gradient will push values around
    
    optimizer = OCOptimizer(rho, vf=vf, move_limit=move_limit)
    
    # Extremely high sensitivity to force large changes
    dc = torch.zeros(n_elem)
    dc[:50] = -1000.0
    dc[50:] = 0.0 # Or positive effectively
    
    optimizer.step(dc=dc)
    
    # Check that no element changed more than move_limit
    change = (rho - rho_init).abs()
    assert change.max() <= move_limit + 1e-6
    print("Move limit passed.")

def test_oc_optimizer_integration_with_autograd():
    """Test using .grad attribute instead of passing dc explicitly."""
    print("Testing autograd integration...")
    # Properly create leaf tensor
    rho = torch.full((10,), 0.5, requires_grad=True)
    # Target volume fraction smaller than current, forcing reduction
    vf = 0.4
    optimizer = OCOptimizer(rho, vf=vf)
    
    # Dummy objective function: minimize Compliance = sum(1/rho)
    # This prefers higher rho (gradient is negative)
    # BUT constraint vf=0.4 forces it to go down.
    # Wait, if objective wants high rho but constraint wants low rho,
    # it will reduce rho to meet constraint.
    compliance = (1.0 / (rho + 1e-3)).sum()
    compliance.backward()
    
    assert rho.grad is not None
    
    # Step using internal gradients
    optimizer.step()
    
    # Should have updated (decreased)
    assert not torch.allclose(rho, torch.full((10,), 0.5))
    assert rho.mean() < 0.5
    
    # Zero grad check
    optimizer.zero_grad()
    assert rho.grad.abs().sum() == 0.0
    print("Autograd integration passed.")

if __name__ == "__main__":
    test_oc_optimizer_initialization()
    test_oc_optimizer_step_basic()
    test_oc_optimizer_move_limit()
    test_oc_optimizer_integration_with_autograd()
    print("\nAll tests passed successfully!")
