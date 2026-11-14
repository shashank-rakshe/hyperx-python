# DEXPI Specification 2.0.1: errata reported to DEXPI

Eight issues for the DEXPI Specification project, <https://gitlab.com/dexpi/Specification>,
filed there on 2026-10-13 as issues #24 to #31 (the table below links each). Each section's heading
is the issue title, and the text below it, down to the next rule, is the issue body as it was
posted. The texts stay here as the record of what was reported and of what pyDEXPI does in the
meantime; when DEXPI resolves one, note the resolution in its row.

The first seven were found while moving pyDEXPI to DEXPI 2.0.1, and the eighth while listing the
process step classes with their descriptions for a language model to choose from. Each body
says what pyDEXPI does in the meantime. Where we deviate from the specification, the table below
gives the id of the declared deviation: an entry of the
`SPEC_DEVIATIONS` table in pyDEXPI-builder, the class generator, which fails the build when the
specification no longer matches what the entry was written against.
The bodies describe each deviation in words, never by an id a DEXPI reader
cannot look up; each footer says that the behaviour described is that of a development version;
and nothing of ours is cited as evidence, which is the specification's own, at its public tag.

| | Erratum | Kind | pyDEXPI meanwhile | Filed |
| --- | --- | --- | --- | --- |
| 1 | `Composition.MassFractions` example is not a vector; `MassFlow` / `MoleFlow` are described as vectors | example, description | follows the bindings | [#24](https://gitlab.com/dexpi/Specification/-/issues/24) |
| 2 | `ListOfMaterialComponents.Component` is not declared ordered | model | deviation `COMPONENT-ORDER` | [#25](https://gitlab.com/dexpi/Specification/-/issues/25) |
| 3 | `Port.ConnectorReference` opposite upper bound of 1, and the other open `TODO check multiplicities` | model | not enforced | [#26](https://gitlab.com/dexpi/Specification/-/issues/26) |
| 4 | `QualifiedValue.Type` is narrower than its bindings | model | deviation `QV-VALUE-UNION` | [#27](https://gitlab.com/dexpi/Specification/-/issues/27) |
| 5 | `Port.SubReference` is a composition; what a delegated port is, with its `ConnectorReference`, is unspecified | model, text | deviation `PORT-SUBREFERENCE`; derives the connection | [#28](https://gitlab.com/dexpi/Specification/-/issues/28) |
| 6 | The 2.0.1 changelog and unit table are incomplete | documentation | none needed | [#29](https://gitlab.com/dexpi/Specification/-/issues/29) |
| 7 | `MeasuredQuantity` has no `Temperature` literal | model | follows the enumeration | [#30](https://gitlab.com/dexpi/Specification/-/issues/30) |
| 8 | `GeneratingDCPower` is described as producing alternating current; `Flaring` names a supertype it does not have; `SupplyingThermalEnergy` is no `SupplyingEnergy` | description, model | follows the specification | [#31](https://gitlab.com/dexpi/Specification/-/issues/31) |

**Verified 2026-10-09 against tag `V2.0.1`** (commit `eef0f0c6e8edfe84582e7a45d109c396bdc544f8`):
every file and line below was read from the public repository at that tag, and every statement
about DEXPI 2.0 from tag `V2.0.0` (commit `260c81c510`, which the annotated tag points at). All
seven still hold in 2.0.1; the eighth was added on 2026-10-11, read from the same two tags. Line
references are to `src/model/Process/Process/Process.py` unless
another file is named, and link to the tag, so they do not move. Two sources are spreadsheets,
which have rows rather than lines:
`src/model/Process/Enumerations/process_enumerations.ods` and
`src/model/Core/PhysicalQuantities/UoM_DEXPI_1.3_SPEC.ods`; their rows are counted in the first
sheet, the header being row 1.

---

## 1. `Composition.MassFractions`: the example value is a `PhysicalQuantity` holding a list, and `MassFlow` / `MoleFlow` are described as vectors but bound to scalars

**Version:** DEXPI Specification 2.0.1, tag `V2.0.1`.

**Where:**
[`Process.py` L36-86](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L36-86),
[`PhysicalQuantities.py` L18-74](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Core/PhysicalQuantities/PhysicalQuantities.py#L18-74).

**What is wrong**

1. `Composition.MassFractions` is bound to `Undefined | PhysicalQuantityVector[RatioUnit]`
   (L39-41), but its `exampleValue` (L44-47) is

   ```python
   Core.QualifiedValue(
       Value=PHYSICAL_QUANTITIES.PhysicalQuantity(
           Value=[19., 81.],
           Unit=PHYSICAL_QUANTITIES.RatioUnit.Percent))
   ```

   a scalar `PhysicalQuantity` whose `Value` is a list. `PhysicalQuantity.Value` is one `Double`
   (`PhysicalQuantities.py` L30-37), and the binding does not admit a `PhysicalQuantity` at all.
   The sibling `MoleFractions` example (L57-60) has the form the binding asks for:
   `PhysicalQuantityVector(Values=[17., 83.], Unit=RatioUnit.Percent)`.
2. `Composition.MassFlow` and `Composition.MoleFlow` are described as "Vector of mass flow rates
   for each component" and "Vector of mole flow rates for each component" (L64, L77), but are
   bound to a scalar, `Undefined | PhysicalQuantity[MassFlowRateUnit]` and
   `PhysicalQuantity[MoleFlowRateUnit]` (L65-67, L78-80), with scalar examples (`270.`, `8.5`;
   L70-73, L83-86). Description and binding cannot both be meant.

**Why it matters** The example is what an implementer copies. A tool that validates values
against the bindings rejects the specification's own example, and one that follows the example
writes a list where the model declares a number. For the flows, an exporter cannot tell whether
one flow per component is a `PhysicalQuantityVector`, like the fractions, or several
`QualifiedValue`s in a property that is not declared ordered.

**What pyDEXPI does meanwhile** It follows the bindings: `massFractions` and `moleFractions`
take a `PhysicalQuantityVector` in a `RatioUnit`, `massFlow` and `moleFlow` a scalar
`PhysicalQuantity`. A value of the other shape is reported by validation as not fitting its
binding; the example's own form, a list in
`PhysicalQuantity.Value`, cannot be built at all. We do not deviate from the model here, since
only an example and two descriptions are affected.

**Proposed fix**

- `MassFractions`: `exampleValue=Core.QualifiedValue(Value=PHYSICAL_QUANTITIES.PhysicalQuantityVector(Values=[19., 81.], Unit=PHYSICAL_QUANTITIES.RatioUnit.Percent))`.
- `MassFlow` / `MoleFlow`: decide which is meant. If one value per component, bind them to
  `PhysicalQuantityVector[MassFlowRateUnit]` / `[MoleFlowRateUnit]` like the fractions; if a total,
  reword the descriptions ("Mass flow rate of the material").

*Found while moving [pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI), an
open-source Python implementation of the DEXPI information model, to DEXPI 2.0.1. That work is
in a development version, not yet in the public repository, which implements DEXPI 1.3: "what
pyDEXPI does" above describes the development version.*

---

## 2. `ListOfMaterialComponents.Component` is not declared ordered, although composition vectors are read by its order

**Version:** DEXPI Specification 2.0.1, tag `V2.0.1`. Unchanged from 2.0.

**Where:**
[`Process.py` L16-26](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L16-26)
and
[L408-424](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L408-424).

**What is wrong** The text makes the order of a `ListOfMaterialComponents` carry meaning:

- its class description (L409-414, emphasis added): "This is an **ordered** list of
  `PureMaterialComponent` and `CustomMaterialComponent` objects. This is used in the
  `MaterialTemplate` to determine the structure of composition vectors";
- `Composition` (L18-22): "The order of items in the array is determined by the list of chemical
  components (`ListOfMaterialComponents`) in the corresponding `MaterialTemplate` object".

But the property that holds the list, `ListOfMaterialComponents.Component` (L418-424), has no
`isOrdered=True`. In the 2.0.1 model that flag is set on eight properties only: seven of
`Core/Diagram/Diagram.py` (`Polygon.Points`, `PolyLine.Points`, `TextTemplate.Fragments`,
`ConnectorLine.InnerPoints`, `RepresentationGroup.Groups`, `RepresentationTypeGroup.Elements`,
`Shape.Primitives`; L1226, L1341, L1425, L1459, L1512, L1574, L2019) and
`PhysicalQuantityVector.Values` (`PhysicalQuantities.py` L73). So the vector's own values are
ordered, and the list that says which component each value belongs to is not.

**Why it matters** An implementation that follows the model may store, compare or serialise the
components in any order, for instance sorted by id for a stable diff. Every fraction vector read
against the list is then silently assigned to other components, with no error anywhere.

**What pyDEXPI does meanwhile** It deviates from the model, deliberately: the generated
`ListOfMaterialComponents.component` is marked ordered, so equality, diff and serialisation keep
its order.

**Proposed fix** `isOrdered=True` on `ListOfMaterialComponents.Component`.

*Found while moving [pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI), an
open-source Python implementation of the DEXPI information model, to DEXPI 2.0.1. That work is
in a development version, not yet in the public repository, which implements DEXPI 1.3: "what
pyDEXPI does" above describes the development version.*

---

## 3. `Port.ConnectorReference`: the opposite upper bound of 1 does not fit a connection between two ports; fourteen `TODO check multiplicities` are open

**Version:** DEXPI Specification 2.0.1, tag `V2.0.1`. Unchanged from 2.0.

**Where:**
[`Process.py` L709-715](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L709-715),
and the lines listed below.

**What is wrong** `Port.ConnectorReference` is declared

```python
PROCESS.Port.ConnectorReference = REFERENCE_PROPERTY(
    type=PROCESS.ProcessConnection,
    lower=1,
    upper=1,
    # TODO check multiplicities
    oppositeLower=0,
    oppositeUpper=1)
```

so at most one `Port` may reference a given `ProcessConnection`. A connection joins two ports:
`ProcessConnection.Source` and `.Target` are both 1..1 (L884-898), and each of those ports has to
reference a connection, because its own `ConnectorReference` is 1..1. Both naming the connection
they belong to is two references where the opposite bound allows one, before any delegated port
(see the erratum on `Port.SubReference`).

The same marker stands on thirteen further properties, several with opposite bounds that cannot
be meant either:

| Line | Property | Declared opposite | Consequence as declared |
| --- | --- | --- | --- |
| L855 | `MaterialPort.MaterialTemplateReference` | 1..1 | every `MaterialTemplate` is referenced by exactly one port, so two ports cannot carry the same material |
| L422 | `ListOfMaterialComponents.Component` | 1..1 | every `MaterialComponent` is in exactly one list, so two templates cannot both list water |
| L669 | `MaterialTemplate.ListOfComponents` | 1..1 | every list belongs to exactly one template |
| L888, L896 | `ProcessConnection.Source`, `.Target` | 0..1 | plausible |
| L705 | `Port.SubReference` | (composition) | see the erratum on `Port.SubReference` |
| L721 | `Port.SuperReference` | 0..* | plausible |
| L340, L349, L357, L365 | `MeasuringProcessVariable.ConnectionReference`, `.MeasuredVariableReference`, `.ProcessStepDetailReference`, `.ProcessStepReference` | 0..* | plausible |
| L4324, L4332 | `Stream.MaterialStateReference`, `.MaterialTemplateReference` | 0..* | plausible; note that the same template reference from a `MaterialPort` (L855) is 1..1 |

**Why it matters** Opposite multiplicities are part of the published model (L714-715 above), and
a validator generated from it rejects every model in which both ports of a connection reference
it, or two ports share a material template. The 2.0.1 release already corrected four such bounds
in the Plant model (changelog: "opposite upper multiplicities of properties
`PipingConnection.SourceItem` ... are now all unlimited (were 1 before)"); these are the Process
counterparts.

**What pyDEXPI does meanwhile** It does not enforce opposite multiplicities, in loading or in
validation: both ports of a connection reference it, and templates and components are shared.
That needs no deviation from the model on our side, because the generated classes do not carry
opposite bounds.

**Proposed fix** `oppositeUpper=None` on `Port.ConnectorReference` (or 2, if a delegated port is
to have no connection of its own); `oppositeLower=0, oppositeUpper=None` on
`MaterialPort.MaterialTemplateReference` and on `ListOfMaterialComponents.Component`; and a
decision on each remaining marker, removing the comment where the bound is confirmed.

*Found while moving [pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI), an
open-source Python implementation of the DEXPI information model, to DEXPI 2.0.1. That work is
in a development version, not yet in the public repository, which implements DEXPI 1.3: "what
pyDEXPI does" above describes the development version.*

---

## 4. `QualifiedValue.Type` is declared narrower than the bindings that use it

**Version:** DEXPI Specification 2.0.1, tag `V2.0.1`. Unchanged from 2.0.

**Where:**
[`Core.py` L261-271](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Core/Core.py#L261-271).

**What is wrong** The type parameter of `QualifiedValue` is bounded

```python
# TODO: any data type
Core.QualifiedValue.Type = DATA_TYPE_PARAMETER(
    type=Core.PhysicalQuantities.PhysicalQuantity | BUILTIN.Double)
```

and `QualifiedValue.Value` has that type (L265-268). The properties that bind the parameter use
three types outside the bound:

- `Undefined`, in every one of the 219 bindings in the model sources (each `'Type':` line under
  `src/model`), e.g. `'Type': BUILTIN.Undefined | PHYSICAL_QUANTITIES.PhysicalQuantity[...]`
  ([`Process.py` L65-67](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L65-67));
- `PhysicalQuantityVector`, in `Composition.MassFractions` and `.MoleFractions` (`Process.py`
  L39-41, L52-54);
- `Integer`, in `ElectricalEnergyFlow.NumberOfPhases` (L956-960), `Compressing.NumberOfStages`
  (L1467-1470), `TransportingElectricalEnergy.NumberOfPhases` (L3887-3889) and
  `ContactingInPacking.NumberOfTheoreticalStages` (L4233-4237).

`MeasuringProcessVariable.MeasuredVariableReference` carries the matching note, "TODO: any type
instead of PhysicalQuantity" (`Process.py` L344-346).

**Why it matters** A generator that gives `QualifiedValue.Value` its declared type produces a
class that rejects every `Undefined`, every composition vector and every integer count, although
each is exactly what a binding prescribes. Under the DEXPI 2.0 model, which declares the same
bound, this cost every fraction vector of the three independent process exports we have.

**What pyDEXPI does meanwhile** It deviates from the model, deliberately: `QualifiedValue.value`
is the union of what the bindings use (`Double`, `Integer`, `PhysicalQuantity`,
`PhysicalQuantityVector`, `Undefined`), still 1..1. Each binding is kept on the property that
declares it and checked there by validation: a value of another shape or unit than its own
property binds is reported.

**Proposed fix** Declare the bound the bindings need: `Undefined | Double | Integer |
PhysicalQuantity | PhysicalQuantityVector`, or any data type, as the TODO says.

*Found while moving [pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI), an
open-source Python implementation of the DEXPI information model, to DEXPI 2.0.1. That work is
in a development version, not yet in the public repository, which implements DEXPI 1.3: "what
pyDEXPI does" above describes the development version.*

---

## 5. `Port.SubReference` is declared a composition; producers write a reference, and what a delegated port is, with its `ConnectorReference`, is not specified

**Version:** DEXPI Specification 2.0.1, tag `V2.0.1`. Unchanged from 2.0.

**Where:**
[`Process.py` L703-723](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L703-723).

**What is wrong**

1. `Port.SubReference` is a `COMPOSITION_PROPERTY` of `Port` (L703-707, 0..*, marked
   `# TODO check multiplicities`), while `Port.SuperReference`, by its name the inverse, is a
   `REFERENCE_PROPERTY` (L717-723); the model does not declare the two as opposites. If a
   delegated port is a port of a sub-step, as both producers below have it, it is already
   composed by that step's `ProcessStep.Ports` (or, since 2.0.1, `ProcessStepDetail.Ports`).
   Composed by its super port as well, it would have two owners, which a composition tree cannot
   have.
2. Nothing says what the port at the other end of a `SubReference` is, a delegated port, as we
   call it below. `Port` (L677-686) describes a port; `SubReference` and `SuperReference` carry
   no description, and neither name occurs anywhere else in the model or the documentation
   sources. Is it its super port's stand-in on a step inside, with the same direction, or the
   inside face of the super port, with the opposite one?
3. `Port.ConnectorReference` is 1..1 (L709-715), and nothing says what a delegated port's is: the
   connection of its super port, in which it takes part without being its source or target; a
   connection of its own inside the sub-process; or none, which the multiplicity forbids.

**Evidence from producers** Both independent DEXPI 2.0 process exports we know that use the
relation write the link as a reference, in two spellings: a hand-authored CO2 terminal model
(University of Oslo) as `<References property="SubReference" objects="#...">`, 10 times, and
the bpmn2dexpi export as `<ObjectReference>` children of `<Components property="SubReference">`,
18 times: a reference inside a composition element. Neither nests the sub-port.

In the CO2 terminal file the two directions do not coincide: 10 ports are named by a
`SubReference` and 11 carry a `SuperReference`, and only 9 links are written both ways. One
`SubReference` target has no `SuperReference` (and is the only one of the 10 with a
`ConnectorReference` of its own), and two ports with a `SuperReference` are named by no
`SubReference`. The table counts the 11 ports with a `SuperReference`; counted on the 10
`SubReference` targets instead, the direction is that of the super port in 8, and
`ConnectorReference` is left out on 9.

On the other two points they read the specification in opposite ways:

| | CO2 terminal (11 ports with a `SuperReference`) | bpmn2dexpi (18 `SubReference` targets) |
| --- | --- | --- |
| Direction | that of the super port, in 9 of the 11 | the opposite one, in all 18: the outlet of a `Source` for a parent's inlet (10), the inlet of a `Sink` for a parent's outlet (8) |
| `ConnectorReference` | left out, on all 11 | a stream of its own inside the sub-process, of which the port is the source (10) or the target (8) |

**What pyDEXPI does meanwhile** It deviates from the model, deliberately: `Port.subReference`
is generated as a reference, and both spellings are read as one. It reads a delegated port as its
super port's stand-in: a load that tolerates absent mandatory attributes gives a delegated port
without a connection that of the first port up its `SuperReference` chain that has one, and
reports that it did; a strict load does not. A delegated port with a connection of its own, as
bpmn2dexpi writes it, is kept as written.

**Proposed fix** Make `Port.SubReference` a `REFERENCE_PROPERTY` (opposite of `SuperReference`),
and define a delegated port in the description of `Port`: its direction relative to its super
port's, and its connection. If it takes part in its super port's `ProcessConnection`, the opposite
bound of `ConnectorReference` rises accordingly (see the erratum on that bound); if it has none of
its own, `ConnectorReference` becomes 0..1 for it.

*Found while moving [pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI), an
open-source Python implementation of the DEXPI information model, to DEXPI 2.0.1. That work is
in a development version, not yet in the public repository, which implements DEXPI 1.3: "what
pyDEXPI does" above describes the development version.*

---

## 6. The 2.0.1 changelog omits a new property and repeats an entry; the new `RatioUnit.Fraction` has no RDL reference

**Version:** DEXPI Specification 2.0.1, tag `V2.0.1`, compared with tag `V2.0.0`.

**Where:**
[`changelog.rst`](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/documentation/appendix/changelog.rst),
[`Process.py` L3837-3876](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L3837-3876),
and `src/model/Core/PhysicalQuantities/UoM_DEXPI_1.3_SPEC.ods`.

**What is wrong**

1. **A new property is not listed.** `TransportingEnergy.Efficiency` (`Process.py` L3844-3855) is
   new in 2.0.1: in 2.0, `TransportingElectricalEnergy` had `Capacity`, `Frequency`,
   `NumberOfPhases`, `Voltage` and `Current`, and no `Efficiency`. The changelog lists the class
   as added (L75) and `Capacity` as moved into it (L79), but not the property, which
   `TransportingElectricalEnergy`, `TransportingMechanicalEnergy` and `TransportingThermalEnergy`
   now all inherit.
2. **An entry is repeated.** "modified: composition property `StoringEnergy.ChargeCapacity`
   renamed from `Capacity`" appears twice, identically (L55 and L59).
3. **A gained property is not mentioned.** `SeparatingByFlash` is listed as re-parented to
   `SeparatingByThermalProcess` (L47), and thereby gains `Duty` (`Process.py` L2486-2497). Four
   other re-parenting entries state their effect on properties ("properties removed as they are
   now inherited", L71 and L73; similarly L87 and L89); this one does not, and nor do L65, L67
   and L77 (for L77, see item 1).
4. **The scope of the unit rename is not given.** The rename of `PercentageUnit` to `RatioUnit`,
   "several literals added", is listed for the enumeration (L15). It changes what 19 properties
   accept, which until 2.0.1 took percent only: in Plant, `PipingNetworkSegment.Inclination`,
   `FilterUnit.LowerLimitAllowableSolidsConcentration` and `.UpperLimitAllowableSolidsConcentration`,
   and the `Efficiency` template used by four equipment classes; in Process,
   `Composition.MassFractions` and `.MoleFractions`, `Compressing.PolytropicEfficiency`,
   `Separating.ProductRecovery`, `.SeparationEfficiency` and `.WasteInProduct`,
   `SeparatingBySurfaceTension.PulpDensity`, and `Efficiency` of `SupplyingElectricalEnergy`,
   `SupplyingMechanicalEnergy`, `Boiling`, `HeatingElectrical` and `HeatingInFurnace`. The added
   literals are not named either: `Fraction`, `PartsPerThousand`, `PartsPerMillion`,
   `PartsPerBillion`.
5. **`RatioUnit.Fraction` is incomplete in the unit table.** In `UoM_DEXPI_1.3_SPEC.ods`, row 39
   (`Fraction`) has a DEXPI name and the symbol `1`, and no POSC Caesar URI, no POSC Caesar name
   and no UN code, where the other four `RatioUnit` rows have all three (rows 38 and 40-42:
   `Percent` `P1`, `PartsPerThousand` `NX`, `PartsPerMillion` `59`, `PartsPerBillion` `61`). The
   description of the quantity type in row 37, renamed `Ratio`, still reads "A quantity given as a
   percentage."

**Why it matters** An implementer upgrading from 2.0 works from the changelog. Item 1 is a model
change that only a diff of the two models shows; items 3 and 4 are consequences a reader has to
derive; item 5 leaves the new unit without the RDL reference and UN code the other four
`RatioUnit` literals have (five older unit rows lack the reference too: 118, 119, 122, 123 and
152).

**What pyDEXPI does meanwhile** Nothing depends on it: the classes are generated from the
published model, not from the changelog. We keep an inventory of the differences between the two
releases, checked against the changelog item by item, and can share it.

**Proposed fix** Add "added: composition property `Process.Process.TransportingEnergy.Efficiency`";
delete one of the two `ChargeCapacity` entries; note the inherited `Duty` under `SeparatingByFlash`;
name the four added literals; give `Fraction` its RDL reference and UN code (or state that it has
none) and reword the `Ratio` description.

*Found while moving [pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI), an
open-source Python implementation of the DEXPI information model, to DEXPI 2.0.1. That work is
in a development version, not yet in the public repository, which implements DEXPI 1.3: "what
pyDEXPI does" above describes the development version.*

---

## 7. `MeasuredQuantity` has no `Temperature` literal

**Version:** DEXPI Specification 2.0.1, tag `V2.0.1`. The enumeration is the same in 2.0, where no
property used it.

**Where:** `src/model/Process/Enumerations/process_enumerations.ods`, sheet
`process_enumerations`, rows 30-51 (read by
[`Enumerations.py` L5-8](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Enumerations/Enumerations.py#L5-8));
used at
[`Process.py` L326-329](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L326-329).

**What is wrong** `MeasuredQuantity` has 21 literals, in this order:

> `WeightMassForce`, `Velocity`, `Time`, `SpatialDimension`, `Radiation`, `Quality`, `Pressure`,
> `Power`, `NumberOfEvents`, `MultipleQuantities`, `Level`, `Humidity`, `Flow`, `Energy`,
> `ElectromagneticField`, `ElectricPotential`, `ElectricCurrent`, `Density`, `AudioVisual`,
> `VibrationOrTorque`, `PressureDifference`

There is no `Temperature`. The first nineteen are in descending alphabetical order, in which
`Temperature` would stand between `Time` and `SpatialDimension`, and the other measured variables
of everyday instrumentation are all there (pressure, flow, level, density, humidity, ...), so it
looks dropped rather than left out on purpose.

Since 2.0.1 the enumeration is the type of `MeasuringProcessVariable.MeasuredVariable`
(`Undefined | MeasuredQuantity`, L326-329; changelog L49), so it now decides what a measuring
activity can say it measures. The Process model itself has temperatures to measure:
`ProcessStep.Temperature` (L1122), `ProcessStepDetail.Temperature` (L4163),
`ThermalEnergyFlow.Temperature` (L1016), `Distilling.TopTemperature` and `.BottomTemperature`
(L2608, L2519).

**Why it matters** A temperature measurement, one of the most common on a process flow diagram,
cannot be classified. An exporter has to leave `MeasuredVariable` out, write `Undefined`, or
pick a wrong literal (`Energy`, `Quality`).

**What pyDEXPI does meanwhile** It follows the enumeration, so `MeasuredVariable` cannot be set
for a temperature measurement, which then names what it measures only through
`MeasuredVariableReference`. We do not deviate from the model here: adding a literal the
specification does not have would write documents other tools reject.

**Proposed fix** Add `Temperature` to `MeasuredQuantity`. If the omission is intended, document it (the
enumeration has no description today), with the literal a temperature measurement should use.

*Found while moving [pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI), an
open-source Python implementation of the DEXPI information model, to DEXPI 2.0.1. That work is
in a development version, not yet in the public repository, which implements DEXPI 1.3: "what
pyDEXPI does" above describes the development version.*

---

## 8. `GeneratingDCPower` is described as producing alternating current; `Flaring` is described as a `SupplyingThermalEnergy` process and does not derive from it

**Version:** DEXPI Specification 2.0.1, tag `V2.0.1`. Items 1 and 2 are unchanged from 2.0; item 3
is new in 2.0.1.

**Where:**
[`Process.py` L3482-3502](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L3482-3502),
[L1276-1281](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L1276-1281)
and
[L3640-3644](https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py#L3640-3644).

**What is wrong**

1. **`GeneratingDCPower` has the description of `GeneratingACPower`.** The two classes are
   described in the same words (L3482-3487 and L3497-3502):

   ```python
   PROCESS.GeneratingDCPower = CONCRETE_CLASS(
       description='''
           This :sp:element:`~Process.Process.SupplyingElectricalEnergy` process produces
           alternating current electrical energy from mechanical energy.''',
       superTypes=[PROCESS.SupplyingElectricalEnergy]
       )
   ```

   A class named `GeneratingDCPower` produces direct current. The properties follow the names
   and not the text: `GeneratingACPower` declares a `Frequency` (L3490-3495), and
   `GeneratingDCPower` declares no property of its own.
2. **`Flaring` names a supertype it does not have.** Its description reads "This
   `SupplyingThermalEnergy` process represents the flare system in a process plant" (L1278-1279),
   and its supertype is `ProcessStep` (L1280). So it inherits nothing from
   `SupplyingThermalEnergy` (L3640-3726). It declares three properties of its own, `Duty`, `Flow`
   and `SkinTemperature` (L1283, L1294, L1305), which have the names and unit types of three of
   that class's eight (L3657, L3668, L3706), and it lacks the other five: `Area`,
   `HeatTransferCoefficient`, `HeatTransferResistance`, `Method` and `TemperatureDifference`. The
   three other classes whose description opens "This `SupplyingThermalEnergy` process",
   `Boiling`, `HeatingElectrical` and `HeatingInFurnace`, do derive from it (L3733, L3759, L3811).
   Description and supertype cannot both be meant.
3. **`SupplyingThermalEnergy` was not moved under the new `SupplyingEnergy`.** 2.0.1 adds
   `SupplyingEnergy`, "a source of energy for use in other processes" (L3394-3399), and makes
   `SupplyingElectricalEnergy` and `SupplyingMechanicalEnergy` its subclasses (L3446, L3527;
   `src/documentation/appendix/changelog.rst` L63-67). `SupplyingThermalEnergy`, "a source of
   thermal energy for use in other processes", still derives from `ProcessStep` (L3643). In the
   two sibling families all three forms of energy derive from the family's class:
   `StoringElectricalEnergy`, `StoringMechanicalEnergy` and `StoringThermalEnergy` from
   `StoringEnergy` (L3333, L3384, L3391), and `TransportingElectricalEnergy`,
   `TransportingMechanicalEnergy` and `TransportingThermalEnergy` from `TransportingEnergy` (L3875,
   L3913, L3924).

Items 1 and 2 are the only ones of their kind in `Process.py`. All of its 150 classes have a
description, and no other two share one. Of the 57 descriptions that open by naming a class of
the model ("This `X` ...", 47 of them "This `X` process ..."), `Flaring`'s is the only one in
which `X` is not a supertype of the class described.

**Why it matters** A class description is what a reader chooses a class by, and what generated
documentation and class catalogues repeat; a language model that picks a process step from such
a catalogue has nothing else to go by. Read as written, `GeneratingACPower` and
`GeneratingDCPower` are the same thing, and no class is described as generating direct current.
`Flaring` is described as a kind of process whose properties it does not have. A query for
every `SupplyingEnergy` step misses every supply of heat; and if the description in item 2 is
what is meant, a query for every `SupplyingThermalEnergy` step misses the flare.

**What pyDEXPI does meanwhile** It follows the specification on all three. Its classes are
generated from the model and carry the model's descriptions as they stand, so both sentences are
shown wherever a class is described: in the class documentation, in the description a graph
export attaches to each node, and in the class catalogue its MCP server gives a language model.
The classes themselves are what the model declares: `GeneratingDCPower` has no frequency,
`Flaring` is a `ProcessStep` with its own three properties, and `SupplyingThermalEnergy` is not a
`SupplyingEnergy`. We do not deviate from the model here: item 1 touches a description only, and
for items 2 and 3 only DEXPI can say which reading is meant.

**Proposed fix**

- `GeneratingDCPower`: "This `SupplyingElectricalEnergy` process produces direct current
  electrical energy from mechanical energy."
- `Flaring`: decide which is meant. If a flare is a `SupplyingThermalEnergy` process, make that
  its supertype and remove its own `Duty`, `Flow` and `SkinTemperature`, which it then inherits.
  If it is not, reword the description ("This process represents the flare system in a process
  plant").
- `SupplyingThermalEnergy`: `superTypes=[PROCESS.SupplyingEnergy]`, as its electrical and
  mechanical siblings have. If it is left out on purpose, say so in its description.

*Found while listing the process step classes of DEXPI 2.0.1 with their descriptions, using
[pyDEXPI](https://github.com/process-intelligence-research/pyDEXPI), an open-source Python
implementation of the DEXPI information model. Its DEXPI 2.0.1 work is in a development version,
not yet in the public repository, which implements DEXPI 1.3: "what pyDEXPI does" above describes
the development version.*
