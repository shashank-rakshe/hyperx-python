"""
Engineering Model Toolkit
--------------------
This module contains functions and tools that concern overall of an overall
engineering model/conceptual model.

"""

from collections.abc import Callable, Iterable
from typing import Any, TypeVar, get_origin, get_type_hints

import pydexpi.toolkits.base_model_utils as bmu
from pydexpi.pydexpi_classes import EngineeringModel, PlantModel, PyDexpiBaseModel
from pydexpi.pydexpi_classes.pydexpi_classes import make_id

ModelT = TypeVar("ModelT", bound=PyDexpiBaseModel)


def resolve_class_by_name(module, class_name: str, base_class):
    """Return the class named `class_name` from `module`, validated as a subclass
    of `base_class`. Raises ValueError on failure.

    Safe against arbitrary code execution: getattr only returns names already
    present in the module namespace, and the issubclass check restricts the
    result to the expected DEXPI class hierarchy.
    """
    candidate = getattr(module, class_name, None)
    if not isinstance(candidate, type) or not issubclass(candidate, base_class):
        # The failure is about the *name* resolving to the wrong thing, and callers catch
        # ValueError for it today; changing that is a behaviour change, not a lint fix (TRY004).
        raise ValueError(  # noqa: TRY004
            f"{class_name!r} is not a valid {base_class.__name__} subclass in {module.__name__}."
        )
    return candidate


def combine_engineering_models(
    models: list[EngineeringModel],
    engineering_model_kwargs: dict | None = None,
    plant_model_kwargs: dict | None = None,
) -> EngineeringModel:
    """This function combines the contents of a list of engineering models and returns
    a new model with its contents.

    The combination is performed on all list attributes of the plant model.
    The data attributes of the engineering model and the plant model can be
    passed in via kwargs.

    Parameters
    ----------
    models : list[EngineeringModel]
        The list of engineering models to be combined.
    engineering_model_kwargs : dict, optional
        The keyword arguments for the engineering model. This can be used to set
        data attributes of the engineering model. By default, an empty dict is used.
    plant_model_kwargs : dict, optional
        The keyword arguments for the plant model. This can be used to set data
        attributes of the plant model. By default, an empty dict is used.

    Returns
    -------
    EngineeringModel
        The combined engineering model.

    Raises
    ------
    NotImplementedError
        Combining diagram information is not yet implemented. If any model
        has diagram or shapeCatalog attributes that are not None, Error is
        raised.
    """

    if plant_model_kwargs is None:
        plant_model_kwargs = {}
    if engineering_model_kwargs is None:
        engineering_model_kwargs = {}
    for engineering_model in models:
        for i in [engineering_model.diagram, engineering_model.shapeCatalogues]:
            if i not in [None, []]:
                msg = "Dexpi toolkit does not yet support manipulating diagram information."
                raise NotImplementedError(msg)

    # Retrieve and combine list attributes
    new_model_args = {}
    for attr_name, typ in get_type_hints(PlantModel).items():
        if get_origin(typ) is list:
            attrs = [getattr(model.conceptualModel, attr_name) for model in models]
            new_model_args[attr_name] = [
                item for model_attr_list in attrs for item in model_attr_list
            ]
        else:
            pass

    new_plant_model = PlantModel(**new_model_args, **plant_model_kwargs)

    return EngineeringModel(conceptualModel=new_plant_model, **engineering_model_kwargs)


