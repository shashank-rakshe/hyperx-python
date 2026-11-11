"""CuPy-backed sparse matmul / matvec with custom autograd (CUDA only)."""

import torch
from torch.autograd import Function
import importlib
from ..utils import tensor2cupy, cupy2tensor, shapeT, is_cupy_available

if is_cupy_available:
    cupyx = importlib.import_module('cupyx')
    cp    = importlib.import_module('cupy')
    importlib.import_module('cupyx.scipy.sparse')


class SparseMMCupy(Function):
    """Differentiable ``A @ B`` via :class:`cupyx.scipy.sparse.coo_matrix`."""

    @staticmethod
    def forward(ctx, edata, row, col, shape, B):
        cp.cuda.Device(edata.device.index).use()
        A_cupy = cupyx.scipy.sparse.coo_matrix((
            tensor2cupy(edata), (tensor2cupy(row), tensor2cupy(col))), 
            shape = shape)
        C_cupy = A_cupy.dot(tensor2cupy(B))
        C = cupy2tensor(C_cupy)
        ctx.save_for_backward(edata, row, col, B)
        ctx.A_shape = shape
        return C

    @staticmethod
    def backward(ctx, grad_outputs):
        edata, row, col, B = ctx.saved_tensors
        edata_grad  = (grad_outputs[row]* B[col]).sum(dim=1)
        A_T    = cupyx.scipy.sparse.coo_matrix((
            tensor2cupy(edata), (tensor2cupy(col),tensor2cupy(row))), 
            shape=shapeT(ctx.A_shape))
        grad_B = A_T.dot(tensor2cupy(grad_outputs))
        grad_B = cupy2tensor(grad_B)
        return edata_grad, None, None, None, grad_B
       
class SparseMVCupy(Function):
    """Differentiable ``A @ b`` via :class:`cupyx.scipy.sparse.coo_matrix`."""

    @staticmethod
    def forward(ctx, edata, row, col, shape, B):
        cp.cuda.Device(edata.device.index).use()
        A_cupy = cupyx.scipy.sparse.coo_matrix((
            tensor2cupy(edata), (tensor2cupy(row), tensor2cupy(col))
            ), shape = shape)
        C_cupy = A_cupy.dot(tensor2cupy(B))
        C = cupy2tensor(C_cupy)
        ctx.save_for_backward(edata, row, col, B)
        ctx.A_shape = shape
        return C

    @staticmethod
    def backward(ctx, grad_outputs):
        edata, row, col, B = ctx.saved_tensors  
        edata_grad  = grad_outputs[row]  * B[col]
        A_T    = cupyx.scipy.sparse.coo_matrix((
            tensor2cupy(edata), (tensor2cupy(col),tensor2cupy(row))), 
            shape=shapeT(ctx.A_shape))
        grad_B = A_T.dot(tensor2cupy(grad_outputs))
        grad_B = cupy2tensor(grad_B)
        return edata_grad, None, None, None, grad_B


