import numpy as np
from sympy import Triangle
import torch 
import sys 
sys.path.append("../..")
from tensormesh import Mesh, MeshGen
from tensormesh import element_type2element, element_type2order
from tensormesh.element import Triangle, Quadrilateral
from tensormesh.mesh.adjacency import cum_dict, facet_connect


def get_element_adjacency(ele_ids, boundaries):
    """
        Parameters:
        -----------
            ele_ids: torch.Tensor [\int n_element*n_boundary_per_element]
            boundaries: torch.Tensor [\int n_element*n_boundary_per_element, n_boundary_basis]
    """
    assert ele_ids.dim() ==  1, f"ele_ids should be 1d, but got {ele_ids.dim()}"	
    assert boundaries.dim() == 2, f"boundaries should be 2d, but got {boundaries.dim()}"
    assert boundaries.shape[0] == ele_ids.shape[0], f"the first dimension of boundaries should be {ele_ids.shape[0]}, but got {boundaries.shape[0]}"
    boundaries= boundaries.reshape(-1, boundaries.shape[-1]) # [n_element * n_boundary_per_element, n_boundary_basis]
    # make sure the index is ascending, so it's unique
    boundaries= boundaries.sort(dim=-1).values # [n_element * n_boundary_per_element, n_boundary_basis] 
    # the count = 2 means the boundary is shared by two elements, otherwise the boundary is on the boundary of the domain
    unique_boundaries, inverse_indices, counts = boundaries.unique(dim=0, return_counts=True,  return_inverse=True) # [n_boundary_element, n_boundary_basis]
    assert counts.max() == 2, f"the maximum number of elements sharing a boundary is 2, but got {counts.max()}"
    valid_mask = counts == 2 # [n_boundary_element]
    # for the each element, which boundary is shared by two elements
    valid_mask = valid_mask[inverse_indices] # [n_element * n_boundary_per_element]
    ele_ids_bd = ele_ids    # [n_element * n_boundary_per_element]
    # only keep the shared boundary elements, but now it's shuffled
    ele_ids_bd = ele_ids_bd[valid_mask] # [n_shared_boundary * 2]
    # by sorting the inverse_indices, we can get the order like [0,0,1,1,2,2,3,3,...]
    sort_index=torch.argsort(inverse_indices[valid_mask]) # [n_shared_boundary * 2]
    # and then we can get the shared boundary elements in order 
    ele_ids_bd = ele_ids_bd[sort_index] # [n_shared_boundary * 2]
    edges     = ele_ids_bd.reshape(-1, 2).T # [2, n_shared_boundary]
    # add the reverse direction
    edges = torch.cat([edges, torch.stack([edges[1], edges[0]])], -1)

    return edges

def test_cum_dict():
    d = {"a": 1, "b": 2, "c": 3}
    cum_d = cum_dict(d)
    assert cum_d == {"a": (0, 1), "b": (1, 3), "c": (3, 6)}

    d = {"a":10}
    cum_d = cum_dict(d)
    assert cum_d == {"a": (0, 10)}

def test_facet_connect():
    mesh = Mesh.gen_rectangle(chara_length=0.5) 
    element = element_type2element(mesh.default_element_type)
    order   = element_type2order[mesh.default_element_type]
    facet   = element.get_facet(order)
    element_index = mesh.elements()
    global_facet = element_index[:,facet]
    global_facet = global_facet.reshape(-1, global_facet.shape[-1])
    element_ids = torch.arange(element_index.shape[0]).repeat_interleave(facet.shape[0])
    edges = facet_connect(global_facet, element_ids)

    edges_gt = get_element_adjacency(element_ids, 
                          global_facet)
    
    assert torch.all(edges == edges_gt), f"{edges} {edges_gt}"

def test_tri():
    mesh = Mesh.gen_rectangle(chara_length=0.5) 
    ele_adj = mesh.element_adjacency()
    

    n_element  = mesh.elements().shape[0]
    ele_adj_gt = torch.zeros((n_element, n_element), dtype=torch.float)
    for i in range(n_element):
        for j in range(i):
            triangle_i, triangle_j = set(mesh.elements()[i].tolist()), set(mesh.elements()[j].tolist())
            if len(triangle_i.intersection(triangle_j)) == 2:
                ele_adj_gt[i, j] = 1
                ele_adj_gt[j, i] = 1

    assert torch.all(ele_adj.to_dense() == ele_adj_gt), f"f{ele_adj.to_dense()} {ele_adj_gt}"