def import_model_contents_into_model(
    target_model: EngineeringModel, import_models: list[EngineeringModel]
) -> None:
    """Imports the contents of passed models into target model. Conceptually
    similar to combine_dexpi_models, but the target_model is manipulated in
    place and its other, non-list attributes are preserved.

    Parameters
    ----------
    target_model : EngineeringModel
        The model that is manipulated in place and that the other models are
        imported into.
    import_models : list[EngineeringModel]
        The models that are to be imported to the target.

    Raises
    ------
    NotImplementedError
        Combining diagram information is not yet implemented. If any model
        has diagram or shapeCatalog attributes that are not None, Error is
        raised.
    """
    for dexpi_model in import_models:
        for i in [dexpi_model.diagram, dexpi_model.shapeCatalogues]:
            if i not in [None, []]:
                msg = "Dexpi toolkit does not yet support manipulating diagram information."
                raise NotImplementedError(msg)

    for attr_name, typ in get_type_hints(PlantModel).items():
        if get_origin(typ) is list:
            attrs = [getattr(model.conceptualModel, attr_name) for model in import_models]
            new_attrs = [item for model_attr_list in attrs for item in model_attr_list]

            # Append new attributes
            getattr(target_model.conceptualModel, attr_name).extend(new_attrs)


def clone_model[ModelT: PyDexpiBaseModel](the_model: ModelT) -> ModelT:
    """Creates a deep copy of the model and generates new IDs for all instances in the model.

    Parameters
    ----------
    the_model : ModelT
        The model to be cloned.

    Returns
    -------
    ModelT
        A deep copy of the model with new IDs for all instances.
    """

    new_model = the_model.model_copy(deep=True)
    reassign_ids_in_model(new_model)
    return new_model


def reassign_ids_in_model(the_model: PyDexpiBaseModel) -> None:
    """Reassigns new IDs to all instances in the model.

    Parameters
    ----------
    the_model : PyDexpiBaseModel
        The model in which to reassign IDs."""
    all_instances = get_all_instances_in_model(the_model)

    # Generate new IDs for all instances
    for instance in all_instances:
        instance.id = make_id()


def get_all_instances_in_model(
    the_model: PyDexpiBaseModel, dexpi_classes: tuple[PyDexpiBaseModel] | None = None
) -> list[PyDexpiBaseModel]:
    """
    Recursively discover and collect all instances of specified classes within a model.

    This function traverses the attributes of the provided model object, recursively inspecting
    its attributes and sub-attributes to find all instances of the specified classes. The function
    returns a list of all discovered instances.

    Parameters
    ----------
    the_model : PyDexpiBaseModel
        The root model object to inspect.
    dexpi_classes : class or tuple of classes, optional
        A tuple of class types to discover within the model. Only instances of these classes will be collected.
        If None, all objects are collected.

    Returns
    -------
    list
        A list of all discovered instances of the specified classes within the model.
    """

    def discover_instances(obj, discovered_instances: list) -> list[PyDexpiBaseModel]:
        """
        Recursively get all compositional attributes of a Python object.

        Parameters
        ----------
        obj : object
            The object to inspect.
        discovered_instances : list
            The list that keeps track of the discovered instances, in discovery order.

        Returns
        -------
        discovered_instances : list
            Returns the list with discovered instances.
        """

        # Identity-based visit tracking: revisiting an aliased object cannot yield
        # instances that its first visit did not, and skipping it keeps the walk
        # linear even if composition aliases the same object more than once.
        if id(obj) in visited_ids:
            return discovered_instances
        visited_ids.add(id(obj))

        if dexpi_classes is None or isinstance(obj, dexpi_classes):
            discovered_instances.append(obj)

        # Get all compositional attributes
        attrs = bmu.get_composition_attributes(obj)

        for attr_value in attrs.values():
            if isinstance(attr_value, PyDexpiBaseModel):
                discovered_instances = discover_instances(attr_value, discovered_instances)
            elif isinstance(attr_value, list):
                for element in attr_value:
                    discovered_instances = discover_instances(element, discovered_instances)

        return discovered_instances

    visited_ids: set[int] = set()
    discovered_instances = discover_instances(the_model, [])
    return discovered_instances


