import os
import sys

# os.environ.setdefault("MPLCONFIGDIR", "/tmp/tensormesh_matplotlib")
# os.environ.setdefault("MPLBACKEND", "Agg")
# os.makedirs(os.environ["MPLCONFIGDIR"], exist_ok=True)

sys.path.append("../..")

import meshio
import torch

from tensormesh import Condenser, ElementAssembler, MassElementAssembler, Mesh, NodeAssembler
from tensormesh.sparse import SparseMatrix


class CurlCurlAssembler(ElementAssembler):
    """Assemble (curl u, curl v) for 3D vector nodal fields."""

    def forward(self, gradu, gradv):
        zero = torch.zeros_like(gradu[0])
        curl_u = torch.stack(
            (
                torch.stack((zero, -gradu[2], gradu[1])),
                torch.stack((gradu[2], zero, -gradu[0])),
                torch.stack((-gradu[1], gradu[0], zero)),
            )
        )
        curl_v = torch.stack(
            (
                torch.stack((zero, -gradv[2], gradv[1])),
                torch.stack((gradv[2], zero, -gradv[0])),
                torch.stack((-gradv[1], gradv[0], zero)),
            )
        )
        return curl_u.T @ curl_v


class DivergenceStabilizationAssembler(ElementAssembler):
    """Assemble sum_K h_K^2 * (div u, div v)_K."""

    def __post_init__(self, h2=1.0):
        self.h2 = h2

    def forward(self, gradu, gradv):
        return self.h2 * torch.outer(gradu, gradv)


class PressureStabilizationAssembler(ElementAssembler):
    """Assemble (grad p, grad q)."""

    def forward(self, gradu, gradv):
        return gradu @ gradv


class PressureCouplingAssembler(ElementAssembler):
    """Assemble B for b(v, p) = -(grad p, v) in interleaved vector layout."""

    def __post_init__(self):
        self.component = 0

    def forward(self, u, gradv):
        return u * gradv[self.component]

    def __call__(self, *args, **kwargs):
        component_matrices = []
        for component in range(self.dimension):
            self.component = component
            component_matrices.append(super().__call__(*args, **kwargs))

        n_points = component_matrices[0].shape[0]
        return SparseMatrix(
            -torch.cat([matrix.edata for matrix in component_matrices]),
            torch.cat(
                [
                    self.dimension * matrix.row + component
                    for component, matrix in enumerate(component_matrices)
                ]
            ),
            torch.cat([matrix.col for matrix in component_matrices]),
            shape=(self.dimension * n_points, n_points),
        )


class VectorLoadAssembler(NodeAssembler):
    """Assemble int f . v for a 3D vector-valued load."""

    def forward(self, v, f):
        return v * f


class CurlProjectionAssembler(NodeAssembler):
    """Assemble the right-hand side for the L2 projection of curl(A)."""

    def forward(self, v, gradA):
        curl_A = torch.stack(
            (
                gradA[2, 1] - gradA[1, 2],
                gradA[0, 2] - gradA[2, 0],
                gradA[1, 0] - gradA[0, 1],
            )
        )
        return v * curl_A


def straight_current_source(points, center_xy, radius, current_density):
    """Smooth z-directed current density concentrated near the center line."""
    x = points[:, 0]
    y = points[:, 1]

    dx = x - center_xy[0]
    dy = y - center_xy[1]
    distance2 = dx.square() + dy.square()
    magnitude = current_density * torch.exp(-distance2 / (2.0 * radius**2))

    return torch.stack((torch.zeros_like(x), torch.zeros_like(x), magnitude), dim=1)


def tangential_vector_potential_mask(points, atol=1e-12):
    x = points[:, 0]
    y = points[:, 1]
    z = points[:, 2]

    on_x = (torch.abs(x) <= atol) | (torch.abs(x - 1.0) <= atol)
    on_y = (torch.abs(y) <= atol) | (torch.abs(y - 1.0) <= atol)
    on_z = (torch.abs(z) <= atol) | (torch.abs(z - 1.0) <= atol)

    ax_dirichlet = on_y | on_z
    ay_dirichlet = on_x | on_z
    az_dirichlet = on_x | on_y

    return torch.stack((ax_dirichlet, ay_dirichlet, az_dirichlet), dim=1).flatten()


def vector_l2_norm_squared(mass_matrix, vector):
    value = torch.zeros((), dtype=vector.dtype, device=vector.device)
    for component in range(vector.shape[1]):
        component_values = vector[:, component]
        value = value + (component_values * (mass_matrix @ component_values)).sum()
    return value


def main():
    chara_length = 0.10
    current_center_xy = (0.5, 0.5)
    current_radius = 0.08
    current_density = 100.0
    out_dir = os.path.dirname(os.path.abspath(__file__))

    mesh = Mesh.gen_cube(chara_length=chara_length, order=1).double()

    points = mesh.points
    h2 = chara_length**2

    A = CurlCurlAssembler.from_mesh(mesh)()

    Su = DivergenceStabilizationAssembler.from_mesh(mesh,h2=h2)()

    Sp = PressureStabilizationAssembler.from_mesh(mesh)()

    B = PressureCouplingAssembler.from_mesh(mesh)()

    K = SparseMatrix.combine(
        [
            [A + Su, B],
            [-1.0 * B.T, Sp],
        ]
    )

    current = straight_current_source(
        points,
        center_xy=current_center_xy,
        radius=current_radius,
        current_density=current_density,
    )
    rhs_u = VectorLoadAssembler.from_mesh(mesh)(
        point_data={"f": current}, batch_size=-1
    )
    rhs_p = torch.zeros(mesh.n_points, dtype=points.dtype, device=points.device)
    rhs = torch.cat((rhs_u, rhs_p))

    dirichlet_mask = torch.cat(
        (
            tangential_vector_potential_mask(points),
            mesh.boundary_mask,
        )
    )
    dirichlet_value = torch.zeros_like(rhs)

    condenser = Condenser(dirichlet_mask, dirichlet_value)
    K_inner, rhs_inner = condenser(K, rhs)
    solution = condenser.recover(K_inner.solve(rhs_inner))

    n_points = mesh.n_points
    vector_potential = solution[: 3 * n_points].reshape(n_points, 3)

    # Compute the curl of A by applying the mass matrix inverse to the curl projection.
    mass_matrix = MassElementAssembler.from_mesh(mesh)()
    curl_rhs = CurlProjectionAssembler.from_mesh(mesh)(
        point_data={"A": vector_potential}, batch_size=-1
    ).reshape(n_points, 3)
    curl_A = torch.stack(
        [mass_matrix.solve(curl_rhs[:, component]) for component in range(3)],
        dim=1,
    )

    out_vtu = os.path.join(out_dir, "magnetostatic_3d.vtu")
    out_mesh = mesh.to_meshio(reorder=True)
    out_mesh.point_data = {
        "A": vector_potential.detach().cpu().numpy(),
        "curl_A": curl_A.detach().cpu().numpy(),
    }
    out_mesh.cell_data = {}
    out_mesh.field_data = {}
    out_mesh.cell_sets = {}
    meshio.write(out_vtu, out_mesh)

    print(
        "[magnetostatic] "
        f"vtu={out_vtu}"
    )


if __name__ == "__main__":
    main()
