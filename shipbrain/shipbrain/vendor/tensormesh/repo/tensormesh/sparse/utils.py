"""Internal utilities shared across the sparse module.

- Backend availability flags (:data:`is_petsc_available`,
  :data:`is_cupy_available`) toggled by env vars
  ``TORCH_FEM_USE_PETSC`` / ``TORCH_FEM_USE_CUPY`` and library import.
- Zero-copy DLPack converters between torch tensors and CuPy arrays
  (:func:`tensor2cupy`, :func:`cupy2tensor`).
- :func:`shapeT` — 2-tuple shape transpose.
"""

import os

import torch

if "TORCH_FEM_USE_PETSC" not in os.environ or os.environ["TORCH_FEM_USE_PETSC"] == "true":
    try:
        import petsc4py  # noqa: F401  (presence-only check)
        is_petsc_available = True
    except ImportError:
        is_petsc_available = False
else:
    is_petsc_available = False

if "TORCH_FEM_USE_CUPY" not in os.environ or os.environ["TORCH_FEM_USE_CUPY"] == "true":
    try:
        import cupy as cp
        is_cupy_available = True
    except ImportError:
        is_cupy_available = False
else:
    is_cupy_available = False


def tensor2cupy(tensor):
    """Zero-copy view of a CUDA :class:`torch.Tensor` as a :class:`cupy.ndarray`.

    Parameters
    ----------
    tensor : torch.Tensor
        Must live on a CUDA device.

    Returns
    -------
    cupy.ndarray
        Shares memory with the input.

    Examples
    --------
    >>> import torch
    >>> import cupy as cp
    >>> x = torch.randn(2, 3).cuda()
    >>> y = tensor2cupy(x)
    >>> isinstance(y, cp.ndarray)
    True
    >>> y.shape == x.shape
    True
    """
    assert is_cupy_available, "cupy is not available"
    assert tensor.device.type == "cuda", "the device of tensor must be cuda"
    return cp.from_dlpack(torch.utils.dlpack.to_dlpack(tensor))


def cupy2tensor(cupy):
    """Zero-copy view of a :class:`cupy.ndarray` as a CUDA :class:`torch.Tensor`.

    Parameters
    ----------
    cupy : cupy.ndarray
        Source array; must live on a CUDA device.

    Returns
    -------
    torch.Tensor
        Shares memory with the input.

    Examples
    --------
    >>> import cupy as cp
    >>> x = cp.array([[1, 2], [3, 4]])
    >>> y = cupy2tensor(x)
    >>> isinstance(y, torch.Tensor)
    True
    >>> y.shape == x.shape
    True
    """
    return torch.utils.dlpack.from_dlpack(cupy.toDlpack())


def shapeT(shape):
    """Transpose a 2-tuple shape: ``(m, n)`` → ``(n, m)``.

    Parameters
    ----------
    shape : Tuple[int, int]

    Returns
    -------
    Tuple[int, int]

    Examples
    --------
    >>> shapeT((2, 3))
    (3, 2)
    """
    return (shape[1], shape[0])