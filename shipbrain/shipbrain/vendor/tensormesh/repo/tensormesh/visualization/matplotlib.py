
from scipy.__config__ import show
import torch 
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
from scipy.interpolate import griddata
import matplotlib.tri as tri
import matplotlib.patches as patches
from matplotlib.collections import PatchCollection
from matplotlib import animation
from scipy.spatial import ConvexHull


def plot_mesh(mesh, save_path=None):
    elements = mesh.elements()
    points   = mesh.points.cpu().numpy()

    assert points.shape[1] == 2, f"points must be 2D, but got {points.shape}"

    fig, ax = plt.subplots(figsize=(8, 8))

    def draw_elements(elements):
        if elements.shape[1] == 3: # tri
            ax.triplot(points[:,0], points[:,1], elements, color='k', linewidth=0.5)
        elif elements.shape[1] == 4: # quad
            polygons = [patches.Polygon(points[element], closed=True, fill=False, edgecolor='k', linewidth=0.5) for element in elements]
            polygons = PatchCollection(polygons, match_original=True)
            ax.add_collection(polygons)
        elif elements.shape[1] == 6: # tri6
            order = np.array([0, 3, 1, 4, 2, 5])
            polygons = [patches.Polygon(points[element[order]], closed=True, fill=False, edgecolor='k', linewidth=0.5) for element in elements]
            polygons = PatchCollection(polygons, match_original=True)
            ax.add_collection(polygons)
        elif elements.shape[1] == 9: # quad9 
            order = np.array([0, 4, 1, 5, 2, 6, 3, 7])
            polygons = [patches.Polygon(points[element[order]], closed=True, fill=False, edgecolor='k', linewidth=0.5) for element in elements]
            polygons = PatchCollection(polygons, match_original=True)
            ax.add_collection(polygons)
        else:
            raise NotImplementedError(f"element type {elements.shape[1]} is not supported")
   
    if isinstance(elements, torch.Tensor):
        elements = elements.detach().cpu().numpy()
        draw_elements(elements)
    elif isinstance(elements, dict):
        for value in elements.values():
            draw_elements(value.detach().cpu().numpy())
    else:
        raise NotImplementedError(f"elements type {type(elements)} is not supported")
    
    ax.set_aspect('equal')
    ax.axis('off')
    if save_path is None:
        plt.show()
    else:
        fig.savefig(save_path, dpi=300)
           
def plot_value(kwargs, mesh, save_path=None, dt=None, show_mesh=False, fix_clim=False, cmap='viridis'):
    """
        Parameters:
        -----------
            kwargs: dict
                the key is the name of the variable, the value is the value of the variable
            mesh: tensormesh.mesh.mesh.Mesh
            cmap: str
                colormap to use (default: viridis)
    """
    points = mesh.points
    elements = mesh.elements()
   
    ncols = len(kwargs.keys())
    width = mesh.points[:,0].max() - mesh.points[:,0].min()
    height = mesh.points[:,1].max() - mesh.points[:,1].min()
    ratio  = (width / height).item()
    fig, ax = plt.subplots(1, ncols, figsize=(5*ncols * ratio, 5))
    key, value = next(iter(kwargs.items()))
    if isinstance(points, torch.Tensor):
        points = points.detach().cpu().numpy()
    if isinstance(elements, torch.Tensor):
        elements = elements.detach().cpu().numpy()
    if not isinstance(ax, np.ndarray):
        ax = [ax]
    if isinstance(value, (torch.Tensor, np.ndarray)):      
        if save_path is None:
            save_path = 'mesh.png'
        for i, (key, value) in enumerate(kwargs.items()):
            img, cb = draw_mesh(points, elements, value, ax=ax[i], show_colorbar=True, show_mesh=show_mesh, cmap=cmap)
            ax[i].set_title(key)
        fig.savefig(save_path, dpi=300)
    elif isinstance(value, (list, tuple)):
        if save_path is None:
            save_path = 'mesh.mp4'
        if fix_clim:
            vmin = min([v.min() for v in value])
            vmax = max([v.max() for v in value])
        cbs = []
        imgs = []
        for i, (key, value) in enumerate(kwargs.items()):
            img, cb = draw_mesh(points, elements, value[0], ax=ax[i], show_colorbar=True, show_mesh=show_mesh, cmap=cmap)
            if fix_clim:
                img.set_clim(vmin, vmax)
                cb.update_normal(img)
            ax[i].set_title(key)
            cbs.append(cb)
            imgs.append(img)
        if dt is not None:
            fig.suptitle(f"t={0*dt:7.5f}")
        else:
            fig.suptitle(f"Frame:{0:5d}")
        def update(frame):
            for i, (key, value) in enumerate(kwargs.items()):
                v = value[frame].detach().cpu().numpy() if isinstance(value[frame], torch.Tensor) else value[frame]
                if not fix_clim:   
                    imgs[i].set_clim(v.min(), v.max())
                imgs[i].set_array(v)
                if not fix_clim:
                    cbs[i].update_normal(imgs[i])
            if dt is not None:
                fig.suptitle(f"t={frame*dt:7.5f}")
            else:
                fig.suptitle(f"Frame:{frame:5d}")
            return imgs
        anim = FuncAnimation(fig, update, frames=len(value), interval=100)
        anim.save(save_path, fps=10, dpi=150)


