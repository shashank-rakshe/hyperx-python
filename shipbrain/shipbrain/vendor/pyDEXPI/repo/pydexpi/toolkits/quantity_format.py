"""Formatting of DEXPI physical quantities: numbers and unit symbols.

This module is the single home for the unit-symbol map.  It sits in
``toolkits`` rather than ``exports`` so that model-level code (label
materialization in :mod:`pydexpi.toolkits.label_toolkit`) can reach it without
importing the ``pydexpi.exports`` package, whose ``__init__`` pulls in pandas,
openpyxl and networkx.  :mod:`pydexpi.exports.table_locale` re-exports
:data:`UNIT_SYMBOLS` and :func:`unit_symbol`, so the export side keeps its
existing import path -- do not add a parallel unit table anywhere.
"""

import math
from decimal import ROUND_HALF_UP, Decimal, localcontext
from enum import Enum

from pydexpi.pydexpi_classes.core.physicalQuantities import (
    PressureAbsoluteUnit,
    PressureGaugeUnit,
)

__all__ = [
    "UNIT_SYMBOLS",
    "float_to_str",
    "number_with_decimals",
    "unit_symbol",
    "value_with_symbol",
]


#: Symbols for every ``PhysicalQuantityUnit`` literal, keyed by the enum
#: *value* string.  Unmapped values render as the value itself (the historical
#: behavior).  ``PressureAbsoluteUnit`` and ``PressureGaugeUnit`` share value
#: strings, so gauge/absolute cannot be told apart by key -- both map to
#: ``"bar"``.  :func:`unit_symbol` can still distinguish them, because it is
#: handed the enum *member* and so knows which enum class it came from; see
#: its ``qualify_pressure_reference`` argument.
#: Exhaustiveness over the generated unit enums is enforced by a test.
UNIT_SYMBOLS: dict[str, str] = {
    # Area
    "CentimetreSquared": "cm²",
    "FootSquared": "ft²",
    "InchSquared": "in²",
    "MetreSquared": "m²",
    "MillimetreSquared": "mm²",
    "YardSquared": "yd²",
    # Density / mass concentration
    "KilogramPerLitre": "kg/L",
    "KilogramPerMetreCubed": "kg/m³",
    "PoundMassPerFootCubed": "lb/ft³",
    "PoundMassPerUsGallon": "lb/gal",
    # Dynamic viscosity
    "Centipoise": "cP",
    "MillipascalSecond": "mPa·s",
    "PascalSecond": "Pa·s",
    "Poise": "P",
    # Electric current
    "Ampere": "A",
    "Kiloampere": "kA",
    "Milliampere": "mA",
    # Energy density
    "JoulePerCubicMetre": "J/m³",
    "KilojoulePerCubicMetre": "kJ/m³",
    # Energy
    "Joule": "J",
    "Kilojoule": "kJ",
    "KilowattHour": "kWh",
    "Megajoule": "MJ",
    "MegawattHour": "MWh",
    # Force
    "KiloNewton": "kN",
    "Newton": "N",
    # Heat capacity
    "BtuITPerDegreeFahrenheit": "Btu(IT)/°F",
    "BtuThPerDegreeFahrenheit": "Btu(th)/°F",
    "WattPerKelvin": "W/K",
    # Heat transfer coefficient
    "KilowattPerMetreSquaredKelvin": "kW/(m²·K)",
    "WattPerMetreSquaredKelvin": "W/(m²·K)",
    # Heat transfer resistance
    "FootSquaredHourDegreeFahrenheitPerBtuTh": "ft²·h·°F/Btu(th)",
    "MetreSquaredKelvinPerWatt": "m²·K/W",
    # Kinematic viscosity
    "CentimetreSquaredPerSecond": "cm²/s",
    "Centistoke": "cSt",
    "MetreSquaredPerSecond": "m²/s",
    "Stoke": "St",
    # Length / particle size
    "Centimetre": "cm",
    "Foot": "ft",
    "Inch": "in",
    "Kilometre": "km",
    "Metre": "m",
    "Micrometre": "µm",
    "Millimetre": "mm",
    "Nanometre": "nm",
    # Magnetic field intensity
    "AmperePerMetre": "A/m",
    "KiloamperePerMetre": "kA/m",
    "Oersted": "Oe",
    # Magnetic flux density
    "Gauss": "G",
    "Tesla": "T",
    # Mass flow rate
    "KilogramPerHour": "kg/h",
    "KilogramPerMinute": "kg/min",
    "KilogramPerSecond": "kg/s",
    "PoundMassPerHour": "lb/h",
    "PoundMassPerMinute": "lb/min",
    "PoundMassPerSecond": "lb/s",
    # Mass-specific energy
    "KilojoulePerKilogram": "kJ/kg",
    "MegajoulePerKilogram": "MJ/kg",
    # Mass-specific heat capacity
    "BtuITPerPoundDegreeFahrenheit": "Btu(IT)/(lb·°F)",
    "KilojoulePerKilogramKelvin": "kJ/(kg·K)",
    # Mass
    "Gram": "g",
    "Kilogram": "kg",
    "PoundMass": "lb",
    "Tonne": "t",
    # Mole concentration
    "MillimolePerLitre": "mmol/L",
    "MolePerLitre": "mol/L",
    # Mole flow rate
    "KilomolePerSecond": "kmol/s",
    "PoundMolePerSecond": "lbmol/s",
    # Mole-specific energy
    "JoulePerMole": "J/mol",
    "KilocaloriePerMole": "kcal/mol",
    "KilojoulePerKilomole": "kJ/kmol",
    "KilojoulePerMole": "kJ/mol",
    # Moment of force
    "NewtonMetre": "N·m",
    "PoundForceFoot": "lbf·ft",
    # Ratio (DEXPI 2.0.1's RatioUnit, PercentageUnit in 2.0). A fraction is a bare number: it
    # has no symbol, and DEXPI's unit table gives it none.
    "Fraction": "",
    "PartsPerBillion": "ppb",
    "PartsPerMillion": "ppm",
    "PartsPerThousand": "‰",
    "Percent": "%",
    # Power
    "Kilowatt": "kW",
    "Megawatt": "MW",
    "Watt": "W",
    # Pressure (absolute and gauge share these values)
    "Bar": "bar",
    "Kilopascal": "kPa",
    "Megapascal": "MPa",
    "Millibar": "mbar",
    "Pascal": "Pa",
    "PoundForcePerInchSquared": "psi",
    # Surface tension
    "DynePerCentimetre": "dyn/cm",
    "NewtonPerMetre": "N/m",
    "PoundForcePerInch": "lbf/in",
    # Temperature
    "DegreeCelsius": "°C",
    "DegreeFahrenheit": "°F",
    "Kelvin": "K",
    # Thermal conductivity
    "BtuITPerHourFootDegreeFahrenheit": "Btu(IT)/(h·ft·°F)",
    "WattPerMetreKelvin": "W/(m·K)",
    # Time interval
    "Day": "d",
    "Hour": "h",
    "Millisecond": "ms",
    "Minute": "min",
    "Month": "mo",
    "Second": "s",
    "Year": "yr",
    # Velocity
    "FootPerSecond": "ft/s",
    "KilometrePerHour": "km/h",
    "MetrePerSecond": "m/s",
    "MilePerHour": "mph",
    "NauticalMilePerHour": "kn",
    # Voltage
    "KiloVolt": "kV",
    "MegaVolt": "MV",
    "Volt": "V",
    # Volume flow rate
    "FootCubedPerHour": "ft³/h",
    "FootCubedPerMinute": "ft³/min",
    "LitrePerSecond": "L/s",
    "MetreCubedPerDay": "m³/d",
    "MetreCubedPerHour": "m³/h",
    "MetreCubedPerMinute": "m³/min",
    "MetreCubedPerSecond": "m³/s",
    # Volume
    "CentimetreCubed": "cm³",
    "DecimetreCubed": "dm³",
    "FootCubed": "ft³",
    "Litre": "L",
    "MetreCubed": "m³",
    "UsFluidOunce": "fl oz",
    "UsGallon": "gal",
    # pH
    "pH": "pH",
    # Frequency
    "Hertz": "Hz",
    "KiloHertz": "kHz",
    "MegaHertz": "MHz",
    "ReciprocalMinute": "1/min",
    "ReciprocalSecond": "1/s",
}


