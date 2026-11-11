import torch
import unittest
from tensormesh.sparse import SparseMatrix, nonlinear_solve

class TestNonLinearSolve(unittest.TestCase):
    def test_scalar_cubic(self):
        """
        Test solving u^3 = theta for u.
        F(u, theta) = u^3 - theta = 0
        J(u) = 3u^2 (diagonal)
        """
        torch.set_default_dtype(torch.float64)
        N = 10
        device = "cpu"
        
        # Target parameter
        theta = (torch.rand(N, device=device) + 0.1).requires_grad_(True) # Ensure positive
        
        def f(u, theta):
            return u**3 - theta
            
        def j(u, theta):
            # J is diagonal with entries 3*u^2
            diag = 3 * u**2
            # Create diagonal sparse matrix
            indices = torch.arange(N, device=device)
            row = indices
            col = indices
            return SparseMatrix(diag, row, col, (N, N))
            
        u0 = torch.ones(N, device=device)
        
        # 1. Test Forward
        u = nonlinear_solve(f, j, u0, (theta,), tol=1e-8, verbose=True)
        
        # Check residual
        res = f(u, theta)
        print(f"Final residual: {torch.norm(res)}")
        self.assertTrue(torch.norm(res) < 1e-6)
        
        # Check solution value
        expected_u = theta**(1.0/3.0)
        self.assertTrue(torch.allclose(u, expected_u, atol=1e-5))
        
        # 2. Test Backward
        loss = u.sum()
        loss.backward()
        
        # Analytical gradient:
        # u = theta^(1/3)
        # du/dtheta = 1/3 * theta^(-2/3)
        expected_grad = (1.0/3.0) * theta**(-2.0/3.0)
        
        self.assertTrue(torch.allclose(theta.grad, expected_grad, atol=1e-5))
        torch.set_default_dtype(torch.float32)

    def test_2x2_system(self):
        """
        Solve system:
        u1^2 + u2 = theta1
        u1 + u2^2 = theta2
        """
        torch.set_default_dtype(torch.float64)
        # We process a batch of 1 (or N independent systems, here just 1 for simplicity)
        theta1 = torch.tensor([4.0], requires_grad=True)
        theta2 = torch.tensor([4.0], requires_grad=True)
        
        # Solution for theta1=4, theta2=4 should be symmetric?
        # u^2 + u = 4 => u^2 + u - 4 = 0 => u = (-1 + sqrt(17))/2 approx 1.56
        
        def f(u, t1, t2):
            # u shape [2]
            u1, u2 = u[0], u[1]
            r1 = u1**2 + u2 - t1
            r2 = u1 + u2**2 - t2
            return torch.stack([r1, r2]).flatten() # Ensure 1D [2]
            
        def j(u, t1, t2):
            u1, u2 = u[0], u[1]
            # J = [[2u1, 1], [1, 2u2]]
            vals = torch.stack([2*u1, torch.tensor(1.0), torch.tensor(1.0), 2*u2])
            rows = torch.tensor([0, 0, 1, 1])
            cols = torch.tensor([0, 1, 0, 1])
            return SparseMatrix(vals, rows, cols, (2, 2))
            
        u0 = torch.tensor([1.0, 1.0])
        
        u = nonlinear_solve(f, j, u0, (theta1, theta2), tol=1e-8)
        
        # Check forward
        self.assertTrue(torch.norm(f(u, theta1, theta2)) < 1e-6)
        
        # Backward
        loss = u.sum()
        loss.backward()
        
        # Check gradients exist
        self.assertIsNotNone(theta1.grad)
        self.assertIsNotNone(theta2.grad)
        
        # We can verify by finite difference locally?
        # Or just trust logic if scalar test passed. 
        # But good to check non-diagonal J.
        
        # Verify gradient values roughly
        # J = [[3.12, 1], [1, 3.12]] approx (u approx 1.56)
        # J^-1 approx ...
        # dL/du = [1, 1]
        # J^T lambda = [1, 1]
        # lambda = J^-T [1, 1]
        # dL/dtheta = -lambda^T * dF/dtheta
        # dF/dt1 = [-1, 0], dF/dt2 = [0, -1]
        # So dL/dt1 = lambda[0], dL/dt2 = lambda[1]
        
        # Calculate manually
        u_val = u.detach()
        u1, u2 = u_val[0], u_val[1]
        J_dense = torch.tensor([[2*u1, 1], [1, 2*u2]])
        inv_JT = torch.linalg.inv(J_dense.T)
        lam = inv_JT @ torch.tensor([1.0, 1.0])
        
        self.assertTrue(torch.allclose(theta1.grad, lam[0], atol=1e-4))
        self.assertTrue(torch.allclose(theta2.grad, lam[1], atol=1e-4))
        torch.set_default_dtype(torch.float32)

if __name__ == '__main__':
    unittest.main()

