"""Parser modules for Proteus XML loading.

In general, each module is responsible for parsing a specific type of element from the Proteus XML
structure. The modules rely on an external function that handles instantiation of the parsers for
an XML element."""

from __future__ import annotations

import datetime
import functools
import logging
import math
import re
import types
import typing
from typing import ClassVar, ForwardRef, Union, get_args, get_origin

from lxml import etree
from pydantic import ValidationError

import pydexpi.toolkits.piping_toolkit as ptk
from pydexpi.loaders.error_registry import ErrorLevels, InternalParserError
from pydexpi.loaders.proteus_serializer.proteus_parser.core import (
    ModuleContext,
    ParserModule,
)
from pydexpi.loaders.proteus_serializer.proteus_parser.parsing_utils import (
    ErrorTemplates,
    NoSuitableFieldError,
    add_by_inferring_type,
    filter_none,
    is_associated_with,
    redirect_errors_to_registry,
)
from pydexpi.pydexpi_classes import pydexpi_classes
from pydexpi.pydexpi_classes.core import (
    EngineeringModel,
    dataTypes,
    diagram as core_diagram,
    physicalQuantities,
)
from pydexpi.pydexpi_classes.plant import (
    PlantModel,
    diagram as plant_diagram,
    enumerations,
    instrumentation,
    piping,
    plantStructure,
    processEquipment,
)
from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
from pydexpi.toolkits import base_model_utils as bmt
from pydexpi.toolkits.diagram_toolkit import swept_arc_box
from pydexpi.toolkits.label_toolkit import FragmentSpec, build_text_template, render_text_template
from pydexpi.toolkits.quantity_units import (
    resolve_unit_for_attribute,
    spec_unit_bindings,
    unit_enum_for_attribute,
)

logger = logging.getLogger(__name__)


@functools.cache
def _spec_unit_bindings() -> dict:
    """``quantity_units.spec_unit_bindings``, computed once: it walks every generated class."""
    return spec_unit_bindings()


#: Proteus writes a CenterLine's end coordinates with the same digits as the
#: connection point they end at; the tolerance only absorbs float formatting.
_POINT_TOLERANCE = 1e-9


def _distance(a: core_diagram.Point, b: core_diagram.Point) -> float:
    return math.hypot(a.x - b.x, a.y - b.y)


def _same_point(a: core_diagram.Point, b: core_diagram.Point) -> bool:
    return _distance(a, b) <= _POINT_TOLERANCE


### GENERIC MODULES ###
@functools.cache
def _resolved_annotations(component_class: type) -> dict:
    """The class's type hints, with forward references resolved, cached per class.

    ``typing.get_type_hints`` rather than ``ForwardRef._evaluate``: that is private,
    and calling it without ``type_params`` is deprecated in 3.13 and disallowed in
    3.15 -- while ``type_params`` does not exist on 3.12, which this package also
    supports. The deprecation warning mattered beyond tidiness: it was raised inside
    the broad ``except`` below, so under a ``-W error`` run it was recorded as a
    registry error and discarded the whole attribute set.

    Returns an empty mapping if the hints cannot be resolved, leaving the caller with
    the unresolved annotation it already had.
    """
    try:
        return typing.get_type_hints(component_class)
    except Exception:  # pragma: no cover - a class whose hints cannot be built
        logger.debug("Cannot resolve type hints for %s", component_class, exc_info=True)
        return {}


class GenericAttributeParser(ParserModule):
    """Parses generic attributes from XML elements.

    Processes attribute sets (DexpiAttributes, CustomAttributes, DexpiCustomAttributes)
    and converts them into the appropriate format for DEXPI component classes. No reference or
    control pass is required.

    Attributes
    ----------
    valid_attribute_lists : list of str (class attribute)
        Valid attribute set types according to DEXPI standards.
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the attributes to be parsed.
    """

    valid_attribute_lists: ClassVar[list[str]] = [
        "DexpiAttributes",
        "CustomAttributes",
        "DexpiCustomAttributes",
    ]

    def __init__(
        self,
        context: ModuleContext,
        parent_element: etree._Element,
    ) -> None:
        """Initialize the GenericAttributeParser.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        parent_element : etree._Element
            The XML element containing the attributes to be parsed.
        """
        super().__init__(context, parent_element)

    def compositional_pass(
        self,
        component_class: type[PyDexpiBaseModel],
    ) -> dict:
        """Parse all attributes in the compositional pass.

        The attributes are retrieved from all valid generic attribute sets in the XML element. The
        attributes are then merged into a single dictionary, with duplicate attributes checked and
        logged as errors.

        Parameters
        ----------
        component_class : type[PyDexpiBaseModel]
            The DEXPI component class for which attributes are being parsed.

        Returns
        -------
        dict
            A dictionary of parsed attributes, where keys are attribute names and values are the
            corresponding attribute values in the DEXPI format.
        """
        # Get all attribute sets from the XML element
        attr_set_elements = self.element.findall("GenericAttributes")

        generic_attr_sets = [
            self.parse_single_attribute_set(attr_set, component_class)
            for attr_set in attr_set_elements
        ]

        # Check for duplicate attributes across all sets
        duplicates = GenericAttributeParser.check_for_duplicates(generic_attr_sets)
        if duplicates:
            self.register_error(
                f"Duplicate attributes found: {', '.join(duplicates)}. Duplicates ignored.",
                level=ErrorLevels.ERROR,
            )

        # Merge all generic attributes into a single dictionary
        all_generic_attributes = GenericAttributeParser.merge_attributes(generic_attr_sets)
        return all_generic_attributes

    def _parse_quantity(self, attribute: etree._Element, name: str, unit_class: type):
        """Build one physical quantity from a Proteus generic attribute.

        The unit comes from the element's own ``Units``, resolved against the
        attribute's dimension by ``quantity_units.resolve_unit_for_attribute``.
        It cannot come from the field's annotation: every
        quantity field is annotated ``PhysicalQuantity``, whose ``unit`` is the
        memberless base enum, so the annotation names no literal. Passing it
        raised a validation error that the caller's broad ``except`` turned into
        the loss of *every* attribute in the set -- 47 sets across 9 of the 35
        training cases.

        Returns None when the attribute cannot be read, having recorded why; the
        caller then skips that one attribute and keeps the rest.
        """
        value = attribute.get("Value")
        try:
            magnitude = float(value)
        except (TypeError, ValueError):
            self.register_error(
                f"Attribute {name!r} has a non-numeric value {value!r} for a physical quantity; "
                "attribute skipped.",
                level=ErrorLevels.WARNING,
            )
            return None

        units = attribute.get("Units")
        if units is None:
            self.register_error(
                f"Attribute {name!r} carries a physical quantity with no Units; attribute skipped.",
                level=ErrorLevels.WARNING,
            )
            return None

        try:
            unit = resolve_unit_for_attribute(name, units)
        except ValueError:
            unit = self._assumed_unit(name, units)
            if unit is None:
                self.register_error(
                    f"Attribute {name!r} carries the unit {units!r}, which does not resolve to a "
                    "unit of that attribute's dimension; attribute skipped.",
                    level=ErrorLevels.WARNING,
                )
                return None

        return unit_class(value=magnitude, unit=unit)

    #: Where a Proteus unit literal is shared by two leaves of one dimension and the
    #: specification binds the attribute to neither leaf alone, the leaf a Proteus file means.
    #: Proteus writes a bare ``Units="Bar"`` and a PCA RDL URI that does not distinguish gauge
    #: from absolute (``RDS1314539``, whose RDL export is incomplete), so the file itself
    #: carries no way to tell. DEXPI 2.0.1 does, per attribute: it binds
    #: ``upperLimitDesignPressure`` to ``PressureGaugeUnit`` and ``differentialPressure`` to
    #: ``PressureAbsoluteUnit``, and that binding is read first (``quantity_units`` widens both
    #: to the shared parent for a client, so the parent alone cannot answer). This table is the
    #: fallback for a name the specification binds to both leaves, or to the parent. The corpus
    #: settles it for pressure: ``data/reference_pid.xml`` is DEXPI's own DEXPI 2.0 rendering
    #: of the plant in ``C01V04-VER.EX01.xml``, and it carries those same values (-1, 60, -1,
    #: 30) as ``PressureGaugeUnit.Bar``, never absolute. Either way the assumption is recorded
    #: per attribute at INFO so a reader can see it was made.
    _AMBIGUOUS_UNIT_LEAVES: ClassVar[dict[str, str]] = {"PressureUnit": "PressureGaugeUnit"}

    def _assumed_unit(self, name: str, units: str):
        """The leaf unit assumed for a literal two leaves of one dimension share."""
        scope = unit_enum_for_attribute(name)
        if scope is None:
            return None
        bound = _spec_unit_bindings().get(name, frozenset())
        if len(bound) == 1 and next(iter(bound)) is not scope:
            leaf = next(iter(bound))
            reason = f"as DEXPI 2.0.1 binds {name!r} to {leaf.__name__}"
        else:
            leaf_name = self._AMBIGUOUS_UNIT_LEAVES.get(scope.__name__)
            leaf = getattr(physicalQuantities, leaf_name, None) if leaf_name else None
            reason = "as DEXPI's own rendering of this plant does"
        if leaf is None:
            return None
        try:
            unit = leaf(units)
        except ValueError:
            return None
        self.register_error(
            f"Attribute {name!r} carries the unit {units!r}, which {scope.__name__} leaves "
            f"ambiguous; read as {leaf.__name__}.{unit.value}, {reason}.",
            level=ErrorLevels.INFO,
        )
        return unit

    def parse_single_attribute_set(
        self,
        element: etree._Element,
        component_class: type[PyDexpiBaseModel],
    ) -> dict:
        """Parse a single attribute set from an attribute set XML element.

        Parameters
        ----------
        element : etree._Element
            The XML element containing the attribute set to be parsed.
        component_class : type[PyDexpiBaseModel]
            The DEXPI component class for which attributes are being parsed.

        Returns
        -------
        dict
            A dictionary of parsed attributes for the given attribute set.
        """
        try:
            attributes = {}
            attr_set_type = element.get("Set")
            component_attributes = component_class.model_fields
            multi_language_strings = {}

            # If attribute set type is not recognized, log a warning and return empty attributes
            if attr_set_type not in self.valid_attribute_lists:
                self.register_error(
                    f"Invalid attribute set discovered: {attr_set_type}. Attributes ignored.",
                    level=ErrorLevels.WARNING,
                )
                return attributes

            for attribute in element.iterchildren(tag=etree.Element):
                # Edit proteus attribute name to correspond to DEXPI class field.
                name = attribute.get("Name")
                name = name.removesuffix("AssignmentClass")
                name = name.removesuffix("Specialization")
                name = name[0].lower() + name[1:]
                # Only parse an attribute if it exists both in proteus and DEXPI.
                if name in component_attributes:
                    value = attribute.get("Value")
                    # skip attribute if value is not given
                    if value is None:
                        continue
                    field_annotation = component_attributes[name].annotation
                    if isinstance(field_annotation, ForwardRef):
                        field_annotation = _resolved_annotations(component_class).get(
                            name, field_annotation
                        )

                    if get_origin(field_annotation) in {Union, types.UnionType}:
                        unit = get_args(field_annotation)[0]
                    else:
                        unit = field_annotation

                    unit_name = unit.__name__
                    if unit is str:
                        attributes[name] = str(value)
                    elif unit is int:
                        attributes[name] = int(value)
                    elif unit is dataTypes.MultiLanguageString:
                        if name not in multi_language_strings:
                            multi_language_strings[name] = []
                        single_language_string = dataTypes.SingleLanguageString(
                            language=attribute.get("Language"),
                            value=attribute.get("Value"),
                        )
                        multi_language_strings[name].append(single_language_string)
                    elif hasattr(physicalQuantities, unit_name):
                        # null value for a physical quantity is currently not implemented
                        unit_name = unit_name.removeprefix("Nullable")
                        unit_class = getattr(physicalQuantities, unit_name)
                        quantity = self._parse_quantity(attribute, name, unit_class)
                        if quantity is None:
                            continue
                        attributes[name] = quantity
                    elif hasattr(enumerations, unit_name):
                        unit_class = getattr(enumerations, unit_name)
                        attributes[name] = unit_class(value)
                    # Fallback: Look it up in all dexpi classes
                    elif hasattr(pydexpi_classes, unit_name):
                        unit_class = getattr(pydexpi_classes, unit_name)
                        attributes[name] = unit_class(value)
                    else:
                        self.register_error(
                            f"Unsupported attribute type for {name}: {unit_name}. "
                            "Attribute ignored.",
                            level=ErrorLevels.ERROR,
                        )
        except Exception as e:
            # Broad exception handler: an attribute set can contain many different
            # attribute types, so a malformed value can raise arbitrary runtime
            # errors. Record the issue and continue with an empty attribute set.
            logger.debug("Error parsing attributes", exc_info=True)
            self.register_error(
                f"Error parsing attributes: {e}",
                level=ErrorLevels.ERROR,
                proteus_id=self.context.get_last_id(),
                exception=e,
            )
            attributes = {}

        return attributes

    @staticmethod
    def check_for_duplicates(attribute_sets: list[dict]) -> set[str]:
        """Check for duplicate attribute names across multiple attribute sets.

        Parameters
        ----------
        attribute_sets : list of dict
            A list of dictionaries representing attribute sets.

        Returns
        -------
        set of str
            A set of duplicate attribute names.
        """
        seen = set()
        duplicates = set()
        for attributes in attribute_sets:
            for name in attributes:
                if name in seen:
                    duplicates.add(name)
                else:
                    seen.add(name)
        return duplicates

    @staticmethod
    def merge_attributes(attribute_sets: list[dict]) -> dict:
        """Merge multiple attribute sets into a single dictionary. Duplicates are skipped.

        Parameters
        ----------
        attribute_sets : list of dict
            A list of dictionaries representing attribute sets, where each dictionary contains
            attribute names as keys.

        Returns
        -------
        dict
            A dictionary containing all attributes from the provided sets, with duplicates handled.
        """
        merged_attributes = {}
        for attributes in attribute_sets:
            for name, value in attributes.items():
                if name not in merged_attributes:
                    merged_attributes[name] = value
        return merged_attributes


class AssociationParser(ParserModule):
    """Parser for association elements in the Proteus XML structure.

    This class is responsible for parsing association elements, retrieving the respective objects
    in the reference pass, providing all necessary information, and check validity of the
    association. Retrieves the element ID and type during compositional pass, and retrieves the
    associated object in the reference pass. No control pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the association to be parsed.
    association_id : str
        The ID of the association, retrieved from the XML element.
    association_type : str
        The type of the association, retrieved from the XML element.
    referenced_item : PyDexpiBaseModel
        The DEXPI object associated with this association, retrieved in the reference pass.
    """

    def __init__(self, context: ModuleContext, element: etree._Element) -> None:
        """Initialize the AssociationParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the association to be parsed.
        """
        super().__init__(context, element)

        self.association_id = None
        self.association_type = None
        self.referenced_item = None

    @redirect_errors_to_registry
    def compositional_pass(self) -> None:
        """Parse the association in the compositional pass by retrieving the ID and type.

        Returns
        -------
        None
            This method does not return any value, as no object is created in this pass.
        """
        # Get the ID of the association
        if self.element is not None:
            self.association_id = self.element.get("ItemID")
            self.association_type = self.element.get("Type")

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Retrieve the referenced item from the context's object registry.

        This method attempts to find the associated object in the context's object registry using
        the association ID. If found, it sets `referenced_item` to the associated object.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Retrieve the referenced item from the context's object registry
        if self.association_id is not None:
            self.referenced_item = self.get_object_from_registry(self.association_id)

    def is_valid(self) -> bool:
        """Check if the association is valid.

        An association is considered valid if it has a valid ID, type, and referenced item (not
        None).

        Returns
        -------
        bool
            True if the association is valid, False otherwise.
        """
        return (
            self.association_id is not None
            and self.association_type is not None
            and self.referenced_item is not None
        )

    def get_error_message(self) -> str:
        """Get the error message for an invalid association.

        Returns
        -------
        str
            An error message indicating the issue with the association.
        """
        if self.association_id is None:
            return "Association ItemID is missing in the XML element. Association skipped."
        elif self.association_type is None:
            return "Association Type is missing in the XML element. Association skipped."
        elif self.referenced_item is None:
            return (
                f"Associated object with ID {self.association_id} not found. Association skipped."
            )
        else:
            raise RuntimeError("No error in this association parser.")

    def get_id(self) -> str:
        """Get the ID of the associated object.

        Returns
        -------
        str
            The ID of the associated object.
        """
        return self.association_id

    def get_type(self) -> str:
        """Get the type of the association.

        Returns
        -------
        str
            The type of the association.
        """
        return self.association_type

    def get_referenced_item(self) -> PyDexpiBaseModel:
        """Get the referenced item of the association.

        The referenced item is previously retrieved in the reference pass.

        Returns
        -------
        PyDexpiBaseModel
            The DEXPI object associated with this association.
        """
        return self.referenced_item


class OffPageConnectorReferenceParser(ParserModule):
    """Parser for OffPageConnectorReference elements in the DEXPI model.

    This parser handles both OffPageConnectorObjectReference and OffPageConnectorReferenceByNumber
    for both piping and information flow elements. The correct type is retrieved from the
    ComponentClass Element. In the compositional pass,
    it composes the generic attributes and creates the appropriate OffPageConnectorReference object.
    In the reference pass, it resolves associations and sets the referenced connector if the
    reference is an object reference.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the pipe off-page connector reference to be parsed.
    association_parsers : list[AssociationParser]
        List of association parsers to be used by the pipe off-page connector reference parser.
    generic_attribute_parser : GenericAttributeParser
        The parser for generic attributes.
    reference_obj : piping.PipeOffPageConnectorReference |
                    instrumentation.SignalOffPageConnectorReference |
                    None
        The reference object being constructed by the parser. It can be either a
        PipeOffPageConnectorReference or a SignalOffPageConnectorReference, depending on the
        context.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        text_parsers: list[TextParser] | None = None,
    ) -> None:
        """Initialize the OffPageConnectorReferenceParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The module context providing access to the ID stack and error registry.
        element : etree._Element
            The XML element containing the pipe off-page connector reference to be parsed.
        association_parsers : list[AssociationParser]
            List of association parsers to be used by the pipe off-page connector reference parser.
        generic_attribute_parser : GenericAttributeParser
            The parser for generic attributes.
        """
        super().__init__(context, element)
        self.text_parsers = text_parsers or []
        self.register_submodule_list(self.text_parsers)
        self.ref_id = None
        self.reference_obj = None

        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

    @redirect_errors_to_registry
    def compositional_pass(
        self,
    ) -> (
        piping.PipeOffPageConnectorReference
        | instrumentation.SignalOffPageConnectorReference
        | None
    ):
        """Parse the pipe off-page connector reference in the compositional pass.

        This method retrieves the ID of the reference, determines the class type from the
        ComponentClass attribute, retrieves the class from the piping or instrumentation module,
        composes the generic attributes, and creates an instance of the appropriate reference class.
        It registers the reference object in the context's object registry.

        Returns
        -------
        piping.PipeOffPageConnectorReference | instrumentation.SignalOffPageConnectorReference | None
            An instance of the PipeOffPageConnectorReference or SignalOffPageConnectorReference class
            created from the parsed data, or None if an error occurs.
        """
        # Get element ID. If not available, log an error.
        self.ref_id = self.element.get("ID")
        if self.ref_id is None:
            self.register_error(*ErrorTemplates.id_not_found("OffPageConnectorReference"))
            return None

        # Determine the class type from the ComponentClass attribute
        class_name = self.element.get("ComponentClass")

        # Retrieve the class from the piping or the instrumentation module
        try:
            ParserClass = getattr(piping, class_name)
        except AttributeError:
            try:
                ParserClass = getattr(instrumentation, class_name)
            except AttributeError:
                self.register_error(
                    f"Unknown ComponentClass '{class_name}' for pipe off-page connector reference.",
                    level=ErrorLevels.ERROR,
                )
                return None

        # Compose generic attributes
        generic_attributes = self.generic_attribute_parser.compositional_pass(ParserClass)

        # Compose the associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Create a PipeOffPageConnectorReference with the composed attributes
        self.reference_obj = ParserClass(id=self.ref_id, **generic_attributes)

        # Register the pipe off-page connector reference
        self.register_object(self.ref_id, self.reference_obj)

        return self.reference_obj

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Keep the reference's nested text under its own drawing, with faithful templates."""
        if self.reference_obj is None:
            return None
        texts = []
        for parser in self.text_parsers:
            text = parser.compositional_pass()
            if text is None:
                continue
            refs = parser.element.findall("TextStringFormatSpecification/ObjectAttributesReference")
            if refs and all(ref.get("ItemID") == self.ref_id for ref in refs):
                fragments = [
                    FragmentSpec(
                        attribute=(ref.get("DependantAttribute") or "").removesuffix(
                            "AssignmentClass"
                        )
                    )
                    for ref in refs
                ]
                try:
                    template = build_text_template(self.reference_obj, fragments)
                except ValueError:
                    pass  # Unknown format attributes keep the parsed text unchanged.
                else:
                    if render_text_template(template) == text.text:
                        text.template = template
            texts.append(text)
        if not texts:
            return None
        return core_diagram.RepresentationGroup(
            represents=self.reference_obj, groups=[core_diagram.Label(elements=texts)]
        )

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Perform a reference pass over the pipe off-page connector reference.

        Establishes associations for the pipe off-page connector reference if it is a reference
        by object. If the reference is a reference by number, no associations are allowed.
        """

        # Call super().reference_pass() to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if not self.reference_obj or not self.ref_id:
            self.register_error(*ErrorTemplates.skip_pass("reference", "OffPageConnectorReference"))
            return

        if isinstance(
            self.reference_obj,
            piping.PipeOffPageConnectorObjectReference
            | instrumentation.SignalOffPageConnectorObjectReference,
        ):
            # If the reference is an object reference, resolve associations
            for association_parser in self.association_parsers:
                assoc_type = association_parser.get_type()
                if not association_parser.is_valid():
                    # Log error and skip association
                    self.register_error(
                        association_parser.get_error_message(),
                        level=ErrorLevels.ERROR,
                    )
                    continue

                elif assoc_type != "refers to":
                    # Not permitted for off-page connector references, add warning
                    self.register_error(
                        *ErrorTemplates.inval_assoc_type("OffPageConnectorReference", assoc_type)
                    )
                    continue
                else:
                    associated_object = association_parser.get_referenced_item()
                    associated_id = association_parser.get_id()

                    try:
                        self.reference_obj.referencedConnector = associated_object
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_adding_error(
                                "OffPageConnectorReference",
                                associated_id,
                            ),
                            exception=e,
                        )
        # If the reference is a reference by number, no associations are allowed.
        elif self.association_parsers:
            self.register_error(
                "Associations are not allowed for OffPageConnectorReference by number. "
                "Associations skipped.",
                level=ErrorLevels.WARNING,
            )


### EQUIPMENT MODULES ###
class NozzleParser(ParserModule):
    """The NozzleParser is a module for parsing nozzles from XML elements.

    This class processes nozzle elements and converts them into DEXPI nozzles. It has connection
    point parsers to parse the relevant connection points. No reference pass is required, but
    control pass is performed to check associations.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the nozzles to be parsed.
    connection_point_parsers : list[ConnectionPointParser]
        List of connection point parsers to be used by the nozzle parser.
    association_parsers : list[AssociationParser]
        List of association parsers to be used by the nozzle parser.
    generic_attribute_parser : GenericAttributeParser
        Generic attribute parser to be used by the nozzle parser.
    nozzle_obj : processEquipment.Nozzle
        The DEXPI nozzle object created from the parsed attributes and connection points.
    nozzle_id : str
        The ID of the DEXPI nozzle object."""

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        connection_point_parsers: list[ConnectionPointParser],
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        shape_usage_parser: ShapeUsageParser,
        label_parsers: list[LabelParser],
    ) -> None:
        """Initialize the NozzleParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the nozzle to be parsed.
        connection_point_parsers : list[ConnectionPointParser]
            List of connection point parsers to be used by the nozzle parser.
        association_parsers : list[AssociationParser]
            List of association parsers to be used by the nozzle parser.
        generic_attribute_parser : GenericAttributeParser
            Generic attribute parser to be used by the nozzle parser.
        """
        super().__init__(context, element)
        self.nozzle_id = None
        self.nozzle_obj = None
        self.nozzle_dwg = None

        # Set and register connection point parsers
        self.connection_point_parsers = connection_point_parsers
        self.register_submodule_list(connection_point_parsers)

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register shape usage parser
        self.shape_usage_parser = shape_usage_parser
        self.register_submodule(shape_usage_parser)

        # Set and register label parsers
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> processEquipment.Nozzle | None:
        """Parse the nozzle in the compositional pass.

        This method retrieves the nozzle ID, composes connection points, and merges generic
        attributes. It creates an instance of the Nozzle class with the composed attributes and
        registers it. In the reference pass, it establishes the reference to the chamber attribute
        if available. The control pass checks for any missed "is located in" and "is the location
        of" associations and attempts to establish them by inference if missing.

        Returns
        -------
        processEquipment.Nozzle | None
            The Nozzle class created with the parsed attributes and connection points, or None if
            an error occurs.
        """

        # Get the ID of the nozzle. If not available, log an error.
        self.nozzle_id = self.element.get("ID")
        if self.nozzle_id is None:
            self.register_error(*ErrorTemplates.id_not_found("Nozzle"))
            return None

        # Compose connection points
        piping_nodes = []
        for connection_point_parser in self.connection_point_parsers:
            parsed_nodes = connection_point_parser.compositional_pass()
            if parsed_nodes is not None:
                piping_nodes.extend(parsed_nodes)

        # Compose association parsers
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attributes = self.generic_attribute_parser.compositional_pass(
            processEquipment.Nozzle
        )

        # Make nozzle
        nozzle_kwargs = generic_attributes.copy()
        nozzle_kwargs["nodes"] = filter_none(piping_nodes)

        new_nozzle = processEquipment.Nozzle(id=self.nozzle_id, **nozzle_kwargs)
        self.nozzle_obj = new_nozzle

        # Register nozzle
        self.register_object(self.nozzle_id, new_nozzle)

        return new_nozzle

    @redirect_errors_to_registry
    def reference_pass(self):
        """Perform a reference pass to collect the nozzle's referenced chambers"""
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.nozzle_obj and self.nozzle_id):
            self.register_error(*ErrorTemplates.skip_pass("reference", "Nozzle"))
            return

        # Get and add associated elements
        for association_parser in self.association_parsers:
            # If associated ID is not available, log an error and skip the association
            if not association_parser.is_valid():
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            assoc_object = association_parser.get_referenced_item()
            assoc_id = association_parser.get_id()
            assoc_type = association_parser.get_type()
            if assoc_type == "is located in":
                try:
                    self.nozzle_obj.chamber = assoc_object
                except (ValidationError, TypeError) as e:
                    logger.debug(
                        "Error adding chamber reference to nozzle %s", assoc_id, exc_info=True
                    )
                    self.register_error(
                        f"Error encountered trying to add chamber reference to {assoc_id} to "
                        f"nozzle: {e}",
                        ErrorLevels.ERROR,
                        exception=e,
                    )

            elif assoc_type == "is the location of":
                # Handled in control pass, so skipped here
                pass
            else:
                # Not permitted for nozzles, add warning
                self.register_error(
                    f"Association of type {assoc_type} is not "
                    "permitted for nozzles. Association skipped.",
                    level=ErrorLevels.WARNING,
                )

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Perform a control pass over the nozzle's associations.

        Iterate over association elements and check if they are valid. If they are valid, but not
        created during the compositional pass, attempt to recover the association by adding it
        by inferring type. Log all inconsistencies encountered.
        """
        # Call super.control_pass() to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.nozzle_obj and self.nozzle_id):
            self.register_error(*ErrorTemplates.skip_pass("control", "Nozzle"))
            return

        # Otherwise, proceed with control pass
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            elif association_parser.get_type() not in ["is located in", "is the location of"]:
                # Not permitted for nozzles, but warning already added in reference pass.
                pass

            else:
                associated_object = association_parser.get_referenced_item()
                association_id = association_parser.get_id()
                if not (
                    is_associated_with(self.nozzle_obj, associated_object)
                    or is_associated_with(associated_object, self.nozzle_obj)
                ):
                    # Log warning and try to add association in control pass
                    self.register_error(*ErrorTemplates.no_assoc_ctrl("Nozzle", association_id))
                    try:
                        fld = add_by_inferring_type(self.nozzle_obj, associated_object)
                        # Log an info error if the association was added in control pass
                        inf = ErrorTemplates.assoc_added_ctrl("Nozzle", association_id, fld)
                        self.register_error(*inf)
                    except ValueError:
                        # Try adding association in reverse order
                        try:
                            fld = add_by_inferring_type(associated_object, self.nozzle_obj)
                            # Log an info error if the association was added in control pass
                            inf = ErrorTemplates.assoc_added_ctrl("Nozzle", association_id, fld)
                            self.register_error(*inf)
                        except ValueError as e:
                            # If the association cannot be added, log an error
                            self.register_error(
                                *ErrorTemplates.assoc_not_added_ctrl("Nozzle", association_id),
                                exception=e,
                            )

    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the nozzle."""

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process shape usage
        shape_usage = self.shape_usage_parser.drawing_pass()
        if shape_usage:
            static = core_diagram.Static(elements=[shape_usage])
            groups.append(static)

        # Process labels
        labels = [parser.drawing_pass() for parser in self.label_parsers]
        labels = filter_none(labels)
        groups.extend(labels)

        self.nozzle_dwg = core_diagram.RepresentationGroup(
            represents=self.nozzle_obj, groups=groups, nodePositions=node_positions
        )

        # Process node positions from connection points
        connection_points_dict = {}
        for parser in self.connection_point_parsers:
            cp_dict = parser.drawing_pass()
            if cp_dict:
                connection_points_dict.update(cp_dict)

        # Separate PipingNodePosition and InstrumentationNodePosition
        piping_positions = []
        instrumentation_positions = []

        # Process the positions from the dictionary values
        for position in connection_points_dict.values():
            if isinstance(position, plant_diagram.PipingNodePosition):
                piping_positions.append(position)
            elif isinstance(position, plant_diagram.InstrumentationNodePosition):
                instrumentation_positions.append(position)

        # Add piping positions as connection points in a RepresentationGroup
        if piping_positions:
            connection_point = core_diagram.RepresentationGroup(
                represents=self.nozzle_obj, groups=[], nodePositions=piping_positions
            )
            self.nozzle_dwg.groups.append(connection_point)

        # Add instrumentation positions directly to the main node_positions
        if instrumentation_positions:
            self.nozzle_dwg.nodePositions.extend(instrumentation_positions)

        self.register_object(f"{self.nozzle_id}_cp_node_positions", connection_points_dict)

        return self.nozzle_dwg


def detached_equipment(parser: EquipmentParser) -> list[processEquipment.ProcessEquipment]:
    """Sub-equipment of `parser`'s tree that no parent could hold, depth first.

    A detached child is not attached anywhere, so its own detached children are
    collected too: every element ends up either attached or in this list, once.
    """
    found = list(parser.detached_subequipment)
    for sub in parser.subequipment_parsers:
        found += detached_equipment(sub)
    return found


