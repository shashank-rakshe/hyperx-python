
import torch 
from typing import Union
from .ops import sym,skew,sqrt,divide

def strain(gradu:torch.Tensor)->torch.Tensor:
    r"""

    .. math::

        \varepsilon_{ij} = \frac{1}{2}(\nabla u_{ij} + \nabla u_{ji}), \quad \varepsilon,\nabla u \in \mathbb{R}^{d \times d}

    where:
    
    - :math:`\nabla u \in \mathbb{R}^{d \times d}` is the displacement gradient tensor
    - :math:`\varepsilon \in \mathbb{R}^{d \times d}` is the strain tensor

    Parameters
    ----------
    gradu: torch.Tensor
        1D Tensor of shape [d]
        gradient of displacement field u with respect to spatial coordinates
    Returns
    -------
    torch.Tensor
        2D Tensor of shape [d, d]
    """
    return sym(gradu)


def isotropic_stress(strain:torch.Tensor, 
           E:Union[float,torch.Tensor]=70.0, 
           nu:Union[float,torch.Tensor] = 0.3)->torch.Tensor:
    r"""
    .. math::

        \sigma_{ij} = \frac{E}{1+\nu} \left(\varepsilon_{ij} + \frac{\nu}{1-2\nu} \text{tr}(\varepsilon) \delta_{ij}\right), \quad \sigma,\varepsilon \in \mathbb{R}^{d \times d}

    where:

    - :math:`\sigma \in \mathbb{R}^{d \times d}` is the stress tensor
    - :math:`\varepsilon \in \mathbb{R}^{d \times d}` is the strain tensor
    - :math:`E \in \mathbb{R}` is Young's modulus
    - :math:`\nu \in \mathbb{R}` is Poisson's ratio
    - :math:`\delta_{ij} \in \mathbb{R}^{d \times d}` is the Kronecker delta tensor
    - :math:`\text{tr}: \mathbb{R}^{d \times d} \rightarrow \mathbb{R}` denotes the trace operator

    Parameters
    ----------
    strain: torch.Tensor
        2D Tensor of shape [d, d]
        strain tensor

    E: Union[float,torch.Tensor]
        if torch.Tensor, 0D Tensor of shape []
        Young's modulus

    nu: Union[float,torch.Tensor]
        if torch.Tensor, 0D Tensor of shape []
        Poisson's ratio

    Returns
    -------
    torch.Tensor
        2D Tensor of shape [d, d]
    """
    # assertion
    if isinstance(E, torch.Tensor):
        assert E.shape == strain.shape[:-2]
    if isinstance(nu, torch.Tensor):
        assert nu.shape == strain.shape[:-2]

    dim = strain.shape[-1]
    mu = E/(2.*(1. + nu))
    _lambda = E*nu/((1+nu)*(1-2*nu))
    return _lambda * strain.trace().repeat(dim).diag() + 2 * mu * strain
   

def deviatoric_stress(stress:torch.Tensor)->torch.Tensor:
    r"""
    .. math::

        s_{ij} = \sigma_{ij} - \frac{1}{d} \text{tr}(\sigma) \delta_{ij}, \quad s,\sigma \in \mathbb{R}^{d \times d}

    where:

    - :math:`s_{ij} \in \mathbb{R}^{d \times d}` is the deviatoric stress tensor
    - :math:`\sigma_{ij} \in \mathbb{R}^{d \times d}` is the stress tensor 
    - :math:`d \in \mathbb{N}` is the dimension
    - :math:`\delta_{ij} \in \mathbb{R}^{d \times d}` is the Kronecker delta
    - :math:`\text{tr}: \mathbb{R}^{d \times d} \rightarrow \mathbb{R}` denotes the trace operator

    Parameters
    ----------
    stress: torch.Tensor
        2D Tensor of shape [d, d]
        stress tensor

    Returns
    -------
    torch.Tensor
        2D Tensor of shape [d, d]
    """
    dim = stress.shape[-1]
    return stress - divide(1. , dim * stress.trace().repeat(dim).diag())

def deviatoric_stress_norm(stress:torch.Tensor)->torch.Tensor:
    r"""Euclidean norm of the deviatoric stress tensor.

    .. math::

        \|s\| = \sqrt{\frac{3}{2} s:s}

    where :math:`s` is the deviatoric stress tensor, :math:`\|s\|` is its
    norm, and ``:`` denotes the double-dot product.

    Parameters
    ----------
    stress: torch.Tensor
        2D Tensor of shape [d, d]
        stress tensor

    Returns
    -------
    torch.Tensor
        0D Tensor of shape []
    """
    stress = deviatoric_stress(stress)
    return sqrt(1.5*(stress * stress).sum())