def get_instances_with_condition(
    the_model: PyDexpiBaseModel,
    condition: Callable[[PyDexpiBaseModel], bool],
    dexpi_classes: tuple[PyDexpiBaseModel] | None = None,
) -> list[PyDexpiBaseModel]:
    """Retrieve all subinstances in a engineering model that satisfy a specific condition.

    Recursively searches through the model's attributes and sub-attributes to find all instances
    that satisfy the given condition. The condition is specified as a callable that takes a
    PyDexpiBaseModel instance as an argument and returns a boolean value.

    Parameters
    ----------
    the_model : PyDexpiBaseModel
        The model to be searched.
    condition : Callable[[PyDexpiBaseModel], bool]
        The condition that the instances must satisfy.
    dexpi_classes : tuple, optional
        Can specify the classes if only certain class types are to be
        considered. If None, all are considered, by default None.

    Returns
    -------
    list
        List of discovered instances that satisfy the condition.
    """
    instances_with_condition = []

    # Discover all candidates in the model of the candidate classes
    all_candidates = get_all_instances_in_model(the_model, dexpi_classes)

    instances_with_condition.extend(
        candidate for candidate in all_candidates if condition(candidate)
    )

    return instances_with_condition


def get_instances_by_ids(
    the_model: PyDexpiBaseModel, ids: Iterable[str]
) -> dict[str, PyDexpiBaseModel]:
    """Resolve DEXPI ids to the live objects carrying them, in one traversal.

    An id that no object in the model carries is simply absent from the result.
    That is the useful answer rather than an error: the caller is typically
    working from a record of what a change touched, and an object it removed is
    legitimately gone.

    Parameters
    ----------
    the_model : PyDexpiBaseModel
        The model to search. Its whole composition tree is walked once.
    ids : Iterable[str]
        The ids to look for.

    Returns
    -------
    dict[str, PyDexpiBaseModel]
        The requested ids that were found, mapped to their objects.

    Raises
    ------
    ValueError
        If a requested id is carried by more than one object. The request is
        genuinely ambiguous, and returning whichever one happened to win would be
        silent: `ModelCompositionTreeUnique` does report two distinct objects
        sharing an id, but it is model-scoped, so the scoped validation this
        lookup serves (`ValidationEngine.validate_objects`) does not run it, and
        nothing downstream would notice the wrong object had been validated. Ids
        duplicated elsewhere in the model are not this function's business and
        are not reported.
    """
    wanted = set(ids)
    found: dict[str, PyDexpiBaseModel] = {}
    for obj in get_all_instances_in_model(the_model):
        if obj.id not in wanted:
            continue
        previous = found.get(obj.id)
        if previous is not None and previous is not obj:
            raise ValueError(
                f"Id {obj.id!r} is carried by more than one object "
                f"({type(previous).__name__} and {type(obj).__name__}); "
                "it cannot be resolved to a single instance."
            )
        found[obj.id] = obj
    return found


#: Sentinel for "caller did not ask for a particular value". A module-level singleton compared
#: by identity, rather than the previous bare ``object()`` default compared with
#: ``type(target_value) is object`` -- that treated *any* plain ``object()`` a caller passed as
#: "match anything", which is forgeable by accident and was never the documented contract.
_ANY_VALUE: Any = object()


def get_instances_with_attribute(
    the_model: PyDexpiBaseModel,
    attribute_name: str,
    target_value: Any = _ANY_VALUE,
    dexpi_classes: tuple[PyDexpiBaseModel] | None = None,
) -> list[PyDexpiBaseModel]:
    """Retrieve all subinstances in a engineering model with a specific attribute.

    The engineering model is searched recursively through compositional attributes
    of all levels. The attribute name is specified as a string. If the target_value is not
    specified, any value is permitted. If the target_value is specified, only instances with
    that value are returned. The dexpi_classes parameter can be used to specify the classes
    to be considered. If None, all classes are considered.

    Parameters
    ----------
    the_model : PyDexpiBaseModel
        The model to be searched.
    attribute_name : str
        The name of the attribute to be identified.
    target_value : Any, optional
        The value this attribute is supposed to have. If not specified any value is permitted.
    dexpi_classes : tuple, optional
        Can specify the classes if only certain class types are to be
        considered. If None, all are considered, by default None.

    Returns
    -------
    list
        List of discovered instances that have the attribute specified.
    """

    def has_matching_attribute(candidate: PyDexpiBaseModel) -> bool:
        # Try retrieving the attribute
        try:
            actual_value = getattr(candidate, attribute_name)
        except AttributeError:
            return False
        else:
            return target_value is _ANY_VALUE or actual_value == target_value

    instances_with_attribute = get_instances_with_condition(
        the_model, has_matching_attribute, dexpi_classes=dexpi_classes
    )

    return instances_with_attribute


