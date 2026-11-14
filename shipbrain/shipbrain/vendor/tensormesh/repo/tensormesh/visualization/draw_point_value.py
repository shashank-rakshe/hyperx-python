from typing import Optional, Union,Dict
import numpy as np
import torch
import matplotlib as mpl
import matplotlib.pyplot as plt
from matplotlib import patches
from matplotlib.collections import PatchCollection, \
                                    LineCollection, \
                                    PolyCollection, \
                                    PathCollection, \
                                    TriMesh
from matplotlib.image import AxesImage
from matplotlib import tri
from matplotlib.axes import Axes
from scipy.interpolate import griddata
from mpl_toolkits.mplot3d.axes3d import Axes3D
from mpl_toolkits.mplot3d.art3d import Path3DCollection
from typing import List, Union, Tuple
from .utils import as_ndarray, as_tensor, dim
from ..element import element_type2order,\
                      element_type2dimension,\
                      element_type2element,\
                      Triangle

##########
# 2d case
##########
def draw_point_value_2d_tri_gouraud(points:Union[torch.Tensor,np.ndarray],
                              point_values:Union[torch.Tensor,np.ndarray],
                              elements:Union[torch.Tensor,np.ndarray],
                              cmap:str = 'jet',
                              ax:Optional[plt.Axes] = None
                              )->Tuple[TriMesh, Axes]:
    """
    Parameters
    ----------
    points: Union[torch.Tensor,np.ndarray]
        2D tensor of shape [n_points, 2]
        the points of the mesh
    point_values: Union[torch.Tensor,np.ndarray]
        1D tensor of shape [n_points]
        the value of the points
    elements: Union[torch.Tensor,np.ndarray]
        2D tensor of shape [n_elements, 3]
        the elements of the mesh
    cmap: str, optional
        the colormap, default is 'jet'
    ax: matplotlib.axes.Axes, optional
        the axis, default is None

    Returns
    -------
    img: matplotlib.collections.PathCollection
    ax: matplotlib.axes.Axes
    """
    # assertion
    assert dim(points) == 2, f"points.dim() must be 2, but got {dim(points)}"
    assert points.shape[1] == 2, f"points.shape[1] must be 2, but got {points.shape[1]}"
    assert dim(point_values) == 1, f"point_values.dim() must be 1, but got {dim(point_values)}"
    assert dim(elements) ==2, f"elements.dim() must be 2, but got {dim(elements)}"
    assert elements.shape[1] == 3, f"elements.shape[1] must be 3, but got {elements.shape[1]}"
    assert point_values.shape[0] == points.shape[0], f"point_values.shape[0] must be equal to points.shape[0], but got {point_values.shape[0]} and {points.shape[0]}"
    assert elements.max() < points.shape[0], f"elements.max() must be less than points.shape[0], but got {elements.max()} and {points.shape[0]}"
    
    # input prepare
    points_np       = as_ndarray(points)
    point_values_np = as_ndarray(point_values)
    elements_np     = as_ndarray(elements)
    cmap = mpl.colormaps[cmap]
    ax   = plt.subplots(figsize=(10,10))[1] if ax is None else ax
    # draw elements

    triangulation = tri.Triangulation(points_np[:,0], points_np[:,1], elements_np)
    img = ax.tripcolor(triangulation, point_values_np,
                 cmap=cmap, shading='gouraud')
    
    return img, ax

def update_point_value_2d_tri_gouraud(img:TriMesh,
                                        point_values:Union[torch.Tensor,np.ndarray]):
    """
    Parameters
    ----------
    img: matplotlib.collections.PolyCollection
        the image
    point_values: Union[torch.Tensor,np.ndarray]
        the point values, 1D tensor of shape [n_points]
    """
    # assertion
    assert isinstance(img, TriMesh), f"img must be an instance of matplotlib.collections.PolyCollection, but got {type(img)}"
    assert dim(point_values) == 1, f"point_values.dim() must be 1, but got {dim(point_values)}"

    point_values_np = as_ndarray(point_values)
    img.set_array(point_values_np)