class EquipmentParser(ParserModule):
    """The EquipmentParser is a module for parsing equipment from XML elements.

    This class processes equipment elements and converts them into DEXPI equipment classes. Includes
    nozzles, subequipment, associations, and generic attributes. Establishes the "is location of"
    relationships in the reference pass, and attempts to recover "is located in" and "is location
    of" relationships in the control pass.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the equipment to be parsed.
    nozzle_parsers : list[NozzleParser]
        List of nozzle parsers to be used by the equipment parser.
    subequipment_parsers : list[EquipmentParser]
        List of subequipment parsers to be used by the equipment parser.
    association_parsers : list[AssociationParser]
        List of association parsers to be used by the equipment parser.
    generic_attribute_parser : GenericAttributeParser
        The generic attribute parser to be used by the equipment parser.
    shape_usage_parser : ShapeUsageParser
        The shape usage parser to be used by the equipment parser.
    graphical_primitive_parsers : list[GraphicalPrimitiveParser]
        List of graphical primitive parsers to be used by the equipment parser.
    label_parsers : list[LabelParser]
        List of label parsers to be used by the equipment parser.
    equipment_obj : processEquipment.Equipment
        The equipment object being constructed by the parser.
    equipment_id : str
        The ID of the equipment being constructed.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        nozzle_parsers: list[NozzleParser],
        subequipment_parsers: list[EquipmentParser],
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        shape_usage_parser: ShapeUsageParser,
        graphical_primitive_parsers: list[GraphicalPrimitiveParser],
        label_parsers: list[LabelParser],
    ) -> None:
        """Initialize the EquipmentParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the equipment to be parsed.
        nozzle_parsers : list[NozzleParser]
            List of nozzle parsers to be used by the equipment parser.
        subequipment_parsers : list[EquipmentParser]
            List of subequipment parsers to be used by the equipment parser.
        association_parsers : list[AssociationParser]
            List of association parsers to be used by the equipment parser.
        generic_attribute_parser : GenericAttributeParser
            The generic attribute parser to be used by the equipment parser.
        shape_usage_parser : ShapeUsageParser
            The shape usage parser to be used by the equipment parser.
        graphical_primitive_parsers : list[GraphicalPrimitiveParser]
            List of graphical primitive parsers to be used by the equipment parser.
        label_parsers : list[LabelParser]
            List of label parsers to be used by the equipment parser.
        """
        super().__init__(context, element)
        self.equipment_obj = None
        self.equipment_id = None
        self.equipment_dwg = None

        # Initialize parser for nozzles
        self.nozzle_parsers = nozzle_parsers
        self.register_submodule_list(nozzle_parsers)

        # Initialize parser for subequipment
        self.subequipment_parsers = subequipment_parsers
        self.register_submodule_list(subequipment_parsers)
        # Sub-equipment the equipment class has no field for. It is kept, not
        # dropped: PlantModelParser places it at plant level (see detached_equipment).
        self.detached_subequipment: list[processEquipment.ProcessEquipment] = []

        # Initialize parser for associations
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Initialize parser for generic attributes
        self.gen_attr_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Initialize parser for shape usage
        self.shape_usage_parser = shape_usage_parser
        # There is a possibility that shape usage parser is None, e.g. for subequipment
        if shape_usage_parser is not None:
            self.register_submodule(shape_usage_parser)

        # Initialize parsers for graphical primitives
        self.graphical_primitive_parsers = graphical_primitive_parsers
        self.register_submodule_list(graphical_primitive_parsers)

        # Initialize parser for labels
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> processEquipment.ProcessEquipment | None:
        """Perform a compositional pass over the equipment and its components.

        This method processes the equipment element and its subcomponents, including nozzles and
        subequipment, to create a equipment object. The type is inferred from the ComponentClass XML
        attribute. For this, the value of Component class is retrieved from the equipment pyDEXPI
        equipment package. If None is found, a warning is logged and the equipment is treated as
        CustomprocessEquipment.

        Returns
        -------
        processEquipment.Equipment | None
            The constructed equipment object if successful, or None if an error occurs during
            parsing.
        """
        # Get the ID of the processEquipment. If not available, log an error.
        self.equipment_id = self.element.get("ID")
        if self.equipment_id is None:
            self.register_error(*ErrorTemplates.id_not_found("Equipment"))
            return None

        kwargs = {}

        # Get the equipment type
        class_name = self.element.get("ComponentClass")

        # Manage the differentiation between subtagged and tagged column sections
        if class_name == "ColumnSection":
            class_name = (
                "TaggedColumnSection"
                if self.context.element_stack[-2] != "Equipment"
                else "SubTaggedColumnSection"
            )

        # If class name not part of equipment, fall back to the generic ProcessEquipment class.
        # TypeError covers a missing ComponentClass attribute (class_name is None).
        try:
            MyClass = getattr(processEquipment, class_name)
        except (AttributeError, TypeError):
            MyClass = processEquipment.ProcessEquipment

            # Log a warning that the class name is invalid
            self.register_error(
                f"Unknown ComponentClass {class_name!r} for processEquipment. Using generic "
                f"ProcessEquipment instead.",
                level=ErrorLevels.WARNING,
            )

        # Process nozzles
        nozzles = [parser.compositional_pass() for parser in self.nozzle_parsers]
        if nozzles:
            kwargs["nozzles"] = filter_none(nozzles)

        # Process subequipment
        subequipment = filter_none(
            [parser.compositional_pass() for parser in self.subequipment_parsers]
        )

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Process generic attributes
        generic_attributes = self.gen_attr_parser.compositional_pass(MyClass)
        kwargs.update(generic_attributes)

        # Create the equipment object
        equipment_obj = MyClass(id=self.equipment_id, **kwargs)

        # Add subequipment by inferring type. A child this class has no field for (e.g. a
        # COMOS motor of unknown class under a Pump) is kept for plant level instead of
        # failing the whole equipment. Only that case is recovered: any other error
        # still goes to the registry through redirect_errors_to_registry.
        for subequipment_item in subequipment:
            try:
                add_by_inferring_type(subequipment_item, equipment_obj)
            except NoSuitableFieldError:
                self.detached_subequipment.append(subequipment_item)
                self.register_error(
                    f"Sub-equipment {subequipment_item.id!r} "
                    f"({type(subequipment_item).__name__}) cannot be attached to "
                    f"{self.equipment_id!r} ({type(equipment_obj).__name__}); moved to plant "
                    f"level, the parent-child relation is not kept.",
                    level=ErrorLevels.WARNING,
                    proteus_id=subequipment_item.id,
                )

        # Register the equipment object
        self.register_object(self.equipment_id, equipment_obj)

        self.equipment_obj = equipment_obj
        return equipment_obj

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Perform a reference pass over the equipment's associations.

        This method processes the associations of the equipment by iterating through the association
        elements of type "is the location of". It retrieves associated objects and adds them to the
        equipment object by inferring the type from the field annotation.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.equipment_obj and self.equipment_id):
            self.register_error(*ErrorTemplates.skip_pass("reference", "Equipment"))
            return

        # Get and add associated elements
        for association_parser in self.association_parsers:
            # If associated ID is not available, log an error and skip the association
            if not association_parser.is_valid():
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            # Add the associated object by inferring type. Skip nozzle associations, they are
            # handled by nozzle parsers.
            assoc_object = association_parser.get_referenced_item()
            assoc_id = association_parser.get_id()
            assoc_type = association_parser.get_type()
            if assoc_type == "is the location of" and not isinstance(
                assoc_object, processEquipment.Nozzle
            ):
                try:
                    add_by_inferring_type(assoc_object, self.equipment_obj)
                    # This error handling is necessary because sometimes the association
                    # is the other way around for reference attributes in dexpi
                except ValueError:
                    try:
                        add_by_inferring_type(self.equipment_obj, assoc_object)
                        # Log info error if the association was added in reverse
                        self.register_error(
                            f"Association {self.equipment_id} with {assoc_id} added in "
                            "reverse order.",
                            level=ErrorLevels.INFO,
                        )
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_adding_error("Equipment", assoc_id),
                            exception=e,
                        )
            elif assoc_type == "is the location of" and isinstance(
                assoc_object, processEquipment.Nozzle
            ):
                # This association is handled in control pass, so we skip it here
                pass
            elif association_parser.get_type() in ("is located in", "is a part of"):
                # Both are inverses of what PlantStructureItemParser writes, which
                # owns the plant-structure axes. The control pass below
                # checks each one landed and recovers it if the document states it
                # from this side only.
                pass
            else:
                # Not permitted for equipment, add warning
                self.register_error(*ErrorTemplates.inval_assoc_type("Equipment", assoc_type))

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Perform a control pass over the equipment's associations.

        This method checks if all associations have been made correctly by checking the
        complementary association element. For this, it checks the associations of type
        "is located in" and "is the location of". Any association that is not previously established
        will be attempted to be recovered by adding it by inferring type.
        """
        # Call super.control_pass() to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.equipment_obj and self.equipment_id):
            self.register_error(*ErrorTemplates.skip_pass("control", "Equipment"))
            return

        # Otherwise, proceed with control pass
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            else:
                associated_object = association_parser.get_referenced_item()
                associated_id = association_parser.get_id()
                if association_parser.get_type() == "is the location of" and not isinstance(
                    associated_object, processEquipment.Nozzle
                ):
                    # Handled in reference pass
                    pass
                elif association_parser.get_type() == "is a part of":
                    # PlantStructureItemParser owns the part-of axis and writes it
                    # from the "is a collection including" side, so for a
                    # document that states the link both ways -- the Proteus norm,
                    # and true of all 45 structural links in the training test
                    # cases -- the guard below makes this a no-op. It is here for
                    # the document that states it on the equipment only, where
                    # nothing else in the parser tree would ever see it.
                    if not (
                        is_associated_with(self.equipment_obj, associated_object)
                        or is_associated_with(associated_object, self.equipment_obj)
                    ):
                        self.register_error(
                            *ErrorTemplates.no_assoc_ctrl("Equipment", associated_id)
                        )
                        # Explicitly, not by inferring the field: parentStructure is
                        # named, and the *ParentStructure marker mixins already say
                        # which parents are legal.
                        reason = set_parent_structure(self.equipment_obj, associated_object)
                        if reason is None:
                            self.register_error(
                                *ErrorTemplates.assoc_added_ctrl(
                                    "Equipment", associated_id, "parentStructure"
                                )
                            )
                        else:
                            # Deduplicated against the PlantStructureItem side, which
                            # states the same link and would otherwise report it twice.
                            register_link_failure(
                                self,
                                child_id=self.equipment_id,
                                parent_id=associated_id,
                                assoc_type="is a part of",
                                reason=reason,
                            )
                elif association_parser.get_type() == "is located in" and not (
                    is_associated_with(self.equipment_obj, associated_object)
                    or is_associated_with(associated_object, self.equipment_obj)
                ):
                    # Log warning and try to add association in control pass
                    self.register_error(*ErrorTemplates.no_assoc_ctrl("Equipment", associated_id))
                    try:
                        fld = add_by_inferring_type(self.equipment_obj, associated_object)
                        # Log an info error if the association was added in control pass
                        self.register_error(
                            *ErrorTemplates.assoc_added_ctrl("Equipment", associated_id, fld)
                        )
                    except ValueError:
                        # This error handling is necessary because sometimes the association
                        # is the other way around for reference attributes in dexpi
                        try:
                            fld = add_by_inferring_type(associated_object, self.equipment_obj)
                            # Log info error if the association was added in reverse
                            self.register_error(
                                *ErrorTemplates.assoc_added_ctrl(
                                    "Equipment", associated_id, fld, reverse=True
                                )
                            )
                        except ValueError as e:
                            # If the association cannot be added, log an error
                            self.register_error(
                                *ErrorTemplates.assoc_not_added_ctrl("Equipment", associated_id),
                                exception=e,
                            )

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the equipment's shape usage and labels.

        This method processes the shape usage and label elements of the equipment, if available,
        to create a visual representation of the processEquipment. It assigns the shape usage and labels
        of equipment object. Also construct from submodules.
        """

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.equipment_obj and self.equipment_id):
            self.register_error(*ErrorTemplates.skip_pass("drawing", "Equipment"))
            return

        # Process nozzles
        nozzles_dwg = [parser.drawing_pass() for parser in self.nozzle_parsers]

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process graphical primitives
        graphical_primitives = []
        for primitive_parser in self.graphical_primitive_parsers:
            primitive = primitive_parser.compositional_pass()
            if primitive is not None:
                graphical_primitives.append(primitive)

        # Process shape usage and combine with graphical primitives in Static element
        static_elements = []

        # Add shape usage if available
        shape_usage = self.shape_usage_parser.drawing_pass()
        if shape_usage:
            static_elements.append(shape_usage)

        # Add graphical primitives to static elements
        static_elements.extend(graphical_primitives)

        # Create Static group if we have any elements
        if static_elements:
            static = core_diagram.Static(elements=static_elements)
            groups.append(static)

        # Process labels
        labels = [parser.drawing_pass() for parser in self.label_parsers]
        labels = filter_none(labels)
        groups.extend(labels)

        self.equipment_dwg = core_diagram.RepresentationGroup(
            represents=self.equipment_obj, groups=groups, nodePositions=node_positions
        )

        for nozzle_item in nozzles_dwg:
            if nozzle_item is not None:
                self.equipment_dwg.groups.append(nozzle_item)

        return self.equipment_dwg


### PIPING MODULES ###
class PipingNodeParser(ParserModule):
    """The PipingNodeParser is a module for parsing piping nodes from XML elements.

    This class processes piping node elements and converts them into DEXPI piping nodes. It also
    handles generic attribute parsing. No reference pass or control pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the piping node to be parsed.
    generic_attribute_parser : GenericAttributeParser
        The generic attribute parser to be used by the piping node parser.
    position_parsers : list[PositionParser]
        List of position parsers to be used by the piping node parser.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        generic_attribute_parser: GenericAttributeParser,
        position_parsers: list[PositionParser],
    ) -> None:
        """Initialize the PipingNodeParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the piping node to be parsed.
        generic_attribute_parser : GenericAttributeParser
            The generic attribute parser to be used by the piping node parser.
        position_parsers : list[PositionParser]
            List of position parsers to be used by the piping node parser.
        """
        super().__init__(context, element)
        self.piping_node_id = None
        self.piping_node = None
        self.piping_node_dwg = None

        # Set generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(self.generic_attribute_parser)

        # Set position parsers
        self.position_parsers = position_parsers
        self.register_submodule_list(position_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> piping.PipingNode | None:
        """Parse the piping node in the compositional pass.

        Retrieves the node ID, composes generic attributes, and creates an instance of PipingNode
        with the composed attributes. Registers the node in the context's object registry.


        Returns
        -------
        piping.PipingNode | None
            An instance of the PipingNode class created from the parsed data, or None if an error
            occurs.
        """
        # Get the ID of the node. If not available, log an error.
        self.piping_node_id = self.element.get("ID")
        if self.piping_node_id is None:
            self.register_error(*ErrorTemplates.id_not_found("Node"))

        # Make generic attribute set parsers
        generic_attributes = self.generic_attribute_parser.compositional_pass(piping.PipingNode)

        # Create a PipingNode with the composed attributes
        self.piping_node = piping.PipingNode(id=self.piping_node_id, **generic_attributes)

        # Register node
        self.register_object(self.piping_node_id, self.piping_node)

        return self.piping_node

    @redirect_errors_to_registry
    def drawing_pass(self) -> tuple[str, plant_diagram.PipingNodePosition] | None:
        """Perform a drawing pass over the piping node's position.

        This method processes the position element of the piping node, if available, to create a
        visual representation of the piping node's position. It assigns the position to the piping
        node object.
        """
        if len(self.position_parsers) > 1:
            self.register_error(
                f"Found {len(self.position_parsers)} Position elements for PipingNode, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.position_parsers) == 0:
            return None

        position_parser = self.position_parsers[0]

        # Process position
        position, _, _ = position_parser.compositional_pass()
        if position:
            self.piping_node_dwg = plant_diagram.PipingNodePosition(
                node=self.piping_node, position=position
            )
            return self.piping_node_id, self.piping_node_dwg
        else:
            self.register_error(
                "No position found for piping node. Drawing pass skipped.",
                level=ErrorLevels.ERROR,
            )
            return None


class ConnectionPointParser(ParserModule):
    """The ConnectionPointParser is a module for parsing connection points from XML elements.

    This class processes connection points and converts them into DEXPI piping nodes. No reference
    or control pass is required. Keeps track of the flow in and out indices, which are determined
    during the compositional pass.

    Attributes
    ----------
    context : ModuleContext
        The context in which the module operates, providing access to the ID stack and error registry.
    element : etree._Element
        The XML element containing the connection points to be parsed.
    piping_node_parsers : list[PipingNodeParser]
        A list of piping node parsers to be used for parsing the connection points.
    flow_in_index : int | None
        The index of the inflow connection point, set during the compositional pass. -1 indicates
        that the inflow connection point has not been parsed yet.
    flow_out_index : int | None
        The index of the outflow connection point, set during the compositional pass. -1 indicates
        that the outflow connection point has not been parsed yet.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        piping_node_parsers: list[PipingNodeParser],
        instrumentation_node_parsers: list[InstrumentationNodeParser],
    ) -> None:
        """Initialize the ConnectionPointParser with the XML element and context.

        Also sets node to keep track generic attribute sets for each node.

        Parameters
        ----------
        context : ModuleContext
            The module context providing access to the ID stack and error registry.
        element : etree._Element
            The XML element containing the connection points to be parsed.
        piping_node_parsers : list[PipingNodeParser]
            List of piping node parsers to be used by the connection point parser.
        instrumentation_node_parsers : list[InstrumentationNodeParser]
            List of instrumentation node parsers to be used by the connection point parser.
        """

        super().__init__(context, element)
        self.connection_points_dwg = None

        # Set and register piping node parsers
        self.piping_node_parsers = piping_node_parsers
        self.register_submodule_list(piping_node_parsers)

        # Set and register instrumentation node parsers
        self.instrumentation_node_parsers = instrumentation_node_parsers
        self.register_submodule_list(instrumentation_node_parsers)

        # Initialize some special proteus attributes to be parsed in compositional pass (-1 as
        # sentinel value. -1 means not parsed yet, None means not available in XML):
        self.flow_in_index = -1
        self.flow_out_index = -1

    @redirect_errors_to_registry
    def compositional_pass(self) -> list[piping.PipingNode] | None:
        """Parse all connection points in the compositional pass.

        This method iterates through all "Node" elements in the XML, and collects and returns the
        created PipingNode instances. Retrieves and determines the main inflow and outflow nodes.
        Also contains some further consistency checks, such as comparing the NumPoints attribute
        with the number of parsed nodes.

        Returns
        -------
        list[piping.PipingNode] | None
            A list of PipingNode instances created from the parsed connection points or None if
            an error occurs during parsing.
        """
        piping_nodes = [parser.compositional_pass() for parser in self.piping_node_parsers]

        # Retrieve the special proteus attributes for connection points
        # Num_points (Irrelevant for parsing, but can be used for extra validation):
        # Read the raw attribute before parsing it: int(None) raises, so testing the parsed
        # value for None could never report a missing attribute.
        raw_num_points = self.element.get("NumPoints")
        try:
            if raw_num_points is None:
                self.register_error(
                    "NumPoints attribute in ConnectionPoints is missing in the XML element. "
                    "Irrelevant for parsing.",
                    level=ErrorLevels.WARNING,
                )
            else:
                num_points = int(raw_num_points)
                if num_points != len(self.element.findall("Node")):
                    self.register_error(
                        f"Potential mismatch in number of connection points: {num_points} "
                        f"specified but {len(self.element.findall('Node'))} found.",
                        level=ErrorLevels.WARNING,
                    )
        except (ValueError, TypeError) as e:
            logger.debug("Error parsing NumPoints attribute", exc_info=True)
            self.register_error(
                f"Error parsing NumPoints attribute (Irrelevant for parsing): {e}",
                level=ErrorLevels.WARNING,
                exception=e,
            )

        # Flow_in_index and flow_out_index:
        try:
            idx = self.element.get("FlowIn", None)
            self.flow_in_index = int(idx) if idx is not None else None
        except (ValueError, TypeError) as e:
            logger.debug("Error parsing FlowIn attribute", exc_info=True)
            self.register_error(
                f"Error parsing FlowIn attributes: {e}. Defaulting to None.",
                level=ErrorLevels.WARNING,
                exception=e,
            )
            self.flow_in_index = None
        try:
            idx = self.element.get("FlowOut", None)
            self.flow_out_index = int(idx) if idx is not None else None
        except (ValueError, TypeError) as e:
            logger.debug("Error parsing FlowOut attribute", exc_info=True)
            self.register_error(
                f"Error parsing FlowOut attributes: {e}. Defaulting to None.",
                level=ErrorLevels.WARNING,
                exception=e,
            )
            self.flow_out_index = None

        return filter_none(piping_nodes)

    def get_inflow_index(self) -> int | None:
        """Get the index of the inflow connection point.

        Returns
        -------
        int
            The index of the inflow connection point, or None if not set.
        """
        if self.flow_in_index == -1:
            raise InternalParserError("Run compositional pass before accessing inflow index.")
        return self.flow_in_index

    def get_outflow_index(self) -> int | None:
        """Get the index of the outflow connection point.

        Returns
        -------
        int
            The index of the outflow connection point, or None if not set.
        """
        if self.flow_out_index == -1:
            raise InternalParserError("Run compositional pass before accessing outflow index.")
        return self.flow_out_index

    @redirect_errors_to_registry
    def drawing_pass(self) -> dict[str, plant_diagram.NodePosition] | None:
        """Perform a drawing pass over the connection points.

        Returns
        -------
        dict[str, plant_diagram.NodePosition] | None
            A dictionary mapping connection point IDs to their NodePosition objects.
            Returns None if no valid connection points were found.
        """
        # Get results from both piping and instrumentation node parsers
        piping_results = [parser.drawing_pass() for parser in self.piping_node_parsers]
        instrumentation_results = [
            parser.drawing_pass() for parser in self.instrumentation_node_parsers
        ]

        # Combine and filter out None results
        all_results = filter_none(piping_results + instrumentation_results)

        # Convert list of (id, position) tuples to dictionary
        self.connection_points_dwg = dict(all_results)

        return self.connection_points_dwg if self.connection_points_dwg else None


class PipingComponentParser(ParserModule):
    """The PipingComponentParser is a module for parsing piping components from XML elements.

    This class processes piping component elements and converts them into DEXPI piping components.
    No reference pass is required, but the control pass checks if all referencing associations have
    been resolved.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element representing the piping component.
    connection_point_parsers : list[ConnectionPointParser]
        List of connection point parsers to be used by the piping component parser.
    association_parsers : list[AssociationParser]
        List of association parsers to be used by the piping component parser.
    generic_attribute_parser : GenericAttributeParser
        The generic attribute parser to be used by the piping component parser.
    component_obj : piping.PipingNetworkSegmentItem | None
        The piping component object being constructed by the parser.
    component_id : str | None
        The ID of the piping component being constructed.
    nodes : list[piping.PipingNode]
        List of piping nodes that are part of the component.
    main_inflow_node : piping.PipingNode | None
        The main inflow node of the component, determined during the compositional pass.
    main_outflow_node : piping.PipingNode | None
        The main outflow node of the component, determined during the compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        connection_point_parsers: list[ConnectionPointParser],
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        shape_usage_parser: ShapeUsageParser,
        label_parsers: list[LabelParser],
    ) -> None:
        """Initialize the PipingComponentParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The module context providing access to the ID stack and error registry.
        element : etree._Element
            The XML element containing the piping component to be parsed.
        connection_point_parsers : list[ConnectionPointParser]
            List of connection point parsers to be used by the piping component parser.
        association_parsers : list[AssociationParser]
            List of association parsers to be used by the piping component parser.
        generic_attribute_parser : GenericAttributeParser
            The generic attribute parser to be used by the piping component parser.
        shape_usage_parser : ShapeUsageParser
            The shape usage parser to be used by the piping component parser.
        label_parsers : list[LabelParser]
            List of label parsers to be used by the piping component parser.
        """
        super().__init__(context, element)
        self.component_obj = None
        self.component_id = None
        self.component_dwg = None

        # Set and register connection point parsers
        self.connection_point_parsers = connection_point_parsers
        self.register_submodule_list(connection_point_parsers)

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.gen_attr_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register shape usage parser
        self.shape_usage_parser = shape_usage_parser
        self.register_submodule(shape_usage_parser)

        # Set and register label parsers
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

        # Keep track of nodes in the component
        self.nodes = []

        # Keep track of main inflow node and main outflow node
        self.main_inflow_node = None
        self.main_outflow_node = None

    @redirect_errors_to_registry
    def compositional_pass(self) -> piping.PipingNetworkSegmentItem | None:
        """Parse the piping component in the compositional pass.

        This method retrieves all data from the XML element and composes connection points,
        associations, and generic attributes. It creates an instance of the PipingNetworkSegmentItem
        class with the composed attributes, registers, and returns it.

        Returns
        -------
        piping.PipingNetworkSegmentItem | None
            An instance of the PipingNetworkSegmentItem class created from the parsed attributes and
            connection points or None if an error occurred during parsing.
        """
        # Get the ID of the piping component. If not available, log an error.
        self.component_id = self.element.get("ID")
        if self.component_id is None:
            self.register_error(*ErrorTemplates.id_not_found("PipingComponent"))
            return None

        # Get the component type
        class_name = self.element.get("ComponentClass")

        # If class name not part of piping, fall back to the generic PipingComponent class.
        # TypeError covers a missing ComponentClass attribute (class_name is None).
        try:
            MyClass = getattr(piping, class_name)
        except (AttributeError, TypeError):
            MyClass = piping.PipingComponent

            # Log a warning that the class name is invalid
            self.register_error(
                f"Unknown ComponentClass {class_name!r} for PipingComponent. Using generic "
                f"PipingComponent instead.",
                level=ErrorLevels.WARNING,
            )

        # Compose connection points
        piping_nodes = []
        for connection_point_parser in self.connection_point_parsers:
            parsed_nodes = connection_point_parser.compositional_pass()
            if parsed_nodes is not None:
                piping_nodes.extend(parsed_nodes)

            # Retrieve inflow and outflow nodes
            inflow_index = connection_point_parser.get_inflow_index()
            outflow_index = connection_point_parser.get_outflow_index()

            if inflow_index is not None:
                if self.main_inflow_node is None:
                    if inflow_index > len(piping_nodes):
                        self.register_error(
                            f"Inflow index {inflow_index} is out of bounds for the number of "
                            f"piping nodes {len(piping_nodes)}. Using first node instead.",
                            level=ErrorLevels.ERROR,
                            proteus_id=self.component_id,
                        )
                    else:
                        self.main_inflow_node = piping_nodes[inflow_index - 1]
                else:
                    self.register_error(
                        "Multiple inflow nodes found. Only one inflow node is allowed. "
                        "Using first encountered node.",
                        level=ErrorLevels.ERROR,
                        proteus_id=self.component_id,
                    )
            if outflow_index is not None:
                if self.main_outflow_node is None:
                    if outflow_index > len(piping_nodes):
                        self.register_error(
                            f"Outflow index {outflow_index} is out of bounds for the number of "
                            f"piping nodes {len(piping_nodes)}. Using first node instead.",
                            level=ErrorLevels.ERROR,
                            proteus_id=self.component_id,
                        )
                    else:
                        self.main_outflow_node = piping_nodes[outflow_index - 1]
                else:
                    self.register_error(
                        "Multiple outflow nodes found. Only one outflow node is allowed. "
                        "Using first encountered node.",
                        level=ErrorLevels.ERROR,
                        proteus_id=self.component_id,
                    )

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attributes = self.gen_attr_parser.compositional_pass(MyClass)

        # Create a PipingNetworkSegmentItem with the composed attributes
        segment_item_kwargs = generic_attributes.copy()
        segment_item_kwargs["nodes"] = piping_nodes

        new_segment_item = MyClass(id=self.component_id, **segment_item_kwargs)

        # Register segment item
        self.register_object(self.component_id, new_segment_item)

        # Keep track of obj in self.component obj and nodes in self.nodes
        self.nodes = piping_nodes
        self.component_obj = new_segment_item

        return new_segment_item

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Perform a control pass over the piping component's associations.

        This is to catch the 'is the location of' associations as sensing locations that are missed
        in the reference pass."""
        # Call super.control_pass() to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.component_obj and self.component_id):
            self.register_error(*ErrorTemplates.skip_pass("control", "PipingComponent"))
            return

        # Otherwise, proceed with control pass. Check if associations have been made correctly.
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            elif association_parser.get_type() not in ["is the location of", "is referenced by"]:
                # Not permitted for piping components, add warning
                self.register_error(
                    f"Association of type {association_parser.get_type()} is not "
                    "permitted for piping components. Association skipped.",
                    level=ErrorLevels.WARNING,
                )

            else:
                associated_object = association_parser.get_referenced_item()
                association_id = association_parser.get_id()
                if not is_associated_with(self.component_obj, associated_object):
                    # Log warning and try to add association in control pass
                    self.register_error(
                        *ErrorTemplates.no_assoc_ctrl("PipingComponent", association_id)
                    )
                    try:
                        fld = add_by_inferring_type(self.component_obj, associated_object)
                        # Log an info error if the association was added in control pass
                        self.register_error(
                            *ErrorTemplates.assoc_added_ctrl("PipingComponent", association_id, fld)
                        )
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_not_added_ctrl("PipingComponent", association_id),
                            exception=e,
                        )

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the piping component's shape usage and labels.

        This method processes the shape usage and label elements of the piping component, if
        available, to create a visual representation of the piping component. It assigns the shape
        usage and labels of piping component object. Also construct from submodules.
        """

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.component_obj and self.component_id):
            self.register_error(*ErrorTemplates.skip_pass("drawing", "PipingComponent"))
            return

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process shape usage
        shape_usage = self.shape_usage_parser.drawing_pass()
        if shape_usage:
            static = core_diagram.Static(elements=[shape_usage])
            groups.append(static)

        # Process labels
        labels_dwg = [parser.drawing_pass() for parser in self.label_parsers]
        labels = filter_none(labels_dwg)
        groups.extend(labels)

        self.component_dwg = core_diagram.RepresentationGroup(
            represents=self.component_obj, groups=groups, nodePositions=node_positions
        )

        # Process node positions from connection points
        # We only have one connection point parser per equipment
        connection_points_dict = self.connection_point_parsers[0].drawing_pass()

        if connection_points_dict:
            # Create a representation group with all node positions
            connection_point = core_diagram.RepresentationGroup(
                represents=self.component_obj,
                groups=[],
                nodePositions=list(connection_points_dict.values()),
            )
            self.component_dwg.groups.append(connection_point)

        self.register_object(f"{self.component_id}_cp_node_positions", connection_points_dict)

        return self.component_dwg

    def get_main_inflow_node(self) -> piping.PipingNode | None:
        """Get the main inflow node of the piping component.

        This is the node that is explicitly found as inflow node or, by default, the first node.
        If no nodes are available, it returns None.

        Returns
        -------
        piping.PipingNode | None
            The main inflow node of the piping component.
        """
        if self.main_inflow_node is not None:
            return self.main_inflow_node
        # If no explicit inflow node is found, return the first inflow node or None
        # if no nodes are available.
        return self.nodes[0] if len(self.nodes) > 0 else None

    def get_main_outflow_node(self) -> piping.PipingNode | None:
        """Get the main outflow node of the piping component.

        This is the node that is explicitly found as outflow node or, by default, the second node.
        If no nodes are available, it returns None.

        Returns
        -------
        piping.PipingNode | None
            The main outflow node of the piping component.
        """
        if self.main_outflow_node is not None:
            return self.main_outflow_node
        # If no explicit outflow node is found, return the first outflow node or None
        # if no nodes are available.
        return self.nodes[1] if len(self.nodes) > 1 else None


