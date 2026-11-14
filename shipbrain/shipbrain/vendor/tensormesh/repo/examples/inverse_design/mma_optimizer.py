"""
MMA (Method of Moving Asymptotes) Optimizer for Topology Optimization

Ported from JAX-FEM implementation:
- Original: https://github.com/arjendeetman/GCMMA-MMA-Python
- Modified by JAX-FEM: https://github.com/UW-ERSL/AuTO

This version is adapted for use with TensorMesh topology optimization,
providing a similar interface to OCOptimizer.
"""

import numpy as np
from numpy import diag as diags
from numpy.linalg import solve
import torch
from typing import Optional, Union, List
import scipy.spatial


def build_sensitivity_filter(mesh, rmin: float):
    """
    Build sensitivity filter using k-d tree for efficient neighbor search.
    
    Args:
        mesh: TensorMesh mesh object
        rmin: Filter radius
    
    Returns:
        H: Sparse filter matrix
        Hs: Row sums of H
    """
    elements = mesh.elements().cpu().numpy()
    points = mesh.points.detach().cpu().numpy()
    centroids = points[elements].mean(axis=1)
    n_elements = len(elements)
    
    kd_tree = scipy.spatial.KDTree(centroids)
    
    I, J, V = [], [], []
    num_nbs = min(20, n_elements)
    
    for i in range(n_elements):
        dd, ii = kd_tree.query(centroids[i], num_nbs)
        vals = np.maximum(rmin - dd, 0.0)
        I.extend([i] * num_nbs)
        J.extend(ii.tolist())
        V.extend(vals.tolist())
    
    H = scipy.sparse.csc_matrix((V, (I, J)), shape=(n_elements, n_elements))
    Hs = np.array(H.sum(axis=1)).flatten()
    
    return H, Hs


def apply_sensitivity_filter(H, Hs, rho, dJ):
    """
    Apply sensitivity filter to gradient.
    
    Args:
        H: Filter matrix
        Hs: Row sums of H
        rho: Current density field
        dJ: Objective gradient
    
    Returns:
        Filtered gradient
    """
    rho_np = rho if isinstance(rho, np.ndarray) else rho.detach().cpu().numpy()
    dJ_np = dJ if isinstance(dJ, np.ndarray) else dJ.detach().cpu().numpy()
    
    # Sensitivity filter: dJ_filtered = H @ (rho * dJ / max(rho, eps)) / Hs
    rho_safe = np.maximum(rho_np, 1e-3)
    dJ_filtered = H @ (rho_np * dJ_np / rho_safe) / Hs[:, None]
    
    return dJ_filtered