#: Suffixes appended to a pressure symbol when the gauge/absolute reference is
#: made explicit: ``"bar"`` -> ``"barg"`` / ``"bara"``, ``"psi"`` -> ``"psig"``.
_PRESSURE_REFERENCE_SUFFIXES: tuple[tuple[type[Enum], str], ...] = (
    (PressureGaugeUnit, "g"),
    (PressureAbsoluteUnit, "a"),
)


def float_to_str(value: float) -> str:
    """Format a float without a trailing ``.0``.

    Parameters
    ----------
    value : float
        The numeric value to format.

    Returns
    -------
    str
        ``"<int>"`` if ``value`` is a whole number (e.g., ``3.0 -> "3"``), otherwise
        the standard string representation of the float.
    """
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def number_with_decimals(value: float, decimals: int | None) -> str:
    """Format a number with a fixed count of digits after the decimal point.

    Parameters
    ----------
    value : float
        The number, an ``int`` or a ``float``.
    decimals : int | None
        How many digits to write after the decimal point, at least 0. None writes the number as
        :func:`float_to_str` does.

    Returns
    -------
    str
        The number rounded half away from zero, as an engineer rounds and not as binary floats
        do: ``2.675`` with two decimals is ``"2.68"``, ``12.5`` is ``"12.50"``, ``3`` with no
        decimals is ``"3"`` and ``2.5`` is ``"3"``. A float is rounded from its shortest
        representation (``repr``), so the result is what the stored number reads as. A
        negative number that rounds to zero is written without its sign. A non-finite float
        (``nan``, ``inf``) has no digits to fix and is written as :func:`float_to_str` writes it.

    Raises
    ------
    ValueError
        If `decimals` is negative.
    """
    if decimals is None or (isinstance(value, float) and not math.isfinite(value)):
        return float_to_str(value)
    if decimals < 0:
        raise ValueError(f"A number cannot be written with {decimals} decimals.")
    exact = Decimal(repr(value)) if isinstance(value, float) else Decimal(value)
    # Enough digits for the whole part, the decimals and a carry: the default 28 would make
    # quantize raise for a large value, 1e20 with 10 decimals.
    with localcontext() as context:
        context.prec = max(context.prec, exact.adjusted() + decimals + 2)
        rounded = exact.quantize(Decimal(1).scaleb(-decimals), rounding=ROUND_HALF_UP)
    if rounded.is_zero():
        rounded = abs(rounded)
    return f"{rounded:f}"