def draw_point_value_2d_interpolation( points:Union[torch.Tensor,np.ndarray],
                                    point_values:Union[torch.Tensor,np.ndarray],
                                    density:int = 100,
                                    cmap:str = 'jet',
                                    use_scatter:bool = False,
                                    ax:Optional[plt.Axes] = None
                                    )->Tuple[Union[PathCollection,AxesImage], Axes]:
    """
    Parameters:
    -----------
    points: Union[torch.Tensor,np.ndarray]
        2D tensor of shape [n_points, 2]
        the points of the mesh
    point_values: Union[torch.Tensor,np.ndarray]
        1D tensor of shape [n_points]
        the value of the points
    density: int
        the density of the interpolation
        default is 100
    cmap: str
        the colormap
        default is 'jet'
    ax: Optional[matplotlib.axes.Axes]
        the axis
        default is None

    Returns
    -------
    img: matplotlib.collections.PathCollection
    ax: matplotlib.axes.Axes
    """
    # assertion
    assert dim(points) == 2, f"points.dim() must be 2, but got {dim(points)}"
    assert points.shape[1] == 2, f"points.shape[1] must be 2, but got {points.shape[1]}"
    assert dim(point_values) == 1, f"point_values.dim() must be 1, but got {dim(point_values)}"
    assert point_values.shape[0] == points.shape[0], f"point_values.shape[0] must be equal to points.shape[0], but got {point_values.shape[0]} and {points.shape[0]}"
    assert density > 0, f"density must be greater than 0, but got {density}"

    # input prepare
    points_np = as_ndarray(points)
    point_values_np = as_ndarray(point_values)
    cmap = mpl.colormaps[cmap]
    ax   = plt.subplots(figsize=(10,10))[1] if ax is None else ax
    xmin, xmax = points_np[:,0].min(), points_np[:,0].max()
    ymin, ymax = points_np[:,1].min(), points_np[:,1].max()
    grid_x, grid_y = np.mgrid[xmin:xmax:density*1j, ymin:ymax:density*1j]
    grid_z = griddata(points_np, point_values_np, (grid_x, grid_y), method='cubic')

    # draw elements
    if use_scatter:
        img = ax.scatter(grid_x.flatten(), grid_y.flatten(), c=grid_z.flatten(), cmap=cmap)
    else:
        img = ax.imshow(grid_z.T, extent=(xmin, xmax, ymin, ymax), origin='lower', cmap=cmap, aspect='auto')
    
    return img, ax

def update_point_value_2d_interpolation(img:Union[PathCollection,AxesImage],
                                        points:Union[torch.Tensor,np.ndarray],
                                        point_values:Union[torch.Tensor,np.ndarray]):
    """
    Parameters
    ----------
    img: Union[PathCollection,AxesImage]
        the image
    points:Union[torch.Tensor,np.ndarray]
        the points, 2D tensor of shape [n_points, 2]
    point_values: Union[torch.Tensor,np.ndarray]
        the point values, 1D tensor of shape [n_points]
    """
    # assertion
    assert dim(point_values) == 1, f"point_values.dim() must be 1, but got {dim(point_values)}"
    assert point_values.shape[0] == points.shape[0], f"point_values.shape[0] must be equal to points.shape[0], but got {point_values.shape[0]} and {points.shape[0]}"
    assert dim(points) == 2, f"points.dim() must be 2, but got {dim(points)}"
    assert points.shape[1] == 2, f"points.shape[1] must be 2, but got {points.shape[1]}"

    points_np       = as_ndarray(points)
    point_values_np = as_ndarray(point_values)

    if isinstance(img, PathCollection):
        # scatter 
        grid_x, grid_y = img.get_offsets().T
        grid_z = griddata(points_np, point_values_np, (grid_x, grid_y), method='cubic')
        img.set_array(grid_z)
     
    elif isinstance(img, AxesImage):
        # imgshow
        image_data = img.get_array()
        height, width  = image_data.shape
        extend     = img.get_extent()
        xmin, xmax, ymin, ymax = extend
        grid_x, grid_y = np.mgrid[xmin:xmax:width*1j, ymin:ymax:height*1j]
        grid_z = griddata(points_np, point_values_np, (grid_x, grid_y), method='cubic')
        img.set_data(grid_z.T)
    else:
        raise NotImplementedError(f"img type {type(img)} is not supported")

