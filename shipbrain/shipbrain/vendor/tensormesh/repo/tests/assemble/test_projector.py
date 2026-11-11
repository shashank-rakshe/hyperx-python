import sys
sys.path.append("../..")
import numpy as np
import torch 
from pytest import mark
from itertools import product
from tensormesh.assemble.projector import ReduceProjector


class NaiveProjector:
    def __init__(self, 
                 src:torch.Tensor,
                 dst:torch.Tensor,
                 from_shape:int,
                 to_shape:int):
        self.src = src
        self.dst = dst


        if isinstance(from_shape, int):
            from_shape = (from_shape,)
        if isinstance(to_shape, int):
            to_shape = (to_shape,)

        self.from_shape = from_shape
        self.to_shape = to_shape
        
    def __call__(self, x:torch.Tensor):

        extra_shape = x.shape[len(self.from_shape):]
        x = x.reshape(np.prod(self.from_shape), *extra_shape)
        o = torch.zeros(np.prod(self.to_shape), *extra_shape, device=x.device)

        for src_idx, dst_idx in zip(self.src, self.dst):
            o[dst_idx] += x[src_idx]

        o = o.reshape(self.to_shape + extra_shape)

        return o

# @mark.parametrize("n_edges,n_dst,n_dim", 
#                   list(product(
#                       [10, 100, 1000], 
#                       [10, 100, 1000], 
#                       [1, 8, 128])))
# def test_sparse_projector_1d(
#         n_edges:int,
#         n_dst:int,
#         n_dim:int):
    
#     src = torch.arange(n_edges)
#     dst = torch.randint(0, n_dst, (n_edges,))
#     x = torch.randn(n_edges, n_dim)

#     proj  = SparseProjector(src, dst, from_shape=n_edges, to_shape=n_dst)
#     proj_ = NaiveProjector(src, dst, from_shape=n_edges, to_shape=n_dst)

#     torch.testing.assert_close(proj(x), proj_(x))

@mark.parametrize("n_edges,n_dst,n_dim", 
                  list(product(
                      [10, 100, 1000], 
                      [10, 100, 1000], 
                      [1, 8, 128])))
def test_reduce_projector_1d(
        n_edges:int,
        n_dst:int,
        n_dim:int):
    
    src = torch.arange(n_edges)
    dst = torch.randint(0, n_dst, (n_edges,))
    x = torch.randn(n_edges, n_dim)

    proj = ReduceProjector(dst, from_shape=n_edges, to_shape=n_dst)
    proj_ = NaiveProjector(src, dst, from_shape=n_edges, to_shape=n_dst)

    torch.testing.assert_close(proj(x), proj_(x))
    
    