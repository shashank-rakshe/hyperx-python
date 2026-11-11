"""SciPy-backed sparse matmul / matvec with custom autograd."""

import torch
from torch.autograd import Function
import scipy.sparse
from ..utils import shapeT


class SparseMMScipy(Function):
    """Differentiable ``A @ B`` via :func:`scipy.sparse.coo_matrix.dot` (CPU)."""

    @staticmethod
    def forward(ctx, edata, row, col, shape, B):
        ctx.save_for_backward(edata, row, col, B)
        A_scipy = scipy.sparse.coo_matrix(
            (edata.detach().cpu().numpy(),
             (row.detach().cpu().numpy(), col.detach().cpu().numpy())),
            shape=shape,
        )
        C_scipy = A_scipy.dot(B.detach().cpu().numpy())
        ctx.A_shape = shape
        return torch.tensor(C_scipy, dtype=B.dtype, device=B.device)

    @staticmethod
    def backward(ctx, grad_outputs):
        edata, row, col, B = ctx.saved_tensors
        edata_grad = (grad_outputs[row] * B[col]).sum(dim=1)

        A_T = scipy.sparse.coo_matrix(
            (edata.detach().cpu().numpy(),
             (col.detach().cpu().numpy(), row.detach().cpu().numpy())),
            shape=[ctx.A_shape[1], ctx.A_shape[0]],
        )
        grad_B = A_T.dot(grad_outputs.detach().cpu().numpy())
        grad_B = torch.tensor(grad_B, dtype=B.dtype, device=B.device)
        return edata_grad, None, None, None, grad_B


class SparseMVScipy(Function):
    """Differentiable ``A @ b`` via :func:`scipy.sparse.coo_matrix.dot` (CPU)."""

    @staticmethod
    def forward(ctx, edata, row, col, shape, B):
        ctx.save_for_backward(edata, row, col, B)
        A_scipy = scipy.sparse.coo_matrix(
            (edata.detach().cpu().numpy(),
             (row.detach().cpu().numpy(), col.detach().cpu().numpy())),
            shape=shape,
        )
        C_scipy = A_scipy.dot(B.detach().cpu().numpy())
        ctx.A_shape = shape
        return torch.tensor(C_scipy, dtype=B.dtype, device=B.device)

    @staticmethod
    def backward(ctx, grad_outputs):
        edata, row, col, B = ctx.saved_tensors
        edata_grad = grad_outputs[row] * B[col]
        A_T = scipy.sparse.coo_matrix(
            (edata.detach().cpu().numpy(),
             (col.detach().cpu().numpy(), row.detach().cpu().numpy())),
            shape=[ctx.A_shape[1], ctx.A_shape[0]],
        )
        grad_B = A_T.dot(grad_outputs.detach().cpu().numpy())
        grad_B = torch.tensor(grad_B, dtype=B.dtype, device=B.device)
        return edata_grad, None, None, None, grad_B