class StreamPlotter:
    def __init__(self, nrows=1, ncols=1, width=5, height=5, filename=None, cmap='viridis'):
        if filename is None:
            filename = "stream_plotter.mp4"
        self.cmap = cmap
        fig, axes = plt.subplots(nrows, ncols, figsize=(width*ncols, height*nrows)) 
        self.fig = fig 
        self.axes = axes
        self.filename = filename
        self.ax2img = {}
        self.ax2cb = {}

    def __enter__(self):
        # Set up the writer
        self.writer = animation.writers['ffmpeg'](fps=10, metadata=dict(artist='TensorMesh'), bitrate=1800)
        self.writer.setup(self.fig, self.filename, dpi=100)
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        # Finish the animation
        self.writer.finish()
        if exc_type is not None:
            print(exc_type, exc_value, traceback)
            return False

    def grab_frame(self, **savefig_kwargs):
        # Grab the current frame
        self.writer.grab_frame(**savefig_kwargs)

    def update(self):
        self.grab_frame()

    def draw_mesh(self, mesh, value, ax=None, show_colorbar=True, title=None, update=True, 
                  show_mesh=False, umin=None, umax=None, cmap=None):
        if cmap is None:
            cmap = self.cmap
        if ax is None:
            assert not isinstance(self.axes, np.ndarray), "ax must be specified when there are multiple axes"
            ax = self.axes 
        if ax in self.ax2img:
            img = self.ax2img[ax]
            if isinstance(value, torch.Tensor):
                value = value.detach().cpu().numpy()
            img.set_array(value)
            if umin is not None and umax is not None:
                img.set_clim(umin, umax)
            if show_colorbar and ax in self.ax2cb:
                self.ax2cb[ax].update_normal(img)
        else:
            img = draw_mesh(mesh.points, 
                    mesh.elements(), 
                    value, 
                    ax=ax, 
                    show_colorbar=show_colorbar, 
                    show_mesh=show_mesh,
                    cmap=cmap)
            if show_colorbar:
                img, cb = img
                self.ax2img[ax] = img
                self.ax2cb[ax] = cb
                if umin is not None and umax is not None:
                    img.set_clim(umin, umax)
                    cb.update_normal(img)
            else:
                self.ax2img[ax] = img
                if umin is not None and umax is not None:
                    img.set_clim(umin, umax)

        if title is not None:
            ax.set_title(title)
        if update:
            self.grab_frame()

def draw_mesh(points, elements, value, ax=None, show_colorbar=True, show_mesh=False, cmap='viridis'):
    """
    Draw mesh with field values.
    
    Parameters:
    -----------
        points: torch.Tensor [n_point, n_dim]
            the coordinates of the points
        elements: torch.Tensor [n_element, n_basis]
            the indices of the element corners
        value: torch.Tensor [n_point]
            the value of the points
        ax: matplotlib.axes.Axes
            the axes to plot on (if None, use plt.gca())
        show_colorbar: bool
            whether to show the colorbar (default: True)
        show_mesh: bool
            whether to show mesh lines (default: False)
        cmap: str
            colormap to use (default: viridis)
    """
    assert points.shape[1] == 2, f"points must be 2D, but got {points.shape}"

    if ax is None:
        ax = plt.gca()

    if isinstance(points, torch.Tensor):
        points = points.detach().cpu().numpy()
    if isinstance(elements, torch.Tensor):
        elements = elements.detach().cpu().numpy()
    if isinstance(value, torch.Tensor):
        value = value.detach().cpu().numpy()

    colormap = plt.get_cmap(cmap)

    if elements.shape[1] == 3:  # tri
        triang = tri.Triangulation(points[:, 0], points[:, 1], elements)
        img = ax.tripcolor(triang, value, cmap=colormap, shading='gouraud')
        if show_mesh:
            ax.triplot(triang, color='k', linewidth=0.5)
    elif elements.shape[1] == 4:  # quad 
        triang = tri.Triangulation(points[:, 0], points[:, 1], 
                                   np.concatenate([elements[:,(0,1,2)], elements[:,(0,2,3)]], 0))
        img = ax.tripcolor(triang, value, cmap=colormap, shading='gouraud')
        if show_mesh:
            polygons = [patches.Polygon(points[element], closed=True, fill=False, 
                                       edgecolor='k', linewidth=0.5) for element in elements]
            polygons = PatchCollection(polygons, match_original=True)
            ax.add_collection(polygons)
    else:
        xmin, xmax = points[:, 0].min(), points[:, 0].max()
        ymin, ymax = points[:, 1].min(), points[:, 1].max()
        x_grid, y_grid = np.mgrid[xmin:xmax:100j, ymin:ymax:100j]
        z_grid = griddata(points, value, (x_grid, y_grid), method='linear')
        img = ax.imshow(z_grid.T, extent=(xmin, xmax, ymin, ymax), origin='lower', 
                       cmap=colormap, aspect='auto')

        if show_mesh:
            polygons = [patches.Polygon(points[element], closed=True, fill=False, 
                                       edgecolor='k', linewidth=0.5) for element in elements]
            polygons = PatchCollection(polygons, match_original=True)
            ax.add_collection(polygons)

    ax.set_aspect('equal')
    ax.axis('off')

    if show_colorbar:
        cb = plt.colorbar(img, ax=ax)
        return img, cb
    
    return img