def draw_point_value_2d(points:Union[torch.Tensor,np.ndarray],
                        point_values:Union[torch.Tensor,np.ndarray],
                        elements:Dict[str,Union[torch.Tensor,np.ndarray]],
                        density:int           = 100,
                        cmap:str              = 'jet',
                        use_scatter:bool      = False,
                        ax:Optional[plt.Axes] = None):
    """Draw nodal values on a 2D mesh.

    For first-order triangles uses Gouraud shading; otherwise uses 2D
    interpolation.

    Parameters
    ----------
    points: Union[torch.Tensor,np.ndarray]
        2D tensor of shape [n_points, 2]
        the points of the mesh
    point_values: Union[torch.Tensor,np.ndarray]
        1D tensor of shape [n_points]
        the value of the points
    elements: Dict[str,Union[torch.Tensor,np.ndarray]]
        2D tensor of shape [n_elements, n_basis]
        the elements of the mesh
    density: int
        the density of the interpolation
        default is 100
    cmap: str
        the colormap
        default is 'jet'
    use_scatter: bool
    ax: Optional[matplotlib.axes.Axes]
        the axis
        default is None

    Returns
    -------
    img: matplotlib.collections.PathCollection
    ax: matplotlib.axes.Axes
        the axis
    """
    # assertion
    for key in elements.keys():
        assert element_type2dimension[key] == 2, f"element_type2dimension[{key}] must be 2, but got {element_type2dimension[key]}"
        assert dim(elements[key]) == 2, f"elements[{key}].dim() must be 2, but got {dim(elements[key])}"
    assert dim(points) == 2, f"points.dim() must be 2, but got {dim(points)}"
    assert points.shape[1] == 2, f"points.shape[1] must be 2, but got {points.shape[1]}"
    assert dim(point_values) == 1, f"point_values.dim() must be 1, but got {dim(point_values)}"
    assert point_values.shape[0] == points.shape[0], f"point_values.shape[0] must be equal to points.shape[0], but got {point_values.shape[0]} and {points.shape[0]}"
    assert density > 0, f"density must be greater than 0, but got {density}"
    
    for k, ele in elements.items():
        element = element_type2element(k)
        order   = element_type2order[k]
     
        if order == 1 and issubclass(element, Triangle):
            img, _ = draw_point_value_2d_tri_gouraud(points, point_values, ele, cmap, ax=ax)
        else:
            img, _ = draw_point_value_2d_interpolation(points, point_values, density, cmap, use_scatter, ax=ax)
    
    return img, ax

def update_point_value_2d(img:Union[PathCollection,PolyCollection,AxesImage],
                          points:Union[torch.Tensor,np.ndarray],
                          point_values:Union[torch.Tensor,np.ndarray]):
    """
    Parameters
    ----------
    img: matplotlib.collections.PathCollection
        the image
    points:Union[torch.Tensor,np.ndarray]
        the points, 2D tensor of shape [n_points, 2]
    point_values: Union[torch.Tensor,np.ndarray]
        the point values, 1D tensor of shape [n_points]
    """
    # assertion
    assert dim(point_values) == 1, f"point_values.dim() must be 1, but got {dim(point_values)}"
    assert point_values.shape[0] == points.shape[0], f"point_values.shape[0] must be equal to points.shape[0], but got {point_values.shape[0]} and {points.shape[0]}"
    assert dim(points) == 2, f"points.dim() must be 2, but got {dim(points)}"
    assert points.shape[1] == 2, f"points.shape[1] must be 2, but got {points.shape[1]}"

    if isinstance(img, (PathCollection, AxesImage)):
        # scatter 
        update_point_value_2d_interpolation(img, points, point_values)
    elif isinstance(img, (PolyCollection,TriMesh)):

        update_point_value_2d_tri_gouraud(img, point_values)
    else:
        raise NotImplementedError(f"img type {type(img)} is not supported")

##########
# 3d case
##########

