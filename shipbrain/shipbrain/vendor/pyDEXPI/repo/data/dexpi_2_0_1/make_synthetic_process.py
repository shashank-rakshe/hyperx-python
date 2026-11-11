"""Generate the synthetic DEXPI 2.0.1 process fixture, ``synthetic_process.xml`` and ``.json``.

No public DEXPI 2.0.1 *process* model exists: the three in ``data/`` (the CO2 terminal, Tennessee
Eastman and the bpmn2dexpi export) are DEXPI 2.0 documents, which pyDEXPI reads through its
2.0 -> 2.0.1 conversion. This fixture is the native counterpart, built with the generated classes
so that every object it holds is one 2.0.1 defines, and small enough to read in full. It holds one
of each 2.0.1 process construct that the conversion's real inputs do not:

- three process steps (a ``Source``, a ``Distilling`` column and a ``Sink``); the column owns a
  ``ContactingOnTray`` *ProcessStepDetail* with a port of its own, and a ``StrippingDistilling``
  sub-step whose port **delegates** the column's feed port: ``superReference`` /
  ``subReference`` both ways, and the delegate's ``connectorReference`` is its super port's
  stream, which names the super port, never the delegate, as its target;
- two ``Stream`` s between ``MaterialPort`` s and two ``InformationFlow`` s between
  ``InformationPort`` s, the second pair through a ``MeasuringProcessVariable`` activity (in an
  ``InstrumentationSystemActivity``) that owns two ``informationPorts``;
- ports, and the tray, that perform ``Role`` s owned by ``ProcessModel.roles``, each named from the
  specification's list for its performer's class (``Feed``, ``BottomProduct``, ``Input``,
  ``Output``, ...; ``Monitored`` for the tray);
- a ``MaterialTemplate`` whose ``ListOfMaterialComponents`` names three components in an order
  that is not the order of their ids, names or labels;
- a ``MaterialState`` owning two ``phases`` and a ``state``, each a ``MaterialStateType`` with a
  nested ``Composition``: ``massFractions`` as a ``PhysicalQuantityVector`` in
  ``RatioUnit.Percent`` summing to exactly 100 and listed in the template's component order, and
  ``massFlow`` as one ``PhysicalQuantity`` per component, in the same order (the specification's
  "vector of mass flow rates for each component"); each ``MaterialStateType`` carries its total
  in its own ``massFlow``, and the overall state is the sum of the two phases;
- every property the specification declares ``Undefined | X`` with multiplicity 1..1 set, to a
  value or to an explicit ``Undefined`` (:data:`REQUIRED_UNDEFINABLE`): pyDEXPI's classes make
  those optional, so nothing else checks them;
- a diagram whose ``RepresentationGroup`` s place ``PortNodePosition`` s on the ports, and two
  ``ConnectorLine`` s drawn between them (the second with two ordered inner points).

Every object carries an explicit, schema-safe id and nothing depends on the clock or the
environment except the generator banner in the XML header, so a re-run writes the same model.
``tests/test_roundtrip/test_synthetic_process_2_0_1.py`` compares the committed files with
:func:`build_model` and fails when they drift apart.

Run from anywhere::

    python data/dexpi_2_0_1/make_synthetic_process.py
"""

from __future__ import annotations

import datetime
from pathlib import Path
from typing import cast

from pydexpi.attribution import PYDEXPI_SYSTEM_NAME, PYDEXPI_VENDOR_NAME
from pydexpi.loaders.json_serializer import JsonSerializer
from pydexpi.loaders.xml_serializer import DexpiXmlSerializer
from pydexpi.pydexpi_classes.pydexpi_classes import (
    Color,
    Composition,
    CompositionDisplay,
    ConnectorLine,
    ContactingOnTray,
    DashStyle,
    Diagram,
    Distilling,
    EngineeringModel,
    InformationFlow,
    InformationPort,
    InformationVariant,
    InformationVariantType,
    InstrumentationSystemActivity,
    ListOfMaterialComponents,
    MassFlowRateUnit,
    MaterialPort,
    MaterialState,
    MaterialStateType,
    MaterialTemplate,
    MeasuredQuantity,
    MeasuringProcessVariable,
    MultiLanguageString,
    PhysicalQuantity,
    PhysicalQuantityUnit,
    PhysicalQuantityVector,
    Point,
    PolyLine,
    PortDirection,
    PortNodePosition,
    PressureAbsoluteUnit,
    ProcessConnection,
    ProcessModel,
    ProcessStepHierarchyLevel,
    PureMaterialComponent,
    QualifiedValue,
    QuantityProvenance,
    RatioUnit,
    RepresentationGroup,
    Role,
    Scope,
    SingleLanguageString,
    Sink,
    Source,
    Static,
    Stream,
    StrippingDistilling,
    Stroke,
    TemperatureUnit,
    Undefined,
)

