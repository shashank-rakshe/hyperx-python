"""Newton-Raphson solver for ``F(u, params) = 0`` with implicit-diff support.

.. deprecated:: 0.x

   This module is a **TensorMesh-internal driver scheduled for removal**.
   The canonical nonlinear-solve path has migrated to
   :meth:`torch_sla.SparseTensor.nonlinear_solve` (available on every
   :class:`~tensormesh.sparse.SparseMatrix` since it subclasses
   ``SparseTensor``), which supports Newton / Picard / Anderson, Armijo
   line search, and an autograd-derived Jacobian — so callers no longer
   need to supply a separate Jacobian closure. See
   :doc:`/user_guide/linear_solvers`.
"""

import torch
from torch.autograd import Function
from typing import Callable, Tuple
from ..sparse.matrix import SparseMatrix


def _newton_solve(
    f: Callable[..., torch.Tensor],
    j: Callable[..., SparseMatrix],
    u0: torch.Tensor,
    params: Tuple[torch.Tensor, ...],
    max_iter: int = 100,
    tol: float = 1e-6,
    verbose: bool = False,
) -> torch.Tensor:
    """Plain Newton iteration; consumed by :class:`NonLinearSolveFunction`.

    Parameters
    ----------
    f : Callable
        ``F(u, *params) -> torch.Tensor`` returning the residual.
    j : Callable
        ``J(u, *params) -> SparseMatrix`` returning ``dF/du`` at ``u``.
    u0 : torch.Tensor
        Initial guess.
    params : Tuple[torch.Tensor, ...]
        Forwarded to ``f`` and ``j``.
    max_iter : int, default 100
        Iteration budget; emits a verbose warning if exhausted.
    tol : float, default 1e-6
        Convergence tolerance on ``||F(u)||``.
    verbose : bool, default False
        Print residual norm at every step.

    Returns
    -------
    torch.Tensor
        Solution ``u``.
    """
    u = u0.clone()
    
    for i in range(max_iter):
        res = f(u, *params)
        res_norm = torch.norm(res)
        
        if verbose:
            print(f"Iter {i}: |F(u)| = {res_norm:.6e}")
            
        if res_norm < tol:
            return u
            
        J = j(u, *params)
        # Newton step: u_{n+1} = u_n - J^{-1} F(u_n)
        # J du = res => du = J^{-1} res
        # Solve linear system with tighter tolerance than Newton tolerance
        linear_tol = max(tol * 0.01, 1e-12)
        du = J.solve(res, tol=linear_tol)
        u = u - du
        
    if verbose:
        print(f"Newton solver reached max_iter ({max_iter}) with residual {res_norm:.6e}")
        
    return u

class NonLinearSolveFunction(Function):
    """Autograd :class:`Function` wrapping :func:`_newton_solve`.

    Forward runs Newton-Raphson in ``no_grad``. Backward applies the
    implicit-function theorem: solve ``J^T lam = grad_output`` for the
    adjoint state ``lam``, then VJP ``-lam`` against ``F`` to get the
    parameter gradients in one extra linear solve.
    """

    @staticmethod
    def forward(ctx, f, j, u0, solver_config, *params):
        with torch.no_grad():
            u = _newton_solve(f, j, u0, params, **solver_config)
        ctx.save_for_backward(u, *params)
        ctx.f = f
        ctx.j = j
        return u

    @staticmethod
    def backward(ctx, grad_output):
        u = ctx.saved_tensors[0]
        params = ctx.saved_tensors[1:]
        f = ctx.f
        j = ctx.j

        with torch.no_grad():
            J = j(u, *params)

        if not isinstance(J, SparseMatrix):
            raise TypeError(f"Jacobian function j must return a SparseMatrix, got {type(J)}")

        # Adjoint solve: J^T lam = grad_output.
        lam = J.T.solve(grad_output)

        # VJP via autograd: dL/dparams = -lam^T dF/dparams.
        with torch.enable_grad():
            res = f(u.detach(), *params)
            grads = torch.autograd.grad(
                outputs=res,
                inputs=params,
                grad_outputs=-lam,
                allow_unused=True,
            )

        # Signature: (f, j, u0, solver_config, *params).
        return (None, None, None, None) + grads

def nonlinear_solve(
    f: Callable[..., torch.Tensor],
    j: Callable[..., SparseMatrix],
    u0: torch.Tensor,
    params: Tuple[torch.Tensor, ...],
    max_iter: int = 100,
    tol: float = 1e-6,
    verbose: bool = False,
) -> torch.Tensor:
    """Solve ``F(u, params) = 0`` for ``u`` (legacy in-tree implementation).

    .. deprecated:: 0.x

       This in-tree Newton-Raphson driver is **scheduled for removal**.
       ``torch-sla`` ships a richer
       ``torch_sla.SparseTensor.nonlinear_solve`` (also accessible
       as ``SparseMatrix.nonlinear_solve``) with Newton / Picard /
       Anderson modes, Armijo line search, and an autograd-based
       Jacobian — so the user no longer has to supply ``j``. Migrate to
       ``A.nonlinear_solve(residual, u0, *params)``; see
       :doc:`/user_guide/linear_solvers`.

    Drives Newton-Raphson on the forward pass and the implicit-function
    theorem on the backward pass: gradients w.r.t. ``params`` cost
    roughly one extra linear solve regardless of how many Newton
    iterations were taken.

    Parameters
    ----------
    f : Callable
        ``F(u, *params) -> torch.Tensor``. Must support autograd in
        ``params`` for gradients to flow.
    j : Callable
        ``J(u, *params) -> SparseMatrix``: the Jacobian ``dF/du``.
    u0 : torch.Tensor
        Initial guess.
    params : Tuple[torch.Tensor, ...]
        Optimizable parameters forwarded to ``f`` / ``j``.
    max_iter : int, default 100
        Newton iteration budget.
    tol : float, default 1e-6
        Convergence tolerance on ``||F(u)||``.
    verbose : bool, default False
        Print residual norm each Newton step.

    Returns
    -------
    torch.Tensor
        Converged ``u``; gradients route back into ``params`` via the
        adjoint solve inside ``NonLinearSolveFunction``.
    """
    solver_config = {
        'max_iter': max_iter,
        'tol': tol,
        'verbose': verbose
    }
    return NonLinearSolveFunction.apply(f, j, u0, solver_config, *params)