def draw_point_value_3d_interpolation(points: Union[torch.Tensor, np.ndarray],
                                    point_values: Union[torch.Tensor, np.ndarray],
                                    density: int = 25,
                                    cmap: str = 'jet',
                                    ax: Optional[Axes3D] = None
                                    ) -> tuple[Path3DCollection, Axes3D]:
    """
    Parameters
    ----------
    points: Union[torch.Tensor, np.ndarray]
        3D tensor of shape [n_points, 3]
        the points of the mesh
    point_values: Union[torch.Tensor, np.ndarray]
        1D tensor of shape [n_points]
        the value of the points
    density: int
        the density of the interpolation
        default is 50
    cmap: str
        the colormap
        default is 'jet'
    ax: Optional[matplotlib.axes.Axes]
        the axis, should be a 3D axis
        default is None

    Returns
    -------
    img: list[matplotlib.collections.PathCollection]
        list of scatter plots for each slice
    ax: matplotlib.axes.Axes
        the 3D axis
    """
    # assertion
    assert dim(points) == 2, f"points.dim() must be 2, but got {dim(points)}"
    assert points.shape[1] == 3, f"points.shape[1] must be 3, but got {points.shape[1]}"
    assert dim(point_values) == 1, f"point_values.dim() must be 1, but got {dim(point_values)}"
    assert point_values.shape[0] == points.shape[0], f"point_values.shape[0] must be equal to points.shape[0]"
    assert density > 0, f"density must be greater than 0, but got {density}"

    # input prepare
    points_np = as_ndarray(points)
    point_values_np = as_ndarray(point_values)
    cmap = mpl.colormaps[cmap]
    
    if ax is None:
        fig = plt.figure(figsize=(10, 10))
        ax = fig.add_subplot(111, projection='3d')
    elif ax.name != "3d":
        # Get current figure and position
        fig = ax.figure
        pos = ax.get_position()
        
        # Remove old 2D axis
        ax.remove()
        
        # Create new 3D axis in same position
        ax = fig.add_axes(pos, projection='3d')

    # Create grid for interpolation
    xmin, xmax = points_np[:,0].min(), points_np[:,0].max()
    ymin, ymax = points_np[:,1].min(), points_np[:,1].max()
    zmin, zmax = points_np[:,2].min(), points_np[:,2].max()
    
    # Create 3D grid
    grid_x, grid_y, grid_z = np.mgrid[xmin:xmax:density*1j, 
                                     ymin:ymax:density*1j,
                                     zmin:zmax:density*1j]
    grid_points = np.column_stack((grid_x.flatten(), 
                                 grid_y.flatten(),
                                 grid_z.flatten()))
    
    # Interpolate values
    grid_values = griddata(points_np, point_values_np, grid_points, method='linear')
    
    # Only plot points where interpolation succeeded
    mask = ~np.isnan(grid_values)
    scatter_plot = ax.scatter(grid_points[mask,0], grid_points[mask,1],
                              grid_points[mask,2], c=grid_values[mask],
                              cmap=cmap, alpha=0.1)

    ax.set_xlabel('X')
    ax.set_ylabel('Y')
    ax.set_zlabel('Z')
    
    return scatter_plot, ax

def update_point_value_3d_interpolation(img: Path3DCollection,
                                      points: Union[torch.Tensor, np.ndarray],
                                      point_values: Union[torch.Tensor, np.ndarray]):
    """
    Parameters
    ----------
    scatter_plots: list[matplotlib.collections.PathCollection]
        list of scatter plots returned by draw_point_value_3d_interpolation
    points: Union[torch.Tensor, np.ndarray]
        the points, 3D tensor of shape [n_points, 3]
    point_values: Union[torch.Tensor, np.ndarray]
        the point values, 1D tensor of shape [n_points]
    """
    # assertion
    assert dim(points) == 2, f"points.dim() must be 2, but got {dim(points)}"
    assert points.shape[1] == 3, f"points.shape[1] must be 3, but got {points.shape[1]}"
    assert dim(point_values) == 1, f"point_values.dim() must be 1, but got {dim(point_values)}"
    assert point_values.shape[0] == points.shape[0], f"point_values.shape[0] must be equal to points.shape[0]"

    points_np = as_ndarray(points)
    point_values_np = as_ndarray(point_values)
    # Get the positions of the 3D scatter points
    pos = np.column_stack(img._offsets3d)
    
    # Interpolate new values at scatter point positions
    new_values = griddata(points_np, point_values_np, pos, method='linear')
    
    # Update the colors of the scatter plot
    img.set_array(new_values)