#: Where the fixture is written: next to this script.
FIXTURE_DIR = Path(__file__).resolve().parent
#: The file name both documents share; the serializers add ``.xml`` / ``.json``.
STEM = "synthetic_process"

#: The ordered component list, by component id: deliberately not sorted by id, label or
#: identifier, so a serializer, diff or hash that sorts it is caught.
COMPONENT_ORDER = ("Component_Water", "Component_Ethanol", "Component_Methanol")

#: Mass fractions in percent, in :data:`COMPONENT_ORDER`, and mass flows in kg/h, per material
#: state type. Every value is a binary fraction, so each vector sums to exactly 100.0, and the
#: overall state is the flow-weighted mean of the liquid (750 kg/h) and the vapour (250 kg/h). A
#: component's flow is its fraction of the total, so the phases' component flows add up to the
#: overall state's, and every one of them is exact.
MASS_FRACTIONS = {
    "Liquid": (62.5, 27.5, 10.0),
    "Vapour": (17.5, 52.5, 30.0),
    "Overall": (51.25, 33.75, 15.0),
}
MASS_FLOWS = {"Liquid": 750.0, "Vapour": 250.0, "Overall": 1000.0}

#: The roles the ports and the tray perform, each a name the specification lists for its
#: performer's class (MaterialPort: Outlet, Feed, BottomProduct, Inlet; InformationPort: Input,
#: Output; ContactingOnTray: Monitored, which the tray performs itself).
ROLE_NAMES = ("Outlet", "Feed", "BottomProduct", "Inlet", "Monitored", "Input", "Output")

#: Every property the DEXPI 2.0.1 specification declares ``Undefined | X`` with multiplicity 1..1,
#: as (owning class, pyDEXPI field): twelve in the whole specification. pyDEXPI's generated
#: classes type each as ``X | Undefined | None`` and make it optional, so neither construction
#: nor ``validate()`` notices one left out. The fixture sets every one its objects carry,
#: to a value or to an explicit ``Undefined``, and the tests check that it does.
REQUIRED_UNDEFINABLE = (
    ("EngineeringModel", "exportDateTime"),
    ("EngineeringModel", "originatingSystemName"),
    ("EngineeringModel", "originatingSystemVendorName"),
    ("EngineeringModel", "originatingSystemVersion"),
    ("PersistentIdentifier", "context"),
    ("QualifiedValue", "displayText"),
    ("SingleLanguageString", "language"),
    ("SingleLanguageString", "value"),
    ("InstrumentationActivity", "label"),
    ("InstrumentationSystemActivity", "label"),
    ("ProcessConnection", "label"),
    ("ProcessStepDetail", "label"),
)

_BLACK = Color(r=0, g=0, b=0)
_LINE = Stroke(color=_BLACK, dashStyle=DashStyle.SOLID, width=0.5)


def _text(value: str) -> MultiLanguageString:
    """Return *value* as a one-language (English) ``MultiLanguageString``."""
    return MultiLanguageString(
        singleLanguageStrings=[SingleLanguageString(language="en", value=value)]
    )


def _quantity(
    id_: str,
    value: float,
    unit: PhysicalQuantityUnit,
    *,
    scope: Scope | None = None,
    provenance: QuantityProvenance | None = None,
    display_text: str | None = None,
) -> QualifiedValue:
    """Return a ``QualifiedValue`` holding one scalar ``PhysicalQuantity``.

    ``DisplayText`` is 1..1 in the specification (:data:`REQUIRED_UNDEFINABLE`), so it is an
    explicit ``Undefined`` unless *display_text* is given.
    """
    return QualifiedValue(
        id=id_,
        value=PhysicalQuantity(value=value, unit=unit),
        scope=scope,
        provenance=provenance,
        displayText=Undefined() if display_text is None else display_text,
    )


