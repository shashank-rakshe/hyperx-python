"""
Topology Optimization using TensorMesh
Implements SIMP method for compliance minimization of a 2D cantilever beam.

This implementation matches JAX-FEM setup for fair comparison:
- Domain: 60 x 30 with mesh resolution matching element count
- Boundary conditions: Left edge fixed, bottom-right loaded downward
- Material: E_max=70e3, E_min=70, nu=0.3, penal=3
- Optimizer: MMA (Method of Moving Asymptotes) - same as JAX-FEM
"""

import numpy as np
import os
import glob
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from matplotlib.animation import FuncAnimation, FFMpegWriter
import time
from pathlib import Path
from tqdm import tqdm
import scipy.spatial

import torch
torch.set_default_dtype(torch.float64)
import sys
sys.path.append("../..")
from tensormesh import ElementAssembler, Mesh, Condenser
from mma_optimizer import MMAOptimizer


class SIMPStiffnessAssembler(ElementAssembler):
    """
    SIMP stiffness matrix assembler for 2D plane stress.
    K_e = E(rho_e) * K_0
    
    Uses SIMP interpolation: E(rho) = E_min + rho^p * (E_max - E_min)
    
    For 2D PLANE STRESS, we use the Voigt notation weak form:
    a(u,v) = ∫ ε(v)ᵀ D ε(u) dΩ
    
    where D = E/(1-ν²) * [[1,  ν,       0],
                          [ν,  1,       0],
                          [0,  0,  (1-ν)/2]]
    
    This matches JAX-FEM's plane stress formulation.
    """
    
    def __post_init__(self, E_max=70e3, E_min=70.0, nu=0.3, penal=3.0):
        """
        Initialize material parameters.
        
        Args:
            E_max: Maximum Young's modulus (solid material)
            E_min: Minimum Young's modulus (void material)  
            nu: Poisson's ratio
            penal: SIMP penalization exponent
        """
        self.E_max = E_max
        self.E_min = E_min
        self.nu = nu
        self.penal = penal
    
    def forward(self, gradu, gradv, rho):
        """
        Compute element stiffness contribution for 2D PLANE STRESS.
        
        Uses Voigt notation: ε = [ε11, ε22, 2*ε12]ᵀ
        
        The weak form integrand is: ε(v)ᵀ D ε(u)
        For basis functions φ_i with grad = [∂φ/∂x, ∂φ/∂y]:
        - ε(u_α) for direction α has components based on grad
        
        Parameters (after vmap):
            gradu, gradv: [dim] - gradient of single basis function (∂φ/∂x, ∂φ/∂y)
            rho: [] - scalar element density
        
        Returns: 
            [dim, dim] - contribution to stiffness matrix K[i,j] for DOFs (i,j)
        """
        # SIMP interpolation: E = E_min + rho^p * (E_max - E_min)
        E = self.E_min + (rho ** self.penal) * (self.E_max - self.E_min)
        nu = self.nu
        
        # Plane stress constitutive matrix (3x3 in Voigt notation)
        # D = E/(1-ν²) * [[1, ν, 0], [ν, 1, 0], [0, 0, (1-ν)/2]]
        D11 = E / (1.0 - nu * nu)
        D12 = nu * E / (1.0 - nu * nu)
        D33 = E / (2.0 * (1.0 + nu))  # = μ = G
        
        # Build the 2x2 stiffness contribution matrix
        # For displacement DOF in direction α (x or y), the strain is:
        # - ε_xx = ∂u_x/∂x when α=x (component 0)
        # - ε_yy = ∂u_y/∂y when α=y (component 1)  
        # - 2*ε_xy = ∂u_x/∂y + ∂u_y/∂x
        #
        # So for gradu (shape [2]) representing [∂φ/∂x, ∂φ/∂y]:
        # - B_matrix for x-direction DOF: ε = [gradu[0], 0, gradu[1]]
        # - B_matrix for y-direction DOF: ε = [0, gradu[1], gradu[0]]
        #
        # K[α,β] = ε_α^T D ε_β
        
        # Strain vectors for each DOF direction
        # For u in x-direction: ε = [∂u/∂x, 0, ∂u/∂y] = [gradu[0], 0, gradu[1]]
        # For u in y-direction: ε = [0, ∂u/∂y, ∂u/∂x] = [0, gradu[1], gradu[0]]
        
        gux, guy = gradu[0], gradu[1]
        gvx, gvy = gradv[0], gradv[1]
        
        # K[i,j] = B_a[:, i]^T @ C @ B_b[:, j]
        # where B = [[∂N/∂x, 0], [0, ∂N/∂y], [∂N/∂y, ∂N/∂x]]
        # B[:, 0] = [gx, 0, gy] (x-DOF), B[:, 1] = [0, gy, gx] (y-DOF)
        K00 = D11 * gux * gvx + D33 * guy * gvy
        K01 = D12 * gux * gvy + D33 * guy * gvx
        K10 = D12 * guy * gvx + D33 * gux * gvy
        K11 = D11 * guy * gvy + D33 * gux * gvx
        
        K = torch.stack([torch.stack([K00, K01]), 
                        torch.stack([K10, K11])])
        
        return K


