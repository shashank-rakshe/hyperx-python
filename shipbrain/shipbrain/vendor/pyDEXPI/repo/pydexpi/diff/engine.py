"""Core diff engine for comparing two pyDEXPI models.

The engine matches objects between the two models based on a provided implementation of the
SemanticEquality interface. It then identifies changes in form of added, removed, moved, and
modified objects.
"""

from __future__ import annotations

from collections.abc import Callable

from pydexpi.diff.domains import ChangeDomain, domain_of_location
from pydexpi.diff.ordering import (
    is_convention_ordered,
    is_order_significant,
    is_spec_ordered,
)
from pydexpi.diff.results import (
    AddedObject,
    AttributeChange,
    DiffResult,
    Matching,
    ModifiedObject,
    MovedObject,
    RemovedObject,
)
from pydexpi.loaders.value_codec import UnsupportedValueError, encode_value
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel, PyDexpiBaseModel
from pydexpi.toolkits.base_model_utils import (
    get_composition_attributes,
    get_data_attributes,
    get_reference_attributes,
)
from pydexpi.toolkits.display_name import get_tag
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

#: The attributes ``TagEquality`` matches on, in the order it tries them. A tuple, not a set: the
#: order decides which attribute is compared when a class declares several, and a set of strings
#: iterates in an order that depends on ``PYTHONHASHSEED``.
TAG_ATTRIBUTE_ORDER: tuple[str, ...] = (
    "tagName",
    "subTagName",
    "lineNumber",
    "segmentNumber",
    "pipingComponentNumber",
    "actuatingSystemNumber",
    "instrumentationLoopFunctionNumber",
    "pipeConnectorNumber",
)

#: The same attributes as a set, kept for membership tests and existing importers.
TAG_ATTRIBUTES = set(TAG_ATTRIBUTE_ORDER)

type SemanticEquality[T: PyDexpiBaseModel] = Callable[[T, T], bool]
"""Callable strategy that determines if two pyDEXPI objects of the same type are semantically equal.

Parameters
----------
object1 : T
    The first pyDEXPI object to compare.
object2 : T
    The second pyDEXPI object to compare.

Returns
-------
bool
    True if the objects are semantically equal, False otherwise.
"""


