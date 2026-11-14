"""This module contains the pattern distribution as used by the generator
and generator function of the synthetic data framework."""

import json
import os
from pathlib import Path
from random import choices, randint

from pydexpi.syndata.pattern import Pattern


class PatternDistribution:
    """A PatternDistribution is a collection of Patterns that share the same
    properties with regards to the generation logic. The patterns are grouped
    for the sake of randomness and for structure. The grouping is based on
    similarity mainly regarding:
        - Outside connectors.
        - Transition logic.
        - Conceptual similarity (e.g. distillation equipment).

    Note: Pattern labels in a distribution are exclusive

    Attributes
    ----------
    name : str
        The name of the pattern distribution, preferably an umbrella term for
        the patterns contained.
    patterns : dict[str, Pattern]
        A dictionary containing the distributions patterns as values, with the
        pattern labels as keys.
    probabilities : dict[str, float]
        A dictionary containing the distributions probabilities as values, with
        the pattern labels as keys.
    connector_labels : list[str]
        The labels of the connectors that each of the patterns in the
        distribution must contain.

    """

    def __init__(
        self,
        name: str,
        patterns: dict[str, Pattern],
        probabilities: dict[str, float],
        connector_labels: set[str],
    ) -> None:
        """Constructor of a pattern distribution. Name, distribution, and
        connector_labels stored as attributes. Each pattern in the distribution
        is validated against the connector labels.

        Parameters
        ----------
        name : str
            The name of the distribution.
        patterns : dict[str, Pattern]
            A dictionary containing the distributions patterns as values, with
            the pattern labels as keys.
        probabilities : dict[str, float]
            A dictionary containing the distributions probabilities as values,
            with the pattern labels as keys.
        connector_labels : set[str]
            The labels of the connectors that each pattern needs to have to be
            part of the distribution.

        Raises
        ------
        ValueError
            In case a pattern of the distribution does not fulfil the connector
            requirements.
        """
        self.connector_labels = set(connector_labels)
        self.name = name
        if set(patterns.keys()) != set(probabilities.keys()):
            msg = "Dictionaries for patterns and probabilities must have the same keys."
            raise ValueError(msg)
        for the_label, the_pattern in patterns.items():
            if the_pattern.label != the_label:
                msg = "Pattern labels dont match label keys"
                raise ValueError(msg)
            if not self.check_pattern_compatibility(the_pattern):
                raise ValueError("Not all patterns in passed distribution compatible")
            if probabilities[the_label] < 0:
                raise ValueError("Probabilities may not be negative.")
        self.patterns = patterns
        self.probabilities = probabilities

    def add_pattern(self, pattern: Pattern, probability: float, normalize: bool = True) -> None:
        """
        Add a pattern to the distribution with a specified probability.

        Parameters
        ----------
        name: str
            Name of the new patterndistribution
        pattern : Pattern
            The pattern to be added to the distribution.
        probability : float
            The probability associated with the pattern. Must be between 0 and 1.
        normalize: bool
            Wherther the probabilities should be normalized after adding the pattern.

        Raises
        ------
        ValueError
            If the pattern does not contain all required connectors.
            If the pattern is already part of the distribution.
            If the probability is not between 0 and 1.
        """
        if not self.check_pattern_compatibility(pattern):
            msg = f"Pattern {pattern} does not contain all required connectors to be added to distribution."
            raise ValueError(msg)
        if pattern.label in self.labels():
            raise ValueError(f"Pattern with label {pattern.label} already part of distribution.")

        self.patterns[pattern.label] = pattern
        self.probabilities[pattern.label] = probability
        if normalize:
            self.normalize_probabilities()

    def normalize_probabilities(self) -> None:
        """
        Normalize the probabilities in the distribution so they sum to 1.

        This method modifies the probabilities in the distribution such that
        the total sum of all probabilities equals 1. If the total probability
        is greater than 0, each probability is divided by the total probability.

        """
        total_prob = sum(self.probabilities.values())
        self.probabilities = {
            label: prob / total_prob for label, prob in self.probabilities.items()
        }

    def check_pattern_compatibility(self, pattern: Pattern) -> bool:
        """Checks if the pattern is compatible with the pattern distribution, ie
        contains all required connector labels. Note that a pattern may have more
        connectors than the required ones to be valid.

        Parameters
        ----------
        pattern : Pattern
            The pattern to be evaluated for compatibility.

        Returns
        -------
        bool
            True if compatible, else False
        """
        return self.connector_labels.issubset(pattern.connectors.keys())

    def __iter__(self):
        """Defines iterable as iterating over the contents of the elements of
        the distribution.
        """
        for key in self.labels():
            yield self.patterns[key].copy_pattern(), self.probabilities[key]

    def sample_pattern(self) -> tuple[Pattern, float]:
        """Samples a pattern from the pattern distribution with respect to the
        probabilities of the distribution.

        Returns
        -------
        Pattern
            The sampled pattern.
        """
        pattern_choices = self.labels()
        probabilities = list(self.probabilities.values())
        sampled_key = choices(pattern_choices, weights=probabilities, k=1)[0]
        return self.patterns[sampled_key].copy_pattern(), self.probabilities[sampled_key]

    def random_pattern(self) -> tuple[Pattern, float]:
        """Samples a pattern from the distribution completely at random,
        disregarding the probabilities.

        Returns
        -------
        Pattern
            The randomly sampled pattern.
        """
        random_index = randint(0, len(self.patterns) - 1)
        random_key = list(self.labels())[random_index]
        return self.patterns[random_key].copy_pattern(), self.probabilities[random_key]

    @classmethod
    def load(cls, dir_path: Path, name: str):
        """Loads a distribution in the directory specified in dir_path with the
        name given in name, as previously saved by the save_distribution method.

        Parameters
        ----------
        dir_path : Path
            The directory the distribution is saved in.
        name : str
            The name of the distribution.

        Returns
        -------
        PatternDistribution
            The loaded pattern distribution.
        """
        distribution_directory = Path(dir_path) / name
        patterns = []
        for filename in os.listdir(distribution_directory):
            if filename == f"{name}.json":
                with open(distribution_directory / filename, encoding="utf-8") as json_file:
                    load_dict = json.load(json_file)
                    connector_labels = set(load_dict["Connector labels"])
                    new_probabilities_dict = load_dict["Probabilities"]
            else:
                pattern_name = Path(filename).stem
                new_pattern = Pattern.load(distribution_directory, pattern_name)
                patterns.append(new_pattern)
        new_pattern_dict = {pattern.label: pattern for pattern in patterns}

        return cls(name, new_pattern_dict, new_probabilities_dict, connector_labels)

    def save(self, dir_path: Path):
        """Saves a distribution to a directory in dirpath with the folder name
        taken from its name attribute. All patterns are saved in a new folder
        with the distribution name. Metadata, specifically the distribution
        probabilities and connector labels, are saved along in a separate json
        in that folder.

        Parameters
        ----------
        dir_path : str
            The path of the directory the pattern is stored in
        """
        # Make a directory for the distribution
        if not os.path.exists(dir_path):
            raise FileNotFoundError("No directory found in path")
        distribution_directory = Path(dir_path) / self.name
        if not os.path.exists(distribution_directory):
            os.mkdir(distribution_directory)
        else:
            raise FileExistsError(
                "Already a file for a pattern distribution found in the path location."
            )
        save_dict = {
            "Connector labels": list(self.connector_labels),
            "Probabilities": self.probabilities,
        }
        with open(distribution_directory / f"{self.name}.json", "w", encoding="utf-8") as json_file:
            json.dump(save_dict, json_file, indent=4)

        for pattern in self.patterns.values():
            pattern.save(distribution_directory, pattern.label)

    def labels(self):
        """Get the labels of the patterns in the distribution."""
        return list(self.patterns.keys())
