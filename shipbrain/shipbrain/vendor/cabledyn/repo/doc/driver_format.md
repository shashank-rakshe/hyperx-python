<!-- SPDX-License-Identifier: Apache-2.0 -->

# Deck format reference (`.dat`)

This page is for anyone writing or editing a CableDyn input deck. It defines every section,
column, keyword, default, and error rule of the sectioned `.dat` deck read by the standalone
driver (`CableDyn_driver`, built as `cabledyn`), the CableDyn module of OpenFAST
(`CompMooring = 5`; OpenFAST is maintained by NLR, the National Laboratory of the Rockies,
formerly NREL), the C API, and the Python package.

The deck is a MoorDyn-style deck: it uses MoorDyn v2 section names, columns, point types, and
option keywords, and it reads stock MoorDyn line rows unchanged. CableDyn adds an optional
`SECTIONS` table, so one line can carry several line types (see
[LINES + SECTIONS](#lines-sections)).

Related pages: [Conventions](conventions.rst), the [OPTIONS reference](options.rst),
[Auxiliary file formats](file_formats.rst), [Outputs](outputs.rst), and the
[coupling boundary](coupling_boundary.md).

## Principles

1. **MoorDyn v2 vocabulary.** Where CableDyn adds capability (finite-EI bending, Newton static
   initial condition), the deck extends MoorDyn and never contradicts it.
2. **Fail closed.** Every section, column, and keyword is either supported on a route or
   rejected at parse with an error that names the feature. Nothing is silently solved as
   something else.
3. **SI units.** Metres, kilograms, newtons and seconds. Angles are in degrees: body
   attitudes, wave directions, `vesselMotion` and `TURBINES` attitudes, RAO phases and every
   output angle. Radians appear only where a row says so: angular rates in motion records,
   wave frequencies, rotational stiffnesses per radian and the MoorDyn-C `WaveKin 7` direction.
   There is no unit conversion. Tensions are written in N.
4. **Line-oriented, case-insensitive keywords.** Blank lines are ignored. Section headers are a
   name inside a rule of dashes. Table sections skip their column-name and units rows; columns
   are positional. Comment rules are in [Records, comments, and
   tokens](#records-comments-and-tokens).
5. **Whole-token values.** Columns are whitespace-separated. A numeric value is one plain number
   with a `.` decimal point. An unquoted value containing `/`, `,` or `;`, or a repeat count such
   as `2*0.0`, is rejected, never read partially (`500/2` is never `500`; `400,0` never shifts the
   columns). Quote text values that need these characters. The `SYROPE:<path>|alpha|beta` EA
   column and file-path options accept unquoted `/` and `\`; paths must not contain spaces, `#`,
   or `!`. Comma lists are accepted only where the grammar names them: FAILURE and CONTROL line
   lists, SYROPE IC line ids, and OUTPUTS channels. Parse errors name the deck line and quote the
   row; duplicate and undefined ids are named. Numbers follow the Fortran real syntax, in which
   the exponent letter may be omitted: `1.5-3` is read as `1.5e-3` and `3.0+6` as `3.0e6`.
   MoorDyn's C reader takes such a token as `1.5` and `3.0`, so write exponents with `e`
   (`1.5e-3`) in a deck meant for both codes.

## Records, comments, and tokens

These rules apply to every deck record. Auxiliary files (motion history, bathymetry, Syrope
tables) use the same comment and record-length rules.

| Rule | Behaviour |
|------|-----------|
| Encoding | UTF-8. A byte-order mark at the start of the file is ignored. File names inside the deck are UTF-8 (see [File names](#file-names)). |
| `#` and `!` | start a comment **anywhere** in a record, including inside a quoted value or a file path. The rest of the record is ignored. |
| `--` | starts a comment only at the start of a record or after whitespace, and only in a record that contains no `---`. `a--b` is not a comment. |
| `---` | a record containing three consecutive dashes is a **section header**; the non-dash text of the whole record is the section name, so a long title banner such as `------ CableDyn Input File ------` is recognised wherever its words fall. Keep `---` out of data rows and descriptions. |
| Record length | at most 512 characters of non-comment text. A longer record fails with `<file> line N is longer than 512 characters`; it is never truncated. A long comment is accepted, and so is a final record without a line ending. |
| Blank records | a record holding only whitespace (after its comment is removed) is skipped anywhere, OPTIONS included. |
| Table header rows | in table sections, a row with no numeric token is a column-name or units row and is skipped. |
| Tokens | separated by ASCII whitespace: space, tab, carriage return, line feed, form feed, or vertical tab. A quoted token may contain spaces. Numeric columns take one plain number (Principle 5). |
| Rejected characters | a NUL character, or a non-ASCII whitespace character such as a no-break space (U+00A0) or an ideographic space (U+3000), outside a comment fails with `deck line N contains ...`: it looks like a separator but would silently become part of a token. |
| Identifiers | line-type names, rod-type names, point and body types, `Outputs` flags, and OUTPUTS channel names are held in 64-character fields. A longer name or text token in any table row, or a longer channel name, is an error naming the deck line. |
| Error location | row-level errors read `CableDyn_DeckDriver: deck line N: <message> [row: <text>]`. Errors found after the whole deck is read that concern one row (a duplicate or undefined id, a `NumSegs` or type range, an unsupported OUTPUTS channel) read `CableDyn_DeckDriver: deck line N: <message>`, N being that row's line. Auxiliary files use their own label, for example `motionFile line N`, `bathymetry file line N`, `WaterKin file line N`, or `WaterKin WaveKinFile line N`. |
| Values | every number in a deck row, an OPTIONS row, or an auxiliary file must be finite and not subnormal: `NaN`, `Inf`, a decimal beyond 1.8e308, and a nonzero magnitude below 2.2e-308 (such as `5e-324`) are rejected on that row with `value "X" is not a finite number` or `value "X" is subnormal`. A negative drag or added-mass coefficient in a LINE TYPES row is rejected on that row. Every OPTIONS row is range-checked on its own, so an invalid value is rejected even when a later row sets the same keyword again. Magnitudes are also bounded; see [Admissible input ranges](#admissible-input-ranges). |

Table rows are filtered strictly. In LINE TYPES, BODIES, ROD TYPES, RODS, POINTS, LINES,
SECTIONS, EQUIVALENT BUOYANCY, and END CONNECTIONS, an unquoted token containing `/`, `,` or `;`,
or of the form `n*value`, fails as `column C value "X" contains ...`. The one exception is LINE
TYPES column 4 (EA), which is read as text so that `SYROPE:<path>|alpha|beta` can hold a path.
Only text columns (names, types, `Outputs` flags, EA/BA, END CONNECTIONS `End`/`Stiffness`) may be
quoted; a quoted number or id fails as `column C must be an unquoted number`. A token that opens a
quote must hold non-empty text inside one pair of matching quotes. LINES attachments (`NodeA`,
`NodeB`, `AttachA`, `AttachB`) are an unquoted point id or rod end (`R<N>A`, `R<N>B`) taken whole:
`"1"`, `1x`, or `"1 x"` fails as `malformed LINES row`.
FAILURE, CONTROL, and SYROPE IC rows are split on whitespace and parse their comma lists
strictly. OUTPUTS rows are split on whitespace and commas.

### Admissible input ranges

Beyond these magnitudes the solver's force, length, or time scales overflow instead of failing to
converge, so a deck outside them is rejected at validation with a message that names the limit.

| Quantity | Admissible range |
|----------|------------------|
| Point, body, rod, and turbine coordinates; `WtrDpth`; current-profile depths | magnitude at most 1e6 m |
| `g` | > 0 and at most 1e3 m/s² |
| `rhoW` | > 0 and at most 1e5 kg/m³ |
| `kBot`, `cBot` | magnitude at most 1e15 |
| LINE TYPES `EA` (where used) | at least 1e-3 N and at most 1e15 N |
| LINE TYPES `Diam` (where used) | at least 1e-6 m and at most 1e3 m |
| LINE TYPES `EI` and the magnitude of `BA` (where used) | at most 1e15 |
| LINE TYPES `Cd_n`, `Cd_t`, `Ca_n`, `Ca_t` (where used) | 0 to 1e3 |
| POINTS `Mass`, `Vol`, `CdA`; body mass, volume, stiffness, drag area, inertia | magnitude at most 1e15 |
| POINTS and body `Ca` | magnitude at most 1e3 |
| Current velocity components (OPTION, WaterKin, `current_profile.txt`) | magnitude at most 1e3 m/s |
| Wave height (regular and spectral), WaveKinMod 1 component amplitude | at most 1e3 m |
| Wave period; JONSWAP `gamma` of a `waves` row | 0.1 s to 1e5 s; `gamma` at most 1e3 |
| WaveKinMod 1 component frequency | at most 1e4 rad/s |
| `motionFile` point rows | position ≤ 1e6 m, velocity ≤ 1e4 m/s, acceleration ≤ 1e6 m/s² in magnitude |
| `vesselMotion` rows | every value at most 1e6 in magnitude |
| Syrope `EXP` working curve `k2` | 1e-6 to 700 |

## File names

A file name written in the deck (`motionFile`, `bathymetryFile`, `WaterKin`, a Syrope
settings file, and the files those name) is read as UTF-8, the same as the deck path and
output root given on the command line, so names in any script are allowed. On Windows the
driver opens exactly the named file or refuses it with a reason; it never falls back to a
look-alike name (`café` is never read as `cafe`):

- the release executables (`CableDyn_driver.exe` and `openfast.exe`) run with UTF-8 as their
  Windows code page (Windows 10 version 1903 or later), so every name, and every working
  folder, is opened as written whatever the system locale;
- a driver built from source with the GNU toolchain uses the system ANSI code page instead: a
  name that code page cannot spell is opened through the 8.3 short name of the file or of its
  folder, and on a volume without 8.3 names it is refused with `the name has characters the
  Windows ANSI code page cannot represent ...`, as is an output root whose own final name has
  such characters;
- a path longer than 259 characters is opened through its short or extended-length (`\\?\`)
  spelling, else refused as too long;
- a reserved device name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`, with any
  extension and in any folder) is refused with `the name is a reserved Windows device`, because
  opening it reads the console or discards the data.

Other systems open the UTF-8 name as given.

## Section structure

A section begins at its header and ends at the next header. Sections may appear in any order,
except that `SYROPE IC` must come **after** `LINES`, because its rows name lines that must already
exist. A conventional layout is:

LINE TYPES → BODIES → EXTERNAL LOADS → ROD TYPES → RODS → POINTS → TURBINES → LINES → SYROPE IC →
SECTIONS → END CONNECTIONS / EQUIVALENT BUOYANCY / ATTACHMENTS / STIFFENERS / FAILURE / CONTROL →
OPTIONS → OUTPUTS

Within LINE TYPES, the header row must precede the data rows because it selects their column
order.

A **line is one object spanning two end points** (End A = `NodeA`, End B = `NodeB`), built from
an ordered list of **sections**, each with its own line type and mesh density (the same
line-and-section arrangement OrcaFlex uses): a bare cable and a buoyancy stretch are sections of
one line, and a bend stiffener over its end is a [STIFFENERS](#stiffeners-optional-finite-ei-lines)
row. A single-material line is one section. MoorDyn composites written
as separate lines
joined at a `Connect` point are also valid.

```
--------------------- CableDyn Input File ------------------------------------
Composite chain-wire mooring, fairlead to anchor
--------------------- LINE TYPES ---------------------------------------
TypeName   Diam    MassDenInAir   EA        BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)        (m)     (kg/m)         (N)       (N-s/-)    (N-m^2)  (-)   (-)   (-)   (-)
chain155   0.252   390.0          1.674e9   -1.0       0.0      1.37  0.64  1.0   0.0
wire       0.20     90.0          7.0e8     -1.0       0.0      1.2   0.05  1.0   0.0
--------------------- POINTS -------------------------------------------
ID    Type      X        Y      Z         Mass    Vol     CdA    Ca
(-)   (-)       (m)      (m)    (m)       (kg)    (m^3)   (m^2)  (-)
1     Fixed     400.0    0.0    -50.0     0       0       0      0
2     Coupled   0.0      0.0    0.0       0       0       0      0
--------------------- LINES --------------------------------------------
ID    NodeA   NodeB   Outputs
(-)   (-)     (-)     (-)
1     2       1       -
--------------------- SECTIONS -----------------------------------------
LineID   LineType   Length   NumSegs
(-)      (-)        (m)      (-)
1        chain155   350.0    35
1        wire        60.0    20
--------------------- OPTIONS ------------------------------------------
9.80665      g         - Gravitational acceleration (m/s^2)
1025.0       rhoW      - Water density (kg/m^3)
50.0         WtrDpth   - Water depth (m)
1.0e5        kBot      - Seabed penalty stiffness base (Pa/m)
1.0e4        cBot      - Seabed normal damping base (Pa-s/m)
--------------------- OUTPUTS ------------------------------------------
"FairTen1"
"AnchTen1"
"FairIncl1"
"AnchIncl1"
"Point2px"
"Point2py"
"Point2pz"
--------------------- need this line -----------------------------------
```

The example decks in `examples/` start with the `CableDyn Input File` banner shown above, followed
by a free-form title line. Auxiliary data tables referenced by a deck, such as a Syrope working
curve, keep their own headers.

### Section headers and aliases

The header name is compared case-insensitively after the dashes are removed and runs of spaces
are collapsed. It must match one of the spellings below; any other name fails with
`unknown deck section "<NAME>"`.

| Section | Accepted header names |
|---------|-----------------------|
| LINE TYPES | `LINE TYPES`, `LINETYPES`, `LINE DICTIONARY` |
| BODIES | `BODIES`, `BODY` |
| ROD TYPES | `ROD TYPES`, `RODTYPES`, `ROD DICTIONARY` |
| RODS | `RODS`, `ROD LIST`, `ROD PROPERTIES` |
| POINTS | `POINTS`, `CONNECTION PROPERTIES`, `POINT PROPERTIES`, `CONNECTS` |
| LINES | `LINES`, `LINE PROPERTIES` |
| SECTIONS | `SECTIONS` |
| SYROPE IC | `SYROPE IC` |
| END CONNECTIONS | `END CONNECTIONS`, `END CONNECTION` |
| EQUIVALENT BUOYANCY | `EQUIVALENT BUOYANCY`, `EQUIVALENT SECTIONS`, `BUOYANCY SECTIONS` |
| ATTACHMENTS | `ATTACHMENTS`, `LINE ATTACHMENTS`, `CLUMPS` |
| STIFFENERS | `STIFFENERS`, `STIFFENER`, `BEND STIFFENERS`, `BEND STIFFENER` |
| FAILURE | `FAILURE`, `FAILURES` |
| CONTROL | `CONTROL`, `CONTROLS` |
| TURBINES | `TURBINES`, `TURBINE` |
| EXTERNAL LOADS | `EXTERNAL LOADS`, `EXTERNAL LOAD` |
| OPTIONS | `OPTIONS`, `SOLVER OPTIONS` |
| OUTPUTS | `OUTPUTS`, `OUTPUT` |

Four header forms close the current section without opening a new one; records after them are
ignored until the next recognised header:

- a bare rule of dashes;
- a header named `END`;
- any header whose name contains `NEED` (the stock `need this line` footer);
- any header whose name contains `INPUT FILE` (the title banner, such as
  `--- CableDyn Input File ---` or `--- MoorDyn Input File ---`). The title line after it is
  therefore ignored.

Inside OUTPUTS, a row whose first token is `END` also closes the channel list.

### LINE TYPES

| Column | Meaning | Notes |
|--------|---------|-------|
| `TypeName` | unique key referenced by LINES / SECTIONS | duplicate names (case-insensitive) are rejected |
| `Diam` | hydrodynamic / volume-equivalent diameter [m] | used for submerged weight, drag, and added mass; at least 1e-6 and at most 1e3 where used |
| `MassDenInAir` | dry mass per unstretched metre [kg/m] | submerged weight = (m − ρ_w·πd²/4)·g; its magnitude at most 1e6 where used |
| `EA` | axial stiffness [N] | linear (T = EA·ε); at least 1e-3 and at most 1e15 where used; see the viscoelastic and Syrope forms below |
| `BA/-zeta` | axial damping: ≥ 0 is BA [N·s], < 0 is −ζ (damping ratio): by default (MoorDyn's convention) of each segment, BA = ζ L0 √(EA m) per element, which damps the line's first axial mode at about ζ π/(2N) on N elements and so depends on the mesh (a run notes the ratio); under `mode1 axialDampingRatio` of the line's first axial mode, on any mesh (see the OPTIONS table) | active in EI = 0 and finite-EI dynamics; ignored in a static-only run |
| `EI` | bending stiffness [N·m²] | finite and ≥ 0; see [EI routing](#ei-routing) |
| `Cd_n`, `Cd_t` | normal / tangential drag coefficients | used by EI = 0 dynamic current and Airy-wave runs |
| `Ca_n`, `Ca_t` | normal / tangential added-mass coefficients | used by EI = 0 dynamic Froude–Krylov and added-mass runs |

Every numeric property must be finite.

**Column order from the header row.** The stock MoorDyn header names its four hydrodynamic
columns `Cd Ca CdAx CaAx` (normal drag, normal added mass, axial drag, axial added mass); the
CableDyn order is `Cd_n Cd_t Ca_n Ca_t`. The data rows cannot distinguish the two, so the header
row decides:

- a header containing `CdAx` or `CaAx` selects the stock order;
- a header containing `Cdt` or `Cd_t` selects the CableDyn order;
- with neither, the CableDyn order is used.

A stock-order header applies only to the 10-column row.

**Optional finite-EI columns.** A 14-column row adds `GAs`, `GJ`, `Irt`, `Irn` (shear stiffness,
torsional stiffness, transverse and polar (axial) rotary inertia per length):
`Name Diam Mass EA BA EI GAs GJ Irt Irn Cd_n Cd_t Ca_n Ca_t`. The four extra values must be finite
and either all `0` or all `> 0`. All zero, or the 10-column row, selects the circular-section
closure `GAs = EA/(2(1+0.3))`, `GJ = EI/(1+0.3)`, `Irt = m d²/16`, `Irn = m d²/8`. The closure
serves the secondary Cosserat library path only: a finite-EI line restrained in torsion
([END CONNECTIONS](#end-connections-optional-finite-ei-lines)) takes `GJ` [N·m²/rad] from the
14-column row of each of its sections and stops by name without it. In the dynamics such a line
carries a twist angle at every node, whose polar rotary inertia is `Irn` [kg·m²/m]
(`m r²/2` for a solid round section; see [Nodal twist](theory.rst)): give the section's real
value, as a placeholder `Irn` gives the line a wrong torsional inertia. `GAs` and `Irt` are not
used by the cubic-Hermite route, but the all-or-nothing rule still asks for positive values.
The `GJ` column may be written `GJ|K`, with `K` [N·m] the torque–tension coupling of an armoured
cable or wire rope (`T = EA ε + K τ`, `M = GJ τ + K ε`; see
[Torque–tension coupling](theory.rst)). It needs a finite-EI, linear-elastic type with
`K² < EA·GJ`. `GJ|0` is the plain `GJ`.
`GJ|K|Bt` adds the torsional damping `Bt` [N·m²·s] of the nodal twist (the torque
`Bt dτ/dt`, stiffness-proportional: a torsional mode of frequency `ω` has the damping ratio
`ω Bt/(2 GJ)`); a negative `Bt` is `-ζ`, the fraction of an element's critical torsional damping
`l0 √(GJ Irn)` on the final mesh, as `BA` is for the axial damping (an element whose length
active line control changes keeps its `ζ`). It needs a finite-EI type; `GJ|0|Bt` is damping
without coupling.

**Viscoelastic axial stiffness (MoorDyn `ElasticMod`).** The EA and BA columns accept
bar-separated parts:

| EA form | Model | Rules |
|---------|-------|-------|
| `EA` | linear | BA is one value |
| `Es\|Ed` | constant dynamic stiffness | `Ed` finite and **greater than** `Es` |
| `Es\|alphaMBL\|vbeta` | load-dependent dynamic stiffness | `alphaMBL` and `vbeta` finite and > 0 |

With a two- or three-part EA, BA may be `Bs` or `Bs|Bd`, with `Bd` finite and ≥ 0. BA never has
more parts than EA, and at most two. Viscoelastic types require `EI = 0`.

**Syrope polyester (MoorDyn-F/C working-curve model).** Use `EA = SYROPE:<settings>|alpha|beta`
and `BA = BA_s|BA_d`:

- EA has exactly three parts; `alpha` and `beta` are finite and > 0.
- BA has exactly two parts; both are ≥ 0 and their sum is > 0.
- The settings file, resolved relative to the deck, holds `OWC`, `WCType` (`LINEAR`, `QUADRATIC`,
  or `EXP`), `k1`, and `k2` rows as `value name`. `OWC` names the original-working-curve table,
  resolved relative to the settings file: a `strain tension` table of at least two numeric rows.
- `BA_d` enters the slow-state rate; the physical damping contribution is `BA_s*d(eps_slow)/dt`.
- A Syrope type requires `EI = 0`. A Syrope line is either a single section, taut at
  initialisation, or a composite line whose other sections are linear-elastic `EI = 0` sections (a
  chain–polyester–chain mooring), with every Syrope element in tension at initialisation. It runs
  on a dynamic deck (`dtM`/`TMax`) and takes the seabed, `bathymetryFile`, Morison loads, current,
  waves, host fluid fields and VIV of any `EI = 0` line, and active line control of a Syrope
  segment on the OpenFAST route ([CONTROL](#control-optional-openfast-line-control)).
- The static start solves each Syrope element on the rest curve of its load history (the OWC, or
  the `Tmax0` working curve under `SYROPE IC`). The tension varies along a Syrope section (a
  sagging section of a composite line, or the weight of a long or inclined taut rope), so every
  Syrope element takes its own secant EA at its own tension: every element starts on its curve
  and the dynamics start in the static equilibrium.

The settings-file grammar is in [Auxiliary file formats](file_formats.rst).

(ei-routing)=
#### EI routing

`EI = 0` uses the positions-only cable path on every route. Non-finite or negative `EI` is
rejected. `EI > 0` is routed as follows.

**Standalone dynamic run** (`dtM`/`TMax` set):

- Finite-EI lines whose End B is a `Fixed`, `Coupled` or `Vessel` point run on the cubic-Hermite
  route. It
  covers suspended spans, motion-file, current, and wave cases, and flat or structured seabed
  contact. Contact uses a C1 normal penalty, compression-only normal damping, and stick-slip
  seabed friction, each scaled by nodal diameter × tributary length. Slack spans with
  both endpoints above the bed start from an isometric two-touchdown seed.
- A line whose End B is a `Coupled`/`Vessel` point (a line between two moving points, such as a
  cable shared by two floaters or a `TURBINES` shared line) has both ends driven: End B moves with
  the same motion table as End A (`motionFile` rows, the `vesselMotion`/`vesselRAO` vessel and its
  rotation, `TURBINES` rows, the `motionFile` roll column) and is held where no motion is given.
  Its static solve is that of a `Fixed` End B at its deck position, so a `Coupled` End B the motion
  leaves at rest is the `Fixed` End B, byte for byte. `staticsFriction asLaid` is refused on such a
  line (it has no anchored end to lay the line from).
- A deck whose finite-EI lines are its only lines and whose endpoints are all
  `Fixed`/`Coupled`/`Vessel` runs on this route; with EI = 0 lines beside them it is a
  standalone mixed deck (below). With BODIES, RODS, or `Connect`/`Free` points it runs on the
  [multibody march](#multibody-march).
- When `motionFile` row 1 differs from the deck fairlead, CableDyn installs that boundary state
  and the initial fluid field, then recomputes the free-node acceleration from the full
  structural, contact, and hydrodynamic residual before writing `t = 0` (also with `TMax = 0`).
  The `.static.out` profile is written before that, so it holds the static solve.

**Standalone mixed deck** (separate `EI = 0` and `EI > 0` lines between `Fixed`/`Coupled`/`Vessel`
points only): the deck is partitioned through the same atomic aggregate used by OpenFAST.
`Coupled`/`Vessel` endpoints are held at their deck positions, or follow a `motionFile` or
`vesselMotion` as on the cubic-Hermite route: row 1 is installed and the cables' free-node
accelerations recomputed before `t = 0` (also with `TMax = 0`, whose `.out` row is then that
state; `.static.out` holds the static solve), a vessel turns the end connection and torsion
frames of the cables on its points, and the roll column imposes the twist of a line restrained
in torsion. The row-1 transfer also re-derives the interior accelerations of the `EI = 0` lines
at that state, which the `EI = 0`-only route does not, so when row 1 is off the deck pose their
first steps differ from that route's. A static run (`TMax = 0`) of a line restrained in torsion
takes `False alpha_force_blend`, as on the single-line route.
The run writes the common `.out` and the all-line `.static.out` tables, plus the range graph of
every line with the `r` flag.
A mixed deck takes every deck current the single-line routes take: a `current` OPTION (uniform or
profile), a WaterKin `CurrentMod 1` table and MoorDyn-C `Currents 1`/`2`/`5`. The static start of
its `EI = 0` lines and finite-EI cables is solved in the current at `t = 0`, and before every step
the current at the step's end time is sampled at every node of the step-start state and held
over the step, as on the single-line routes and with the same field evaluation (a `Currents 2`/`5`
table that varies in time repeats past its last sample there too). Mixed decks reject, by name,
deck waves (so `vesselRAO`), WaterKin `WaveKinMod 1`, MoorDyn-C `WaveKin 3`/`7`, and per-line
`p`/`t` flags.

(multibody-march)=
**Multibody march** (bodies, rods, `Connect`/`Free` points, EI = 0 lines and finite-EI cables in
one deck). A standalone dynamic deck runs on one march over all of its objects when it has a rod
pinned to a body, a `Pinned` rod carrying lines, finite-EI lines beside bodies, rods or
`Connect`/`Free` points, free or fixed rods beside Rigid6 bodies or `Connect`/`Free` points, or
Rigid6 bodies beside `Connect`/`Free` points. Under the default `bodyScheme monolithic` it also
takes every other dynamic deck of free Rigid6 bodies, `Point3` buoys, free, fixed or pinned rods
and `Connect`/`Free` points on EI = 0 lines, unless the deck has a `motionFile`, a `FAILURE`
section or `Coupled`/`Vessel` rods.

With `bodyScheme monolithic` (the default) each step is one implicit generalised-α step: the
end-of-step accelerations of the bodies, rods, `Point3` buoys and `Connect`/`Free` points are the
unknowns of a Newton iteration, and every iterate steps the attached EI = 0 lines with the
resulting end motion and takes their end reactions and condensed end stiffness
([theory](theory.rst)). The step needs no sub-stepping for stability; `bodySubstep accuracy`
(the default) divides it only to resolve the stiffest body-mooring mode.

With `bodyScheme staggered` each step is a predictor-corrector:

1. the free bodies and the free and pinned rods move to their end-of-step positions with their
   previous accelerations (central difference); a rod pinned to a body turns with its own
   rotation and keeps End A on the body's pin point;
2. the EI = 0 lines are stepped with that end motion, with the `Connect`/`Free` points
   integrated on their summed line-end loads as on the point-system route, and each finite-EI
   cable is stepped with its End A driven by its attachment and End B held;
3. each body solves its equation of motion together with the rods pinned to it (the body twist
   and each pinned rod's rotation as unknowns), each free rod its own, and each `Pinned` rod its
   rotation about the pin, from the end-of-step line loads; the EI = 0 line end-node inertia and
   the drag of the objects enter implicitly.

The staggered steps are sub-cycled so the explicit object positions resolve the stiffest
object-mooring mode of the EI = 0 lines. A finite-EI cable end on a body point or a rod end is
pinned unless it has an [END CONNECTIONS](#end-connections-optional-finite-ei-lines) row: a pinned
end passes its end force to the object at the attachment and no moment. A `Rigid` or spring end
is fixed in the object: its direction turns with the object, the connection moment is returned to
it, and the monolithic step re-steps the cable at every outer iteration with its end stiffness in
the Newton matrix. A cable between two objects (End B on a body point or a rod end as well) is
driven at both ends and re-stepped at every outer iteration whatever its connections; its
end-to-end stiffness couples the two objects' coordinates in the one Newton matrix of the step,
and its end loads (and, at a connected or torsional end, the connection moment and torque) return
to each object. The static solve (`bodyIC static`) balances the cable's bending end force and
connection moment at every connected end, and at both ends of a cable between two objects
(passes accelerated by Anderson mixing when the deck has such a cable). On this route:

- a finite-EI cable's ends may be `Fixed` points, Rigid6 `Body<N>` points or rod ends, not
  `Free`/`Connect` points or `Point3` buoys; a `Coupled`/`Vessel` end, which this march has no
  motion to drive, is rejected by name;
- a clamped or elastic end, or a torsional one (bending-pinned included), on a body or rod needs
  `bodyScheme monolithic` (the default); `staggered` rejects it by name, at either end. The
  staggered scheme passes cable end forces explicitly and sizes its sub-steps from each end's
  spring to its own object, so a stiff cable with both ends on one body (or between two light
  objects) is resolved there only as far as `dtM` allows; the monolithic scheme couples it in its
  Newton matrix;
- the monolithic step re-steps at every outer iteration every cable with an end, pinned or
  connected, on a moving object (a Rigid6 body, a free or pinned rod), with its end stiffness in
  the Newton matrix, so a light object on a stiff cable is as stable as a heavy one; an end on a
  fixed rod's end is the `Fixed` end there;
- every `Free`/`Connect` point carries at least one EI = 0 line;
- `motionFile` and `Coupled`/`Vessel` rods are rejected by name.

Static initial condition: the static solve moves the free bodies, the free rods, the pinned rods
(two rotations about the pin, the pin force on the parent body) and the `Free`/`Connect` points
together. A finite-EI line enters it with its axial stiffness and weight (its part above the
surface with its dry weight), without its bending stiffness (a note names the line); its own
shape is then solved with the bending stiffness at the equilibrium end positions. A line
connected (clamped, elastic or restrained in torsion) at a body or rod end, a line between two
objects, and a bending-pinned line on a Rigid6 body or a rod end are balanced on their
cubic-Hermite end loads in static passes.

**OpenFAST `CompMooring = 5` (aggregate route):** finite-EI cables run on the cubic-Hermite path:
lazy-wave statics and generalised-α dynamics driven by the coupled fairlead, including platform
rotation at a hang-off that declares an [END CONNECTIONS](#end-connections-optional-finite-ei-lines)
row. On this route:

- deck `waves` and `wavetrain` OPTIONS are rejected at initialisation on every coupled deck,
  because the host SeaState supplies the waves; a deck `current` (or a WaterKin `CurrentMod 1`
  table) is rejected on any deck with a finite-EI cable, Rigid6 body or rod, and a deck `current`
  row is kept as a steady current only on a single-turbine, pure `EI = 0` deck in a SeaState
  without waves or current; coupled cables take their fluid kinematics from the host SeaState
  field;
- a finite-EI cable cannot share a coupled deck with Rigid6 bodies, rods, or `Connect`/`Free`
  points;
- FAILURE rows are rejected on decks that contain finite-EI cables; CONTROL rows may name
  finite-EI cables (see [CONTROL](#control-optional-openfast-line-control));
- `Coupled`/`Vessel` rods are platform-borne and need no `motionFile`: each is a node of the
  OpenFAST mesh at its End A, turns rigidly with the platform orientation (its deck coordinates,
  like those of `Coupled` points, are given at the undisplaced platform and moved by
  `PtfmInit`), and returns to the platform the force and moment about End A of its attached
  lines, weight, buoyancy, Morison loads, seabed contact and its own and added-mass inertia
  (MoorDyn-F's coupled rod);
- `CoupledPinned`/`VesselPinned` rods are pinned to the platform: each is a node of the OpenFAST
  mesh at its End A (moved by `PtfmInit` with the rod, like a `Coupled` rod) that takes the
  platform position only. The rod turns about the node with its own three rotations, the node
  orientation and angular rates are ignored, and the node returns a force and no moment: the
  rod's lines, weight, buoyancy, Morison loads and seabed contact less its own and added-mass
  inertia (MoorDyn-F's coupled pinned rod). The angular acceleration in that inertia is solved
  for the node's current acceleration, so the rotation feels the platform acceleration and a
  CalcOutput at an off-step acceleration returns the rod's effective inertia about the pin.
  `Pinned` rods turn about their fixed End A. With `bodyIC static` both start balanced about
  their pins; a pinned rod that carries no line is not part of the static solve and starts at
  rest in its deck orientation, turned by `PtfmInit` for a `CoupledPinned` rod (a dry pendulum
  given at an angle starts at that angle). An end
  of a `Pinned` or `CoupledPinned` rod that carries no line needs no `Rod<ID>A`/`Rod<ID>B` POINT
  row on this route; every other rod needs a line or a POINT row at both ends. Outside a
  coupled host a `CoupledPinned` rod is rejected by name ("requires a coupled host"),
  zero-length ones included;
- `Coupled`/`Vessel` bodies are platform-borne the same way: a mesh node at the body reference
  point, the body frame turning with the platform, returning the force and moment about the
  reference point of its `Body<ID>` lines, weight, buoyancy and restoring, Morison and
  Froude-Krylov loads of the SeaState field, seabed contact, external loads and its rigid-body
  and added-mass inertia (MoorDyn-F's coupled body). They may share a deck with `Free` bodies:
  when the free bodies sub-cycle the coupling step, the host-driven bodies follow the host motion
  interpolated from the step start;
- `CoupledPinned`/`VesselPinned` bodies are pinned to the platform as `CoupledPinned` rods are:
  a mesh node at the body reference point (moved and turned by `PtfmInit` with the body) that
  takes the platform position only. The body turns about it with its own three rotations, the
  node orientation and angular rates are ignored, and the node returns the body's net load less
  its inertia, with no moment (MoorDyn-F's coupled pinned body); the angular acceleration in that
  inertia is solved for the node's current acceleration. With `bodyIC static` the body starts
  balanced about its node. `PtfmInit` turns the body with the platform, as it turns the body's
  attachment points (M^T R0 for the deck orientation R0 and the platform's global-to-local DCM
  M); MoorDyn-F's driver instead starts a coupled pinned body at its deck orientation, so with
  `bodyIC deck` and a rotation in `PtfmInit` the two start from different poses. Outside a
  coupled host such a body is rejected by name ("requires a coupled host");
- cables may be suspended or use the same flat/structured seabed contact, normal damping, and
  stick-slip friction as the standalone Hermite route.

(deck-bodies)=
### BODIES (3D point buoy + 6D rigid body)

A body is a discrete rigid float or buoy that a line end can attach to. A BODIES row has 15
columns, or 18 with the trailing inertias, or the 14 columns of a MoorDyn v2 row (below).

| Column | Meaning |
|--------|---------|
| `ID` | unique body id ≥ 1 (referenced by `Body<ID>` points) |
| `Type` | `Point3` (3-DOF translational buoy or clump), `Rigid6` (6-DOF rigid body), `Coupled`/`Vessel` (a `Rigid6` body whose pose follows the host: the OpenFAST platform, or `motionFile` rows for its `Body<ID>` points in the standalone driver), or `CoupledPinned`/`VesselPinned` (MoorDyn aliases `CpldPin`, `VesPin`: a `Rigid6` body whose reference point follows the OpenFAST platform position while it turns about that point; OpenFAST only) |
| `X,Y,Z` | reference position [m] |
| `Roll,Pitch,Yaw` | reference orientation [deg] (`Rigid6`; ignored for `Point3`) |
| `Mass` | body mass [kg]; > 0 (≥ 0 for `Coupled`/`Vessel` and `CoupledPinned`/`VesselPinned`) |
| `Vol` | displaced volume [m³] (buoyancy ρ_w·g·Vol); ≥ 0 |
| `C33` | heave hydrostatic restoring ρ_w·g·A_wp [N/m] |
| `C44/55` | roll/pitch restoring [N·m/rad] (`Rigid6`) |
| `CdA`, `Ca` | drag area and added-mass coefficient (dynamic); ≥ 0 |
| `Ixx,Iyy,Izz` | trailing diagonal rotational inertias [kg·m²]; required and > 0 for `Rigid6` and `CoupledPinned`/`VesselPinned` (≥ 0, like `Mass`, for `Coupled`/`Vessel`) |

Every body value must be finite. Both body types require a dynamic deck (`dtM`/`TMax`) in the
standalone driver.

The MoorDyn v2 row `ID Attachment X0 Y0 Z0 r0 p0 y0 Mass CG* I* Volume CdA* Ca*` defines a
`Rigid6` body with a centre of gravity: `Attachment` is `Free`, `Coupled`/`Vessel` for a
host-driven body, or `CoupledPinned`/`VesselPinned` for a body pinned to a host node; `CG` is `z`
or `x|y|z` in
the body frame from the reference point (it is also the centre of buoyancy, as in MoorDyn);
`I` is one value or `Ixx|Iyy|Izz` about the CG; `CdA` is one value, `CdA|CdA_rot`, or 3 or 6
entries, and `Ca` one value or 3 entries. The body model is isotropic, so direction-dependent
`CdA`/`Ca` entries and a non-zero rotational drag area fail closed, as do other attachments.

A line's End A attaches to a body through a `Body<ID>` point; the point's position is the
fairlead offset in the body frame.

- A `Point3` body supports exactly one attachment point, which becomes a dynamic point with the
  body's `Mass`/`Vol`/`CdA`/`Ca`. The static solve does not place it: it starts at its deck
  position. Under `bodyIC static` (the default) a run whose buoy is not balanced there notes the
  unbalanced force and the distance to its static balance as a `Free` point; give the deck
  position of that balance, or set `bodyIC deck` to start it off balance on purpose.
- A `Rigid6` body transfers structural force and moment through rigid attachment kinematics, plus
  lumped translational current and wave hydrodynamics from `CdA`/`Ca`. Rotational body
  hydrodynamics are not modelled.
- A `Rigid6` body's weight acts at its centre of gravity and its buoyancy ρ_w g φ `Vol` at its
  centre of buoyancy, where φ is the submerged fraction. With `bodyWetting sphere` (default) φ is
  that of a sphere of volume `Vol` centred at the centre of buoyancy (of projected area `CdA`
  when `Vol` = 0), cut by the local free surface: a dry body carries no buoyancy and the force
  is continuous through the surface. `bodyWetting moordyn` keeps φ = 1 at any elevation, as in
  MoorDyn. A body with `C33`/`C44`/`C55` describes a surface-piercing hull: it keeps the full
  buoyancy of `Vol` (φ = 1) plus the linear restoring of its reference pose, `C33` in heave and
  `C44`/`C55` about the body's own roll and pitch axes (the horizontal projections of its x axis
  and of the perpendicular), so the restoring does not depend on the heading.
- The body takes quadratic drag ½ ρ_w φ `CdA` |u − v| (u − v) on the relative velocity, in
  still water too (u = 0), so `current none` and a zero current give the same body motion; the
  fluid inertia ρ_w φ `Vol` (1 + `Ca`) u̇ (omitted with `bodyHydro moordyn`, as in MoorDyn);
  and the isotropic translational added mass ρ_w φ `Vol` `Ca`, as for a MoorDyn Body with a
  single `Ca`. There is no rotational added inertia.
- A `Rigid6` body has no contact footprint. Its seabed contact is a one-sided penalty at the
  reference point over a fixed reference area of 1 m²: stiffness `kBot`·1 m² [N/m] and
  downward-only damping `cBot`·1 m² [N·s/m]. Resolve a real footprint with the attached lines
  or with rods.
- A standalone dynamic Rigid6 deck with lines and without a `motionFile` or `FAILURE` section
  runs on the [multibody march](#multibody-march) under the default `bodyScheme monolithic`
  (`Point3` buoys, rods and `Connect`/`Free` points may join it), and with
  `bodyScheme staggered` when it also has `Connect`/`Free` points, rods other than `Body<N>`
  rods, or finite-EI lines.

With `motionFile`, a Rigid6 deck prescribes the full 6-DOF body motion from the body's
`Body<ID>` point rows:

- If every attachment row implies the same reference-point translation, velocity, and
  acceleration, the body translates with its deck attitude.
- Otherwise the driver recovers the rigid motion behind the rows: rotation by the Davenport
  q-method on the centred reference→current attachment arms (always a proper rotation, exact for
  planar sets); angular velocity and acceleration by 3×3 least-squares normal equations on the
  centred velocity and acceleration rows.
- It **fails closed** when the attachments are collinear (rotation unobservable; at least three
  non-collinear `Body<ID>` points are needed) or when any row deviates from the recovered rigid
  motion by more than 1e-6 relative to the arm, velocity, or acceleration scale.

### EXTERNAL LOADS

`EXTERNAL LOADS` rows `ID Object Fext Blin Bquad CSys`, in the MoorDyn-F column order, add a
constant force and translational damping to a Rigid6 body (`Object` `Body<N>`): the load
`Fext - Blin v - Bquad |v| v` acts at the body reference point, per axis of the global frame
(`CSys` `G`) or of the body frame (`L`, velocity and force in body axes). `Fext` is `0` or
`f1|f2|f3` [N]; `Blin` [N·s/m] and `Bquad` [N·s²/m²] are one value (all axes) or three,
non-negative. A row whose third token is `G`, `L` or `-` is read in the alternative CableDyn
column order `ID Object CSys Fext Blin Bquad`. IDs run 1, 2, 3, … in row order. Several rows
on one body add up. The damping
enters the body step implicitly. External loads apply to Rigid6 bodies only: a row on a Point3
body is rejected ("EXTERNAL LOADS apply to Rigid6 bodies only"), and rod and point objects are
rejected by name.

### TURBINES (standalone farm decks)

`TURBINES` rows `J X0 Y0 Z0 [PtfmSurge PtfmSway PtfmHeave PtfmRoll PtfmPitch PtfmYaw]` let the
standalone driver run a FAST.Farm deck: every `Turbine<J>` (or `T<J>`) POINT is a coupled
fairlead whose coordinates are turbine-local; it is placed at the farm-global position
`(X0, Y0, Z0) + PtfmInit_J(p)` (the MoorDyn-F initial-displacement transform, angles in
degrees). Turbines not in the section are an error naming the point. With a `motionFile`, the
rows are per-turbine rigid-body records
`time J x y z q0 q1 q2 q3 vx vy vz wx wy wz ax ay az alx aly alz` (reference position,
unit quaternion, velocity, angular velocity, and their rates); each Turbine<J> fairlead
follows `x + R(q) p`, with the rigid-body velocity and acceleration. A finite-EI line end on a
`Turbine<J>` point takes its `END CONNECTIONS` direction `Ez` and torsion normal `Nx` in that
turbine's axes: turned by the `PtfmInit` rotation at the static start and by `R(q)`, with the
row's angular velocity and acceleration, in the run (End A and End B alike), as the FAST.Farm
host's orientations turn them. A `TURBINES` deck that mixes `EI = 0` lines and finite-EI cables (a
power cable shared by two turbines beside their chain legs) runs on the standalone mixed route,
the aggregate of FAST.Farm, with the same placement, records and end frames as the decks of its
cables alone and of its `EI = 0` lines alone. In FAST.Farm the host supplies the turbine positions
and the section is not used.

### ROD TYPES + RODS (rigid cylindrical rods)

Dynamic decks support free, fixed, pinned, and prescribed rigid cylindrical rods, rods fixed
to a Rigid6 body, rods pinned to a Rigid6 body, and zero-length rods. Lines attach to a rod end
directly with `R<N>A`/`R<N>B` (also `Rod<N>A`/`Rod<N>B`) in the LINES attachment columns, as in
MoorDyn, or through POINT rows of type `Rod<ID>A` and `Rod<ID>B` (at most one of each per rod).
Those POINT coordinates must be finite but are replaced by the rod end coordinates. A line
attached to an end of a rod fixed to a body loads the body at that end. Free, fixed, pinned and
prescribed rods with lines may share a deck with bodies and `Connect`/`Free` points (the
[multibody march](#multibody-march)), except that prescribed (`Coupled`/`Vessel`) rods need
`motionFile`, which that march does not take. Rods require a dynamic deck (`dtM`/`TMax`) in the
standalone driver.

A deck may consist of bodies and rods alone, without LINE TYPES, POINTS, LINES, or SECTIONS
(for example a floating spar or a pendulum). Its objects are integrated with the explicit
central-difference scheme, or with the monolithic implicit step when the deck names
`monolithic bodyScheme`; with `bodyIC static` a floating body starts
at its hydrostatic equilibrium in heave, roll, and pitch (its horizontal position and heading,
which nothing restrains, are kept). Such a deck writes `Body<N>` and `Rod<N>` channels only.

`ROD TYPES` (7 columns, as in MoorDyn, or 9 with the CableDyn axial side coefficients):

| Column | Meaning |
|--------|---------|
| `Name` | rod type key (unique) |
| `Diam` | cylinder diameter [m]; > 0 |
| `Mass` | dry mass per unit length [kg/m]; > 0 |
| `Cd`, `Ca` | transverse drag / added-mass coefficients; ≥ 0 |
| `CdEnd`, `CaEnd` | end drag / end added-mass coefficients (MoorDyn); ≥ 0 |
| `CdAx`, `CaAx` | optional columns 8–9: axial side drag / added-mass coefficients (CableDyn extension, default 0 as in MoorDyn); ≥ 0 |

Columns 6–7 are always MoorDyn's `CdEnd CaEnd`. A header row naming axial coefficients
(`CdAx`, `CaAx`) in columns 6–7, the column order of earlier CableDyn decks, is rejected with a
migration message: move those values to columns 8–9 and set `CdEnd CaEnd` (0 keeps the earlier
model). A section without a header row uses the MoorDyn meaning.

Rod loads are integrated over the rod's `NumSegs` segments. Each cross-section is wet over the
part below the local free surface (a circular segment when the rod is inclined), and buoyancy,
drag, Froude–Krylov, and added mass scale with that wet fraction. Buoyancy acts at the centroid of
the wet part, so a surface-piercing rod carries the exact hydrostatic force and waterplane
restoring of the displaced cylinder (second moment π d⁴/64) at any tilt, continuously as it
submerges or emerges. A wet length element dl carries the translational added mass
ρ_w A dl [`Ca` (I − a aᵀ) + `CaAx` a aᵀ] (a = rod axis), as in a MoorDyn Rod, attached at its
offset from the rod centre, which gives the rotational added inertia `Ca` ρ_w A ∫ s² ds about the
transverse axes (`Ca` ρ_w A L³/12 for a fully submerged rod) and the matching
translation–rotation coupling. There is no added inertia about the rod axis. Drag and fluid
inertia are evaluated at two Gauss points per wet segment part; with deck waves the free surface
is taken linear between the segment ends, so use more segments for waves shorter than about
10 rod segments.

Each rod end carries MoorDyn's end effects, scaled by the wet fraction of its end cap: the axial
added mass ρ_w `CaEnd` V_end a aᵀ with V_end = (2/3) π (d/2)³, the axial drag
½ ρ_w `CdEnd` A |u_a| u_a (A = π d²/4, u_a the axial relative flow velocity) and the axial fluid
inertia ρ_w `CaEnd` V_end (u̇·a) a. With deck waves each wet end cap also carries the linear wave
dynamic pressure, which gives the axial Froude–Krylov force (the side then carries only the
`CaAx` part of the axial fluid inertia). These act along the axis through the rod centre, so they
carry no moment about it. In a coupled run the host (SeaState) fluid is sampled at the `NumSegs` + 1
segment ends of each rod, End A to End B, and interpolated linearly along the rod; the end caps
carry the sampled wave dynamic pressure, as with deck waves.

Rod seabed contact is distributed along the rod. `kBot` and `cBot` are per unit contact area, as
for line nodes. Each of n + 1 stations (End A, End B, and the interior points of n = max(20,
`NumSegs`) equal segments) carries a spring `kBot`·d·Δl and a downward-only damper `cBot`·d·Δl
over its tributary length Δl (L/n inside, L/(2n) at the ends). The resulting forces and moments
about the rod centre support a
rod lying on the bed along its whole length.

`RODS` (10 columns, or 11 with `Outputs`):

| Column | Meaning |
|--------|---------|
| `ID` | unique rod id ≥ 1 |
| `RodType` | a `ROD TYPES` key |
| `Type` | `Free`, `Fixed`, `Pinned`, `Coupled`, `Vessel`, `CoupledPinned`, `VesselPinned`, `Body<N>`, or `Body<N>Pinned` (MoorDyn aliases `Anchor`/`Fix`, `Pin`, `Point`/`Con`, `Ves`, `Cpld`, `CpldPin`, `VesPin`, `Body<N>Pin`). `Coupled`/`Vessel` rods are prescribed by `motionFile` rows for both `Rod<N>A` and `Rod<N>B`, which must preserve the rod length; in OpenFAST (`CompMooring = 5`) they follow the platform instead (see the OpenFAST route above). `CoupledPinned`/`VesselPinned` rods run only in OpenFAST, pinned at End A to a node that follows the platform position. `Free` rods are integrated dynamically and may coexist with prescribed rods. A `Pinned` rod turns about its End A, which stays fixed; it may carry lines. A `Body<N>` rod is fixed to Rigid6 body N: its end coordinates are in the body frame from the body reference point, and its mass, inertia, hydrostatic, Morison, and seabed loads and added mass are lumped into the body about that point. A `Body<N>Pinned` rod has its end coordinates in the body frame too, but only its End A is held, on the body: the rod has its own three rotations, its loads reach the body as the pin force (no moment), and it may carry lines. |
| `XA,YA,ZA` | rod End A coordinates [m] |
| `XB,YB,ZB` | rod End B coordinates [m]; distinct from End A (ignored for a zero-length rod) |
| `NumSegs` | ≥ 1; hydrodynamic segments of the rod (loads integrated per segment); seabed contact uses max(20, `NumSegs`) segments. `0` declares a zero-length rod (MoorDyn): a point-like connector at End A with no mass, volume or side loads and, having no axis, no end loads either. It becomes one point that both of its ends resolve to: `Free` for a free rod, `Fixed` for a fixed or pinned rod, `Coupled` for a coupled rod or, in OpenFAST, a `CoupledPinned` rod, `Body<N>` for a rod on body N. A free zero-length rod therefore moves with the end-node mass of its lines, as a `Mass = 0` `Free` point, and `Rod<N>` output channels of it are rejected by name (use `Point<P>` channels) |
| `Outputs` | `-` or `p`; `p` writes the end positions as a time series to `<out_root>.Rod<ID>.p.out`, End A first |

### POINTS

A POINTS row has 9 columns, `ID Type X Y Z Mass Vol CdA Ca`, or the short 5-column form
`ID Type X Y Z`, which sets `Mass`, `Vol`, `CdA`, and `Ca` to zero. Point ids are unique integers
≥ 1; every value must be finite.

| `Type` | Meaning | Data used |
|--------|---------|-----------|
| `Fixed` | anchor held at (X,Y,Z) | X,Y,Z |
| `Coupled` | fairlead driven by a host or by prescribed motion | X,Y,Z (held for static; motion file for dynamic) |
| `Vessel` | alias of `Coupled` (MoorDyn) | X,Y,Z |
| `Body<N>` | line end on body N; (X,Y,Z) is the attachment offset in the body frame | X,Y,Z offset; the body supplies Mass/Vol/CdA/Ca |
| `Rod<N>A` / `Rod<N>B` | line end on rod N End A / End B; coordinates come from the `RODS` row | X,Y,Z placeholders; zero Mass/Vol/CdA/Ca |
| `Connect` | free internal point where ≥ 2 lines meet; its static position is solved from force balance (lines, weight/buoyancy, current drag) starting at the deck seed, and the march starts there | X,Y,Z seed; Mass, Vol, CdA, Ca ≥ 0 |
| `Free` | free line end (clump or float terminal); a one-line `Connect`, solved the same way | X,Y,Z seed; Mass, Vol, CdA, Ca ≥ 0 |
| `Turbine<J>` / `T<J>` | FAST.Farm coupled point on turbine J (turbine-local coordinates) | X,Y,Z; zero Mass/Vol/CdA/Ca |

For dynamic `Connect`/`Free` points, `Mass` is inertial mass and `(rhoW·Vol − Mass)·g` is a
constant vertical load. A `Mass = 0` junction is accepted; it moves with the end-node mass of its
lines. `CdA` adds lumped drag and `Ca` lumped added mass in EI = 0 dynamic runs with uniform or
profile current or deck waves. A `Connect`/`Free` point with `Mass` or `Vol` (a clump weight or
a buoy) has its own seabed contact, the line contact law with stiffness `kBot·A` and damping
`cBot·A` over the footprint `A = V^(2/3)`, where `V = Vol`, or `Mass/7850` (solid steel) when
`Vol = 0`; a point with neither has none. A `Point3` buoy has the same contact over the footprint
of its BODY `Mass`/`Vol` (see the theory manual, Seabed contact).
`Connect`/`Free` points require `dtM`/`TMax` in the
standalone driver. Non-zero `Mass`/`Vol`/`CdA`/`Ca` on `Fixed`, `Coupled`, `Vessel`, `Body<N>`,
`Rod<N>A/B`, or `Turbine<J>` points is rejected.

`Turbine<J>` points (J ≥ 1) need the turbine reference positions from one of two sources: the
OpenFAST/FAST.Farm aggregate route, where the host supplies them, or a
[TURBINES](#turbines-standalone-farm-decks) section, with which the standalone driver runs the
farm deck. A deck with `Turbine<J>` points and neither source is rejected, naming the point
type, rather than solving turbine-local coordinates as global ones.

(lines-sections)=
### LINES + SECTIONS

A `LINES` row declares a line and its two end points. The line's geometry is the ordered list of
its `SECTIONS` rows, matched by `LineID`. The unstretched length is the sum of the section
lengths; mesh density is set per section. LINES accepts three row forms:

| Columns | Form | Meaning |
|---------|------|---------|
| 3 | `ID NodeA NodeB` | CableDyn line; `Outputs` defaults to `-` |
| 4 | `ID NodeA NodeB Outputs` | CableDyn line with per-line output flags |
| 7 | `ID LineType AttachA AttachB UnstrLen NumSegs Outputs` | stock MoorDyn v2 row; equal to a 4-column row plus one implicit `SECTIONS` row `ID LineType UnstrLen NumSegs` |

In the 3/4/7-column forms, `AttachA`/`AttachB` are POINT ids or rod ends `R<N>A`/`R<N>B`
(`Rod<N>A`/`Rod<N>B`). A body attachment goes through a `Body<N>` POINT. A line is defined either by
a 7-column row or by a 3/4-column row plus `SECTIONS` rows,
never both: a `SECTIONS` row for a 7-column line is an error naming the line.

`LINES` columns:

| Column | Meaning |
|--------|---------|
| `ID` | unique line id ≥ 1 |
| `NodeA`, `NodeB` | End A / End B POINT ids (distinct). **End A is the fairlead (top) end and End B the anchor (lower) end**, as in OrcaFlex. |
| `Outputs` | per-line file flags. `-` = none. `p` (node positions) and `t` (segment tensions) write `<out_root>.Line<ID>.p.out` / `.t.out`, End A first. Static EI = 0 decks write node/segment tables; independent EI = 0, point-system EI = 0, independent finite-EI, rod, and Rigid6 dynamic decks write time series (one row per output time). `r` writes the range graph `<out_root>.Line<ID>.range.out`: the minimum, maximum and mean over the run (from `RangeStart`) of the node tension, curvature, bend moment, declination and seabed clearance (and torque and twist on a line with torsion), on every standalone route and in a single-turbine OpenFAST run (`<RootName>.CD.Line<ID>.range.out`); a FAST.Farm shared mooring and the C API reject it. Line-node channels in the main `.out` file are requested in `OUTPUTS`. |

**Automatic anchor-first swap.** Stock MoorDyn decks list lines anchor first. When a line's
`NodeA` is a `Fixed` point and its `NodeB` is a `Coupled`, `Vessel`, `Body<N>`, `Free`, or
`Connect` point (`Turbine<J>` points count as coupled), or a finite-EI line's `NodeB` is a rod
end (`R<N>A`/`R<N>B`), the parser swaps the two ends, reverses that line's `SECTIONS` rows, and
swaps its `END CONNECTIONS` ends, negating their reference directions and pretwists (the
torsion normals swap with their ends). Lines already listed fairlead first, `EI = 0` lines to a
rod end, and `Free`/`Connect`-to-`Coupled` lines are left as written.

**Endpoint rules.**

- In a deck without dynamic points (`Connect`, `Free`, `Body<N>`, or `Rod<N>A/B`), End A must be a
  `Coupled`, `Vessel`, or `Body<N>` point and End B a `Fixed` point. A fairlead below its anchor
  fails with `LINE End A fairlead (NodeA) must not be below End B anchor (NodeB)`. The exceptions
  are a FAST.Farm shared line with both ends on `Turbine<J>` points and a finite-EI line whose End
  B is also a `Coupled`/`Vessel` point (a line between two moving points, driven at both ends).
- In a deck with dynamic points, line ends may be `Fixed`, `Coupled`, `Vessel`, `Connect`, `Free`,
  `Body<N>`, or `Rod<N>A/B`.

`SECTIONS` (4 columns; at least one row per line, listed from End A to End B):

| Column | Meaning |
|--------|---------|
| `LineID` | the owning `LINES` id |
| `LineType` | a LINE TYPES key |
| `Length` | section unstretched length [m]; > 0 and at most 1e6, with `Length/NumSegs` at least 1e-6 |
| `NumSegs` | section element count, 1 to 1 000 000. A finite-EI line needs far fewer: its static solve is verified up to 20 480 elements on the 80 m reference cable (elements of about 8 mm) and does not converge at 40 960 (about 4 mm). Keep finite-EI elements longer than about `sqrt(EI/EA)`, and refine only where the curvature needs it |

A single-material line is one `SECTIONS` row; a bare cable with a buoyancy stretch is three sections
of one line (bare, buoyant, bare). A bend stiffener over a line end is a
[STIFFENERS](#stiffeners-optional-finite-ei-lines) row, not a section.

- A standalone deck with a finite-EI section needs `dtM`/`TMax`, unless it is a mixed
  `EI = 0` + finite-EI deck, which may be static-only.
- On the cubic-Hermite route a finite-EI line starts from the exact EI = 0 catenary of its
  sections (buoyant lazy-wave sections included) and reaches its bending equilibrium by
  continuation in EI; the mesh-sequenced route is its fallback (`cable_statics`, and the
  Hermite path in [theory](theory.rst)).
- `WtrDpth`, `bathymetryFile`, `kBot`, and `cBot` add one-sided normal seabed contact where
  supported; `current`/`waves` add translational Morison and Froude–Krylov loads at element
  midpoints; `frictionMu` adds stick-slip seabed friction on finite-EI touchdown.
- Net-buoyant EI = 0 sections are rejected; model them as finite-EI lazy-wave sections.

### SYROPE IC (optional, Syrope lines)

`SYROPE IC` supplies the prior load history of path-dependent polyester lines. It must come
**after** the `LINES` section that defines the referenced lines.

```text
--------------------- SYROPE IC ----------------------------------------
Line(s)   Tmax0    Tmean0
(-)       (N)      (N)
1,2       3.53e6   1.18e6
```

The last two tokens are `Tmax0 Tmean0`; the tokens before them form the line list. Line ids are
comma-separated (`1,2` or `1, 2`); ids separated only by spaces are rejected. Values must satisfy
`Tmax0 >= Tmean0 >= 0` and `Tmax0 > 0`, and be finite. Every referenced line must have a
Syrope section, and be named in only one row. On a composite line the history applies to every
Syrope section.

`Tmax0` is the rope's running maximum tension. The static initial condition is solved on its
rest curve, the working curve regenerated at `Tmax0` (the OWC beyond that curve's top strain).
Every element starts with the slow strain whose tension equals its static tension. t = 0 is
therefore the static equilibrium, with no initial transient. An element whose static tension
exceeds `Tmax0` sits on the OWC and raises its running maximum to that tension. With fixed
line ends, the geometry and `Tmax0` set the mean tension, so `Tmean0` is accepted for MoorDyn
compatibility but does not enter the state. If it differs from the static mean tension by more
than 1 %, the driver prints the static value on the console. A line whose initial strain is below
the zero-tension strain of the `Tmax0` working curve is slack on that history, and
initialisation stops with an error. Without a `SYROPE IC` row, a Syrope line starts as a virgin
rope: its static solve uses the OWC, and each element's running maximum is its static tension.

### END CONNECTIONS (optional, finite-EI lines)

`END CONNECTIONS` sets the bending boundary at either end of a finite-EI line. Omitted ends are
pinned. At most one row may name a given line end. A non-pinned connection requires a finite-EI
line whose End B is a `Fixed` point or a `Coupled`/`Vessel` point, whose connection is held by
that point's parent and turns with it as End A's does (the `vesselMotion`/`vesselRAO` vessel
standalone, the host orientation of End B's point when coupled), or a Rigid6 `Body<N>` point or a
rod end on the [multibody march](#multibody-march) (a line between two objects, whose connection
turns with End B's object); any other End B fails deck validation. End A may be a `Fixed` or
`Coupled` point, a Rigid6 `Body<N>` point or a rod end.

```text
--------------------- END CONNECTIONS -------------------------------
LineID  End  Stiffness  EzX       EzY  EzZ
(-)     (-)  (N-m/rad)  (-)       (-)  (-)
1       A    2.0e4      -0.25     0.0  -0.97
1       B    Rigid       1.0      0.0   0.0
```

| Column | Meaning |
|--------|---------|
| `LineID` | existing `LINES` id |
| `End` | `A`/`EndA`/`End_A` or `B`/`EndB`/`End_B` |
| `Stiffness` | finite bending stiffness ≥ 0 [N·m/rad], `Pinned`/`Free`/`Zero`, or `Rigid`/`Infinity`/`Inf`; a numeric `0` is pinned |
| `EzX`, `EzY`, `EzZ` | non-zero reference direction, normalised by the parser |

Behaviour:

- The direction follows the End A → End B line convention. At a coupled end it is stored in the
  platform frame and rotates with the OpenFAST orientation input. In the standalone driver
  `motionFile` prescribes translation only, so the direction stays fixed in global axes;
  with `vesselMotion` or `vesselRAO` it is stored in vessel axes (equal to global axes at the
  reference pose) and turns with the vessel.
- The connection moment equals the bending moment of the line at its end node, so
  `BendMom<L>N1` (End A) and `BendMom<L>N<NumSegs+1>` (End B) report it; under a bend stiffener
  it is `BendMom` plus `StfMom` at that node.
- On a `Body<N>` point the direction is given in the body frame, like the point offset, and
  turns with the body. On a rod end it must be parallel to the rod axis (either sense, in the
  frame of the rod's deck coordinates); another direction is rejected by name. The connection
  moment is part of `Body<N>M*`/`Rod<N>M*` (of both on an end of a rod fixed to a body), and the
  body or rod carries it in the dynamics and in the static solve.
- A finite stiffness is an isotropic rotational spring on the tangent direction; the tangent
  magnitude stays free.
- `Rigid` is an exact two-coordinate direction constraint, not a large penalty; the tangent
  magnitude remains a solved axial degree of freedom.
- `Pinned` adds no spring and no moment; it is identical to omitting the row.
- Connection moments are included in the OpenFAST coupled-load mesh.

Rows on an `EI = 0` line, duplicate rows, unknown line ids, null directions, negative stiffnesses,
and non-finite values fail deck validation. OpenFAST linearisation with a `Rigid` end connection
is rejected at initialisation.

#### Torsion columns

Four or five optional columns restrain the twist of a finite-EI line end (rows of 10 or 11
columns; the 6-column rows keep their meaning):

```text
--------------------- END CONNECTIONS -------------------------------
LineID  End  Stiffness  EzX  EzY  EzZ   TorsStiffness  NxX  NxY  NxZ  Pretwist
(-)     (-)  (N-m/rad)  (-)  (-)  (-)   (N-m/rad)      (-)  (-)  (-)  (deg)
1       A    Rigid      1.0  0.0  0.0   Rigid          0.0  0.0  1.0  0.0
1       B    Rigid      1.0  0.0  0.0   Rigid          0.0  0.0  1.0  720.0
```

| Column | Meaning |
|--------|---------|
| `TorsStiffness` | `Free`/`Zero`/`0` (default, no torsional restraint), `Rigid`/`Infinity`/`Inf` (any case), or a positive torsional end spring [N·m/rad], a plain finite number |
| `NxX`, `NxY`, `NxZ` | zero-twist reference normal of the end, in the frame of `Ez`; finite numbers; at a restrained end non-zero and not parallel to `Ez` (within about 0.06°), orthonormalised against `Ez` by the parser |
| `Pretwist` | optional roll of the end frame about `Ez` [deg, right-handed, default 0]; any finite value, several turns included, with the imposed twist `Pretwist(B) − Pretwist(A)` within 1000 turns (360 000°) |

At a `Free` end the normal and `Pretwist` are only checked to be finite numbers; they are not
used.

Behaviour:

- Torsion is solved on a line restrained at both ends, and on a line restrained at **one** end
  whose other end is free to twist (`TorsStiffness` `Free` there, or no row), under the rules
  below. A free end carries no torque. In statics the line then has none, and its static state
  is that of the line without the columns; under torque–tension coupling (`GJ|K`) the stretch
  twists it by `Twist<L> = −Σ (K/GJ)(l − L)` over the elements (`l` stretched, `L`
  unstretched). `Twist<L>` keeps its sign, the turn of End B relative to End A, right-handed
  about the End A → End B tangent: a free End B turns by `+Twist<L>` against End A's frame
  carried along the line, a free End A by `−Twist<L>` against End B's. In the dynamics the
  polar inertia `Irn` carries torsional waves that reflect at the free end, and the restrained
  end (and the body or vessel holding it) takes their torque. The free end's `Nx` and
  `Pretwist` are not used. The section axes of `CurvX`/`CurvY` start, with End A restrained,
  from End A's `Nx` (not rolled by its `Pretwist`, as on a line restrained at both ends) and,
  with End B restrained, from End B's `Nx` rolled by End B's `Pretwist`; either way they are
  carried along the line and turned by its twist. `ATTACHMENTS`, `CONTROL`, `nModes` (the
  free end's angle is a mode coordinate, with the clamped–free modes) and OpenFAST
  linearisation (the free end's angle is a state) take such a line as they take one
  restrained at both ends. A line restrained at one end that misses a rule (its `LINE TYPES`
  rows give no `GJ`, two moving ends, a dynamic or coupled run with `False alpha_force_blend`,
  a restrained End A on a rod end other than a `Fixed` rod's or on a non-Rigid6 body) is
  solved as without the columns, and the standalone driver prints a note with the reason. A
  solved one's imposed twist, its restrained end's `Pretwist`, must lie within 1000 turns, as
  `Pretwist(B) − Pretwist(A)` must on a line restrained at both ends. A line restrained at End A
  on a Rigid6 body joins the static balance of the body's clamped and elastic ends, also at a
  bending-`Pinned` End A (the body takes its torque).
  `Free` columns, or no columns, reproduce the 6-column results exactly.
- The imposed twist is `Phi = Pretwist(B) − Pretwist(A)`, measured against the line's own
  geometric twist `Theta`, the parallel-transport rotation of the End A normal carried along the
  centreline to End B (zero for a line that stays in a plane, with both normals perpendicular to
  that plane). The torque is uniform along the line, `M = (Phi − Theta)/C`, with the compliance
  `C = Σ L/GJ` over the sections plus `1/k` of each torsional end spring. Positive torque is a
  right-handed twist of End B relative to End A about the End A → End B tangent (OrcaFlex's
  sign). A non-planar line has `Theta ≠ 0` in its untwisted shape; to start it free of torque,
  set the End B pretwist to minus the static `Twist<L>` of a run with zero pretwist (in degrees);
  the line then keeps its untwisted shape.
- The torsion end frame turns with what carries the end: a Rigid6 body, the vessel of
  `vesselMotion`/`vesselRAO`, or nothing at a `Fixed` or held point or on a `Fixed` rod. The
  `motionFile` roll column rolls the frame of the line's moving end
  ([Prescribed motion](#prescribed-motion-motionfile)).
- On a rod end (an I-tube or J-tube modelled as a rod), `Ez` lies along the rod axis and `Nx`
  is given in the frame of the rod's deck coordinates, as `Ez` is. A `Fixed` rod holds the frame
  still, and its `Rod<N>M*` carries the torque about the line axis. The ends of a rod fixed to a
  Rigid6 body (`RODS` type `Body<N>`) are points of the body: `Ez` and `Nx` are given in the body
  frame, the frame rolls with the body, and the torque reaches the body (`Body<N>M*`) and appears
  in the rod's `Rod<N>M*`.
- A Rigid6 body holding such a line turns by less than 90° per step: a step whose turn would be
  larger is halved (the twist is read from the body's orientation, which repeats every turn), and
  a run that still needs more after six halvings stops by name; reduce `dtM`.
- Torsion may be restrained at a bending-`Pinned` end. The torque then passes through a
  constant-velocity-joint idealisation: the end frame is carried from `Ez` to the line tangent by
  the smallest rotation, so the end transmits the torque *semi-tangentially*, not as Greenhill's
  axial-torque hinge. A straight rod with two such ends buckles at `M = 4.9113 EI/L` at zero
  tension (`7.2693 EI/L` at `T L²/EI = 10`), not `2π EI/L`; clamped ends buckle at
  `8.9868 EI/L` (see [theory](theory.rst)).
- The torque returns to a Rigid6 body at End A, in the static body equilibrium and in the
  dynamics; it is part of `Body<N>M*`.
- Statics solve the imposed twist as the last load stage, in steps of at most 45°, test every
  stage for stability and, above a buckling onset, leave the unstable straight state for the
  buckled one. Dynamics carry the torsion in every step with a twist angle at every node and the
  polar inertia `Irn` of the `LINE TYPES` row (see [theory](theory.rst)).

Scope. A torsionally restrained line needs a finite-EI line with a `Fixed` End B or, restrained
at both ends, a `Coupled`/`Vessel` or Rigid6 `Body<N>` End B (both end frames then turn with
their parents, and standalone the `motionFile` roll column rolls either end: `Φ = Pretwist(B) −
Pretwist(A) − roll(A) − roll(B)`, each roll about the tangent pointing into the line from that
end), an explicit `GJ` on every section, and, at End A, a `Fixed`, `Coupled`/`Vessel` point, a
Rigid6 `Body<N>` point (the ends of a `Body<N>` rod included) or an end of a `Fixed` rod (with a
`Fixed` End B); in a coupled OpenFAST or FAST.Farm run the End A frame turns with the platform
(see the manual's OpenFAST page, Line torsion). Each of the following stops with a named error:
torsion on an `EI = 0` line, on an end of a `Free`, `Pinned`, `Body<N>Pinned` or `CoupledPinned`
rod (an axisymmetric rod has no roll angle about its own axis: no load acts about the axis and
its static solve has none, so it cannot hold the torque) or of a `Coupled`/`Vessel` rod (no route
carries a finite-EI line on a host-driven rod), at End B on a rod end (a line between two rods:
restrain it through End A, or put a `Fixed` point at the rod end), on a `Point3` body, a dynamic
or coupled run with `False alpha_force_blend`, any restrained end (one end included) through the
C API's `CableDyn_InitDeck`/`InitDeckAt`, which move the line ends by translation only (`a line
restrained in torsion needs a host that turns its fairlead frame ...`; a C API host passes its
rotations after `CableDyn_InitDeckRotating`), and a `Torq`/`Twist` channel on a line whose
torsion is not solved. OpenFAST linearisation includes the twist angles as states; like any
cable, the line must not have a `Rigid` bending connection there, nor a second moving end. Seabed
friction does not resist twist (the laid part of a line twists freely).

### EQUIVALENT BUOYANCY (optional)

Specifies a cable section by its target submerged weight per metre instead of its dry mass. Rows
are applied after `OPTIONS`, using the final `rhoW` and `g`, and rewrite the named line type's
`Diam` and `MassDenInAir` before validation. The rewritten line type is then used through the
ordinary `SECTIONS` table; no discrete buoy object is created.

```text
--------------------- EQUIVALENT BUOYANCY -----------------------------
LineType  Diam  SubmergedWeightNpm
(-)       (m)   (N/m)
power     0.50  -1483.0
```

| Column | Meaning |
|--------|---------|
| `LineType` | existing `LINE TYPES` key to rewrite |
| `Diam` | equivalent hydrodynamic / displaced-volume diameter [m] |
| `SubmergedWeightNpm` | target net submerged weight [N/m]; positive downward, negative for uplift |

A row fails if the line type is unknown or duplicated, a value is non-finite, or the result would
need a negative dry mass. Net-buoyant EI = 0 sections are still rejected (see
[LINES + SECTIONS](#lines-sections)).

### ATTACHMENTS (optional, finite-EI lines)

Discrete buoyancy modules and clump weights on a finite-EI line, the alternative to a smeared
[EQUIVALENT BUOYANCY](#equivalent-buoyancy-optional) section. Each attachment is a point load
at a node of the cable, not a separate object: there is no Connect point, and its loads enter
the cable's own static and dynamic equations.

```text
--------------------- ATTACHMENTS ----------------------------------
LineID  ArcLength        Mass    Volume   CdA     Ca    CdAx
(-)     (m)              (kg)    (m^3)    (m^2)   (-)   (m^2)
1       42.5:5.0:87.5    114.15  0.2297   0.78    1.0   0.204
1       120.0            800.0   0.0      0.3     0.0
```

| Column | Meaning |
|--------|---------|
| `LineID` | existing `LINES` id of a finite-EI line |
| `ArcLength` | unstretched arc length from End A [m], or a series `first:pitch:last` (inclusive) of identical attachments |
| `Mass` | dry mass [kg] |
| `Volume` | displaced volume [m³] (buoyancy `rhoW g Volume`) |
| `CdA` | drag area normal to the line [m²] |
| `Ca` | added-mass coefficient on `rhoW Volume`, in every direction |
| `CdAx` | optional drag area along the line [m²]; default 0 |

The drag acts on the fluid velocity relative to the node, `w = u − v`, split into its parts
normal (`w_n`) and along (`w_t`) the line tangent at the node:
`½ rhoW (CdA ‖w_n‖ w_n + CdAx ‖w_t‖ w_t)`. This is the line's own Morison law per metre with
`CdA = Cd_n d` and `CdAx = π Cd_t d`, so a module that adds the diameter `d_m − d` over a
pitch `p` carries `CdA = Cd_n (d_m − d) p` and `CdAx = π Cd_t (d_m − d) p` and matches the
smeared section in a current.

Behaviour:

- An attachment acts at the node nearest its arc length; the initialisation note reports the
  largest distance between an attachment and its node. Mesh the line so that nodes fall at the
  attachments, with several elements between neighbouring attachments to resolve the curvature
  between them.
- Loads: the net weight `(Mass − rhoW Volume) g` downward; with the dry mass, the added mass
  `Ca rhoW Volume` (a constant nodal mass); the fluid-inertia force
  `rhoW Volume (1 + Ca) du/dt` and the drag against the current and wave velocity at the node.
  A deck current (a `current` row, uniform or profile, or a MoorDyn-C `Currents` field at
  `t = 0`, sampled at the attachment node) loads the attachments in the static initial condition
  with the same drag law at rest, so a run in a current starts in equilibrium.
  An attachment above the free surface carries its weight only, in the static initial condition
  too. Attachments have no seabed contact of their own; the node's contact acts on the line.
- The static equilibrium is solved first with each attachment's net weight, and in a current
  across the vertical plane of the line its drag areas, spread over the two elements at its node,
  then carried to the discrete loads by continuation. The current drag
  depends on the node's position and line direction, and the weight on the side of the surface
  an attachment is on, so the final solve is repeated until the node positions change by less
  than 1e-9 m and no attachment changes side. A residual floor above the tight static tolerance
  is accepted at the coupled static tolerance 1e-6, as on a line without attachments, and noted
  with the residual reached. On a line restrained in torsion the torsion stage
  (the imposed twist) follows on the discrete equilibrium, with the attachments' net weights
  and drag as nodal loads (the drag again to a fixed point), so a run starts in the twisted
  equilibrium. An attachment adds no polar inertia to the line's twist.
- A row fails if the line is not finite-EI, the arc lies beyond the line, every one of `Mass`,
  `Volume`, `CdA` and `CdAx` is zero, a value is negative or non-finite, or a series has a
  non-positive
  pitch or `first > last`. A stock-order line (anchor as `NodeA`) measures the arc from that
  anchor. Attachments run on the cubic-Hermite cable route, standalone (End A `Coupled`/
  `Vessel` or `Fixed`, End B `Fixed`, `Coupled` or `Vessel`) and coupled (OpenFAST
  `CompMooring = 5`, the C API and Python), where the SeaState kinematics the host samples at
  every cable node reach the attachments at theirs; a checkpoint restart is bit-identical.

### STIFFENERS (optional, finite-EI lines)

A bend stiffener: a tapered polyurethane sleeve over a line end, usually at a hang-off, that
spreads the bending of the cable over its length. The sleeve is not a separate object; it adds
its bending stiffness, mass, buoyancy and drag to the elements it covers. Each row is one
conical segment, and the rows of one line end follow each other outward from the stiffener
root, each starting where the previous one ends. A cylindrical root, a cone and a tip are three
rows.

```text
--------------------- STIFFENERS ------------------------------------
LineID  End  Length  RootOD  TipOD  InnerD  E       Density
(-)     (-)  (m)     (m)     (m)    (m)     (Pa)    (kg/m^3)
1       A    0.4     0.45    0.45   0.17    5.0e7   1150
1       A    3.6     0.45    0.18   0.17    5.0e7   1150
```

| Column | Meaning |
|--------|---------|
| `LineID` | existing `LINES` id of a finite-EI line |
| `End` | the end the stiffener sleeves: `A` or `B` (also `EndA`, `EndB`) |
| `Length` | length of the segment along the line [m] |
| `RootOD` | outer diameter at the segment's root side [m] |
| `TipOD` | outer diameter at the segment's tip side [m]; the diameter varies linearly in between |
| `InnerD` | inner (bore) diameter [m], smaller than both outer diameters |
| `E` | Young's modulus of the sleeve material [Pa] |
| `Density` | density of the sleeve material [kg/m³] |

Behaviour:

- Over the stiffener the section bends as cable and sleeve together:
  `EI(s) = EI_cable + E π/64 (OD(s)⁴ − InnerD⁴)`. The sleeve carries no axial load and no
  torque, so `EA` and `GJ` are the cable's. Each element takes the compliance average of
  `EI(s)` over its length, `L / ∫ ds/EI(s)`, the cable mass plus the mean sleeve mass, a
  diameter of the displaced area of cable plus solid sleeve, `√(d² + OD² − InnerD²)`, for its
  buoyancy, added mass and drag alike, as a line type has one diameter (the sleeve's outer
  diameter when `InnerD` is the cable diameter; see [theory](theory.rst), *Bend stiffeners*). Elements the stiffener does not reach keep
  their line type's values exactly.
- The element properties are piecewise constant, one value per deck element, so the deck mesh
  must resolve the taper: an initialisation note names a stiffener that spans fewer than 10
  elements and the element length that resolves it. Split the section at the stiffener tip and
  mesh the part under it finely (about 0.1–0.2 m elements for a typical 3–8 m stiffener). The
  node outputs and the element peaks of `.elements.out` do not take these element values: they
  read `EI(s)` at their own arc, and at a real step of the section (the tip, rows that do not
  match, two line types) the softer side's.
- The stiffener root takes the moment only where the end is held in rotation: declare the end
  `Rigid`, or a rotational spring, in [END CONNECTIONS](#end-connections-optional-finite-ei-lines).
  A stiffener at a pinned end prints a note.
- Outputs: `Curv<L>N<J>` is the curvature cable and sleeve share; `BendMom<L>N<J>` the cable's
  own moment (the line type's `EI` × curvature, the value to check against the cable's limits);
  `StfMom<L>N<J>` the sleeve's share, so that the two add up to the section moment the root
  connection carries. `FairDefl<L>`/`AnchDefl<L>` give the angle between the end force and the
  held direction, which with `FairTen`/`AnchTen` is the stiffener's load case. Keep the fine
  mesh a couple of metres past the stiffener tip, where the cable's curvature can peak.
- The material is linear elastic. A row fails if the line is not finite-EI, a value is
  non-finite, above 1e15 or out of range (`Length`, `RootOD`, `TipOD` and `E` must be positive,
  `InnerD` and `Density` non-negative, `InnerD` below both outer diameters), or the stiffeners
  of End A and End B together are longer than the line. On a stock-order line (anchor as
  `NodeA`) the `End` column follows the written row, so the stiffener stays on the same physical
  end. Stiffeners run wherever the cubic-Hermite cable does, standalone and coupled.

### FAILURE (optional, EI = 0 decks)

A FAILURE row detaches line ends from a point during a dynamic run, with MoorDyn's trigger rules.

```text
--------------------- FAILURE ------------------------------------------
FailID  Point  Line(s)  FailTime  FailTen
(-)     (-)    (-)      (s)       (N)
1       P3     1,2      0         2.5e6
```

| Column | Meaning |
|--------|---------|
| `FailID` | integer; rows are numbered 1, 2, 3, … in order |
| `Point` | the point the lines detach from: `P<n>` or a positive integer id. Rod ends (`R<n>A`/`R<n>B`) are rejected |
| `Line(s)` | one line id or a comma list without spaces (`1,2`); every listed line must be attached to `Point` |
| `FailTime` | trigger time [s]; `0` disables the time trigger |
| `FailTen` | trigger tension [N] at the attached line end; `0` disables the tension trigger |

At least one of `FailTime > 0` or `FailTen > 0` is required; both must be finite. At each
committed step an unfailed row fires when `t >= FailTime` (if positive) or when the attached-end
tension of any listed line reaches `FailTen` (if positive). Firing moves the listed line ends onto
a new free point with id = largest deck point id + row number, and prints
`CableDyn: FAILURE <id> triggered at t = ...`. A row whose lines were already detached by an
earlier row has no effect.

FAILURE rows are used by three routes: the standalone EI = 0 dynamic point-system run, the
standalone Rigid6 body run, and the OpenFAST aggregate for pure EI = 0, non-FAST.Farm, frictionless
decks without Rigid6 bodies. In the standalone driver a FAILURE deck needs `dtM` and `TMax`;
finite-EI lines, rods, `motionFile`, and `frictionMu` are each rejected by name. A FAILURE deck with
free Rigid6 bodies runs on the staggered body scheme (`bodyScheme` is overridden, with a note) and
may not also hold `Connect`/`Free` points or `Point3` bodies; a detached line end is integrated as
a free point while the bodies carry on with the remaining lines. This models a line break at a
fairlead in an accidental limit state (ALS) analysis; see
`examples/als_volturnus_line_break_time.dat`.

### CONTROL (optional, OpenFAST line control)

A CONTROL row assigns lines to an active cable-control channel driven by the OpenFAST ServoDyn
`CableDeltaL` / `CableDeltaLdot` inputs.

```text
--------------------- CONTROL ------------------------------------------
ChannelID  Line(s)
(-)        (-)
1          1,2
2          3
```

| Column | Meaning |
|--------|---------|
| `ChannelID` | positive integer control channel |
| `Line(s)` | one line id or a comma list without spaces (`1,2`) |

Each line belongs to at most one channel. Before every advance, the channel's `DeltaL` sets the
unstretched length of each assigned line's **fairlead-side segment** to its initial length plus
`DeltaL`; `DeltaLdot` supplies the matching rate. The fairlead-side segment is the one at the
line's end on a host-driven point: `Coupled`, `Vessel`, `Turbine<J>`, `Body<N>`, or an end of a
`Coupled` or `Vessel` rod. When both ends or neither end are on such points, it is the segment at
the `NodeB` written in the deck. A line written in the stock MoorDyn order, with its host-driven
end at `NodeB`, is therefore controlled where MoorDyn-F controls it, at its last segment N at
`AttachB`; so is a line with both or no host-driven ends. A line written fairlead first, with its
only host-driven end at `NodeA`, is controlled at that end. The length is held over the advance.
On a linear-elastic segment the axial damping acts on the strain rate, as in MoorDyn-F
(`BA (lstrd − lstr ld/l)/l`), so a segment paid out at constant strain carries no damping
tension; the viscoelastic and Syrope laws take the plain chord rate `lstrd`, as MoorDyn-F and
MoorDyn-C do (see the bullets below).

A command outside MoorDyn-F's bounds stops the run with a message that names the channel, the
line, the command and the bound, as MoorDyn-F stops there. With `UnstrLen` the line's unstretched
length and N its number of segments, both summed over its `SECTIONS` rows, MoorDyn-F refuses
`DeltaL` > `UnstrLen`/N and `DeltaL` < −0.5 `UnstrLen`/N; CableDyn makes the same comparisons, so
a command MoorDyn-F accepts is accepted. On a line of one section `UnstrLen`/N is the controlled
segment's initial length S, and the bounds read −S/2 ≤ `DeltaL` ≤ S. On a line of several
sections the controlled segment can be shorter or longer than `UnstrLen`/N; a command within the
bounds that would make it zero or negative (possible when it is shorter than half of
`UnstrLen`/N) also stops the run, with a message that names the line.

- On an `EI = 0` line the segment is the end element on that side, of initial length S. The
  step evaluates the committed side of its generalised-α blend at the lengths of the previous
  advance (with the force blend, the default, the step-start force; under
  `False alpha_force_blend`, lengths blended with the configuration), so a length ramp is
  followed without lag at any `rhoInf`.
- A Syrope polyester segment (a Syrope line, or a composite line whose fairlead-side section is
  Syrope) carries its slow stretch over the length change, as MoorDyn-F and MoorDyn-C carry it:
  they keep the stretch `dl_1` of the segment as its state and read its slow strain as `dl_1`
  over the new length. The running maximum tension is kept, and the slow-strain rate takes the
  chord rate without the paid-out term, as MoorDyn's Syrope rate does. A slow pay-out therefore
  unloads the segment along the working curve of its load history, and a haul-in beyond the
  running maximum follows the OWC and raises it.
- A viscoelastic segment (`Es|Ed` or `Es|alphaMBL|vbeta`) keeps its slow-branch stretch `dl_1`
  as it is over the length change and reads it at the new length, as MoorDyn-F and MoorDyn-C do:
  the tension `EA_1 dl_1/L0 + BA ld_1/L0`, the rate `ld_1` with `dl` = stretched length − `L0`,
  and the load-dependent `EA_D` all take the new `L0`, and the rate takes the chord rate without
  the paid-out term. A slow pay-out or haul-in therefore follows the static law `Es` times the
  strain; a fast change first meets the dynamic stiffness and relaxes to it.
- On a finite-EI cable, which runs from a `Fixed` anchor to a host-driven fairlead, the segment
  is the fairlead segment of the deck mesh (the length of the `SECTIONS` row at the fairlead over
  its `NumSegs`). Where the static initialisation refined the mesh, it is the cable elements that
  make up that segment. Each of them scales by (S + `DeltaL`)/S, S being the segment's initial
  length, with rate `DeltaLdot` l/S for an element of initial length l, so the segment becomes
  S + `DeltaL` long. The structural and attachment mass, the seabed contact coefficients and the
  tributary lengths follow the new lengths; `BA` keeps its initial resolution. The step blends
  the force of the committed state, taken at the lengths of the previous advance, with the force
  at the new lengths, so a length ramp is followed without lag at any `rhoInf`. This needs the
  force-blended generalised-α, the default: a deck that controls a finite-EI cable under
  `False alpha_force_blend` fails at initialisation with a message that names the line. Within
  the bounds above, a cable of one section scales each element within [0.5, 2] of its initial
  length; on a cable of several sections the scaling can leave that range, beyond the
  resolution its static mesh was built for, so keep large commands on a fairlead section whose
  segments are at least `UnstrLen`/N long.
- On a cable restrained in torsion at both ends the torsion follows the lengths too: the line's
  torsional compliance, the elements' torsional stiffness `GJ`/l and damping `Bt`/l, the
  torque–tension coupling and the polar inertia `Irn` l/2 at the nodes take the new lengths, a
  torsional damping written as `-ζ` keeps its `ζ` (`Bt` = ζ l √(GJ `Irn`) at the new length; a
  positive `Bt` stays), and the damping acts on the rate of the twist per unit length, so a
  segment paid out at constant twist per length carries no damping torque. A haul-in raises the
  torque of a fixed end-to-end twist as `GJ` Twist/L does.

The host input arrays are sized to the highest channel id.

CONTROL is supported only on the OpenFAST `CompMooring = 5` route, for non-FAST.Farm decks,
without OpenFAST linearisation. The standalone driver rejects a CONTROL section.

### OPTIONS (`value keyword` order, case-insensitive keyword)

The [OPTIONS reference](options.rst) is the complete table of every keyword and alias with its
type, unit, default, valid range, and route. `examples/cabledyn_options_reference.dat` shows every
syntax form. The most frequently edited keywords are:

| Keyword | Meaning | Default |
|---------|---------|---------|
| `g` | gravity [m/s²] | 9.80665 |
| `rhoW` / `WtrDnsty` | water density [kg/m³] | 1025.0 |
| `WtrDpth` | water depth [m]; seabed plane z = −WtrDpth. Omit for a suspended or taut line with no bottom contact | none |
| `bathymetryFile` / `bathymetry_file` / `seafloorFile` | structured bathymetry file (rows `x y depth`); mutually exclusive with `WtrDpth`. Supported for static EI = 0, independent-line EI = 0 dynamic, EI = 0 `Connect`/`Free` point-system line contact, cubic-Hermite finite-EI dynamic with held or prescribed-translation ends, free/fixed rod dynamic, and Rigid6 dynamic decks | none |
| `kBot` | seabed penalty stiffness base [Pa/m = N/m³], scaled per line node and rod contact station by diameter × tributary length, at a Free/Connect point with Mass or Vol and a Point3 buoy by its footprint `V^(2/3)` (`V` = Vol, or Mass/7850), and by a fixed 1 m² reference area at a Rigid6 reference point (only with `WtrDpth`/`bathymetryFile`) | 1.0e5 |
| `cBot` | seabed normal damping base [Pa·s/m = N·s/m³], scaled like `kBot` (also over a point footprint); active only on contacting nodes and points moving downward | 1.0e4 |
| `bodyIC` | `static`: free `Rigid6` bodies and free rods, with `Free`/`Connect` points, start at their static equilibrium; `deck`: they start at their deck pose (for example a free-decay test) | `static` |
| `frictionMu` / `mu` | isotropic seabed friction coefficient: stick-slip springs on line nodes (held by the static solve too in a deck current, from the still-water laid shape, or toward the as-laid position with `staticsFriction asLaid`), regularised kinetic friction on rods and bodies; requires `WtrDpth` or `bathymetryFile`, and `dtM`/`TMax` in the standalone driver. Rejected on some routes (decks with `Connect`/`Free` points, `Point3` buoys or `FAILURE` rows, and body or rod decks off the default monolithic march); see the [OPTIONS reference](options.rst) | 0 |
| `frictionMuAxial` / `frictionMuLateral` | anisotropic line friction: the coefficients along and across the local line axis (OrcaFlex axial/normal); an omitted one takes `frictionMu`; both positive or both zero; rods and bodies use the lateral one | `frictionMu` |
| `staticsFriction` | statics seabed friction policy (OrcaFlex): `none` solves frictionless statics (in a deck current, friction from the still-water equilibrium); `asLaid` holds every grounded node toward its as-laid position (laid from the line's lower end, the anchor or the fairlead when that is lower, along `layAzimuth` at `asLaidTension`) with the regularised Coulomb law; rejected where the statics solve the lines without seabed friction (decks with bodies, rods or `Connect`/`Free` points, and a finite-EI line whose End B is not `Fixed`, as a line shared between two turbines) | `none` |
| `layAzimuth`, `layAzimuth<ID>` | lay azimuth (deg, from +x toward +y) of every line, or of line `ID` | chord direction, from the lower end |
| `asLaidTension`, `asLaidTension<ID>` | as-laid effective tension (N, ≥ 0) of every line, or of line `ID` | 0 |
| `dtM` | dynamic time step [s] | — |
| `TMax` | dynamic end time [s]; an integer multiple of `dtM` | — |
| `rhoInf` | generalised-α spectral radius | 0.4 |
| `maxStrain` | plausibility bound on `EI = 0` element strain, checked after every committed dynamic step; a non-finite state or a larger strain stops the run with exit code 2. `0` disables it | 0.5 |
| `RangeStart` / `range_start` | first output time [s] in the range graphs of the `LINES` `Outputs` flag `r`; earlier rows (a start-up transient) are left out. ≥ 0 and ≤ `TMax` (the host's in OpenFAST); needs a line with the `r` flag and, standalone, `TMax` | 0 |
| `modified_newton` | `True`/`False`: reuse the tangent within a step on every dynamic solver the deck builds (the EI = 0 system and each coupled finite-EI cable): one effective-tangent factorization per step, contraction-checked with a refresh when the direction goes stale. Committed states meet the same Newton tolerance either way | `False` |
| `cable_load_feedback` | coupled finite-EI cable reaction switch. `True` returns cable force and moment to the host. `False` marches the cable with the same moving boundary and host fluid field and keeps its output channels, but returns zero force and moment; use it for a one-way comparison, not as a physical model | `True` |
| `adaptive_mesh` | `True`/`False`; allow finite-EI mesh refinement when the static resolution check is fragile | `False` |
| `cable_statics` | `continuation` or `sequenced`: which finite-EI static route runs first (the other is its fallback); both results are audited | `continuation` |
| `axialDampingRatio` / `axial_damping_ratio` | `segment` or `mode1`: what a negative `BA` is the damping ratio ζ of. `segment` (MoorDyn's convention): of each segment, BA = ζ L0 √(EA m) per element, so the line's first axial mode is damped at about ζ π/(2N) on N elements and less on a finer mesh; a dynamic run notes that ratio. `mode1`: of the line's first axial mode (both ends held, dry mass, from its sections, so the same on any mesh): BA = 2 ζ EA / ω1 on every element, a damping proportional to the stiffness, so the axial mode n is damped at ζ ωn/ω1. A line with a negative `BA` and a viscoelastic or Syrope section is refused under `mode1` | `segment` |
| `OutputRecovery` / `output_recovery` | `equilibrium` or `element`: definition of the finite-EI node tension, curvature, bend moment and segment tension. `equilibrium` recovers them from nodal equilibrium (the effective tension F·t, the moment the neighbouring elements carry, curvature = moment / EI); `element` reports the length-weighted element-mean axial force EA(\|r'\| − 1), the larger one-sided exact curvature, and the element-midpoint axial resultant as segment tension. End forces, positions and TDP channels are the same under both | `equilibrium` |
| `alpha_force_blend` | `True`/`False`; generalised-α blend of the finite-EI and `EI = 0` dynamics: forces (`True`) or the configuration `q_αf` (`False`), which biases the mean tension of a rotating finite-EI line at large `dtM` and lets `EI = 0` segments that go slack report spurious tension spikes | `True` |
| `tensile_safety` | `False`, `warn`, or `True`; audits the element-mean axial force (three-point Gauss mean of the signed axial resultant, averaged over an element and its two neighbours). `True` rejects. `warn` commits the state, counts accepted-step events, and reports the worst force, threshold, element and time (the printed `xi` is always 0.5, the element centre) | `False` |
| `tensile_strain_tolerance` | non-negative strain band for the dynamic tensile audit | `2e-6` |
| `recovery_max_substeps` | integer from 4 to 65536; maximum step subdivision for dynamic-step recovery on tension-only and bending lines. Internal prescribed states lie on one C2 quintic trajectory and land on the nominal coupling endpoint. The standalone summary reports recovered intervals and the largest subdivision used | `1024` |
| `ei0_substeps` | `auto` or `off`. `auto` solves a converged `EI = 0` step again in `max(4, ceil(turn/ei0_substep_angle))` equal sub-steps (at most `ei0_substep_max`) when a segment that ends it taut turned by more than `ei0_substep_angle`, or a segment slack at its start ends it above a quarter of the largest step-start tension while the step does not resolve the axial wave over it; the end motion follows the C2 quintic of the recovering step, and output and coupling times are unchanged. `off` takes every step as given. The lines attached to the bodies, rods and points of the monolithic body and point coupling (the default `bodyScheme` of decks with them) are not sub-stepped | `auto` (`off` with `False alpha_force_blend`) |
| `ei0_substep_angle` | real in (0, 90], deg; largest taut-segment turn per step before `auto` sub-steps it | `1.0` |
| `ei0_substep_max` | integer from 2 to 1024; most sub-steps `auto` takes for one step | `16` |
| `axial_quadrature_order` | Gauss order 1–6 for the finite-EI axial energy; a value different from the bending order gives selective integration | `4` |
| `bending_quadrature_order` | Gauss order 1–6 for the finite-EI curvature energy | `4` |
| `dynamic_solver rel abs max_iter backtracks [rhoInf]` | dynamic Newton controls; keyword-first syntax, unlike scalar rows. `EI = 0` solves use all four; finite-EI cables use `rel` and `max_iter` on every route (standalone, mixed, OpenFAST, FAST.Farm, C API). Choose them for the mesh and load case; the 952-element Gulf of Maine example uses `1e-4 1e-14 100 12` | `1e-8 1e-14 30 12` |
| `current` | `none current` / `uniform vx vy vz current` / `profile z1 vx1 vy1 vz1 z2 vx2 vy2 vz2 current`; included in the static initial condition. Standalone only | none |
| `waves` | `none waves` / `airy H T dir waves` / `stream H T dir waves` (`dean`; regular nonlinear stream-function wave) / `jonswap Hs Tp gamma dir waves` / `pm Hs Tp dir waves` (`issc`, `bretschneider`) / `torsethaugen Hs Tp dir waves` / `ochihubble Hs1 Tp1 lambda1 Hs2 Tp2 lambda2 dir waves`. Standalone only | none |
| `wavetrain` | one train of a multi-train sea, rows add up (at most 16): `airy H T dir wavetrain`, `jonswap Hs Tp gamma dir s wavetrain`, `pm Hs Tp dir s wavetrain`, `torsethaugen Hs Tp dir s wavetrain`, `ochihubble Hs1 Tp1 lambda1 Hs2 Tp2 lambda2 dir s wavetrain`; `s` is the cos-2s spreading exponent (`0` long-crested). Excludes a `waves` row | none |
| `WaveSpreading` | cos-2s spreading exponent of a spectral `waves` row, in [0, 1000] | 0 |
| `WaveDirections` | direction bins of a spread train | 9 |
| `WaveComponents` | frequency components per train and direction (at least 2) | 200 |
| `StreamOrder` | Fourier terms of a `stream` wave: 0 (default, 20) or 2 to 60 | 0 |
| `nModes` | modal analysis: the N lowest natural frequencies and mode shapes of every line about its static equilibrium, written to `<root>.modes.out` (EI = 0 decks, or finite-EI decks on the Hermite route, where a line restrained in torsion adds the twist angle of every node; flat seabed; 0 = off) | 0 |
| `WaveSeed` | integer from 1 to 2147483646; seed of the random spectral sea (the same seed gives the same sea on every platform; train *i* uses seed + 7919 (*i* − 1)) | 1 |
| `rampTime` | half-cosine start-up ramp of the wave amplitudes [s]; the current is not ramped. `0` disables it | 0 |
| `motionFile` | path to a prescribed-motion time series for `Coupled`/`Vessel` points, rod end rows, and prescribed Rigid6 `Body<N>` points; `0` or `none` disables it | — |
| `vesselMotion` | path to a 6-DOF vessel record; every `Coupled`/`Vessel` point moves rigidly with the vessel (see [Vessel motion](#vessel-motion-vesselmotion-vesselrao)); an alternative to `motionFile` | — |
| `vesselRAO` | path to a displacement RAO table; the vessel moves as the RAO response to the deck waves; an alternative to `motionFile` | — |
| `vesselRef` | `x\|y\|z` vessel reference point at the reference pose [m]: rotation centre and RAO origin | `0\|0\|0` |

The example decks write each record as `value keyword - Description (unit) {choices}` (the
OpenFAST style). The parser reads only the `value keyword` pair. The unit follows the description
and is omitted for dimensionless records; braces list the accepted values of a discrete option.
The positional `current` and `waves` records place the keyword after their parameters and accept
the same trailing description; the numeric fields before the keyword are validated strictly.

```text
9.80665              g       - Gravitational acceleration (m/s^2)
1.0e5                kBot    - Seabed penalty stiffness base (Pa/m)
airy 2.0 8.0 0.0     waves   - Wave model, height, period, and direction (m, s, deg)
staggered            bodyScheme - Multibody step scheme {monolithic; staggered}
```

Option rows are last-row-wins. Unknown keywords are rejected. Static-solver tolerances are built
in, so keys such as `staticRelTol` or `staticMaxIter` are rejected like any other unknown option;
set the dynamic Newton controls with `dynamic_solver`. The stock MoorDyn keywords `dtIC`,
`TmaxIC`, `CdScaleIC`, `threshIC`, `TScheme`, `WriteLog`, and `dtOut` are accepted and ignored,
because CableDyn uses a Newton static initial condition, an implicit integrator, and
caller-controlled output cadence. MoorDyn-F's `inertialF` is accepted as `1` only (CableDyn
always returns the inertia of coupled bodies and rods; `0` and `2` are rejected by name), and
`inertialF_rampT` is accepted and ignored.

(moordyn-c-wavekin)=
### MoorDyn-C `WaveKin` and `Currents` modes

A MoorDyn-C deck selects its water kinematics with the numeric `WaveKin` and `Currents` options
and fixed-name files in the deck folder. CableDyn reduces each wave file to wave components and
evaluates them exactly at every node, with Wheeler stretching; MoorDyn-C tabulates them on
`water_grid.txt` and interpolates, so that file is not read. The current files are evaluated at
every node's position and time as MoorDyn-C interpolates them. Standalone decks only.

| Option | File | Meaning |
|---|---|---|
| `WaveKin 3` | `wave_elevation.txt` | `time elevation` rows from `t = 0` (no header rows), resampled linearly at `dtWave` to `floor(t_last/dtWave) + 1` samples (the last dropped when the count is odd) and reduced to its Fourier components; components above `WvHiCOff` (default 0.5 Hz, MoorDyn-C's fixed cut) are dropped and the mean is a mean-level offset, as MoorDyn-C does. Waves travel along +x |
| `WaveKin 7` | `wave_frequencies.txt` | `omega Re Im [beta]` rows [rad/s, m, m, rad], the first at `omega = 0`: each row is the component `\|c\| sin(omega t - k d + arg c)`, `d = x cos(beta) + y sin(beta)` with the row's own `beta` (0 when the column is left out); the `omega = 0` row is a mean-level offset and its `beta` has no effect. Rows of different directions describe a short-crested sea, summed in ascending frequency |
| `Currents 1` | `current_profile.txt` | `z ux uy uz` rows after its header rows, strictly increasing `z`; linear in `z` and held beyond the end rows |
| `Currents 2` | `current_profile_dynamic.txt` | a depth profile in time: lines 1-4 and 6 are free text, line 5 lists the depths `z1 ... zn` (strictly increasing, read in single precision as MoorDyn-C does), and each later row is `t ux1 ... uxn [uy1 ... uyn [uz1 ... uzn]]` (missing components zero), at least two rows with strictly increasing `t` |
| `Currents 5` | `current_profile_4d.txt` | a grid in x, y, z and time: line 1 is `nx ny nz nt`, lines 2-5 the x, y, z and t coordinates (each strictly increasing, at least two times), then one `x y z t ux uy uz` row per grid point, in any order, matched to the grid by value; a text line 6 is a header |

`Currents 2` and `5` follow MoorDyn-C v2.7.1 (`constructDynamicCurrentGrid`,
`construct4DCurrentGrid` and `CurrentGrid::getCurrentKin`):

- the table is resampled in time at its smallest time interval `dt`, from `t = 0` to
  `floor(t_last/dt) dt` (a last time that is not a multiple of `dt` is not reached), linearly
  between rows and held at the first and last rows;
- between samples the current is linear in time; past the last sample the grid repeats with
  period `nt dt` (`nt` samples), holding its `t = 0` value over the last interval of each period,
  as MoorDyn-C's index wrap does. A run longer than the last sample prints a note;
- in x, y and z the current is linear between grid coordinates and held beyond the end ones; the
  node elevation is not stretched;
- the current has no fluid acceleration (MoorDyn-C sets it to zero), so its time variation adds
  no Froude-Krylov or added-mass load;
- the static start takes the current at `t = 0`, as MoorDyn-C's default stationary initial
  condition does (its legacy dynamic relaxation, `ICgenDynamic 1`, samples the current over the
  relaxation time instead);
- a grid holds at most 2e6 resampled points in space and time (every static solve holds a copy,
  48 MB at the limit);
- the C API and the OpenFAST point-system shells have no simulation clock: they apply a current
  constant in time as a steady field, as `Currents 1`, sampled at the nodes of the static state
  and, through the C API, at the step-start nodes before every step, and refuse one that varies
  in time;
- `current_profile_4d.txt` is read as MoorDyn-C documents it, which MoorDyn-C v2.7.1 does not
  quite do: it reads its rows from line 7, so a row on line 6 leaves that grid point at zero, and
  it matches a row to the grid by the text of its coordinates, so a row writing `-0` for `0` or
  `1.0` for `1` lands on the first grid point. CableDyn reads line 6 as a row unless it is text
  and matches by value, and it rejects a missing, repeated or off-grid point. A file with a text
  line 6 and its coordinates written as on lines 2-5 reads the same in both codes.

With `WaveKin 3`, MoorDyn-C (its default `UnifyCurrentGrid 1`) adds a current to the wave grid,
where it is sampled on `water_grid.txt`; CableDyn adds the current at the nodes, as MoorDyn-C's
`UnifyCurrentGrid 0`.

Rejected by name: `WaveKin 1` (kinematics set node by node through the MoorDyn-C API; a deck has
no source for them), `WaveKin 2` (the FFT grid: `wave_frequencies.txt` resampled to an even
spectrum; `WaveKin 7` evaluates the same file's components exactly), `WaveKin 4`-`6` and
`Currents 3`-`4` (no kinematics source in MoorDyn-C v2.7.1). A deck that also declares a `waves`
option, a WaterKin file, or a second current source is rejected as double counting. On shared
inputs the `wavekin_modes` test holds `WaveKin 7` and `Currents 1` identical to MoorDyn-C v2.7.1 (`5e-12` relative) and `WaveKin 3`
within `3e-7` m in elevation and `1e-4` in velocity and acceleration at MoorDyn-C's grid points,
the remainder being MoorDyn-C's grid interpolation and its approximate wave number. The
`mdc_currents` test holds `Currents 2` and `5` identical to MoorDyn-C v2.7.1 at 739 points and
times (including past the last sample), and `mdc_currents_runs` matches the tension change of a
time-varying and of a sheared current to MoorDyn-C's within 0.9 % on a 70 m rope.

`wave_frequencies.txt` is the file MoorDyn-C v2.7.1 reads, a `beta` per row included: its
`SUM_COMPONENTS` mode gives each row its own direction too. `WaveRefX` and `WaveRefY`
([options](options.rst)) are an extension of CableDyn and no part of MoorDyn-C or MoorDyn-F: a
deck with them is not a plain MoorDyn deck, and a MoorDyn solver would not place the phases there.

A mean level, a non-zero `omega = 0` row or the mean of `wave_elevation.txt`, is added to the
elevation alone, as MoorDyn-C does: every wave number stays that of `WtrDpth`, and the Wheeler
stretching maps the water column under the total elevation, the level included. The
`wavekin_modes` test holds both files with a 0.8 m level, under six `WaveKin 7` components in
six directions, to MoorDyn-C v2.7.2: `WaveKin 7` to `1e-8` of its scale and `WaveKin 3` to the
tolerances above. The mean of a WaterKin `WaveKinMod 1` record raises the still-water level
instead ([below](#moordyn-f-waterkin-file-modes)).

(waterkin-file-modes)=
### MoorDyn-F `WaterKin` file modes

A MoorDyn-F deck may select a WaterKin file (grammar in [Auxiliary file formats](file_formats.rst)).
`WaveKinMod` and `CurrentMod` are independent switches. `SEASTATE` is recognised only as the
`WaveKinMod` value token, never in a trailing comment.

| Mode | Meaning |
|---|---|
| `WaveKinMod = 0` | no waves |
| `WaveKinMod = 1` | elevation history resampled at `dtWave` over deck `TMax` (host `TMax` for caller-driven decks), truncated or zero-padded, and Fourier-reduced once on one padded DFT time base, keeping the components up to `WvHiCOff` (default 0.5 Hz; `none` keeps all, as MoorDyn-F) |
| `WaveKinMod = 2` / `SEASTATE` | waves from the coupled host SeaState field |
| `CurrentMod = 0` | no current |
| `CurrentMod = 1` | N-level WaterKin depth table, interpolated at structural nodes |
| `CurrentMod = 2` | current from the coupled host SeaState field |

The mean of a `WaveKinMod 1` record raises the still-water level: its wave numbers are those of
`WtrDpth` plus the mean, and the stretching maps the water column under the raised level.
MoorDyn-F instead drops the record's mean, and its Nyquist bin, so a record whose mean is not zero
puts the surface of the two codes apart by that mean.

**`WaveKinMod 1`** is standalone-only. It needs a `WaveKinFile` of at least four finite
`time elevation` rows starting at `t = 0` with strictly increasing times, a positive `dtWave`, a
positive `TMax`, and the ordinary `waves` requirements (`dtM`/`TMax` and `WtrDpth`). It cannot be
combined with a `waves` option or with `CurrentMod = 2`, and it is rejected on the coupled
aggregate route and in a mixed `EI = 0` + finite-EI standalone deck.

**Host modes** (`WaveKinMod 2`/`SEASTATE`, `CurrentMod 2`) require aggregate/OpenFAST
initialisation with a SeaState field; the standalone driver rejects them with
`WaterKin WaveKinMod 2/SEASTATE is coupled-only`.

- Host waves may be combined with a file `CurrentMod 1` profile.
- Current-only host mode removes host wave velocity and acceleration and uses still-water wetting.
- SeaState embeds its standard steady current in `WaveVel`. The module reconstructs that current
  on the same four vertical grid nodes and interpolation weights before removing or keeping it.
  If SeaState uses its user-defined current (SeaState `CurrMod = 2`), the field cannot be
  decomposed and is rejected whenever separate wave/current selection is required.
- An explicit WaterKin file overrides SeaState: `WaveKinMod 0`/`CurrentMod 0` disables both host
  components, and `WaveKinMod 0`/`CurrentMod 1` uses only the file profile. The full host field is
  used only when the deck gives no WaterKin selection.
- A deck that declares both a `current` option and a WaterKin `CurrentMod 1` table is rejected as
  double counting.

### Prescribed motion (`motionFile`)

`0` or `none` (any case) disables prescribed motion, so one deck can serve static and dynamic
cases. With an active path:

- On the finite-EI (`EI > 0`) route each prescribed endpoint is a moving support: its velocity,
  acceleration, and support inertia enter the dynamic residual, not only its position. Row 1 is
  committed as the initial boundary state before the `t = 0` fluid sample and output; this does
  not advance time.
- `Coupled`/`Vessel` rods are prescribed from their two end rows while the attached lines advance;
  `Free` rods in the same deck are integrated dynamically.
- Rigid6 decks prescribe the full 6-DOF body motion from `Body<N>` rows (see
  [BODIES](#deck-bodies)).
- A mixed `EI = 0` + finite-EI deck of lines between `Fixed`/`Coupled`/`Vessel` points moves the
  points of both line kinds from their rows, and a finite-EI line on them as on the finite-EI
  route (row 1 installed before `t = 0`, the roll column below).
- `Connect`/`Free` point-system decks and FAILURE decks reject `motionFile`.

Every non-comment record of the motion file is one row `time point_id x y z vx vy vz ax ay az` of
plain numbers; tokens after the eleventh are ignored, except that a deck with a line solved in
torsion reads a twelfth, `roll` [deg]: at the point, the roll of the frame of the line's moving
end restrained in torsion (End A, or End B in a deck that lists the `Fixed` anchor as End A; both
ends of a line between two moving points), right-handed about the line tangent pointing into the
line from that end. It imposes `Phi(t) = Pretwist(B) − Pretwist(A) − roll(A)(t) − roll(B)(t)`,
the roll of a `Fixed` end, or of an end free in torsion, being 0: the roll has the sense of
`Pretwist(A)` at End A (where the inward tangent is `Ez`) and the opposite sense to `Pretwist(B)`
at End B (where it is `−Ez`), so equal rolls of the two ends of a line between two moving points
twist it by twice the roll, and a rigid roll of the line about its axis (opposite rolls) does not
twist it. The roll is 0 at
`t = 0` and is given on every row of the point or on none. Header lines must be comments. `time` must
lie on the `0, dtM, 2·dtM, …` grid (rows after `TMax` are read and not used) and `point_id` must be
a prescribed point. Each
(point, time) pair appears once, every prescribed point needs a row at every grid time, and rows
may appear in any order. See also [Auxiliary file formats](file_formats.rst).

### Vessel motion (`vesselMotion`, `vesselRAO`)

A vessel is a rigid body that carries every `Coupled`/`Vessel` point of the deck. Its
reference point `vesselRef` (default `0|0|0`) is the rotation centre and the RAO origin. The deck
positions of the points are their positions at the reference pose, where the vessel axes are the
global axes. With the vessel reference point at `r(t)` and rotation `R(t)`, a point with deck
position `P` moves as

```text
x = r + R p,   v = dr/dt + w × (R p),   a = d²r/dt² + al × (R p) + w × (w × (R p)),   p = P − vesselRef
```

where `w` and `al` are the angular velocity and acceleration in global axes. The resulting point
rows replace a `motionFile`, so vessel motion runs wherever a `motionFile` runs; decks with
prescribed rods, Rigid6 bodies or `TURBINES` reject it. `motionFile`, `vesselMotion` and
`vesselRAO` are alternatives: a deck may activate only one. A finite or `Rigid` END CONNECTION
at a vessel point keeps its direction in vessel axes, so it turns with the vessel and its
moment follows the vessel rotation.

Rotations use the OrcaFlex vessel convention: `R = Rz(yaw)·Ry(pitch)·Rx(roll)`, right-handed
about the vessel x (roll), y (pitch) and z (yaw) axes, applied yaw, then pitch, then roll.

**`vesselMotion` record.** One row per `dtM` grid time from 0 to `TMax`, in any order (rows on
the grid after `TMax` are read and not used), in one of two forms for the whole file:

```text
time x y z roll pitch yaw vx vy vz wx wy wz ax ay az alx aly alz        (19 values)
time x y z q0 q1 q2 q3   vx vy vz wx wy wz ax ay az alx aly alz        (20 values)
```

`x y z` is the reference-point position [m]; `roll pitch yaw` are the Euler angles [deg], or
`q0 q1 q2 q3` a unit quaternion (scalar first, norm within 1e-6 of 1); `vx vy vz` and
`ax ay az` are the reference-point velocity [m/s] and acceleration [m/s²]; `wx wy wz` and
`alx aly alz` are the angular velocity [rad/s] and angular acceleration [rad/s²] in global axes.
The driver uses the velocities and accelerations as given; they must be the time derivatives of
the positions and rotations for the motion to be consistent.

**`vesselRAO` table.** Displacement RAOs in blocks, one per relative wave heading:

```text
HEADING 0
# period  surgeA surgeP  swayA swayP  heaveA heaveP  rollA rollP  pitchA pitchP  yawA yawP
  6.0     0.10   95.0    0.0   0.0    0.35   5.0     0.0   0.0    0.9    100.0   0.0   0.0
  10.0    0.60   92.0    0.0   0.0    0.95   2.0     0.0   0.0    1.2    95.0    0.0   0.0
HEADING 45
  ...
```

- Periods in s; translation amplitudes in m/m, rotation amplitudes in deg/m; phases in deg.
- **Phase convention: a lag relative to the wave crest at the vessel reference point.** A wave
  component whose elevation at `vesselRef` is `a cos(ωt − ε)` moves DOF j as
  `A_j a cos(ωt − ε − P_j)`: a positive phase `P_j` means the motion peaks `P_j/ω` after the crest
  passes the reference point. This is OrcaFlex's default RAO convention (phases as lags,
  relative to the wave crest at the RAO origin, rotations in deg/m).
- The relative heading of a wave component is its own direction of travel (the vessel axes are
  the global axes), so the components of a spread sea or of several wave trains each take the
  RAO at their own heading. Every block must list the same periods; periods and headings may
  appear in either order.
- The complex RAO `A e^(−iP)` is interpolated linearly in period and in heading. A component
  period outside the table takes the RAO of the nearest tabulated period (the run notes how many
  components do); a heading outside the tabulated range is an error, and a one-block table
  applies to its own heading only.
- The waves are the deck linear sea: `airy`, the spectral `waves` rows (with `WaveSpreading`),
  `wavetrain` rows, or a WaterKin `WaveKinMod 1` file, with the same component frequencies,
  directions and phases that drive the line kinematics, so the vessel and the line see one sea.
  A nonlinear `stream`/`dean` wave has no linear components and is rejected with `vesselRAO`. The
  response is multiplied by the `rampTime` ramp; velocities and accelerations are the
  exact time derivatives (including those of the ramp), and rotation rates become the global
  angular velocity and acceleration through the Euler-angle kinematics.

### OUTPUTS (one channel per line)

The example decks list one double-quoted channel per row; the quotes are removed on read. Rows
with several channels separated by whitespace or commas (`FairTen1 AnchTen1`,
`FairTen1, AnchTen1`) are also accepted, quoted as a whole (`"FairTen1, AnchTen1"`) or not. A bare
`END` row closes the list. Channel names are
case-insensitive and at most 64 characters.

The example decks request `FairTen`, `AnchTen`, `FairIncl`, and `AnchIncl` for every line;
point-system examples add point X/Y/Z position and finite-EI examples add selected curvature and
bending moment. None of these channels is mandatory.

| Channel | Meaning | Unit |
|---------|---------|------|
| `FairTen<L>` | line L fairlead (End A) line-end tension: the magnitude of the force the line actually exerts on its End-A point (end element force with axial damping, including the bending shear of a finite-EI line, plus the end node's share of the submerged weight, seabed contact and drag at the actual velocity; without the end node's inertia), the static end reaction at rest. Route differences (seabed friction) are in [Outputs](outputs.rst) | N |
| `AnchTen<L>` | line L anchor (End B) line-end tension, as `FairTen` | N |
| `AnchFz<L>` | line L vertical component of the `AnchTen` end force, positive upward (the line lifts its End-B point) | N |
| `AnchFH<L>` | line L horizontal magnitude of the `AnchTen` end force (same availability as `AnchFz`) | N |
| `FairIncl<L>` | line L fairlead (End A) signed inclination below horizontal (0 = horizontal; positive = downward) | deg |
| `AnchIncl<L>` | line L anchor (End B) signed inclination below horizontal (0 = horizontal; positive = downward) | deg |
| `FairDecl<L>` | line L fairlead (End A) declination from +GZ (0 = up, 90 = horizontal, 180 = down) | deg |
| `AnchDecl<L>` | line L anchor (End B) declination from +GZ (0 = up, 90 = horizontal, 180 = down) | deg |
| `FairAngle<L>` / `AnchAngle<L>` | aliases of `FairDecl<L>` / `AnchDecl<L>` | deg |
| `FairDefl<L>` / `AnchDefl<L>` | line L deflection of the End-A / End-B end force from the direction a `Rigid` or rotational-spring END CONNECTIONS row holds there (0 when the line leaves along it); only at such an end | deg |
| `Point<P>p{x,y,z}` | point P position component | m |
| `Con<P>p{x,y,z}` | alias of `Point<P>p{x,y,z}` (MoorDyn v1 spelling) | m |
| `Body<N>…`, `Rod<N>…` | Rigid6 body and rod channels in the MoorDyn-F names: position, attitude, velocity and acceleration (`P`, `R`, `V`, `RV`, `A`, `RA`), net force and moment (`F`, `M`), rod end tensions (`TenA`, `TenB`), submerged fraction (`Sub`) and rod node positions (`Rod<N>N<k>P`). Available on every route that carries bodies or rods, OpenFAST included; the full list and units are in [Outputs](outputs.rst) | see Outputs |
| `Point<P>F{x,y,z}`, `Point<P>FH` | resultant of the line-end and cable end forces on point P (each the `FairTen`/`AnchTen` end force): the anchor load of a Fixed point shared by several lines, the line load a free point balances; `FH` is its horizontal magnitude. Available on every route (static, `EI = 0`, finite-EI, multibody and OpenFAST) | N |
| `Ten<L>N<J>` | line L effective tension at node J. EI = 0 lines: the mean of the two adjacent segment tensions. Finite-EI lines: the axial component of the section force recovered from nodal equilibrium (`OutputRecovery element`: the length-weighted mean of the adjacent element-mean axial forces). End nodes report the line-end force of `FairTen`/`AnchTen` | N |
| `Curv<L>N<J>` | line L curvature at node J. `EI = 0` lines: geometric curvature of the circle through the node and its two neighbours (end nodes take the adjacent interior value). Cubic-Hermite lines: the geometric curvature of the stretched line, (1 + ε) `BendMom<L>N<J>` / EI with ε the axial strain at the node, the larger of the two sides at a section junction (`OutputRecovery element`: exact curvature of the continuous centreline, the larger one-sided element value at an interior node) | 1/m |
| `BendMom<L>N<J>` | line L bend moment = EI × curvature / (1 + ε), the moment that balances the forces on the section, **relative to the stress-free reference shape** (≈ 0 at the reference; the finite-EI reference is straight). Finite-EI lines: recovered from nodal equilibrium, the moment the neighbouring elements carry (`OutputRecovery element`: EI × the larger one-sided exact curvature); 0 on EI = 0 lines. Under a bend stiffener: the cable's own share, the section moment × the line type's EI / EI(s) | N·m |
| `StfMom<L>N<J>` | line L share of the section moment a bend stiffener carries at node J (the section moment less `BendMom<L>N<J>`; 0 outside the stiffener); only on a line with STIFFENERS | N·m |
| `L<L>N<J>p{x,y,z}` | line L node J position component | m |
| `L<L>N<J>v{x,y,z}` | line L node J velocity component (0 in static-only runs) | m/s |
| `L<L>N<J>a{x,y,z}` | line L node J acceleration component (0 in static-only runs) | m/s² |
| `L<L>N<J>Dec` | line L declination of the axial tangent at node J (from +GZ; 0 = up, 90 = horizontal, 180 = down) | deg |
| `L<L>N<J>Azi` | line L azimuth of the axial tangent at node J (from +GX toward +GY, in [0, 360)) | deg |
| `TDP<L>s` | line L touchdown point (TDP): arc length from End A, between the last grounded node and the next, where the parabola through the last grounded node and the next two nodes crosses the contact-onset height (1e-6 m above the seabed); continuous as nodes ground and lift off ([Outputs](outputs.rst)) | m |
| `TDP<L>x`, `TDP<L>y`, `TDP<L>z` | line L TDP position | m |
| `TDP<L>Lay` | line L layback: horizontal distance from the TDP to the suspended end | m |
| `TDP<L>Exc` | line L TDP excursion: horizontal TDP displacement from its initial position, along the initial direction toward the suspended end | m |
| `TDP<L>Grd` | line L grounded length: deformed chord length along the nodes from the grounded end to the TDP; continuous with the TDP, 0 only when nothing touches (the grounded end has lifted off) | m |
| `Torq<L>N<J>` | line L torque at node J (uniform along the line in statics); positive for a right-handed twist of End B relative to End A about the End A → End B tangent. Only on a line solved in torsion (restrained at both ends, or at one end with the other free) | N·m |
| `Twist<L>N<J>` | line L material twist accumulated from End A to node J, `M × Σ L/GJ` (less `(K/GJ)(l − L)` under coupling) over the elements in between; 0 at End A, without the end-spring windup. Only on a line solved in torsion | deg |
| `Twist<L>` | line L total twist `Phi − Theta = M C`, end-spring windup included; on a line free at one end the twist of its elements, the free end's turn. Only on a line solved in torsion | deg |

- `<L>`/`<P>` are deck LINE/POINT **ids**, not array positions. A channel that matches no
  supported form, names an unknown id, or carries trailing text (for example `Point2px_raw`) is a
  parse error. The `.out` header lists each channel token verbatim.
- Curvature, bend moment, declination, azimuth, and end angles are computed from node positions,
  so they are available on every route: static, independent EI = 0 dynamic, point-system EI = 0
  dynamic, independent finite-EI dynamic, rod dynamic, Rigid6 dynamic, multibody and mixed.
  `BendMom` is non-zero
  only on finite-EI lines. The axial tangent points End A → End B (OrcaFlex's node Ez axis).
- Per-line `p` and `t` files are available on the same routes except the mixed `EI = 0` +
  finite-EI route, the `r` range graph on every standalone route; other flags are rejected.
- `TDP<L>` channels need a seabed (`WtrDpth` or `bathymetryFile`) and a line that rests on the
  seabed at exactly one end in its initial state; otherwise the run stops with exit code 1
  naming the line. They are available on every route, OpenFAST included.
- The anchor uplift check of a drag-embedment anchor (no vertical load at the anchor in the
  intact condition) reads `TDP<L>Grd` (greater than a small tolerance such as 0.01 m
  throughout); `AnchFz<L>` is the vertical anchor load. On an `EI = 0` line it includes the
  anchor node's lumped weight, so its sign change lags the anchor segment's lift-off; see
  [Outputs](outputs.rst) (Anchor uplift).
- In an OpenFAST `CompMooring = 5` run, channel headers in the OpenFAST output and in
  `<OpenFASTRoot>.CD.out` use OpenFAST's 20-character width (`ChanLen`). A longer channel name
  stops coupled initialisation with an error naming the channel; keep coupled channel names
  within 20 characters.

File layouts and column definitions for every output are in [Outputs](outputs.rst).

### Static-configuration file `<out_root>.static.out`

The along-arc static profile (a range graph of the static state) is written in the
OpenFAST/MoorDyn tabular layout that `pyDatView` reads, one row per node of every line. Its
columns are `LineID Node ArcLength X Y Z Tension Curvature BendMoment Declination Inclination
Azimuth` ([Outputs](outputs.rst) defines each one). These standalone routes write it:

- a static-only `EI = 0` deck (no `dtM`/`TMax`);
- the cubic-Hermite finite-EI route, on both static (`TMax = 0`) and dynamic runs, together with
  the element-extrema file `<out_root>.elements.out`;
- a mixed `EI = 0` + finite-EI deck.

The independent `EI = 0` dynamic, point-system, rod, and Rigid6 routes do not write it. The file
is additive; `<out_root>.out` is
unchanged.

An OpenFAST `CompMooring = 5` run always writes `<OpenFASTRoot>.CD.static.out` after coupled
initialisation. It also writes `<OpenFASTRoot>.CD.out` at the committed `dtM` cadence when the
deck requests time-history channels; this file is independent of OpenFAST `DT_Out`.

## Driver workflow

```
CableDyn_driver <deck.dat> <out_root>
```

A source build names the same program `cabledyn`; see the [command-line reference](cli.rst).

1. **Parse** the deck into line types, points, lines, options, and outputs; fail closed on any
   unsupported feature.
2. **Build** each line's mesh and analytic catenary seed.
3. **Static initial condition**: per-line load-continuation Newton solve on the
   flat or structured penalty seabed; point systems add the shared-point force balance.
4. **Dynamic run** (when `dtM`/`TMax` are set): generalised-α integration from the static state,
   with BA damping, added mass, seabed spring, normal damping and stick-slip seabed friction,
   optional uniform/profile-current Morison drag, and optional wave drag, Froude–Krylov,
   and buoyancy wetting.
   - Finite-EI decks run on the cubic-Hermite route with held or prescribed translational end
     motion, structural loads, translational current/wave loads, and flat or structured seabed
     contact, damping, and friction on the same residual. Finite-EI rotational hydrodynamics are
     not modelled. Decks that add bodies, rods or `Connect`/`Free` points run on the
     [multibody march](#multibody-march).
   - Without `motionFile`, `Fixed`/`Coupled` ends are held at their deck positions. With it, the
     file gives a row on the `dtM` grid for every `Coupled`/`Vessel` point, prescribed rod end,
     and prescribed Rigid6 `Body<N>` point at every time.
   - A mixed `EI = 0` + finite-EI deck runs on the failure-atomic aggregate used by OpenFAST, with
     every coupled end held. Prescribed motion, deck wave/current, and per-line `p`/`t` requests
     are rejected; use `OUTPUTS` channels for mixed-deck histories. A static-only mixed deck may
     omit both `dtM` and `TMax`; a positive `TMax` needs an explicit positive `dtM`.
5. **Output** `<out_root>.out`: column 1 is `Time(s)`, followed by the requested channels. The
   time column has 17 significant digits (`ES25.16E3`), so time stamps round-trip exactly on long
   records and fine steps; channel columns use `ES15.7E3` (`ES15.7` on the mixed route). A
   static-only run writes one row at
   t = 0. On single-type routes, LINES `Outputs` flags `p` and `t` also write per-line files
   (static: node/segment tables; dynamic: time series).

Exit codes, the stdout/stderr split, and the completion line are in
[Exit status and automation](standalone_driver.rst); error messages and fixes are in
[Troubleshooting](troubleshooting.rst).

## Design decisions

- SI units in the deck; tensions output in N.
- The static initial condition is always a load-continuation Newton equilibrium computed from
  geometry alone; there is no initial-condition option, and an `ICmode` row is rejected. MoorDyn's
  drag-scaled dynamic relaxation is not used; its tuning keywords are accepted and ignored.
- A line is one object (End A → End B) built from ordered `SECTIONS`, each with its own line type
  and mesh. The stock one-type-per-line MoorDyn row is the single-section case.