class PyDexpiDiffEngine:
    """A diff engine for comparing two pyDEXPI models based on a provided semantic equality.

    The diff engine identifies changes in form of added, removed, moved, and modified objects, where
    modified objects are objects with changes in their data attributes or connectivity. The diff
    engine relies on a provided semantic equality function that defines the criteria for semantic
    equality between pyDEXPI objects of the same type.

    To calculate the diffs, the engine first creates a mapping between semantically equal objects in
    the two models based on the provided SemanticEquality implementation. It also keeps track of
    objects, ids, and composition hierarchy for both models. Then, diffs are calculated:
    - Added objects: Objects in model 2 that have no semantic match in model 1.
    - Removed objects: Objects in model 1 that have no semantic match in model 2.
    - Moved objects: Objects that have a semantic match in the other model but a different container
      (i.e. parent in the composition hierarchy).
    - Modified objects: Objects that have a semantic match in the other model but changes in
      reference or data attributes.

    Attributes
    ----------
    semantic_equality : SemanticEquality
        The semantic equality function used to compare pyDEXPI objects of the same type.
    _object_map1 : dict[str, PyDexpiBaseModel]
        A mapping of object IDs to pyDEXPI objects for model 1.
    _object_map2 : dict[str, PyDexpiBaseModel]
        A mapping of object IDs to pyDEXPI objects for model 2.
    _semantic_map : dict[str, str]
        A mapping of object IDs from model 1 to object IDs from model 2 for pairs of objects
        considered equal within the composition hierarchy.
    _second_semantic_map : dict[str, str]
        A mapping of object IDs from model 1 to object IDs from model 2 for pairs of objects
        considered equal globally.
    _container_map1 : dict[str, str | None]
        A mapping of object IDs from model 1 to the ID of their direct container (i.e. parent in
        the composition hierarchy), or ``None`` for the root model itself.
    _container_map2 : dict[str, str | None]
        A mapping of object IDs from model 2 to the ID of their direct container (i.e. parent in
        the composition hierarchy), or ``None`` for the root model itself.
    _non_mapped_obj1 : list[PyDexpiBaseModel]
        A list of objects from model 1 that have no semantic match in model 2.
    _non_mapped_obj2 : list[PyDexpiBaseModel]
        A list of objects from model 2 that have no semantic match in model 1.

    Example usage
    -------------
    >>> from pydexpi.diff.engine import PyDexpiDiffEngine
    >>> from pydexpi.diff.semantic_equality import id_equality
    >>> from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel

    >>> # Create two models to compare
    >>> model1 = EngineeringModel(...)
    >>> model2 = EngineeringModel(...)

    >>> # Initialize the diff engine with ID-based semantic equality
    >>> diff_engine = PyDexpiDiffEngine(semantic_equality=id_equality)

    >>> # Perform the diff operation
    >>> diff_result = diff_engine.diff(model1, model2)
    """

    def __init__(self, semantic_equality: SemanticEquality, *, track_order: bool = False):
        """Initialize the diff engine with a specific semantic equality function.

        Parameters
        ----------
        semantic_equality : SemanticEquality
            The semantic equality function to use for comparing pyDEXPI objects of the same type.
        track_order : bool, optional
            Also report reorders of the composition lists pyDEXPI gives an order -- a segment's
            flow order (``pydexpi.diff.ordering.ORDERED_COMPOSITION``) -- as
            ``AttributeChange(category="composition")``. Off by default: most comparisons are
            about content. The lists the *specification* declares ordered (the drawing's z-order
            and geometry, a vector's values, a template's component list) are compared by
            position whether or not this is set; every other list is compared as a multiset.
        """
        self.semantic_equality = semantic_equality
        self.track_order = track_order

        self._object_map1: dict[str, PyDexpiBaseModel] = {}
        self._object_map2: dict[str, PyDexpiBaseModel] = {}

        self._semantic_map: dict[str, str] = {}
        self._second_semantic_map: dict[str, str] = {}

        # The root model has no container, so it maps to None -- hence the optional value type.
        self._container_map1: dict[str, str | None] = {}
        self._container_map2: dict[str, str | None] = {}
        # The composition attribute of the container that holds each object (None for the root).
        self._container_attribute_map1: dict[str, str | None] = {}
        self._container_attribute_map2: dict[str, str | None] = {}
        self._domain_cache: dict[tuple[int, str], ChangeDomain] = {}
        self._all_matches: dict[str, str] = {}

        self._non_mapped_obj1: list[PyDexpiBaseModel] = []
        self._non_mapped_obj2: list[PyDexpiBaseModel] = []

    def diff(self, model1: EngineeringModel, model2: EngineeringModel) -> DiffResult:
        """Calculate the diff between model1 and model2.

        Parameters
        ----------
        model1 : EngineeringModel
            The first pyDEXPI model to compare, considered the "old model".
        model2 : EngineeringModel
            The second pyDEXPI model to compare, considered the "new model".

        Returns
        -------
        DiffResult
            The result of the diff operation.
        """
        return self._diff(model1, model2)

    def diff_objects(self, object1: PyDexpiBaseModel, object2: PyDexpiBaseModel) -> DiffResult:
        """Compare two subtrees -- one piece of equipment, a segment -- on their own.

        This is a *comparison scope*: only the two subtrees are traversed and matched, and
        nothing outside them is looked at. That differs from filtering a whole-model diff
        (``id_diff(..., scope=...)``, ``DiffResult.for_objects``) in ways that matter:

        - An object moved *across* the boundary -- a valve moved out of the compared segment --
          is reported as removed (or added), not as moved: its other parent is out of view.
        - The two roots are matched like any other pair. If they do not match (different ids,
          under id equality), every object is reported as removed on one side and added on the
          other.
        - Domains are classified by class, since the subtree's location in a model is unknown.

        Parameters
        ----------
        object1 : PyDexpiBaseModel
            The root of the old subtree.
        object2 : PyDexpiBaseModel
            The root of the new subtree.

        Returns
        -------
        DiffResult
            The changes within the two subtrees.
        """
        return self._diff(object1, object2)

    def _diff(self, model1: PyDexpiBaseModel, model2: PyDexpiBaseModel) -> DiffResult:
        """The diff pipeline shared by ``diff`` and ``diff_objects``."""
        self.reset()
        self._make_basic_maps(model1, model2)
        self._make_semantic_map(model1, model2)
        # Both passes' matches, merged once: the packaging steps look pairs up per object.
        self._all_matches = {**self._semantic_map, **self._second_semantic_map}
        added_objects = self._package_added_objects()
        removed_objects = self._package_removed_objects()
        moved_objects = self._package_moved_objects()
        modified_objects = self._package_modified_objects()
        return DiffResult(
            matching=self._matching(),
            track_order=self.track_order,
            moved_objects=moved_objects,
            added_objects=added_objects,
            removed_objects=removed_objects,
            modified_objects=modified_objects,
        )

    def reset(self) -> None:
        """Clear all internal state of the diff engine to prepare for a new diff operation."""
        self._object_map1 = {}
        self._object_map2 = {}

        self._semantic_map = {}

        self._second_semantic_map = {}

        self._container_map1 = {}
        self._container_map2 = {}
        self._container_attribute_map1 = {}
        self._container_attribute_map2 = {}
        self._domain_cache = {}
        self._all_matches = {}

        self._non_mapped_obj1 = []
        self._non_mapped_obj2 = []

    def _make_basic_maps(self, model1: PyDexpiBaseModel, model2: PyDexpiBaseModel) -> None:
        """Extract object and container maps for *model1* and *model2*.

        Does a recursive depth-first traversal of the composition hierarchy of each model to
        populate:
        - object_map: mapping of all object IDs to their corresponding pyDEXPI objects.
        - container_map: mapping of each object's ID to the ID of its direct container.
        - container_attribute_map: mapping of each object's ID to the composition attribute of
          its container that holds it.
        """

        def traverse(
            obj: PyDexpiBaseModel,
            object_map: dict[str, PyDexpiBaseModel],
            container_map: dict[str, str | None],
            attribute_map: dict[str, str | None],
        ) -> None:
            """Helper for df traversal and discovery of object and container maps."""
            comp_attrs = get_composition_attributes(obj)
            for attr_name, attr_value in comp_attrs.items():
                if isinstance(attr_value, list):
                    for item in attr_value:
                        if isinstance(item, PyDexpiBaseModel):
                            container_map[item.id] = obj.id
                            attribute_map[item.id] = attr_name
                            object_map[item.id] = item
                            traverse(item, object_map, container_map, attribute_map)
                        else:
                            # ValueError, not TypeError: this surfaces through the public
                            # diff API, and what it raises is part of that contract (TRY004).
                            raise ValueError(  # noqa: TRY004
                                "Non-pyDEXPI object found in composition attribute list"
                            )
                elif isinstance(attr_value, PyDexpiBaseModel):
                    container_map[attr_value.id] = obj.id
                    attribute_map[attr_value.id] = attr_name
                    object_map[attr_value.id] = attr_value
                    traverse(attr_value, object_map, container_map, attribute_map)
                elif attr_value is not None:
                    raise ValueError("Non-pyDEXPI object found in composition attribute")

        # Add the root objects to the object maps
        self._object_map1[model1.id] = model1
        self._object_map2[model2.id] = model2
        self._container_map1[model1.id] = None
        self._container_map2[model2.id] = None
        self._container_attribute_map1[model1.id] = None
        self._container_attribute_map2[model2.id] = None
        self._root1: PyDexpiBaseModel = model1
        self._root2: PyDexpiBaseModel = model2

        # Traverse both models
        traverse(model1, self._object_map1, self._container_map1, self._container_attribute_map1)
        traverse(model2, self._object_map2, self._container_map2, self._container_attribute_map2)

    def _make_semantic_map(self, model1: PyDexpiBaseModel, model2: PyDexpiBaseModel) -> None:
        """Create a mapping of semantically equivalent objects between *model1* and *model2*.

        The mapping is stored in the internal attribute ``_semantic_map``, which maps
        object IDs from *model1* to object IDs from *model2* for all pairs of objects
        that are considered semantically equal by the provided ``SemanticEquality``
        implementation. Any object from *model1* that has no semantic counterpart will be stored in
        ``_non_mapped_obj1``, and any object from *model2* that has no semantic counterpart will be
        stored in ``_non_mapped_obj2``.

        To increase robustness of the semantic map with respect to possible duplications in
        semantic equality, the mapping is built recursively first, prioritizing equality within
        a compositional container (df_pass). Then, any remaning unmapped objects are compared
        globally to find additional semantic matches (second_pass).
        """
        # First pass to populate semantic map within the composition hierarchy
        if self._is_equal(model1, model2):
            self._semantic_map[model1.id] = model2.id
            self._df_semantic_map(model1, model2)

        # Second pass to find additional semantic matches outside of the composition hierarchy
        self._second_pass_semantic_map(model1, model2)

    def _df_semantic_map(self, obj1: PyDexpiBaseModel, obj2: PyDexpiBaseModel) -> None:
        """Recursively populate the semantic map for all objects contained within obj1 and obj2.

        This method assumes that obj1 and obj2 are already known to be semantically equal, and
        that their IDs have already been mapped in the semantic map. It then compares all
        composition attributes of obj1 and obj2 (i.e. attributes that contain other pyDEXPI
        objects) and recursively maps any semantically equal contained objects.
        """

        comp1 = get_composition_attributes(obj1)
        comp2 = get_composition_attributes(obj2)
        for attr_name in comp1:
            val1 = comp1[attr_name]
            val2 = comp2[attr_name]

            if isinstance(val1, list):
                # Iterate over members of model 1 and keep track whether a counterpart is found in
                # model 2. If so, add to semantic map. Continue search for discovered counterparts
                # Each member is matched at most once on either side: without the break, a
                # model-1 member equal to several model-2 members (duplicate tags) was mapped to
                # each in turn, the last one winning, and its subtree walked once per match.
                val_2_visited = set()
                for val1_member in val1:
                    for val2_member in val2:
                        if (
                            self._is_equal(val1_member, val2_member)
                            and val2_member not in val_2_visited
                        ):
                            val_2_visited.add(val2_member)
                            self._semantic_map[val1_member.id] = val2_member.id
                            self._df_semantic_map(val1_member, val2_member)
                            break

            # If single instances, compare equality and map if semantically equal
            elif isinstance(val1, PyDexpiBaseModel):
                if self._is_equal(val1, val2):
                    self._semantic_map[val1.id] = val2.id
                    self._df_semantic_map(val1, val2)

    def _second_pass_semantic_map(self, model1: PyDexpiBaseModel, model2: PyDexpiBaseModel) -> None:
        """Second pass to find additional semantic matches outside of the composition hierarchy.

        This method compares all unmapped objects from model1 to all unmapped objects from
        model2, and maps any pairs of objects that are found to be semantically equal by the
        provided SemanticEquality implementation. This allows the diff engine to find semantic
        matches outside the composition hierarchy to find moved objects.
        """

        # Retrieve all instances and determine which are unmapped in the first pass
        all_instances1 = get_all_instances_in_model(model1)
        all_instances2 = get_all_instances_in_model(model2)

        unmapped_obj1_rw = [obj for obj in all_instances1 if obj.id not in self._semantic_map]
        unmapped_obj2_rw = [
            obj for obj in all_instances2 if obj.id not in self._semantic_map.values()
        ]

        # Discover newly mapped objects by comparing all unmapped objects pairwise.
        # New matches are added to the second semantic map.
        newly_mapped_obj1 = set()
        newly_mapped_obj2 = set()
        for obj1 in unmapped_obj1_rw:
            for obj2 in unmapped_obj2_rw:
                # An object already claimed by an earlier match is not available again.
                if obj2.id in newly_mapped_obj2:
                    continue
                if self._is_equal(obj1, obj2):
                    self._second_semantic_map[obj1.id] = obj2.id
                    newly_mapped_obj1.add(obj1.id)
                    newly_mapped_obj2.add(obj2.id)
                    break

        # Any unmapped objects are considered non-matching and stored in the non-mapped lists
        self._non_mapped_obj1 = [obj for obj in unmapped_obj1_rw if obj.id not in newly_mapped_obj1]
        self._non_mapped_obj2 = [obj for obj in unmapped_obj2_rw if obj.id not in newly_mapped_obj2]

    def _package_added_objects(self) -> list[AddedObject]:
        """Package all non-mapped objects from model2 as added objects.

        Returns
        -------
         list[AddedObject]
            A list of all added objects, represented as instances of the AddedObject dataclass.
        """
        return [
            AddedObject(
                object_id=obj.id,
                object_type=type(obj).__name__,
                tag=self._get_tag(obj),
                domain=self._domain(obj.id, 2),
            )
            for obj in self._non_mapped_obj2
        ]

    def _package_removed_objects(self) -> list[RemovedObject]:
        """Package all non-mapped objects from *model1* as removed objects.

        Returns
        -------
        list[RemovedObject]
            A list of all removed objects, represented as instances of the RemovedObject dataclass.
        """
        return [
            RemovedObject(
                object_id=obj.id,
                object_type=type(obj).__name__,
                tag=self._get_tag(obj),
                domain=self._domain(obj.id, 1),
            )
            for obj in self._non_mapped_obj1
        ]

    def _package_moved_objects(self) -> list[MovedObject]:
        """Package all objects with a different container as moved objects.

        An object is moved if its container's counterpart is not its new container, or if it
        stayed with the same container but moved to another of its composition attributes.

        Returns
        -------
        list[MovedObject]
            A list of all moved objects, represented as instances of the MovedObject dataclass."""
        moved_objects = []

        # Loop over all semantic matches
        all_semantic_matches = self._all_matches
        for obj1_id, obj2_id in all_semantic_matches.items():
            # Get container ids for both objects. And map the container id from model 1 to the
            # corresponding container id in model 2 using the semantic map to enable comparison of
            # container ids.
            container1_id = self._container_map1.get(obj1_id)
            container2_id = self._container_map2.get(obj2_id)
            # A None container means the object is the root model, which has no counterpart to
            # look up -- both sides then compare as None and the object is not reported as moved.
            mapped_container1_id = (
                all_semantic_matches.get(container1_id) if container1_id is not None else None
            )

            attribute1 = self._container_attribute_map1.get(obj1_id)
            attribute2 = self._container_attribute_map2.get(obj2_id)

            # See if the containers and attributes match, otherwise consider it a move.
            if container2_id != mapped_container1_id or attribute1 != attribute2:
                moved_objects.append(
                    MovedObject(
                        object_id_1=obj1_id,
                        object_id_2=obj2_id,
                        object_type=type(self._object_map2[obj2_id]).__name__,
                        tag=self._get_tag(self._object_map2[obj2_id]),
                        old_parent_id=container1_id,
                        new_parent_id=container2_id,
                        old_container_attribute=attribute1,
                        new_container_attribute=attribute2,
                        domain=self._domain(obj2_id, 2),
                    )
                )
        return moved_objects

    def _package_modified_objects(self) -> list[ModifiedObject]:
        """Compare all mapped objects for changes in data attributes and connectivity.

        This method compares all pairs of semantically mapped objects for changes in their data
        attributes and reference attributes (i.e. connectivity). For any pair of mapped objects with
        changes, a ModifiedObject instance is created.

        Returns
        -------
        list[ModifiedObject]
            A list of all modified objects, packaged as instances of the ModifiedObject dataclass.
        """
        attribute_changes = []

        # Gather all semantic matches
        all_semantic_matches = self._all_matches

        # Loop over semantic matches
        for obj1_id, obj2_id in all_semantic_matches.items():
            # Retrieve objects from maps
            obj1 = self._object_map1[obj1_id]
            obj2 = self._object_map2[obj2_id]

            # Collect attribute changes for this pair of objects
            data_changes = self._data_attribute_changes(obj1, obj2)
            reference_changes = self._reference_attribute_changes(obj1, obj2)
            changes = data_changes + reference_changes + self._order_changes(obj1, obj2)

            # If there are any changes, make a Modified object with changes
            if changes:
                attribute_changes.append(
                    ModifiedObject(
                        object_id_1=obj1_id,
                        object_id_2=obj2_id,
                        object_type=type(obj2).__name__,
                        tag=self._get_tag(obj2),
                        changes=changes,
                        domain=self._domain(obj2_id, 2),
                    )
                )

        return attribute_changes

    def _reference_attribute_changes(
        self, obj1: PyDexpiBaseModel, obj2: PyDexpiBaseModel
    ) -> list[AttributeChange]:
        """Compare all mapped objects for changes in reference attributes.

        This method compares all reference attributes of obj1 and obj2 and identifies any
        changes. Changes are packaged as instances of the AttributeChange dataclass, with category
        "reference".

        Returns
        -------
        list[AttributeChange]
            A list of all reference attribute changes between obj1 and obj2.
        """

        attribute_changes = []

        # Get reference attributes
        ref_attrs1 = get_reference_attributes(obj1)
        ref_attrs2 = get_reference_attributes(obj2)

        # Iterate over attributes and compare values
        for attr_name in ref_attrs1:
            attribute_changed = False
            val1 = ref_attrs1[attr_name]
            val2 = ref_attrs2[attr_name]

            ordered = isinstance(val1, list) and is_order_significant(obj1, attr_name)
            if isinstance(val1, list):
                # Map the ids from val1 to the corresponding id in model2 using the semantic map.
                # If any is not in the semantic map, then it's considered changed
                mapped_val1: list[str] = []
                for item in val1:
                    mapped_id = self._semantic_map.get(item.id) or self._second_semantic_map.get(
                        item.id
                    )
                    if mapped_id is not None:
                        mapped_val1.append(mapped_id)
                    else:
                        attribute_changed = True
                        break

                # An ordered list (ListOfMaterialComponents.component: a fraction vector is read
                # against it position by position) is compared as the sequence of ids, always;
                # any other reference list as the set of ids it names.
                val2_ids = [item.id for item in val2]
                if ordered:
                    if mapped_val1 != val2_ids:
                        attribute_changed = True
                elif set(mapped_val1) != set(val2_ids):
                    attribute_changed = True

            # If attribute is a single reference, check if the mapped id from val1 matches the id in
            # val2
            elif isinstance(val1, PyDexpiBaseModel):
                if val2 is None:
                    attribute_changed = True
                else:
                    mapped_id = self._semantic_map.get(val1.id) or self._second_semantic_map.get(
                        val1.id
                    )
                    if mapped_id != val2.id:
                        attribute_changed = True
            elif val1 is None and val2 is not None:
                attribute_changed = True

            if attribute_changed:
                attribute_changes.append(
                    AttributeChange(
                        attribute_name=attr_name,
                        old_value=val1,
                        new_value=val2,
                        category="reference",
                        ordered=ordered,
                    )
                )

        return attribute_changes

    def _data_attribute_changes(
        self, obj1: PyDexpiBaseModel, obj2: PyDexpiBaseModel
    ) -> list[AttributeChange]:
        """Compare all mapped objects for changes in data attributes.

        This method compares all data attributes of obj1 and obj2 and identifies any changes.
        Changes are packaged as instances of the AttributeChange dataclass, with category "data".

        Returns
        -------
        list[AttributeChange]
            A list of all data attribute changes between obj1 and obj2.
        """

        attribute_changes = []

        # Get data attributes
        data_attrs1 = get_data_attributes(obj1)
        data_attrs2 = get_data_attributes(obj2)

        # Iterate over attributes and compare values. A list the model orders (a polyline's
        # points) compares by position, any other as a multiset (MaterialTemplate.phaseLabel);
        # inside a data value, the data type's own equality decides (a vector's values are
        # ordered, a MultiLanguageString's languages are not).
        for attr_name in data_attrs1:
            val1 = data_attrs1[attr_name]
            val2 = data_attrs2[attr_name]
            ordered = isinstance(val1, list) and is_order_significant(obj1, attr_name)

            if isinstance(val1, list) and isinstance(val2, list) and not ordered:
                changed = not _same_multiset(val1, val2)
            else:
                changed = not same_value(val1, val2)
            if changed:
                attribute_changes.append(
                    AttributeChange(
                        attribute_name=attr_name,
                        old_value=val1,
                        new_value=val2,
                        category="data",
                        ordered=ordered,
                    )
                )
        return attribute_changes

    def _order_changes(
        self, obj1: PyDexpiBaseModel, obj2: PyDexpiBaseModel
    ) -> list[AttributeChange]:
        """Report reorders of the ordered composition lists of a matched pair.

        A list the specification declares ordered (z-order included) is always compared; one
        pyDEXPI orders (a segment's flow order) only when the engine tracks order. A list counts as reordered when
        the members present on both sides appear in a different relative order. Members added or
        removed are reported as added or removed objects, and do not make a list reordered on
        their own. The change carries the whole list on each side: model-1 ids in the old order,
        model-2 ids in the new one.

        Returns
        -------
        list[AttributeChange]
            One ``category="composition"`` change per reordered list.
        """
        all_semantic_matches = self._all_matches
        changes = []
        comp1 = get_composition_attributes(obj1)
        comp2 = get_composition_attributes(obj2)
        for attr_name, val1 in comp1.items():
            val2 = comp2[attr_name]
            if not isinstance(val1, list):
                continue
            if not (
                is_spec_ordered(obj1, attr_name)
                or (self.track_order and is_convention_ordered(obj1, attr_name))
            ):
                continue
            ids2 = [item.id for item in val2]
            present2 = set(ids2)
            common_in_old_order = [
                all_semantic_matches[item.id]
                for item in val1
                if all_semantic_matches.get(item.id) in present2
            ]
            common = set(common_in_old_order)
            common_in_new_order = [item_id for item_id in ids2 if item_id in common]
            if common_in_old_order != common_in_new_order:
                changes.append(
                    AttributeChange(
                        attribute_name=attr_name,
                        old_value=[item.id for item in val1],
                        new_value=ids2,
                        category="composition",
                        ordered=True,
                    )
                )
        return changes

    def _domain(self, object_id: str, side: int) -> ChangeDomain:
        """Classify an object by its location in model 1 or 2 (``side``).

        Walks the container maps up to the root, collecting the composition attribute at each
        step, and hands the path to ``domains.domain_of_location``. Cached per object.
        """
        key = (side, object_id)
        cached = self._domain_cache.get(key)
        if cached is not None:
            return cached
        if side == 1:
            containers = self._container_map1
            attributes = self._container_attribute_map1
            objects = self._object_map1
            root = self._root1
        else:
            containers = self._container_map2
            attributes = self._container_attribute_map2
            objects = self._object_map2
            root = self._root2
        path: list[str] = []
        current: str | None = object_id
        while current is not None:
            attribute = attributes.get(current)
            if attribute is not None:
                path.append(attribute)
            current = containers.get(current)
        path.reverse()
        domain = domain_of_location(root, path, objects[object_id])
        self._domain_cache[key] = domain
        return domain

    def _matching(self) -> Matching:
        """Label the matching strategy for the result, without naming a callable."""
        # Imported here: semantic_equality imports this module for TAG_ATTRIBUTE_ORDER.
        from pydexpi.diff.semantic_equality import TagEquality, id_equality

        if self.semantic_equality is id_equality:
            return "id"
        if isinstance(self.semantic_equality, TagEquality):
            return "tag"
        return "custom"

    def _is_equal(self, object1: PyDexpiBaseModel, object2: PyDexpiBaseModel) -> bool:
        """Determine if two pyDEXPI objects are semantically equal.

        First checks if the objects are of the same type. If they are different types,
        returns False. If they are the same type, delegates to the semantic equality function.

        Parameters
        ----------
        object1 : PyDexpiBaseModel
            The first object to compare.
        object2 : PyDexpiBaseModel
            The second object to compare.

        Returns
        -------
        bool
            True if the objects are of the same type and semantically equal, False otherwise.
        """
        if type(object1) is not type(object2):
            return False
        return self.semantic_equality(object1, object2)

    def _get_tag(self, obj: PyDexpiBaseModel) -> str | None:
        """Return the tag of an object, if any, as resolved by ``display_name.get_tag``."""
        return get_tag(obj)


