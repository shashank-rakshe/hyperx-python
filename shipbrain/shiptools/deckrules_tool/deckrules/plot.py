"""Review plots: rule output vs answer key, in ship coordinates."""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from shapely.geometry import Polygon, Point

TCOL = {6.0: '#c6dbef', 7.0: '#9ecae1', 8.0: '#a1d99b', 9.0: '#fdd0a2', 10.0: '#fdae6b', 12.0: '#fb6a4a'}


def _draw(ax, poly, **kw):
    for g in getattr(poly, 'geoms', [poly]):
        x, y = g.exterior.xy
        ax.plot(x, y, **kw)


def review(out, ref, path, title):
    fig, axs = plt.subplots(1, 2, figsize=(22, 13), sharex=True, sharey=True)
    for ax, src, lab in ((axs[0], 'out', 'RULE OUTPUT (drawing only)'), (axs[1], 'ref', 'SAMPLE XML (answer key)')):
        if src == 'out':
            for z in out['zones']:
                for g in getattr(z['poly'], 'geoms', [z['poly']]):
                    ax.fill(*g.exterior.xy, color=TCOL.get(z['t'], '#ddd'), alpha=.8, lw=0)
                    ax.plot(*g.exterior.xy, color='k', lw=.6)
                    c = g.representative_point()
                    ax.text(c.x, c.y, f"{z['t']:g}", fontsize=7, ha='center')
            for o in out['openings']:
                _draw(ax, o['poly'], color='r', lw=1)
            for m in out.get('members', []):
                ax.plot([m['a'][0], m['b'][0]], [m['a'][1], m['b'][1]], color=m.get('color', 'b'), lw=.8)
        else:
            for p in ref['plates']:
                g = Polygon(p['poly'])
                ax.fill(*g.exterior.xy, color=TCOL.get(p['t'], '#ddd'), alpha=.8, lw=0)
                ax.plot(*g.exterior.xy, color='k', lw=.6)
                c = g.representative_point()
                ax.text(c.x, c.y, f"{p['t']:g}", fontsize=7, ha='center')
            for h in ref['holes']:
                if len(h['poly']) > 3:
                    ax.plot(*Polygon(h['poly']).exterior.xy, color='r', lw=1)
                elif h['box']:
                    xs = [q[0] for q in h['poly']]
                    ys = [q[1] for q in h['poly']]
                    ax.plot(*Point((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2).buffer(h['box'][0] / 2).exterior.xy, color='r', lw=1)
            for s in ref['stiffeners']:
                ax.plot([s['a'][0], s['b'][0]], [s['a'][1], s['b'][1]], color=s.get('color', 'b'), lw=.8)
        ax.set_title(lab)
        ax.set_aspect('equal')
        ax.grid(alpha=.3)
    fig.suptitle(title)
    fig.tight_layout()
    fig.savefig(path, dpi=70)
    plt.close(fig)


def single(out, path, title):
    """review plot without an answer key: the extracted deck on its own (R-RV)."""
    fig, ax = plt.subplots(figsize=(13, 13))
    for z in out['zones']:
        for g in getattr(z['poly'], 'geoms', [z['poly']]):
            ax.fill(*g.exterior.xy, color=TCOL.get(z['t'], '#ddd'), alpha=.8, lw=0)
            ax.plot(*g.exterior.xy, color='k', lw=.6)
            c = g.representative_point()
            ax.text(c.x, c.y, f"{z['t']:g}", fontsize=7, ha='center')
    for o in out['openings']:
        _draw(ax, o['poly'], color='r', lw=1)
    for m in out.get('members', []):
        ax.plot([m['a'][0], m['b'][0]], [m['a'][1], m['b'][1]], color=m.get('color', 'b'), lw=.8)
    ax.plot(*out['footprint'].exterior.xy, color='g', lw=1.2)
    ax.set_aspect('equal')
    ax.grid(alpha=.3)
    ax.set_title(title)
    fig.tight_layout()
    fig.savefig(path, dpi=70)
    plt.close(fig)
