# ISA-5.1 quick reference for reading P&IDs

A summary of ANSI/ISA-5.1 *Instrumentation Symbols and Identification*, covering what you need to read tags, bubbles and signal lines. Drawings may follow a company variant; their legend sheet always wins.

## Contents
1. Tag structure
2. First letters (measured variable)
3. Succeeding letters (function)
4. Common tags
5. Bubble symbols → `location`
6. Signal line types → `type`
7. Final elements and actuators

## 1. Tag structure

```
[area-]  F  I  C  -  101  [A]
         │  └─┬┘     │    └ suffix (parallel devices: A, B)
         │    │      └ loop number
         │    └ succeeding letters: functions (indicate, control)
         └ first letter: measured/initiating variable (+ optional modifier)
```

In a bubble the letters sit on the top line and the number on the bottom line. Read them together as one tag: `FIC` over `101` → `FIC-101`.

The **loop** is identified by the first letter and the number: FE-101, FT-101, FIC-101 and FV-101 are all loop F-101.

## 2. First letters (measured or initiating variable)

| Letter | Variable | | Letter | Variable |
|---|---|---|---|---|
| A | Analysis (pH, ORP, conductivity, gas…) | | N | User's choice |
| B | Burner, combustion | | O | User's choice |
| C | User's choice (often conductivity) | | P | Pressure |
| D | User's choice (often density) | | Q | Quantity |
| E | Voltage | | R | Radiation |
| F | Flow | | S | Speed, frequency |
| G | User's choice (gauging, position) | | T | Temperature |
| H | Hand (manual) | | U | Multivariable |
| I | Current | | V | Vibration, machinery analysis |
| J | Power | | W | Weight, force |
| K | Time, schedule | | X | Unclassified |
| L | Level | | Y | Event, state, presence |
| M | User's choice (often moisture) | | Z | Position, dimension |

**Variable modifiers** come immediately after the first letter:

- D = differential (PDT, differential pressure transmitter)
- F = ratio (FFIC)
- Q = totalize (FQI, flow totalizer)
- K = rate of change
- J = scan

## 3. Succeeding letters (functions)

| Letter | Function | | Letter | Function |
|---|---|---|---|---|
| A | Alarm | | Q | Totalize |
| C | Control | | R | Record |
| E | Primary element (sensor) | | S | Switch; as a first-letter modifier, safety (PSV) |
| G | Gauge, glass (local) | | T | Transmit |
| H / L | High / low (modifies A or S) | | V | Valve, damper (final element) |
| I | Indicate | | W | Well (thermowell) |
| K | Control station | | Y | Relay, compute, convert (I/P) |
| O | Orifice, restriction | | Z | Driver, actuator |
| P | Test point | | | |

## 4. Common tags

| Tag | Meaning | Role in graph |
|---|---|---|
| FE / FT / FIT | flow element / transmitter / indicating transmitter | element / transmitter |
| FIC, LIC, PIC, TIC | indicating controller | controller |
| FV, LV, PV, TV, FCV | control valve | final element (record as a component) |
| FY, LY | I/P converter or relay | relay |
| PI, TI, LG | local gauge or indicator, level glass | gauge or indicator |
| PSV, PRV | pressure safety/relief valve | relief device (record as a component, `kind: relief_valve`) |
| LSH, LSL, LSHH, LSLL | level switch high / low / high-high / low-low | switch (interlock initiator) |
| LAH, PAL | alarm high / low | alarm |
| HS | hand switch (start/stop, open/close) | switch, manual |
| SC, SIC | speed controller (VFD) | controller acting on a motor or pump |
| XV, HV | on/off valve, hand-operated valve | final element |
| ZSO, ZSC | position switch open / closed | switch on a valve (`measures` = the valve) |
| AIT, AE | analyser transmitter, analyser element | transmitter / element |

## 5. Bubble symbols → `location`

| Symbol | Meaning | `location` |
|---|---|---|
| Plain circle | Field mounted | `field` |
| Circle with a solid horizontal line | Main control room panel, operator accessible | `main_panel` |
| Circle with a dashed horizontal line | Behind panel, not operator accessible | `behind_panel` |
| Circle with a double line | Local or auxiliary panel | `local_panel` |
| Circle inside a square | Shared display / DCS | `dcs` |
| Diamond inside a square | PLC | `plc` |
| Hexagon | Computer function | `computer` |
| Item inside a labelled panel outline (e.g. "LOCAL PLC CONTROL PANEL") | That panel | `plc`, `local_panel` or `scada`, as labelled |
| Item in a band labelled SCADA | SCADA | `scada` |
| Bubble labelled SIS or in an SIS band | Safety instrumented system | `sis` |

## 6. Signal line types → `type`

| Line style | Signal | `type` |
|---|---|---|
| Dashed line `- - -` | Electric (analog, discrete) | `electrical` |
| Line with double hatch marks `-//-//-` | Pneumatic | `pneumatic` |
| Line with small circles `-o-o-` | Data link, software, fieldbus | `software` |
| Line with small L-shaped marks | Hydraulic | `hydraulic` |
| Line with x marks `-x-x-` | Capillary (filled system) | `capillary` |
| Wavy or zig-zag line | Wireless | `wireless` |
| Thin solid line from bubble to process | Process connection, impulse line (**not** a signal) | use `measures` |

Process lines are thicker solid lines. A thin solid line from a bubble to a pipe or vessel is the process connection: it tells you where `measures` points.

## 7. Final elements and actuators

- **Control valve:** a valve body (bow-tie) with an actuator on top. A dome or umbrella is a diaphragm actuator (`pneumatic`), an "M" in a box or circle is `electric`, an "S" is `solenoid`, and a box with "H" is `hydraulic`.
- **Fail action** is printed near the valve: FO (fail open), FC (fail closed), FL (fail last/locked), FI (fail indeterminate). It may also appear as an arrow on the actuator stem.
- **Self-actuated regulator:** a valve with an actuator and an impulse line, but no signal from a controller. Use `kind: pressure_regulator`, `actuator: self`.
- **Motor-driven equipment** (pumps, agitators) receives VFD or start/stop signals. Use the equipment as the signal `to`.
