"""Pure-PyTorch sparse-solve backends.

Provides:

- :func:`coo_diagonal`, :func:`jacobi_precond` — small utility primitives;
- :func:`cg_py` — CG for SPD matrices;
- :func:`bicgstab_py` — Jacobi-preconditioned BiCGSTAB for general
  square systems;
- :class:`SparseSolveTorch` — :class:`torch.autograd.Function` wrapping
  :func:`bicgstab_py` with an adjoint backward.

This module is part of the legacy fallback path used only when
``torch-sla`` is not installed; with ``torch-sla`` (the default
dependency) the dispatcher in :func:`tensormesh.sparse.spsolve` does
not reach here.
"""

import math
import torch
from torch.autograd import Function
import warnings
from ..utils import shapeT

def coo_diagonal(A, at_least=1):
    """Extract the diagonal of a sparse COO tensor.

    Missing diagonal entries are filled with ``at_least`` (default 1).

    Parameters
    ----------
    A : torch.sparse_coo_tensor
        Square sparse tensor.
    at_least : float, default 1
        Fill value for diagonal positions absent from the sparsity
        pattern (so Jacobi preconditioning does not divide by zero).

    Returns
    -------
    torch.Tensor
        1D tensor of length ``A.shape[0]``.
    """
    assert A.shape[0] == A.shape[1], f"Matrix is not square. Shape is {A.shape}"
    N = A.shape[0]
    edges = A.indices()
    value = A.values()
    mask  = edges[0] == edges[1]
    cand_value = value[mask]
    cand_index = edges[0][mask]
    diag_value = torch.full(size=(N,), fill_value=at_least, dtype=cand_value.dtype, device=cand_value.device)
    diag_value[cand_index] = cand_value
    return diag_value


def jacobi_precond(A, x=None):
    """Jacobi (inverse-diagonal) preconditioner; returns ``M^{-1}`` or ``M^{-1} x``."""
    if x is None:
        return 1.0 / coo_diagonal(A, at_least=1.0)
    else:
        return x * (1.0 / coo_diagonal(A, at_least=1.0))


def identity_precond(A, x=None):
    """Identity preconditioner; returns ``1`` or ``x`` unchanged."""
    if x is None:
        return torch.ones(A.shape[0], dtype=A.dtype, device=A.device)
    else:
        return x


def cg_py(indices, values, m, n, b, x0=None, atol=1e-5, max_iter=10000):
    """Conjugate-gradient solve of ``A x = b`` for symmetric positive-definite ``A``.

    See https://en.wikipedia.org/wiki/Conjugate_gradient_method.

    Parameters
    ----------
    indices : torch.Tensor
        2D int tensor of shape ``[2, nnz]`` stacking ``(row, col)``.
    values : torch.Tensor
        1D tensor of shape ``[nnz]``: non-zero values of ``A``.
    m, n : int
        Shape of ``A``; must satisfy ``m == n``.
    b : torch.Tensor
        1D tensor of shape ``[n]``: right-hand side.
    x0 : torch.Tensor, optional
        1D tensor of shape ``[n]``: initial guess. Defaults to zeros.
    atol : float, default 1e-5
        Convergence tolerance on ``||r||``.
    max_iter : int, default 10000
        Iteration budget; emits a warning if exhausted.

    Returns
    -------
    torch.Tensor
        Solution ``x`` of shape ``[n]``.
    """
    A = torch.sparse_coo_tensor(indices, values, (m, n), is_coalesced =True)

    if x0 is None:
        x0 = torch.zeros_like(b)
    
    A = A.to_sparse_csr()

    x0 = x0.view(-1)
    b  = b.view(-1)

    r = b - A @ x0
    p = r.clone()
    x = x0
    rs_old = torch.dot(r, r)

    for i in range(max_iter):
        Ap = A @ p
        alpha = rs_old / torch.dot(p,Ap)
        x = x + alpha * p
        r = r - alpha * Ap
        rs_new = torch.dot(r,r)

        if torch.sqrt(rs_new) < atol:
            break

        p = r + (rs_new / rs_old) * p
        rs_old = rs_new
       
    if torch.norm(A @ x - b) > atol:
        warnings.warn(f"cg did not converge after {i} iterations. with residual {torch.norm(A @ x - b)}")

    return x.view(-1)

