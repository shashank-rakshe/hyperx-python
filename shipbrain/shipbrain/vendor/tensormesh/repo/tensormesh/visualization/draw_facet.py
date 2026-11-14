from typing import Union,Dict
import numpy as np
from pyparsing import line
import torch
import matplotlib.pyplot as plt
from matplotlib import patches
from matplotlib.collections import PatchCollection, LineCollection
import matplotlib.colors as mcolors

from .utils import dim, as_ndarray, as_tensor
from ..element import   element_type2order,\
                        element_type2dimension,\
                        element_type2element
def draw_facet_2d(
            points:torch.Tensor|np.ndarray,
            elements:Dict[str,torch.Tensor|np.ndarray],
            draw_basis:bool=False,
            point_color:str='orange',
            color:str = "blue",
            alpha:float = 0.5,
            linewidth:int = 1,
            ax:Union[plt.Axes,None] = None):
    """
    Parameters
    ----------
    points: torch.Tensor|np.ndarray
        2D tensor of shape [n_points, 2]
        the points of the mesh
    elements: Dict[str,torch.Tensor|np.ndarray]
        the elements of the mesh [n_element, n_basis]
    color: str, optional
        the color of the facet, default is "blue"
    alpha: float, optional
        the transparency of the facet, default is 0.5
    linewidth: int, optional
        the linewidth of the facet, default is 3
    ax: matplotlib.axes.Axes, optional
        the axis, default is None

    Returns
    -------
    ax: matplotlib.axes.Axes
        the axis
    """
    # assertion
    assert dim(points) == 2, f"points.dim() must be 2, but got {dim(points)}"
    assert points.shape[1] == 2, f"points.shape[1] must be 2, but got {points.shape[1]}"
    for k, v in elements.items():
        assert dim(v) == 2, f"elements[{k}].dim() must be 2, but got {dim(v)}"
        assert element_type2dimension[k] == 2, f"element_type2dimension[k] must be 2, but got {element_type2dimension[k]}"

    # input prepare
    points_np = as_ndarray(points)
    ax        = plt.subplots(figsize=(10,10))[1] if ax is None else ax

    edge_index = []
    for k, v in elements.items():
        v       = as_tensor(v)
        element = element_type2element(k)
        order   = element_type2order[k]
        facet   = element.get_facet(order) # [n_facet, n_basis]
        facet   = v[:,facet] # [n_element, n_facet, n_basis]
        facet   = facet.reshape(-1, facet.shape[-1]) # [n_element * n_facet, n_basis]
        if order == 1: # 0 - 1
            _edge_index = facet
        elif order > 1: # for line element, 0 - 2 - 3 - 1
            _edge_index = torch.cat([facet[:, :1], facet[:, -1:], facet[:,1:-1]], 0)
            _edge_index = torch.cat([_edge_index[:, :-1], _edge_index[:, 1:]], 0)
        else:
            raise NotImplementedError()
       
        edge_index.append(_edge_index)

    edge_index = torch.cat(edge_index, 0) # [n_edge, 2]
    edge_index = edge_index.sort(-1).values 
    edge_index = torch.unique(edge_index, dim=0) # [n_edge, 2]
    edge_index_np = as_ndarray(edge_index)
    lines_pos  = points_np[edge_index_np] # [n_edge, 2, 2]
    lines      = LineCollection(lines_pos, color=color, linewidth=linewidth, alpha=alpha) # type:ignore
    ax.add_collection(lines)

    if draw_basis:
        ax.scatter(points_np[:,0], points_np[:,1], c=point_color)

    return ax
       


def draw_face(mesh, color="blue",
                linewidth=3,
                ax=None):
    r"""
    Parameters
    ----------
    mesh: tensormesh.Mesh
        the mesh
    
    ax: matplotlib.axes.Axes, optional
        the axis, default is None

    Returns
    -------
    ax: matplotlib.axes.Axes
        the axis
    """
    assert mesh.points.shape[-1] == 2, f"Currently, only 2D mesh is supported"

    lines = mesh.element('line').cpu().numpy()

    line_pos = mesh.points[lines]

    if ax is None:
        fig, ax = plt.subplots(figsize=(10,10))

    lines = LineCollection(line_pos, color=color, linewidth=linewidth)
    ax.add_collection(lines)

    return ax