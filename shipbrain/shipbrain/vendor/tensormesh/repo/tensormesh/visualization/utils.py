from matplotlib.pyplot import isinteractive
import torch
import numpy as np
import meshio
import os
from functools import lru_cache
from typing import Sequence, Union, TypeVar,Generic
from scipy.sparse import coo_matrix, csr_matrix, csc_matrix, dia_matrix, dok_matrix, lil_matrix, issparse
from ..sparse import SparseMatrix

# pyvista is an optional dependency — only required for 3D rendering and
# pyvista-backed exports. The 2D matplotlib path does not need it. Mirrors
# the try/except pattern used elsewhere in tensormesh (see e.g.
# tensormesh.sparse.solve.torch_sla_solve).
try:
    import pyvista as pv
    HAS_PYVISTA = True
except ImportError:
    pv = None
    HAS_PYVISTA = False

_PYVISTA_INSTALL_HINT = (
    "pyvista is required for this function. Install it with:\n"
    "    pip install pyvista"
)

ScipySparseMatrix = Union[coo_matrix, csr_matrix, csc_matrix, dia_matrix, dok_matrix, lil_matrix]
def as_sparse_matrix(x:Union[SparseMatrix,ScipySparseMatrix])->SparseMatrix:
    if issparse(x):
        x = x.tocoo()
        x = SparseMatrix.from_scipy_coo(x)
    elif isinstance(x, SparseMatrix):
        x = x.detach().cpu()
    else:
        raise TypeError(f"{type(x)} is not acceptable for SparseMatrix|ScipySparseMatrix")
    return x

def as_tensor(x:Union[torch.Tensor,np.ndarray])->torch.Tensor:
    if isinstance(x, np.ndarray):
        return torch.from_numpy(x)
    elif isinstance(x, torch.Tensor):
        return x.detach().cpu()
    else:
        raise ValueError(f"unsupported type {type(x)}")


def as_ndarray(x:Union[torch.Tensor,np.ndarray])->np.ndarray:
    if isinstance(x, torch.Tensor):
        return x.detach().cpu().numpy()
    elif isinstance(x, np.ndarray):
        return x
    else:
        raise ValueError(f"unsupported type {type(x)}")

def dim(x:torch.Tensor|np.ndarray)->int:
    if isinstance(x, torch.Tensor):
        return x.dim()
    elif isinstance(x, np.ndarray):
        return len(x.shape)
    else:
        raise ValueError(f"unsupported type {type(x)}")
    
@lru_cache()
def grid(dim:int, min_vals:Sequence[float], max_vals:Sequence[float], density:int=100) -> np.ndarray:
    """Create a grid of points in 2D or 3D space.

    Parameters
    ----------
    dim : int
        Dimension of the grid (2 or 3)
    min_vals : Sequence[float]
        Minimum values for each dimension
    max_vals : Sequence[float] 
        Maximum values for each dimension
    density : int, optional
        Number of points along each dimension, by default 100

    Returns
    -------
    np.ndarray
        Grid points with shape (density^dim, dim)
    """
    assert dim in [2,3], f"dim must be 2 or 3, got {dim}"
    assert len(min_vals) == dim, f"min_vals must have length {dim}"
    assert len(max_vals) == dim, f"max_vals must have length {dim}"

    if dim == 2:
        x = np.linspace(min_vals[0], max_vals[0], density)
        y = np.linspace(min_vals[1], max_vals[1], density)
        X, Y = np.meshgrid(x, y)
        return np.column_stack((X.flatten(), Y.flatten()))
    else:
        x = np.linspace(min_vals[0], max_vals[0], density)
        y = np.linspace(min_vals[1], max_vals[1], density)
        z = np.linspace(min_vals[2], max_vals[2], density)
        X, Y, Z = np.meshgrid(x, y, z)
        return np.column_stack((X.flatten(), Y.flatten(), Z.flatten()))

def setup_headless():
    """Start xvfb for headless rendering if needed."""
    if not HAS_PYVISTA:
        raise ImportError(_PYVISTA_INSTALL_HINT)
    try:
        pv.start_xvfb()
    except Exception:
        pass

