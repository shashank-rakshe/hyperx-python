from numpy import tri
import torch 
import sys
import numpy as np
sys.path.append("../..")
from typing import Type, Optional
from tensormesh.element import Element,\
                                Triangle,\
                                Quadrilateral,\
                                Tetrahedron,\
                                Hexahedron,\
                                Prism,\
                                Pyramid


def _quadrature(element:Type[Element], volume:float):
    for order in range(1, 4):
        w, q = element.get_quadrature(order)
        assert w.dim() == 1 
        assert q.dim() == 2
        assert w.shape[0] == q.shape[0]
        assert q.shape[1] == element.dim 
        assert w.sum().allclose(torch.tensor([volume]).type(w.dtype), atol=1e-4, rtol=1e-4)


def _facet_quadrature(element:Type[Element], facet_volumne:Optional[float]=None):
    for order in range(1, 4):
        facet_quadrature = element.get_facet_quadrature(order)  
        if len(facet_quadrature) == 2:
            w, q = facet_quadrature 
            assert w.dim() == 2
            assert q.dim() == 3
            assert w.shape[0:2] == q.shape[0:2]
            assert q.shape[-1] == element.dim
            assert w.sum(-1).allclose(torch.full((w.shape[0],),facet_volumne, dtype=w.dtype), atol=1e-4, rtol=1e-4)
        elif len(facet_quadrature) == 4:
            tri_w, tri_q, quad_w, quad_q = facet_quadrature
            assert tri_w.dim() == 2
            assert tri_q.dim() == 3
            assert tri_w.shape[0:2] == tri_q.shape[0:2]
            assert tri_q.shape[-1] == element.dim
            assert tri_w.sum(-1).allclose(torch.ones(tri_w.shape[0], dtype=tri_w.dtype)/2, atol=1e-4, rtol=1e-4)
            assert (quad_w > 0).all()
            assert quad_w.dim() == 2
            assert quad_q.dim() == 3
            assert quad_w.shape[0:2] == quad_q.shape[0:2]
            assert quad_q.shape[-1] == element.dim
            assert quad_w.sum(-1).allclose(torch.ones(quad_w.shape[0], dtype=quad_w.dtype), atol=1e-4, rtol=1e-4)
        else:
            raise ValueError(f"Invalid facet quadrature, got {facet_quadrature}, expected 2 or 4 elements")
        
def test_tri():
    _quadrature(Triangle, 1/2)
    _facet_quadrature(Triangle, 1)

def test_quad():
    _quadrature(Quadrilateral, 1)
    _facet_quadrature(Quadrilateral, 1)

def test_tet():
    _quadrature(Tetrahedron, 1/6)
    _facet_quadrature(Tetrahedron, 1/2)  

def test_hex():
    _quadrature(Hexahedron, 1)
    _facet_quadrature(Hexahedron, 1)

def test_pyr():
    _quadrature(Pyramid, 1/3)
    _facet_quadrature(Pyramid)

def test_pri():
    _quadrature(Prism, 1/2)
    _facet_quadrature(Prism)