def _box(id_: str, x0: float, y0: float, x1: float, y1: float) -> Static:
    """Return a ``Static`` group drawing the closed rectangle (x0, y0)-(x1, y1), Y-down."""
    corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)]
    return Static(
        id=f"{id_}_Static",
        elements=[
            PolyLine(
                id=f"{id_}_Outline",
                points=[Point(x=x, y=y) for x, y in corners],
                stroke=_LINE,
            )
        ],
    )


def _shell[ConnectionT: ProcessConnection](cls: type[ConnectionT], id_: str) -> ConnectionT:
    """Return an empty connection, to be completed by :func:`_complete`.

    DEXPI makes ``Port.connectorReference`` and ``ProcessConnection.source`` / ``.target``
    required references to each other, so no order builds both validated (AGENTS.md, "Process
    models always contain a required-reference cycle"). The connection is therefore built with
    nothing but its id, the ports are built against it, and :func:`_complete` assigns every other
    field afterwards, each assignment validated (``validate_assignment=True``).
    """
    # The one unvalidated construction; mypy's pydantic plugin wants the required fields here.
    shell = cls.model_construct(id=id_)  # type: ignore[call-arg]
    return cast(ConnectionT, shell)


def _complete(connection: ProcessConnection, **fields: object) -> None:
    """Assign *fields* to a connection from :func:`_shell`, one validated assignment each."""
    for name, value in fields.items():
        setattr(connection, name, value)


