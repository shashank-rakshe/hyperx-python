import torch
from .explicit_rungekutta import ExplicitRungeKutta
from .implicit_linear_rungekutta import ImplicitLinearRungeKutta

class ExplicitEuler(ExplicitRungeKutta):
    r"""
    .. math::

        \begin{array}{c|c}
        \textbf{c} & \mathfrak{A} \\
        \hline
        & \textbf{b}^\top
        \end{array}
        =
        \begin{array}{c|c}
        0 & 0 \\
        \hline 
        & 1
        \end{array}

    .. math::

        \Psi^{t,t+\tau}\textbf{u} \approx \textbf{u} + \tau \textbf{f}(t,\textbf{u})

    Examples
    --------

    .. math::

        \frac{\text{d}u}{\text{d}t} = u 

    .. code-block:: python

        import torch
        from tensormesh.ode import ExplicitEuler

        class MyExplicitEuler(ExplicitEuler):
            def forward(self, t, u):
                return u

        u0 = torch.rand(4)
        dt = 0.1
        ut_gt = u0 + dt * u0
        ut_my = MyExplicitEuler().step(0, u0, dt)
        assert torch.allclose(ut_gt, ut_my)

    """
    def __init__(self):
        a = torch.zeros(1, 1)
        b = torch.ones(1)
        super().__init__(a, b)

class ImplicitLinearEuler(ImplicitLinearRungeKutta):
    r"""
    .. math::

        \begin{array}{c|c}
        \textbf{c} & \mathfrak{A} \\
        \hline
        & \textbf{b}^\top
        \end{array}
        =
        \begin{array}{c|c}
        1 & 1 \\ 
        \hline 
        & 1
        \end{array}

    .. math::

        \Psi^{t,t+\tau}\textbf{u} \approx \textbf{w}\quad \textbf{w}=\textbf{u}+\tau\textbf{f}(t+\tau,\textbf{w})

    Examples
    --------

    .. math::

        \frac{\text{d}u}{\text{d}t} = u 

    .. code-block:: python

        import torch
        from tensormesh.ode import ImplicitLinearEuler

        u0 = torch.rand(4).double()
        dt = 0.1
        ut_gt = (1/(1-dt)) * u0
        ut_my = ImplicitLinearEuler().step(0, u0, dt)
        assert torch.allclose(ut_gt, ut_my), f"expected {ut_gt}, got {ut_my}"

    """
    def __init__(self):
        a = torch.ones(1, 1)
        b = torch.ones(1)
        super().__init__(a, b)

class MidPointLinearEuler(ImplicitLinearRungeKutta):
    r"""
    .. math::

        \begin{array}{c|c}
        \textbf{c} & \mathfrak{A} \\
        \hline
        & \textbf{b}^\top
        \end{array}
        =
        \begin{array}{c|c}
        \frac{1}{2} & \frac{1}{2} \\ 
        \hline 
        & 1
        \end{array}

    .. math::

        \Psi^{t,t+\tau}\textbf{u} \approx \textbf{w}\quad \textbf{w} = \textbf{u} +\tau \textbf{f}\left(t+\frac{\tau}{2},\frac{\textbf{w}+\textbf{u}}{2}\right)

    Examples
    --------

    .. math::

        \frac{\text{d} u}{\text{d} t} = u 

    .. code-block:: python

        import torch
        from tensormesh.ode import MidPointLinearEuler

        u0 = torch.rand(4)
        dt = 0.1
        ut_gt = ((dt+2)/(2-dt)) * u0
        ut_my = MidPointLinearEuler().step(0, u0, dt)
        assert torch.allclose(ut_gt, ut_my), f"expected {ut_gt}, got {ut_my}"

    """
    def __init__(self):
        a = torch.ones(1, 1) / 2
        b = torch.ones(1)
        super().__init__(a, b)