class PipeOffPageConnectorParser(PipingComponentParser):
    """Parser for PipeOffPageConnector elements in the DEXPI model.

    It behaves like the component parser, but additionally handles the pipe off-page connector
    references.  In the compositional pass, it additionally composes the pipe off-page connector
    references. The control of the inverse OPC reference is also handled by the parent class
    PipingComponentParser via the "is referenced by" association.

    Attributes
    ----------
    reference_parsers : list[OffPageConnectorReferenceParser]
        A list of parsers for the pipe off-page connector references."""

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        connection_point_parsers: list[ConnectionPointParser],
        reference_parsers: list[OffPageConnectorReferenceParser],
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        shape_usage_parser: ShapeUsageParser,
        label_parsers: list[LabelParser],
    ) -> None:
        """Initialize the PipeOffPageConnectorParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The module context providing access to the ID stack and error registry.
        element : etree._Element
            The XML element containing the pipe off-page connector to be parsed.
        connection_point_parsers : list[ConnectionPointParser]
            List of connection point parsers to be used by the pipe off-page connector parser.
        association_parsers : list[AssociationParser]
            List of association parsers to be used by the pipe off-page connector parser.
        generic_attribute_parser : GenericAttributeParser
            The generic attribute parser to be used by the pipe off-page connector parser.
        shape_usage_parser : ShapeUsageParser
            The shape usage parser to be used by the pipe off-page connector parser.
        label_parsers : list[LabelParser]
            List of label parsers to be used by the pipe off-page connector parser.
        """
        super().__init__(
            context,
            element,
            connection_point_parsers,
            association_parsers,
            generic_attribute_parser,
            shape_usage_parser,
            label_parsers,
        )

        self.opc = None
        self.opc_id = None
        self.opc_dwg = None

        self.reference_parsers = reference_parsers
        self.register_submodule_list(reference_parsers)

        # register shape usage parser
        self.shape_usage_parser = shape_usage_parser
        self.register_submodule(shape_usage_parser)

        # register label parsers
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> piping.PipeOffPageConnector | None:
        """Parse the pipe off-page connector in the compositional pass.

        Performs the compositional pass just like the PipingComponentParser, but also handles
        the pipe off-page connector references. If multiple references are found, it keeps only the
        first valid one and logs a warning.

        Returns
        -------
        piping.PipeOffPageConnector | None
            An instance of the PipeOffPageConnector class created from the parsed data, or None
            if an error occurs during parsing.
        """
        self.opc: piping.PipeOffPageConnector = super().compositional_pass()

        if self.opc is None:
            # If the parent compositional pass failed, do nothing
            return self.opc

        if len(self.reference_parsers) > 1:
            # Log a warning if there are multiple reference parsers
            self.register_error(
                "Multiple PipeOffPageConnectorReference parsers found. Keeping only the first "
                "valid one.",
                level=ErrorLevels.WARNING,
            )
        for reference_parser in self.reference_parsers:
            reference_obj = reference_parser.compositional_pass()
            if reference_obj:
                # If the reference object is valid, add it to the PipeOffPageConnector
                self.opc.connectorReference = reference_obj
                break

        return self.opc

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the piping component's shape usage and labels.

        This method processes the shape usage and label elements of the piping component, if
        available, to create a visual representation of the piping component. It assigns the shape
        usage and labels of piping component object. Also construct from submodules.
        """

        # Skip pass if the reference object or ID is not available due to previous error
        self.opc_id = self.element.get("ID")
        if not (self.opc and self.opc_id):
            self.register_error(*ErrorTemplates.skip_pass("drawing", "PipeOffPageConnector"))
            return

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process shape usage
        shape_usage = self.shape_usage_parser.drawing_pass()
        if shape_usage:
            static = core_diagram.Static(elements=[shape_usage])
            groups.append(static)

        # Process labels
        labels_dwg = [parser.drawing_pass() for parser in self.label_parsers]
        labels = filter_none(labels_dwg)
        groups.extend(labels)

        for parser in self.reference_parsers:
            if parser.reference_obj is self.opc.connectorReference:
                reference_drawing = parser.drawing_pass()
                if reference_drawing is not None:
                    groups.append(reference_drawing)

        self.opc_dwg = core_diagram.RepresentationGroup(
            represents=self.opc, groups=groups, nodePositions=node_positions
        )

        # Process node positions from connection points
        # We only have one connection point parser per off-page connector
        connection_points_dict = self.connection_point_parsers[0].drawing_pass()

        if connection_points_dict:
            # Create a representation group with all node positions
            connection_point = core_diagram.RepresentationGroup(
                represents=self.opc, groups=[], nodePositions=list(connection_points_dict.values())
            )
            self.opc_dwg.groups.append(connection_point)

        self.register_object(f"{self.opc_id}_cp_node_positions", connection_points_dict)

        return self.opc_dwg


class PropertyBreakParser(PipingComponentParser):
    """Parser for PropertyBreak elements in the DEXPI model.

    In this implementation, it behaves exactly like PipingComponentParser."""


class CenterLineParser(ParserModule):
    """Parser for CenterLine elements in the DEXPI model.

    Creates a Pipe for a center line and parses related generic attributes in
    compositional pass. No reference or control pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the center line to be parsed.
    generic_attribute_parser : GenericAttributeParser
        The parser for generic attributes.
    presentation_parsers : list[PresentationParser]
        List of presentation parsers to be used by the center line parser.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        generic_attribute_parser: GenericAttributeParser,
        presentation_parsers: list[PresentationParser],
        coordinate_parsers: list[CoordinateParser],
    ) -> None:
        """Initialize the CenterLineParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The module context providing access to the ID stack and error registry.
        element : etree._Element
            The XML element containing the center line to be parsed.
        generic_attribute_parser : GenericAttributeParser
            The parser for generic attributes.
        presentation_parsers : list[PresentationParser]
            List of presentation parsers to be used by the center line parser.
        coordinate_parsers : list[CoordinateParser]
            List of coordinate parsers to be used by the center line parser.
        """
        super().__init__(context, element)
        self.center_line_dwg = None
        self.center_line_pipe = None

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register presentation parsers
        self.presentation_parsers = presentation_parsers
        self.register_submodule_list(presentation_parsers)

        # Set and register coordinate parsers
        self.coordinate_parsers = coordinate_parsers
        self.register_submodule_list(coordinate_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> piping.Pipe | None:
        """Parse the center line in the compositional pass.

        Parses the generic attributes and creates a Pipe for the center line.

        Returns
        -------
        piping.Pipe | None
            An instance of the Pipe class created from the parsed data or None if an error
            occurs during parsing.
        """
        kwargs = {}
        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(piping.Pipe)
        kwargs.update(generic_attrs)

        # Create the Pipe for the center line
        self.center_line_pipe = piping.Pipe(**kwargs)

        return self.center_line_pipe

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.ConnectorLine | None:
        """Perform a drawing pass over the center line's presentation and coordinates.

        This method processes the presentation and coordinate elements of the center line, if
        available, to create a visual representation of the center line. It assigns the presentation
        and coordinates to the center line object.
        """

        # Process presentation
        if len(self.presentation_parsers) > 1:
            self.register_error(
                f"Found {len(self.presentation_parsers)} Presentation elements for CenterLine, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.presentation_parsers) == 0:
            return None

        presentation_parser = self.presentation_parsers[0]

        presentation = presentation_parser.compositional_pass()

        coordinates = [parser.compositional_pass() for parser in self.coordinate_parsers]
        coordinates = filter_none(coordinates)

        connector_line = core_diagram.ConnectorLine(
            innerPoints=coordinates,
            stroke=presentation,
            source=None,
            target=None,
        )

        self.center_line_dwg = core_diagram.Static(elements=[connector_line])

        return self.center_line_dwg


class PipingNetworkSegmentParser(ParserModule):
    """Parser for PipingNetworkSegment elements in the DEXPI model.

    Converts PipingNetworkSegment XML elements into pyDEXPI PipingNetworkSegment objects. Composes
    all components, connections, associations, and generic attributes in compositional pass and
    creates the pyDEXPI PipingNetworkSegment object. Hereby, DirectPipingConnections are inferred
    from the absence of pipes between components (as defined by DEXPI spec). In the reference pass,
    all explicit and implicit sources and targets of the segment connections are established, as
    well as the explicit sources and targets of the segment itself (In accordance with the DEXPI
    convention). In control pass, checks if the associations of the object were correctly
    established, and tries to recover missed associations.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the piping network segment to be parsed.
    item_parsers : list[PipingComponentParser | PipeOffPageConnectorParser | PropertyBreakParser]
        A list of parsers for the items in the piping network segment.
    center_line_parsers : list[CenterLineParser]
        A list of parsers for the center lines in the piping network segment.
    ordered_element_parsers : list[PipingComponentParser | PipeOffPageConnectorParser |
                                   PropertyBreakParser | CenterLineParser]
        A list of parsers for the ordered elements in the piping network segment that preserve the
        order of elements.
    association_parsers : list[AssociationParser]
        A list of parsers for the associations in the piping network segment.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the piping network segment.
    pns_id : str | None
        The ID of the piping network segment being constructed. Set during compositional pass.
    pn_segment : piping.PipingNetworkSegment | None
        The PipingNetworkSegment object being constructed. Set during compositional pass.
    pns_elements : list | None
        The elements of the piping network segment being constructed. Set during compositional pass.
    from_id : str | None
        The ID of the connection point from which the segment starts. Set during compositional pass.
    to_id : str | None
        The ID of the connection point at which the segment ends. Set during compositional pass.
    from_node_index : int | None
        The index of the node in from_id item from which the segment starts. Set during
        compositional pass.
    to_node_index : int | None
        The index of the node in to_id item at which the segment ends. Set during
        compositional pass.
    main_inflow_nodes : dict[str, piping.PipingNode]
        A dictionary mapping component IDs to their main inflow nodes. Set during compositional
        pass.
    main_outflow_nodes : dict[str, piping.PipingNode]
        A dictionary mapping component IDs to their main outflow nodes. Set during compositional
        pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        item_parsers: list[
            PipingComponentParser | PipeOffPageConnectorParser | PropertyBreakParser
        ],
        center_line_parsers: list[CenterLineParser],
        ordered_element_parsers: list[
            PipingComponentParser
            | PipeOffPageConnectorParser
            | PropertyBreakParser
            | CenterLineParser
        ],
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        symbol_parsers: list[SymbolParser],
    ) -> None:
        """Initialize the PipingNetworkSegmentParser with the XML element and context.

        Sets the submodules for generic attributes, piping components, and connection points. Makes
        sure that the ordered_element_parsers contains all and only item_parsers and
        center_line_parsers, and raises an internal parser error if not. Initializes all further
        attributes that are needed for the parsing process.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the piping network segment to be parsed.
        item_parsers : list[PipingComponentParser |
                            PipeOffPageConnectorParser |
                            PropertyBreakParser]
            A list of parsers for the items in the piping network segment.
        center_line_parsers : list[CenterLineParser]
            A list of parsers for the center lines in the piping network segment.
        ordered_element_parsers : list[PipingComponentParser |
                                       PipeOffPageConnectorParser |
                                       PropertyBreakParser |
                                       CenterLineParser]
            A list of parsers for the ordered elements in the piping network segment.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations in the piping network segment.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the piping network segment.
        symbol_parsers : list[SymbolParser]
            A list of parsers for the symbols in the piping network segment.
        """
        super().__init__(context, element)
        self.pns_id = None
        self.pn_segment = None
        self.segment_dwg = None

        # Consistency check to make sure that the ordered_element_parsers contains all and only
        # item_parsers and center_line_parsers. Raise an exception if not (this is a parser
        # error, not a DEXPI error).
        expected_parsers = set(item_parsers + center_line_parsers)
        actual_parsers = set(ordered_element_parsers)

        if expected_parsers != actual_parsers:
            raise InternalParserError(
                "Ordered element parsers must contain all and only item parsers and "
                "center line parsers."
            )

        # Set item parsers
        self.item_parsers = item_parsers

        # Set center line parsers
        self.center_line_parsers = center_line_parsers

        # Set and register ordered element parser reference
        self.ordered_element_parsers = ordered_element_parsers
        self.register_submodule_list(ordered_element_parsers)

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register symbol parsers
        self.symbol_parsers = symbol_parsers
        self.register_submodule_list(symbol_parsers)

        # Initialize attribute for the PipingNetworkSegment elements. This will be set to a list in
        # the compositional pass. None means not parsed yet.
        self.pns_elements = None

        # Initialize attributes for connection points. Directly extract the connection points to
        # avoid ambiguity of None meaning not parsed or not found. This way, None always means not
        # found.
        self.from_id = None
        self.to_id = None
        self.from_node_index = None
        self.to_node_index = None
        self._extract_connections()

        # Keep track of all item main inflow and main outflow nodes.
        self.main_inflow_nodes = {}
        self.main_outflow_nodes = {}

    @redirect_errors_to_registry
    def compositional_pass(self) -> piping.PipingNetworkSegment | None:
        """Parse the PipingNetworkSegment in the compositional pass.

        Compose all components, connections and generic attributes and keep track of connection
        points, main inflow and outflow nodes. Create an instance of the PipingNetworkSegment class
        with the composed attributes and register it. No internal or external sources or targets are
        defined. This happens in the reference pass.

        Returns
        -------
        piping.PipingNetworkSegment | None
            An instance of the PipingNetworkSegment class created from the parsed attributes and
            components, or None if an error occurs during parsing.
        """

        # Extract pns id
        self.pns_id = self.element.get("ID")
        if self.pns_id is None:
            self.register_error(*ErrorTemplates.id_not_found("PipingNetworkSegment"))
            return None

        # Compose all piping components and connections
        self.pns_elements = []
        items = []
        connections = []
        last_was_item = False
        for element_parser in self.ordered_element_parsers:
            component_element = element_parser.compositional_pass()

            # Infer a direct piping connection if the last parser was an item parser (Comparison
            # done on parser object, since an internal error may return None for the parsed
            # object)
            if element_parser in self.item_parsers and last_was_item:
                direct_connection = piping.DirectPipingConnection()
                self.pns_elements.append(direct_connection)
                connections.append(direct_connection)

            if element_parser in self.item_parsers:
                last_was_item = True
                items.append(component_element)
                # If the element is not None, register main inflow and outflow nodes
                if component_element is not None:
                    self.main_inflow_nodes[component_element.id] = (
                        element_parser.get_main_inflow_node()
                    )
                    self.main_outflow_nodes[component_element.id] = (
                        element_parser.get_main_outflow_node()
                    )

            elif element_parser in self.center_line_parsers:
                last_was_item = False
                connections.append(component_element)
            else:
                msg = f"Unknown component parser type: {element_parser}. Internal error in "
                "Parser."
                exception = InternalParserError(msg)
                self.register_error(msg, level=ErrorLevels.CRITICAL, exception=exception)
                continue

            self.pns_elements.append(component_element)

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(
            piping.PipingNetworkSegment
        )

        # Create the PipingNetworkSegment with the composed attributes. No internal or external
        # sources or targets are defined yet. This happens in the reference pass.
        kwargs = generic_attrs.copy()
        kwargs["items"] = filter_none(items)
        kwargs["connections"] = filter_none(connections)

        new_segment = piping.PipingNetworkSegment(id=self.pns_id, **kwargs)

        # Register the PipingNetworkSegment object
        self.register_object(self.pns_id, new_segment)

        # Set the pn_segment attribute to the new segment
        self.pn_segment = new_segment

        return new_segment

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Perform a reference pass over the PipingNetworkSegment.

        This method calls the reference pass on all component parsers. Then, it checks if the
        segment is reversed and reverses the order of all items and connections if so. Then, it
        creates internal and external source and target connections, respectively, according to the
        DEXPI convention.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.pns_id is None or self.pn_segment is None:
            self.register_error(*ErrorTemplates.skip_pass("reference", "PipingNetworkSegment"))
            return

        # Check if the segment is reversed. If so, reverse the order of all items and connections
        if self._infer_is_reversed():
            self.pn_segment.items.reverse()
            self.pn_segment.connections.reverse()

            self.item_parsers.reverse()
            self.center_line_parsers.reverse()
            self.ordered_element_parsers.reverse()
            self.pns_elements.reverse()

        # After potential reversal, append missing direct piping connections to start and end if
        # required by the external connection points.
        self._infer_direct_connections_at_ends()

        # Go through all elements and assign sources and targets.
        for i, element in enumerate(self.pns_elements):
            if isinstance(element, piping.PipingConnection):
                # Assign source
                if i > 0 and isinstance(self.pns_elements[i - 1], piping.PipingNetworkSegmentItem):
                    source_item = self.pns_elements[i - 1]
                    element.sourceItem = source_item
                    source_node = self.main_outflow_nodes.get(source_item.id)
                    element.sourceNode = source_node

                # Assign target
                if i < len(self.pns_elements) - 1 and isinstance(
                    self.pns_elements[i + 1], piping.PipingNetworkSegmentItem
                ):
                    target_item = self.pns_elements[i + 1]
                    element.targetItem = target_item
                    target_node = self.main_inflow_nodes.get(target_item.id)
                    element.targetNode = target_node

        # Set the external segment source and target. The referenced object can be missing from
        # the registry if its own parse failed; register the unresolved reference and continue
        # with a partial segment rather than raising.
        if self.from_id is not None:
            source_item = self.get_object_from_registry(self.from_id)
            if source_item is None:
                self.register_error(
                    f"Could not resolve source item {self.from_id!r} of PipingNetworkSegment "
                    f"{self.pns_id}. Leaving the segment source unset.",
                    level=ErrorLevels.ERROR,
                )
            else:
                self.pn_segment.sourceItem = source_item
                if self.from_node_index is not None:
                    self.pn_segment.sourceNode = self._resolve_external_node(
                        source_item, self.from_node_index, "FromNode"
                    )

                # If the first element is a piping connection, set its source item and node to
                # the source item and node of the segment.
                first_element = self.pns_elements[0] if self.pns_elements else None
                if isinstance(first_element, piping.PipingConnection):
                    first_element.sourceItem = self.pn_segment.sourceItem
                    first_element.sourceNode = self.pn_segment.sourceNode

        # If no external source is defined and the first element is an item, the first item is
        # inferred as source to produce a valid segment. If the item has a main inflow node, it is
        # used as source node. The element can be None if its parse failed; skip it then.
        #
        # Gated on ``from_id is None``, not on ``sourceItem is None``: a ``FromID`` that named an
        # item the registry does not hold has already been recorded as an error above, and
        # inferring here would silently substitute an *internal* item for the external one the
        # document named -- a change of topology, not a degradation, and one no error reports
        # because the error was already filed and moved past.
        if (
            self.from_id is None
            and self.ordered_element_parsers
            and self.ordered_element_parsers[0] in self.item_parsers
        ):
            source_item = self.pns_elements[0]
            if source_item is not None:
                self.pn_segment.sourceItem = source_item
                self.pn_segment.sourceNode = self.main_inflow_nodes.get(source_item.id)

        # Set the external segment target same as source above.
        if self.to_id is not None:
            target_item = self.get_object_from_registry(self.to_id)
            if target_item is None:
                self.register_error(
                    f"Could not resolve target item {self.to_id!r} of PipingNetworkSegment "
                    f"{self.pns_id}. Leaving the segment target unset.",
                    level=ErrorLevels.ERROR,
                )
            else:
                self.pn_segment.targetItem = target_item
                if self.to_node_index is not None:
                    self.pn_segment.targetNode = self._resolve_external_node(
                        target_item, self.to_node_index, "ToNode"
                    )

                # If the last element is a piping connection, set its target item and node to
                # the target item and node of the segment.
                last_element = self.pns_elements[-1] if self.pns_elements else None
                if isinstance(last_element, piping.PipingConnection):
                    last_element.targetItem = self.pn_segment.targetItem
                    last_element.targetNode = self.pn_segment.targetNode

        # Gated on ``to_id``, for the same reason as the source above.
        if (
            self.to_id is None
            and self.ordered_element_parsers
            and self.ordered_element_parsers[-1] in self.item_parsers
        ):
            target_item = self.pns_elements[-1]
            if target_item is not None:
                self.pn_segment.targetItem = target_item
                self.pn_segment.targetNode = self.main_outflow_nodes.get(target_item.id)

    def _resolve_external_node(
        self, item: PyDexpiBaseModel, node_index: int, role: str
    ) -> piping.PipingNode | None:
        """Resolve a 1-based Proteus FromNode/ToNode index on an external item's nodes.

        Proteus node indices count from 1 (the same convention the drawing pass uses for
        node positions). An index outside the item's node list is registered as an error
        and resolves to None, keeping the segment partial instead of raising.

        Parameters
        ----------
        item : PyDexpiBaseModel
            The resolved source or target item.
        node_index : int
            The 1-based node index from the Connection element.
        role : str
            "FromNode" or "ToNode", for the error message.

        Returns
        -------
        piping.PipingNode | None
            The referenced node, or None if the index is out of range.
        """
        nodes = getattr(item, "nodes", None) or []
        if 1 <= node_index <= len(nodes):
            return nodes[node_index - 1]
        self.register_error(
            f"{role} index {node_index} is out of range for item "
            f"{getattr(item, 'id', None)!r} with {len(nodes)} nodes in PipingNetworkSegment "
            f"{self.pns_id}. Leaving the node unset.",
            level=ErrorLevels.ERROR,
        )
        return None

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Perform a control pass over the segment's associations.

        This is to catch the 'is location of' associations as sensing locations that are missed in
        the reference pass."""
        # Call super.control_pass() to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.pn_segment and self.pns_id):
            self.register_error(*ErrorTemplates.skip_pass("control", "PipingNetworkSegment"))
            return

        # Otherwise, proceed with control pass. Check if associations have been made correctly.
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            elif association_parser.get_type() != "is the location of":
                # Not permitted for pn segments, add warning
                self.register_error(
                    f"Association of type {association_parser.get_type()} is not "
                    "permitted for PipingNetworkSegments. Association skipped.",
                    level=ErrorLevels.WARNING,
                )

            else:
                associated_object = association_parser.get_referenced_item()
                association_id = association_parser.get_id()
                if not is_associated_with(self.pn_segment, associated_object):
                    # Log warning and try to add association in control pass
                    self.register_error(
                        *ErrorTemplates.no_assoc_ctrl("PipingNetworkSegment", association_id)
                    )
                    try:
                        fld = add_by_inferring_type(self.pn_segment, associated_object)
                        # Log an info error if the association was added in control pass
                        self.register_error(
                            *ErrorTemplates.assoc_added_ctrl(
                                "PipingNetworkSegment", association_id, fld
                            )
                        )
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_not_added_ctrl(
                                "PipingNetworkSegment", association_id
                            ),
                            exception=e,
                        )

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the PipingNetworkSegment.

        This method calls the drawing pass on all submodules and collects their graphical
        representations into a RepresentationGroup.

        Returns
        -------
        core_diagram.RepresentationGroup | None
            A RepresentationGroup containing all graphical representations from submodules, or
            None if an error occurs during the drawing pass.
        """

        # Collect graphical representations from all submodules
        if not (self.pn_segment and self.pns_id):
            self.register_error(*ErrorTemplates.skip_pass("drawing", "PipingNetworkSystem"))
            return

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        self.segment_dwg = core_diagram.RepresentationGroup(
            represents=self.pn_segment, groups=groups, nodePositions=node_positions
        )

        items_dwg = [parser.drawing_pass() for parser in self.item_parsers]

        for item_dwg in items_dwg:
            if item_dwg is not None:
                self.segment_dwg.groups.append(item_dwg)

        symbols_dwg = [parser.drawing_pass() for parser in self.symbol_parsers]
        for symbol_dwg in symbols_dwg:
            if symbol_dwg is not None:
                self.segment_dwg.groups.append(symbol_dwg)

        # Proteus draws one CenterLine per pipe, so each line is the pipe's own
        # drawing: RG(segment) -> RG(pipe) -> Static -> ConnectorLine, as in a
        # native DEXPI drawing. Grouping it under the segment instead would leave
        # pipes undrawn and every line of a segment indistinguishable.
        for parser in self.center_line_parsers:
            cl_dwg = parser.drawing_pass()
            if cl_dwg is None:
                continue
            owner = (
                parser.center_line_pipe if parser.center_line_pipe is not None else self.pn_segment
            )
            self.segment_dwg.groups.append(
                core_diagram.RepresentationGroup(
                    represents=owner, groups=[cl_dwg], nodePositions=[]
                )
            )

        return self.segment_dwg

    def drawing_reference_pass(self) -> None:
        """Bind each centerline's line to the end nodes of its own pipe.

        The ends come from the topology the reference pass resolved (the pipe's
        ``sourceNode`` and ``targetNode``, reversal and external nodes already
        applied), never from the segment's outer Connection or from matching
        coordinates, so a line ends where its pipe ends and never runs on
        through the component after it. Coordinates that repeat a bound end are
        dropped; interior bends are kept. An end whose node has no drawn
        position stays unbound, with its coordinates kept.
        """
        if self.segment_dwg is None:
            return
        positions = self._node_positions_by_node()
        for parser in self.center_line_parsers:
            pipe = parser.center_line_pipe
            if pipe is None or parser.center_line_dwg is None:
                continue
            for line in self._find_connector_lines(parser.center_line_dwg):
                self._bind_center_line(line, pipe, positions)

    def _node_positions_by_node(self) -> dict[int, core_diagram.NodePosition]:
        """Every registered connection-point position, keyed by ``id()`` of its node."""
        by_node: dict[int, core_diagram.NodePosition] = {}
        for key, obj in self.context.object_registry.objects.items():
            if "_cp_node_positions" not in key or not obj:
                continue
            for position in obj.values():
                node = getattr(position, "node", None)
                if node is not None:
                    by_node.setdefault(id(node), position)
        return by_node

    def _bind_center_line(
        self,
        line: core_diagram.ConnectorLine,
        pipe: piping.PipingConnection,
        positions: dict[int, core_diagram.NodePosition],
    ) -> None:
        """Set `line`'s ends to `pipe`'s end node positions and tidy its points."""
        source = positions.get(id(pipe.sourceNode)) if pipe.sourceNode is not None else None
        target = positions.get(id(pipe.targetNode)) if pipe.targetNode is not None else None
        points = list(line.innerPoints)

        # Coordinates listed from the target end, as in a segment the reference
        # pass reversed, are turned around to run from source to target.
        if len(points) >= 2 and (source is not None or target is not None):
            forward = reverse = 0.0
            if source is not None:
                forward += _distance(points[0], source.position)
                reverse += _distance(points[-1], source.position)
            if target is not None:
                forward += _distance(points[-1], target.position)
                reverse += _distance(points[0], target.position)
            if reverse < forward:
                points.reverse()

        if source is not None:
            while points and _same_point(points[0], source.position):
                points.pop(0)
        if target is not None:
            while points and _same_point(points[-1], target.position):
                points.pop()

        line.source = source
        line.target = target
        line.innerPoints = points
        if source is None or target is None:
            self.register_error(
                "A CenterLine end has no drawn connection point; that end is left unbound "
                "and drawn from its coordinates.",
                level=ErrorLevels.INFO,
                proteus_id=self.pns_id,
            )

    def _find_connector_lines(self, group) -> list[core_diagram.ConnectorLine]:
        """Find all connector lines recursively in a given group.

        This helper method searches through a group and its subgroups to find all
        connector line elements.

        Parameters
        ----------
        group : core_diagram.Static | core_diagram.RepresentationGroup
            The group to search for connector lines

        Returns
        -------
        list[core_diagram.ConnectorLine]
            A list of found connector line elements
        """
        connector_lines = []
        if isinstance(group, core_diagram.Static):
            connector_lines.extend(
                element
                for element in group.elements
                if isinstance(element, core_diagram.ConnectorLine)
            )
        elif isinstance(group, core_diagram.RepresentationGroup):
            for subgroup in group.groups:
                connector_lines.extend(self._find_connector_lines(subgroup))
        return connector_lines

    def _extract_connections(self) -> None:
        """Extract connection relationships from the PipingNetworkSegment element.

        This method retrieves the connections from the XML element and sets the attributes
        for from_id, to_id, from_node_index, and to_node_index. It also registers errors if
        multiple connection elements or attributes are found.
        """
        try:
            attrs = {
                "FromID": None,
                "ToID": None,
                "FromNode": None,
                "ToNode": None,
            }

            # Find all ConnectionPoints in the PipingNetworkSegment element
            connection_points = self.element.findall("Connection")

            # If more than one connection point is found, log a warning. This is not expected
            # directly
            if len(connection_points) > 1:
                self.register_error(
                    "Multiple ConnectionPoints found in PipingNetworkSegment. "
                    "Will only parse the first of each element encountered",
                    level=ErrorLevels.WARNING,
                )

            # Iterate through the connection points and extract attributes. If multiple attributes
            # are found, log an error and use the first encountered value.
            for connection_point in connection_points:
                for attr_name in ["FromID", "ToID", "FromNode", "ToNode"]:
                    if connection_point.get(attr_name) is not None:
                        if attrs[attr_name] is not None:
                            self.register_error(
                                f"Multiple {attr_name} attributes found in ConnectionPoints. "
                                "Will only parse the first of each element encountered.",
                                level=ErrorLevels.ERROR,
                            )
                        else:
                            attrs[attr_name] = connection_point.get(attr_name)

            # Set attributes
            self.from_id = attrs["FromID"]
            self.to_id = attrs["ToID"]
            if attrs["FromNode"] is None:
                self.from_node_index = None
            else:
                try:
                    self.from_node_index = int(attrs["FromNode"])
                except (ValueError, TypeError):
                    self.register_error(
                        f"Invalid FromNode index: {attrs['FromNode']}",
                        level=ErrorLevels.ERROR,
                    )
                    self.from_node_index = None
            if attrs["ToNode"] is None:
                self.to_node_index = None
            else:
                try:
                    self.to_node_index = int(attrs["ToNode"])
                except (ValueError, TypeError):
                    self.register_error(
                        f"Invalid ToNode index: {attrs['ToNode']}",
                        level=ErrorLevels.ERROR,
                    )
                    self.to_node_index = None

        except Exception as e:
            # Broad exception handler: connection-point extraction walks the whole
            # PipingNetworkSegment element; do not abort parsing the whole document.
            logger.debug("Error extracting connection points", exc_info=True)
            self.register_error(
                f"Error extracting connection points: {e}",
                level=ErrorLevels.ERROR,
                exception=e,
            )

    def _infer_is_reversed(
        self,
    ) -> bool:
        """Infer if the piping network segment is reversed based on connection points.

        This method checks if the last element in the pns_elements is the source or if the first
        element is the target. If either condition is true, it indicates that the piping network
        segment is reversed. Method should be called after compositional pass. Does not handle
        errors.

        Returns
        -------
        bool
            True if the piping network segment is reversed, False otherwise.
        """
        # If there are no pns_elements, return False
        if not self.pns_elements:
            return False

        source_obj = self.get_object_from_registry(self.from_id)
        target_obj = self.get_object_from_registry(self.to_id)

        # If the last element is the source or the first element is the target, it is reversed
        return source_obj is self.pns_elements[-1] or target_obj is self.pns_elements[0]

    def _infer_direct_connections_at_ends(self) -> None:
        """Checks if direct piping connections are needed at the start or end of the segment.

        This method infers if a direct piping connection is needed at the start or the end of the
        segment. This is needed if an external source/target is defined, but the first/last element
        is an item, or the segment is empty completely. In this case, a direct piping connection is
        added to the start/end.

        This method needs to be called AFTER the potential reversal of the segment, since it assumes
        that the first element is the start and the last element is the end of the segment. It
        needs to be called BEFORE establishing the internal and external sources and targets of the
        connections and the segment itself, since it does not take care of that for the potentially
        created connections."""

        source_obj = self.get_object_from_registry(self.from_id)
        first_element = self.pns_elements[0] if self.pns_elements else None

        if (
            source_obj is not None
            and source_obj is not first_element
            and (
                isinstance(first_element, piping.PipingNetworkSegmentItem) or first_element is None
            )
        ):
            direct_connection = piping.DirectPipingConnection()
            self.pns_elements.insert(0, direct_connection)
            self.pn_segment.connections.insert(0, direct_connection)

        target_obj = self.get_object_from_registry(self.to_id)
        last_element = self.pns_elements[-1] if self.pns_elements else None

        if (
            target_obj is not None
            and target_obj is not last_element
            and (isinstance(last_element, piping.PipingNetworkSegmentItem) or last_element is None)
        ):
            direct_connection = piping.DirectPipingConnection()
            self.pns_elements.append(direct_connection)
            self.pn_segment.connections.append(direct_connection)


class PipingNetworkSystemParser(ParserModule):
    """Parser for PipingNetworkSystem elements in the DEXPI model.

    Extracts the PipingNetworkSystem from the XML element. Composes all segments and
    generic attributes in the compositional pass and returns an instance of PipingNetworkSystem.
    In the reference pass, it checks if there are any unconnected segments and infers an implicit
    connection between them if so, according to the DEXPI convention. No control pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the piping network system to be parsed.
    segment_parsers : list[PipingNetworkSegmentParser]
        A list of parsers for the piping network segments in the system.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the piping network system.
    system_id : str | None
        The ID of the piping network system being constructed. Set during compositional pass.
    the_system : piping.PipingNetworkSystem | None
        The PipingNetworkSystem object being constructed. Set during compositional pass.
    segment_ids : list[str]
        A list of IDs of the segments in the piping network system. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        segment_parsers: list[PipingNetworkSegmentParser],
        generic_attribute_parser: GenericAttributeParser,
        label_parsers: list[LabelParser],
    ) -> None:
        """Initialize the PipingNetworkSystemParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The module context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the piping network system to be parsed.
        segment_parsers : list[PipingNetworkSegmentParser]
            A list of parsers for the piping network segments in the system.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the piping network system.
        label_parsers : list[LabelParser]
            A list of parsers for the labels in the piping network system.
        """
        super().__init__(context, element)
        self.system_id = None
        self.the_system = None
        self.system_dwg = None

        self.segment_ids = []

        # Set and register segment parsers
        self.segment_parsers = segment_parsers
        self.register_submodule_list(segment_parsers)

        # Initialize parsers for generic attributes
        self.gen_attr_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Initialize parsers for labels
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self):
        """Parse the PipingNetworkSystem in the compositional pass.

        Composes all segments and generic attributes and creates a PipingNetworkSystem with the
        parsed data. Registers the system object in the module context. Also logs any errors that
        occur during compositional parsing.

        Returns
        -------
        piping.PipingNetworkSystem | None
            An instance of the PipingNetworkSystem class created from the parsed attributes, or
            None if an error occurred during parsing.
        """
        # Extract pns id
        self.system_id = self.element.get("ID")
        if self.system_id is None:
            self.register_error(*ErrorTemplates.id_not_found("PipingNetworkSystem"))
            return None

        # Compose all piping network segments
        segments = []
        for segment_parser in self.segment_parsers:
            segment = segment_parser.compositional_pass()
            self.segment_ids.append(segment_parser.pns_id)
            if segment is not None:
                segments.append(segment)

        # Compose generic attributes
        generic_attrs = self.gen_attr_parser.compositional_pass(piping.PipingNetworkSystem)

        kwargs = generic_attrs.copy()
        kwargs["segments"] = segments

        self.the_system = piping.PipingNetworkSystem(id=self.system_id, **kwargs)

        # Register the PipingNetworkSystem object
        self.register_object(self.element.get("ID"), self.the_system)

        return self.the_system

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Perform a reference pass over the PipingNetworkSystem.

        This method calls the reference pass on all submodules. Checks if there are any unconnected
        segments. If there are, a connection is inferred between its neighboring segments.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.the_system is None or self.system_id is None:
            self.register_error(*ErrorTemplates.skip_pass("reference", "PipingNetworkSystem"))
            return

        # Check if connections need to be inferred between the segments
        for i, segment_id in enumerate(self.segment_ids):
            if segment_id is None:
                continue

            segment = self.get_object_from_registry(segment_id)
            has_no_source = segment.sourceItem is None
            has_no_target = segment.targetItem is None

            # Attempt to infer a connection if the segment is free and unconnected
            if i > 0 and has_no_source:
                # Check if the previous segment is connected internally, in which case connection
                # can be inferred
                prev_segment_id = self.segment_ids[i - 1]
                if prev_segment_id is not None:
                    prev_segment = self.get_object_from_registry(prev_segment_id)
                    if (
                        prev_segment
                        and prev_segment.targetItem in prev_segment.items
                        and prev_segment.targetItem is not None
                    ):
                        # Get connector node index:
                        connector_node_index = (
                            prev_segment.targetItem.nodes.index(prev_segment.targetNode)
                            if prev_segment.targetNode
                            else None
                        )

                        ptk.connect_piping_network_segment(
                            segment,
                            prev_segment.targetItem,
                            connector_node_index=connector_node_index,
                            as_source=True,
                        )

                        # Log info about the inferred connection
                        self.register_error(
                            f"Inferred connection between segment {i} and previous segment.",
                            level=ErrorLevels.INFO,
                        )

            if i < len(self.the_system.segments) - 1 and has_no_target:
                # Check if the next segment is connected internally, in which case connection
                # can be inferred
                next_segment_id = self.segment_ids[i + 1]
                if next_segment_id is not None:
                    next_segment = self.get_object_from_registry(next_segment_id)
                    if (
                        next_segment
                        and next_segment.sourceItem in next_segment.items
                        and next_segment.sourceItem is not None
                    ):
                        # Get connector node index:
                        connector_node_index = (
                            next_segment.sourceItem.nodes.index(next_segment.sourceNode)
                            if next_segment.sourceNode
                            else None
                        )

                        ptk.connect_piping_network_segment(
                            segment,
                            next_segment.sourceItem,
                            connector_node_index=connector_node_index,
                            as_source=False,
                        )

                        # Log info about the inferred connection
                        self.register_error(
                            f"Inferred connection between segment {i} and next segment.",
                            level=ErrorLevels.INFO,
                            proteus_id=self.system_id,
                        )

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the pns labels."""

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.the_system and self.system_id):
            self.register_error(*ErrorTemplates.skip_pass("drawing", "PipingNetworkSystem"))
            return

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process labels
        labels = [parser.drawing_pass() for parser in self.label_parsers]
        labels = filter_none(labels)
        groups.extend(labels)

        self.system_dwg = core_diagram.RepresentationGroup(
            represents=self.the_system, groups=groups, nodePositions=node_positions
        )

        segements_dwg = [parser.drawing_pass() for parser in self.segment_parsers]
        segements_dwg = filter_none(segements_dwg)
        for segment_dwg in segements_dwg:
            self.system_dwg.groups.append(segment_dwg)

        return self.system_dwg


### INSTRUMENTATION PARSERS ###
class ActuatingSystemComponentParser(ParserModule):
    """Parser for ActuatingSystemComponent elements in the DEXPI model.

    Parsing ActuatingSystemComponent elements into corresponding pyDEXPI objects. In the
    compositional pass, determines the correct pyDEXPI class based on the ComponentClass attribute.
    Modeled as CustomActuatingSystemComponent if the class name is not part of the pyDEXPI
    instrumentation package. Composes all associations and generic attributes, and creates the
    component object. Establishes associations of type "refers to" (if the class is an
    OperatedValveReference). No control pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the ActuatingSystemComponent to be parsed.
    association_parsers : list[AssociationParser]
        A list of parsers for the associations related to the ActuatingSystemComponent.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the ActuatingSystemComponent.
    component_id : str | None
        The ID of the ActuatingSystemComponent being constructed. Set during compositional pass.
    component : OperatedValveReference | ControlledActuator | Positioner |
                CustomActuatingSystemComponent | None
        The ActuatingSystemComponent object being constructed. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        shape_usage_parser: ShapeUsageParser,
        label_parsers: list[LabelParser],
        connection_point_parsers: list[ConnectionPointParser],
    ) -> None:
        """Initialize the ActuatingSystemComponentParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The module context providing access to the ID stack and error registry.
        element : etree._Element
            The XML element containing the ActuatingSystemComponent to be parsed.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations related to the ActuatingSystemComponent.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the ActuatingSystemComponent.
        shape_usage_parser : ShapeUsageParser
            A parser for the shape usage of the ActuatingSystemComponent.
        label_parsers : list[LabelParser]
            A list of parsers for the labels of the ActuatingSystemComponent.
        connection_point_parsers : list[ConnectionPointParser]
            A list of parsers for the connection points of the ActuatingSystemComponent.
        """
        super().__init__(context, element)
        self.component_id = None
        self.component = None
        self.as_component_dwg = None

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register shape usage parser
        self.shape_usage_parser = shape_usage_parser
        # There is a potential of actuating system components not having a shape usage
        if shape_usage_parser is not None:
            self.register_submodule(shape_usage_parser)

        # Set and register label parsers
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

        # Set and register connection point parsers
        self.connection_point_parsers = connection_point_parsers
        self.register_submodule_list(connection_point_parsers)

    def compositional_pass(
        self,
    ) -> (
        instrumentation.OperatedValveReference
        | instrumentation.ControlledActuator
        | instrumentation.Positioner
        | instrumentation.CustomActuatingSystemComponent
        | None
    ):
        """Parse the ActuatingSystemComponent in the compositional pass.

        Retrieves the correct pyDEXPI class based on the ComponentClass attribute, and instantiates
        the component with parsed data.

        Returns
        -------
        OperatedValveReference | ControlledActuator | Positioner | CustomActuatingSystemComponent |
        None
            An instance of the ActuatingSystemComponent class created from the parsed attributes,
            or None if an error occurs during parsing.
        """
        # Extract ID
        self.component_id = self.element.get("ID")
        if self.component_id is None:
            self.register_error(*ErrorTemplates.id_not_found("ActuatingSystemComponent"))
            return None

        kwargs = {}

        # Get component type
        class_name = self.element.get("ComponentClass")

        # If the class name is not part of instrumentation, skip the component: the DEXPI 2.0
        # ActuatingSystem has only typed slots (controlledActuator, operatedValveReference,
        # positioner), so there is no generic class an unknown component could map to.
        # TypeError covers a missing ComponentClass attribute (class_name is None).
        try:
            MyClass = getattr(instrumentation, class_name)
        except (AttributeError, TypeError):
            self.register_error(
                f"Unknown ComponentClass {class_name!r} for ActuatingSystemComponent. Skipping "
                f"the component.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(MyClass)
        kwargs.update(generic_attrs)

        # Make component and register it
        self.component = MyClass(id=self.component_id, **kwargs)

        self.register_object(self.component_id, self.component)
        return self.component

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Perform a reference pass over the ActuatingSystemComponent.

        Establishes associations of type "refers to" if the component is an OperatedValveReference,
        and logs errors if the associations are not valid.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.component is None or self.component_id is None:
            self.register_error(*ErrorTemplates.skip_pass("reference", "ActuatingSystemComponent"))
            return

        # Establish associations of type "refers to" if the component is an OperatedValveReference
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            # Check if the component is valid
            assoc_type = association_parser.get_type()
            if assoc_type == "refers to" and isinstance(
                self.component, instrumentation.OperatedValveReference
            ):
                # If the component is a reference, check if it is valid
                referenced_item = association_parser.get_referenced_item()
                referenced_item_id = association_parser.get_id()
                try:
                    self.component.valve = referenced_item
                except (ValidationError, TypeError) as e:
                    logger.debug(
                        "Error setting valve attribute for OperatedValveReference %s",
                        self.component_id,
                        exc_info=True,
                    )
                    self.register_error(
                        f"Error setting valve attribute to {referenced_item_id} for "
                        f"OperatedValveReference {self.component_id}: {e}",
                        level=ErrorLevels.ERROR,
                        exception=e,
                    )
            else:
                self.register_error(
                    *ErrorTemplates.inval_assoc_type("ActuatingSystemComponent", assoc_type)
                )

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the ActuatingSystemComponent.

        This method calls the drawing pass on all submodules and collects their graphical
        representations into a RepresentationGroup.

        Returns
        -------
        core_diagram.RepresentationGroup | None
            A RepresentationGroup containing all graphical representations from submodules, or
            None if an error occurs during the drawing pass.
        """

        # Collect graphical representations from all submodules
        if not (self.component and self.component_id):
            self.register_error(*ErrorTemplates.skip_pass("drawing", "ActuatingSystemComponent"))
            return

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process shape usage
        if self.shape_usage_parser is not None:
            shape_usage = self.shape_usage_parser.drawing_pass()
            if shape_usage is not None:
                static = core_diagram.Static(elements=[shape_usage])
                groups.append(static)

        # Process labels
        if self.label_parsers:
            labels = [parser.drawing_pass() for parser in self.label_parsers]
            labels = filter_none(labels)
            groups.extend(labels)

        # Process connection points
        connection_points_dict = {}
        if self.connection_point_parsers:
            # Combine all connection points from parsers into a single dictionary
            for parser in self.connection_point_parsers:
                cp_dict = parser.drawing_pass()
                if cp_dict:
                    connection_points_dict.update(cp_dict)

            # Add all node positions to the representation group
            node_positions.extend(connection_points_dict.values())

        self.as_component_dwg = core_diagram.RepresentationGroup(
            represents=self.component, groups=groups, nodePositions=node_positions
        )

        self.register_object(f"{self.component_id}_cp_node_positions", connection_points_dict)

        return self.as_component_dwg


class ActuatingSystemParser(ParserModule):
    """Parser for ActuatingSystem elements in the DEXPI model.

    Parses ActuatingSystem elements into an instance of the ActuatingSystem class. Collects all
    subcomponents and attributes in compositional pass, and returns created instance of
    ActuatingSystem. No reference or control pass required

    Attributes
    ----------
    context : ModuleContext
        The context in which the parser is operating.
    element : etree._Element
        The XML element containing the ActuatingSystem to be parsed.
    component_parsers : list[ActuatingSystemComponentParser]
        The component parsers for the ActuatingSystem.
    generic_attribute_parser : GenericAttributeParser
        The parser for the generic attributes of the ActuatingSystem.
    actuating_system_id : str | None
        The ID of the ActuatingSystem. Set during compositional pass.
    actuating_system : instrumentation.ActuatingSystem | None
        The parsed ActuatingSystem instance. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        component_parsers: list[ActuatingSystemComponentParser],
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        label_parsers: list[LabelParser],
    ) -> None:
        super().__init__(context, element)
        self.actuating_system_id = None
        self.actuating_system = None
        self.actuating_system_dwg = None

        # Set and register component parsers
        self.component_parsers = component_parsers
        self.register_submodule_list(component_parsers)

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register label parsers
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> instrumentation.ActuatingSystem | None:
        """Parse the ActuatingSystem in the compositional pass.

        Composes all components and generic attributes, and creates an instance of the
        ActuatingSystem class.

        Returns
        -------
        instrumentation.ActuatingSystem | None
            An instance of the ActuatingSystem class created from the parsed attributes, or None
            if an error occurred during parsing.
        """
        # Extract ID. If not found, register an error and return None.
        self.actuating_system_id = self.element.get("ID")
        if self.actuating_system_id is None:
            self.register_error(*ErrorTemplates.id_not_found("ActuatingSystem"))
            return None

        # Compose association parsers
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose all components. Sort them into ControlledActuator, OperatedValveReference,
        # Positioner, and CustomActuatingSystemComponent
        actuator = None
        valve_ref = None
        positioner = None
        for component_parser in self.component_parsers:
            component = component_parser.compositional_pass()
            if component:
                if isinstance(component, instrumentation.ControlledActuator):
                    if actuator is not None:
                        self.register_error(
                            "Multiple ControlledActuator components found. Only one is allowed "
                            "in an ActuatingSystem. Keeping the first one encountered.",
                            level=ErrorLevels.ERROR,
                        )
                    else:
                        actuator = component
                elif isinstance(component, instrumentation.OperatedValveReference):
                    if valve_ref is not None:
                        self.register_error(
                            "Multiple OperatedValveReference components found. Only one is "
                            "allowed in an ActuatingSystem. Keeping the first one encountered.",
                            level=ErrorLevels.ERROR,
                        )
                    else:
                        valve_ref = component
                elif isinstance(component, instrumentation.Positioner):
                    if positioner is not None:
                        self.register_error(
                            "Multiple Positioner components found. Only one is allowed "
                            "in an ActuatingSystem. Keeping the first one encountered.",
                            level=ErrorLevels.ERROR,
                        )
                    else:
                        positioner = component
                else:
                    self.register_error(
                        f"Unexpected component {component} encountered in Actuating system",
                        level=ErrorLevels.ERROR,
                    )

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(
            instrumentation.ActuatingSystem
        )

        # Create the ActuatingSystem object
        self.actuating_system = instrumentation.ActuatingSystem(
            id=self.actuating_system_id,
            controlledActuator=actuator,
            operatedValveReference=valve_ref,
            positioner=positioner,
            **generic_attrs,
        )

        # Register and return the ActuatingSystem object
        self.register_object(self.actuating_system_id, self.actuating_system)
        return self.actuating_system

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Checks if associations of type "fulfills" to ActuatingFunction objects have been made."""
        # Call super to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.actuating_system_id is None or self.actuating_system is None:
            self.register_error(*ErrorTemplates.skip_pass("control", "ActuatingSystem"))
            return

        # Iterate through all association parsers and check if they are valid. Check if they have
        # been established in reference pass, and if not, try to add them in control pass.
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            assoc_type = association_parser.get_type()
            if assoc_type != "fulfills":
                # Not permitted for ActuatingSystem, add warning
                self.register_error(*ErrorTemplates.inval_assoc_type("ActuatingSystem", assoc_type))
                continue

            else:
                associated_object = association_parser.get_referenced_item()
                association_id = association_parser.get_id()
                if not is_associated_with(self.actuating_system, associated_object):
                    # Log warning and try to add association in control pass
                    self.register_error(
                        *ErrorTemplates.no_assoc_ctrl("ActuatingSystem", association_id)
                    )
                    try:
                        fld = add_by_inferring_type(self.actuating_system, associated_object)
                        # Log an info error if the association was added in control pass
                        self.register_error(
                            *ErrorTemplates.assoc_added_ctrl("ActuatingSystem", association_id, fld)
                        )
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_not_added_ctrl("ActuatingSystem", association_id),
                            exception=e,
                        )

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the actuating system labels and components."""

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.actuating_system and self.actuating_system_id):
            self.register_error(*ErrorTemplates.skip_pass("drawing", "ActuatingSystem"))
            return

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process labels
        labels = [parser.drawing_pass() for parser in self.label_parsers]
        labels = filter_none(labels)
        groups.extend(labels)

        # generate actuating system dwg
        self.actuating_system_dwg = core_diagram.RepresentationGroup(
            represents=self.actuating_system, groups=groups, nodePositions=node_positions
        )

        as_components = [parser.drawing_pass() for parser in self.component_parsers]
        for as_component in as_components:
            if as_component is not None:
                self.actuating_system_dwg.groups.append(as_component)

        return self.actuating_system_dwg