def build_model() -> EngineeringModel:
    """Build the synthetic DEXPI 2.0.1 process model.

    Returns
    -------
    EngineeringModel
        A ``ProcessModel`` with its diagram; the same model on every call.
    """
    roles = {name: Role(id=f"Role_{name}", name=name) for name in ROLE_NAMES}

    # -- Materials ---------------------------------------------------------------------------
    water = PureMaterialComponent(
        id="Component_Water",
        identifier="H2O",
        label="Water",
        chEBI_identifier="CHEBI:15377",
        iUPAC_identifier="oxidane",
    )
    ethanol = PureMaterialComponent(
        id="Component_Ethanol",
        identifier="C2H5OH",
        label="Ethanol",
        chEBI_identifier="CHEBI:16236",
        iUPAC_identifier="ethanol",
    )
    methanol = PureMaterialComponent(
        id="Component_Methanol",
        identifier="CH3OH",
        label="Methanol",
        chEBI_identifier="CHEBI:17790",
        iUPAC_identifier="methanol",
    )
    by_id = {component.id: component for component in (water, ethanol, methanol)}
    component_list = ListOfMaterialComponents(
        id="ComponentList_Feed", component=[by_id[id_] for id_ in COMPONENT_ORDER]
    )
    template = MaterialTemplate(
        id="MaterialTemplate_Feed",
        identifier="MT-1",
        label="Water, ethanol, methanol",
        description=_text("Aqueous alcohol feed, in two phases"),
        listOfComponents=component_list,
        numberOfMaterialComponents=len(COMPONENT_ORDER),
        numberOfPhases=2,
        phaseLabel=["Liquid", "Vapour"],
    )

    def state_type(name: str, identifier: str) -> MaterialStateType:
        fractions = MASS_FRACTIONS[name]
        return MaterialStateType(
            id=f"MaterialStateType_{name}",
            identifier=identifier,
            label=f"{name} feed",
            description=_text(f"{name} part of the column feed"),
            # The state type's total; the composition's massFlow is per component.
            massFlow=[
                _quantity(
                    f"MassFlow_{name}",
                    MASS_FLOWS[name],
                    MassFlowRateUnit.KILOGRAMPERHOUR,
                    display_text=f"{MASS_FLOWS[name]:g} kg/h",
                )
            ],
            composition=Composition(
                id=f"Composition_{name}",
                display=CompositionDisplay.PERCENT,
                massFractions=[
                    QualifiedValue(
                        id=f"MassFractions_{name}",
                        value=PhysicalQuantityVector(
                            values=list(fractions), unit=RatioUnit.PERCENT
                        ),
                        displayText=" / ".join(f"{fraction:g} %" for fraction in fractions),
                    )
                ],
                # The specification's "vector of mass flow rates for each component": one
                # quantity per component, in the template's order.
                massFlow=[
                    _quantity(
                        f"MassFlow_{name}_{component_id.removeprefix('Component_')}",
                        MASS_FLOWS[name] * fraction / 100.0,
                        MassFlowRateUnit.KILOGRAMPERHOUR,
                    )
                    for component_id, fraction in zip(COMPONENT_ORDER, fractions, strict=True)
                ],
            ),
        )

    material_state = MaterialState(
        id="MaterialState_Feed",
        identifier="MS-1",
        label="Column feed",
        description="Two-phase column feed: 75 % liquid, 25 % vapour by mass",
        phases=[state_type("Liquid", "MST-L"), state_type("Vapour", "MST-V")],
        state=state_type("Overall", "MST-O"),
    )

    # -- Connections, completed once their ports exist (see _shell) ---------------------------
    feed_stream = _shell(Stream, "Stream_Feed")
    bottoms_stream = _shell(Stream, "Stream_Bottoms")
    tray_signal = _shell(InformationFlow, "InformationFlow_TrayPressure")
    feed_signal = _shell(InformationFlow, "InformationFlow_FeedSignal")

    # -- Ports ---------------------------------------------------------------------------------
    source_outlet = MaterialPort(
        id="Port_SourceOutlet",
        identifier="N1",
        nominalDirection=PortDirection.OUTLET,
        performedRoles=[roles["Outlet"]],
        connectorReference=feed_stream,
    )
    source_signal = InformationPort(
        id="Port_SourceSignal",
        identifier="S1",
        nominalDirection=PortDirection.INLET,
        performedRoles=[roles["Input"]],
        connectorReference=feed_signal,
    )
    column_feed = MaterialPort(
        id="Port_ColumnFeed",
        identifier="N2",
        nominalDirection=PortDirection.INLET,
        performedRoles=[roles["Feed"]],
        materialTemplateReference=template,
        connectorReference=feed_stream,
    )
    # The delegate: same class, direction, roles and template as its super port, and its
    # super port's stream as its connector -- it takes part in that stream without being its end.
    stripping_feed = MaterialPort(
        id="Port_StrippingFeed",
        identifier="N2.1",
        nominalDirection=PortDirection.INLET,
        performedRoles=[roles["Feed"]],
        materialTemplateReference=template,
        connectorReference=feed_stream,
        superReference=column_feed,
    )
    column_feed.subReference = [stripping_feed]
    column_bottoms = MaterialPort(
        id="Port_ColumnBottoms",
        identifier="N3",
        nominalDirection=PortDirection.OUTLET,
        performedRoles=[roles["BottomProduct"]],
        connectorReference=bottoms_stream,
    )
    sink_inlet = MaterialPort(
        id="Port_SinkInlet",
        identifier="N4",
        nominalDirection=PortDirection.INLET,
        performedRoles=[roles["Inlet"]],
        connectorReference=bottoms_stream,
    )
    tray_signal_out = InformationPort(
        id="Port_TraySignal",
        identifier="T1",
        nominalDirection=PortDirection.OUTLET,
        performedRoles=[roles["Output"]],
        connectorReference=tray_signal,
    )
    transmitter_in = InformationPort(
        id="Port_TransmitterIn",
        identifier="PT-101.1",
        nominalDirection=PortDirection.INLET,
        performedRoles=[roles["Input"]],
        connectorReference=tray_signal,
    )
    transmitter_out = InformationPort(
        id="Port_TransmitterOut",
        identifier="PT-101.2",
        nominalDirection=PortDirection.OUTLET,
        performedRoles=[roles["Output"]],
        connectorReference=feed_signal,
    )

    # -- Steps -----------------------------------------------------------------------------------
    tray_pressure = _quantity(
        "TrayPressure",
        1.2,
        PressureAbsoluteUnit.BAR,
        provenance=QuantityProvenance.OBSERVED,
    )
    tray = ContactingOnTray(
        id="Detail_FeedTray",
        identifier="C-101.T12",
        label="Feed tray",
        description=_text("The tray the feed enters on"),
        number=12,
        performedRoles=[roles["Monitored"]],
        pressure=[tray_pressure],
        temperature=[_quantity("TrayTemperature", 82.5, TemperatureUnit.DEGREECELSIUS)],
        ports=[tray_signal_out],
    )
    stripping = StrippingDistilling(
        id="Step_StrippingSection",
        identifier="C-101.S",
        label="Stripping section",
        hierarchyLevel=ProcessStepHierarchyLevel.ELEMENTARYFUNCTION,
        ports=[stripping_feed],
    )
    source = Source(
        id="Step_Feed",
        identifier="FEED",
        label="Feed",
        ports=[source_outlet, source_signal],
    )
    column = Distilling(
        id="Step_Column",
        identifier="C-101",
        label="Distillation column",
        hierarchyLevel=ProcessStepHierarchyLevel.UNITOPERATION,
        ports=[column_feed, column_bottoms],
        processStepDetails=[tray],
        subProcessSteps=[stripping],
    )
    sink = Sink(id="Step_Product", identifier="PRODUCT", label="Bottom product", ports=[sink_inlet])

    transmitter = MeasuringProcessVariable(
        id="Activity_PT101",
        identifier="PT-101",
        label="Feed tray pressure",
        description=_text("Measures the feed tray pressure"),
        measuredVariable=MeasuredQuantity.PRESSURE,
        measuredVariableReference=tray_pressure,
        processStepDetailReference=tray,
        informationPorts=[transmitter_in, transmitter_out],
    )
    instrumentation = InstrumentationSystemActivity(
        id="InstrumentationSystem_PIC101",
        identifier="PIC-101",
        label="Feed tray pressure loop",
        description=_text("Feed tray pressure loop"),
        instrumentationActivities=[transmitter],
    )

    _complete(
        feed_stream,
        identifier="S-1",
        label="Column feed",
        source=source_outlet,
        target=column_feed,
        materialTemplateReference=template,
        materialStateReference=material_state,
        massFlow=[
            _quantity(
                "FeedMassFlow",
                MASS_FLOWS["Overall"],
                MassFlowRateUnit.KILOGRAMPERHOUR,
                scope=Scope.DESIGN,
                provenance=QuantityProvenance.SPECIFIED,
            )
        ],
        temperature=[_quantity("FeedTemperature", 78.0, TemperatureUnit.DEGREECELSIUS)],
        pressure=[_quantity("FeedPressure", 1.5, PressureAbsoluteUnit.BAR)],
    )
    _complete(
        bottoms_stream,
        identifier="S-2",
        label="Bottom product",
        source=column_bottoms,
        target=sink_inlet,
        materialTemplateReference=template,
    )
    for flow, identifier, label, source_port, target_port, reading in (
        (tray_signal, "I-1", "Tray pressure", tray_signal_out, transmitter_in, 1.2),
        (feed_signal, "I-2", "Feed signal", transmitter_out, source_signal, 1.2),
    ):
        _complete(
            flow,
            identifier=identifier,
            label=label,
            source=source_port,
            target=target_port,
            informationValue=InformationVariant(
                id=f"{flow.id}_Value",
                variantType=InformationVariantType.DOUBLE,
                doubleValue=reading,
                booleanValue=False,
                integerValue=0,
                vectorSize=1,
            ),
        )

    process_model = ProcessModel(
        id="ProcessModel_Synthetic",
        roles=list(roles.values()),
        # Not in the template's order: the list is ordered, this container is not.
        materialComponents=[ethanol, methanol, water],
        listsOfMaterialComponents=[component_list],
        materialTemplates=[template],
        materialStates=[material_state],
        processSteps=[source, column, sink],
        processConnections=[feed_stream, bottoms_stream, tray_signal, feed_signal],
        instrumentationSystemActivities=[instrumentation],
    )

    return EngineeringModel(
        id="EngineeringModel_Synthetic",
        conceptualModel=process_model,
        diagram=_diagram(process_model),
        exportDateTime=datetime.datetime(2026, 10, 3, 12, 0, 0),
        originatingSystemName=PYDEXPI_SYSTEM_NAME,
        originatingSystemVendorName=PYDEXPI_VENDOR_NAME,
        # Knowingly unknown: the fixture does not depend on pyDEXPI's version (the XML header
        # names the one that wrote it), and every export keeps an explicit Undefined.
        originatingSystemVersion=Undefined(),
    )


