"""Sparse linear system solvers for TensorMesh (legacy entry points).

.. deprecated:: 0.x

   The module-level :func:`spsolve` here is a **TensorMesh-internal
   wrapper scheduled for removal**. The canonical solver path has
   migrated to ``torch-sla``: assembly returns a
   :class:`~tensormesh.sparse.SparseMatrix` (a subclass of
   :class:`torch_sla.SparseTensor`), and you simply call ``K.solve(b)``,
   which auto-detects symmetry / positive-definiteness and dispatches
   directly to ``torch_sla.spsolve``. See
   :doc:`/user_guide/linear_solvers`.

The free function below remains only for the niche case where a caller
holds raw ``(edata, row, col, shape, b)`` arrays without a
:class:`SparseMatrix`. With ``torch-sla`` installed (the default and
recommended path) it dispatches to one of the torch-sla backends —
SciPy / native PyTorch / Eigen / cuDSS / CuPy — chosen by the
``backend`` argument, honours ``method`` / ``preconditioner`` /
``is_spd`` hints, and routes batched right-hand sides through SuperLU.

Without ``torch-sla`` (the legacy fallback path) ``spsolve`` still works
but the choice of algorithm collapses: each fallback wrapper picks a
single hard-coded method (direct SuperLU on CPU / CUDA, BiCGSTAB for the
pure-PyTorch path), and ``method`` / ``preconditioner`` / ``is_spd``
become inert. Install ``torch-sla`` for the full feature set.
"""

import warnings

import torch

try:
    import torch_sla  # noqa: F401  (presence-only check)
    is_torch_sla_available = True
except ImportError:
    is_torch_sla_available = False

from ..utils import is_petsc_available, is_cupy_available


def spsolve(edata, row, col, shape, b,
            backend='auto', method='cg', preconditioner='jacobi',
            tol=1e-5, max_iter=10000, x0=None, is_spd=True,
            verbose=False):
    """Solve the sparse linear system ``A x = b`` (legacy entry point).

    .. deprecated:: 0.x

       This free function pre-dates the ``torch-sla`` integration and is
       **scheduled for removal**. The canonical path is to wrap the data
       in a :class:`~tensormesh.sparse.SparseMatrix` and call its
       ``solve`` method (inherited from ``torch_sla.SparseTensor``),
       which auto-detects symmetry / positive-definiteness and routes
       to ``torch_sla.spsolve`` directly. See
       :doc:`/user_guide/linear_solvers`.

    Low-level entry point: takes raw COO arrays instead of a
    :class:`~tensormesh.sparse.SparseMatrix` object. With ``torch-sla`` installed,
    dispatches to a differentiable sparse-linear-algebra backend;
    without it, falls back to a curated mini-stack of
    SciPy / SuperLU / CuPy / PETSc wrappers.

    Parameters
    ----------
    edata : torch.Tensor
        1D tensor of shape ``[nnz]``: non-zero values of ``A``.
    row : torch.Tensor
        1D int tensor of shape ``[nnz]``: row indices of ``A``.
    col : torch.Tensor
        1D int tensor of shape ``[nnz]``: column indices of ``A``.
    shape : Tuple[int, int]
        Dense shape ``(m, n)`` of ``A``.
    b : torch.Tensor
        Right-hand side. Shape ``[n]`` for a single RHS, or
        ``[n, n_batch]`` for batched RHS (auto-routed through SuperLU).
    backend : str, default ``"auto"``
        Torch-sla path: ``"auto"`` (CPU → ``"scipy"``, CUDA →
        ``"pytorch"``), ``"scipy"``, ``"pytorch"``, ``"eigen"``,
        ``"cudss"``, ``"cupy"``.
        Fallback path (no torch-sla): ``"auto"``, ``"petsc"``,
        ``"cupy"`` — others are accepted but the method/preconditioner
        hints below are ignored.
    method : str, default ``"cg"``
        Iterative algorithm — ``"cg"``, ``"bicgstab"``, ``"minres"``,
        ``"gmres"``, ``"lgmres"`` — or one of the direct factorizations
        ``"lu"``, ``"umfpack"``, ``"cholesky"``, ``"ldlt"``. See the
        installed ``torch_sla.spsolve`` signature for the canonical
        list. **Honoured only on the torch-sla path.** On the fallback
        path, each wrapper uses a fixed algorithm.
    preconditioner : str, default ``"jacobi"``
        ``"jacobi"``, ``"ilu"``, or ``"none"``. Same caveat as
        ``method`` — torch-sla path only.
    tol : float, default ``1e-5``
        Convergence tolerance (iterative methods).
    max_iter : int, default ``10000``
        Iteration budget (iterative methods).
    x0 : torch.Tensor, optional
        Initial guess. Currently consumed only by some fallback wrappers
        and ignored by torch-sla.
    is_spd : bool, default ``True``
        Hint to the torch-sla path that ``A`` is symmetric positive
        definite. Picks CG as the default ``method``; set ``False`` for
        indefinite / non-symmetric ``A`` and combine with
        ``method="bicgstab"`` or ``"gmres"``.
    verbose : bool, default ``False``
        Print which backend/method was picked.

    Returns
    -------
    torch.Tensor
        Solution ``x``, same shape and dtype as ``b``.

    Notes
    -----
    Both paths are autograd-aware: gradients of ``x`` flow back into
    ``edata`` and ``b`` via an adjoint sparse solve. On the torch-sla
    path this is built in to the library; on the fallback path each
    wrapper supplies its own :class:`torch.autograd.Function` backward.

    Examples
    --------
    >>> from tensormesh.sparse import spsolve
    >>> x = spsolve(edata, row, col, (n, n), b)                   # auto
    >>> x = spsolve(edata, row, col, (n, n), b, method="lu")      # direct
    >>> x = spsolve(edata, row, col, (n, n), b, backend="cudss")  # GPU direct
    >>> x = spsolve(edata, row, col, (n, n), b,
    ...             is_spd=False, method="bicgstab")              # non-SPD
    """
    
    # Validate inputs
    assert edata.device == row.device == col.device == b.device, \
        f"All inputs must be on same device, got {edata.device}, {row.device}, {col.device}, {b.device}"
    
    if edata.dtype != torch.float64:
        warnings.warn("float64 recommended for better accuracy in spsolve")
    
    # Handle batched RHS
    is_batched = len(b.shape) == 2
    
    # Use torch-sla if available (preferred)
    if is_torch_sla_available:
        return _solve_torch_sla(
            edata, row, col, shape, b,
            backend=backend, method=method, preconditioner=preconditioner,
            tol=tol, max_iter=max_iter, x0=x0, is_spd=is_spd,
            is_batched=is_batched, verbose=verbose
        )
    
    # Fallback to legacy solvers
    warnings.warn(
        "torch-sla not available, using fallback solver. "
        "Install torch-sla for better performance: pip install torch-sla"
    )
    return _solve_fallback(
        edata, row, col, shape, b,
        backend=backend, tol=tol, max_iter=max_iter, x0=x0,
        is_batched=is_batched, verbose=verbose
    )