def mesh_to_pyvista(mesh, point_data=None, cell_data=None, linearize=False):
    """
    Convert TensorMesh to PyVista mesh via intermediate VTU file.
    
    Parameters
    ----------
    mesh : tensormesh.Mesh
    point_data : dict, optional
        Dict of {name: tensor/array} to add as point data.
    cell_data : dict, optional
        Dict of {name: tensor/array} to add as cell data.
    linearize : bool, optional
        If True, convert high-order elements to linear (e.g. tet10 -> tet4).
        
    Returns
    -------
    pyvista.DataSet
    """
    if not HAS_PYVISTA:
        raise ImportError(_PYVISTA_INSTALL_HINT)
    # 1. Get meshio object
    # mesh_to_pyvista ultimately writes VTU, so we must export connectivity in Gmsh/VTK ordering
    m_io = mesh.to_meshio(reorder=True)
    
    # 2. Add point data
    if point_data:
        for k, v in point_data.items():
            if isinstance(v, torch.Tensor):
                v = v.detach().cpu().numpy()
            # Pad 2D vectors to 3D
            if v.ndim == 2 and v.shape[1] == 2: 
                v = np.concatenate([v, np.zeros((v.shape[0], 1))], axis=1)
            m_io.point_data[k] = v

    # 3. Add cell data
    if cell_data:
        # Check structure of m_io.cells
        # Try to match data to cell blocks by length
        for k, v in cell_data.items():
            if isinstance(v, torch.Tensor):
                v = v.detach().cpu().numpy()
            
            # If user passed a list of arrays, assume it matches blocks
            if isinstance(v, list) and len(v) == len(m_io.cells):
                m_io.cell_data[k] = v
                continue
                
            # Otherwise, assume v is a single array for the main domain
            # We try to find a block with matching length
            matched = False
            data_list = []
            for cell_block in m_io.cells:
                n_cells = len(cell_block.data)
                if not matched and len(v) == n_cells:
                    data_list.append(v)
                    matched = True
                else:
                    # Fill with zeros
                    data_list.append(np.zeros(n_cells, dtype=v.dtype))
            
            if matched:
                m_io.cell_data[k] = data_list
            else:
                # Fallback: just wrap it and hope meshio handles it (likely fails if mismatch)
                 m_io.cell_data[k] = [v]

    # Fix boolean data types for VTU
    for k, v in m_io.point_data.items():
        if v.dtype == bool:
            m_io.point_data[k] = v.astype(int)
    
    for k, v in m_io.cell_data.items():
        m_io.cell_data[k] = [val.astype(int) if val.dtype == bool else val for val in v]
            
    # Clear cell_sets to avoid meshio write errors with VTU
    m_io.cell_sets = {}

    # 3. Linearize if requested
    if linearize:
        new_cells = []
        for cell_block in m_io.cells:
            if cell_block.type == 'tetra10':
                # Take first 4 nodes
                new_cells.append(meshio.CellBlock('tetra', cell_block.data[:, :4]))
            elif cell_block.type in ['hexahedron20', 'hexahedron27']:
                # Take first 8 nodes
                new_cells.append(meshio.CellBlock('hexahedron', cell_block.data[:, :8]))
            elif cell_block.type == 'triangle6':
                new_cells.append(meshio.CellBlock('triangle', cell_block.data[:, :3]))
            elif cell_block.type in ['quad9', 'quad8']:
                new_cells.append(meshio.CellBlock('quad', cell_block.data[:, :4]))
            else:
                new_cells.append(cell_block)
        m_io.cells = new_cells

    # 4. Save and Read
    tmp_filename = f".tmp_mesh_{os.getpid()}_{np.random.randint(0, 10000)}.vtu"
    
    try:
        m_io.write(tmp_filename)
        pv_mesh = pv.read(tmp_filename)
    except Exception as e:
        if os.path.exists(tmp_filename):
            os.remove(tmp_filename)
        raise e
        
    if os.path.exists(tmp_filename):
        os.remove(tmp_filename)
            
    return pv_mesh
