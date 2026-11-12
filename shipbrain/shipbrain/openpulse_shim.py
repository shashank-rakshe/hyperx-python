"""
Lets OpenPulse's numerical code (model, preprocessor, assembly, solvers) import and run without its desktop interface and without gmsh.

OpenPulse imports Qt (PySide6), molde / VTK and polars at package level for its windows, 3D views and spreadsheet import; none of
them is used by a calculation. This shim answers those imports with placeholder modules. gmsh gets a placeholder that refuses to
run: ShipBrain never uses gmsh (standing rule) - the mesh comes from ShipBrain's own 1D mesher (pulsation.own_mesh).
Install it only inside the separate process that runs OpenPulse (pulsation.py does that), never in the ShipBrain app itself.
"""
import importlib.machinery as _machinery
import sys
import types

PREFIXES = ('PySide6', 'shiboken6', 'molde', 'vtk', 'vtkmodules', 'pyqtdarktheme', 'qdarktheme', 'polars', 'fastexcel', 'pyarrow')


class _Any:
    def __init__(self, *a, **k):
        pass

    def __call__(self, *a, **k):
        return _Any()

    def __getattr__(self, n):
        if n.startswith('__'):
            raise AttributeError(n)
        return _Any()

    def __or__(self, o):
        return self

    __ror__ = __or__

    def __mro_entries__(self, bases):          # used as a base class (class Window(QWidget, ...)): drop it
        return ()

    @staticmethod
    def instance():                            # QApplication.instance(): no application window
        return None


class _Mod(types.ModuleType):
    def __getattr__(self, n):
        if n.startswith('__'):
            raise AttributeError(n)
        return _Any()


class _Blocked:
    def __getattr__(self, n):
        if n.startswith('__'):
            raise AttributeError(n)
        return _Blocked()

    def __or__(self, o):
        return self

    __ror__ = __or__

    def __call__(self, *a, **k):
        raise RuntimeError("gmsh is not used by ShipBrain: the mesh comes from ShipBrain's own 1D mesher")


class _GmshMod(types.ModuleType):
    def __getattr__(self, n):
        if n.startswith('__'):
            raise AttributeError(n)
        return _Blocked()


class _Finder:
    def find_spec(self, name, path=None, target=None):
        if name.split('.')[0] in PREFIXES:
            return _machinery.ModuleSpec(name, self)
        return None

    def create_module(self, spec):
        m = _Mod(spec.name)
        m.__path__ = []
        return m

    def exec_module(self, module):
        pass


def install():
    if not any(isinstance(f, _Finder) for f in sys.meta_path):
        sys.meta_path.insert(0, _Finder())
    sys.modules['gmsh'] = _GmshMod('gmsh')