def bicgstab_py(indices, values, m, n, b, x0=None, atol=1e-5, max_iter=10000):
    """Jacobi-preconditioned BiCGSTAB solve of ``A x = b``.

    Suited for non-SPD square systems where CG cannot be used.

    Parameters
    ----------
    indices : torch.Tensor
        2D int tensor of shape ``[2, nnz]`` stacking ``(row, col)``.
    values : torch.Tensor
        1D tensor of shape ``[nnz]``: non-zero values of ``A``.
    m, n : int
        Shape of ``A``; must satisfy ``m == n``.
    b : torch.Tensor
        1D tensor of shape ``[n]``: right-hand side. Same dtype as
        ``values``.
    x0 : torch.Tensor, optional
        1D tensor of shape ``[n]``: initial guess. Defaults to zeros.
    atol : float, default 1e-5
        Convergence tolerance on ``||r||``.
    max_iter : int, default 10000
        Iteration budget; emits a warning if final residual exceeds
        ``sqrt(atol)``.

    Returns
    -------
    torch.Tensor
        Solution ``x`` of shape ``[n]``.
    """
    assert m == n, f"Matrix is not square. Shape is {m}x{n}"
    assert b.shape[0] == m, f"Shape mismatch. A is {m}x{n}, b is {b.shape}"
    assert b.dim() == 1, f"b should be a 1D tensor. b is {b.dim()}D"
    assert b.dtype == values.dtype, f"b.dtype {b.dtype} does not match values.dtype {values.dtype}"
    
    # Construct A for matrix multiplication
    A_coo = torch.sparse_coo_tensor(indices, values, (m, n), is_coalesced=True)
    A = A_coo.to_sparse_csr()

    # Construct Jacobi Preconditioner (Inverse Diagonal)
    # Extract diagonal from indices/values
    # Assuming indices are [2, NNZ]
    row_idx, col_idx = indices
    diag_mask = (row_idx == col_idx)
    diag_indices = row_idx[diag_mask]
    diag_values = values[diag_mask]
    
    # Initialize diagonal with ones
    M_diag = torch.ones(m, device=values.device, dtype=values.dtype)
    M_diag.index_put_((diag_indices,), diag_values)
    
    # Avoid division by zero
    M_diag = torch.where(M_diag.abs() < 1e-12, torch.tensor(1.0, device=values.device, dtype=values.dtype), M_diag)
    M_inv = 1.0 / M_diag

    def apply_precond(v):
        return v * M_inv



    if x0 is None:
        x0 = torch.zeros_like(b)
    
    # Initial residual
    r = b - A @ x0
    r0_hat = r.clone()
    
    rho = alpha = omega = 1.0
    v = p = torch.zeros_like(b)
    
    rho = torch.dot(r0_hat, r)
    
    # Reuse p for the first iteration logic to match standard algo structure
    p = r.clone()

    for i in range(max_iter):
        if torch.norm(r) < atol:
            break
            
        p_hat = apply_precond(p)
        v = A @ p_hat
        
        denom = torch.dot(r0_hat, v)
        if denom.abs() < 1e-12:
            break # Breakdown
            
        alpha = rho / denom
        s = r - alpha * v
        
        if torch.norm(s) < atol:
            x0 = x0 + alpha * p_hat
            break
            
        s_hat = apply_precond(s)
        t = A @ s_hat
        
        t_norm2 = torch.dot(t, t)
        if t_norm2.abs() < 1e-12:
            omega = 0.0
        else:
            omega = torch.dot(t, s) / t_norm2
            
        x0 = x0 + alpha * p_hat + omega * s_hat
        r = s - omega * t
        
        if torch.norm(r) < atol:
            break
            
        rho_new = torch.dot(r0_hat, r)
        if omega == 0:
            break
            
        beta = (rho_new / rho) * (alpha / omega)
        rho = rho_new
        p = r + beta * (p - omega * v)

    if torch.norm(A @ x0 - b) > math.sqrt(atol):
        warnings.warn(f"bicgstab did not converge after {max_iter} iterations. with residual {torch.norm(A @ x0 - b)}")

    return x0.view(-1)

lse_solver = bicgstab_py

class SparseSolveTorch(Function):
    @staticmethod
    def forward(ctx, edata, row, col, shape, b, x0=None, tol=1e-5, max_iter=10000):
        u = lse_solver(torch.stack([row, col],0), edata, shape[0], shape[1], b, x0=x0, atol=tol, max_iter=max_iter)
        ctx.save_for_backward(edata, row, col, u)
        ctx.A_shape = shape
        ctx.tol = tol
        ctx.max_iter = max_iter
        return u
    
    @staticmethod
    def backward(ctx, grad_output):
        edata, row, col, u = ctx.saved_tensors
        shape_T = shapeT(ctx.A_shape)
        # Gradient for b: solve A^T * grad_b = grad_output
        # We can also use 'u' (if symmetric) or previous solution as guess? 
        # But backward solve is a new system. x0=None is safe.
        b_grad = lse_solver(torch.stack([col, row],0), edata, shape_T[0], shape_T[1], grad_output, atol=ctx.tol, max_iter=ctx.max_iter)
        edata_grad      = - b_grad[row] * u[col]

        return edata_grad, None, None, None, b_grad, None, None, None
    