def object_is_in_model(dexpi_model: EngineeringModel, dexpi_object: PyDexpiBaseModel) -> bool:
    """Checks if the given dexpi_object is in some way a member of the given
    dexpi_model.

    Parameters
    ----------
    dexpi_model : EngineeringModel
        The model to be searched for the object.
    dexpi_object : PyDexpiBaseModel
        The object to be searched for in the model.

    Returns
    -------
    bool
        True if object is found in the model, False otherwise
    """
    candidates = get_all_instances_in_model(dexpi_model, type(dexpi_object))
    # Identity, not equality -- see remove_object_from_model.
    return any(candidate is dexpi_object for candidate in candidates)


def remove_external_references(object: PyDexpiBaseModel) -> None:
    """Removes all references to objects outside of the given object.

    This is done by searching through the object's reference attributes to find
    any references to objects that are not part of the object's composition tree.
    These references are then removed.

    Parameters
    ----------
    object : PyDexpiBaseModel
        The object whose external references are to be removed.
    """

    # Get all compositional attributes of the object
    composition_tree = get_all_instances_in_model(object)

    # One identity set, hoisted out of the loop. The previous `any(x is obj for obj
    # in composition_tree)` rescanned the whole tree for every reference attribute of
    # every instance, which is quadratic in the size of the tree. The list keeps the
    # objects alive, so the id() keys cannot be recycled.
    internal_ids = {id(obj) for obj in composition_tree}

    for instance in composition_tree:
        ref_attrs = bmu.get_reference_attributes(instance)
        for attr_name, attr_value in ref_attrs.items():
            if isinstance(attr_value, PyDexpiBaseModel):
                if id(attr_value) not in internal_ids:
                    setattr(instance, attr_name, None)

            elif isinstance(attr_value, list):
                new_attr_value = [item for item in attr_value if id(item) in internal_ids]
                setattr(instance, attr_name, new_attr_value)


def _detach_from_composition_parents(
    all_instances: list[PyDexpiBaseModel], dexpi_objects: Iterable[PyDexpiBaseModel]
) -> None:
    """Detach each of dexpi_objects from whichever instance composes it.

    Shared by remove_object_from_model and remove_children_from_model so the two
    cannot drift. Matching is identity-based, and each object is detached at most
    once: the scan returns as soon as every object has been accounted for, which
    for a single object reproduces the "stop at the first composition parent"
    behaviour that remove_object_from_model documents.

    Parameters
    ----------
    all_instances : list[PyDexpiBaseModel]
        The model's instances, already materialized by the caller so that a batch
        costs one traversal rather than one per object.
    dexpi_objects : Iterable[PyDexpiBaseModel]
        The objects to detach from their composition parents.
    """
    remaining = {id(obj) for obj in dexpi_objects}

    for instance in all_instances:
        if not remaining:
            return

        for attr_name, attr_value in bmu.get_composition_attributes(instance).items():
            if isinstance(attr_value, PyDexpiBaseModel):
                if id(attr_value) in remaining:
                    setattr(instance, attr_name, None)
                    remaining.discard(id(attr_value))
                    if not remaining:
                        return

            elif isinstance(attr_value, list):
                matched_ids = {id(item) for item in attr_value if id(item) in remaining}
                if matched_ids:
                    setattr(
                        instance,
                        attr_name,
                        [item for item in attr_value if id(item) not in matched_ids],
                    )
                    remaining -= matched_ids
                    if not remaining:
                        return


