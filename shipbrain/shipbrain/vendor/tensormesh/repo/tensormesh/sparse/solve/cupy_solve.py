"""CuPy-backed sparse direct solvers (CUDA only).

Mirrors :mod:`tensormesh.sparse.solve.scipy_solve` on the GPU:

- :class:`SparseSolveCupy` — single RHS, ``cupyx.scipy.sparse.linalg.spsolve``;
- :class:`SparseLUSolveCupy` — batched RHS,
  ``cupyx.scipy.sparse.linalg.splu``.

Both interop with torch tensors via DLPack (see
:func:`tensormesh.sparse.utils.tensor2cupy`).
"""

import torch
from torch.autograd import Function
import importlib
from ..utils import tensor2cupy, cupy2tensor, shapeT, is_cupy_available

if is_cupy_available:
    cupyx = importlib.import_module('cupyx')
    cp    = importlib.import_module('cupy')
    importlib.import_module('cupyx.scipy.sparse')
    importlib.import_module('cupyx.scipy.sparse.linalg')


class SparseSolveCupy(Function):
    """Differentiable ``A x = b`` via ``cupyx.scipy.sparse.linalg.spsolve``."""

    @staticmethod
    def forward(ctx, edata, row, col, shape, b):
        cp.cuda.Device(edata.device.index).use()
        A_cupy = cupyx.scipy.sparse.coo_matrix((
            tensor2cupy(edata), (tensor2cupy(row), tensor2cupy(col))), 
            shape = shape).tocsr()
        u_cupy = cupyx.scipy.sparse.linalg.spsolve(A_cupy, tensor2cupy(b))
        u = cupy2tensor(u_cupy)
        ctx.save_for_backward(edata, row, col, u)
        ctx.A_shape = shape
        return u
    
    @staticmethod
    def backward(ctx, grad_output):
        edata, row, col, u = ctx.saved_tensors
        A_T             = cupyx.scipy.sparse.coo_matrix((
            tensor2cupy(edata), (tensor2cupy(col), tensor2cupy(row))), 
            shape=shapeT(ctx.A_shape)).tocsr()
        b_grad          = cupyx.scipy.sparse.linalg.spsolve(A_T, tensor2cupy(grad_output))
        b_grad          = cupy2tensor(b_grad)

        edata_grad      = - b_grad[row] * u[col]

        return edata_grad, None, None, None, b_grad
    

class SparseLUSolveCupy(Function):
    """Differentiable batched solve via ``cupyx.scipy.sparse.linalg.splu``."""

    @staticmethod
    def forward(ctx, edata, row, col, shape, b):
        cp.cuda.Device(edata.device.index).use()
        A_cupy = cupyx.scipy.sparse.coo_matrix((
            tensor2cupy(edata), (tensor2cupy(row), tensor2cupy(col))), 
            shape = shape).tocsc()
        lu_cupy = cupyx.scipy.sparse.linalg.splu(A_cupy)
        u_cupy = lu_cupy.solve(tensor2cupy(b))
        u = cupy2tensor(u_cupy)
        ctx.save_for_backward(edata, row, col, u)
        ctx.A_shape = shape
        return u
    
    @staticmethod
    def backward(ctx, grad_output):
        edata, row, col, u = ctx.saved_tensors
        
        A_T             = cupyx.scipy.sparse.coo_matrix((
            tensor2cupy(edata), (tensor2cupy(col), tensor2cupy(row))), 
            shape=shapeT(ctx.A_shape)).tocsc()
        b_grad          = cupyx.scipy.sparse.linalg.splu(A_T).solve(tensor2cupy(grad_output))
        b_grad          = cupy2tensor(b_grad)

        edata_grad      = - (b_grad[row] * u[col]).sum(-1)
        return edata_grad, None, None, None, b_grad