class ProcessSignalGeneratingSystemComponentParser(ParserModule):
    """Parser for ProcessSignalGeneratingSystemComponent elements in the DEXPI model.

    Parses ProcessSignalGeneratingSystemComponent elements into an instance of the appropriate
    pyDEXPI class. In the compositional pass, it determines the correct class based on the
    ComponentClass attribute. In the reference pass, it establishes all associations of type
    "refers to" if the component is an InlinePrimaryElementReference. No control pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the ProcessSignalGeneratingSystemComponent to be parsed.
    association_parsers : list[AssociationParser]
        A list of parsers for the associations related to the component.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the component.
    component_id : str | None
        The ID of the ProcessSignalGeneratingSystemComponent being constructed. Set during
        compositional pass.
    component : Transmitter | PrimaryElement | CustomProcessSignalGeneratingSystemComponent | None
        The ProcessSignalGeneratingSystemComponent object being constructed. Set during
        compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        shape_usage_parser: ShapeUsageParser,
        label_parsers: list[LabelParser],
    ) -> None:
        """Initialize the ProcessSignalGeneratingSystemComponentParser with the element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the ProcessSignalGeneratingSystemComponent to be parsed.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations related to the component.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the component.
        """
        super().__init__(context, element)
        self.component = None
        self.component_id = None
        self.psgsc_dwg = None

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register shape usage parser
        self.shape_usage_parser = shape_usage_parser
        self.register_submodule(shape_usage_parser)

        # Set and register label parsers
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

    @redirect_errors_to_registry
    def compositional_pass(
        self,
    ) -> (
        instrumentation.Transmitter
        | instrumentation.PrimaryElement
        | instrumentation.CustomProcessSignalGeneratingSystemComponent
        | None
    ):
        """Parse the ProcessSignalGeneratingSystemComponent in compositional pass.

        Retrieves the correct pyDEXPI class based on the ComponentClass attribute, and instantiates
        the component with parsed data. If no valid class is found, it uses
        CustomProcessSignalGeneratingSystemComponent.

        Returns
        -------
        Transmitter | PrimaryElement | CustomProcessSignalGeneratingSystemComponent | None
            The ProcessSignalGeneratingSystemComponent instance created from the parsed attributes,
            or None if an error occurs during parsing.
        """
        # Extract ID. If not found, register an error and return None.
        self.component_id = self.element.get("ID")
        if self.component_id is None:
            self.register_error(*ErrorTemplates.id_not_found("ProcessSignalGeneratingSystem"))
            return None

        kwargs = {}

        # Get component type
        class_name = self.element.get("ComponentClass")

        # If the class name is not part of instrumentation, skip the component: the DEXPI 2.0
        # model has no generic signal generating system component class an unknown component
        # could map to. TypeError covers a missing ComponentClass attribute (class_name is None).
        try:
            MyClass = getattr(instrumentation, class_name)
        except (AttributeError, TypeError):
            self.register_error(
                f"Unknown ComponentClass {class_name!r} for ProcessSignalGeneratingSystem"
                f"Component. Skipping the component.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(MyClass)
        kwargs.update(generic_attrs)

        # Make component and register it
        self.component = MyClass(id=self.component_id, **kwargs)

        self.register_object(self.component_id, self.component)
        return self.component

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Perform a reference pass over the ProcessSignalGeneratingSystemComponent.

        Establishes associations of type "refers to" if the component is an
        InlinePrimaryElementReference.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.component is None or self.component_id is None:
            self.register_error(
                *ErrorTemplates.skip_pass("reference", "ProcessSignalGeneratingSystemComponent")
            )
            return

        # Establish associations
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            # Check if the component is valid
            assoc_type = association_parser.get_type()
            if assoc_type == "refers to" and isinstance(
                self.component, instrumentation.InlinePrimaryElementReference
            ):
                # If the component is a reference, check if it is valid
                referenced_item = association_parser.get_referenced_item()
                referenced_item_id = association_parser.get_id()
                try:
                    self.component.inlinePrimaryElement = referenced_item
                except (ValidationError, TypeError) as e:
                    logger.debug(
                        "Error setting inlinePrimaryElement for ProcessSignalGeneratingSystemComponent %s",
                        referenced_item_id,
                        exc_info=True,
                    )
                    self.register_error(
                        *ErrorTemplates.assoc_adding_error(
                            "ProcessSignalGeneratingSystemComponent", referenced_item_id
                        ),
                        exception=e,
                    )
            else:
                self.register_error(
                    *ErrorTemplates.inval_assoc_type(
                        "ProcessSignalGeneratingSystemComponent", assoc_type
                    )
                )

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the ProcessSignalGeneratingSystemComponent.

         This method calls the drawing pass on all submodules and collects their graphical
         representations into a RepresentationGroup.

         Returns
         -------
        core_diagram.RepresentationGroup | None
             A RepresentationGroup containing all graphical representations from submodules, or
             None if an error occurs during the drawing pass.
        """

        # Collect graphical representations from all submodules
        if not (self.component and self.component_id):
            self.register_error(
                *ErrorTemplates.skip_pass("drawing", "ProcessSignalGeneratingSystemComponent")
            )
            return

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process shape usage
        shape_usage = self.shape_usage_parser.drawing_pass()
        if shape_usage is not None:
            static = core_diagram.Static(elements=[shape_usage])
            groups.append(static)

        # Process labels
        labels = [parser.drawing_pass() for parser in self.label_parsers]
        labels = filter_none(labels)
        groups.extend(labels)

        self.psgsc_dwg = core_diagram.RepresentationGroup(
            represents=self.component, groups=groups, nodePositions=node_positions
        )

        return self.psgsc_dwg


class ProcessSignalGeneratingSystemParser(ParserModule):
    """Parser for ProcessSignalGeneratingSystem elements in the DEXPI model.

    Parses ProcessSignalGeneratingSystem elements into an instance of the
    ProcessSignalGeneratingSystem class. Collects all subcomponents and attributes in compositional
    pass, and returns created instance of ProcessSignalGeneratingSystem. No reference or control
    pass required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the ProcessSignalGeneratingSystem to be parsed.
    component_parsers : list[ProcessSignalGeneratingSystemComponentParser]
        The component parsers for the ProcessSignalGeneratingSystem.
    generic_attribute_parser : GenericAttributeParser
        The parser for the generic attributes of the ProcessSignalGeneratingSystem.
    process_signal_system_id : str | None
        The ID of the ProcessSignalGeneratingSystem. Set during compositional pass.
    process_signal_system : instrumentation.ProcessSignalGeneratingSystem | None
        The parsed ProcessSignalGeneratingSystem instance. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        component_parsers: list[ProcessSignalGeneratingSystemComponentParser],
        generic_attribute_parser: GenericAttributeParser,
        label_parsers: list[LabelParser],
    ) -> None:
        """Initialize the ProcessSignalGeneratingSystemParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the ProcessSignalGeneratingSystem to be parsed.
        component_parsers : list[ProcessSignalGeneratingSystemComponentParser]
            A list of parsers for the components in the system.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the system.
        """
        super().__init__(context, element)
        self.process_signal_system_id = None
        self.process_signal_system = None
        self.process_signal_system_dwg = None

        # Set and register component parsers
        self.component_parsers = component_parsers
        self.register_submodule_list(component_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register label parsers
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> instrumentation.ProcessSignalGeneratingSystem | None:
        """Parse the ProcessSignalGeneratingSystem in the compositional pass.

        Composes all components and generic attributes, and creates an instance of the
        ProcessSignalGeneratingSystem class.

        Returns
        -------
        instrumentation.ProcessSignalGeneratingSystem | None
            An instance of the ProcessSignalGeneratingSystem class created from the parsed
            attributes, or None if an error occurred during parsing.
        """
        # Extract ID. If not found, register an error and return None.
        self.process_signal_system_id = self.element.get("ID")
        if self.process_signal_system_id is None:
            self.register_error(*ErrorTemplates.id_not_found("ProcessSignalGeneratingSystem"))
            return None

        # Compose all components. Sort them into Transmitter, PrimaryElement,
        # and CustomProcessSignalGeneratingSystemComponent
        transmitters = []
        primary_elements = []
        custom_components = []

        for component_parser in self.component_parsers:
            component = component_parser.compositional_pass()
            if component:
                if isinstance(component, instrumentation.Transmitter):
                    transmitters.append(component)
                elif isinstance(component, instrumentation.PrimaryElement):
                    primary_elements.append(component)
                elif isinstance(
                    component, instrumentation.CustomProcessSignalGeneratingSystemComponent
                ):
                    custom_components.append(component)
                else:
                    self.register_error(
                        f"Unexpected component {component} encountered in "
                        f"ProcessSignalGeneratingSystem",
                        level=ErrorLevels.ERROR,
                    )

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(
            instrumentation.ProcessSignalGeneratingSystem
        )

        # Create the ProcessSignalGeneratingSystem object
        process_signal_system = instrumentation.ProcessSignalGeneratingSystem(
            id=self.process_signal_system_id,
            transmitters=filter_none(transmitters),
            primaryElements=filter_none(primary_elements),
            customComponents=filter_none(custom_components),
            **generic_attrs,
        )

        # Register and return the ProcessSignalGeneratingSystem object
        self.register_object(self.process_signal_system_id, process_signal_system)
        self.process_signal_system = process_signal_system

        return process_signal_system

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass over the process signal generating system labels."""

        # Skip pass if the reference object or ID is not available due to previous error
        if not (self.process_signal_system and self.process_signal_system_id):
            self.register_error(
                *ErrorTemplates.skip_pass("drawing", "ProcessSignalGeneratingSystem")
            )
            return

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process labels
        labels = [parser.drawing_pass() for parser in self.label_parsers]
        labels = filter_none(labels)
        groups.extend(labels)

        # generate process signal generating system dwg
        self.process_signal_system_dwg = core_diagram.RepresentationGroup(
            represents=self.process_signal_system, groups=groups, nodePositions=node_positions
        )

        psgs_components = [parser.drawing_pass() for parser in self.component_parsers]
        # Add subequipment by inferring type

        for psgs_component in psgs_components:
            if psgs_component is not None:
                self.process_signal_system_dwg.groups.append(psgs_component)

        return self.process_signal_system_dwg


class ActuatingFunctionParser(ParserModule):
    """Parser for ActuatingFunction elements in the DEXPI model.

    Parses ActuatingFunction elements into an instance of the ActuatingFunction class. Collects all
    associations and generic attributes in compositional pass, and returns created instance of
    ActuatingFunction. In the reference pass, it establishes associations of type "is located in"
    as the ActuatingLocation attribute of the ActuatingFunction, and associations of type
    "is fulfilled by" as the ActuatingElement attribute of the ActuatingFunction. In control pass,
    it checks if the associations of type "is logical start of" and "is logical end of" to
    InformationFlow objects have been made.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the ActuatingFunction to be parsed.
    association_parsers : list[AssociationParser]
        A list of parsers for the associations related to the ActuatingFunction.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the ActuatingFunction.
    actuating_function_id : str | None
        The ID of the ActuatingFunction being constructed. Set during compositional pass.
    actuating_function : instrumentation.ActuatingFunction | None
        The ActuatingFunction object being constructed. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
    ) -> None:
        """Initialize the ActuatingFunctionParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the ActuatingFunction to be parsed.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations related to the ActuatingFunction.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the ActuatingFunction.
        """
        super().__init__(context, element)
        self.actuating_function_id = None
        self.actuating_function = None

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

    @redirect_errors_to_registry
    def compositional_pass(self) -> instrumentation.ActuatingFunction | None:
        """Parse the ActuatingFunction in the compositional pass.

        Composes all associations and generic attributes, and creates an instance of the
        ActuatingFunction class.

        Returns
        -------
        instrumentation.ActuatingFunction | None
            An instance of the ActuatingFunction class created from the parsed attributes, or None
            if an error occurred during parsing.
        """
        # Extract ID. If not found, register an error and return None.
        self.actuating_function_id = self.element.get("ID")
        if self.actuating_function_id is None:
            self.register_error(*ErrorTemplates.id_not_found("ActuatingFunction"))
            return None

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(
            instrumentation.ActuatingFunction
        )

        # Create the ActuatingFunction object
        self.actuating_function = instrumentation.ActuatingFunction(
            id=self.actuating_function_id, **generic_attrs
        )

        # Register and return the ActuatingFunction object
        self.register_object(self.actuating_function_id, self.actuating_function)
        return self.actuating_function

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Parse the ActuatingFunction in the reference pass.

        Establishes associations of type "is located in" as the ActuatingLocation attribute of the
        ActuatingFunction. Establishes associations of type "is fulfilled by" as the system
        attribute of the ActuatingFunction. Since both associations can be at max one, it
        logs an error if multiple associations of the same type are found and keeps the first one
        encountered.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.actuating_function is None or self.actuating_function_id is None:
            self.register_error(*ErrorTemplates.skip_pass("reference", "ActuatingFunction"))
            return

        # Establish associations of type "is located in" and "is fulfilled by"
        for association_parser in self.association_parsers:
            # Log error and skip association if not valid
            if not association_parser.is_valid():
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            # Check if the association is of type "is located in"
            assoc_type = association_parser.get_type()
            assoc_id = association_parser.get_id()
            if assoc_type == "is located in":
                if self.actuating_function.actuatingLocation is not None:
                    self.register_error(
                        f"Multiple 'is located in' associations found for ActuatingFunction "
                        f"{self.actuating_function_id}. Keeping the first one encountered.",
                        level=ErrorLevels.ERROR,
                    )
                else:
                    try:
                        self.actuating_function.actuatingLocation = (
                            association_parser.get_referenced_item()
                        )
                    except (ValidationError, TypeError) as e:
                        logger.debug(
                            "Error setting actuatingLocation for ActuatingFunction %s",
                            assoc_id,
                            exc_info=True,
                        )
                        self.register_error(
                            *ErrorTemplates.assoc_adding_error("ActuatingFunction", assoc_id),
                            exception=e,
                        )

            # Check if the association is of type "is fulfilled by"
            elif association_parser.get_type() == "is fulfilled by":
                if self.actuating_function.systems is not None:
                    self.register_error(
                        f"Multiple 'is fulfilled by' associations found for ActuatingFunction "
                        f"{self.actuating_function_id}. Keeping the first one encountered.",
                        level=ErrorLevels.ERROR,
                    )
                else:
                    try:
                        self.actuating_function.systems = association_parser.get_referenced_item()
                    except (ValidationError, TypeError) as e:
                        logger.debug(
                            "Error setting systems for ActuatingFunction %s",
                            assoc_id,
                            exc_info=True,
                        )
                        self.register_error(
                            *ErrorTemplates.assoc_adding_error("ActuatingFunction", assoc_id),
                            exception=e,
                        )
            elif association_parser.get_type() in ["is logical start of", "is logical end of"]:
                # Processed in control pass, so skip here
                continue

            # If unexpected association type, log a warning
            else:
                self.register_error(
                    *ErrorTemplates.inval_assoc_type("ActuatingFunction", assoc_type)
                )

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Perform a control pass over the ActuatingFunction associations.

        Checks if associations of type "is logical start of" and "is logical end of" to
        InformationFlow objects have been made."""
        # Call super to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.actuating_function_id is None or self.actuating_function is None:
            self.register_error(*ErrorTemplates.skip_pass("control", "ActuatingFunction"))
            return

        # Iterate through all association parsers and check if they are valid. Check if they have
        # been established in reference pass, and if not, try to add them in control pass.
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Invalid association errors logged in reference pass
                continue

            elif association_parser.get_type() in ["is logical start of", "is logical end of"]:
                associated_object = association_parser.get_referenced_item()
                association_id = association_parser.get_id()
                if not is_associated_with(self.actuating_function, associated_object):
                    # Log warning and try to add association in control pass
                    self.register_error(
                        *ErrorTemplates.no_assoc_ctrl("ActuatingFunction", association_id)
                    )
                    try:
                        fld = add_by_inferring_type(self.actuating_function, associated_object)
                        # Log an info error if the association was added in control pass
                        self.register_error(
                            *ErrorTemplates.assoc_added_ctrl(
                                "ActuatingFunction", association_id, fld
                            )
                        )
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_not_added_ctrl(
                                "ActuatingFunction", association_id
                            ),
                            exception=e,
                        )


