"""Differentiable sparse matrix-multiply / matrix-vector kernels.

Dispatches to one of three backends:

- ``scipy`` — :func:`scipy.sparse.coo_matrix.dot` (CPU only);
- ``torch`` — :func:`torch.sparse_coo_tensor` then ``.mm`` / ``.mv``
  (CPU or CUDA);
- ``cupy`` — :func:`cupyx.scipy.sparse.coo_matrix.dot` (CUDA, requires
  CuPy).

Each backend ships its own ``Function`` subclass with a custom backward.
Most internal code uses :class:`tensormesh.sparse.SparseMatrix`
``__matmul__`` (inherited from ``torch-sla``) instead of these helpers
directly; they are kept as an escape hatch for the scipy / cupy paths.
"""

from .cupy_mm  import SparseMMCupy, SparseMVCupy
from .scipy_mm import SparseMMScipy, SparseMVScipy
from .torch_mm import SparseMVTorch, SparseMMTorch
from ..utils import is_cupy_available

def spmv(edata, row, col, shape, B, backend=None):
    """Compute ``A @ B`` for sparse ``A`` and dense vector ``B``.

    Parameters
    ----------
    edata : torch.Tensor
        1D tensor of shape ``[nnz]``: non-zero values of ``A``.
    row : torch.Tensor
        1D int tensor of shape ``[nnz]``: row indices of ``A``.
    col : torch.Tensor
        1D int tensor of shape ``[nnz]``: column indices of ``A``.
    shape : Tuple[int, int]
        Shape ``(M, N)`` of the dense ``A``.
    B : torch.Tensor
        1D tensor of shape ``[N]``: the dense vector.
    backend : str or None, default None
        One of ``{None, "scipy", "torch", "cupy"}``. ``None`` picks
        ``"scipy"`` on CPU and ``"cupy"`` (or ``"torch"`` if CuPy is
        missing) on CUDA. Must be compatible with ``edata.device``.

    Returns
    -------
    torch.Tensor
        1D tensor of shape ``[M]``: the output vector ``A @ B``.
    """
    assert backend in [None, 'scipy', 'torch', 'cupy']
    assert edata.dtype == B.dtype, f"A.dtype {edata.dtype} != B.dtype {B.dtype}"
    assert B.dim() == 1
    if edata.device.type == 'cpu':
        if backend is None or backend == 'scipy':
            return SparseMVScipy.apply(edata, row, col, shape, B)
        elif backend == 'torch':
            return SparseMVTorch.apply(edata, row, col, shape, B)
        else:
            raise NotImplementedError(f"backend {backend} not supported for CPU")
    elif edata.device.type == 'cuda':
        if backend is None:
            if is_cupy_available:
                return SparseMVCupy.apply(edata, row, col, shape, B)
            else:
                # Use torch backend when cupy is not available (scipy doesn't support CUDA)
                return SparseMVTorch.apply(edata, row, col, shape, B)
        elif backend == 'cupy':
            assert is_cupy_available, f"cupy is not available"
            return SparseMVCupy.apply(edata, row, col, shape, B)
        elif backend == 'torch':
            return SparseMVTorch.apply(edata, row, col, shape, B)
        else:
            raise NotImplementedError(f"backend {backend} not supported for CUDA")
    else:
        raise NotImplementedError(f"device {edata.device.type} not supported")

def spmm(edata, row, col, shape, B, backend=None):
    """Compute ``A @ B`` for sparse ``A`` and dense matrix (or vector) ``B``.

    When ``B`` is 1D this transparently delegates to ``spmv``.

    Parameters
    ----------
    edata : torch.Tensor
        1D tensor of shape ``[nnz]``: non-zero values of ``A``.
    row : torch.Tensor
        1D int tensor of shape ``[nnz]``: row indices of ``A``.
    col : torch.Tensor
        1D int tensor of shape ``[nnz]``: column indices of ``A``.
    shape : Tuple[int, int]
        Shape ``(M, N)`` of the dense ``A``.
    B : torch.Tensor
        Dense operand of shape ``[N, K]`` (matrix) or ``[N]`` (vector).
    backend : str or None, default None
        See ``spmv`` for the backend / device matrix.

    Returns
    -------
    torch.Tensor
        ``[M, K]`` or ``[M]`` matching the rank of ``B``.
    """
    assert edata.dtype == B.dtype, f"A.dtype {edata.dtype} != B.dtype {B.dtype}"
    if B.dim() == 1:
        return spmv(edata, row, col, shape, B)
    assert B.dim() == 2
    if edata.device.type == 'cpu':
        if backend is None or backend == 'scipy':
            return SparseMMScipy.apply(edata, row, col, shape, B)
        elif backend == 'torch':
            return SparseMMTorch.apply(edata, row, col, shape, B)
        else:
            raise NotImplementedError(f"backend {backend} not supported for CPU")
    elif edata.device.type == 'cuda':
        if backend is None:
            if is_cupy_available:
                return SparseMMCupy.apply(edata, row, col, shape, B)
            else:
                # Use torch backend when cupy is not available (scipy doesn't support CUDA)
                return SparseMMTorch.apply(edata, row, col, shape, B)
        elif backend == 'cupy':
            assert is_cupy_available, f"cupy is not available"
            return SparseMMCupy.apply(edata, row, col, shape, B)
        elif backend == 'torch':
            return SparseMMTorch.apply(edata, row, col, shape, B)
        else:
            raise NotImplementedError(f"backend {backend} not supported for CUDA")
    else:
        raise NotImplementedError(f"device {edata.device.type} not supported")
