import torch
import numpy as np
from .utils import mesh_to_pyvista, setup_headless, pv, HAS_PYVISTA, _PYVISTA_INSTALL_HINT

def plot_deformation(mesh, displacement: torch.Tensor, file_name: str,
                     scale_factor: float = 1.0,
                     camera_position = 'isometric',
                     fixed_nodes = None,
                     force_vectors = None,
                     linearize: bool = True):
    if not HAS_PYVISTA:
        raise ImportError(_PYVISTA_INSTALL_HINT)
    """
    Save a static comparison plot of undeformed (wireframe) vs deformed (solid) mesh,
    optionally showing boundary conditions (fixed nodes and force vectors).
    
    Parameters
    ----------
    mesh : tensormesh.Mesh
    displacement : torch.Tensor
    file_name : str
        Output filename (e.g. 'result.png')
    scale_factor : float
        Scale factor for deformation. Default 1.0.
    camera_position : str
        'isometric', 'xy', 'xz', 'yz'
    fixed_nodes : torch.Tensor/ndarray, optional
        Boolean mask or indices of fixed nodes.
    force_vectors : torch.Tensor/ndarray, optional
        Force vectors at nodes (shape [N, 3]).
    linearize : bool
        If True, convert high-order elements to linear elements for robust visualization. Default True.
    """
    setup_headless()
    
    # Prepare Displacement Data
    if isinstance(displacement, torch.Tensor):
        u = displacement.detach().cpu().numpy()
    else:
        u = displacement
    
    # Use utility for conversion
    pv_mesh = mesh_to_pyvista(mesh, point_data={"displacement": u}, linearize=linearize)

    # Calculate bounding box diagonal for scaling glyphs
    bounds = pv_mesh.bounds
    diag = np.linalg.norm([bounds[1]-bounds[0], bounds[3]-bounds[2], bounds[5]-bounds[4]])
    glyph_scale = diag * 0.02 # 2% of diagonal size

    # Create Plotter
    plotter = pv.Plotter(off_screen=True, window_size=[1024, 768])
    
    # 1. Undeformed Mesh (Wireframe, Grey, Transparent)
    plotter.add_mesh(pv_mesh, style='wireframe', color='grey', opacity=0.3, label='Original')
    
    # 2. Deformed Mesh (Solid, Colored by displacement)
    warped = pv_mesh.warp_by_vector(vectors="displacement", factor=scale_factor)
    plotter.add_mesh(warped, scalars="displacement", cmap="jet", show_edges=True, edge_color="black", label='Deformed', smooth_shading=True, split_sharp_edges=True)
    
    # 3. BC Visualization
    
    # Fixed Constraints (Blue Cubes)
    if fixed_nodes is not None:
        if isinstance(fixed_nodes, torch.Tensor): fixed_nodes = fixed_nodes.detach().cpu().numpy()
        
        # Get coordinates
        pts = pv_mesh.points # Use pv_mesh points which are already numpy and 3D
        if fixed_nodes.dtype == bool:
            fixed_pts = pts[fixed_nodes]
        else:
            fixed_pts = pts[fixed_nodes]
            
        if len(fixed_pts) > 0:
            cloud = pv.PolyData(fixed_pts)
            # Use cubes for constraints
            glyphs = cloud.glyph(scale=False, geom=pv.Cube(), orient=False, factor=glyph_scale)
            plotter.add_mesh(glyphs, color="blue", label="Fixed")

    # Force Vectors (Red Arrows)
    if force_vectors is not None:
        if isinstance(force_vectors, torch.Tensor): force_vectors = force_vectors.detach().cpu().numpy()
        
        # Ensure 3D
        if force_vectors.shape[1] == 2:
             force_vectors = np.concatenate([force_vectors, np.zeros((force_vectors.shape[0], 1))], axis=1)
             
        force_mag = np.linalg.norm(force_vectors, axis=1)
        load_mask = force_mag > 1e-9 * force_mag.max() # Filter near-zero
        
        if np.any(load_mask):
            pts = pv_mesh.points
            load_pts = pts[load_mask]
            load_vecs = force_vectors[load_mask]
            
            # Subsample if too many (>30) to avoid clutter
            if len(load_pts) > 30:
                # Random sampling
                indices = np.random.choice(len(load_pts), 30, replace=False)
                load_pts = load_pts[indices]
                load_vecs = load_vecs[indices]
            
            cloud = pv.PolyData(load_pts)
            cloud["vectors"] = load_vecs
            
            # Arrows
            # Reduced scale for better visibility
            arrows = cloud.glyph(orient="vectors", scale=False, factor=glyph_scale*2.0, geom=pv.Arrow())
            plotter.add_mesh(arrows, color="red", label="Load")

    # Setup
    plotter.add_text(f"Deformation Scale: {scale_factor:.1f}x", position='upper_left')
    plotter.add_axes()
    plotter.add_legend()
    
    if camera_position == 'xy':
        plotter.view_xy()
    elif camera_position == 'isometric':
        plotter.view_isometric()
    elif camera_position == 'xz':
        plotter.view_xz()
    
    plotter.reset_camera()
    plotter.camera.zoom(1.2)
    
    # Save
    plotter.screenshot(file_name)
    plotter.close()
    print(f"Comparison plot saved to {file_name}")