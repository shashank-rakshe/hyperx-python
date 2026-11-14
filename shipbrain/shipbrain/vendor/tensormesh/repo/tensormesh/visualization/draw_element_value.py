from optparse import Option
import torch 
import numpy as np 
import matplotlib.pyplot as plt
from typing import Optional, Dict, Tuple, List, Union
from matplotlib import tri
from matplotlib.patches import Polygon
from matplotlib.collections import PatchCollection, PolyCollection
from matplotlib.axes import Axes
from scipy.interpolate import griddata
from mpl_toolkits.mplot3d.axes3d import Axes3D
from mpl_toolkits.mplot3d.art3d import Path3DCollection

from ..element import element_type2dimension, element_type2element, element_type2order, Triangle
from .utils import as_ndarray, dim, grid


#####
# 2D
####
def draw_element_value_2d_tri(
                        points:Union[torch.Tensor,np.ndarray],
                        elements:Union[torch.Tensor,np.ndarray],
                        values:Union[torch.Tensor,np.ndarray],
                        alpha:Optional[Union[float,torch.Tensor,np.ndarray]]=None,
                        cmap:str='viridis',
                        color:Optional[str]=None,
                        ax:Optional[Axes]=None,
                    **kwargs)->Tuple[PolyCollection, Axes]:
    """
    Parameters:
    -----------
    points: torch.Tensor or np.ndarray
        [n_points, 2]
    elements: torch.Tensor or np.ndarray
        [n_elements, 3]
    values: torch.Tensor or np.ndarray
        [n_elements]
    alpha: float or torch.Tensor or np.ndarray
        [n_elements]
        should be greater or equal 0
    cmap: str
        colormap, default is 'viridis'
    color: str
        color, if alpha is torch.Tensor or np.ndarray, the color will be used 
        default is None
    ax: Axes
        default is None

    Returns:
    --------
    Axes
    """
    # assertion
    assert dim(points) == 2
    assert dim(elements) == 2
    assert dim(values) == 1
    assert elements.shape[1] == 3
    assert elements.shape[0] == values.shape[0]
    if isinstance(alpha, (torch.Tensor, np.ndarray)):
        assert alpha.shape[0] == values.shape[0]
        assert (alpha >= 0).all()

    # to numpy 
    points   = as_ndarray(points)
    elements = as_ndarray(elements)
    values   = as_ndarray(values)
    if isinstance(alpha, (torch.Tensor, np.ndarray)):
        alpha = as_ndarray(alpha)

    
    if ax is None:
        fig, ax = plt.subplots()

    # draw the triangles
    triangles = tri.Triangulation(points[:, 0], points[:, 1], elements)

    # Workaround for matplotlib tripcolor bug with tuple edgecolor
    if 'edgecolor' in kwargs:
        kwargs['edgecolors'] = kwargs.pop('edgecolor')
    
    # Avoid tripcolor crash when edgecolors is a tuple (bypass ec.lower() check)
    if 'edgecolors' in kwargs and 'antialiaseds' not in kwargs:
        kwargs['antialiaseds'] = True

    if color is None: # use cmap
        img = ax.tripcolor(triangles, values, cmap=cmap, alpha=alpha, **kwargs)
    else: # use color
        img = ax.tripcolor(triangles, values, color=color, alpha=alpha, **kwargs)

    return img, ax