class MMA:
    """
    Core MMA solver class.
    
    Based on Svanberg 1987: "The method of moving asymptotes - a new method
    for structural optimization"
    """
    
    def __init__(self):
        self.epoch = 0
        
    def reset(self):
        self.epoch = 0
        
    def register_iter(self, xval, xold1, xold2):
        self.epoch += 1
        self.xval = xval
        self.xold1 = xold1
        self.xold2 = xold2
        
    def set_num_constraints(self, m):
        self.m = m
        
    def set_num_design_vars(self, n):
        self.n = n
        
    def set_bounds(self, xmin, xmax):
        self.xmin = xmin
        self.xmax = xmax
        
    def set_objective(self, obj, grad):
        self.f0val = obj
        self.df0dx = grad
        
    def set_constraints(self, fval, dfdx):
        self.fval = fval
        self.dfdx = dfdx
        
    def set_scaling(self, a0, a, c, d):
        self.a0 = a0
        self.a = a
        self.c = c
        self.d = d
        
    def set_move_limit(self, move):
        self.move = move
        
    def set_asymptotes(self, low, upp):
        self.low = low
        self.upp = upp
        
    def solve(self, xval):
        """Solve MMA subproblem."""
        m = self.m
        n = self.n
        iter_num = self.epoch
        xmin, xmax = self.xmin, self.xmax
        xold1, xold2 = self.xold1, self.xold2
        f0val, df0dx = self.f0val, self.df0dx
        fval, dfdx = self.fval, self.dfdx
        low, upp = self.low, self.upp
        a0, a, c, d = self.a0, self.a, self.c, self.d
        move = self.move
        
        epsimin = 1e-7
        raa0 = 1e-5
        albefa = 0.1
        asyinit = 0.5
        asyincr = 1.2
        asydecr = 0.7
        
        eeen = np.ones((n, 1))
        eeem = np.ones((m, 1))
        zeron = np.zeros((n, 1))
        
        # Calculation of asymptotes
        if iter_num <= 2:
            low = xval - asyinit * (xmax - xmin)
            upp = xval + asyinit * (xmax - xmin)
        else:
            zzz = (xval - xold1) * (xold1 - xold2)
            factor = eeen.copy()
            factor[zzz > 0] = asyincr
            factor[zzz < 0] = asydecr
            low = xval - factor * (xold1 - low)
            upp = xval + factor * (upp - xold1)
            lowmin = xval - 10 * (xmax - xmin)
            lowmax = xval - 0.01 * (xmax - xmin)
            uppmin = xval + 0.01 * (xmax - xmin)
            uppmax = xval + 10 * (xmax - xmin)
            low = np.maximum(low, lowmin)
            low = np.minimum(low, lowmax)
            upp = np.minimum(upp, uppmax)
            upp = np.maximum(upp, uppmin)
            
        # Bounds alfa and beta
        zzz1 = low + albefa * (xval - low)
        zzz2 = xval - move * (xmax - xmin)
        alfa = np.maximum(np.maximum(zzz1, zzz2), xmin)
        
        zzz1 = upp - albefa * (upp - xval)
        zzz2 = xval + move * (xmax - xmin)
        beta = np.minimum(np.minimum(zzz1, zzz2), xmax)
        
        # Calculations of p0, q0, P, Q, b
        xmami = np.maximum(xmax - xmin, 1e-5 * eeen)
        xmamiinv = eeen / xmami
        ux1 = upp - xval
        ux2 = ux1 * ux1
        xl1 = xval - low
        xl2 = xl1 * xl1
        uxinv = eeen / ux1
        xlinv = eeen / xl1
        
        p0 = np.maximum(df0dx, 0)
        q0 = np.maximum(-df0dx, 0)
        pq0 = 0.001 * (p0 + q0) + raa0 * xmamiinv
        p0 = (p0 + pq0) * ux2
        q0 = (q0 + pq0) * xl2
        
        P = np.maximum(dfdx, 0)
        Q = np.maximum(-dfdx, 0)
        PQ = 0.001 * (P + Q) + raa0 * np.dot(eeem, xmamiinv.T)
        P = (P + PQ) * ux2.T
        Q = (Q + PQ) * xl2.T
        
        b = np.dot(P, uxinv) + np.dot(Q, xlinv) - fval
        
        # Solve subproblem
        xmma, ymma, zmma, lam, xsi, eta, mu, zet, s = self._subsolv(
            m, n, epsimin, low, upp, alfa, beta, p0, q0, P, Q, a0, a, b, c, d
        )
        
        self.xmma = xmma
        self.ymma = ymma
        self.zmma = zmma
        self.low = low
        self.upp = upp
        
        return xmma
    
    def _subsolv(self, m, n, epsimin, low, upp, alfa, beta, p0, q0, P, Q, a0, a, b, c, d):
        """Solve the MMA subproblem using primal-dual Newton method."""
        een = np.ones((n, 1))
        eem = np.ones((m, 1))
        epsi = 1.0
        
        x = 0.5 * (alfa + beta)
        y = eem.copy()
        z = np.array([[1.0]])
        lam = eem.copy()
        xsi = np.maximum(een / (x - alfa), een)
        eta = np.maximum(een / (beta - x), een)
        mu = np.maximum(eem, 0.5 * c)
        zet = np.array([[1.0]])
        s = eem.copy()
        
        while epsi > epsimin:
            epsvecn = epsi * een
            epsvecm = epsi * eem
            
            ux1 = upp - x
            xl1 = x - low
            ux2 = ux1 * ux1
            xl2 = xl1 * xl1
            uxinv1 = een / ux1
            xlinv1 = een / xl1
            
            plam = p0 + np.dot(P.T, lam)
            qlam = q0 + np.dot(Q.T, lam)
            gvec = np.dot(P, uxinv1) + np.dot(Q, xlinv1)
            dpsidx = plam / ux2 - qlam / xl2
            
            rex = dpsidx - xsi + eta
            rey = c + d * y - mu - lam
            rez = a0 - zet - np.dot(a.T, lam)
            relam = gvec - a * z - y + s - b
            rexsi = xsi * (x - alfa) - epsvecn
            reeta = eta * (beta - x) - epsvecn
            remu = mu * y - epsvecm
            rezet = zet * z - epsi
            res = lam * s - epsvecm
            
            residu = np.concatenate([rex, rey, rez, relam, rexsi, reeta, remu, rezet, res])
            residunorm = np.linalg.norm(residu)
            residumax = np.max(np.abs(residu))
            
            ittt = 0
            while residumax > 0.9 * epsi and ittt < 200:
                ittt += 1
                
                ux1 = upp - x
                xl1 = x - low
                ux2 = ux1 * ux1
                xl2 = xl1 * xl1
                ux3 = ux1 * ux2
                xl3 = xl1 * xl2
                uxinv1 = een / ux1
                xlinv1 = een / xl1
                uxinv2 = een / ux2
                xlinv2 = een / xl2
                
                plam = p0 + np.dot(P.T, lam)
                qlam = q0 + np.dot(Q.T, lam)
                gvec = np.dot(P, uxinv1) + np.dot(Q, xlinv1)
                GG = uxinv2.T * P - xlinv2.T * Q
                
                dpsidx = plam / ux2 - qlam / xl2
                delx = dpsidx - epsvecn / (x - alfa) + epsvecn / (beta - x)
                dely = c + d * y - lam - epsvecm / y
                delz = a0 - np.dot(a.T, lam) - epsi / z
                dellam = gvec - a * z - y - b + epsvecm / lam
                
                diagx = 2 * (plam / ux3 + qlam / xl3) + xsi / (x - alfa) + eta / (beta - x)
                diagxinv = een / diagx
                diagy = d + mu / y
                diagyinv = eem / diagy
                diaglam = s / lam
                diaglamyi = diaglam + diagyinv
                
                if m < n:
                    blam = dellam + dely / diagy - np.dot(GG, delx / diagx)
                    bb = np.concatenate([blam, delz])
                    Alam = diags(diaglamyi.flatten()) + (diagxinv.T * GG).dot(GG.T)
                    AAr1 = np.concatenate([Alam, a], axis=1)
                    AAr2 = np.concatenate([a, -zet / z], axis=0).T
                    AA = np.concatenate([AAr1, AAr2], axis=0)
                    solut = solve(AA, bb)
                    dlam = solut[:m]
                    dz = solut[m:m+1]
                    dx = -delx / diagx - np.dot(GG.T, dlam) / diagx
                else:
                    diaglamyiinv = eem / diaglamyi
                    dellamyi = dellam + dely / diagy
                    Axx = diags(diagx.flatten()) + (diaglamyiinv.T * GG.T).dot(GG.T).T
                    azz = zet / z + np.dot(a.T, a / diaglamyi)
                    axz = np.dot(-GG.T, a / diaglamyi)
                    bx = delx + np.dot(GG.T, dellamyi / diaglamyi)
                    bz = delz - np.dot(a.T, dellamyi / diaglamyi)
                    AAr1 = np.concatenate([Axx, axz], axis=1)
                    AAr2 = np.concatenate([axz.T, azz], axis=1)
                    AA = np.concatenate([AAr1, AAr2], axis=0)
                    bb = np.concatenate([-bx, -bz])
                    solut = solve(AA, bb)
                    dx = solut[:n]
                    dz = solut[n:n+1]
                    dlam = np.dot(GG, dx) / diaglamyi - dz * (a / diaglamyi) + dellamyi / diaglamyi
                
                dy = -dely / diagy + dlam / diagy
                dxsi = -xsi + epsvecn / (x - alfa) - xsi * dx / (x - alfa)
                deta = -eta + epsvecn / (beta - x) + eta * dx / (beta - x)
                dmu = -mu + epsvecm / y - mu * dy / y
                dzet = -zet + epsi / z - zet * dz / z
                ds = -s + epsvecm / lam - s * dlam / lam
                
                xx = np.concatenate([y, z, lam, xsi, eta, mu, zet, s])
                dxx = np.concatenate([dy, dz, dlam, dxsi, deta, dmu, dzet, ds])
                
                stepxx = np.max(-1.01 * dxx / xx)
                stepalfa = np.max(-1.01 * dx / (x - alfa))
                stepbeta = np.max(1.01 * dx / (beta - x))
                steg = 1.0 / max(stepxx, stepalfa, stepbeta, 1.0)
                
                xold, yold, zold = x.copy(), y.copy(), z.copy()
                lamold, xsiold, etaold = lam.copy(), xsi.copy(), eta.copy()
                muold, zetold, sold = mu.copy(), zet.copy(), s.copy()
                
                itto = 0
                resinew = 2 * residunorm
                
                while resinew > residunorm and itto < 50:
                    itto += 1
                    x = xold + steg * dx
                    y = yold + steg * dy
                    z = zold + steg * dz
                    lam = lamold + steg * dlam
                    xsi = xsiold + steg * dxsi
                    eta = etaold + steg * deta
                    mu = muold + steg * dmu
                    zet = zetold + steg * dzet
                    s = sold + steg * ds
                    
                    ux1 = upp - x
                    xl1 = x - low
                    ux2 = ux1 * ux1
                    xl2 = xl1 * xl1
                    uxinv1 = een / ux1
                    xlinv1 = een / xl1
                    
                    plam = p0 + np.dot(P.T, lam)
                    qlam = q0 + np.dot(Q.T, lam)
                    gvec = np.dot(P, uxinv1) + np.dot(Q, xlinv1)
                    dpsidx = plam / ux2 - qlam / xl2
                    
                    rex = dpsidx - xsi + eta
                    rey = c + d * y - mu - lam
                    rez = a0 - zet - np.dot(a.T, lam)
                    relam = gvec - np.dot(a, z) - y + s - b
                    rexsi = xsi * (x - alfa) - epsvecn
                    reeta = eta * (beta - x) - epsvecn
                    remu = mu * y - epsvecm
                    rezet = np.dot(zet, z) - epsi
                    res = lam * s - epsvecm
                    
                    residu = np.concatenate([rex, rey, rez, relam, rexsi, reeta, remu, rezet, res])
                    resinew = np.linalg.norm(residu)
                    steg = steg / 2
                
                residunorm = resinew
                residumax = np.max(np.abs(residu))
                steg = 2 * steg
            
            epsi = 0.1 * epsi
        
        return x, y, z, lam, xsi, eta, mu, zet, s


