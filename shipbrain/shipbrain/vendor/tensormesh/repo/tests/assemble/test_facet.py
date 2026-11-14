
import sys
import torch
sys.path.append("../..")

from tensormesh import FacetAssembler, Mesh


class ProductAssembler(FacetAssembler):
    def forward(self, u, v):
        return u * v


class LaplaceAssembler(FacetAssembler):
    def forward(self, gradu, gradv):
        return gradu @ gradv


class IntegrateOne(FacetAssembler):
    def forward(self, v):
        return v


class IntegrateX(FacetAssembler):
    def forward(self, v, x):
        return x[0] * v


class IntegrateXSquared(FacetAssembler):
    def forward(self, v, x):
        return (x[0] ** 2) * v


class IntegrateXPlusY(FacetAssembler):
    def forward(self, v, x):
        return (x[0] + x[1]) * v


class IntegrateGradF0(FacetAssembler):
    def forward(self, v, gradf):
        return gradf[0] * v


def test_facet_shape():
    mesh = Mesh.gen_rectangle(0.1)
    assembler = ProductAssembler.from_mesh(mesh, quadrature_order=2)
    V = assembler()
    assert V.shape == (mesh.points.shape[0],)


def test_facet_integrate_one_p1_triangle():
    # On a unit-square mesh the boundary integral of 1 must equal the perimeter.
    mesh = Mesh.gen_rectangle(0.1)
    val = IntegrateOne.from_mesh(mesh)().sum().item()
    assert abs(val - 4.0) < 1e-10


def test_facet_integrate_one_p2_triangle():
    mesh = Mesh.gen_rectangle(0.2, order=2)
    val = IntegrateOne.from_mesh(mesh)().sum().item()
    assert abs(val - 4.0) < 1e-10


def test_facet_integrate_one_p1_quad():
    mesh = Mesh.gen_rectangle(0.25, element_type="quad")
    val = IntegrateOne.from_mesh(mesh)().sum().item()
    assert abs(val - 4.0) < 1e-7


def test_facet_reduce_sparse_match():
    mesh = Mesh.gen_rectangle(0.1)
    v_reduce = IntegrateOne.from_mesh(mesh, project="reduce")().sum().item()
    v_sparse = IntegrateOne.from_mesh(mesh, project="sparse")().sum().item()
    assert abs(v_reduce - v_sparse) < 1e-10


def test_facet_integrate_polynomials_p1_triangle():
    # ``x`` is automatically supplied via point_data["x"] = mesh.points.
    # Closed-form boundary integrals over the unit square:
    #   ∫_∂Ω x ds       = 2
    #   ∫_∂Ω x^2 ds     = 5/3
    #   ∫_∂Ω (x+y) ds   = 4
    mesh = Mesh.gen_rectangle(0.1)
    assert abs(IntegrateX.from_mesh(mesh)().sum().item() - 2.0) < 1e-8
    assert abs(IntegrateXSquared.from_mesh(mesh)().sum().item() - 5.0 / 3.0) < 1e-8
    assert abs(IntegrateXPlusY.from_mesh(mesh)().sum().item() - 4.0) < 1e-8


def test_facet_integrate_polynomials_p2_triangle():
    mesh = Mesh.gen_rectangle(0.2, order=2)
    assert abs(IntegrateX.from_mesh(mesh, quadrature_order=4)().sum().item() - 2.0) < 1e-10
    assert abs(IntegrateXSquared.from_mesh(mesh, quadrature_order=4)().sum().item() - 5.0 / 3.0) < 1e-8


def test_facet_integrate_polynomials_p1_quad():
    mesh = Mesh.gen_rectangle(0.25, element_type="quad")
    assert abs(IntegrateX.from_mesh(mesh)().sum().item() - 2.0) < 1e-6
    assert abs(IntegrateXSquared.from_mesh(mesh)().sum().item() - 5.0 / 3.0) < 1e-6


def test_facet_grad_point_data_p1_triangle():
    # For a P1-interpolatable f(x) = x, ∇f = (1, 0) exactly, so ∫_∂Ω ∂_x f ds = perimeter = 4.
    mesh = Mesh.gen_rectangle(0.1)
    asm = IntegrateGradF0.from_mesh(mesh)
    f_vals = mesh.points[:, 0].contiguous()
    val = asm(point_data={"f": f_vals}).sum().item()
    assert abs(val - 4.0) < 1e-8