def voigt_shape_grad(gradu:torch.Tensor)->torch.Tensor:
    r"""

    Convert displacement gradient to Voigt notation for strain calculation.

    For 2D:

    .. math::

        B \in \mathbb{R}^{3 \times (2\times 3)} = \begin{bmatrix}
            \frac{\partial u_1}{\partial x_1} & 0 & \mid & \frac{\partial u_2}{\partial x_1} & 0 & \mid & \frac{\partial u_3}{\partial x_1} & 0 \\
            0 & \frac{\partial u_1}{\partial x_2} & \mid & 0 & \frac{\partial u_2}{\partial x_2} & \mid & 0 & \frac{\partial u_3}{\partial x_2} \\
            \frac{\partial u_1}{\partial x_2} & \frac{\partial u_1}{\partial x_1} & \mid & \frac{\partial u_2}{\partial x_2} & \frac{\partial u_2}{\partial x_1} & \mid & \frac{\partial u_3}{\partial x_2} & \frac{\partial u_3}{\partial x_1}
        \end{bmatrix}

    representing [:math:`\varepsilon_{xx}, \varepsilon_{yy}, \gamma_{xy}`]

    where:
    
    - :math:`u_i \in \mathbb{R}` is the displacement component in direction i
    - :math:`x_i \in \mathbb{R}` is the spatial coordinate in direction i
    - :math:`\frac{\partial u_i}{\partial x_j} \in \mathbb{R}` is the partial derivative of displacement i with respect to coordinate j
    
   

    For 3D:

    .. math::

        B \in \mathbb{R}^{6 \times (3\times 3)} = \begin{bmatrix}
            \frac{\partial u_1}{\partial x_1} & 0 & 0 & \mid & \frac{\partial u_2}{\partial x_1} & 0 & 0 & \mid & \frac{\partial u_3}{\partial x_1} & 0 & 0 \\
            0 & \frac{\partial u_1}{\partial x_2} & 0 & \mid & 0 & \frac{\partial u_2}{\partial x_2} & 0 & \mid & 0 & \frac{\partial u_3}{\partial x_2} & 0 \\
            0 & 0 & \frac{\partial u_1}{\partial x_3} & \mid & 0 & 0 & \frac{\partial u_2}{\partial x_3} & \mid & 0 & 0 & \frac{\partial u_3}{\partial x_3} \\
            0 & \frac{\partial u_1}{\partial x_3} & \frac{\partial u_1}{\partial x_2} & \mid & 0 & \frac{\partial u_2}{\partial x_3} & \frac{\partial u_2}{\partial x_2} & \mid & 0 & \frac{\partial u_3}{\partial x_3} & \frac{\partial u_3}{\partial x_2} \\
            \frac{\partial u_1}{\partial x_3} & 0 & \frac{\partial u_1}{\partial x_1} & \mid & \frac{\partial u_2}{\partial x_3} & 0 & \frac{\partial u_2}{\partial x_1} & \mid & \frac{\partial u_3}{\partial x_3} & 0 & \frac{\partial u_3}{\partial x_1} \\
            \frac{\partial u_1}{\partial x_2} & \frac{\partial u_1}{\partial x_1} & 0 & \mid & \frac{\partial u_2}{\partial x_2} & \frac{\partial u_2}{\partial x_1} & 0 & \mid & \frac{\partial u_3}{\partial x_2} & \frac{\partial u_3}{\partial x_1} & 0
        \end{bmatrix}
    
    representing [:math:`\varepsilon_{xx}, \varepsilon_{yy}, \varepsilon_{zz}, \gamma_{yz}, \gamma_{xz}, \gamma_{xy}`]
    
    where :math:`\varepsilon` denotes normal strain and :math:`\gamma` denotes shear strain components

    where:
    
    - :math:`u_i \in \mathbb{R}` is the displacement component in direction i
    - :math:`x_i \in \mathbb{R}` is the spatial coordinate in direction i
    - :math:`\frac{\partial u_i}{\partial x_j} \in \mathbb{R}` is the partial derivative of displacement i with respect to coordinate j

    Parameters
    ----------
    gradu: torch.Tensor
        1D Tensor of shape [d], where dim must be 2 or 3
        gradient of displacement

    Returns
    -------
    torch.Tensor
        2D Tensor with shape [3, 2] if d=2 or [6, 3] if d=3,
    """

    assert gradu.dim() == 1, f"gradu should be a 1D tensor of shape [dim], but got shape {gradu.shape}"
    dim = gradu.shape[-1]
    assert dim in (2, 3),f"dimension is only supported for 2, 3 for voigt shape grad, but got {dim}"

    a = gradu.diag()
    b = skew(gradu, sign=False, at_least2d=True)
    B = torch.cat([a, b], 0)

    return B 