def remove_children_from_model(
    dexpi_model: EngineeringModel, dexpi_object: PyDexpiBaseModel
) -> None:
    """Removes all children of the given dexpi_object from the given dexpi_model.

    The children are removed as one batch: the model is traversed a constant number
    of times regardless of how many children there are. Calling
    remove_object_from_model per child instead costs two full-model traversals each,
    a multiplicative cost on a large model.

    Batching also makes the outcome independent of iteration order. Removing the
    children one at a time cleared references held by a later child to an earlier
    one but not the reverse, because the earlier child was already detached and so
    no longer reachable when the later one was processed. References between the
    removed children are now cleared symmetrically.

    Parameters
    ----------
    dexpi_model : EngineeringModel
        The model to be searched for the children.
    dexpi_object : PyDexpiBaseModel
        The object whose children are to be removed from the model.

    Raises
    ------
    ValueError
        If any child is not found in the model.
    """

    # Get all compositional attributes of the object
    children: list[PyDexpiBaseModel] = []
    for attr_value in bmu.get_composition_attributes(dexpi_object).values():
        if isinstance(attr_value, PyDexpiBaseModel):
            children.append(attr_value)
        elif isinstance(attr_value, list):
            children.extend(item for item in attr_value if isinstance(item, PyDexpiBaseModel))

    if not children:
        return

    all_instances = get_all_instances_in_model(dexpi_model)
    instance_ids = {id(instance) for instance in all_instances}
    for child in children:
        if id(child) not in instance_ids:
            raise ValueError("The object is not found in the model.")

    # References to the children and to everything they compose, in one traversal.
    removed_instances = [
        instance for child in children for instance in get_all_instances_in_model(child)
    ]
    remove_references_to_objects(dexpi_model, removed_instances)

    _detach_from_composition_parents(all_instances, children)


def remove_references_to_objects(
    dexpi_model: EngineeringModel, dexpi_objects: Iterable[PyDexpiBaseModel]
) -> None:
    """Removes all references to any of the given dexpi_objects from the given dexpi_model.

    The model is traversed exactly once, regardless of how many objects are passed,
    and every reference attribute is checked against the batch with an O(1)
    membership test. Matching is identity-based (``is``), never by ``id`` field or
    equality, so distinct objects that happen to share an ``id`` do not alias.

    Scalar references to a matched object are set to None; this raises a pydantic
    ValidationError if the reference attribute is required. List references are
    filtered. Attributes without a match are left untouched (no reassignment, so no
    validation pass). Only objects reachable from dexpi_model through composition
    are visited: references held by already-detached subtrees are not cleared.

    Parameters
    ----------
    dexpi_model : EngineeringModel
        The model to be searched for the references.
    dexpi_objects : Iterable[PyDexpiBaseModel]
        The objects whose references are to be removed from the model.
    """

    # Materializing keeps the objects alive for the duration of the call, so the
    # id() keys cannot be recycled by the garbage collector.
    dexpi_objects = list(dexpi_objects)
    if not dexpi_objects:
        return
    target_ids = {id(obj) for obj in dexpi_objects}

    for instance, attr_name in get_objects_referencing(dexpi_model, dexpi_objects):
        attr_value = getattr(instance, attr_name)
        if isinstance(attr_value, PyDexpiBaseModel):
            setattr(instance, attr_name, None)
        elif isinstance(attr_value, list):
            new_attr_value = [item for item in attr_value if id(item) not in target_ids]
            setattr(instance, attr_name, new_attr_value)


