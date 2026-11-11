import numpy as np
import torch
import matplotlib.pyplot as plt
from matplotlib import patches
from matplotlib.collections import PatchCollection, LineCollection
from matplotlib.patches import Arc
from mpl_toolkits.mplot3d.art3d import Line3DCollection

from .. import element as E

def draw_mesh(mesh, draw_basis:bool= True, edgecolor="blue", linewidth=3, alpha=0.3, ax=None):
    r"""
    Parameters
    ----------
    mesh: tensormesh.Mesh
        the mesh
    draw_basis:bool
        whether to draw basis
    edgecolor: str, optional
        the color of the edge, default is "blue"
    linewidth: float, optional
        the width of the edge, default is 3
    alpha: float, optional
        the transparency of the edge, default is 0.3
    ax: matplotlib.axes.Axes, optional
        the axis, default is None

    Returns
    -------
    ax: matplotlib.axes.Axes
        the axis
    """
    pos = mesh.points.cpu().numpy()

    if ax is None:
        if mesh.dim < 3:
            fig, ax = plt.subplots()
            ax.set_aspect('equal')
        else:
            fig = plt.figure()
            ax = fig.add_subplot(111, projection='3d')
            ax.set_box_aspect([1,1,1])
    else:
        if mesh.dim == 3 and ax.name != "3d":
            # Get current figure and position
            fig = ax.figure
            position = ax.get_position()
            
            # Remove old 2D axis
            ax.remove()
            
            # Create new 3D axis in same position
            ax = fig.add_axes(position, projection='3d')
            ax.set_box_aspect([1,1,1])
    
    for element_type, elements in mesh.elements(mesh.dim).items():

        Element:E.Element = E.element_type2element(element_type)
        order:int         = E.element_type2order[element_type]
        edges:torch.Tensor= Element.element_to_edge(elements, order) # [N, 2]
        edges:np.ndarray  = edges.cpu().numpy()
        edges             = pos[edges]

        # Create line segments collection
        if mesh.dim < 3:
            lines = LineCollection(edges,
                                 colors=edgecolor,
                                 linewidths=linewidth,
                                 alpha=alpha)
        else:
            lines = Line3DCollection(edges,
                                   colors=edgecolor,
                                   linewidths=linewidth,
                                   alpha=alpha)
        ax.add_collection(lines)

        if draw_basis:
            # Draw basis points
            if mesh.dim < 3:
                ax.scatter(pos[:,0], pos[:,1], 
                          c='orange', s=20, alpha=0.5)
            else:
                ax.scatter(pos[:,0], pos[:,1], pos[:,2],
                          c='orange', s=20, alpha=0.5)


    return ax