def _diagram(process_model: ProcessModel) -> Diagram:
    """Draw the three steps, their material ports and the two streams between them (Y-down)."""
    steps = {step.id: step for step in process_model.processSteps}
    column = steps["Step_Column"]
    (stripping,) = column.subProcessSteps
    ports = {
        port.id: port
        for step in (*steps.values(), stripping)
        for port in step.ports
        if isinstance(port, MaterialPort)
    }
    streams = {connection.id: connection for connection in process_model.processConnections}

    def at(port_id: str, x: float, y: float) -> PortNodePosition:
        return PortNodePosition(
            id=f"Position_{port_id.removeprefix('Port_')}",
            position=Point(x=x, y=y),
            port=ports[port_id],
        )

    source_outlet = at("Port_SourceOutlet", 100.0, 150.0)
    column_feed = at("Port_ColumnFeed", 180.0, 150.0)
    stripping_feed = at("Port_StrippingFeed", 185.0, 150.0)
    column_bottoms = at("Port_ColumnBottoms", 210.0, 240.0)
    sink_inlet = at("Port_SinkInlet", 320.0, 200.0)

    def line(
        stream_id: str,
        source: PortNodePosition,
        target: PortNodePosition,
        *inner: tuple[float, float],
    ) -> RepresentationGroup:
        return RepresentationGroup(
            id=f"Drawing_{stream_id}",
            represents=streams[stream_id],
            groups=[
                Static(
                    id=f"Drawing_{stream_id}_Static",
                    elements=[
                        ConnectorLine(
                            id=f"Line_{stream_id}",
                            source=source,
                            target=target,
                            innerPoints=[Point(x=x, y=y) for x, y in inner],
                            stroke=_LINE,
                        )
                    ],
                )
            ],
        )

    return Diagram(
        id="Diagram_Synthetic",
        name="Synthetic DEXPI 2.0.1 process",
        represents=process_model,
        minX=0.0,
        minY=0.0,
        maxX=420.0,
        maxY=297.0,
        backgroundColor=Color(r=255, g=255, b=255),
        groups=[
            RepresentationGroup(
                id="Drawing_Step_Feed",
                represents=steps["Step_Feed"],
                groups=[_box("Drawing_Step_Feed", 40.0, 130.0, 100.0, 170.0)],
                nodePositions=[source_outlet],
            ),
            RepresentationGroup(
                id="Drawing_Step_Column",
                represents=column,
                groups=[
                    _box("Drawing_Step_Column", 180.0, 60.0, 240.0, 240.0),
                    RepresentationGroup(
                        id="Drawing_Step_StrippingSection",
                        represents=stripping,
                        groups=[_box("Drawing_Step_StrippingSection", 185.0, 140.0, 235.0, 235.0)],
                        nodePositions=[stripping_feed],
                    ),
                ],
                nodePositions=[column_feed, column_bottoms],
            ),
            RepresentationGroup(
                id="Drawing_Step_Product",
                represents=steps["Step_Product"],
                groups=[_box("Drawing_Step_Product", 300.0, 120.0, 340.0, 200.0)],
                nodePositions=[sink_inlet],
            ),
            line("Stream_Feed", source_outlet, column_feed),
            line("Stream_Bottoms", column_bottoms, sink_inlet, (210.0, 260.0), (320.0, 260.0)),
        ],
    )


def main() -> None:
    """Write ``synthetic_process.xml`` and ``synthetic_process.json`` next to this script."""
    model = build_model()
    DexpiXmlSerializer().save(model, FIXTURE_DIR, STEM)
    JsonSerializer().save(model, FIXTURE_DIR, STEM)


if __name__ == "__main__":
    main()