class ActuatingElectricalFunctionParser(ParserModule):
    """Parser for ActuatingElectricalFunction elements in the DEXPI model.

    Parses ActuatingElectricalFunction elements into an instance of the ActuatingElectricalFunction
    class. Collects all associations and generic attributes in compositional pass, and returns
    created instance of ActuatingElectricalFunction. In the reference pass, it establishes
    associations of type "is located in" as the ActuatingElectricalLocation attribute of the
    ActuatingElectricalFunction. Associations of type "is fulfilled by" to the
    ActuatingElectricalSystems are disregarded, as ActuatingElectricalSystems are illdefined in
    DEXPI 1.3. In control pass, it checks if the associations of type "is logical end of" to
    InformationFlow objects have been made.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the ActuatingElectricalFunction to be parsed.
    association_parsers : list[AssociationParser]
        A list of parsers for the associations related to the ActuatingElectricalFunction.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the ActuatingElectricalFunction.
    actuating_function_id : str | None
        The ID of the ActuatingElectricalFunction being constructed. Set during compositional pass.
    actuating_function : instrumentation.ActuatingElectricalFunction | None
        The ActuatingElectricalFunction object being constructed. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
    ) -> None:
        """Initialize the ActuatingElectricalFunctionParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the ActuatingElectricalFunction to be parsed.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations related to the ActuatingElectricalFunction.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the ActuatingElectricalFunction.
        """
        super().__init__(context, element)
        self.actuating_function_id = None
        self.actuating_function = None

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

    @redirect_errors_to_registry
    def compositional_pass(self) -> instrumentation.ActuatingElectricalFunction | None:
        """Parse the ActuatingElectricalFunction in the compositional pass.

        Composes all associations and generic attributes, and creates an instance of the
        ActuatingElectricalFunction class.

        Returns
        -------
        instrumentation.ActuatingElectricalFunction | None
            An instance of the ActuatingElectricalFunction class created from the parsed attributes,
            or None if an error occurred during parsing.
        """
        # Extract ID. If not found, register an error and return None.
        self.actuating_function_id = self.element.get("ID")
        if self.actuating_function_id is None:
            self.register_error(*ErrorTemplates.id_not_found("ActuatingFunction"))
            return None

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(
            instrumentation.ActuatingElectricalFunction
        )

        # Create the ActuatingElectricalFunction object
        self.actuating_function = instrumentation.ActuatingElectricalFunction(
            id=self.actuating_function_id, **generic_attrs
        )

        # Register and return the ActuatingElectricalFunction object
        self.register_object(self.actuating_function_id, self.actuating_function)
        return self.actuating_function

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Parse the ActuatingElectricalFunction in the reference pass.

        Establishes associations of type "is located in" as the ActuatingElectricalLocation
        attribute of the ActuatingElectricalFunction. Associations of type "is fulfilled by" are
        disregarded, due to ambiguous and faulty design of ActuatingElectricalSystem in DEXPI 1.3.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.actuating_function is None or self.actuating_function_id is None:
            self.register_error(
                *ErrorTemplates.skip_pass("reference", "ActuatingElectricalFunction")
            )
            return

        # Establish associations of type "is located in"
        for association_parser in self.association_parsers:
            # Log error and skip association if not valid
            if not association_parser.is_valid():
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            # Check if the association is of type "is located in"
            assoc_type = association_parser.get_type()
            if assoc_type == "is located in":
                if self.actuating_function.actuatingElectricalLocation is not None:
                    self.register_error(
                        f"Multiple 'is located in' associations found for "
                        f"ActuatingElectricalFunction {self.actuating_function_id}. Keeping the "
                        f"first one encountered.",
                        level=ErrorLevels.ERROR,
                    )
                else:
                    try:
                        self.actuating_function.actuatingElectricalLocation = (
                            association_parser.get_referenced_item()
                        )
                    except (ValidationError, TypeError) as e:
                        logger.debug(
                            "Error setting actuatingElectricalLocation for ActuatingElectricalFunction %s",
                            association_parser.get_id(),
                            exc_info=True,
                        )
                        self.register_error(
                            *ErrorTemplates.assoc_adding_error(
                                "ActuatingElectricalFunction", association_parser.get_id()
                            ),
                            exception=e,
                        )

            # Check if the association is of type "is fulfilled by"
            elif assoc_type == "is fulfilled by":
                self.register_error(
                    "Association of type 'is fulfilled by' to "
                    "ActuatingElectricalSystem objects is not implemented, due to unclear "
                    "definition of ActuatingElectricalSystem in DEXPI 1.3.",
                    level=ErrorLevels.ERROR,
                )
            elif assoc_type in ["is logical end of"]:
                # Processed in control pass, so skip here
                continue

            # If unexpected association type, log a warning
            else:
                self.register_error(
                    *ErrorTemplates.inval_assoc_type("ActuatingElectricalFunction", assoc_type)
                )

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Perform a control pass over the ActuatingElectricalFunction associations.

        Checks if associations of type "is logical end of" to InformationFlow objects have been
        made."""
        # Call super to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.actuating_function_id is None or self.actuating_function is None:
            self.register_error(*ErrorTemplates.skip_pass("control", "ActuatingElectricalFunction"))
            return

        # Iterate through all association parsers and check if they are valid. Check if they have
        # been established in reference pass, and if not, try to add them in control pass.
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Invalid association errors logged in reference pass
                continue

            elif association_parser.get_type() in ["is logical end of"]:
                associated_object = association_parser.get_referenced_item()
                association_id = association_parser.get_id()
                if not is_associated_with(self.actuating_function, associated_object):
                    # Log warning and try to add association in control pass
                    self.register_error(
                        *ErrorTemplates.no_assoc_ctrl("ActuatingFunction", association_id)
                    )
                    try:
                        fld = add_by_inferring_type(self.actuating_function, associated_object)
                        # Log an info error if the association was added in control pass
                        self.register_error(
                            *ErrorTemplates.assoc_added_ctrl(
                                "ActuatingElectricalFunction", association_id, fld
                            )
                        )
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_not_added_ctrl(
                                "ActuatingElectricalFunction", association_id
                            ),
                            exception=e,
                        )


class ProcessSignalGeneratingFunctionParser(ParserModule):
    """Parser for ProcessSignalGeneratingFunction elements in the DEXPI model.

    Parses ProcessSignalGeneratingFunction elements into an instance of the
    ProcessSignalGeneratingFunction class. Collects all associations and generic attributes in
    compositional pass, and returns created instance of ProcessSignalGeneratingFunction.
    In the reference pass, it establishes associations of type "is located in"
    as the SensingLocation attribute of the ProcessSignalGeneratingFunction, and associations of
    type "is fulfilled by" as the SensingLocation attribute of the ProcessSignalGeneratingFunction.
    In control pass, it checks if the associations of type "is logical start of" and
    "is logical end of" to InformationFlow objects have been made.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the ProcessSignalGeneratingFunction to be parsed.
    association_parsers : list[AssociationParser]
        A list of parsers for the associations related to the ProcessSignalGeneratingFunction.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the ProcessSignalGeneratingFunction.
    psgf_id : str | None
        The ID of the ProcessSignalGeneratingFunction being parsed.
    psgf : instrumentation.ProcessSignalGeneratingFunction | None
        The ProcessSignalGeneratingFunction object being constructed. Set during compositional pass.

    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
    ) -> None:
        """Initialize the ProcessSignalGeneratingFunctionParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the ProcessSignalGeneratingFunction to be parsed.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations related to the ProcessSignalGeneratingFunction.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the ProcessSignalGeneratingFunction.
        """
        super().__init__(context, element)
        self.psgf_id = None
        self.psgf = None

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(self.association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(self.generic_attribute_parser)

    @redirect_errors_to_registry
    def compositional_pass(self) -> instrumentation.ProcessSignalGeneratingFunction | None:
        """Parse the ProcessSignalGeneratingFunction in the compositional pass.

        Composes all associations and generic attributes, and creates an instance of the
        ProcessSignalGeneratingFunction class.

        Returns
        -------
        instrumentation.ProcessSignalGeneratingFunction | None
            An instance of the ProcessSignalGeneratingFunction class created from the parsed
            attributes, or None if an error occurred during parsing.
        """
        # Extract ID
        self.psgf_id = self.element.get("ID")
        if self.psgf_id is None:
            self.register_error(*ErrorTemplates.id_not_found("ProcessSignalGeneratingFunction"))
            return None

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(
            instrumentation.ProcessSignalGeneratingFunction
        )

        # Create the ProcessSignalGeneratingFunction object
        self.psgf = instrumentation.ProcessSignalGeneratingFunction(
            id=self.psgf_id, **generic_attrs
        )

        # Register and return the ProcessSignalGeneratingFunction object
        self.register_object(self.psgf_id, self.psgf)
        return self.psgf

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Parse the ProcessSignalGeneratingFunction in the reference pass.

        Establishes associations of type "is located in" as the SensingLocation attribute of the
        ProcessSignalGeneratingFunction. Establishes associations of type "is fulfilled by" as the
        system attribute of the ProcessSignalGeneratingFunction. Since both associations can be at
        max one, it logs an error if multiple associations of the same type are found and keeps the
        first one encountered.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip reference pass if id or object are not available due to previous error in
        # compositional pass.
        if self.psgf is None or self.psgf_id is None:
            self.register_error(
                *ErrorTemplates.skip_pass("reference", "ProcessSignalGeneratingFunction")
            )
            return

        # Establish associations of type "is located in" and "is fulfilled by"
        for association_parser in self.association_parsers:
            # Log error and skip association if not valid
            if not association_parser.is_valid():
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            # Check if the association is of type "is located in"
            assoc_type = association_parser.get_type()
            assoc_id = association_parser.get_id()
            if assoc_type == "is located in":
                if self.psgf.sensingLocation is not None:
                    i = self.psgf_id
                    self.register_error(
                        f"Multiple 'is located in' associations found for "
                        f"ProcessSignalGeneratingFunction {i}. Keeping the first one encountered.",
                        level=ErrorLevels.ERROR,
                    )
                else:
                    try:
                        self.psgf.sensingLocation = association_parser.get_referenced_item()
                    except (ValidationError, TypeError) as e:
                        logger.debug(
                            "Error setting sensingLocation for ProcessSignalGeneratingFunction %s",
                            assoc_id,
                            exc_info=True,
                        )
                        self.register_error(
                            *ErrorTemplates.assoc_adding_error(
                                "ProcessSignalGeneratingFunction", assoc_id
                            ),
                            exception=e,
                        )

            # Check if the association is of type "is fulfilled by"
            elif assoc_type == "is fulfilled by":
                if self.psgf.systems is not None:
                    i = self.psgf_id
                    self.register_error(
                        f"Multiple 'is fulfilled by' associations found for "
                        f"ProcessSignalGeneratingFunction {i}. Keeping the first one encountered.",
                        level=ErrorLevels.ERROR,
                    )
                else:
                    try:
                        self.psgf.systems = association_parser.get_referenced_item()
                    except (ValidationError, TypeError) as e:
                        logger.debug(
                            "Error setting systems for ProcessSignalGeneratingFunction %s",
                            self.psgf_id,
                            exc_info=True,
                        )
                        self.register_error(
                            *ErrorTemplates.assoc_adding_error(
                                "ProcessSignalGeneratingFunction", assoc_id
                            ),
                            exception=e,
                        )
            elif assoc_type in ["is logical start of"]:
                # Processed in control pass, so skip here
                continue

            # If unexpected association type, log a warning
            else:
                self.register_error(
                    *ErrorTemplates.inval_assoc_type("ProcessSignalGeneratingFunction", assoc_type)
                )

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Perform a control pass over the ProcessSignalGeneratingFunctionParser associations.

        Checks if associations of type "is logical start of" to InformationFlow objects have been
        made."""
        # Call super to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.psgf_id is None or self.psgf is None:
            self.register_error(
                *ErrorTemplates.skip_pass("control", "ProcessSignalGeneratingFunction")
            )
            return

        # Iterate through all association parsers and check if they are valid. Check if they have
        # been established in reference pass, and if not, try to add them in control pass.
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Invalid association errors logged in reference pass
                continue

            elif association_parser.get_type() in ["is logical start of"]:
                associated_object = association_parser.get_referenced_item()
                association_id = association_parser.get_id()
                if not is_associated_with(self.psgf, associated_object):
                    # Log warning and try to add association in control pass
                    err = ErrorTemplates.no_assoc_ctrl(
                        "ProcessSignalGeneratingFunction", association_id
                    )
                    self.register_error(*err)
                    try:
                        fld = add_by_inferring_type(self.psgf, associated_object)
                        # Log an info error if the association was added in control pass
                        self.register_error(
                            *ErrorTemplates.assoc_added_ctrl(
                                "ProcessSignalGeneratingFunction", association_id, fld
                            )
                        )
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_not_added_ctrl(
                                "ProcessSignalGeneratingFunction", association_id
                            ),
                            exception=e,
                        )


