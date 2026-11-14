import torch 
import sys 
import math 
import random
from tqdm import tqdm
sys.path.append("../..")
from tensormesh.element.polynomial import Polynomial, Polynomials

def call_polynomial(x:torch.Tensor,
                    coef:torch.Tensor,
                    exp:torch.Tensor)->torch.Tensor:
    """
    x: torch.tensor
        [n_vars]
    coef: torch.tensor
        [n_terms]
    exp: torch.tensor
        [n_vars, n_terms]
    """
    n_vars, n_terms  = exp.shape 
    _sum = 0.0
    for i in range(n_terms):
        _term = 1.0
        for j in range(n_vars):
            _term  *= x[j] ** exp[j, i]
        _sum += _term * coef[i]  
    return _sum

def call_polynomials(x:torch.Tensor, 
                     coef:torch.Tensor, 
                     exp:torch.Tensor
                     )->torch.Tensor:
    """
    x: torch.tensor
        [*n_polys, n_vars]
    coef: torch.tensor
        [*n_polys, n_terms]
    exp: torch.tensor
        [*n_polys, n_vars, n_terms]
    """
    *n_polys, n_vars, n_terms = exp.shape 
    x = x.reshape(-1, n_vars)
    coef = coef.reshape(-1, n_terms)
    exp = exp.reshape(-1, n_vars, n_terms)
    return torch.vmap(call_polynomial)(x, coef, exp).reshape(*n_polys)

def test_polynomial():
    exp = torch.tensor([[1, 2, 3], [2, 1, 0]]) # [n_vars(2), n_terms(3)]
    coef = torch.tensor([1, 1, 1])             # [n_terms(3)]
    poly = Polynomial(exp, coef)
    x = torch.tensor([2, 3])

    assert poly(x).item() == 38

    print(poly)

def test_polynomial_vector():
    exp  = torch.tensor([[1, 2, 3], [2, 1, 0]]) # [n_vars(2), n_terms(3)]
    coef = torch.tensor([1, 1, 1])             # [n_terms(3)]

    exp  = exp.repeat(2, 1, 1)
    coef = coef.repeat(2, 1)

    polys = Polynomials(exp, coef)

    x = torch.tensor([2, 3])
    x = x.repeat(2, 1)

    y = polys(x)
    assert y.dim() == 1
    assert y.shape[0] == 2
    assert (y == 38).all()

    print(polys)
    

def test_polynomial_matrix():
    exp  = torch.tensor([[1, 2, 3], [2, 1, 0]]) # [n_vars(2), n_terms(3)]
    coef = torch.tensor([1, 1, 1])             # [n_terms(3)]

    exp  = exp[None, None, :, :].repeat(3, 2, 1, 1)
    coef = coef[None, None, :].repeat(3, 2, 1)

    polys = Polynomials(exp, coef)

    x = torch.tensor([2, 3])
    x = x[None, None, :].repeat(3, 2, 1)

    y = polys(x)
    assert y.dim() == 2
    assert y.shape == (3, 2)
    assert (y == 38).all()

    print(polys)

def test_polynomial_tensor():

    exp  = torch.tensor([[1, 2, 3], [2, 1, 0]])
    coef = torch.tensor([1, 1, 1])

    exp  = exp[None, None, None, :, :].repeat(3, 2, 2, 1, 1)
    coef = coef[None, None, None, :].repeat(3, 2, 2, 1)

    polys = Polynomials(exp, coef)

    x = torch.tensor([2, 3])
    x = x[None, None, None, :].repeat(3, 2, 2, 1)

    y = polys(x)

    assert y.dim() == 3
    assert y.shape == (3, 2, 2)
    assert (y == 38).all()

    print(polys)

def test_deriv():
    exp = torch.tensor([[0, 1, 2, 3], [0, 2, 1, 0]]) # [n_vars(2), n_terms(3)]
    coef = torch.tensor([1, 1, 1, 1])             # [n_terms(3)]
    poly = Polynomial(exp.double(), coef.double())
    x = torch.tensor([2, 3])

    deriv = poly.deriv(0)
    assert deriv._coef.allclose(torch.tensor([0,1,2,3]).double())
    assert deriv._exp.allclose(torch.tensor([[0,0, 1, 2], [0,2, 1, 0]]).double())
  
    print(deriv)

def test_grad():
    exp = torch.tensor([[1, 2, 3], [2, 1, 0]]) # [n_vars(2), n_terms(3)]
    coef = torch.tensor([1, 1, 1])             # [n_terms(3)]
    poly = Polynomial(exp.double(), coef.double())

    grad = poly.grad()

    assert grad._coef.allclose(torch.tensor([[1, 2, 3],[2, 1, 0]]).double())
    assert grad._exp.allclose(torch.tensor([[[0, 1, 2], [2, 1, 0]], 
                                            [[1, 2, 3], [1, 0, 0]]]).double())

    print(grad)

def test_lin_exp():
    n_vars = 2
    polys = Polynomial.lin_exp(n_vars)

    assert isinstance(polys, Polynomial), f"Expected Polynomial, got {type(polys)}"
    assert polys.n_vars == n_vars 
    assert polys.n_terms == n_vars + 1

    print(polys)

def test_tens_exp():
    n_vars = 2
    dim    = 2
    polys = Polynomial.tens_exp(n_vars, dim)

    assert isinstance(polys, Polynomial), f"Expected Polynomial, got {type(polys)}"
    assert polys.n_vars == n_vars 
    assert polys.n_terms == (dim+1) ** n_vars
   
    print(polys)

def test_polynomial_rand():
    for n_vars in range(1, 10):
        for n_terms in range(1, 10):
            exp =  torch.rand(n_vars, n_terms) * 10
            coef = torch.rand(n_terms) 
            poly = Polynomial(exp.double(), coef.double())

            x = torch.rand(n_vars).double()
            y = poly(x)

            assert y.allclose(call_polynomial(x, coef, exp)), f"Expected {call_polynomial(x, coef, exp)}, got {y}"
            
def test_polynomials_rand():
    for _ in range(10):
        dim     = random.randint(1, 5)
        n_polys = [random.randint(1, 20) for _ in range(dim)]
        n_vars  = random.randint(1, 10)
        n_terms = random.randint(1, 20)
        exp     = torch.rand(*n_polys, n_vars, n_terms) * 10 
        coef    = torch.rand(*n_polys, n_terms) 
        polys = Polynomials(exp.double(), coef.double())

        x       = torch.rand(*n_polys, n_vars).double()

        y = polys(x)

        assert y.allclose(call_polynomials(x, coef, exp)), f"Expected {call_polynomials(x, coef, exp)}, got {y}"