def get_objects_referencing(
    dexpi_model: EngineeringModel, dexpi_objects: Iterable[PyDexpiBaseModel]
) -> list[tuple[PyDexpiBaseModel, str]]:
    """Find every reference attribute in the model that points at one of dexpi_objects.

    Returns (holder, attribute_name) pairs: the object holding the reference and
    the attribute it holds it in. A holder appears once per matching attribute.

    DEXPI references are one-directional -- an ActuatingSystem points at the valve
    it operates, the valve points at nothing -- so answering "what refers to this?"
    means scanning. The model is traversed exactly once regardless of how many
    objects are passed, and matching is identity-based (``is``), never by ``id``
    field or equality, so distinct objects sharing an ``id`` do not alias. Only
    objects reachable from dexpi_model through composition are visited.

    Parameters
    ----------
    dexpi_model : EngineeringModel
        The model to search.
    dexpi_objects : Iterable[PyDexpiBaseModel]
        The objects to find references to.

    Returns
    -------
    list[tuple[PyDexpiBaseModel, str]]
        (referencing object, reference attribute name) pairs, in traversal order,
        and for one holder in the order its class declares the attributes. The
        order is deterministic, so a caller can record what it clears in it.
    """
    dexpi_objects = list(dexpi_objects)
    if not dexpi_objects:
        return []
    target_ids = {id(obj) for obj in dexpi_objects}

    # Reference-attribute names per class, resolved once per class instead of
    # rescanning model_fields for every instance. Kept in declaration order: the
    # helper returns a set, whose iteration order varies with PYTHONHASHSEED.
    ref_attr_names_cache: dict[type, tuple[str, ...]] = {}
    found: list[tuple[PyDexpiBaseModel, str]] = []

    for instance in get_all_instances_in_model(dexpi_model):
        instance_class = type(instance)
        attr_names = ref_attr_names_cache.get(instance_class)
        if attr_names is None:
            references = bmu.get_reference_attributes_from_class(instance_class)
            attr_names = tuple(name for name in instance_class.model_fields if name in references)
            ref_attr_names_cache[instance_class] = attr_names
        for attr_name in attr_names:
            attr_value = getattr(instance, attr_name)
            if isinstance(attr_value, PyDexpiBaseModel):
                if id(attr_value) in target_ids:
                    found.append((instance, attr_name))
            elif isinstance(attr_value, list) and any(
                id(item) in target_ids for item in attr_value
            ):
                found.append((instance, attr_name))

    return found


def remove_references_to_object(
    dexpi_model: EngineeringModel, dexpi_object: PyDexpiBaseModel
) -> None:
    """Removes all references to the given dexpi_object from the given dexpi_model.

    This is done by searching through the model's reference attributes to find
    the object and remove it. This ensures that the object is removed from the
    cross-references. References to the compositional descendants of dexpi_object
    are removed as well, in the same single model traversal.

    Parameters
    ----------
    dexpi_model : EngineeringModel
        The model to be searched for the references.
    dexpi_object : PyDexpiBaseModel
        The object whose references are to be removed from the model.
    """

    remove_references_to_objects(dexpi_model, get_all_instances_in_model(dexpi_object))


def remove_references_to_children(
    dexpi_model: EngineeringModel, dexpi_object: PyDexpiBaseModel
) -> None:
    """Removes all references to the children of the given dexpi_object from the given dexpi_model.

    This is done by searching through the model's reference attributes to find
    the children and remove them. This ensures that the children are removed from the
    cross-references. References to dexpi_object itself are kept.

    Parameters
    ----------
    dexpi_model : EngineeringModel
        The model to be searched for the references.
    dexpi_object : PyDexpiBaseModel
        The object whose children's references are to be removed from the model.
    """

    children = [obj for obj in get_all_instances_in_model(dexpi_object) if obj is not dexpi_object]
    remove_references_to_objects(dexpi_model, children)