def _solve_torch_sla(edata, row, col, shape, b,
                     backend, method, preconditioner,
                     tol, max_iter, x0, is_spd,
                     is_batched, verbose):
    """Solve via torch-sla; honours ``method`` / ``preconditioner`` / ``is_spd``.

    Batched RHS (``b.ndim == 2``) auto-routes to an LU factorization
    when the user did not request a direct method, since a single
    factorization + ``n_batch`` back-substitutions beats running an
    iterative solver per column.
    """
    from .torch_sla_solve import SparseSolveTorchSLA

    # Map 'auto' to appropriate torch-sla backend.
    if backend == 'auto':
        if edata.device.type == 'cuda':
            backend = 'pytorch'
        else:
            backend = 'scipy'

    # For batched solve, route iterative requests to a direct factorization.
    _DIRECT_METHODS = ('lu', 'umfpack', 'cholesky', 'ldlt')
    if is_batched and method not in _DIRECT_METHODS:
        if verbose:
            print(f"Using LU for batched solve (batch_size={b.shape[1]})")
        method = 'lu'
    
    if verbose:
        print(f"Solving with torch-sla: backend={backend}, method={method}, preconditioner={preconditioner}")
    
    return SparseSolveTorchSLA.apply(
        edata, row, col, shape, b,
        x0, tol, max_iter,
        backend, method, preconditioner, is_spd
    )


def _solve_fallback(edata, row, col, shape, b,
                    backend, tol, max_iter, x0,
                    is_batched, verbose):
    """Fallback dispatcher when torch-sla is unavailable.

    Each branch picks a fixed algorithm:

    - CPU + non-batched + ``backend="petsc"`` → PETSc BiCGSTAB + ILU;
    - CPU + non-batched + otherwise → SciPy ``spsolve`` (direct);
    - CPU + batched → SciPy SuperLU;
    - CUDA + non-batched + CuPy available → CuPy ``spsolve`` (direct);
    - CUDA + batched + CuPy available → CuPy SuperLU;
    - CUDA + CuPy missing → pure-PyTorch BiCGSTAB (only path that
      consults ``tol`` / ``max_iter`` / ``x0``).

    ``method`` and ``preconditioner`` from :func:`spsolve` do not reach
    this function; they are torch-sla-only knobs.
    """
    
    # Import fallback solvers
    from .scipy_solve import SparseSolveScipy, SparseLUSolveScipy
    from .torch_solve import SparseSolveTorch
    
    device = edata.device
    
    if device.type == 'cuda':
        # CUDA fallback
        if is_cupy_available:
            from .cupy_solve import SparseSolveCupy, SparseLUSolveCupy
            if is_batched:
                return SparseLUSolveCupy.apply(edata, row, col, shape, b)
            else:
                return SparseSolveCupy.apply(edata, row, col, shape, b)
        else:
            # Use torch sparse solver
            return SparseSolveTorch.apply(edata, row, col, shape, b, x0, tol, max_iter)
    else:
        # CPU fallback
        if is_batched:
            return SparseLUSolveScipy.apply(edata, row, col, shape, b)
        else:
            if backend == 'petsc' and is_petsc_available:
                from .petsc_solve import SparseSolvePETSc
                return SparseSolvePETSc.apply(edata, row, col, shape, b)
            else:
                return SparseSolveScipy.apply(edata, row, col, shape, b)