def build_filter(mesh, rmin):
    """
    Build density filter matrix for regularization.
    
    Args:
        mesh: TensorMesh mesh object
        rmin: Filter radius
    
    Returns:
        H_normalized: Filter matrix [n_elements, n_elements]
    """
    elements = mesh.elements()
    points = mesh.points.detach().cpu().numpy()
    centroids = points[elements.cpu().numpy()].mean(axis=1)
    n_elements = len(elements)
    
    print(f"Building filter with rmin = {rmin:.4f}")
    
    kd_tree = scipy.spatial.KDTree(centroids)
    
    I, J, V = [], [], []
    for i in range(n_elements):
        neighbors = kd_tree.query_ball_point(centroids[i], rmin)
        for j in neighbors:
            d = np.linalg.norm(centroids[i] - centroids[j])
            val = max(0.0, rmin - d)
            if val > 0:
                I.append(i)
                J.append(j)
                V.append(val)
    
    H = scipy.sparse.csc_array((V, (I, J)), shape=(n_elements, n_elements))
    H_np = np.array(H.todense())
    Hs_np = H_np.sum(axis=1, keepdims=True)
    H_normalized = H_np / (Hs_np + 1e-10)
    
    return torch.tensor(H_normalized, dtype=mesh.dtype, device=mesh.device)


