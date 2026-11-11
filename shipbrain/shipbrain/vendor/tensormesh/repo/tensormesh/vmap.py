import torch
if torch.__version__ >= '2.0.0':
    from torch import vmap
elif torch.__version__ >= '1.8.0':
    from functorch import vmap
else:
    raise ImportError("torch version must be >= 1.8.0 to use vmap functionality")