def voigt_stiffness(E:Union[float,torch.Tensor],
            nu:Union[float,torch.Tensor],
            dim:int = 2)->torch.Tensor:
    r"""

    For 2D:

    .. math::

        \mathbb{C} \in \mathbb{R}^{3 \times 3} = \begin{bmatrix}
            \lambda + 2\mu & \lambda & 0 \\
            \lambda & \lambda + 2\mu & 0 \\
            0 & 0 & \mu
        \end{bmatrix}

    representing [:math:`\varepsilon_{xx}, \varepsilon_{yy}, \gamma_{xy}`]

    For 3D:

    .. math::

        \mathbb{C} \in \mathbb{R}^{6 \times 6} = \begin{bmatrix}
            \lambda + 2\mu & \lambda & \lambda & 0 & 0 & 0 \\
            \lambda & \lambda + 2\mu & \lambda & 0 & 0 & 0 \\
            \lambda & \lambda & \lambda + 2\mu & 0 & 0 & 0 \\
            0 & 0 & 0 & \mu & 0 & 0 \\
            0 & 0 & 0 & 0 & \mu & 0 \\
            0 & 0 & 0 & 0 & 0 & \mu
        \end{bmatrix}

    representing [:math:`\varepsilon_{xx}, \varepsilon_{yy}, \varepsilon_{zz}, \gamma_{yz}, \gamma_{xz}, \gamma_{xy}`]

    where:

    - :math:`\lambda \in \mathbb{R} = \frac{E\nu}{(1+\nu)(1-2\nu)}`
    - :math:`\mu \in \mathbb{R} = \frac{E}{2(1+\nu)}`
    
    

    Parameters
    ----------
    E: Union[float,torch.Tensor]
        if torch.Tensor, 0D Tensor
        Young's modulus

    nu: float
        if torch.Tensor, 0D Tensor
        Poisson's ratio

    dim: int 
        Spatial dimension of the problem (2 or 3).
        For 2D problems use dim=2, for 3D problems use dim=3.
        Default is 2.

    Returns
    -------
    torch.Tensor
        2D Tensor of shape :math:`[d(d+1)/2, d(d+1)/2]`, where :math:`d` is the spatial dimension

    """
    # assertion
    assert dim in (2, 3)

    mu = E/(2.*(1. + nu))
    _lambda = E*nu/((1+nu)*(1-2*nu))

    if not isinstance(mu, torch.Tensor):
        mu = torch.tensor(mu)
    if not isinstance(_lambda, torch.Tensor):
        _lambda = torch.tensor(_lambda)

    if dim == 2:
        C = mu.repeat(3).diag()
        C[:2, :2] = _lambda + C[:2, :2]
        C[:2, :2] = mu.repeat(2).diag() + C[:2, :2]
    elif dim == 3:
        C = mu.repeat(6).diag()
        C[:3, :3] = _lambda + C[:3, :3]
        C[:3, :3] = mu.repeat(3).diag() + C[:3, :3]
    else:
        raise Exception(f"dim must be 2 or 3, but got {dim}")
    
    return C
    
def voigt_shape_val(u:torch.Tensor, dim:int)->torch.Tensor:
    r"""

    Convert shape functions to Voigt notation matrix for strain-displacement relations.
    
    For 2D:

    .. math::

        N_1, N_2, N_3 \in \mathbb{R} \quad \text{(shape values)} \\
        N \in \mathbb{R}^{2 \times (2\times 3)}= \begin{bmatrix} 
        N_1 & 0 &\mid& N_2 & 0 &\mid& N_3 & 0 \\
        0 & N_1 &\mid& 0 & N_2 &\mid& 0 & N_3
        \end{bmatrix}

    For 3D:

    .. math::

        N_1, N_2, N_3 \in \mathbb{R} \quad \text{(shape values)} \\
        N \in \mathbb{R}^{3 \times (3\times 3)}= \begin{bmatrix}
        N_1 & 0 & 0 &\mid& N_2 & 0 & 0 &\mid& N_3 & 0 & 0 \\
        0 & N_1 & 0 &\mid& 0 & N_2 & 0 &\mid& 0 & N_3 & 0 \\
        0 & 0 & N_1 &\mid& 0 & 0 & N_2 &\mid& 0 & 0 & N_3
        \end{bmatrix}
        
    Parameters
    ----------
    u: torch.Tensor
        0D Tensor of shape [],
        shape value
    dim: int 
        Spatial dimension. Must be 2 or 3.
    Returns
    -------
    torch.Tensor
        2D Tensor of shape [d, d], where :math:`d\in \{2,3\}`
    
    """
    assert dim in (2, 3),f"dimension is only supported for 2, 3 for voigt shape val, but got {dim}"

    return u.repeat(dim).diag()