def _same_multiset(first: list, second: list) -> bool:
    """Whether two lists hold equal elements, as many times each, in any order.

    Matched by equality rather than by hash: data values are not all hashable, and these lists
    are short. Elements are matched as `same_value` matches two values, so the unordered lists
    and the single values of a model are compared by one rule. No generated class reaches it with
    a number today: the only unordered data list is ``MaterialTemplate.phaseLabel``, of strings.
    """
    if len(first) != len(second):
        return False
    remaining = list(second)
    for item in first:
        for index, candidate in enumerate(remaining):
            if same_value(item, candidate):
                del remaining[index]
                break
        else:
            return False
    return True


def same_value(first: object, second: object) -> bool:
    """Whether two data values say the same: equal, or kept apart by a NaN alone.

    A NaN is not equal to itself, so a ``PhysicalQuantity`` holding one is not equal to its own
    copy, and a model was reported changed from its own reload. A DEXPI ``Double`` may be a NaN
    (``xsd:double``), and a model that holds one has not changed from a model that holds one in
    the same place. The wire form spells a NaN as a string (``pydexpi.loaders.value_codec``), so
    two values that are not equal are compared in it. Only a NaN makes the two comparisons disagree.

    Parameters
    ----------
    first, second : object
        Two values of one data attribute.

    Returns
    -------
    bool
        True when the values are equal, or encode to the same wire value.
    """
    if first == second:
        return True
    try:
        return encode_value(first) == encode_value(second)
    except UnsupportedValueError:
        return False