class SignalOffPageConnectorParser(ParserModule):
    """Parser for SignalOffPageConnector elements in the DEXPI model.

    Parses SignalOffPageConnector elements into an instance of the SignalOffPageConnector class.
    Collects all associations and generic attributes in compositional pass, and returns created
    instance of SignalOffPageConnector. In the reference pass, it establishes associations of type
    "is location of" as the source attribute and "is referenced by" as the target attribute.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the SignalOffPageConnector to be parsed.
    reference_parsers : list[OffPageConnectorReferenceParser]
        A list of parsers for the off-page connector references related to the
        SignalOffPageConnector
    association_parsers : list[AssociationParser]
        A list of parsers for the associations related to the SignalOffPageConnector.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the SignalOffPageConnector.
    signal_off_page_connector_id : str | None
        The ID of the SignalOffPageConnector being parsed. Set during compositional pass.
    obj : instrumentation.SignalOffPageConnector | None
        The SignalOffPageConnector object being constructed. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        reference_parsers: list[OffPageConnectorReferenceParser],
        association_parsers: list[AssociationParser],
    ) -> None:
        """Initialize the SignalOffPageConnectorParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the SignalOffPageConnector to be parsed.
        reference_parsers : list[OffPageConnectorReferenceParser]
            A list of parsers for the off-page connector references related to the
            SignalOffPageConnector.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations related to the SignalOffPageConnector.
        """
        super().__init__(context, element)
        self.signal_off_page_connector_id = None
        self.obj = None

        # Set and register off-page connector reference parsers
        self.reference_parsers = reference_parsers
        self.register_submodule_list(reference_parsers)

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> instrumentation.SignalOffPageConnector | None:
        """Parse the SignalOffPageConnector in the compositional pass.

        Composes all associations and references, and creates an instance of the
        SignalOffPageConnector class.

        Returns
        -------
        instrumentation.SignalOffPageConnector | None
            An instance of the SignalOffPageConnector class created from the parsed attributes, or
            None if an error occurred during parsing.
        """
        # Extract ID. If not found, register an error and return None.
        self.signal_off_page_connector_id = self.element.get("ID")
        if self.signal_off_page_connector_id is None:
            self.register_error(*ErrorTemplates.id_not_found("SignalOffPageConnector"))
            return None

        # Get class name
        class_name = self.element.get("ComponentClass")

        try:
            MyClass = getattr(instrumentation, class_name)
        except AttributeError:
            self.register_error(
                f"Invalid class {class_name} for SignalOffPageConnector. Using "
                f"SignalOffPageConnector instead.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Compose and collect references
        if len(self.reference_parsers) > 1:
            # Log a warning if there are multiple reference parsers
            self.register_error(
                "Multiple PipeOffPageConnectorReference parsers found. Keeping only the first "
                "valid one.",
                level=ErrorLevels.WARNING,
            )

        for reference_parser in self.reference_parsers:
            reference_obj = reference_parser.compositional_pass()
            if reference_obj:
                # If the reference object is valid, break
                break

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        self.obj = MyClass(id=self.signal_off_page_connector_id, connectorReference=reference_obj)

        # Register the object
        self.register_object(self.signal_off_page_connector_id, self.obj)

        return self.obj

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Perform a control pass over the SignalOffPageConnectorParser associations.

        Checks that associations of type "is logical start of" and "is logical end of" to
        InformationFlow objects have been made. Also checks if associations of type
        "is referenced by" to OPC references have been made, and if not, tries to add them in
        control pass."""
        # Call super to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.signal_off_page_connector_id is None or self.obj is None:
            self.register_error(*ErrorTemplates.skip_pass("control", "SignalOffPageConnector"))
            return

        # Otherwise, iterate through all association parsers and check if they are valid.
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log and skip invalid associations
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            assoc_type = association_parser.get_type()
            if assoc_type in ["is logical start of", "is logical end of", "is referenced by"]:
                associated_object = association_parser.get_referenced_item()
                assoc_id = association_parser.get_id()
                if not is_associated_with(self.obj, associated_object):
                    # Log warning and try to add association in control pass
                    self.register_error(
                        *ErrorTemplates.no_assoc_ctrl("SignalOffPageConnector", assoc_id)
                    )
                    try:
                        fld = add_by_inferring_type(self.obj, associated_object)
                        # Log an info error if the association was added in control pass
                        self.register_error(
                            *ErrorTemplates.assoc_added_ctrl(
                                "SignalOffPageConnector", assoc_id, fld
                            )
                        )
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_not_added_ctrl(
                                "SignalOffPageConnector", assoc_id
                            ),
                            exception=e,
                        )
            else:
                # If unexpected association type, log a warning
                self.register_error(
                    *ErrorTemplates.inval_assoc_type("SignalOffPageConnector", assoc_type)
                )

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Draw nested reference texts under the signal connector that owns the reference."""
        if self.obj is None:
            return None
        groups = [
            parser.drawing_pass()
            for parser in self.reference_parsers
            if parser.reference_obj is self.obj.connectorReference
        ]
        groups = filter_none(groups)
        return (
            core_diagram.RepresentationGroup(represents=self.obj, groups=groups) if groups else None
        )


class InformationFlowParser(ParserModule):
    """Parser for InformationFlow elements in the DEXPI model.

    Parses InformationFlow elements into an instance of the SignalConveyingFunction class (or
    appropriate subclass retrieved from ComponentClass). Collects all associations and generic
    attributes in compositional pass, and returns created instance of SignalConveyingFunction.
    In the reference pass, it establishes associations of type "has logical start" and
    "has logical end" as source and target attributes.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the InformationFlow to be parsed.
    association_parsers : list[AssociationParser]
        A list of parsers for the associations related to the InformationFlow.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the InformationFlow.
    center_line_parsers : list[CenterLineParser]
        List of center line parsers to be used by the information flow parser.
    information_flow_id : str | None
        The ID of the InformationFlow element being parsed. Set during compositional pass.
    obj : instrumentation.SignalConveyingFunction | None
        The SignalConveyingFunction object being constructed. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        center_line_parsers: list[CenterLineParser],
    ) -> None:
        """Initialize the InformationFlowParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the InformationFlow to be parsed.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations related to the InformationFlow.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the InformationFlow.
        center_line_parsers : list[CenterLineParser]
            List of center line parsers to be used by the information flow parser.
        """
        super().__init__(context, element)
        self.information_flow_id = None
        self.obj = None
        self.information_flow_dwg = None

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register center line parser
        self.center_line_parsers = center_line_parsers
        self.register_submodule_list(center_line_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> instrumentation.SignalConveyingFunction | None:
        """Parse the InformationFlow in the compositional pass.

        Composes all associations and generic attributes, and creates an instance of the
        SignalConveyingFunction. If the ComponentClass attribute is not found in the
        instrumentation module, it uses SignalConveyingFunction as a fallback and adds a custom
        typeName attribute.

        Returns
        -------
        instrumentation.SignalConveyingFunction | None
            An instance of the SignalConveyingFunction class created from the parsed attributes, or
            None if an error occurred during parsing.
        """
        # Extract ID. If not found, log an error and return None.
        self.information_flow_id = self.element.get("ID")
        if self.information_flow_id is None:
            self.register_error(*ErrorTemplates.id_not_found("InformationFlow"))
            return None

        kwargs = {}

        # Get the component type
        class_name = self.element.get("ComponentClass")

        # If class name not part of instrumentation, treat it as SignalConveyingFunction
        try:
            MyClass = getattr(instrumentation, class_name)
        except AttributeError:
            MyClass = instrumentation.SignalConveyingFunction

            # Log a warning that the class name is invalid
            self.register_error(
                f"Invalid class {class_name} for InformationFlow. Using "
                f"SignalConveyingFunction instead and adding custom typeName attribute.",
                level=ErrorLevels.WARNING,
            )

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(MyClass)
        kwargs.update(generic_attrs)

        # Make component and register it
        self.obj = MyClass(id=self.information_flow_id, **kwargs)

        self.register_object(self.information_flow_id, self.obj)

        return self.obj

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Perform a reference pass over the InformationFlow.

        Establishes associations of type "has logical start" and "has logical end" as the
        source and target attributes of the SignalConveyingFunction, respectively.
        If multiple associations of the same type are found, it logs an error and keeps the first
        one encountered.
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.obj is None or self.information_flow_id is None:
            self.register_error(*ErrorTemplates.skip_pass("reference", "InformationFlow"))
            return

        # Establish associations of type "has logical start" and "has logical end"
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            assoc_type = association_parser.get_type()
            assoc_id = association_parser.get_id()
            if assoc_type == "has logical start":
                if self.obj.source is not None:
                    self.register_error(
                        f"Multiple 'has logical start' associations found for InformationFlow "
                        f"{self.information_flow_id}. Keeping the first one encountered.",
                        level=ErrorLevels.ERROR,
                    )
                else:
                    try:
                        self.obj.source = association_parser.get_referenced_item()
                    except (ValidationError, TypeError) as e:
                        logger.debug(
                            "Error setting source for InformationFlow %s", assoc_id, exc_info=True
                        )
                        self.register_error(
                            *ErrorTemplates.assoc_adding_error("InformationFlow", assoc_id),
                            exception=e,
                        )

            elif assoc_type == "has logical end":
                if self.obj.target is not None:
                    self.register_error(
                        f"Multiple 'has logical end' associations found for InformationFlow "
                        f"{self.information_flow_id}. Keeping the first one encountered.",
                        level=ErrorLevels.ERROR,
                    )
                else:
                    try:
                        self.obj.target = association_parser.get_referenced_item()
                    except (ValidationError, TypeError) as e:
                        logger.debug(
                            "Error setting target for InformationFlow %s", assoc_id, exc_info=True
                        )
                        self.register_error(
                            *ErrorTemplates.assoc_adding_error("InformationFlow", assoc_id),
                            exception=e,
                        )

            else:
                self.register_error(*ErrorTemplates.inval_assoc_type("InformationFlow", assoc_type))

    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Parse the InformationFlow in the drawing pass.

         Composes the center line and adds it to a RepresentationGroup.

         Returns
         -------
        core_diagram.RepresentationGroup | None
             An instance of the RepresentationGroup class containing the center line, or None if an
             error occurred during parsing.
        """
        if len(self.center_line_parsers) > 1:
            self.register_error(
                f"Found {len(self.center_line_parsers)} CenterLine elements for InformationFlow, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.center_line_parsers) == 0:
            return None

        center_line_parser = self.center_line_parsers[0]

        # Skip pass if the reference object or ID is not available due to previous error
        if self.obj is None or self.information_flow_id is None:
            self.register_error(*ErrorTemplates.skip_pass("drawing", "InformationFlow"))
            return None

        node_positions = []

        # Compose center line
        connector_line_static = center_line_parser.drawing_pass()
        self.information_flow_dwg = core_diagram.RepresentationGroup(
            represents=self.obj,
            groups=[connector_line_static],
            nodePositions=node_positions,
        )

        return self.information_flow_dwg

    def drawing_reference_pass(self) -> None:
        """Bind the drawn signal line to the node positions its Connection names.

        A file with no ``<Drawing>`` has no drawing to bind: ``PlantModelParser.drawing_pass``
        returns before any ``<id>_cp_node_positions`` key is registered, while the loader runs
        this pass unconditionally. Looking the keys up anyway produced "Source node with ID X
        not found in registry" on documents whose topology is perfectly resolved -- a message
        that reads as a connectivity failure and is not one. The absence of
        ``information_flow_dwg`` is exactly the condition, and the pass had nothing to do in
        that case regardless.
        """
        if self.information_flow_dwg is None:
            return

        connection_element = self.element.find("Connection")
        if connection_element is not None:
            from_id = connection_element.get("FromID")
            to_id = connection_element.get("ToID")
            from_node = connection_element.get("FromNode")
            to_node = connection_element.get("ToNode")

            if from_id and to_id and from_node and to_node:
                # Find Source and Target object from ObjectRegistry
                source_object = self.get_object_from_registry(from_id + "_cp_node_positions")
                target_object = self.get_object_from_registry(to_id + "_cp_node_positions")

                if source_object is None:
                    self.register_error(
                        f"Source node with ID {from_id} not found in registry.",
                        level=ErrorLevels.WARNING,
                    )
                if target_object is None:
                    self.register_error(
                        f"Target node with ID {to_id} not found in registry.",
                        level=ErrorLevels.WARNING,
                    )

                if source_object and target_object:
                    # Get values as list and access by index (1-based to 0-based conversion)
                    source_values = list(source_object.values())
                    target_values = list(target_object.values())
                    source_node = source_values[int(from_node) - 1] if source_values else None
                    target_node = target_values[int(to_node) - 1] if target_values else None

                    if (
                        source_node is not None
                        and target_node is not None
                        and self.information_flow_dwg is not None
                    ):
                        # The line *references* the two positions; it does not own them.
                        # Each one is already composed in the drawing of the item it sits
                        # on -- the instrument bubble or the nozzle -- and nodePositions is
                        # a composition attribute, so adding them here put one object in
                        # two groups: the composition tree stopped being a tree and the XML
                        # export wrote the same xsd:ID twice. The piping path has
                        # always bound its endpoints by reference alone; this now matches
                        # it.
                        # Update the connector line's source and target nodes
                        if isinstance(
                            self.information_flow_dwg.groups[0], core_diagram.Static
                        ) and isinstance(
                            self.information_flow_dwg.groups[0].elements[0],
                            core_diagram.ConnectorLine,
                        ):
                            connector_line = self.information_flow_dwg.groups[0].elements[0]
                            connector_line.source = source_node
                            connector_line.target = target_node
                    else:
                        self.register_error(
                            f"Could not find node positions for connection: FromNode={from_node}, ToNode={to_node}",
                            level=ErrorLevels.WARNING,
                        )


class InstrumentationNodeParser(ParserModule):
    """Parser for InstrumentationNode elements in the DEXPI model.

    Parses InstrumentationNode elements into an instance of the InstrumentationNodePosition class.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the InstrumentationNode to be parsed.
    position_parsers : list[PositionParser]
        List of position parsers to be used by the instrumentation node parser.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        position_parsers: list[PositionParser],
    ) -> None:
        """Initialize the InstrumentationNodeParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the InstrumentationNode to be parsed.
        position_parsers : list[PositionParser]
            List of position parsers to be used by the instrumentation node parser.
        """
        super().__init__(context, element)
        self.instrumentation_node_id = None
        self.instrumentation_node_dwg = None

        # Set and register position parser
        self.position_parsers = position_parsers
        self.register_submodule_list(position_parsers)

    def compositional_pass(self) -> None:
        pass

    @redirect_errors_to_registry
    def drawing_pass(self) -> tuple[str, plant_diagram.InstrumentationNodePosition] | None:
        """Parse the InstrumentationNode in the drawing pass.

        Composes the position and creates an instance of the InstrumentationNodePosition class.

        Returns
        -------
        instrumentation.InstrumentationNodePosition | None
            An instance of the InstrumentationNodePosition class created from the parsed
            attributes, or None if an error occurred during parsing.
        """
        if len(self.position_parsers) > 1:
            self.register_error(
                f"Found {len(self.position_parsers)} Position elements for InstrumentationNode, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.position_parsers) == 0:
            return None

        position_parser = self.position_parsers[0]
        if position_parser is not None:
            self.register_submodule(position_parser)

        # Extract ID
        self.instrumentation_node_id = self.element.get("ID")

        # Compose position
        position, _, _ = position_parser.compositional_pass()

        if position is None:
            self.register_error(*ErrorTemplates.skip_pass("drawing", "InstrumentationNode"))
            return None

        # Create the InstrumentationNodePosition object
        self.instrumentation_node_dwg = plant_diagram.InstrumentationNodePosition(position=position)

        return self.instrumentation_node_id, self.instrumentation_node_dwg


class ProcessInstrumentationFunctionParser(ParserModule):
    """Parser for ProcessInstrumentationFunction elements in the DEXPI model.

    Parses ProcessInstrumentationFunction elements into an instance of the
    ProcessInstrumentationFunction class. Parses and creates the object in compositional pass,
    and checks if associations of type "is logical start of" and "is logical end of" were correctly
    established in control pass. No reference pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the ProcessInstrumentationFunction to be parsed.
    actuating_electrical_function_parsers : list[ActuatingElectricalFunctionParser]
        A list of parsers for the actuating electrical functions related to the
        ProcessInstrumentationFunction.
    actuating_function_parsers : list[ActuatingFunctionParser]
        A list of parsers for the actuating functions related to the
        ProcessInstrumentationFunction.
    signal_generating_function_parsers : list[ProcessSignalGeneratingFunctionParser]
        A list of parsers for the process signal generating functions related to the
        ProcessInstrumentationFunction.
    signal_opc_parsers : list[SignalOffPageConnectorParser]
        A list of parsers for the signal off-page connectors related to the
        ProcessInstrumentationFunction.
    information_flow_parsers : list[InformationFlowParser]
        A list of parsers for the signal conveying functions related to the
        ProcessInstrumentationFunction.
    association_parsers : list[AssociationParser]
        A list of parsers for the associations related to the ProcessInstrumentationFunction.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the ProcessInstrumentationFunction.
    pif_id : str | None
        The ID of the ProcessInstrumentationFunction being parsed. Set during compositional pass.
    pif_obj : instrumentation.ProcessInstrumentationFunction | None
        The ProcessInstrumentationFunction object being constructed. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        actuating_electrical_function_parsers: list[ActuatingElectricalFunctionParser],
        actuating_function_parsers: list[ActuatingFunctionParser],
        signal_generating_function_parsers: list[ProcessSignalGeneratingFunctionParser],
        signal_opc_parsers: list[SignalOffPageConnectorParser],
        information_flow_parsers: list[InformationFlowParser],
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
        shape_usage_parser: ShapeUsageParser,
        label_parsers: list[LabelParser],
        connection_point_parsers: list[ConnectionPointParser],
    ) -> None:
        """Initialize the ProcessInstrumentationFunctionParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the ProcessInstrumentationFunction to be parsed.
        actuating_electrical_function_parsers : list[ActuatingElectricalFunctionParser]
            A list of parsers for the actuating electrical functions related to the
            ProcessInstrumentationFunction.
        actuating_function_parsers : list[ActuatingFunctionParser]
            A list of parsers for the actuating functions related to the
            ProcessInstrumentationFunction.
        signal_generating_function_parsers : list[ProcessSignalGeneratingFunctionParser]
            A list of parsers for the process signal generating functions related to the
            ProcessInstrumentationFunction.
        signal_opc_parsers : list[SignalOffPageConnectorParser]
            A list of parsers for the signal off-page connectors related to the
            ProcessInstrumentationFunction.
        information_flow_parsers : list[InformationFlowParser]
            A list of parsers for the signal conveying functions related to the
            ProcessInstrumentationFunction.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations related to the ProcessInstrumentationFunction.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the ProcessInstrumentationFunction.
        shape_usage_parser : ShapeUsageParser
            A parser for the shape usage of the ProcessInstrumentationFunction.
        label_parsers : list[LabelParser]
            A list of parsers for the labels related to the ProcessInstrumentationFunction.
        connection_point_parsers : list[ConnectionPointParser]
            A list of parsers for the connection points related to the ProcessInstrumentationFunction.

        """
        super().__init__(context, element)
        self.pif_id = None
        self.pif_obj = None
        self.pif_dwg = None

        # Set and register all submodule parsers
        self.actuating_electrical_function_parsers = actuating_electrical_function_parsers
        self.register_submodule_list(actuating_electrical_function_parsers)

        self.actuating_function_parsers = actuating_function_parsers
        self.register_submodule_list(actuating_function_parsers)

        self.signal_generating_function_parsers = signal_generating_function_parsers
        self.register_submodule_list(signal_generating_function_parsers)

        self.signal_opc_parsers = signal_opc_parsers
        self.register_submodule_list(signal_opc_parsers)

        self.information_flow_parsers = information_flow_parsers
        self.register_submodule_list(information_flow_parsers)

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Set and register shape usage parser
        self.shape_usage_parser = shape_usage_parser
        self.register_submodule(shape_usage_parser)

        # Set and register label parsers
        self.label_parsers = label_parsers
        self.register_submodule_list(label_parsers)

        # Set and register connection point parsers
        self.connection_point_parsers = connection_point_parsers
        self.register_submodule_list(connection_point_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> instrumentation.ProcessInstrumentationFunction | None:
        """Parse the ProcessInstrumentationFunction in the compositional pass.

        Composes all associations, actuating electrical functions, actuating functions,
        process signal generating functions, signal off-page connectors, signal conveying functions,
        and generic attributes, and creates an instance of the ProcessInstrumentationFunction class.

        Returns
        -------
        instrumentation.ProcessInstrumentationFunction | None
            An instance of the ProcessInstrumentationFunction class created from the parsed
            attributes, or None if an error occurred during parsing.
        """
        # Extract ID. If not found, register an error and return None.
        self.pif_id = self.element.get("ID")
        if self.pif_id is None:
            self.register_error(*ErrorTemplates.id_not_found("ProcessInstrumentationFunction"))
            return None

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose actuating electrical functions
        actuating_electrical_functions = []
        for parser in self.actuating_electrical_function_parsers:
            aef = parser.compositional_pass()
            if aef is not None:
                actuating_electrical_functions.append(aef)

        # Compose actuating functions
        actuating_functions = []
        for parser in self.actuating_function_parsers:
            af = parser.compositional_pass()
            if af is not None:
                actuating_functions.append(af)

        # Compose process signal generating functions
        process_signal_generating_functions = []
        for parser in self.signal_generating_function_parsers:
            psgf = parser.compositional_pass()
            if psgf is not None:
                process_signal_generating_functions.append(psgf)

        # Compose signal off-page connectors
        signal_off_page_connectors = []
        for parser in self.signal_opc_parsers:
            sopc = parser.compositional_pass()
            if sopc is not None:
                signal_off_page_connectors.append(sopc)

        # Compose signal conveying functions
        signal_conveying_functions = []
        for parser in self.information_flow_parsers:
            ifp = parser.compositional_pass()
            if ifp is not None:
                signal_conveying_functions.append(ifp)

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(
            instrumentation.ProcessInstrumentationFunction
        )

        self.pif_obj = instrumentation.ProcessInstrumentationFunction(
            id=self.pif_id,
            actuatingElectricalFunctions=filter_none(actuating_electrical_functions),
            actuatingFunctions=filter_none(actuating_functions),
            processSignalGeneratingFunctions=filter_none(process_signal_generating_functions),
            signalConnectors=filter_none(signal_off_page_connectors),
            signalConveyingFunctions=filter_none(signal_conveying_functions),
            **generic_attrs,
        )

        # Register the object
        self.register_object(self.pif_id, self.pif_obj)

        return self.pif_obj

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Perform a control pass over the associations.

        Checks if associations of type "is logical start of" and "is logical end of" to
        InformationFlow objects have been made."""
        # Call super to call control pass on all submodules
        super().control_pass()

        # Skip pass if the reference object or ID is not available due to previous error
        if self.pif_id is None or self.pif_obj is None:
            self.register_error(
                *ErrorTemplates.skip_pass("control", "ProcessInstrumentationFunction")
            )
            return

        # Iterate through all association parsers and check if they are valid.
        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            # Check for associations of type "is logical start of" and "is logical end of"
            assoc_type = association_parser.get_type()
            if assoc_type in ["is logical start of", "is logical end of", "is a part of"]:
                associated_object = association_parser.get_referenced_item()
                assoc_id = association_parser.get_id()
                # Symmetric, as EquipmentParser's control pass already is: the
                # plant-structure link is written on the *other* object, so a
                # one-directional check misses it and brute-forces a second copy.
                if not (
                    is_associated_with(self.pif_obj, associated_object)
                    or is_associated_with(associated_object, self.pif_obj)
                ):
                    # Log warning and try to add association in control pass
                    self.register_error(
                        *ErrorTemplates.no_assoc_ctrl("ProcessInstrumentationFunction", assoc_id)
                    )
                    try:
                        fld = add_by_inferring_type(self.pif_obj, associated_object)
                        # Log an info error if the association was added in control pass
                        self.register_error(
                            *ErrorTemplates.assoc_added_ctrl(
                                "ProcessInstrumentationFunction", assoc_id, fld
                            )
                        )
                    except ValueError as e:
                        # If the association cannot be added, log an error
                        self.register_error(
                            *ErrorTemplates.assoc_not_added_ctrl(
                                "ProcessInstrumentationFunction", assoc_id
                            ),
                            exception=e,
                        )
            else:
                self.register_error(
                    *ErrorTemplates.inval_assoc_type("ProcessInstrumentationFunction", assoc_type)
                )

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.RepresentationGroup | None:
        """Perform a drawing pass to create a graphical representation of the component."""

        # Collect graphical representations from all submodules
        if not (self.pif_obj and self.pif_id):
            self.register_error(
                *ErrorTemplates.skip_pass("drawing", "ProcessInstrumentationFunction")
            )
            return

        # Partial groups and node_positions list for representation group
        groups = []
        node_positions = []

        # Process shape usage
        shape_usage = self.shape_usage_parser.drawing_pass()
        if shape_usage is not None:
            static = core_diagram.Static(elements=[shape_usage])
            groups.append(static)

        # Process labels
        labels = [parser.drawing_pass() for parser in self.label_parsers]
        labels = filter_none(labels)
        groups.extend(labels)

        # Process connection points and collect them in a dictionary
        connection_point_dict = {}
        connection_points = [parser.drawing_pass() for parser in self.connection_point_parsers]
        connection_points = filter_none(connection_points)
        for cp_entries in connection_points:
            connection_point_dict.update(cp_entries)

        # Convert dictionary values to node_positions list
        node_positions.extend(connection_point_dict.values())

        # Process information flow drawings
        information_flow_dwgs = [parser.drawing_pass() for parser in self.information_flow_parsers]
        information_flow_dwgs = filter_none(information_flow_dwgs)
        groups.extend(information_flow_dwgs)

        groups.extend(filter_none([parser.drawing_pass() for parser in self.signal_opc_parsers]))

        self.pif_dwg = core_diagram.RepresentationGroup(
            represents=self.pif_obj, groups=groups, nodePositions=node_positions
        )

        self.register_object(f"{self.pif_id}_dwg", self.pif_dwg)
        self.register_object(f"{self.pif_id}_cp_node_positions", connection_point_dict)

        return self.pif_dwg


class InstrumentationLoopFunctionParser(ParserModule):
    """Parser for InstrumentationLoopFunction elements in the DEXPI model.

    Parses InstrumentationLoopFunction elements into an instance of the InstrumentationLoopFunction
    in the compositional pass. Collects references to ProcessInstrumentationFunction in reference
    pass. No control pass is needed.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the InstrumentationLoopFunction to be parsed.
    association_parsers : list[AssociationParser]
        A list of parsers for the associations related to the InstrumentationLoopFunction.
    generic_attribute_parser : GenericAttributeParser
        A parser for the generic attributes of the InstrumentationLoopFunction.
    ilf_id : str | None
        The ID of the InstrumentationLoopFunction being parsed. Set during compositional pass.
    ilf_obj : instrumentation.InstrumentationLoopFunction | None
        The InstrumentationLoopFunction object being constructed. Set during compositional pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
    ) -> None:
        """Initialize the InstrumentationLoopFunctionParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the InstrumentationLoopFunction to be parsed.
        association_parsers : list[AssociationParser]
            A list of parsers for the associations related to the InstrumentationLoopFunction.
        generic_attribute_parser : GenericAttributeParser
            A parser for the generic attributes of the InstrumentationLoopFunction.
        """
        super().__init__(context, element)
        self.ilf_id = None
        self.ilf_obj = None

        # Set and register association parsers
        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        # Set and register generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser

    @redirect_errors_to_registry
    def compositional_pass(self) -> instrumentation.InstrumentationLoopFunction | None:
        """Parse the InstrumentationLoopFunction in the compositional pass.

        Composes all associations and generic attributes, and creates an instance of the
        InstrumentationLoopFunction class.

        Returns
        -------
        instrumentation.InstrumentationLoopFunction | None
            An instance of the InstrumentationLoopFunction class created from the parsed attributes,
            or None if an error occurred during parsing.
        """
        # Extract ID
        self.ilf_id = self.element.get("ID")
        if self.ilf_id is None:
            self.register_error(*ErrorTemplates.id_not_found("InstrumentationLoopFunction"))
            return None

        # Compose associations
        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        # Compose generic attributes
        generic_attrs = self.generic_attribute_parser.compositional_pass(
            instrumentation.InstrumentationLoopFunction
        )

        # Create the InstrumentationLoopFunction object
        self.ilf_obj = instrumentation.InstrumentationLoopFunction(id=self.ilf_id, **generic_attrs)

        # Register the object
        self.register_object(self.ilf_id, self.ilf_obj)

        return self.ilf_obj

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Perform a reference pass over the InstrumentationLoopFunction.

        Establish connections to the associated process instrumentation functions by parsing the
        associations of type "is a collection including".
        """
        # Call super to call reference pass on all submodules
        super().reference_pass()

        # Skip reference pass if id or object are not available due to previous error in
        # compositional pass.
        if self.ilf_obj is None or self.ilf_id is None:
            self.register_error(
                *ErrorTemplates.skip_pass("reference", "InstrumentationLoopFunction")
            )
            return

        # Iterate through all association parsers and check if they are valid.
        pifs = []
        for association_parser in self.association_parsers:
            association_parser.reference_pass()
            if not association_parser.is_valid():
                # Log error and skip association
                self.register_error(
                    association_parser.get_error_message(),
                    level=ErrorLevels.ERROR,
                )
                continue

            # Check for associations of type "is a collection including"
            assoc_type = association_parser.get_type()
            if assoc_type == "is a collection including":
                associated_pif = association_parser.get_referenced_item()
                if not isinstance(associated_pif, instrumentation.ProcessInstrumentationFunction):
                    self.register_error(
                        f"Association of InstrumentationLoopFunction with  "
                        f"{association_parser.get_id()} is not a ProcessInstrumentationFunction. "
                        f"Skipping association.",
                        level=ErrorLevels.ERROR,
                    )
                    continue
                pifs.append(associated_pif)

            else:
                self.register_error(
                    *ErrorTemplates.inval_assoc_type("InstrumentationLoopFunction", assoc_type)
                )
                continue

        # Set the process instrumentation functions in the InstrumentationLoopFunction object
        self.ilf_obj.processInstrumentationFunctions = pifs


#: Proteus ``ComponentClass`` -> the pyDEXPI plant-structure class it denotes.
#:
#: An explicit table rather than ``getattr``: the Proteus names are not the DEXPI
#: class names, and two of them ("IndustrialComplexIso10209-2012",
#: "PlantSectionIso10209-2012") are not Python identifiers at all. ``PlantSystem``
#: appears in no vendored test case but is one of the eight DEXPI plant-structure
#: classes, so it is mapped rather than left to fail later.
PLANT_STRUCTURE_ITEM_CLASSES: dict[str, type] = {
    "Isa95Enterprise": plantStructure.Enterprise,
    "SiteIsa95": plantStructure.Site,
    "IndustrialComplexIso10209-2012": plantStructure.IndustrialComplex,
    "PlantSectionIso10209-2012": plantStructure.PlantSection,
    "ProcessPlant": plantStructure.ProcessPlant,
    "PlantTrain": plantStructure.PlantTrain,
    "AreaIsa95": plantStructure.PlantArea,
    "PlantSystem": plantStructure.PlantSystem,
}

#: Locator class -> the field the *located* object carries it in.
#:
#: There are exactly three, each supplied by its own mixin, so the field is chosen
#: from the locator's class and target heterogeneity needs no branching at all:
#: a TechnicalItem inherits all three, while IndustrialComplex, ProcessPlant and
#: PlantSection inherit only ``plantArea``.
PLANT_STRUCTURE_LOCATION_FIELDS: tuple[tuple[type, str], ...] = (
    (plantStructure.PlantArea, "plantArea"),
    (plantStructure.PlantSystem, "plantSystem"),
    (plantStructure.PlantTrain, "plantTrain"),
)


def set_parent_structure(child, parent) -> str | None:
    """Point `child` at `parent` through ``parentStructure``. None on success.

    A plain assignment, deliberately, rather than
    :func:`parsing_utils.add_by_inferring_type`. There is nothing to infer -- the
    field is called ``parentStructure`` on every class that has one -- and the
    inferring helper walks ``model_fields`` in declaration order taking the first
    field that does not raise, which is not the same thing as the field that is
    meant. DEXPI already states which parents are legal, through the
    ``*ParentStructure`` marker mixins, and ``validate_assignment=True`` turns a
    plain setattr into exactly that check.

    Returns a human-readable reason when the model cannot hold the link, so the
    caller can report it. ``PlantArea``, ``PlantSystem`` and ``PlantTrain`` have no
    ``parentStructure`` at all: they are the location axis, not the part-of chain.
    """
    if not hasattr(child, "parentStructure"):
        return (
            f"{type(child).__name__} has no parentStructure; it belongs to the location axis, "
            "not the part-of chain"
        )
    if child.parentStructure is parent:
        return None
    try:
        child.parentStructure = parent
    except ValidationError:
        return (
            f"the data model does not permit {type(parent).__name__} as the parentStructure of "
            f"{type(child).__name__}"
        )
    return None


def set_plant_structure_location(thing, locator) -> str | None:
    """Point `thing` at the `locator` it sits in. None on success.

    The field is chosen from the *locator*: a PlantArea lands in ``plantArea``, a
    PlantTrain in ``plantTrain``. ``isinstance`` rather than an exact-type lookup,
    so a future subclass still resolves.
    """
    field = next(
        (name for cls, name in PLANT_STRUCTURE_LOCATION_FIELDS if isinstance(locator, cls)), None
    )
    if field is None:
        return f"{type(locator).__name__} is not a plant-structure location"
    if not hasattr(thing, field):
        return f"{type(thing).__name__} cannot be located in a {type(locator).__name__}"
    if getattr(thing, field) is locator:
        return None
    try:
        setattr(thing, field, locator)
    except ValidationError:
        return (
            f"the data model does not permit {type(locator).__name__} as the {field} of "
            f"{type(thing).__name__}"
        )
    return None


PLANT_STRUCTURE_AXES: dict[str, str] = {
    "is a collection including": "part of",
    "is a part of": "part of",
    "is the location of": "located in",
    "is located in": "located in",
}


def register_link_failure(
    parser: ParserModule, child_id: str, parent_id: str, assoc_type: str, reason: str
) -> None:
    """Report a structural link the data model cannot hold. ERROR, and once.

    Proteus states every structural association twice, once from each end, so a
    broken link is reached twice: from the parent in a reference pass and from
    the child in a control pass. Both ends describe one lost link, and counting
    it twice would misrepresent how much of the document failed to load.

    So the message names the child before the parent whatever direction it was
    read from, and the two association types of an axis collapse to one name --
    making the two sightings textually identical, which is what lets the second
    one be dropped. The level stays ERROR either way: whichever end happens to
    arrive first, a link a verified DEXPI document asserts is being lost, and
    ``ErrorLevels.ERROR`` is defined as exactly that.
    """
    axis = PLANT_STRUCTURE_AXES.get(assoc_type, assoc_type)
    message = f"Cannot link {child_id!r} to {parent_id!r} ({axis}): {reason}."
    if any(entry.message == message for entry in parser.context.error_registry.get_errors()):
        return
    parser.register_error(message, level=ErrorLevels.ERROR)


class PlantStructureItemParser(ParserModule):
    """Parser for a ``<PlantStructureItem>``: one node of the plant hierarchy.

    The hierarchy is not nested in the document. Every item is a sibling under
    ``<PlantModel>`` and the structure lives in ``<Association>`` elements, on two
    independent axes that Proteus writes redundantly in **both** directions:

    ``is a collection including`` / ``is a part of``
        composition -- becomes ``parentStructure`` on the child.
    ``is the location of`` / ``is located in``
        location -- becomes ``plantArea`` / ``plantSystem`` / ``plantTrain`` on the
        thing located.

    **This parser owns both axes**, through the two directions written on the
    PlantStructureItem itself. That is not a preference: ``PipingNetworkSystem``
    elements are built with ``parse_associations=False``, so their structural
    associations are visible from nowhere else, and driving from one side also
    means each logical link is written once and reported once. The two inverse
    types are therefore left alone in the reference pass and only recovered in the
    control pass, for a document that states a link from one side only.

    Nothing here is drawn, so there is no drawing pass.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        association_parsers: list[AssociationParser],
        generic_attribute_parser: GenericAttributeParser,
    ) -> None:
        super().__init__(context, element)
        self.item_id = None
        self.item_obj = None

        self.association_parsers = association_parsers
        self.register_submodule_list(association_parsers)

        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

    @redirect_errors_to_registry
    def compositional_pass(self) -> plantStructure.PlantStructureItem | None:
        """Build the item and register it, so the mirror associations can resolve."""
        self.item_id = self.element.get("ID")
        if self.item_id is None:
            self.register_error(*ErrorTemplates.id_not_found("PlantStructureItem"))
            return None

        class_name = self.element.get("ComponentClass")
        item_class = PLANT_STRUCTURE_ITEM_CLASSES.get(class_name)
        if item_class is None:
            # There is no CustomPlantStructureItem to fall back to, and guessing a
            # neighbouring class would fabricate a hierarchy, so the item is dropped.
            self.register_error(
                f"Unknown ComponentClass {class_name!r} for PlantStructureItem "
                f"{self.item_id!r}. Item skipped.",
                level=ErrorLevels.ERROR,
            )
            return None

        for association_parser in self.association_parsers:
            association_parser.compositional_pass()

        generic_attrs = self.generic_attribute_parser.compositional_pass(item_class)
        self.item_obj = item_class(id=self.item_id, **generic_attrs)
        self.register_object(self.item_id, self.item_obj)
        return self.item_obj

    @redirect_errors_to_registry
    def reference_pass(self) -> None:
        """Wire both axes, from the directions this element states itself."""
        super().reference_pass()

        if self.item_obj is None or self.item_id is None:
            self.register_error(*ErrorTemplates.skip_pass("reference", "PlantStructureItem"))
            return

        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                self.register_error(association_parser.get_error_message(), level=ErrorLevels.ERROR)
                continue

            assoc_type = association_parser.get_type()
            other = association_parser.get_referenced_item()
            if assoc_type == "is a collection including":
                reason = set_parent_structure(other, self.item_obj)
            elif assoc_type == "is the location of":
                reason = set_plant_structure_location(other, self.item_obj)
            elif assoc_type in ("is a part of", "is located in"):
                # The inverse of what this parser writes. Recovered in the control
                # pass if the mirror association turns out to be absent.
                continue
            else:
                self.register_error(
                    *ErrorTemplates.inval_assoc_type("PlantStructureItem", assoc_type)
                )
                continue

            if reason is not None:
                # This element is the parent here, so the *other* id is the child.
                register_link_failure(
                    self,
                    child_id=association_parser.get_id(),
                    parent_id=self.item_id,
                    assoc_type=assoc_type,
                    reason=reason,
                )

    @redirect_errors_to_registry
    def control_pass(self) -> None:
        """Recover a link the document states from one side only.

        Silent in the normal case, where the mirror association already wired it.
        A successful recovery is INFO; a link the model cannot hold goes through
        :func:`register_link_failure`, which reports it at ERROR unless the
        mirror association already reported the same one.
        """
        super().control_pass()

        if self.item_obj is None or self.item_id is None:
            return

        for association_parser in self.association_parsers:
            if not association_parser.is_valid():
                continue
            assoc_type = association_parser.get_type()
            if assoc_type not in ("is a part of", "is located in"):
                continue

            other = association_parser.get_referenced_item()
            if is_associated_with(self.item_obj, other) or is_associated_with(other, self.item_obj):
                continue

            if assoc_type == "is a part of":
                reason = set_parent_structure(self.item_obj, other)
            else:
                reason = set_plant_structure_location(self.item_obj, other)

            if reason is not None:
                # This element is the child here, so the *other* id is the parent.
                register_link_failure(
                    self,
                    child_id=self.item_id,
                    parent_id=association_parser.get_id(),
                    assoc_type=assoc_type,
                    reason=reason,
                )
                continue

            self.register_error(
                f"Association {self.item_id!r} with {association_parser.get_id()!r} "
                f"({assoc_type}) added in the control pass.",
                level=ErrorLevels.INFO,
            )


### DRAWING PARSERS ###
class CoordinateParser(ParserModule):
    """Parser for coordinate information in XML elements.

    This class processes coordinate data from XML elements and provides methods to extract coordinate (X,Y)."""

    def __init__(self, context: ModuleContext, element: etree._Element) -> None:
        """Initialize the PointParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain coordinate information.
        """
        super().__init__(context, element)
        self.coordinate_obj = None

    def compositional_pass(self) -> core_diagram.Point | None:
        """Parse the element to extract x and y values.

        Returns
        -------
        core_diagram.Point | None
            Point object with x and y values from the element or None if invalid
        """

        if self.element is None:
            # Register an error and return None if the element is missing
            self.register_error(
                message="Missing element for PointParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse x and y attributes
        if "X" not in self.element.attrib:
            self.register_error(
                message="Missing X attribute in element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None
        else:
            x = float(self.element.get("X"))
        if "Y" not in self.element.attrib:
            self.register_error(
                message="Missing Y attribute in element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None
        else:
            y = float(self.element.get("Y"))

        self.coordinate_obj = core_diagram.Point(x=x, y=y)

        return self.coordinate_obj


class PresentationParser(ParserModule):
    """Parser for presentation information in XML elements.
    This class processes presentation data from XML elements and provides methods to extract stroke
    and color information."""

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
    ) -> None:
        """Initialize the PresentationParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain presentation information.
        """
        super().__init__(context, element)
        self.presentation_obj = None

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.Stroke | core_diagram.Color | None:
        """Perform a compositional pass over the presentation element.

        This method processes the presentation element to create either a Stroke or Color object.
        If the element contains both color and line properties, it creates a Stroke object.
        If the element only contains color properties, it creates a Color object.
        If the element contains only line properties, it creates a Stroke object with default color.
        If the element is None or contains no relevant attributes, None is returned.

        Returns
        -------
        diagram.Stroke | diagram.Color | None
            The constructed Stroke or Color object representing the presentation information or None if invalid
        """

        # If no element is provided, return None
        if self.element is None:
            self.register_error(
                message="Missing element for PresentationParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Check if color attributes are present in the presentation element
        has_color = all(attr in self.element.attrib for attr in ["R", "G", "B"])
        has_line_properties = (
            "LineWeight" in self.element.attrib and "LineType" in self.element.attrib
        )

        # If no relevant properties found, return None
        if not has_color and not has_line_properties:
            self.register_error(
                message="No color or line properties found in presentation element.",
                level=ErrorLevels.WARNING,
            )
            return None

        # Process color information if available
        color = None
        if has_color:
            # Parse RGB values and convert to integers in range 0-255
            # In some cases, values might be provided as floats in range 0-1
            r_value = float(self.element.get("R"))
            g_value = float(self.element.get("G"))
            b_value = float(self.element.get("B"))

            # Check if values are in 0-1 range and scale if needed
            if max(r_value, g_value, b_value) <= 1.0:
                r = int(r_value * 255)
                g = int(g_value * 255)
                b = int(b_value * 255)
            else:
                r = int(r_value)
                g = int(g_value)
                b = int(b_value)

            # Ensure values are within valid range
            r = max(0, min(255, r))
            g = max(0, min(255, g))
            b = max(0, min(255, b))

            color = core_diagram.Color(r=r, g=g, b=b)

        # Process line properties if available
        if has_line_properties:
            # Default values
            width = 1.0
            dash_style = core_diagram.DashStyle("Solid")

            # Get width if available
            if "LineWeight" in self.element.attrib:
                line_weight_value = self.element.get("LineWeight")

                # Check for empty string
                if line_weight_value == "":
                    self.register_error(
                        message="Empty string LineWeight value. Return Color only.",
                        level=ErrorLevels.WARNING,
                    )
                    self.presentation_obj = color
                    return self.presentation_obj

            # Get line type if available
            if "LineType" in self.element.attrib:
                line_type_value = self.element.get("LineType")

                # Check for empty string
                if line_type_value == "":
                    self.register_error(
                        message="Empty string LineType value. Return Color only.",
                        level=ErrorLevels.WARNING,
                    )
                    self.presentation_obj = color
                    return self.presentation_obj

                else:
                    try:
                        dash_style = bmt.resolve_enum_member(
                            core_diagram.DashStyle, line_type_value
                        )

                    except (ValueError, TypeError, IndexError):
                        self.register_error(
                            message=f"Invalid LineType value '{line_type_value}'. Using 'Solid' as default.",
                            level=ErrorLevels.WARNING,
                        )
                        dash_style = core_diagram.DashStyle.SOLID

            # Use default color (black) if no color is defined
            if color is None:
                color = core_diagram.Color(r=0, g=0, b=0)

            self.presentation_obj = core_diagram.Stroke(
                color=color, dashStyle=dash_style, width=width
            )

            return self.presentation_obj

        self.presentation_obj = color
        return self.presentation_obj


class PositionParser(ParserModule):
    """Parser for position information in XML elements.

    This class processes position data from XML elements and provides methods to extract position,
    rotation, and mirroring information. No reference or control pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the position information to be parsed.
    """

    def __init__(self, context: ModuleContext, element: etree._Element) -> None:
        """Initialize the PositionParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain position information.
        """
        super().__init__(context, element)
        self.position_obj = None

    def compositional_pass(self) -> tuple | None:
        """Parse position information from the element.

        Returns
        -------
        tuple | None
            (position, rotation, is_mirrored) where:
            - position is a Point object representing the location
            - rotation is a float representing the rotation angle in degrees
            - is_mirrored is a boolean indicating if the element is mirrored
            Returns None if no position data is found or if parsing fails
        """

        position_element = self.element
        is_position = position_element.tag == "Position"

        if not is_position:
            self.register_error(
                message="No Position element found. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Initialize with default values
        position = None
        rotation = None
        is_mirrored = False

        # Get location (x, y coordinates)
        location_element = position_element.find("Location")
        if location_element is not None:
            # Check for X attribute
            if "X" not in location_element.attrib:
                self.register_error(
                    message="Missing X attribute in Location element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None
            else:
                x_coord = float(location_element.get("X"))

            # Check for Y attribute
            if "Y" not in location_element.attrib:
                self.register_error(
                    message="Missing Y attribute in Location element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None
            else:
                y_coord = float(location_element.get("Y"))
            position = core_diagram.Point(x=x_coord, y=y_coord)
        else:
            self.register_error(
                message="No Location element found. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Calculate rotation from Axis and Reference vectors
        axis_element = position_element.find("Axis")
        reference_element = position_element.find("Reference")
        if axis_element is not None and reference_element is not None:
            # Get axis vector Z component (we only need this one)
            if "Z" not in axis_element.attrib:
                self.register_error(
                    message="Missing Z attribute in Axis element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None
            else:
                axis_z = float(axis_element.get("Z"))

            # Get reference vector X and Y for angle calculation
            if "X" not in reference_element.attrib:
                self.register_error(
                    message="Missing X attribute in Reference element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None
            else:
                ref_x = float(reference_element.get("X"))
            if "Y" not in reference_element.attrib:
                self.register_error(
                    message="Missing Y attribute in Reference element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None
            else:
                ref_y = float(reference_element.get("Y"))

            # Calculate rotation - assuming Z axis is up and rotation is in XY plane
            if axis_z != 0 and (ref_x != 0 or ref_y != 0):
                # Calculate angle in radians and convert to degrees
                # We subtract from 360 to convert CCW to CW rotation and normalize to 0-360
                rotation = (360 - math.degrees(math.atan2(ref_y, ref_x))) % 360
                # Check for mirroring (if Z component of axis is negative)
                if axis_z < 0:
                    is_mirrored = True

        self.position_obj = position, rotation, is_mirrored

        return self.position_obj


class ScaleParser(ParserModule):
    """Parser for scale information in XML elements.

    This class processes scale data from XML elements and provides methods to extract scale factors
    and detect mirroring. No reference or control pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the scale information to be parsed.
    """

    def __init__(self, context: ModuleContext, element: etree._Element) -> None:
        """Initialize the ScaleParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain scale information.
        """
        super().__init__(context, element)
        self.scale_obj = None

    def compositional_pass(self) -> tuple | None:
        """Parse scale information from the element.

        Returns
        -------
        tuple | None
            (scale_x, scale_y, is_mirrored_scale) where:
            - scale_x is a float representing the x scale factor
            - scale_y is a float representing the y scale factor
            - is_mirrored_scale is a boolean indicating if scale indicates mirroring
            Returns None if no scale data is found or parsing fails
        """

        # Initialize with default values
        scale_x = None
        scale_y = None
        is_mirrored_scale = False

        if self.element is None:
            self.register_error(
                message="No Scale element found. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        if self.element.tag != "Scale":
            self.register_error(
                message="Element is not a Scale element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Check for X attribute
        if "X" not in self.element.attrib:
            self.register_error(
                message="Missing X attribute in Scale element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None
        else:
            scale_x = float(self.element.get("X"))

        # Check for Y attribute
        if "Y" not in self.element.attrib:
            self.register_error(
                message="Missing Y attribute in Scale element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None
        else:
            scale_y = float(self.element.get("Y"))

        # Detect mirroring from negative scale values
        if scale_x < 0 or scale_y < 0:
            is_mirrored_scale = True

            # Use absolute values for scale
            scale_x = abs(scale_x)
            scale_y = abs(scale_y)

        self.scale_obj = scale_x, scale_y, is_mirrored_scale

        return self.scale_obj


### PARSE GRAPHICAL PRIMITIVES ###
class GraphicalPrimitiveParser(ParserModule):
    """Parent parser for graphical primitive information in XML elements.

    Used for unified type hinting.
    """


class PolylineParser(GraphicalPrimitiveParser):
    """Parser for polyline information in XML elements.

    This class processes polyline data from XML elements and provides methods to extract
    polyline properties such as points and stroke information.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        presentation_parsers: list[PresentationParser],
        coordinate_parsers: list[CoordinateParser],
    ) -> None:
        """Initialize the PolylineParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain polyline information.
        presentation_parsers : list[PresentationParser]
            List of presentation parsers to use for parsing presentation (stroke) information.
        coordinate_parsers : list[CoordinateParser]
            List of coordinate parsers to use for parsing coordinate (point) information.
        """
        super().__init__(context, element)
        self.polyline_obj = None

        # Initialize parsers for presentation
        self.presentation_parsers = presentation_parsers
        self.register_submodule_list(presentation_parsers)

        # Initialize parser for coordinates
        self.coordinate_parsers = coordinate_parsers
        self.register_submodule_list(coordinate_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.PolyLine | None:
        """Perform a compositional pass over the polyline element.

        Returns
        -------
        core_diagram.PolyLine | None
            The constructed PolyLine object representing the polyline element or None if invalid
        """

        # If no element is provided, return None
        if self.element is None:
            self.register_error(
                message="Missing element for PolylineParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse presentation data for presentation
        if len(self.presentation_parsers) > 1:
            self.register_error(
                f"Found {len(self.presentation_parsers)} Presentation elements for PolyLine, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.presentation_parsers) == 0:
            return None

        presentation_parser = self.presentation_parsers[0] if self.presentation_parsers else None

        presentation = presentation_parser.compositional_pass()
        if presentation is None:
            self.register_error(
                message="Invalid stroke for PolyLine. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse coordinates into Point objects
        coordinates = []
        for coord_parser in self.coordinate_parsers:
            coordinate = coord_parser.compositional_pass()
            if coordinate is not None:
                coordinates.append(coordinate)

        # If no valid points were found, return None
        if not coordinates:
            self.register_error(
                message="No valid coordinates found for PolyLine. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Create and return the PolyLine object
        self.polyline_obj = core_diagram.PolyLine(points=coordinates, stroke=presentation)
        return self.polyline_obj


class PolygonParser(GraphicalPrimitiveParser):
    """Parser for polygon information in XML elements.

    This class processes polygon data from XML elements and provides methods to extract
    polygon properties such as points, stroke information, and fill style.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        presentation_parsers: list[PresentationParser],
        coordinate_parsers: list[CoordinateParser],
    ) -> None:
        """Initialize the PolygonParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain polygon information.
        presentation_parsers : list[PresentationParser]
            List of presentation parsers to use for parsing presentation (stroke) information.
        coordinate_parsers : list[CoordinateParser]
            List of coordinate parsers to use for parsing coordinate (point) information.
        """
        super().__init__(context, element)
        self.polygon_obj = None

        # Initialize parser for stroke
        if len(presentation_parsers) > 1:
            self.register_error(
                f"Found {len(presentation_parsers)} Presentation elements for Polygon, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        self.presentation_parser = presentation_parsers[0] if presentation_parsers else None
        if self.presentation_parser is not None:
            self.register_submodule(self.presentation_parser)

        # Initialize parser for coordinates
        self.coordinate_parsers = coordinate_parsers
        self.register_submodule_list(coordinate_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.Polygon | None:
        """Perform a compositional pass over the polygon element.

        This method processes the polygon element to create a Polygon object,
        combining points, stroke information, and fill style.

        Returns
        -------
        diagram.Polygon | None
            The constructed Polygon object representing the polygon element or None if invalid
        """

        # If no element is provided, return None
        if self.element is None:
            self.register_error(
                message="Missing element for PolygonParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Get the first Polygon element
        poly_element = self.element.find("Polygon")
        if poly_element is None:
            self.register_error(
                message="No Polygon element found in the provided XML element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse presentation data for stroke
        presentation = self.presentation_parser.compositional_pass()
        if presentation is None:
            self.register_error(
                message="Invalid stroke for Polygon. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse coordinates into Point objects
        coordinates = []
        for coord_parser in self.coordinate_parsers:
            coordinate = coord_parser.compositional_pass()
            if coordinate is not None:
                coordinates.append(coordinate)

        # Parse fill style from the Polygon element
        fill_style = core_diagram.FillStyle.SOLID  # Default fill style
        fill_style_str = poly_element.get("Filled")

        if fill_style_str is not None:
            try:
                fill_style_enum = bmt.resolve_enum_member(core_diagram.FillStyle, fill_style_str)
                fill_style = core_diagram.FillStyle(fill_style_enum)
            except (ValueError, TypeError, IndexError):
                logger.debug(
                    "Invalid Filled attribute '%s'. Using default.",
                    fill_style_str,
                    exc_info=True,
                )
                self.register_error(
                    message=f"Invalid Filled attribute '{fill_style_str}'. Using default.",
                    level=ErrorLevels.WARNING,
                )

        # Create and return the Polygon object
        self.polygon_obj = core_diagram.Polygon(
            points=coordinates, stroke=presentation, fillStyle=fill_style
        )
        return self.polygon_obj


class TextParser(GraphicalPrimitiveParser):
    """Parser for text information in XML elements.

    This class processes text data from XML elements and provides methods to extract text properties
    such as content, font, size, position, rotation, alignment, and color.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        position_parsers: list[PositionParser],
        presentation_parsers: list[PresentationParser],
    ) -> None:
        """Initialize the TextParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain text information.
        position_parsers : list[PositionParser]
            List of position parsers to use for parsing position information.
        presentation_parsers : list[PresentationParser]
            List of presentation parsers to use for parsing presentation (color) information.
        """
        super().__init__(context, element)
        self.text_obj = None

        # Initialize parser for position - using PositionParser for position, rotation, and mirroring
        if len(position_parsers) > 1:
            self.register_error(
                f"Found {len(position_parsers)} Position elements for Text, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        self.position_parser = position_parsers[0] if position_parsers else None
        if self.position_parser is not None:
            self.register_submodule(self.position_parser)

        # Initialize parser for presentation
        if len(presentation_parsers) > 1:
            self.register_error(
                f"Found {len(presentation_parsers)} Presentation elements for Text, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        self.presentation_parser = presentation_parsers[0] if presentation_parsers else None
        if self.presentation_parser is not None:
            self.register_submodule(self.presentation_parser)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.Text | None:
        """Perform a compositional pass over the text element.

        This method processes the text element to create a Text object,
        combining text content, font, size, position, rotation, alignment, and color information.

        Returns
        -------
        core_diagram.Text | None
            The constructed Text object representing the text element or None if invalid
        """

        if self.element is None:
            # Return None if no element is provided
            self.register_error(
                message="Missing element for TextParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        is_text = self.element.tag == "Text"
        if is_text is False:
            self.register_error(
                message="No Text element found in the provided XML element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Extract basic text properties
        if "String" not in self.element.attrib:
            self.register_error(
                message="Missing String attribute in Text element.",
                level=ErrorLevels.ERROR,
            )

            return None

        else:
            text_string = self.element.get("String")

        if "Font" not in self.element.attrib:
            self.register_error(
                message="Missing Font attribute in Text element.",
                level=ErrorLevels.ERROR,
            )

        else:
            font = self.element.get("Font")

        # Use Height for size, with Width as a fallback if available
        if "Height" not in self.element.attrib:
            self.register_error(
                message="Missing Height attribute in Text element. Returning None.",
                level=ErrorLevels.ERROR,
            )

        else:
            try:
                size = float(self.element.get("Height"))
            except (ValueError, TypeError):
                self.register_error(
                    message="Invalid Height attribute in Text element. Returning None.",
                    level=ErrorLevels.ERROR,
                )

        # Parse TextAngle if available
        rotation = None
        if "TextAngle" in self.element.attrib:
            try:
                rotation = float(self.element.get("TextAngle"))
            except (ValueError, TypeError):
                self.register_error(
                    message="Invalid TextAngle attribute in Text element. Returning None.",
                    level=ErrorLevels.ERROR,
                )

        # Parse justification/alignment
        alignment = None  # Default alignment
        justification = self.element.get("Justification")
        if justification is not None:
            try:
                justification_str = bmt.resolve_enum_member(
                    core_diagram.TextAlignment, justification
                )
                alignment = core_diagram.TextAlignment(justification_str)
            except (ValueError, TypeError, IndexError):
                logger.debug(
                    "Invalid Justification attribute '%s'. Using default.",
                    justification,
                    exc_info=True,
                )
                self.register_error(
                    message=f"Invalid Justification attribute '{justification}'. Using default.",
                    level=ErrorLevels.WARNING,
                )

        # Parse position using PositionParser to get position, rotation, and mirroring
        position_data = self.position_parser.compositional_pass()
        if position_data is None:
            self.register_error(
                message="Invalid Position in Text element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        position, position_rotation, _ = position_data

        # Use the TextAngle if available, otherwise fall back to position rotation
        if "TextAngle" not in self.element.attrib:
            rotation = position_rotation

        # Extract color from presentation if available
        presentation_result = self.presentation_parser.compositional_pass()
        if presentation_result is None:
            self.register_error(
                message="Invalid presentation in Text element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Check if the presentation result is a Color or a Stroke
        if isinstance(presentation_result, core_diagram.Color):
            color = presentation_result
        elif isinstance(presentation_result, core_diagram.Stroke):
            color = presentation_result.color
        else:
            self.register_error(
                message="Unknown presentation type in Text element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Create template if format specification is available
        template = None
        format_spec_element = self.element.find("TextStringFormatSpecification")
        if format_spec_element is not None:
            # Create a new TextTemplate object
            template = core_diagram.TextTemplate(fragments=[])

            # Process all ObjectAttributesReference elements
            ref_elements = format_spec_element.findall("ObjectAttributesReference")
            if ref_elements:
                for _ref_element in ref_elements:
                    # Create a TextTemplateFragment for each reference
                    fragment = core_diagram.TextTemplateFragment()
                    template.fragments.append(fragment)

        # Create and return the Text object
        self.text_obj = core_diagram.Text(
            text=text_string,
            font=font,
            size=size,
            position=position,
            rotation=rotation,
            alignment=alignment,
            color=color,
            template=template,
        )

        return self.text_obj


### Graphical Primitives to be continued ###
class ConnectorLineParser(GraphicalPrimitiveParser):
    """Parser for connector line information in XML elements.

    This class processes connector line data from XML elements and provides methods to extract
    connector line properties such as points and stroke information.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        presentation_parsers: list[PresentationParser],
        coordinate_parsers: list[CoordinateParser],
    ) -> None:
        """Initialize the ConnectorLineParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain connector line information.
        presentation_parsers : list[PresentationParser]
            List of presentation parsers to use for parsing presentation (stroke) information.
        coordinate_parsers : list[CoordinateParser]
            List of coordinate parsers to use for parsing coordinate (point) information.
        """
        super().__init__(context, element)
        self.connector_line_obj = None

        # Initialize parsers for stroke
        self.presentation_parsers = presentation_parsers
        self.register_submodule_list(presentation_parsers)

        # Initialize parser for coordinates
        self.coordinate_parsers = coordinate_parsers
        self.register_submodule_list(coordinate_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.ConnectorLine | None:
        """Perform a compositional pass over the connector line element.

         This method processes the connector line element to create a ConnectorLine object,
         combining points and stroke information.

         Returns
         -------
        core_diagram.ConnectorLine | None
             The constructed ConnectorLine object representing the connector line element or None if invalid
        """

        # If no element is provided, return None
        if self.element is None:
            self.register_error(
                message="Missing element for ConnectorLineParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse presentation data for stroke
        if len(self.presentation_parsers) > 1:
            self.register_error(
                f"Found {len(self.presentation_parsers)} Presentation elements for ConnectorLine, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.presentation_parsers) == 0:
            return None

        presentation_parser = self.presentation_parsers[0]
        stroke = presentation_parser.compositional_pass()
        if stroke is None:
            self.register_error(
                message="Invalid stroke for ConnectorLine. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse coordinates into Point objects
        coordinates = []
        for coord_parser in self.coordinate_parsers:
            coordinate = coord_parser.compositional_pass()
            if coordinate is not None:
                coordinates.append(coordinate)

        # If no valid points were found, return None
        if not coordinates:
            self.register_error(
                message="No valid coordinates found for ConnectorLine. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Create and return the ConnectorLine object
        self.connector_line_obj = core_diagram.ConnectorLine(points=coordinates, stroke=stroke)
        return self.connector_line_obj


class EllipseParser(GraphicalPrimitiveParser):
    """Parser for ellipse information in XML elements.

    This class processes ellipse data from XML elements and provides methods to extract
    ellipse properties such as center point, radii, stroke information, and fill style.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        presentation_parsers: list[PresentationParser],
        position_parsers: list[PositionParser],
    ) -> None:
        """Initialize the EllipseParser with the XML element and context.
        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain ellipse information.
        presentation_parsers : list[PresentationParser]
            List of presentation parsers to use for parsing presentation (stroke) information.
        position_parsers : list[PositionParser]
            List of position parsers to use for parsing position information.
        """
        super().__init__(context, element)
        self.ellipse_obj = None

        # Initialize parsers for presentation (stroke)
        self.presentation_parsers = presentation_parsers
        self.register_submodule_list(presentation_parsers)

        # Initialize parsers for position
        self.position_parsers = position_parsers
        self.register_submodule_list(position_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.Ellipse | None:
        """Perform a compositional pass over the ellipse or circle element.

        This method processes the element to create an Ellipse object,
        combining center point, radii, stroke information, and fill style.

        Returns
        -------
        core_diagram.Ellipse | None
            The constructed Ellipse object representing the ellipse or circle element or None if invalid
        """

        # If no element is provided, return None
        if self.element is None:
            self.register_error(
                message="Missing element for EllipseParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Try to find Ellipse or Circle element
        element_tag = self.element.tag
        is_ellipse = element_tag == "Ellipse"
        is_circle = element_tag == "Circle"

        if not (is_ellipse or is_circle):
            self.register_error(
                message="No Ellipse or Circle element found in the provided XML element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse presentation data for stroke
        if len(self.presentation_parsers) > 1:
            self.register_error(
                f"Found {len(self.presentation_parsers)} Presentation elements for Ellipse, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.presentation_parsers) == 0:
            return None

        self.presentation_parser = self.presentation_parsers[0]

        stroke = self.presentation_parser.compositional_pass()
        if stroke is None:
            self.register_error(
                message="Invalid stroke information for Ellipse. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse position data for center and rotation
        if len(self.position_parsers) > 1:
            self.register_error(
                message=f"Found {len(self.position_parsers)} Position elements for Ellipse, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.position_parsers) == 0:
            return None

        self.position_parser = self.position_parsers[0]

        position_data = self.position_parser.compositional_pass()
        if position_data is None:
            self.register_error(
                message="Invalid position information for Ellipse. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse fillStyle with default value
        fill_style = core_diagram.FillStyle.SOLID  # Default fill style
        fill_style_str = self.element.get("Filled")
        if fill_style_str is not None:
            try:
                fill_style_enum = bmt.resolve_enum_member(core_diagram.FillStyle, fill_style_str)
                fill_style = core_diagram.FillStyle(fill_style_enum)
            except (ValueError, TypeError, IndexError):
                logger.debug(
                    "Invalid Filled attribute '%s'. Using default.",
                    fill_style_str,
                    exc_info=True,
                )
                self.register_error(
                    message=f"Invalid Filled attribute '{fill_style_str}'. Using default.",
                    level=ErrorLevels.WARNING,
                )

        position, rotation, _ = position_data
        # If position is None, return None
        if position is None:
            self.register_error(
                message="Invalid position for Ellipse. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        if is_ellipse:
            # Parse primary axis and secondary axis
            if "PrimaryAxis" not in self.element.attrib:
                self.register_error(
                    message="Missing PrimaryAxis attribute in Ellipse element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None

            try:
                primary_axis = float(self.element.get("PrimaryAxis"))
            except (TypeError, ValueError):
                self.register_error(
                    message="Invalid PrimaryAxis attribute in Ellipse element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None

            if "SecondaryAxis" not in self.element.attrib:
                self.register_error(
                    message="Missing SecondaryAxis attribute in Ellipse element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None

            try:
                secondary_axis = float(self.element.get("SecondaryAxis"))
            except (TypeError, ValueError):
                self.register_error(
                    message="Invalid SecondaryAxis attribute in Ellipse element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None

            # Compose and return the Ellipse object. Proteus PrimaryAxis/SecondaryAxis are
            # the FULL axis lengths (a Circle gives the half-measure Radius instead), while
            # the pydexpi Ellipse stores semi-axes, so halve them here.
            self.ellipse_obj = core_diagram.Ellipse(
                center=position,
                fillStyle=fill_style,
                horizontalSemiAxis=primary_axis / 2,
                verticalSemiAxis=secondary_axis / 2,
                rotation=rotation,
                stroke=stroke,
            )
            return self.ellipse_obj

        else:  # Circle element
            # Parse radius
            if "Radius" not in self.element.attrib:
                self.register_error(
                    message="Missing Radius attribute in Circle element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None
            try:
                radius = float(self.element.get("Radius"))
            except (TypeError, ValueError):
                self.register_error(
                    message="Invalid Radius attribute in Circle element. Returning None.",
                    level=ErrorLevels.ERROR,
                )
                return None

            # Compose and return the Ellipse object as a circle (equal axes)
            self.ellipse_obj = core_diagram.Ellipse(
                center=position,
                fillStyle=fill_style,
                horizontalSemiAxis=radius,
                verticalSemiAxis=radius,
                rotation=rotation,
                stroke=stroke,
            )
            return self.ellipse_obj


class EllipseArcParser(GraphicalPrimitiveParser):
    """Parser for ellipse arc information in XML elements.

    This class processes ellipse arc data from XML elements and provides methods to extract
    ellipse arc properties such as center point, radii, start and end angles, stroke information, and fill style.
    """

    def __init__(
        self, context: ModuleContext, element: etree._Element, ellipse_parsers: list[EllipseParser]
    ) -> None:
        """Initialize the EllipseArcParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain ellipse arc information.
        ellipse_parsers : list[EllipseParser]
            List of ellipse parsers to use for parsing ellipse information.
        """
        super().__init__(context, element)
        self.ellipse_arc_obj = None

        # Initialize parser for center point
        self.ellipse_parsers = ellipse_parsers
        self.register_submodule_list(ellipse_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.EllipseArc | None:
        """Perform a compositional pass over the ellipse arc element.
        This method processes the ellipse arc element to create an EllipseArc object,
        combining center point, radii, start and end angles, stroke information, and fill style.

        Returns
        -------
        core_diagram.EllipseArc | None
            The constructed EllipseArc object representing the ellipse arc element or None if invalid
        """

        # If no element is provided, return None
        if self.element is None:
            self.register_error(
                message="Missing element for EllipseArcParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Get the first EllipseArc element
        element_tag = self.element.tag
        is_trimmed_curve = element_tag == "TrimmedCurve"

        if not is_trimmed_curve:
            self.register_error(
                message="No TrimmedCurve element found in the provided XML elemen. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Check if StartAngle attribute exists
        if "StartAngle" not in self.element.attrib:
            self.register_error(
                message="Missing StartAngle attribute in TrimmedCurve element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse start angle
        try:
            start_angle = float(self.element.get("StartAngle"))
        except (TypeError, ValueError):
            self.register_error(
                message="Invalid StartAngle attribute in TrimmedCurve element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Check if EndAngle attribute exists
        if "EndAngle" not in self.element.attrib:
            self.register_error(
                message="Missing EndAngle attribute in TrimmedCurve element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse end angle
        try:
            end_angle = float(self.element.get("EndAngle"))
        except (TypeError, ValueError):
            self.register_error(
                message="Invalid EndAngle attribute in TrimmedCurve element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Parse the ellipse using EllipseParser
        if len(self.ellipse_parsers) > 1:
            self.register_error(
                f"Found {len(self.ellipse_parsers)} Ellipse/Circle elements for EllipseArc, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.ellipse_parsers) == 0:
            return None
        ellipse_parser = self.ellipse_parsers[0]

        ellipse = ellipse_parser.compositional_pass()
        if ellipse is None:
            self.register_error(
                message="Failed to parse ellipse for EllipseArc. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Compose and return the EllipseArc object
        self.ellipse_arc_obj = core_diagram.EllipseArc(
            center=ellipse.center,
            endAngle=end_angle,
            horizontalSemiAxis=ellipse.horizontalSemiAxis,
            rotation=ellipse.rotation,
            startAngle=start_angle,
            stroke=ellipse.stroke,
            verticalSemiAxis=ellipse.verticalSemiAxis,
        )
        return self.ellipse_arc_obj


class ShapeParser(ParserModule):
    """Parser for Shape elements in XML.

    This class processes Shape data from XML elements and uses GraphicalPrimitiveParser
    to extract shape information, creating a Shape object.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        generic_attribute_parser: GenericAttributeParser,
        graphical_primitive_parsers: list[GraphicalPrimitiveParser],
    ) -> None:
        """Initialize the ShapeParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that contains shape information.
        generic_attribute_parser : GenericAttributeParser
            The parser to use for parsing generic attributes.
        graphical_primitive_parsers : list[GraphicalPrimitiveParser]
            List of parsers for graphical primitives (PolyLine, Polygon, Ellipse, etc.).
        """
        super().__init__(context, element)
        self.shape_obj = None

        # Initialize parser for generic attributes
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

        # Initialize parsers for graphical primitives
        self.graphical_primitive_parsers = graphical_primitive_parsers
        self.register_submodule_list(graphical_primitive_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.Shape | None:
        """Perform a compositional pass over the shape element.

        This method processes the shape element to create a Shape object,
        combining polylines, polygons, ellipses, and texts.

        Returns
        -------
        core_diagram.Shape | None
            The constructed Shape object representing the shape element or None if invalid
        """

        # Skip pass if element is not available
        if self.element is None:
            self.register_error(
                message="Missing element for ShapeParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Extract ID and name attributes
        id_attr = self.element.get("ID")
        if id_attr is None:
            self.register_error(
                message="Missing ID attribute in Shape element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Extract ComponentName attribute - this will be the shape name
        component_name = self.element.get("ComponentName")
        if component_name is None:
            self.register_error(
                message=f"Missing ComponentName attribute in Shape element with ID {id_attr}. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Extract generic attributes using GenericAttributeParser
        generic_attributes = self.generic_attribute_parser.compositional_pass(core_diagram.Shape)

        # Extract the symbol registration number if available. It is mandatory on the pydexpi
        # Shape class, but some originating systems (e.g. XVisual PlantEngineer) do not emit
        # it, so default to an empty string rather than dropping the whole shape.
        symbol_registration_number = generic_attributes.get("symbolRegistrationNumber")
        if symbol_registration_number is None:
            symbol_registration_number = ""
            self.register_error(
                f"Missing symbolRegistrationNumber for Shape with ID {id_attr}. Defaulting to "
                f"an empty string.",
                level=ErrorLevels.WARNING,
            )

        # Parse all graphical primitives
        primitives = []
        for primitive_parser in self.graphical_primitive_parsers:
            primitive = primitive_parser.compositional_pass()
            if primitive is not None:
                primitives.append(primitive)

        # Check if we have any primitives
        if not primitives:
            self.register_error(
                message=f"No valid primitives found in Shape with ID {id_attr}. Returning None.",
                level=ErrorLevels.WARNING,
            )
            # Continue anyway since a shape can be empty

        # Create and return the Shape object using the determined shape class
        self.shape_obj = core_diagram.Shape(
            id=id_attr,
            name=component_name,
            symbolRegistrationNumber=symbol_registration_number,
            primitives=primitives,
        )
        # Register the shape in the object registry with its ID for reference by other elements
        self.context.object_registry.register_object(id_attr, self.shape_obj)
        return self.shape_obj


class ShapeCatalogueParser(ParserModule):
    """Parser for ShapeCatalogue elements in XML.

    This class processes ShapeCatalogue data from XML elements and uses ShapeParser to extract
    shape information for each Equipment element, creating a ShapeCatalogue object.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        shape_parsers: list[ShapeParser],
    ) -> None:
        """Initialize the ShapeCatalogueParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that contains shape catalogue information.
        shape_parsers : Type[ShapeParser]
            The parser class to use for parsing shape information.
        """
        super().__init__(context, element)
        self.shape_catalogue_obj = None

        # Initialize parser for shapes
        self.shape_parsers = shape_parsers
        self.register_submodule_list(shape_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.ShapeCatalogue | None:
        """Perform a compositional pass over the ShapeCatalogue element.

        This method processes the ShapeCatalogue element to create a ShapeCatalogue object,
        parsing all Equipment elements as shapes.

        Returns
        -------
        ShapeCatalogue | None
            The constructed ShapeCatalogue object representing the shape catalogue or None if invalid
        """

        # Skip pass if element is not available
        if self.element is None:
            self.register_error(
                message="Missing element for ShapeCatalogueParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Extract ID and name attributes
        name = self.element.get("Name")
        if name is None:
            self.register_error(
                message="Missing Name attribute in ShapeCatalogue element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Instantiate empty components
        shapes = []

        for shape_parser in self.shape_parsers:
            shape = shape_parser.compositional_pass()
            if shape is not None:
                shapes.append(shape)

        # Check if we have any shapes
        if not shapes:
            self.register_error(
                message="No valid shapes found in ShapeCatalogue. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Create and return the ShapeCatalogue object
        self.shape_catalogue_obj = core_diagram.ShapeCatalogue(
            name=name,
            shapes=shapes,
        )
        return self.shape_catalogue_obj


class ShapeUsageParser(ParserModule):
    """Parser for ShapeUsage information in XML elements."""

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        position_parsers: list[PositionParser],
        scale_parsers: list[ScaleParser],
    ) -> None:
        """Initialize the ShapeUsageParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that may contain ShapeUsage information.
        position_parsers : list[PositionParser]
            List of position parsers to use for parsing position information.
        scale_parsers : list[ScaleParser]
            List of scale parsers to use for parsing scale information.
        """
        super().__init__(context, element)
        self.shape_usage_obj = None

        # Initialize parsers for position
        self.position_parsers = position_parsers
        self.register_submodule_list(position_parsers)

        # Initialize parser for scale
        self.scale_parsers = scale_parsers
        self.register_submodule_list(scale_parsers)

    def compositional_pass(self) -> None:
        """ShapeUsageParser does not implement compositional_pass, as the drawing object is created in the ShapeCatalogueParser.
        In this parser, the drawing information is stich together with shape usage information (position, rotation, scale, mirroring) in the drawing_pass.

        compositional_pass need to be here as it is an abstract method in the parent class.
        """

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.ShapeUsage | None:
        """Perform a drawing pass over the ShapeUsage element.

        This method processes the ShapeUsage element to create a ShapeUsage object,
        combining position, rotation, scale, and mirroring information.

        Returns
        -------
        core_diagram.ShapeUsage | None
            The constructed ShapeUsage object representing the shape usage information or None if invalid
        """

        # If position is none return None
        if len(self.position_parsers) > 1:
            self.register_error(
                f"Found {len(self.position_parsers)} Position elements for ShapeUsage, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.position_parsers) == 0:
            return None
        position_parser = self.position_parsers[0]

        # Extract scale information. If missing or faulty, use default scale 1,1,false
        if len(self.scale_parsers) > 1:
            self.register_error(
                f"Found {len(self.scale_parsers)} Scale elements for ShapeUsage, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.scale_parsers) == 0:
            scale_data = (1.0, 1.0, False)
        else:
            scale_parser = self.scale_parsers[0]
            scale_data = scale_parser.compositional_pass()
            if scale_data is None:
                self.register_error(
                    message="Invalid scale information for ShapeUsage. Using default scale 1,1,false.",
                    level=ErrorLevels.ERROR,
                )
                scale_data = (1.0, 1.0, False)

        component_shape_name = self.element.get("ComponentName")
        if component_shape_name is None:
            self.register_error("ComponentName not found for Equipment", level=ErrorLevels.WARNING)
            return None

        # Find the appropriate shape in the ShapeCatalogue based on ComponentName
        shape_obj = None

        # Get all ShapeCatalogue objects from the context (from PlantModelParser)
        shape_catalogue_objs = [
            obj
            for obj in self.context.object_registry.objects.values()
            if isinstance(obj, core_diagram.Shape)
        ]

        # Look for a Shape with matching name in any ShapeCatalogue
        for shape in shape_catalogue_objs:
            if shape.name == component_shape_name:
                shape_obj = shape
                break

        if not shape_obj:
            self.register_error(
                f"Shape with name '{component_shape_name}' not found in any ShapeCatalogue",
                level=ErrorLevels.WARNING,
            )

        # Parse position, rotation, and mirroring from position element
        position_data = position_parser.compositional_pass()
        if position_data is None:
            self.register_error(
                message="Invalid position information for ShapeUsage. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        position, rotation, is_mirrored_pos = position_data

        scale_x, scale_y, is_mirrored_scale = scale_data
        # Combine mirroring information from both sources
        is_mirrored = is_mirrored_pos or is_mirrored_scale

        # The instance's declared Extent is the authoritative bounding box of the placed
        # symbol. Some exporters (e.g. XVisual PlantEngineer) write catalogue geometry that
        # is offset from the shape's own origin; placed as-is, it escapes the declared
        # extent and lands off its connection nodes. Reconcile by translation when the
        # placed geometry provably lies outside the extent; consistent files (geometry
        # inside its extent) are untouched.
        position = self._reconcile_position_with_extent(
            position, rotation, (scale_x, scale_y), is_mirrored, shape_obj
        )

        # Create and return the ShapeUsage object
        self.shape_usage_obj = core_diagram.ShapeUsage(
            position=position,
            rotation=rotation,
            scaleX=scale_x,
            scaleY=scale_y,
            isMirrored=is_mirrored,
            shape=shape_obj,
        )

        return self.shape_usage_obj

    def _reconcile_position_with_extent(
        self,
        position: core_diagram.Point,
        rotation: float | None,
        scale: tuple[float, float],
        is_mirrored: bool,
        shape_obj: core_diagram.Shape | None,
    ) -> core_diagram.Point:
        """Translate the usage position so the placed geometry honors the declared Extent.

        Computes the shape's local geometry bounding box, transforms it with the usage's
        mirror/scale/rotation/translation (in the raw Proteus Y-up sheet space this parser
        operates in), and compares it against the instance's declared Extent. If the
        placed geometry escapes the extent by more than a small tolerance, the position is
        translated so the geometry's center coincides with the extent's center, and a
        warning is registered. Consistent data, where the geometry lies within its
        declared extent, is returned unchanged.

        Parameters
        ----------
        position : core_diagram.Point
            The parsed usage position (raw Proteus sheet coordinates).
        rotation : float | None
            The parsed usage rotation (stored negated relative to the mathematical
            convention by PositionParser).
        scale : tuple[float, float]
            The usage's (scaleX, scaleY).
        is_mirrored : bool
            Whether the usage is mirrored (negates the X scale, as in rendering).
        shape_obj : core_diagram.Shape | None
            The resolved catalogue shape.

        Returns
        -------
        core_diagram.Point
            The original or corrected position.
        """
        if shape_obj is None:
            return position

        extent_element = self.element.find("Extent")
        if extent_element is None:
            return position
        min_element = extent_element.find("Min")
        max_element = extent_element.find("Max")
        if min_element is None or max_element is None:
            return position
        try:
            extent_min_x = float(min_element.get("X"))
            extent_min_y = float(min_element.get("Y"))
            extent_max_x = float(max_element.get("X"))
            extent_max_y = float(max_element.get("Y"))
        except (TypeError, ValueError):
            return position

        local_bbox = self._shape_geometry_bbox(shape_obj)
        if local_bbox is None:
            return position

        # Transform the local bbox corners the way rendering will: mirror, scale, rotate,
        # translate. The stored rotation is negated relative to the mathematical
        # convention, so rotate by -rotation here in Y-up space.
        effective_scale_x = -scale[0] if is_mirrored else scale[0]
        effective_scale_y = scale[1]
        angle = math.radians(-(rotation or 0.0))
        cos_a, sin_a = math.cos(angle), math.sin(angle)
        transformed_xs, transformed_ys = [], []
        for corner_x in (local_bbox[0], local_bbox[2]):
            for corner_y in (local_bbox[1], local_bbox[3]):
                x = corner_x * effective_scale_x
                y = corner_y * effective_scale_y
                rotated_x = x * cos_a - y * sin_a
                rotated_y = x * sin_a + y * cos_a
                transformed_xs.append(rotated_x + position.x)
                transformed_ys.append(rotated_y + position.y)

        # How far does the placed geometry escape the declared extent?
        escape = max(
            extent_min_x - min(transformed_xs),
            min(transformed_xs) - extent_max_x,
            extent_min_y - min(transformed_ys),
            min(transformed_ys) - extent_max_y,
            extent_min_x - max(transformed_xs),
            max(transformed_xs) - extent_max_x,
            extent_min_y - max(transformed_ys),
            max(transformed_ys) - extent_max_y,
        )
        tolerance = max(1.0, 0.05 * max(extent_max_x - extent_min_x, extent_max_y - extent_min_y))
        if escape <= tolerance:
            return position

        delta_x = (extent_min_x + extent_max_x) / 2 - (
            min(transformed_xs) + max(transformed_xs)
        ) / 2
        delta_y = (extent_min_y + extent_max_y) / 2 - (
            min(transformed_ys) + max(transformed_ys)
        ) / 2
        self.register_error(
            f"Geometry of shape '{shape_obj.name}' escapes the declared Extent of its usage "
            f"by {escape:.2f} drawing units. Translating the usage by ({delta_x:.2f}, "
            f"{delta_y:.2f}) to honor the extent.",
            level=ErrorLevels.WARNING,
        )
        return core_diagram.Point(x=position.x + delta_x, y=position.y + delta_y)

    @staticmethod
    def _shape_geometry_bbox(
        shape_obj: core_diagram.Shape,
    ) -> tuple[float, float, float, float] | None:
        """Compute the bounding box of a shape's local geometry.

        Covers polylines, polygons, ellipses and ellipse arcs. An arc is measured by its sweep,
        rotated or not (``diagram_toolkit.swept_arc_box``, the measure every extent of a drawn
        symbol uses), and an ellipse by its turned box. Both are taken in the parser's
        own frame, which is Proteus's Y-up one: the angles run counterclockwise there and the
        stored rotation is clockwise (``PositionParser``), so the ellipse is turned by
        ``-rotation``, as the usage's corners are below. Text is skipped, since its extent
        depends on font metrics, and so is a primitive holding a number that is not finite;
        either only loosens the escape check, never triggers a spurious correction.

        Returns
        -------
        tuple[float, float, float, float] | None
            (min_x, min_y, max_x, max_y), or None if the shape has no usable geometry.
        """
        xs: list[float] = []
        ys: list[float] = []
        for primitive in shape_obj.primitives or []:
            if isinstance(primitive, (core_diagram.PolyLine, core_diagram.Polygon)):
                for point in primitive.points or []:
                    if math.isfinite(point.x) and math.isfinite(point.y):
                        xs.append(point.x)
                        ys.append(point.y)
            elif isinstance(primitive, (core_diagram.Ellipse, core_diagram.EllipseArc)):
                if primitive.center is None:
                    continue
                start, sweep = 0.0, 360.0
                if isinstance(primitive, core_diagram.EllipseArc):
                    start = primitive.startAngle
                    sweep = (primitive.endAngle - start) % 360.0 or 360.0
                numbers = (
                    primitive.center.x,
                    primitive.center.y,
                    primitive.horizontalSemiAxis,
                    primitive.verticalSemiAxis,
                    primitive.rotation or 0.0,
                    start,
                    sweep,
                )
                if not all(math.isfinite(number) for number in numbers):
                    continue
                min_x, min_y, max_x, max_y = swept_arc_box(
                    primitive.center.x,
                    primitive.center.y,
                    primitive.horizontalSemiAxis,
                    primitive.verticalSemiAxis,
                    -(primitive.rotation or 0.0),
                    start,
                    sweep,
                )
                xs.extend([min_x, max_x])
                ys.extend([min_y, max_y])
        if not xs:
            return None
        return min(xs), min(ys), max(xs), max(ys)


class SymbolParser(ParserModule):
    """Parser for Symbol elements in XML."""

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        shape_usage_parser: ShapeUsageParser,
    ) -> None:
        """Initialize the SymbolParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that contains symbol information.
        shape_usage_parser : ShapeUsageParser
            The parser class to use for parsing shape usage information.
        """
        super().__init__(context, element)
        self.symbol_id = None
        self.symbol_obj = None

        # Initialize parser for shape usages
        self.shape_usage_parsers = shape_usage_parser
        self.register_submodule(shape_usage_parser)

    def compositional_pass(self) -> None:
        pass

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.Symbol | None:
        """Perform a compositional pass over the symbol element.

        This method processes the symbol element to create a Symbol object,
        combining all shape usages.

        Returns
        -------
        core_diagram.Symbol | None
            The constructed Symbol object representing the symbol element or None if invalid
        """

        # Skip pass if element is not available
        if self.element is None:
            self.register_error(
                message="Missing element for SymbolParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Extract ID and name attributes
        self.symbol_id = self.element.get("ID")
        if self.symbol_id is None:
            self.register_error(
                message="Missing ID attribute in Symbol element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        shape_usage = self.shape_usage_parsers.drawing_pass()

        # Try to get the appropriate class based on the element tag
        element_tag = self.element.tag
        try:
            # Get the class from diagram module using the element tag
            symbol_class = getattr(core_diagram, element_tag)
        except (AttributeError, TypeError):
            # Failsafe: use diagram.Symbol if element_tag is not a valid class in diagram
            symbol_class = core_diagram.Symbol

        # Create the object with the determined class
        self.symbol_obj = symbol_class(id=self.symbol_id, elements=[shape_usage])

        self.register_object(self.symbol_id, self.symbol_obj)

        return self.symbol_obj


class DrawingBorderParser(ParserModule):
    """Parser for DrawingBorder elements in XML."""

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        polyline_parsers: list[PolylineParser],
        text_parsers: list[TextParser],
    ) -> None:
        """Initialize the ShapeParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that contains shape information.
        polyline_parsers : Type[PolylineParser]
            The parser class to use for parsing polyline information.
        text_parsers : Type[TextParser]
            The parser class to use for parsing text information.
        """
        super().__init__(context, element)
        self.border_obj = None

        # Initialize parsers for different shape components
        self.polyline_parsers = polyline_parsers
        self.register_submodule_list(polyline_parsers)

        self.text_parsers = text_parsers
        self.register_submodule_list(text_parsers)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.Shape | None:
        """Perform a compositional pass over the shape element.

        This method processes the shape element to create a Shape object,
        combining polylines, polygons, ellipses, and texts.

        Returns
        -------
        core_diagram.Shape | None
            The constructed Shape object representing the shape element or None if invalid
        """

        # Skip pass if element is not available
        if self.element is None:
            self.register_error(
                message="Missing element for ShapeParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Instantiate empty components
        primitives = []

        # Parse polylines
        for polyline_parser in self.polyline_parsers:
            polyline = polyline_parser.compositional_pass()
            if polyline is not None:
                primitives.append(polyline)

        # Parse texts
        for text_parser in self.text_parsers:
            text = text_parser.compositional_pass()
            if text is not None:
                primitives.append(text)

        # Check if we have any primitives
        if not primitives:
            self.register_error(
                message="No valid primitives found in Border. Returning None.",
                level=ErrorLevels.WARNING,
            )
            # Continue anyway since a border can be empty

        # Create a Border object with the primitives
        self.border_obj = core_diagram.Border(elements=primitives)

        return self.border_obj


class LabelParser(ParserModule):
    """Parser for DrawingLabel elements in XML."""

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        polyline_parsers: list[PolylineParser],
        text_parsers: list[TextParser],
    ) -> None:
        """Initialize the ShapeParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that contains shape information.
        polyline_parsers : Type[PolylineParser]
            The parser class to use for parsing polyline information.
        text_parsers : Type[TextParser]
            The parser class to use for parsing text information.
        """
        super().__init__(context, element)
        self.label_obj = None

        # Initialize parsers for different shape components
        self.polyline_parsers = polyline_parsers
        self.register_submodule_list(polyline_parsers)

        self.text_parsers = text_parsers
        self.register_submodule_list(text_parsers)

    def compositional_pass(self) -> None:
        pass

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.Label | None:
        """Perform a compositional pass over the label element.

        This method processes the label element to create a Label object,
        combining polylines and texts.

        Returns
        -------
        diagram.Label | None
            The constructed Label object representing the label element or None if invalid
        """

        # Skip pass if element is not available
        if self.element is None:
            self.register_error(
                message="Missing element for LabelParser. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Extract ID attribute
        id_attr = self.element.get("ID")
        if id_attr is None:
            self.register_error(
                "Missing ID attribute in Label element. compositional pass skipped.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Determine the appropriate label class from the ID by removing numbering suffix
        # Example: "PipeTagLabelShape-1" -> "PipeTagLabelShape"
        label_class_name = "Label"  # Default class name
        if id_attr:
            # Extract the base class name from the ID
            # "PipeTagLabelShape-1" -> "PipeTagLabelShape"; an id without a hyphen is used
            # as it stands.
            label_class_name = id_attr.split("-")[0] if "-" in id_attr else id_attr

            # Check if this class name exists in diagram module
            if not hasattr(plant_diagram, label_class_name) and label_class_name != "Label":
                self.register_error(
                    message=f"Label class {label_class_name} not found in diagram module for ID {id_attr}, using default Label",
                    level=ErrorLevels.ERROR,
                )
                label_class_name = "Label"

        # Default to Label if we couldn't determine a specific class
        label_class = (
            getattr(plant_diagram, label_class_name)
            if label_class_name != "Label"
            else core_diagram.Label
        )

        # Extract ComponentClass attribute
        component_class = self.element.get("ComponentClass")
        if component_class is None:
            self.register_error(
                f"Missing ComponentClass attribute in Label element with ID {id_attr}. compositional pass skipped.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Instantiate empty components
        primitives = []

        # Parse polylines
        for polyline_parser in self.polyline_parsers:
            polyline = polyline_parser.compositional_pass()
            if polyline is not None:
                primitives.append(polyline)

        # Parse texts
        for text_parser in self.text_parsers:
            text = text_parser.compositional_pass()
            if text is not None:
                primitives.append(text)

        # Check if we have any primitives
        if not primitives:
            self.register_error(
                message=f"No valid primitives found in Label with ID {id_attr}. Returning None.",
                level=ErrorLevels.WARNING,
            )
            # Continue anyway since a label can be empty

        # Create a Label object with the primitives using the determined label class
        self.label_obj = label_class(id=id_attr, elements=primitives)

        # Register the label in the object registry with its ID for reference by other elements
        self.context.object_registry.register_object(id_attr, self.label_obj)
        return self.label_obj


class DiagramParser(ParserModule):
    """Parser for Drawing information in XML elements.

    This class processes Drawing data from XML elements and provides methods to extract
    diagram properties such as name, type, background color, and extents.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        presentation_parsers: list[PresentationParser],
        drawing_border_parsers: list[DrawingBorderParser],
        drawing_label_parsers: list[LabelParser],
    ) -> None:
        """Initialize the DiagramParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that contains drawing information.
        presentation_parsers : list[PresentationParser]
            List of presentation parsers for presentation information (for background color).
        drawing_border_parsers : list[DrawingBorderParser]
            List of drawing border parsers to use.
        drawing_label_parsers : list[LabelParser]
            List of label parsers to use.
        """
        super().__init__(context, element)
        self.diagram_obj = None

        # Initialize parsers for presentation
        self.presentation_parsers = presentation_parsers
        self.register_submodule_list(presentation_parsers)

        # Initialize border parsers
        self.border_parsers = drawing_border_parsers
        self.register_submodule_list(drawing_border_parsers)

        # Initialize label parsers
        self.label_parsers = drawing_label_parsers
        self.register_submodule_list(drawing_label_parsers)

    def compositional_pass(self) -> None:
        """Diagram pass doesnt need compositional pass, as all the object have
        been created in the drawing pass of the conceptualModel of the DEXPI object.


        compositional_pass need to be here as it is an abstract method in the parent class."""

    @redirect_errors_to_registry
    def drawing_pass(self) -> core_diagram.Diagram | None:
        """Parse diagram information from the element.

        Returns
        -------
        core_diagram.Diagram | None
            A Diagram object containing the drawing information, or None if parsing fails.
        """
        # Get the name and type attributes
        name = self.element.get("Name")
        if name is None:
            self.register_error(
                message="Missing Name attribute in Drawing element. Returning None.",
                level=ErrorLevels.ERROR,
            )
            return None

        # Get the background color from the presentation parser
        if len(self.presentation_parsers) > 1:
            self.register_error(
                f"Found {len(self.presentation_parsers)} Presentation elements for Diagram, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.presentation_parsers) == 0:
            return None
        presentation_parser = self.presentation_parsers[0]

        background_color = None
        background_color = presentation_parser.compositional_pass()

        # Parse the extents
        min_x, min_y, max_x, max_y = 0, 0, 0, 0

        extent_element = self.element.find("Extent")
        if extent_element is not None:
            min_element = extent_element.find("Min")
            if min_element is not None:
                if "X" in min_element.attrib:
                    min_x = float(min_element.get("X"))
                if "Y" in min_element.attrib:
                    min_y = float(min_element.get("Y"))

            max_element = extent_element.find("Max")
            if max_element is not None:
                if "X" in max_element.attrib:
                    max_x = float(max_element.get("X"))
                if "Y" in max_element.attrib:
                    max_y = float(max_element.get("Y"))
        else:
            self.register_error(
                message="No Extent element found in Drawing. Using default extents.",
                level=ErrorLevels.WARNING,
            )

        # Create a temporary PyDexpiBaseModel instance to satisfy the 'represents' requirement
        # This will be properly linked to the actual conceptual model when the diagram is used in PlantModelParser
        conceptual_model_placeholder = PlantModel()

        # Create the diagram object
        self.diagram_obj = core_diagram.Diagram(
            backgroundColor=background_color,
            name=name,
            minX=min_x,
            minY=min_y,
            maxX=max_x,
            maxY=max_y,
            represents=conceptual_model_placeholder,  # Add the required 'represents' field
        )

        # Instantiate empty components
        drawing_border = []

        for border_parser in self.border_parsers:
            border = border_parser.compositional_pass()
            if border is not None:
                drawing_border.append(border)
                # Add the border to the diagram's groups list
                self.diagram_obj.groups.append(border)

        # Check if we have any borders
        if not drawing_border:
            self.register_error(
                message="No valid borders found in Drawing. Using empty borders list.",
                level=ErrorLevels.INFO,
            )

        drawing_label = []

        for label_parser in self.label_parsers:
            lbl = label_parser.drawing_pass()
            if lbl is not None:
                drawing_label.append(lbl)
                # Add the label to the diagram's groups list
                self.diagram_obj.groups.append(lbl)

        # Check if we have any labels
        if not drawing_label:
            self.register_error(
                message="No valid labels found in Drawing. Using empty labels list.",
                level=ErrorLevels.INFO,
            )

        return self.diagram_obj


### MODEL PARSERS ###
class MetaDataParser(ParserModule):
    """Parser for MetaData elements in Proteus XML.

    Parses generic attributes to create a MetaData object. No reference or control pass is
    required."""

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        generic_attribute_parser: GenericAttributeParser,
    ) -> None:
        """Initialize the MetaDataParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element that contains MetaData information.
        generic_attribute_parser : GenericAttributeParser
            The parser to use for parsing generic attributes.
        """
        super().__init__(context, element)

        # Make and register the generic attribute parser
        self.generic_attribute_parser = generic_attribute_parser
        self.register_submodule(generic_attribute_parser)

    @redirect_errors_to_registry
    def compositional_pass(self) -> core_diagram.MetaData | None:
        """Parse the generica attributes in a MetaData element to create a MetaData object.

        Returns
        -------
        core_diagram.MetaData | None
            The constructed MetaData object or None if an error occurs in parsing.
        """
        # Get the ID
        id_attr = self.element.get("ID")
        if id_attr is None:
            self.register_error(
                message="Missing ID attribute in MetaData element.",
                level=ErrorLevels.WARNING,
            )
        generic_attributes = self.generic_attribute_parser.compositional_pass(core_diagram.MetaData)
        meta_data_obj = core_diagram.MetaData(id=id_attr, **generic_attributes)

        return meta_data_obj


class PlantModelParser(ParserModule):
    """The DexpiModelParser is a module for parsing DEXPI models from XML elements.

    This class first compiles the model information from the PlantInformation tag and then
    processes the elements of the conceptual model to create a DEXPI model. No reference or control
    pass is required.

    Attributes
    ----------
    context : ModuleContext
        The context containing the ID-, and element stack, error-, and object registry.
    element : etree._Element
        The XML element containing the DEXPI model to be parsed.
    dexpi_model : dexpiModel.DexpiModel | None
        The parsed DEXPI model object, or None if not yet parsed.
    metadata_parser : MetaDataParser
        The parser for the metadata of the DEXPI model.
    equipment_parsers : list[EquipmentParser]
        A list of parsers for the equipment in the DEXPI model.
    piping_network_system_parsers : list[PipingNetworkSystemParser]
        A list of parsers for the piping network systems in the DEXPI model.
    actuating_system_parsers : list[ActuatingSystemParser]
        A list of parsers for the actuating systems in the DEXPI model.
    process_signal_generating_system_parsers : list[ProcessSignalGeneratingSystemParser]
        A list of parsers for the process signal generating systems in the DEXPI model.
    process_instrumentation_function_parsers : list[ProcessInstrumentationFunctionParser]
        A list of parsers for the process instrumentation functions in the DEXPI model.
    shape_catalogue_parsers : list[ShapeCatalogueParser]
        A list of parsers for the shape catalogue in the DEXPI model.
    drawing_parsers : list[DiagramParser]
        List of diagram parsers to use for parsing drawing information.
    """

    def __init__(
        self,
        context: ModuleContext,
        element: etree._Element,
        metadata_parsers: list[MetaDataParser],
        equipment_parsers: list[EquipmentParser],
        piping_network_system_parsers: list[PipingNetworkSystemParser],
        actuating_system_parsers: list[ActuatingSystemParser],
        process_signal_generating_system_parsers: list[ProcessSignalGeneratingSystemParser],
        process_instrumentation_function_parsers: list[ProcessInstrumentationFunctionParser],
        instrumentation_loop_function_parsers: list[InstrumentationLoopFunctionParser],
        plant_structure_item_parsers: list[PlantStructureItemParser],
        shape_catalogue_parsers: list[ShapeCatalogueParser],
        drawing_parsers: list[DiagramParser],
    ) -> None:
        """Initialize the DexpiModelParser with the XML element and context.

        Parameters
        ----------
        context : ModuleContext
            The context containing the ID-, and element stack, error-, and object registry.
        element : etree._Element
            The XML element containing the DEXPI model to be parsed.
        metadata_parser : MetaDataParser
            The parser for the metadata of the DEXPI model.
        equipment_parsers : list[EquipmentParser]
            A list of parsers for the equipment in the DEXPI model.
        piping_network_system_parsers : list[PipingNetworkSystemParser]
            A list of parsers for the piping network systems in the DEXPI model.
        actuating_system_parsers : list[ActuatingSystemParser]
            A list of parsers for the actuating systems in the DEXPI model.
        process_signal_generating_system_parsers : list[ProcessSignalGeneratingSystemParser]
            A list of parsers for the process signal generating systems in the DEXPI model.
        process_instrumentation_function_parsers : list[ProcessInstrumentationFunctionParser]
            A list of parsers for the process instrumentation functions in the DEXPI model.
        instrumentation_loop_function_parsers : list[InstrumentationLoopFunctionParser]
            A list of parsers for the instrumentation loop functions in the DEXPI model.
        plant_structure_item_parsers : list[PlantStructureItemParser]
            A list of parsers for the plant structure items in the DEXPI model.
        shape_catalogue_parsers : list[ShapeCatalogueParser]
            A list of parsers for the shape catalogue in the DEXPI model.
        drawing_parsers : list[DiagramParser]
            List of diagram parsers to use for parsing drawing information.
        """
        super().__init__(context, element)
        self.dexpi_model = None

        # Set and register plant structure item parsers.
        #
        # Registered first, deliberately. These own the plant-structure axes,
        # and several item-level parsers fall back to
        # `add_by_inferring_type`, which fills the first field that is still None.
        # Wiring the hierarchy before those run means the brute-force fallbacks
        # can no longer land in `parentStructure` or `plantArea` by accident.
        self.plant_structure_item_parsers = plant_structure_item_parsers
        self.register_submodule_list(plant_structure_item_parsers)

        # Set and register metadata parsers
        self.metadata_parsers = metadata_parsers
        self.register_submodule_list(metadata_parsers)

        # Set and register equipment parsers
        self.equipment_parsers = equipment_parsers
        self.register_submodule_list(equipment_parsers)

        # Set and register piping network system parsers
        self.pnsystem_parsers = piping_network_system_parsers
        self.register_submodule_list(piping_network_system_parsers)

        # Set and register actuating system parsers
        self.actuating_system_parsers = actuating_system_parsers
        self.register_submodule_list(actuating_system_parsers)

        # Set and register process signal generating system parsers
        self.process_signal_generating_system_parsers = process_signal_generating_system_parsers
        self.register_submodule_list(process_signal_generating_system_parsers)

        # Set and register process instrumentation function parsers
        self.process_instrumentation_function_parsers = process_instrumentation_function_parsers
        self.register_submodule_list(process_instrumentation_function_parsers)

        # Set and register instrumentation loop function parsers
        self.instrumentation_loop_function_parsers = instrumentation_loop_function_parsers
        self.register_submodule_list(instrumentation_loop_function_parsers)

        # Set and register shape catalogue parsers
        self.shape_catalogue_parsers = shape_catalogue_parsers
        self.register_submodule_list(shape_catalogue_parsers)

        # Set and register diagram parsers
        self.drawing_parsers = drawing_parsers
        self.register_submodule_list(drawing_parsers)

    def compositional_pass(self) -> EngineeringModel:
        """Parse the DEXPI model in the compositional pass.

        Extracts all required data from the plant information tag, and composes all main DEXPI
        model elements. Since the DEXPI model requires some fixed fields, it raises critical errors
        if these are missing or incorrect.

        Returns
        -------
        dexpiModel.DexpiModel
            An instance of the DexpiModel class created from the parsed attributes.

        """
        # Log a depreciation warning to disclaim that Proteus is a discontinued format for DEXPI 2.
        # This parser is only kept to map legacy Proteus data to the new format, which can lead
        # to loss of information and potential parsing issues.
        msg = (
            "Deprecation Warning: Proteus format is discontinued for DEXPI 2. Parsing Proteus "
            "models may lead to loss of information, incorrect mapping, or parsing errors."
        )
        self.register_error(msg, level=ErrorLevels.WARNING, proteus_id="_ProteusDeprecationWarning")

        # Retrieve model information from PlantInformation tag
        plant_info = self.element.find("PlantInformation")
        if plant_info is None:
            exception = ValueError(
                "PlantInformation tag is missing in the DEXPI model. "
                "This information is required for a valid DEXPI model."
            )
            self.register_error(
                "PlantInformation tag is missing. Info required for dexpi model.",
                level=ErrorLevels.CRITICAL,
                exception=exception,
            )
            raise exception

        # Check for required fields in PlantInformation
        missing_fields = [
            field
            for field in [
                "Date",
                "Time",
                "OriginatingSystem",
                "OriginatingSystemVendor",
                "OriginatingSystemVersion",
            ]
            if plant_info.get(field) is None
        ]
        if missing_fields:
            # ERROR, not CRITICAL: CRITICAL means the model cannot be loaded at all, and these
            # documents load completely -- two of DEXPI's own verified reference solutions
            # (C02, C03) omit OriginatingSystemVendor/Version and are otherwise intact. A
            # CRITICAL that fires on models that load fine is not something a caller can branch
            # on to reject a document, so it teaches callers to ignore the level. ERROR
            # is what the registry defines for data the source does not carry and the model
            # therefore lacks -- the same level `id_not_found` uses.
            self.register_error(
                f"Missing fields in PlantInformation: {', '.join(missing_fields)}. "
                "DEXPI requires them; the model loads without them, and the EngineeringModel "
                "attributes they feed (exportDateTime, originatingSystemName, "
                "originatingSystemVendorName, originatingSystemVersion) stay unset, so "
                "anything reading the model's provenance reports less than the document "
                "should have carried.",
                level=ErrorLevels.ERROR,
            )

        # Manage fixed fields
        app = plant_info.get("Application")
        if app != "Dexpi":
            self.register_error(
                f"Unexpected Application value: {app}. Expected 'Dexpi'.",
                level=ErrorLevels.WARNING,
            )
        ver = plant_info.get("ApplicationVersion")
        if ver is not None and ver[0:3] != "1.3":
            self.register_error(
                f"Unexpected ApplicationVersion value: {ver}. Expected '1.3'.",
                level=ErrorLevels.WARNING,
            )
        disc = plant_info.get("Discipline")
        if disc != "PID":
            self.register_error(
                f"Unexpected Discipline value: {disc}. Expected 'PID'.",
                level=ErrorLevels.WARNING,
            )
        is3d = plant_info.get("Is3D")
        if is3d is not None and is3d.lower() != "no":
            self.register_error(
                f"Unexpected Is3D value: {is3d}. Expected 'No'.",
                level=ErrorLevels.WARNING,
            )
        sch_ver = plant_info.get("SchemaVersion")
        if sch_ver is not None and sch_ver[0:3] != "4.1":
            self.register_error(
                f"Unexpected SchemaVersion value: {sch_ver}. Expected '4.1'.",
                level=ErrorLevels.WARNING,
            )

        # Create date and time from PlantInformation. Guard against missing or invalid values. Also
        # parses UTC-offset suffix for both date and time
        date_time = None
        try:
            date_str = re.sub(r"[+-]\d{2}:\d{2}$", "", plant_info.get("Date"))
            time_str = plant_info.get("Time")
            date_time = datetime.datetime.fromisoformat(f"{date_str}T{time_str}")
        except (AttributeError, TypeError, ValueError) as exception:
            self.register_error(
                f"Could not parse Date/Time from PlantInformation "
                f"(Date={plant_info.get('Date')!r}, Time={plant_info.get('Time')!r}): "
                f"{exception}. Leaving exportDateTime unset.",
                level=ErrorLevels.WARNING,
                exception=exception,
            )

        the_system = plant_info.get("OriginatingSystem")
        the_vendor = plant_info.get("OriginatingSystemVendor")
        the_version = plant_info.get("OriginatingSystemVersion")

        # Compose metadata
        if len(self.metadata_parsers) > 1:
            self.register_error(
                f"Found {len(self.metadata_parsers)} MetaData elements in PlantModel, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.metadata_parsers) == 0:
            metadata = None
        else:
            self.metadata_parser = self.metadata_parsers[0]
            metadata = self.metadata_parser.compositional_pass()

        # Compose equipment as tagged_plant_items
        tagged_plant_items = [
            equipment_parser.compositional_pass() for equipment_parser in self.equipment_parsers
        ]
        # Sub-equipment its parent could not hold goes to plant level, once
        for equipment_parser in self.equipment_parsers:
            for detached in detached_equipment(equipment_parser):
                if isinstance(detached, pydexpi_classes.TaggedPlantItem):
                    tagged_plant_items.append(detached)
                else:
                    self.register_error(
                        f"Sub-equipment {detached.id!r} ({type(detached).__name__}) could not "
                        f"be attached to its parent and is not a TaggedPlantItem; omitted.",
                        level=ErrorLevels.WARNING,
                        proteus_id=detached.id,
                    )

        # Compose piping network systems
        piping_network_systems = []
        for pns_parser in self.pnsystem_parsers:
            pns = pns_parser.compositional_pass()
            if pns is not None:
                piping_network_systems.append(pns)

        # Compose actuating systems
        actuating_systems = []
        for actuating_system_parser in self.actuating_system_parsers:
            asystem = actuating_system_parser.compositional_pass()
            if asystem is not None:
                actuating_systems.append(asystem)

        # Compose process signal generating systems
        measuring_systems = []
        for (
            process_signal_generating_system_parser
        ) in self.process_signal_generating_system_parsers:
            psgs = process_signal_generating_system_parser.compositional_pass()
            if psgs is not None:
                measuring_systems.append(psgs)

        # Compose process instrumentation functions
        process_instrumentation_functions = []
        for (
            process_instrumentation_function_parser
        ) in self.process_instrumentation_function_parsers:
            pif = process_instrumentation_function_parser.compositional_pass()
            if pif is not None:
                process_instrumentation_functions.append(pif)

        # Compose instrumentation loop functions
        instrumentation_loop_functions = []
        for instrumentation_loop_function_parser in self.instrumentation_loop_function_parsers:
            ilf = instrumentation_loop_function_parser.compositional_pass()
            if ilf is not None:
                instrumentation_loop_functions.append(ilf)

        # Compose plant structure items.
        #
        # Before the PlantModel is built, so the hierarchy is composed into it
        # rather than existing only in the object registry -- an item that
        # is registered but not held here is invisible to
        # get_all_instances_in_model, the graph and both exporters.
        plant_structure_items = []
        for plant_structure_item_parser in self.plant_structure_item_parsers:
            psi = plant_structure_item_parser.compositional_pass()
            if psi is not None:
                plant_structure_items.append(psi)

        # Create the conceptual model
        conceptual_model = PlantModel(
            metaData=metadata,
            taggedPlantItems=filter_none(tagged_plant_items),
            pipingNetworkSystems=filter_none(piping_network_systems),
            actuatingSystems=filter_none(actuating_systems),
            measuringSystems=filter_none(measuring_systems),
            processInstrumentationFunctions=filter_none(process_instrumentation_functions),
            instrumentationLoopFunctions=filter_none(instrumentation_loop_functions),
            plantStructureItems=filter_none(plant_structure_items),
        )

        # Compose shape catalogue if available
        shape_catalogue = []
        for shape_catalogue_parser in self.shape_catalogue_parsers:
            sc = shape_catalogue_parser.compositional_pass()
            if sc is not None:
                shape_catalogue.append(sc)

        # Create the DEXPI model
        dexpi_model = EngineeringModel(
            conceptualModel=conceptual_model,
            exportDateTime=date_time,
            originatingSystemName=the_system,
            originatingSystemVendorName=the_vendor,
            originatingSystemVersion=the_version,
            shapeCatalogues=shape_catalogue,
        )

        self.dexpi_model = dexpi_model

        return dexpi_model

    def drawing_pass(self) -> EngineeringModel | None:
        """Perform the drawing pass for the DEXPI model.

        This method collects all graphical representations from equipment parsers, piping networks,
        and other components, and adds them to the diagram. It first calls the drawing_pass method
        on all submodules, then explicitly collects and organizes the graphical results.

        The graphical representations from various components (equipment, piping, etc.) are
        collected and added to the diagram's groups list if a diagram was created during the
        compositional pass.
        """

        # Get the diagram from the drawing parser
        if self.dexpi_model is None:
            self.register_error(
                "No dexpi model is initiated. Skipping diagram drawing pass.",
                level=ErrorLevels.WARNING,
            )
            return

        # Compose diagram
        if len(self.drawing_parsers) > 1:
            self.register_error(
                f"Found {len(self.drawing_parsers)} Drawing elements in PlantModel, "
                "expected at most 1. Using the first one.",
                level=ErrorLevels.WARNING,
            )
        elif len(self.drawing_parsers) == 0:
            return None
        drawing_parser = self.drawing_parsers[0]

        diagram = drawing_parser.drawing_pass()

        # Check if diagram was not none, then proceed to add graphical elements
        if diagram is not None:
            # Process all equipment graphical representations
            for equipment_parser in self.equipment_parsers:
                equip_graphic = equipment_parser.drawing_pass()
                if equip_graphic is not None:
                    diagram.groups.append(equip_graphic)

            # Process piping network system graphical representations
            for pnsystem_parser in self.pnsystem_parsers:
                pns_graphic = pnsystem_parser.drawing_pass()
                if pns_graphic is not None:
                    diagram.groups.append(pns_graphic)

            # Process actuating system graphical representations
            for actuating_system_parser in self.actuating_system_parsers:
                as_graphic = actuating_system_parser.drawing_pass()
                if as_graphic is not None:
                    diagram.groups.append(as_graphic)

            # Process process instrumentation function graphical representations
            for pif_parser in self.process_instrumentation_function_parsers:
                pif_graphic = pif_parser.drawing_pass()
                if pif_graphic is not None:
                    diagram.groups.append(pif_graphic)

            # Process process signal generating system graphical representations
            for psgs_parser in self.process_signal_generating_system_parsers:
                psgs_graphic = psgs_parser.drawing_pass()
                if psgs_graphic is not None:
                    diagram.groups.append(psgs_graphic)

            # Process instrumentation loop function graphical representations
            # No drawing object for ILF

            # Update DEXPI object in Diagram
            diagram.represents = self.dexpi_model.conceptualModel

            # Assign the diagram to the dexpi_model
            self.dexpi_model.diagram = diagram