def draw_element_value_2d( points:Union[torch.Tensor,np.ndarray],
                        elements:Dict[str,Union[torch.Tensor,np.ndarray]],
                        values:Dict[str,Union[torch.Tensor,np.ndarray]],
                        alpha:Union[float,Dict[str,Union[torch.Tensor,np.ndarray]]]=1.0,
                        cmap:str='viridis',
                        color:Optional[str]=None,
                        ax:Optional[Axes]=None,
                        **kwargs
                        )->Tuple[Dict[str,PolyCollection], Axes]:
    """
    Parameters
    ----------
    points: torch.Tensor or np.ndarray
        [n_points, 2]
    elements: Dict[str, torch.Tensor or np.ndarray]
        keys are 'tri' or 'quad'
        values are torch.Tensor or np.ndarray
        [n_elements, 3] or [n_elements, 4]
    values: Dict[str, torch.Tensor or np.ndarray]
        [n_elements]
    alpha: float or torch.Tensor or np.ndarray
        [n_elements]
        should be greater or equal 0 and less or equal than 1
    cmap: str
        colormap, default is 'viridis'
    color: str
        color, if alpha is torch.Tensor or np.ndarray, the color will be used 
        default is None
    ax: plt.Axes
        default is None

    Returns
    -------
    collections: Dict[str, matplotlib.collections.PolyCollection]
        Dictionary mapping element types to their polygon collections
    ax: matplotlib.axes.Axes
        The matplotlib axes object
    """
    # assertion
    assert dim(points) == 2
    assert isinstance(elements, dict)
    for key in elements.keys():
        assert element_type2dimension[key] == 2, f"element type {key} is not 2D"
        assert values[key].shape[0] == elements[key].shape[0], f"values for {key} is not equal to elements"
        if isinstance(alpha, dict):
            assert alpha[key].shape[0] == values[key].shape[0], f"alpha for {key} is not equal to values"
            assert (alpha[key] >= 0).all(), f"alpha for {key} should be greater or equal 0"
            assert (alpha[key] <= 1).all(), f"alpha for {key} should be less or equal 1"
    if isinstance(alpha, float):
        assert 0 <= alpha <= 1, f"alpha should be between 0 and 1"

    # to numpy
    points = as_ndarray(points)
    elements = {key:as_ndarray(elements[key]) for key in elements.keys()}
    values = {key:as_ndarray(values[key]) for key in values.keys()}
    if isinstance(alpha, dict):
        alpha = {key:as_ndarray(alpha[key]) for key in alpha.keys()}
    else:
        alpha = {key:alpha for key in elements.keys()}

    if ax is None:
        fig, ax = plt.subplots()

    # draw the elements
    collections = {}
    for key in elements.keys():
        element = element_type2element(key)
        order   = element_type2order[key]
      
        if element is Triangle:
            img, ax = draw_element_value_2d_tri(points, elements[key], values[key], alpha[key], cmap, color, ax, **kwargs)
            collections[key] = img
            continue

        contour = element.get_contour(order)
        contour = elements[key][:, contour] # [n_elements, n_contour]
        contour = points[contour] # [n_elements, n_contour, 2]

        # polygons= [Polygon(x,closed=True) for x in contour]
        collection = PolyCollection(contour, cmap=cmap, **kwargs)
        
        if color is None: # use cmap 
            collection.set_facecolor(plt.cm.get_cmap(cmap)(values[key]))
        else: # use alpha
            collection.set_alpha(alpha[key])
            collection.set_color(color)

        collections[key] = ax.add_collection(collection)

    return collections,  ax

def update_element_value_2d_tri(
                        img:PolyCollection,
                        values:Union[torch.Tensor,np.ndarray],
                        alpha:Optional[Union[float,torch.Tensor,np.ndarray]]=None,
                        )->PolyCollection:
    """Update face colors of a triangle ``PolyCollection``.

    Parameters
    ----------
    img : PolyCollection
        Collection returned by a draw helper.
    values : torch.Tensor or np.ndarray
        Per-element values, shape ``(n_elements,)``.
    alpha : float or torch.Tensor or np.ndarray, optional
        Per-element opacity, shape ``(n_elements,)``; must be
        non-negative when provided as an array.

    Returns
    -------
    PolyCollection
        The same collection with updated array data.
    """
    # assertion
    assert dim(values) == 1
    assert img.get_array().shape[0] == values.shape[0]
    if isinstance(alpha, (torch.Tensor, np.ndarray)):
        assert alpha.shape[0] == values.shape[0]
        assert (alpha >= 0).all()

    # to numpy 
    values = as_ndarray(values)
    if isinstance(alpha, (torch.Tensor, np.ndarray)):
        alpha = as_ndarray(alpha)

    img.set_array(values)
    if isinstance(alpha, (torch.Tensor, np.ndarray)):
        img.set_alpha(alpha)

    return img

def update_element_value_2d(
                        collections:Dict[str,PolyCollection],
                        values:Dict[str,Union[torch.Tensor,np.ndarray]],
                        alpha:Union[float,Dict[str,Union[torch.Tensor,np.ndarray]]]=1.0,
                        )->Dict[str,PolyCollection]:
    """
    Parameters
    ----------
    collections: Dict[str,PolyCollection]
    values: Dict[str, torch.Tensor or np.ndarray]
        [n_elements]
    alpha: float or torch.Tensor or np.ndarray
        [n_elements]
        should be greater or equal 0 and less or equal than 1
    """
    # assertion
    for key in collections.keys():
        assert dim(values[key]) == 1
        assert collections[key].get_array().shape[0] == values[key].shape[0]
        if isinstance(alpha, dict):
            assert alpha[key].shape[0] == values[key].shape[0]
            assert (alpha[key] >= 0).all()
            assert (alpha[key] <= 1).all()
    if isinstance(alpha, float):
        assert 0 <= alpha <= 1

    # to numpy
    values = {key:as_ndarray(values[key]) for key in values.keys()}
    if isinstance(alpha, dict):
        alpha = {key:as_ndarray(alpha[key]) for key in alpha.keys()}
    else:
        alpha = {key:alpha for key in values.keys()}

    for key in collections.keys():
        collections[key].set_alpha(alpha[key])
        collections[key].set_array(values[key])
    return collections