def unit_symbol(unit: Enum, *, qualify_pressure_reference: bool = False) -> str:
    """Return the display symbol for a ``PhysicalQuantityUnit`` literal.

    Parameters
    ----------
    unit : Enum
        A unit literal from the generated DEXPI unit enums.
    qualify_pressure_reference : bool, default ``False``
        If True, append ``"g"`` to gauge pressures and ``"a"`` to absolute
        pressures (``"barg"``, ``"bara"``, ``"psig"``).  Off by default so the
        table export keeps rendering the bare symbol; label materialization
        turns it on, because P&ID labels conventionally spell the reference out
        and the DEXPI reference drawing does too.

    Returns
    -------
    str
        The conventional symbol (``"m"``, ``"kg/h"``, ``"°C"``), or the raw
        enum value for unmapped literals.  ``RatioUnit.Fraction`` has no symbol
        and renders ``""``; join a value to a symbol with
        :func:`value_with_symbol`, which then writes the bare number.
    """
    symbol = UNIT_SYMBOLS.get(unit.value, unit.value)
    if qualify_pressure_reference:
        for unit_enum, suffix in _PRESSURE_REFERENCE_SUFFIXES:
            if isinstance(unit, unit_enum):
                return symbol + suffix
    return symbol


def value_with_symbol(value_text: str, symbol: str) -> str:
    """Join a rendered value and a unit symbol as ``"<value> <symbol>"``.

    Parameters
    ----------
    value_text : str
        The rendered number (or numbers), e.g. ``"60"``.
    symbol : str
        The unit symbol from :func:`unit_symbol`, e.g. ``"barg"``.

    Returns
    -------
    str
        ``"60 barg"``; just the value when the symbol is empty (a
        ``RatioUnit.Fraction``), never with a trailing space.
    """
    return f"{value_text} {symbol}" if symbol else value_text