def test_mix_naive():
    elements = {
        "triangle": torch.tensor([[0, 1, 2],[3, 4, 5],[0, 1, 4]]),
        "quad": torch.tensor([[0, 2, 4, 3],[2,3,6,7]])
    }


    local_tri_facet  = Triangle.get_facet()
    local_quad_facet = Quadrilateral.get_facet()
    global_tri_facet = elements['triangle'][:, local_tri_facet]
    global_quad_facet= elements['quad'][:, local_quad_facet]
    global_tri_facet = global_tri_facet.reshape(-1, global_tri_facet.shape[-1])
    global_quad_facet= global_quad_facet.reshape(-1, global_quad_facet.shape[-1])
    tri_ele_ids      = torch.arange(0, elements['triangle'].shape[0]).repeat_interleave(local_tri_facet.shape[0])
    quad_ele_ids     = torch.arange(elements['triangle'].shape[0], elements['triangle'].shape[0]+elements['quad'].shape[0]).repeat_interleave(local_quad_facet.shape[0])
    ele_ids          = torch.cat([tri_ele_ids, quad_ele_ids], 0)
    facet            = torch.cat([global_tri_facet, global_quad_facet], 0)
    edges            = facet_connect(facet,ele_ids)
    

    n_element  = sum([i.shape[0] for i in elements.values()])
    ele_adj_gt = torch.zeros((n_element, n_element), dtype=torch.float)
    ptr_i = 0
    for elements_i in elements.values():
        for e_i in range(elements_i.shape[0]):
            nodes_i = set(elements_i[e_i].tolist())
            ptr_j = 0 
            for elements_j in elements.values():
                for e_j in range(elements_j.shape[0]):
                    nodes_j = set(elements_j[e_j].tolist())
                    if len(nodes_i.intersection(nodes_j)) == 2:
                        ele_adj_gt[ptr_i, ptr_j]+= 1
                    ptr_j += 1
                    # print(f"ptr_i {ptr_i} ptr_j {ptr_j}")
            ptr_i += 1

    assert True

def test_mix():
    mesh_gen = MeshGen(element_type=None, chara_length=0.5, order=1)
    mesh_gen.add_rectangle(0,0,0.5,1, element="tri")
    mesh_gen.add_rectangle(0.5,0,0.5,1, element="quad")
    mesh_gen.remove_circle(0.5,0.5,0.1)
    mesh = mesh_gen.gen()
    ele_adj = mesh.element_adjacency()

    local_tri_facet  = Triangle.get_facet()
    local_quad_facet = Quadrilateral.get_facet()
    global_tri_facet = mesh.elements()['triangle'][:, local_tri_facet]
    global_quad_facet= mesh.elements()['quad'][:, local_quad_facet]
    global_tri_facet = global_tri_facet.reshape(-1, global_tri_facet.shape[-1])
    global_quad_facet= global_quad_facet.reshape(-1, global_quad_facet.shape[-1])
    tri_ele_ids      = torch.arange(0, 
                        mesh.elements()['triangle'].shape[0]
                        ).repeat_interleave(local_tri_facet.shape[0])
    quad_ele_ids     = torch.arange(
                        mesh.elements()['triangle'].shape[0], 
                        mesh.elements()['triangle'].shape[0]+\
                        mesh.elements()['quad'].shape[0]
                        ).repeat_interleave(local_quad_facet.shape[0])
    ele_ids          = torch.cat([tri_ele_ids, quad_ele_ids], 0)
    facet            = torch.cat([global_tri_facet, global_quad_facet], 0)
    edges            = facet_connect(facet,ele_ids)
    
    n_element  = sum([i.shape[0] for i in mesh.elements().values()])
    ele_adj_gt = torch.zeros((n_element, n_element), dtype=torch.float)
    ptr_i = 0
    for elements_i in mesh.elements().values():
        for e_i in range(elements_i.shape[0]):
            e = elements_i[e_i]
            if len(e) == 4:
                f = e[Quadrilateral.get_facet()] # [4, 2]
            else:
                f = e[Triangle.get_facet()] # [3, 2]
            facet_i = set([tuple(sorted(i.tolist())) for i in f])
            ptr_j = 0 
            for elements_j in mesh.elements().values():
                for e_j in range(elements_j.shape[0]):
                    if e_i == e_j:
                        ptr_j += 1
                        continue
                    e = elements_j[e_j]
                    if len(e) == 4:
                        f = e[Quadrilateral.get_facet()]
                    else:
                        f = e[Triangle.get_facet()]
                    facet_j = set([tuple(sorted(i.tolist())) for i in f]) # [3, 2]
                   
                    if len(facet_i.intersection(facet_j)) > 0:
                        ele_adj_gt[ptr_i, ptr_j] = 1
                    ptr_j += 1
                    # print(f"ptr_i {ptr_i} ptr_j {ptr_j}")
            ptr_i += 1  
    assert torch.all(ele_adj.to_dense() == ele_adj_gt), f"f{ele_adj.to_dense()} {ele_adj_gt}"