import torch 
import sys 
sys.path.append("../..")
from tensormesh.element.transformation import Transformation
from tensormesh import  Mesh

def _init_trans():
    mesh  = Mesh.gen_rectangle(0.1, order=2)
    elements = mesh.elements()
    trans = Transformation(mesh.points, mesh.elements(), mesh.default_element_type, 4)  
    return trans

def tri_shape_grad_p2(quadrature, element_coords):
    """
        Parameters:
        -----------
            quadrature: torch.Tensor [n_quadrature, n_dim]
            element_coords: torch.Tensor [n_element, n_corner, n_dim]
                        n_dim = 2 for triangle
            return_jac: bool
                        whether to return the jacobian
                        default is False
        Returns:
        --------
            grad_phi: torch.Tensor of shape [n_element, n_quadrature, n_basis, n_dim]
                the gradient of the base functions
            jacdet     : torch.Tensor of shape [n_element, n_quadrature]
                the jacobian of the base functions
                if return_jac is False, then jac is None
    """
    assert element_coords.dtype == quadrature.dtype, f"element_coords.dtype must be {quadrature.dtype}, but got {element_coords.dtype}"
    assert element_coords.device == quadrature.device, f"element_coords.device must be {quadrature.device}, but got {element_coords.device}"
    assert element_coords.dim() == 3, f"element_coords must be 3D of shape [n_element, 6, 2], but got {element_coords.dim()}"
    n_quadrature, n_dim = quadrature.shape 
    n_element, n_corner, _ = element_coords.shape
    assert n_dim == 2, f"n_dim must be 2 for triangle , but got {n_dim}"
    
    n_basis = 6
    grad_phi = torch.zeros(n_quadrature, n_basis, n_dim, device=quadrature.device,dtype=quadrature.dtype)
    xi, eta = quadrature[..., 0], quadrature[..., 1]
    grad_phi[..., 0, 0] = -3 + 4*xi + 4*eta
    grad_phi[..., 0, 1] = -3 + 4*xi + 4*eta
    grad_phi[..., 1, 0] = 2 - 4*xi - 2*eta
    grad_phi[..., 1, 1] = -2*xi
    grad_phi[..., 2, 0] = 2 - 4*xi - 2*eta
    grad_phi[..., 2, 1] = 0
    # grad_phi[..., 3, 0] = 2*eta
    # grad_phi[..., 3, 1] = 2*xi
    # grad_phi[..., 4, 0] = -2*eta
    # grad_phi[..., 4, 1] = 1 - 2*xi - 2*eta
    # grad_phi[..., 5, 0] = 0
    # grad_phi[..., 5, 1] = 4*eta - 2
    grad_phi[..., 5, 0] = 2*eta
    grad_phi[..., 5, 1] = 2*xi
    grad_phi[..., 3, 0] = -2*eta
    grad_phi[..., 3, 1] = 1 - 2*xi - 2*eta
    grad_phi[..., 4, 0] = 0
    grad_phi[..., 4, 1] = 4*eta - 2

    jac  = torch.einsum("ebj,qbi->eqij", element_coords, grad_phi)
    ijac = torch.inverse(jac)
    grad_phi = torch.einsum("qbi,eqji->eqbj", grad_phi, ijac)
    jacdet = torch.det(jac)
    return grad_phi, jacdet

def shape_val_p2(quadrature):
    """
        Parameters:
        -----------
            quadrature: torch.Tensor [n_quadrature, n_dim]
                        n_dim = 2 for triangle
        Returns:
        --------
            phi      : torch.Tensor [n_quadrature, n_basis]
                        n_basis = 6
    """
    n_quadrature, n_dim = quadrature.shape[-2:]
    assert n_dim == 2, f"n_dim must be 2 for triangle , but got {n_dim}"

    phi = torch.zeros(*quadrature.shape[:-1], 6, device=quadrature.device, dtype=quadrature.dtype)
    xi, eta = quadrature[..., 0], quadrature[..., 1]
    
    phi[..., 0] = (1 - xi - eta) * ( 1 - 2*xi - 2*eta)
    phi[..., 1] = xi * (2*xi - 1)
    phi[..., 2] = eta * (2*eta - 1)
    # phi[..., 3] = 4*xi * (1 - xi - eta)
    # phi[..., 4] = 4*xi * eta
    # phi[..., 5] = 4*eta * (1 - xi - eta)
    phi[..., 5] = 4*xi * (1 - xi - eta)
    phi[..., 3] = 4*xi * eta
    phi[..., 4] = 4 * eta * (1 - xi - eta)
    # phi[..., 0] = 1 - 3*xi - 3*eta + 2*xi*xi + 4*xi*eta + 2*eta*eta
    # phi[..., 1] = 2*xi - 2*xi*xi - 2*xi*eta
    # phi[..., 2] = -xi + 2*xi*xi
    # phi[..., 3] = 2*xi*eta
    # phi[..., 4] = -eta + 2*xi*eta
    # phi[..., 5] = 2*eta*eta - 2*eta
    return phi

def test_batch_quadrature():
    trans      = _init_trans()
    w, q       = trans.batch_quadrature(0,  4)
    assert w.shape[0] == q.shape[0] == 4
    assert w.dim() == 1
    assert q.dim() == 2
    assert q.shape[1] == trans.dim

def test_batch_element_coords():
    trans   = _init_trans()
    ele_coords = trans.batch_elements_coords(0, 4)  
    assert ele_coords.dim() == 3 
    assert ele_coords.shape[0] == 4
    assert ele_coords.shape[1] == trans.n_basis
    assert ele_coords.shape[2] == trans.dim

def test_batch_shape_val():
    trans   = _init_trans()
    shape_val  = trans.batch_shape_val(0, 4)
    assert shape_val.dim() == 2
    assert shape_val.shape[0] ==  4
    assert shape_val.shape[1] == trans.n_basis 

    w, q  = trans.batch_quadrature(0, 4)
    _shape_val = shape_val_p2(q)

    # breakpoint()
    assert _shape_val.allclose(shape_val)

def test_batch_shape_grad_jxw():
    trans   = _init_trans()
    shape_grad, jxw = trans.batch_shape_grad_jxw(0, 4, 0, 2)
    assert shape_grad.dim() == 4 
    assert jxw.dim() == 2
    assert shape_grad.shape[0] == jxw.shape[0] == 4 # n_element
    assert shape_grad.shape[1] == jxw.shape[1] == 2 # n_quadrature
    assert shape_grad.shape[2] == trans.n_basis
    assert shape_grad.shape[3] == trans.dim


    # element_coords = trans.batch_elements_coords(0, 4)
    # w, q           = trans.batch_quadrature(0, 2)
    # _shape_grad, _jacdet = tri_shape_grad_p2(q, element_coords)
    # _jxw           = w * _jacdet   

    # assert _shape_grad.allclose(shape_grad)
    # assert _jxw.allclose(jxw)