class MMAOptimizer:
    """
    MMA Optimizer with interface similar to TensorMesh's OCOptimizer.
    
    Parameters
    ----------
    params : torch.Tensor
        Initial design variables (density field)
    vf : float
        Target volume fraction
    move_limit : float
        Maximum density change per iteration (default: 0.1)
    rho_min : float
        Minimum density (default: 1e-3)
    rho_max : float
        Maximum density (default: 1.0)
    use_filter : bool
        Whether to use sensitivity filtering (default: True)
    filter_radius : float, optional
        Filter radius (default: auto-computed from mesh)
    mesh : Mesh, optional
        Mesh object for filter construction
    """
    
    def __init__(
        self,
        params: torch.Tensor,
        vf: float,
        move_limit: float = 0.1,
        rho_min: float = 1e-3,
        rho_max: float = 1.0,
        use_filter: bool = True,
        filter_radius: Optional[float] = None,
        mesh = None,
    ):
        self.params = params
        self.vf = vf
        self.move_limit = move_limit
        self.rho_min = rho_min
        self.rho_max = rho_max
        self.use_filter = use_filter
        
        self.n = params.numel()
        self.m = 1  # One volume constraint
        
        # Initialize MMA solver
        self.mma = MMA()
        self.mma.set_num_constraints(self.m)
        self.mma.set_num_design_vars(self.n)
        self.mma.set_bounds(
            np.full((self.n, 1), rho_min),
            np.full((self.n, 1), rho_max)
        )
        self.mma.set_move_limit(move_limit)
        self.mma.set_scaling(
            1.0,  # a0
            np.zeros((self.m, 1)),  # a
            10000 * np.ones((self.m, 1)),  # c
            np.zeros((self.m, 1)),  # d
        )
        self.mma.set_asymptotes(
            np.ones((self.n, 1)),
            np.ones((self.n, 1))
        )
        
        # Initialize state
        xval = params.detach().cpu().numpy().reshape(-1, 1)
        self.xval = xval
        self.xold1 = xval.copy()
        self.xold2 = xval.copy()
        
        # Build filter if mesh is provided
        self.H = None
        self.Hs = None
        if use_filter and mesh is not None:
            if filter_radius is None:
                # Auto-compute filter radius
                elements = mesh.elements().cpu().numpy()
                points = mesh.points.detach().cpu().numpy()
                centroids = points[elements].mean(axis=1)
                avg_elem_size = np.sqrt(np.mean(np.sum((points[elements[:, 1]] - points[elements[:, 0]])**2, axis=1)))
                filter_radius = 1.5 * avg_elem_size
            self.H, self.Hs = build_sensitivity_filter(mesh, filter_radius)
        
        self.state = {'step': 0}
    
    def zero_grad(self):
        """Clear gradients."""
        if self.params.grad is not None:
            self.params.grad.zero_()
    
    @torch.no_grad()
    def step(self, dc: Optional[torch.Tensor] = None, dv: Optional[torch.Tensor] = None):
        """
        Perform MMA update step.
        
        Args:
            dc: Compliance sensitivity (dC/drho)
            dv: Volume sensitivity (dV/drho)
        
        Returns:
            dict with 'volume' key
        """
        self.state['step'] += 1
        
        # Get gradients as numpy
        if dc is None:
            if self.params.grad is None:
                raise RuntimeError("No gradient found. Call backward() first.")
            dc_np = self.params.grad.detach().cpu().numpy().reshape(-1, 1)
        else:
            dc_np = dc.detach().cpu().numpy().reshape(-1, 1) if isinstance(dc, torch.Tensor) else dc.reshape(-1, 1)
        
        # Volume gradient (uniform)
        if dv is None:
            dv_np = np.ones((self.n, 1)) / self.n
        else:
            dv_np = dv.detach().cpu().numpy().reshape(-1, 1) if isinstance(dv, torch.Tensor) else dv.reshape(-1, 1)
        
        # Apply sensitivity filter
        if self.use_filter and self.H is not None:
            rho_np = self.params.detach().cpu().numpy().flatten()
            dc_np = apply_sensitivity_filter(self.H, self.Hs, rho_np.reshape(-1, 1), dc_np)
        
        # Current density
        rho_np = self.params.detach().cpu().numpy().reshape(-1, 1)
        
        # Volume constraint: mean(rho)/vf - 1 <= 0
        g = np.mean(rho_np) / self.vf - 1.0
        dg = dv_np.T / self.vf  # Shape: (1, n)
        
        # Register iteration
        self.mma.register_iter(self.xval, self.xold1, self.xold2)
        
        # Set objective and constraints
        # Note: MMA minimizes, so we use dc directly (compliance should decrease)
        self.mma.set_objective(0.0, dc_np)  # f0val doesn't matter for update
        self.mma.set_constraints(np.array([[g]]), dg)
        
        # Solve MMA subproblem
        xmma = self.mma.solve(self.xval)
        
        # Update history
        self.xold2 = self.xold1.copy()
        self.xold1 = self.xval.copy()
        self.xval = xmma.copy()
        
        # Update params in-place
        new_rho = torch.from_numpy(xmma.flatten()).to(
            dtype=self.params.dtype, device=self.params.device
        )
        self.params.copy_(new_rho)
        
        return {
            'volume': self.params.mean().item(),
        }
    
    def get_volume(self):
        """Get current volume fraction."""
        return self.params.mean().item()
    
    def get_stats(self):
        """Get optimizer statistics."""
        rho = self.params
        return {
            'step': self.state['step'],
            'volume': rho.mean().item(),
            'n_void': (rho < 0.1).sum().item(),
            'n_solid': (rho > 0.9).sum().item(),
            'rho_min': rho.min().item(),
            'rho_max': rho.max().item(),
        }