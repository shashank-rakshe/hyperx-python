"""Generation history to store the generation steps of a generator."""

import json
from dataclasses import dataclass, field

from pydexpi.syndata.generator_step import GeneratorStepDict, WriteableStep


@dataclass
class GenerationHistory:
    """Class to store the generation history of a generator.

    Attributes
    ----------
    history : list[GeneratorStepDict]
        The history of the generator.
    """

    history: list[GeneratorStepDict] = field(default_factory=list)

    def write_step(self, step: WriteableStep) -> None:
        """Write a step to the history.

        Parameters
        ----------
        step : WriteableStep
            The step to write to the history.

        Returns
        -------
        None
        """
        self.history.append(step.to_dict())


def save_generation_history_as_json(generation_history: GenerationHistory, path: str) -> None:
    """Save the history as a json file.

    Parameters
    ----------
    generation_history : GenerationHistory
        The history to save.
    path : str
        The path to save the json file to.
    """

    with open(path, "w", encoding="utf-8") as f:
        json.dump(generation_history.history, f, indent=4)


def load_generation_history_from_json(path: str) -> list[GeneratorStepDict]:
    """Load the history from a json file.

    Parameters
    ----------
    path : str
        The path to load the json file from.

    Returns
    -------
    list[GeneratorStepDict]
        The loaded history.
    """
    with open(path, encoding="utf-8") as f:
        history = json.load(f)
    return history
