import sys
import torch
import meshio

# Match existing tests pattern
sys.path.append("../..")

from tensormesh.element import Triangle, Quadrilateral, Tetrahedron, Hexahedron, Pyramid, Prism
from tensormesh.mesh import Mesh


def _roundtrip(element_cls, n_nodes: int):
    conn = torch.arange(n_nodes, dtype=torch.long)[None, :]
    internal = element_cls.reorder(conn, to_gmsh=False)
    back = element_cls.reorder(internal, to_gmsh=True)
    assert torch.equal(back, conn), f"{element_cls.__name__} roundtrip failed for n_nodes={n_nodes}"


def test_quad4_mapping_expected():
    # Gmsh/VTK Quad4 is [0,1,2,3] (BL, BR, TR, TL)
    conn_gmsh = torch.tensor([[0, 1, 2, 3]], dtype=torch.long)
    conn_internal = Quadrilateral.reorder(conn_gmsh, to_gmsh=False)
    assert torch.equal(conn_internal, torch.tensor([[0, 1, 3, 2]], dtype=torch.long))

    conn_back = Quadrilateral.reorder(conn_internal, to_gmsh=True)
    assert torch.equal(conn_back, conn_gmsh)


def test_element_reorder_roundtrip_common():
    # Triangle
    _roundtrip(Triangle, 3)
    _roundtrip(Triangle, 6)
    _roundtrip(Triangle, 10)

    # Quadrilateral
    _roundtrip(Quadrilateral, 4)
    _roundtrip(Quadrilateral, 9)
    _roundtrip(Quadrilateral, 16)

    # Tetrahedron
    _roundtrip(Tetrahedron, 4)
    _roundtrip(Tetrahedron, 10)
    _roundtrip(Tetrahedron, 20)
    _roundtrip(Tetrahedron, 35)

    # Hexahedron (linear)
    _roundtrip(Hexahedron, 8)
    _roundtrip(Hexahedron, 27)
    _roundtrip(Hexahedron, 64)
    _roundtrip(Hexahedron, 125)

    # Pyramid (linear)
    _roundtrip(Pyramid, 5)

    # Prism/Wedge
    _roundtrip(Prism, 6)
    _roundtrip(Prism, 18)
    _roundtrip(Prism, 40)
    _roundtrip(Prism, 75)


def test_mesh_to_meshio_reorder_flag_quad4():
    # Build a single quad in gmsh ordering
    pts = torch.tensor(
        [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]],
        dtype=torch.float64,
    ).numpy()
    cells = [("quad", torch.tensor([[0, 1, 2, 3]], dtype=torch.int64).numpy())]
    m = meshio.Mesh(points=pts, cells=cells)

    # Read with reorder=True: gmsh -> internal
    mesh = Mesh(m, reorder=True)
    conn_internal = mesh.cells["quad"]
    assert torch.equal(conn_internal, torch.tensor([[0, 1, 3, 2]], dtype=torch.long))

    # Export with reorder=False: stays internal
    m0 = mesh.to_meshio(reorder=False)
    assert (m0.cells_dict["quad"] == conn_internal.cpu().numpy()).all()

    # Export with reorder=True: internal -> gmsh
    m1 = mesh.to_meshio(reorder=True)
    assert (m1.cells_dict["quad"] == torch.tensor([[0, 1, 2, 3]], dtype=torch.long).numpy()).all()


