"""Regression tests for ``batch_size``-correctness in ElementAssembler /
NodeAssembler.

Before fix, ``n_batch = n_quadrature // batch_size`` silently dropped the
tail quadrature points when ``batch_size`` did not divide ``n_quadrature``,
and ``batch_size > n_quadrature`` produced an empty loop that tripped an
AssertionError. ``batch_size=-1`` on NodeAssembler also crashed (it computed
``// -1`` and got a negative ``n_batch``).
"""
import sys
import pytest
import torch

sys.path.append("../..")

from tensormesh import (
    Mesh,
    NodeAssembler,
    MassElementAssembler,
)


class _Ones(NodeAssembler):
    def forward(self, v):
        return v


def _abs_err(val, expected):
    return abs(val - expected)


# --- NodeAssembler: ∫_Ω 1 dΩ = 1 on the unit square, every batch_size ---

@pytest.mark.parametrize("batch_size", [-1, None, 1, 2, 3, 4, 5, 7, 9])
def test_node_assembler_batch_size_triangle_order1(batch_size):
    mesh = Mesh.gen_rectangle(chara_length=0.15)        # n_quadrature = 3 per element
    val = _Ones.from_mesh(mesh)(batch_size=batch_size).sum().item()
    assert _abs_err(val, 1.0) < 1e-10


@pytest.mark.parametrize("batch_size", list(range(1, 9)) + [-1, None])
def test_node_assembler_batch_size_triangle6_order4(batch_size):
    mesh = Mesh.gen_rectangle(chara_length=0.2, order=2)  # P2
    val = _Ones.from_mesh(mesh, quadrature_order=4)(batch_size=batch_size).sum().item()
    assert _abs_err(val, 1.0) < 1e-10


# --- ElementAssembler: 1^T M 1 = area of Ω, every batch_size ---

@pytest.mark.parametrize("batch_size", [-1, None, 1, 2, 3, 4, 5])
def test_element_assembler_batch_size_mass_unit_square(batch_size):
    mesh = Mesh.gen_rectangle(chara_length=0.15)
    M = MassElementAssembler.from_mesh(mesh)(batch_size=batch_size)
    val = M.to_dense().sum().item()
    assert _abs_err(val, 1.0) < 1e-10