def create_animation(mesh, frames, save_path, fps=5, bc_info=None):
    """
    Create animation of optimization process.
    
    Args:
        mesh: TensorMesh mesh object
        frames: List of frame dictionaries with 'epoch', 'rho', 'compliance'
        save_path: Output file path
        fps: Frames per second
        bc_info: Dictionary with boundary condition info
    """
    if len(frames) == 0:
        print("  No frames to animate")
        return False
    
    points = mesh.points.detach().cpu().numpy()
    elements = mesh.elements().cpu().numpy()
    verts = [points[elem] for elem in elements]
    
    # Get domain bounds
    x_min, x_max = points[:, 0].min(), points[:, 0].max()
    y_min, y_max = points[:, 1].min(), points[:, 1].max()
    domain_size = max(x_max - x_min, y_max - y_min)
    
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))
    
    # Density plot
    coll = PolyCollection(verts, array=frames[0]['rho'], cmap='gray_r',
                         edgecolors='none', linewidths=0.0)
    coll.set_clim(0, 1)
    ax1.add_collection(coll)
    ax1.autoscale()
    ax1.set_aspect('equal')
    title1 = ax1.set_title(f'Iteration 0', fontsize=12)
    ax1.set_xlabel('x')
    ax1.set_ylabel('y')
    plt.colorbar(coll, ax=ax1, shrink=0.6, label='Density')
    
    # Draw boundary conditions
    if bc_info is not None:
        # Fixed boundary (left edge)
        ax1.plot([x_min, x_min], [y_min, y_max], 'b-', linewidth=3, label='Fixed')
        
        # Load point
        if 'load_pts' in bc_info:
            load_pts = bc_info['load_pts']
            load_coords = points[load_pts]
            ax1.scatter(load_coords[:, 0], load_coords[:, 1], c='red', s=50, marker='v', label='Load')
    
    # Compliance history
    compliances = [f['compliance'] for f in frames]
    epochs = [f['epoch'] for f in frames]
    line, = ax2.semilogy([], [], 'b-', linewidth=2)
    ax2.set_xlim(0, max(epochs) + 1)
    ax2.set_ylim(min(compliances) * 0.9, max(compliances) * 1.1)
    ax2.set_xlabel('Iteration')
    ax2.set_ylabel('Compliance')
    ax2.set_title('Convergence', fontsize=12)
    ax2.grid(True, alpha=0.3)
    
    plt.tight_layout()
    
    def update(frame_idx):
        frame = frames[frame_idx]
        coll.set_array(frame['rho'])
        title1.set_text(f'Iteration {frame["epoch"]}, C={frame["compliance"]:.2e}')
        current_epochs = epochs[:frame_idx+1]
        current_compliances = compliances[:frame_idx+1]
        line.set_data(current_epochs, current_compliances)
        return coll, title1, line
    
    anim = FuncAnimation(fig, update, frames=len(frames), interval=1000//fps, blit=False)
    
    try:
        writer = FFMpegWriter(fps=fps, metadata={'title': 'TensorMesh Topology Optimization'})
        anim.save(str(save_path), writer=writer, dpi=150)
        print(f"  Saved: {save_path}")
        plt.close()
        return True
    except Exception as e:
        print(f"  ffmpeg failed: {e}, trying gif...")
        gif_path = str(save_path).replace('.mp4', '.gif')
        try:
            anim.save(gif_path, writer='pillow', fps=fps, dpi=100)
            print(f"  Saved: {gif_path}")
            plt.close()
            return True
        except Exception as e2:
            print(f"  Warning: Could not save animation ({e2})")
            plt.close()
            return False


def save_vtk(mesh, rho, u, filepath):
    """Save solution to VTK file for visualization."""
    try:
        import meshio
        
        dim = 2
        n_points = mesh.n_points
        
        # Reshape displacement to [n_points, dim]
        u_reshaped = u.reshape(-1, dim).detach().cpu().numpy()
        
        # Pad to 3D
        u_padded = np.hstack([u_reshaped, np.zeros((n_points, 1))])
        
        # Get mesh data
        points = mesh.points.detach().cpu().numpy()
        points = np.hstack([points, np.zeros((n_points, 1))])  # Pad to 3D
        
        cells = mesh.elements().cpu().numpy()
        
        # Create meshio mesh
        mesh_out = meshio.Mesh(
            points=points,
            cells=[('quad', cells)],
            point_data={'displacement': u_padded},
            cell_data={'density': [rho.detach().cpu().numpy().flatten()]}
        )
        
        mesh_out.write(filepath)
        
    except Exception as e:
        print(f"Warning: Failed to save VTK: {e}")


def run_topology_optimization(output_dir='output', vf=0.5, max_iters=51,
                              Nx=60, Ny=30, device='cpu', record_video=True):
    """
    Run topology optimization using OC method with autograd gradients.
    
    This implementation matches JAX-FEM setup:
    - Domain: Lx=60, Ly=30 with Nx x Ny elements
    - Left edge fixed, bottom-right corner loaded downward with F=100
    - E_max=70e3, E_min=70, nu=0.3, penal=3
    - Volume fraction constraint vf
    
    Args:
        output_dir: Output directory for results
        vf: Volume fraction constraint
        max_iters: Maximum number of optimization iterations
        Nx, Ny: Mesh resolution
        device: 'cpu' or 'cuda'
        record_video: Whether to save frames for video generation
    
    Returns:
        outputs: List of objective function values
        timings: Dictionary of timing information
    """
    # Create output directories
    output_path = Path(output_dir)
    vtk_path = output_path / 'vtk' / 'tensormesh'
    vtk_path.mkdir(parents=True, exist_ok=True)
    
    # Clean old files
    for f in glob.glob(str(vtk_path / '*')):
        os.remove(f)
    
    print("="*80)
    print("TensorMesh Topology Optimization (SIMP)")
    print("="*80)
    print(f"Mesh resolution: {Nx} x {Ny}")
    print(f"Volume fraction: {vf}")
    print(f"Max iterations: {max_iters}")
    print(f"Device: {device}")
    print("="*80)
    
    # Domain dimensions (match JAX-FEM)
    Lx, Ly = 60.0, 30.0
    
    # Setup timing
    setup_start = time.time()
    
    # Create mesh
    chara_length = min(Lx / Nx, Ly / Ny)
    mesh = Mesh.gen_rectangle(
        left=0.0, right=Lx,
        bottom=0.0, top=Ly,
        chara_length=chara_length,
        element_type="quad"
    ).double()
    
    if device == 'cuda' and torch.cuda.is_available():
        mesh = mesh.to('cuda')
    
    n_points = mesh.n_points
    n_elements = mesh.n_elements
    dim = 2
    
    print(f"\nMesh: {n_points} nodes, {n_elements} elements")
    
    # Setup SIMP assembler with JAX-FEM matching parameters
    E_max = 70e3
    E_min = 1e-3 * E_max  # = 70
    nu = 0.3
    penal = 3.0
    
    K_asm = SIMPStiffnessAssembler.from_mesh(
        mesh, E_max=E_max, E_min=E_min, nu=nu, penal=penal
    )
    
    # Boundary conditions: fix left boundary
    dbc_mask = mesh.point_data['is_left_boundary'].flatten().repeat_interleave(dim)
    condenser = Condenser(dbc_mask)
    
    print(f"Dirichlet DOFs: {dbc_mask.sum().item()} / {n_points * dim}")
    
    # Load: match JAX-FEM exactly
    # JAX-FEM applies traction on boundary where x=Lx and y in [0, 0.1*Ly]
    # Traction = [0, 100] with negative sign in compliance, so effective = [0, -100] (downward)
    points_np = mesh.points.detach().cpu().numpy()
    right_boundary = mesh.point_data['is_right_boundary'].flatten().cpu().numpy()
    
    # Find points on right edge in the load region (y <= 0.1*Ly)
    right_pts = np.where(right_boundary)[0]
    load_pts = right_pts[points_np[right_pts, 1] <= 0.1 * Ly + 1e-5]
    
    # Sort by y coordinate
    load_pts = load_pts[np.argsort(points_np[load_pts, 1])]
    
    if len(load_pts) == 0:
        dists = np.linalg.norm(points_np[right_pts] - np.array([Lx, 0.0]), axis=1)
        load_pts = right_pts[np.argmin(dists):np.argmin(dists)+1]
    
    print(f"Load applied to {len(load_pts)} nodes near bottom-right")
    for i, pt_idx in enumerate(load_pts):
        print(f"  Node {pt_idx}: position ({points_np[pt_idx, 0]:.2f}, {points_np[pt_idx, 1]:.2f})")
    
    # Compute equivalent nodal forces using consistent load distribution
    # For uniform traction t on a boundary, the equivalent nodal force is:
    # F_i = ∫ N_i * t dS
    #
    # NOTE: Due to FEM implementation differences between JAX-FEM and TensorMesh
    # (Jacobian handling, integration schemes, etc.), we apply an empirical
    # scaling factor to match compliance values.
    # JAX-FEM compliance / TensorMesh compliance ≈ 2.56, so scale force by sqrt(2.56) ≈ 1.6
    
    # No scaling factor needed after fixing K01/K10 formula bug
    traction = 100.0
    
    F = torch.zeros(n_points * dim, dtype=mesh.dtype, device=mesh.device)
    
    if len(load_pts) >= 2:
        y_coords = points_np[load_pts, 1]
        
        for i, pt_idx in enumerate(load_pts):
            if i == 0:
                L_influence = (y_coords[1] - y_coords[0]) / 2.0
            elif i == len(load_pts) - 1:
                L_influence = (y_coords[-1] - y_coords[-2]) / 2.0
            else:
                L_influence = (y_coords[i+1] - y_coords[i-1]) / 2.0
            
            F[pt_idx * dim + 1] = -traction * L_influence
    else:
        F[load_pts[0] * dim + 1] = -traction * 0.1 * Ly
    
    total_force = F[1::2].sum().item()
    print(f"Total applied force: {total_force:.2f} N (scaled to match JAX-FEM)")
    
    # Initialize densities
    rho = torch.full((n_elements,), vf, dtype=mesh.dtype, device=mesh.device)
    
    # Create MMA optimizer (same as JAX-FEM)
    optimizer = MMAOptimizer(
        rho,
        vf=vf,
        move_limit=0.1,  # Match JAX-FEM
        rho_min=1e-3,
        rho_max=1.0,
        use_filter=True,
        mesh=mesh,
    )
    
    setup_time = time.time() - setup_start
    print(f"Setup time: {setup_time:.4f} s")
    
    print(f"\nStarting MMA optimization with autograd gradients...")
    
    # Storage
    history = {'compliance': [], 'volume': []}
    animation_frames = []
    iteration_times = []
    
    opt_start = time.time()
    
    for epoch in tqdm(range(max_iters), desc="Optimizing"):
        iter_start = time.time()
        
        # No density filtering (matches JAX-FEM where density_filtering=False)
        # Enable gradients for sensitivity analysis
        rho_var = rho.clone().requires_grad_(True)
        
        # Assemble stiffness matrix with per-element density via element_data
        K = K_asm(mesh.points, element_data={"rho": rho_var})
        
        # Apply boundary conditions
        K_, F_ = condenser(K, F)
        
        # Solve linear system
        u_ = K_.solve(F_, backend="scipy")
        
        # Recover full displacement
        u = condenser.recover(u_)
        
        # Compute compliance: C = F^T u
        compliance = u @ F
        
        # Compute sensitivity via autograd
        compliance.backward()
        dc = rho_var.grad.clone()
        
        # Volume sensitivity
        dv = torch.ones_like(rho) / n_elements
        
        # MMA update step (sensitivity filtering is applied inside optimizer, like JAX-FEM)
        step_info = optimizer.step(dc=dc, dv=dv)
        
        # Record
        compliance_val = compliance.item()
        history['compliance'].append(compliance_val)
        history['volume'].append(step_info['volume'])
        iteration_times.append(time.time() - iter_start)
        
        # Save frame for animation every 5 iterations
        if epoch % 5 == 0:
            animation_frames.append({
                'epoch': epoch,
                'rho': rho.clone().cpu().numpy(),
                'compliance': compliance_val
            })
        
        # Save VTK for visualization every 5 iterations
        if record_video and epoch % 5 == 0:
            save_vtk(mesh, rho, u, vtk_path / f'sol_{epoch:03d}.vtu')
        
        if epoch % 10 == 0:
            print(f"\n  Epoch {epoch}: compliance = {compliance_val:.6e}, volume = {rho.mean().item():.4f}")
    
    opt_time = time.time() - opt_start
    
    # Compute reference compliance (full material)
    rho_full = torch.ones(n_elements, dtype=mesh.dtype, device=mesh.device)
    rho_full_var = rho_full.clone()
    K_full = K_asm(mesh.points, element_data={"rho": rho_full_var})
    K_full_, F_full_ = condenser(K_full, F)
    u_full_ = K_full_.solve(F_full_, backend="scipy")
    u_full = condenser.recover(u_full_)
    full_compliance = (u_full @ F).item()
    
    print("\n" + "="*80)
    print("Optimization completed!")
    print(f"Total optimization time: {opt_time:.4f} s")
    print(f"Average iteration time: {np.mean(iteration_times):.4f} s")
    print(f"Final compliance: {history['compliance'][-1]:.6e}")
    print(f"Full material compliance: {full_compliance:.6e}")
    print(f"Compliance reduction: {(1 - history['compliance'][-1]/full_compliance)*100:.2f}%")
    print("="*80)
    
    # Save results
    outputs = history['compliance']
    results = {
        'outputs': outputs,
        'setup_time': setup_time,
        'optimization_time': opt_time,
        'iteration_times': iteration_times,
        'full_compliance': full_compliance,
        'final_compliance': outputs[-1],
        'mesh_size': (Nx, Ny),
        'volume_fraction': vf,
        'max_iters': max_iters,
        'device': device
    }
    
    np.save(output_path / 'tensormesh_results.npy', results, allow_pickle=True)
    
    # Plot convergence
    plot_convergence(outputs, output_path / 'tensormesh_convergence.png')
    
    # Create animation
    if record_video:
        print("\nGenerating optimization animation...")
        bc_info = {'load_pts': load_pts}
        create_animation(mesh, animation_frames, 
                        output_path / 'tensormesh_optimization.mp4',
                        fps=5, bc_info=bc_info)
    
    timings = {
        'setup': setup_time,
        'optimization': opt_time,
        'per_iteration': np.mean(iteration_times),
        'total': setup_time + opt_time
    }
    
    return outputs, timings


def plot_convergence(outputs, save_path):
    """Plot optimization convergence curve."""
    obj = np.array(outputs)
    plt.figure(figsize=(10, 8))
    plt.plot(np.arange(len(obj)) + 1, obj, linestyle='-', linewidth=2, color='blue')
    plt.xlabel(r"Optimization step", fontsize=20)
    plt.ylabel(r"Objective value (Compliance)", fontsize=20)
    plt.title("TensorMesh Topology Optimization", fontsize=22)
    plt.tick_params(labelsize=18)
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(save_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"Convergence plot saved to {save_path}")


if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='TensorMesh Topology Optimization')
    parser.add_argument('--device', type=str, default='cpu', choices=['cpu', 'cuda'])
    parser.add_argument('--vf', type=float, default=0.5, help='Volume fraction')
    parser.add_argument('--max-iters', type=int, default=51, help='Max iterations')
    parser.add_argument('--nx', type=int, default=60, help='Mesh resolution in x')
    parser.add_argument('--ny', type=int, default=30, help='Mesh resolution in y')
    
    args = parser.parse_args()
    
    outputs, timings = run_topology_optimization(
        output_dir='output',
        vf=args.vf,
        max_iters=args.max_iters,
        Nx=args.nx,
        Ny=args.ny,
        device=args.device,
        record_video=True
    )
    
    print("\nTiming Summary:")
    for key, val in timings.items():
        print(f"  {key}: {val:.4f} s")