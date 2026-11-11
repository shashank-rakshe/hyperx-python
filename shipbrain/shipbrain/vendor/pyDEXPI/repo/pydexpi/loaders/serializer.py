from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any

from pydexpi.loaders import pickle_stamp
from pydexpi.pydexpi_classes import PyDexpiBaseModel


class Serializer(ABC):
    """Abstract class to (de)serialize DEXPI models."""

    @abstractmethod
    def save(self, model: PyDexpiBaseModel, dir_path: Path, filename: str) -> None:
        """Abstract method to save a DEXPI model to a file.

        Parameters
        ----------
        model : PyDexpiBaseModel
            DEXPI model that should be saved.
        dir_path : Path
            Directory where the DEXPI model should be saved.
        filename : str
            Filename for the saved DEXPI model.
        """

    @abstractmethod
    def load(self, dir_path: Path, filename: str) -> Any:
        """Abstract method to load a DEXPI PID data model from a P&ID file.

        Parameters
        ----------
        dir_path : Path
            Directory where the P&ID file is stored.
        filename : str
            Filename of the P&ID file.

        Returns
        -------
        DexpiModel
            Loaded DEXPI model.
        """


class PickleSerializer(Serializer):
    """Save a DEXPI model as a pickle, and load one these classes wrote.

    A pickle is Python-specific persistence, tied to the pyDEXPI classes that wrote it: it is not
    a format for exchange, and not one for keeping a model across pyDEXPI or DEXPI versions.
    Nothing converts it, so `load` refuses a pickle written by other classes rather than return a
    model that fails later (`pydexpi.loaders.pickle_stamp`).

    **Only load a pickle you trust.** Unpickling runs code the file names, so a pickle from
    somewhere else can do anything your Python process can. The check for other classes is no
    protection against that: it reads what the file says about itself.
    """

    def save(self, model: PyDexpiBaseModel, dir_path: Path, filename: str) -> None:
        """Saves a DEXPI model to pickle.

        The file is a plain pickle of *model*, which ``pickle.load`` reads as it is, followed by
        a stamp naming the DEXPI version, the pyDEXPI version and the classes it holds, which
        `load` checks.

        Parameters
        ----------
        model : PyDexpiBaseModel
            DEXPI model that should be saved.
        dir_path : Path
            Directory where the DEXPI model should be saved.
        filename : str
            Filename for the saved DEXPI model.
        """
        if not filename.endswith(".pkl"):
            filename += ".pkl"
        path = Path(dir_path) / filename

        path.write_bytes(pickle_stamp.dumps(model))

    def load(self, dir_path: Path, filename: str) -> Any:
        """Load a DEXPI model from a pickle file written by these pyDEXPI classes.

        Only for a file you trust: unpickling runs code the file names.

        Parameters
        ----------
        dir_path : Path
            Directory where the pickle file is stored.
        filename : str
            Filename of the pickle file.

        Returns
        -------
        DexpiModel
            Loaded DEXPI model.

        Raises
        ------
        IncompatiblePickleError
            If the pickle was written by other classes: its stamp names another DEXPI version, or
            a class that is gone or whose fields changed; or, for a pickle without a stamp (one
            an earlier pyDEXPI wrote), an object in it does not hold the fields of its class.
            Read the model from its DEXPI XML or JSON source instead, and pickle it again.
        """
        if not filename.endswith(".pkl"):
            filename += ".pkl"
        path = Path(dir_path) / filename

        return pickle_stamp.loads(path.read_bytes(), source=f"the pickle '{path}'")
