"""
Distributed Mesh for multi-GPU FEM assembly.

Partitions a mesh into submeshes and assigns each to a device (GPU or CPU).
"""

import torch
from typing import List, Optional, Union

from ..mesh import Mesh
from ..mesh.partition import partition_mesh


class DistributedMesh:
    """Partitioned mesh for multi-GPU parallel assembly.

    Wraps ``partition_mesh`` to split a global mesh into submeshes,
    each assigned to a separate device. Each submesh stores an ``orig_nid``
    mapping (local node index → global node index) in ``point_data``.

    Parameters
    ----------
    mesh : Mesh
        Global mesh (typically on CPU).
    num_partitions : int, optional
        Number of partitions. Defaults to ``torch.cuda.device_count()``,
        or 2 if no CUDA devices are available.
    method : str, optional
        Partitioning method: ``'coordinate'`` (default, fast RCB),
        ``'spectral'``, or ``'metis'``.
    devices : list of torch.device, optional
        Devices to assign partitions to. Defaults to ``cuda:0, cuda:1, ...``
        or ``cpu`` if CUDA is unavailable.

    Examples
    --------
    >>> mesh = tm.Mesh.gen_rectangle(chara_length=0.05)
    >>> dmesh = DistributedMesh(mesh, num_partitions=4)
    >>> print(dmesh.num_partitions, dmesh.n_global_points)
    """

    def __init__(
        self,
        mesh: Mesh,
        num_partitions: Optional[int] = None,
        method: str = 'coordinate',
        devices: Optional[List[torch.device]] = None,
    ):
        # Determine number of partitions
        if num_partitions is None:
            num_partitions = torch.cuda.device_count() if torch.cuda.is_available() else 2

        # Determine devices
        if devices is None:
            if torch.cuda.is_available() and num_partitions <= torch.cuda.device_count():
                devices = [torch.device(f'cuda:{i}') for i in range(num_partitions)]
            else:
                devices = [torch.device('cpu')] * num_partitions

        assert len(devices) == num_partitions, \
            f"Number of devices ({len(devices)}) must match num_partitions ({num_partitions})"

        self.global_mesh = mesh
        self.num_partitions = num_partitions
        self.method = method
        self.devices = devices
        self.n_global_points = mesh.n_points

        # Partition the mesh
        self.submeshes: List[Optional[Mesh]] = partition_mesh(
            mesh, num_partitions, method=method
        )

    def __len__(self) -> int:
        return self.num_partitions

    def __getitem__(self, idx: int) -> Optional[Mesh]:
        return self.submeshes[idx]

    def __repr__(self) -> str:
        partition_sizes = []
        for s in self.submeshes:
            partition_sizes.append(s.n_points if s is not None else 0)
        return (
            f"DistributedMesh(partitions={self.num_partitions}, "
            f"global_points={self.n_global_points}, "
            f"partition_sizes={partition_sizes}, "
            f"devices={[str(d) for d in self.devices]})"
        )
