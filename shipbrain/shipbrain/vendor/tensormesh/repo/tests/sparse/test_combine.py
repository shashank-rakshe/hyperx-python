import sys 
sys.path.append("../..")


import torch 
import random
import scipy.sparse
from tensormesh.sparse import SparseMatrix

def test_combine_vector():
    x = torch.rand([4, 4])
    y = torch.rand([6, 4])
    z = torch.rand([1, 4])

    mat = SparseMatrix.combine([x, y, z]).to_dense()

    label = torch.cat([x, y, z], 0)

    assert torch.allclose(mat, label), f"expected {label}, got {mat}"

def test_combine_matrix():
    a11 = torch.rand([4, 4])
    a12 = torch.rand([4, 6])
    a13 = torch.zeros([4, 1])
    a21 = torch.rand([2, 4])
    a22 = torch.full([2, 6], 2)
    a23 = torch.zeros([2, 1])
    
    mat = SparseMatrix.combine([
        [a11, a12, None],
        [a21, 2, a23]
    ]).to_dense()
    
    label = torch.cat([
        torch.cat([a11, a12, a13], 1),
        torch.cat([a21, a22, a23], 1)
    ], 0)

    assert torch.allclose(mat, label), f"expected {label}, got {mat}"