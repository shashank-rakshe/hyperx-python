import torch
from tensormesh.sparse import SparseMatrix



class ExplicitRungeKutta:
    r"""Base class for explicit Runge-Kutta schemes.

    Integrates the ODE

    .. math::

       \frac{\partial u}{\partial t} = f(t, u)

    with a user-supplied right-hand side :meth:`forward`. The scheme is
    encoded by its Butcher tableau ``(a, b)`` and a single :meth:`step`
    advances one time step.

    Parameters
    ----------
    a : torch.Tensor
        2D tensor of shape ``[s, s]``; should be lower triangular.

        .. math::

            a = \begin{bmatrix}
            0 & \cdots & 0 & 0 \\
            a_{21} & \cdots & 0 & 0 \\
            \vdots & \ddots & \vdots & \vdots \\
            a_{s1} & \cdots & a_{s,s-1} & 0
            \end{bmatrix}

    b : torch.Tensor
        1D tensor of shape ``[s]`` with :math:`\sum_i b_i = 1`.

    Examples
    --------
    Solve :math:`\frac{\mathrm{d}u}{\mathrm{d}t} = u` with explicit Euler:

    .. code-block:: python

        import torch
        from tensormesh.ode import ExplicitRungeKutta

        class MyExplicitRungeKutta(ExplicitRungeKutta):
            def forward(self, t, u):
                return u

        a = torch.zeros(1, 1)
        b = torch.ones(1)
        u0 = torch.rand(4)
        dt = 0.1
        ut = MyExplicitRungeKutta(a, b).step(0, u0, dt)
    """
    def __init__(self, a, b):
        assert a.dim() == 2, f"expected a to be 2D tensor, got {a.dim()}"
        assert b.dim() == 1, f"expected b to be 1D tensor, got {b.dim()}"
        assert a.shape[0] == a.shape[1], f"expected a to be square, got {a.shape}"
        assert a.shape[0] == b.shape[0], f"expected a and b to have same shape, got {a.shape} and {b.shape}"
        assert torch.allclose(b.sum(), torch.tensor(1.0, dtype=b.dtype)), \
            f"expected b to sum to 1, got {b.sum()}"
        assert torch.allclose(a.tril(), a), f"expected a to be lower triangular, got {a}"
        
        self.a = a
        self.b = b
        self.c = a.sum(dim=1)
        self.s = b.shape[0]
        self.__post_init__()

    def __post_init__(self):
        """Hook for subclasses to precompute values after ``__init__``.

        Default is a no-op. Subclasses that need to cache derived data
        from ``a`` / ``b`` may override.
        """
        pass


    def forward(self, t, u):
        r"""Right-hand side of the ODE.

        .. math::

           \frac{\partial u}{\partial t} = f(t, u)

        Default returns ``u`` (i.e. :math:`f(t, u) = u`); subclasses are
        expected to override.

        Parameters
        ----------
        t : float
            Current time.
        u : torch.Tensor
            State of shape ``[D]`` where ``D`` is the spatial dimension.

        Returns
        -------
        torch.Tensor
            :math:`f(t, u)`, same shape as ``u``.
        """
        return u

    def step(self, t0, u0, dt):
        r"""Advance one explicit Runge-Kutta step from ``t0`` to ``t0 + dt``.

        .. math::

            k_i &= f\!\left(t_0 + c_i\,\tau,\ u_0 + \tau \sum_{j=1}^{s} a_{ij}\,k_j\right) \\
            \Psi^{t_0,\,t_0 + \tau} u_0 &= u_0 + \tau \sum_{i=1}^{s} b_i\,k_i

        Parameters
        ----------
        t0 : float
            Initial time.
        u0 : torch.Tensor
            Initial state of shape ``[D]``.
        dt : float
            Time step :math:`\tau`.

        Returns
        -------
        torch.Tensor
            State at time :math:`t_0 + \mathrm{d}t`, same shape as ``u0``.
        """
        assert u0.dim() == 1, f"expected u0 to be 1D tensor, got {u0.dim()}"
        a = self.a.type(u0.dtype).to(u0.device)
        b = self.b.type(u0.dtype).to(u0.device)
        c = self.c.type(u0.dtype).to(u0.device)
        D = u0.shape[0]
        h = dt
        k = torch.zeros((self.s, D), dtype=u0.dtype, device=u0.device)
        for i in range(self.s):
            ci = c[i]

            if i == 0:
                f = self.forward(t0 + ci * h, u0)
            else:
                f = self.forward(t0 + ci * h, u0 + h * a[i, :i] @ k[:i])
            k[i] += f
        u = u0 + h * b @ k
        return u
    


