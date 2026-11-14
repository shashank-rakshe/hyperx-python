import torch
import numpy as np
from .utils import mesh_to_pyvista, setup_headless, pv, HAS_PYVISTA, _PYVISTA_INSTALL_HINT

def animate_deformation(mesh, displacement: torch.Tensor, file_name: str,
                       frames: int = 30, fps: int = 10,
                       scale_factor: float = 1.0,
                       scalars: str = 'displacement'):
    if not HAS_PYVISTA:
        raise ImportError(_PYVISTA_INSTALL_HINT)
    """
    Generate an MP4 animation of the mesh deformation.
    
    Parameters
    ----------
    mesh : tensormesh.Mesh
    displacement : torch.Tensor
    file_name : str
    frames : int
    fps : int
    scale_factor : float
    scalars : str
    """
    setup_headless()
    
    # Prepare data
    if isinstance(displacement, torch.Tensor):
        u = displacement.detach().cpu().numpy()
    else:
        u = displacement
        
    # Use utility
    pv_mesh = mesh_to_pyvista(mesh, point_data={"displacement": u})
    
    # Create Plotter
    plotter = pv.Plotter(off_screen=True, window_size=[1024, 768])
    plotter.open_movie(file_name, framerate=fps)
    
    print(f"Generating animation: {file_name}")
    
    for i in range(frames + 1):
        progress = i / frames
        current_factor = progress * scale_factor
        
        # Warp
        warped = pv_mesh.warp_by_vector(vectors="displacement", factor=current_factor)
        
        plotter.clear()
        plotter.add_mesh(warped, scalars=scalars, cmap="jet", show_edges=True, edge_color="black")
        plotter.add_text(f"Deformation Scale: {current_factor:.2f}x", position='upper_left', font_size=10)
        
        if i == 0:
            plotter.view_isometric()
            plotter.reset_camera()
            plotter.camera.zoom(1.2)
            
        plotter.write_frame()
        
    plotter.close()
    print("Done.")