def remove_object_from_model(dexpi_model: EngineeringModel, dexpi_object: PyDexpiBaseModel) -> None:
    """Removes the given dexpi_object from the given dexpi_model.

    This is done by searching through the model's compositional and reference attributes to find
    the object and remove it. This ensures that the object is removed from both the model's
    compositional tree and the cross-references.

    Assumptions
    -----------
    Assumes that the object is in the model's composition tree only once, as it should for
    a well-formed model. If the object is found in multiple places, only the first occurrence will
    be removed. Scanning stops as soon as the composition parent is found; in a malformed model
    with the object in multiple locations, remaining occurrences are left intact.

    Note that any references from the removed object to other objects in the model are not removed.
    This can be done with remove_references_to_object, if desired.

    Note also that this covers the generic case. However, for some specific cases, such as removing
    a pipe in a segment, this can lead to an invalid model.

    Parameters
    ----------
    dexpi_model : EngineeringModel
        The model to be searched for the object.
    dexpi_object : PyDexpiBaseModel
        The object to be removed from the model.

    Raises
    ------
    ValueError
        If the object is not found in the model.
    """

    all_instances = get_all_instances_in_model(dexpi_model)
    # Identity, not equality: `in` on a list of models runs pydantic's inherited
    # deep field comparison against every element. See remove_references_to_objects.
    if not any(instance is dexpi_object for instance in all_instances):
        raise ValueError("The object is not found in the model.")

    # Remove all references to the object in the model, including children
    remove_references_to_object(dexpi_model, dexpi_object)

    # Each object has exactly one composition parent in a well-formed model, so the
    # helper stops scanning as soon as it is found.
    _detach_from_composition_parents(all_instances, [dexpi_object])


def replace_object_in_model(
    dexpi_model: EngineeringModel,
    old_object: PyDexpiBaseModel,
    new_object: PyDexpiBaseModel,
    replace_obj_references: bool = True,
) -> None:
    """Replaces the given old_object with the new_object in the given dexpi_model.

    This is done by searching through the model's compositional and reference attributes to find
    the old object and replace it with the new object. This ensures that the object is replaced in
    both the model's compositional tree and the cross-references.

    Assumptions
    -----------
    Assumes that the old object is in the model's composition tree only once, as it should for
    a well-formed model. If the old object is found in multiple places, only the first occurrence
    will be replaced.

    Note that any references from the old object to other objects in the model are not removed or
    updated. These can be removed with remove_references_to_object, if desired.

    Note also that any nested references are not updated, as not to assume that the new object has
    the same nested structure as the old object. Instead, these references are removed. Nested
    references need to be updated manually on children of the new object, if desired.

    Parameters
    ----------
    dexpi_model : EngineeringModel
        The model to be searched for the old object.
    old_object : PyDexpiBaseModel
        The object to be replaced in the model.
    new_object : PyDexpiBaseModel
        The object to replace the old object with.
    replace_obj_references : bool, optional
        If True, the new object will be assigned the old object's references. If False, the
        new object will not be assigned the old object's references. By default, True.

    Raises
    ------
    ValueError
        If the old object is not found in the model.
    """

    all_instances = get_all_instances_in_model(dexpi_model)
    # Identity, not equality -- see remove_object_from_model.
    if not any(instance is old_object for instance in all_instances):
        raise ValueError("The old object is not found in the model.")

    # First, assign the new object the old object's references, if requested
    if replace_obj_references:
        for attr_name, attr_value in bmu.get_reference_attributes(old_object).items():
            setattr(new_object, attr_name, attr_value)

    # Next, remove all references to the old object in the model, including children
    remove_references_to_children(dexpi_model, old_object)

    composition_parent_found = False
    for instance in all_instances:
        # Get all compositional attributes
        attrs = bmu.get_composition_attributes(instance)

        for attr_name, attr_value in attrs.items():
            if isinstance(attr_value, PyDexpiBaseModel):
                if attr_value is old_object:
                    setattr(instance, attr_name, new_object)
                    composition_parent_found = True
                    break

            elif isinstance(attr_value, list) and any(item is old_object for item in attr_value):
                new_attr_value = [new_object if item is old_object else item for item in attr_value]
                setattr(instance, attr_name, new_attr_value)
                composition_parent_found = True
                break

        # Each object has exactly one composition parent in a well-formed model;
        # stop scanning once it is found.
        if composition_parent_found:
            break

        ref_attrs = bmu.get_reference_attributes(instance)
        for attr_name, attr_value in ref_attrs.items():
            if isinstance(attr_value, PyDexpiBaseModel):
                if attr_value is old_object:
                    setattr(instance, attr_name, new_object)

            elif isinstance(attr_value, list) and any(item is old_object for item in attr_value):
                new_attr_value = [new_object if item is old_object else item for item in attr_value]
                setattr(instance, attr_name, new_attr_value)
