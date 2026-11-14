import torch
from typing import Optional, List, Union

class OCOptimizer:
    """Optimality Criteria (OC) optimizer for topology optimization.
    
    Similar interface to :obj:`torch.optim.Optimizer`, but specifically designed
    for density-based topology optimization with volume constraints.
    
    The OC update rule is:
    
    .. math::
        \\rho_{\\text{new}} = \\rho \\cdot B_e^{\\eta}
        
    where:
    
    .. math::
        B_e = \\sqrt{\\frac{-\\frac{\\partial C}{\\partial \\rho}}{\\lambda \\cdot \\frac{\\partial V}{\\partial \\rho}}}
    
    - :math:`\\lambda`: Lagrange multiplier (found by bisection to satisfy volume constraint)
    - :math:`\\eta = 0.5`: damping exponent
    
    Parameters
    ----------
    params : torch.Tensor or List[torch.Tensor]
        Tensor or list of tensors (design variables)
    vf : float
        Target volume fraction
    move_limit : float, optional
        Maximum density change per iteration
        default: ``0.2``
    rho_min : float, optional
        Minimum density
        default: :obj:`1e-3`
    rho_max : float, optional
        Maximum density
        default: ``1.0``
    eta : float, optional
        Damping exponent
        default: ``0.5``
    bisection_tol : float, optional
        Tolerance for bisection
        default: :obj:`1e-4`
    bisection_max_iter : int, optional
        Maximum bisection iterations
        default: ``50``
    
    Examples
    --------
    
    .. code-block:: python
    
        optimizer = OCOptimizer(rho, vf=0.5, move_limit=0.2)
        
        for epoch in range(max_iter):
            # Forward pass and compute compliance
            compliance = compute_compliance(rho)
            
            # Backward pass
            compliance.backward()
            
            # OC update
            optimizer.step(rho.grad)
            optimizer.zero_grad()
    """
    
    def __init__(
        self,
        params: Union[torch.Tensor, List[torch.Tensor]],
        vf: float,
        move_limit: float = 0.2,
        rho_min: float = 1e-3,
        rho_max: float = 1.0,
        eta: float = 0.5,
        bisection_tol: float = 1e-4,
        bisection_max_iter: int = 50,
    ):
        if isinstance(params, torch.Tensor):
            self.params = [params]
        else:
            self.params = list(params)
        
        self.vf = vf
        self.move_limit = move_limit
        self.rho_min = rho_min
        self.rho_max = rho_max
        self.eta = eta
        self.bisection_tol = bisection_tol
        self.bisection_max_iter = bisection_max_iter
        
        # State for tracking
        self.state = {
            'step': 0,
            'lambda': 1.0,  # Last Lagrange multiplier
        }
    
    def zero_grad(self):
        """Clear gradients of all parameters."""
        for p in self.params:
            if p.grad is not None:
                p.grad.zero_()
    
    @torch.no_grad()
    def step(self, dc: Optional[torch.Tensor] = None, dv: Optional[torch.Tensor] = None):
        """Perform one OC update step.

        If ``dc`` is omitted, uses each parameter's gradient (negative for
        compliance minimization). If ``dv`` is omitted, uses a uniform
        volume sensitivity. Returns a dict with keys ``lambda`` and
        ``volume``.
        """
        self.state['step'] += 1
        
        for rho in self.params:
            # Get compliance sensitivity
            if dc is None:
                if rho.grad is None:
                    raise RuntimeError("No gradient found. Call backward() first.")
                dc_local = rho.grad.clone()
            else:
                dc_local = dc
            
            # Get volume sensitivity (uniform by default)
            if dv is None:
                dv_local = torch.ones_like(rho) / rho.numel()
            else:
                dv_local = dv
            
            # Bisection for Lagrange multiplier
            lam_min, lam_max = 1e-10, 1e10
            lam_mid = lam_min  # Initialize to avoid UnboundLocalError
            
            for _ in range(self.bisection_max_iter):
                lam_mid = 0.5 * (lam_min + lam_max)
                
                # OC update: Be = (-dc / (lam * dv))^eta
                # Note: dc < 0 for compliance, so -dc > 0
                dc_positive = (-dc_local).clamp(min=1e-10)
                Be = (dc_positive / (lam_mid * dv_local)).clamp(min=1e-10) ** self.eta
                
                # New density
                rho_new = rho * Be
                
                # Apply move limits
                rho_new = torch.maximum(rho_new, rho - self.move_limit)
                rho_new = torch.minimum(rho_new, rho + self.move_limit)
                rho_new = rho_new.clamp(self.rho_min, self.rho_max)
                
                # Check volume constraint
                if rho_new.mean() > self.vf:
                    lam_min = lam_mid
                else:
                    lam_max = lam_mid
                
                # Check convergence
                if (lam_max - lam_min) / (lam_min + lam_max) < self.bisection_tol:
                    break
            
            # Update parameter in-place
            rho.copy_(rho_new)
            self.state['lambda'] = lam_mid
        
        return {
            'lambda': self.state['lambda'],
            'volume': self.params[0].mean().item(),
        }
    
    def get_volume(self):
        """Get current volume fraction."""
        return self.params[0].mean().item()
    
    def get_stats(self):
        """Get optimizer statistics."""
        rho = self.params[0]
        return {
            'step': self.state['step'],
            'lambda': self.state['lambda'],
            'volume': rho.mean().item(),
            'n_void': (rho < 0.1).sum().item(),
            'n_solid': (rho > 0.9).sum().item(),
            'rho_min': rho.min().item(),
            'rho_max': rho.max().item(),
        }