def draw_point_value(mesh,
                    point_values: Union[torch.Tensor, np.ndarray],
                    density: int = 25,
                    cmap: str = 'jet',
                    use_scatter: bool = False,
                    ax: Optional[Union[Axes,Axes3D]] = None
                    )->Tuple[Union[TriMesh, AxesImage, PathCollection, Path3DCollection], Union[Axes, Axes3D]]:
    """
    Parameters
    ----------
    points: Union[torch.Tensor, np.ndarray]
        tensor of shape [n_points, dim]
        the points of the mesh
    point_values: Union[torch.Tensor, np.ndarray]
        1D tensor of shape [n_points]
        the value of the points
    elements: Dict[str,Union[torch.Tensor, np.ndarray]]
        the elements of the mesh
    density: int
        the density of the interpolation
        default is 100
    cmap: str
        the colormap
        default is 'jet'
    use_scatter: bool
        whether to use scatter plot (2D only)
    ax: Optional[matplotlib.axes.Axes]
        the axis
        default is None

    Returns
    -------
    img: Union[matplotlib.collections.PathCollection, list[matplotlib.collections.PathCollection]]
    ax: matplotlib.axes.Axes
    """
    # Get dimension from first element type
    assert mesh.dim in [2,3], f"mesh.dim should be in `2` or `3` got {mesh.dim}"
    points = mesh.points
    elements = mesh.elements(mesh.dim)

    if mesh.dim == 2:
        if ax is None:
            fig, ax = plt.subplots(figsize=(10,10))
            ax.set_aspect('equal')
    elif mesh.dim == 3:
        if ax is None:
            fig = plt.figure(figsize=(10,10))
            ax = fig.add_subplot(111, projection='3d')
            ax.set_box_aspect([1,1,1])
        else:
            assert ax.name != "3d", "ax must be a 2D axes"

    if (isinstance(mesh.default_eletyp, str) 
        and element_type2order[mesh.default_eletyp] == 1 
        and issubclass(element_type2element(mesh.default_eletyp), Triangle)
        ):
    
        img, ax = draw_point_value_2d_tri_gouraud(points, point_values, mesh.elements(), cmap, ax=ax)
        # img : TriMesh

    elif mesh.dim == 2:

        img, ax = draw_point_value_2d_interpolation(points, point_values, density, cmap, use_scatter, ax=ax)
        # img : Union[PathCollection, AxesImage]

    elif mesh.dim == 3:

        img, ax = draw_point_value_3d_interpolation(points, point_values, density, cmap, ax=ax)
        # img : Path3DCollection

    else:
        raise NotImplementedError(f"Unsupported mesh type: dimension {mesh.dim} with element type {mesh.default_eletyp}")

    return img, ax


def update_point_value(mesh,
                        img: Union[TriMesh, AxesImage, PathCollection, Path3DCollection],
                      point_values: Union[torch.Tensor, np.ndarray]):
    """
    Parameters
    ----------
    img: Union[PathCollection, PolyCollection, AxesImage, list]
        the visualization object(s) to update
    points: Union[torch.Tensor, np.ndarray]
        the points
    point_values: Union[torch.Tensor, np.ndarray]
        the point values
    """
    points = mesh.points
    if isinstance(img, TriMesh):
        update_point_value_2d_tri_gouraud(img, point_values)
    elif isinstance(img, (AxesImage, PathCollection)):
        update_point_value_2d_interpolation(img, points, point_values)
    elif isinstance(img, Path3DCollection):
        update_point_value_3d_interpolation(img, points, point_values)
    else:
        raise NotImplementedError(f"img type {type(img)} is not supported")