#####
# 3D
#####
def draw_element_value_3d( points:Union[torch.Tensor,np.ndarray],
                        elements:Dict[str,Union[torch.Tensor,np.ndarray]],
                        values:Dict[str,Union[torch.Tensor,np.ndarray]],
                        alpha:Union[float,Dict[str,Union[torch.Tensor,np.ndarray]]]=0.3,
                        cmap:str='viridis',
                        color:Optional[str]=None,
                        density:bool = 25,
                        ax:Optional[Axes3D]=None,
                        )->Tuple[Dict[str,Path3DCollection], Axes3D]:

    """
    Parameters
    ----------
    points: torch.Tensor or np.ndarray
        [n_points, 3]
    elements: Dict[str,torch.Tensor|np.ndarray]
        dictionary of elements for each element type
    values: Dict[str,torch.Tensor|np.ndarray]
        dictionary of values for each element type [n_elements]
    alpha: float or Dict[str,torch.Tensor|np.ndarray]
        transparency value(s), default is 1.0
    cmap: str
        colormap, default is 'viridis'
    color: Optional[str]
        if specified, use this color instead of colormap
    ax: Optional[plt.Axes]
        matplotlib 3D axes, default is None

    Returns
    -------
    collections: Dict[str,Path3DCollection]
        dictionary of scatter collections for each element type
    ax: Axes3D
        the matplotlib 3D axes
    """
    # Create 3D axes if not provided
    if ax is None:
        fig = plt.figure(figsize=(10,10))
        ax = fig.add_subplot(111, projection='3d')
        ax.set_box_aspect([1,1,1])
    else:
        # Get current figure and position
        fig = ax.figure
        position = ax.get_position()
        
        # Remove old 2D axis
        ax.remove()
        
        # Create new 3D axis in same position
        ax = fig.add_axes(position, projection='3d')
        ax.set_box_aspect([1,1,1])

    # Convert inputs to numpy
    points = as_ndarray(points)
    elements = {k: as_ndarray(v) for k,v in elements.items()}
    values = {k: as_ndarray(v) for k,v in values.items()}
    
    if isinstance(alpha, dict):
        alpha = {k: as_ndarray(v) for k,v in alpha.items()}
    else:
        alpha = {k: alpha for k in elements.keys()}

    collections = {}
    
    # For each element type
    for ele_type in elements.keys():
        # Calculate centroid of each element
        ele_points = points[elements[ele_type]]
        centroids = ele_points.mean(axis=1)

        # Create interpolation grid using full point cloud bounds
        x = np.linspace(points[:,0].min(), points[:,0].max(), density)
        y = np.linspace(points[:,1].min(), points[:,1].max(), density)
        z = np.linspace(points[:,2].min(), points[:,2].max(), density)
        grid_x, grid_y, grid_z = np.meshgrid(x, y, z)
        grid_points = np.column_stack((grid_x.ravel(), grid_y.ravel(), grid_z.ravel()))

        # Interpolate values onto grid
        grid_values = griddata(centroids, values[ele_type], grid_points, method='linear')
        
        # Update points and values to use interpolated points where valid
        valid_mask = ~np.isnan(grid_values)
        centroids = grid_points[valid_mask]  # Will be scattered instead of original centroids
        values[ele_type] = grid_values[valid_mask]  # Update values to match interpolated points
        
        # Create scatter plot
        if color is None:
            scatter = ax.scatter(grid_points[valid_mask,0],
                               grid_points[valid_mask,1], 
                               grid_points[valid_mask,2],
                               c=grid_values[valid_mask],
                               alpha=alpha[ele_type],
                               cmap=cmap)
        else:
            scatter = ax.scatter(grid_points[valid_mask,0],
                               grid_points[valid_mask,1],
                               grid_points[valid_mask,2], 
                               c=color,
                               alpha=alpha[ele_type])
            
        collections[ele_type] = scatter

    ax.set_xlabel('X')
    ax.set_ylabel('Y') 
    ax.set_zlabel('Z')

    return collections, ax

