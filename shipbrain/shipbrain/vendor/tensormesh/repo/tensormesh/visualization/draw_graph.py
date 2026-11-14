import torch
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.collections import PatchCollection, LineCollection
from matplotlib.patches import Polygon, Arc
from matplotlib import patches
from typing import Optional, Union
from mpl_toolkits.mplot3d.art3d import Line3DCollection
from mpl_toolkits.mplot3d import Axes3D  # Add this import
from ..sparse import SparseMatrix
from .utils import ScipySparseMatrix, as_ndarray, as_sparse_matrix, dim

def draw_graph(sparse_matrix:Union[SparseMatrix,ScipySparseMatrix],
                  points:Union[torch.Tensor,np.ndarray], 
                  draw_points:bool = True, 
                  point_color:str  = 'orange',
                  color:str = "blue",
                  linewidth:int = 3,
                  alpha:float = 0.5,
                  ax:Optional[Union[plt.Axes, Axes3D]] = None
                  )->Union[plt.Axes, Axes3D]:
    """
    Parameters
    ----------
    sparse_matrix: Union[tensormesh.sparse.SparseMatrix, ScipySparseMatrix]
        the sparse matrix
    points: Union[torch.Tensor, np.ndarray]
        2D tensor of shape [n_points, 2]
        the points of the mesh
    color: str, optional
        the color of the edge, default is "blue"
    linewidth: int, optional
        the width of the edge, default is 3
    ax: matplotlib.axes.Axes, optional
        the axis, default is None

    Returns
    -------
    ax: matplotlib.axes.Axes
        the axis
    """

    # assertion
    assert dim(points) == 2, f"points.dim() must be 2, but got {dim(points)}"
    n_points = points.shape[0]
    assert sparse_matrix.shape == (n_points, n_points), f"sparse_matrix.shape must be ({n_points}, {n_points}), but got {sparse_matrix.shape}"

    # input prepare
    points_np     = as_ndarray(points)
    sparse_matrix = as_sparse_matrix(sparse_matrix)

    if ax is None:
        if points_np.shape[1] < 3:
            fig, ax = plt.subplots(figsize=(10,10))
            ax.set_aspect('equal')
        else:
            fig = plt.figure(figsize=(10,10))
            ax = fig.add_subplot(111, projection='3d')
            ax.set_box_aspect([1,1,1])
    else:
        if points_np.shape[1] >= 3 and ax.name != "3d":
            # Get current figure and position
            fig = ax.figure
            pos = ax.get_position()
            
            # Remove old 2D axis
            ax.remove()
            
            # Create new 3D axis in same position
            ax = fig.add_axes(pos, projection='3d')
            ax.set_box_aspect([1,1,1])
        elif points_np.shape[1] < 3 and ax.name == "3d":
            # Get current figure and position
            fig = ax.figure
            pos = ax.get_position()
            
            # Remove old 3D axis
            ax.remove()
            
            # Create new 2D axis in same position
            ax = fig.add_axes(pos)
            ax.set_aspect('equal')

    where_self_loop = sparse_matrix.row == sparse_matrix.col
    edges           = sparse_matrix.edges[:, ~where_self_loop]
    self_loops      = sparse_matrix.edges[:, where_self_loop]
    edges_np        = edges.detach().cpu().numpy()
    self_loops_np   = self_loops.detach().cpu().numpy()
    if points_np.shape[1] == 2:
        # 2D case
        lines = LineCollection(points_np[edges_np.T], color=color, linewidth=linewidth, alpha=alpha)
        arcs = []
        for loop in self_loops_np.T:
            i = loop[0]
            arcs.append(Arc(xy=(points_np[i][0], points_np[i][1]),
                          width=0.01,
                          height=0.01,
                          angle=0,
                          theta1=0,
                          theta2=360,
                          color=color,
                          alpha = alpha,
                          linewidth=linewidth))
        arcs = PatchCollection(arcs, match_original=True)
    else:
        # 3D case
        lines = Line3DCollection(points_np[edges_np.T], color=color, linewidth=linewidth, alpha=alpha)
        arcs = []
        for loop in self_loops_np.T:
           
            loop = loop[0]
           
            # Create 3D self-loop using a parametric curve
            t = np.linspace(0, 2*np.pi, 50)
            radius = 0.01  # Size of the loop
            
            # Create a random direction for the loop orientation
            random_dir = np.random.randn(3)
            random_dir = random_dir / np.linalg.norm(random_dir)
            
            # Create two perpendicular vectors to form a plane
            v1 = np.array([1, 0, 0]) if not np.allclose(random_dir, [1, 0, 0]) else np.array([0, 1, 0])
            perpendicular1 = v1 - (np.dot(v1, random_dir) * random_dir)
            perpendicular1 = perpendicular1 / np.linalg.norm(perpendicular1)
            perpendicular2 = np.cross(random_dir, perpendicular1)
            
            # Create the 3D loop using a parametric equation
            center_offset = random_dir * radius * 0.5
            loop_points = (points_np[loop] + center_offset + 
                         radius * (np.cos(t)[:, np.newaxis] * perpendicular1 + 
                                 np.sin(t)[:, np.newaxis] * perpendicular2))
            
            arcs.append(loop_points)
        arcs = Line3DCollection(arcs, color=color, linewidth=linewidth, alpha=alpha)

    ax.add_collection(lines)
    ax.add_collection(arcs)

    if draw_points:
        if points_np.shape[1] == 2:
            ax.scatter(points_np[:, 0], points_np[:, 1], c=point_color)
        else:
            ax.scatter(points_np[:, 0], points_np[:, 1], points_np[:, 2], c=point_color)

    return ax

# def draw_graph(sparse_matrix, points, ax=None):
    r"""
    Parameters
    ----------
    sparse_matrix: tensormesh.sparse.SparseTensor
        the sparse matrix
    points: torch.Tensor
        2D tensor of shape :math:`[|\mathcal V|, 2]`, where  :math:`|\mathcal V|` is the number of vertices

    Returns
    -------
    ax: matplotlib.axes.Axes
        the axis
    """
    if ax is None:
        fig, ax = plt.subplots(figsize=(10,10))

    if isinstance(points, torch.Tensor):
        points = points.numpy()
    pos = points.numpy()
    row, col = sparse_matrix.row, sparse_matrix.col
    if isinstance(row, torch.Tensor):
        row, col = row.numpy(), col.numpy()
    fig, ax = plt.subplots(figsize=(10,10))
    lines = []
    selfloops = []
    diameter = 0.02
    for (u, v) in zip(row, col):
        if u == v:
            selfloops.append(Arc((pos[u,0],pos[u,1]+diameter/2), diameter, diameter, 0, 0, 360, color="black", linewidth=0.5))
        else:
            line = (pos[u], pos[v])
            lines.append(line)
    lc = LineCollection(lines, color="black", linewidth=0.5)
    loops = PatchCollection(selfloops, match_original=True)
    ax.add_collection(lc)
    ax.add_collection(loops)

    return ax