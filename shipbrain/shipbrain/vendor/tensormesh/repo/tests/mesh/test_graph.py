import torch
import pytest
from tensormesh import sparse
from tensormesh.mesh.partition import graph_partition
from tensormesh.mesh.coloring import graph_coloring

def get_grid_graph(n=10):
    """Create a 2D grid graph (n x n)."""
    # Grid connectivity
    # A simple way: (i,j) connected to (i+1,j), (i,j+1)
    
    N = n * n
    indices = torch.arange(N)
    
    # Right neighbors
    right = indices + 1
    # Mask right edge
    mask_r = (indices + 1) % n != 0
    u_r = indices[mask_r]
    v_r = right[mask_r]
    
    # Down neighbors
    down = indices + n
    mask_d = down < N
    u_d = indices[mask_d]
    v_d = down[mask_d]
    
    u = torch.cat([u_r, u_d])
    v = torch.cat([v_r, v_d])
    
    # Undirected
    row = torch.cat([u, v])
    col = torch.cat([v, u])
    edata = torch.ones_like(row, dtype=torch.float32)
    
    adj = sparse.SparseMatrix(edata, row, col, (N, N))
    return adj

def test_graph_coloring():
    """Test greedy coloring on a grid graph."""
    if not torch.cuda.is_available():
        device = 'cpu'
    else:
        device = 'cuda'
        
    n = 20
    adj = get_grid_graph(n).to(device)
    
    colors = graph_coloring(adj, max_iter=50)
    
    # Verification
    # Check all edges have different colors
    row = adj.row
    col = adj.col
    
    color_u = colors[row]
    color_v = colors[col]
    
    # Ignore self loops if any (our grid gen doesn't have them)
    mask = row != col
    
    conflicts = (color_u[mask] == color_v[mask]).sum()
    assert conflicts == 0, f"Found {conflicts} conflicts in coloring!"
    
    # Check number of colors is reasonable (Grid is bipartite, so 2 is min, greedy usually < 6)
    n_colors = colors.max().item() + 1
    print(f"Grid {n}x{n} colored with {n_colors} colors.")
    assert n_colors >= 2

def test_graph_partition():
    """Test spectral partitioning."""
    if not torch.cuda.is_available():
        device = 'cpu'
    else:
        device = 'cuda'
        
    n = 20
    adj = get_grid_graph(n).to(device)
    n_parts = 4
    
    parts = graph_partition(adj, n_parts, method='spectral')
    
    # Check range
    assert parts.min() >= 0
    assert parts.max() < n_parts
    
    # Check partition sizes (should be somewhat balanced)
    counts = torch.bincount(parts, minlength=n_parts)
    print(f"Partition sizes: {counts.tolist()}")
    
    # Ideal size is n*n / n_parts = 400/4 = 100
    # Spectral isn't perfect but shouldn't produce empty partitions
    assert (counts > 0).all(), "Some partitions are empty!"

if __name__ == "__main__":
    test_graph_coloring()
    test_graph_partition()
    print("All graph tests passed.")


