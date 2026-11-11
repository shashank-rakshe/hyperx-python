# Runge Kutta 


$$
\begin{array}{c|c}
        \textbf  c & \mathfrak A \\
        \hline
        &\textbf b^\top
        \end{array}
        \quad = \quad 
        \begin{array}{c|ccc}
        c_1 & a_{11} & \cdots & a_{1s}\\
        \vdots & \vdots & \ddots & \vdots \\
        c_s & a_{s1} & \cdots & a_{ss}\\\hline
        & b_1 & \cdots & b_s
        \end{array}
        \qquad 
        \textbf c, \textbf b \in \R^s,\mathfrak A\in  \R^{s\times s}
$$

$$
\textbf k_i =\textbf f(t+c_i\tau, \textbf u +\tau \sum_{j=1}^s a_{ij}\textbf k_j)\quad \Psi^{t,t+\tau}\textbf u = \textbf u+\tau\sum_{i=1}^s b_i \textbf  k_i
$$

$$
c_i = \sum_j a_{ij}
$$

## Explicit Runge Kutta

$$
a = \begin{bmatrix}
0 & \cdots &0& 0 \\
a_{21} & \cdots &0 & 0 \\
\vdots & \ddots & \vdots  &\vdots\\
a_{s1} & \cdots & a_{s{s-1}} &0
\end{bmatrix}
$$

$$
\frac{\partial u}{\partial t} = f(t, u)
$$

- $M\in\R^{n\times n}$
- $f(t,u)\in \R^ n$
- $u\in \R^n$ 

$$
M_{i+1}\textbf k_{i+1} = f\left(t + c_i\tau, u+\tau\sum_{j=1}^j \textbf k_i\right)
$$

$$
\text d u = \tau \sum_i{b_i}\textbf k_i
$$

## Implicit Linear Runge Kutta

$$
M(t) \frac{\partial u}{\partial t} = 
A(t) u + B(t)
$$

- $M\in \mathbb R^{n\times n}$ 
- $A\in \mathbb R^{n\times n}$
- $B\in \mathbb R^{n}$
- $u\in \mathbb R^n$


$$
\begin{bmatrix}
M_0 - A_0\tau a_{0,0}& - A_0\tau a_{0,1}&\cdots  & - A_{0}\tau a_{0,{n-1}}\\
-A_1\tau a_{1,0}& M_1-A_1\tau a_{1,1} & \cdots & - A_{1}\tau a_{1,{n-1}}\\
\vdots & \vdots &\ddots & \vdots \\
-A_{n-1}\tau a_{{n-1},0} & -A_{n-1}\tau a_{{n-1},1} & \cdots &  M_{n-1} - A_{n-1}\tau a_{n-1,n-1}
\end{bmatrix}
\begin{bmatrix}
\textbf k_0\\ \textbf k_1 \\\vdots \\\textbf k_{n-1}
\end{bmatrix}= 
\begin{bmatrix}
B_0 + A_0 u \\
B_1 + A_1 u \\
\vdots\\
B_{n-1} + A_{n-1} u 
\end{bmatrix}
$$

$$
\text d u = \tau \sum_i{b_i}\textbf k_i
$$

## Builtin

### Explicit Euler

$$
\begin{array}{c|c}
\textbf  c & \mathfrak A \\
\hline
&\textbf b^\top
\end{array}
= ~
\begin{array}{c|c}
0 & 0 \\\hline & 1
\end{array}
$$

$$
\Psi^{t,t+\tau}\textbf  u  \approx  \textbf  u  + \tau \textbf f(t,\textbf u)
$$



### Implicit Euler

$$
\begin{array}{c|c}
\textbf  c & \mathfrak A \\
\hline
&\textbf b^\top
\end{array}
= ~
\begin{array}{c|c}
1 & 1 \\\hline & 1
\end{array}
$$

$$
\Psi^{t,t+\tau}\textbf u \approx  \textbf w\quad \textbf w=\textbf u+\tau\textbf f(t+\tau,\textbf w)
$$



### Midpoint Euler

$$
\begin{array}{c|c}
\textbf  c & \mathfrak A \\
\hline
&\textbf b^\top
\end{array}
= ~
\begin{array}{c|c}
\frac{1}{2} & \frac{1}{2} \\\hline & 1
\end{array}
$$

$$
\Psi^{t,t+\tau}\textbf u \approx \textbf w\quad \textbf w = \textbf u +\tau \textbf f(t+\frac{\tau}{2},\frac{\textbf w+\textbf u}{2})
$$