def update_element_value_3d(collections: Dict[str, Path3DCollection],
                           points: Union[torch.Tensor, np.ndarray],
                           elements: Dict[str, Union[torch.Tensor, np.ndarray]], 
                           values: Dict[str, Union[torch.Tensor, np.ndarray]],
                           density: int = 25):
    """Update the element values for a 3D visualization
    
    Parameters
    ----------
    collections: Dict[str, Path3DCollection]
        Dictionary mapping element types to their scatter plot collections
    points: Union[torch.Tensor, np.ndarray] 
        Points tensor of shape [n_points, 3]
    elements: Dict[str, Union[torch.Tensor, np.ndarray]]
        Dictionary mapping element types to their element arrays
    values: Dict[str, Union[torch.Tensor, np.ndarray]]
        Dictionary mapping element types to their value arrays
    density: int
        Grid density for interpolation, default 25
    """
    points_np = as_ndarray(points)
    elements = {k: as_ndarray(v) for k,v in elements.items()}
    values = {k: as_ndarray(v) for k,v in values.items()}
    for ele_type in elements.keys():
        # Calculate centroids
        ele_points = points_np[elements[ele_type]]
        centroids = ele_points.mean(axis=1)

        # Create interpolation grid 
        grid_points = grid(3, points_np.min(0), points_np.max(0), density)

        # Get current scatter point positions
        pos = np.column_stack(collections[ele_type]._offsets3d)

        # Interpolate values at scatter point positions
        new_values = griddata(centroids, values[ele_type], pos, method='linear')

        # Update scatter plot
        valid_mask = ~np.isnan(new_values)
        collections[ele_type].set_array(new_values[valid_mask])


def draw_element_value(mesh,
                      values: Dict[str, Union[torch.Tensor, np.ndarray]],
                      alpha: Optional[Union[float, Dict[str, Union[torch.Tensor, np.ndarray]]]] = None,
                      cmap: str = 'viridis',
                      color: Optional[str] = None,
                      density: int = 25,
                      ax: Optional[Union[Axes, Axes3D]] = None
                      ) -> Tuple[Dict[str, Union[PolyCollection, Path3DCollection]], Union[Axes, Axes3D]]:
    """Draw element values for 2D or 3D mesh
    
    Parameters
    ----------
    mesh: Mesh
        The mesh object containing points and elements
    values: Dict[str, Union[torch.Tensor, np.ndarray]]
        Dictionary mapping element types to their value arrays
    alpha: Optional[Union[float, Dict[str, Union[torch.Tensor, np.ndarray]]]]
        Transparency value(s). If None, defaults to 1.0 for 2D and 0.2 for 3D.
        For float values, should be between 0 and 1.
        For tensor/array values, should be shape [n_elements] with values between 0 and 1.
    cmap: str
        Colormap name, default 'viridis'
    color: Optional[str]
        If specified, use this color instead of colormap
    density: int
        Grid density for 3D interpolation, default 25
    ax: Optional[Union[Axes, Axes3D]]
        Matplotlib axes, default None
        
    Returns
    -------
    collections: Dict[str, Union[PolyCollection, Path3DCollection]]
        Dictionary mapping element types to their collections
    ax: Union[Axes, Axes3D]
        The matplotlib axes
    """
    points = mesh.points
    elements = mesh.elements(mesh.dim)
    
    if alpha is None:
        if mesh.dim == 2:
            alpha = 1.0 
        elif mesh.dim == 3:
            alpha = 0.2

    if mesh.dim == 2:
        return draw_element_value_2d(points, elements, values, alpha, cmap, color, ax)
    else:
        return draw_element_value_3d(points, elements, values, alpha, cmap, color, density, ax)

def update_element_value(
                        mesh,
                        collections: Dict[str, Union[PolyCollection, Path3DCollection]],
                        values: Dict[str, Union[torch.Tensor, np.ndarray]],
                        alpha: Union[float, Dict[str, Union[torch.Tensor, np.ndarray]]] = 1.0,
                        density: int = 25):
    """Update element values for 2D or 3D visualization
    
    Parameters
    ----------
    mesh: Mesh
        The mesh object containing points and elements
    collections: Dict[str, Union[PolyCollection, Path3DCollection]]
        Dictionary mapping element types to their collections
    values: Dict[str, Union[torch.Tensor, np.ndarray]]
        Dictionary mapping element types to their value arrays
    alpha: float or Dict[str, Union[torch.Tensor, np.ndarray]]
        Transparency value(s), default 1.0
    density: int
        Grid density for 3D interpolation, default 25
    """
    points = mesh.points
    elements = mesh.elements(mesh.dim)
    
    if mesh.dim == 2:
        return update_element_value_2d(collections, values, alpha)
    else:
        return update_element_value_3d(collections, points, elements, values, density)