# SPDX-License-Identifier: Apache-2.0
"""Python interfaces for CableDyn, the geometrically exact cable and mooring solver.

The standalone-driver API works with the statically linked release executable.
The in-process :class:`CableDyn` class, and the ``abi_version``, ``abi_minor``,
``library_path``, and ``version_string`` helpers, load the CableDyn shared
library on first access. They are deliberately left out of ``__all__`` so that
``from cabledyn import *`` works in installations without the shared library.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from cabledyn.animation import Recorder, Seabed, Snapshots, WaterSurface, animate
from cabledyn.builder import DeckModel, DeckReferenceError, SyropeEA
from cabledyn.checks import (
    API_RP_2SK_SAFETY_FACTORS,
    DNV_OS_E301_PARTIAL_FACTORS,
    DNV_OS_E301_STRENGTH_FACTOR,
    BendCheck,
    BendLimits,
    TensionCheck,
    bend_check,
    mbr_utilisation,
    tension_check,
)
from cabledyn.clearance import (
    Bathymetry,
    ClearanceMatrix,
    LineClearance,
    SeabedClearance,
    clearance_matrix,
    line_clearance,
    read_bathymetry,
    seabed_clearance,
    segment_distance,
)
from cabledyn.compare import ChannelComparison, HistoryComparison, compare_histories
from cabledyn.curves import (
    FatigueCurve,
    api_rp_2sk_curve,
    chain_nominal_area,
    dnv_os_e301_curve,
    dnv_rp_c203_curve,
)
from cabledyn.damage import (
    ChannelDamage,
    DamageProfile,
    LifetimeFatigue,
    SeaStateDamage,
    cable_stress,
    channel_damage,
    damage_along_arc,
    lifetime_fatigue,
    miner_damage,
    study_sea_state_damage,
)
from cabledyn.deck import DeckWriter
from cabledyn.deck_file import DeckFile, GeneratedCase, generate_deck_cases
from cabledyn.driver import (
    CableDynDriver,
    DriverError,
    DriverExecutionError,
    DriverNotFoundError,
    DriverResult,
    read_output,
)
from cabledyn.errors import (
    CableDynError,
    ConvergenceError,
    DeckFormatError,
    OutputFormatError,
    StudyFormatError,
    StudyOutputError,
)
from cabledyn.extremes import (
    GumbelFit,
    WeibullFit,
    block_maxima,
    fit_gumbel,
    fit_weibull,
    upcrossing_maxima,
)
from cabledyn.fatigue import (
    FatigueResult,
    RainflowCycle,
    RainflowHistogram,
    cycle_histogram,
    damage_equivalent_range,
    rainflow_cycles,
)
from cabledyn.formats import (
    CoupledRun,
    MoorDynLineHistory,
    read_coupled_run,
    read_moordyn_line,
    read_moordyn_output,
    read_openfast_output,
    read_table,
)
from cabledyn.geometry import LineGeometry, Touchdown, line_geometry
from cabledyn.processing import fft_filter, moving_average, resample
from cabledyn.profiles import (
    ArcProfile,
    LineField,
    LinePositions,
    available_quantities,
    line_field,
    line_positions,
    line_range_graph,
    profile_at,
    profiles_at,
)
from cabledyn.ranges import (
    RangeGraph,
    element_range_graph,
    node_range_graph,
    read_range_graph,
    read_range_graphs,
    static_range_graph,
)
from cabledyn.results import (
    ChannelStatistics,
    LineNodeHistory,
    LineSegmentHistory,
    ModeShapes,
    NaturalModes,
    OutputTable,
    SpatialStatistics,
    StaticLineSummary,
    StaticProfile,
    TimeHistory,
)
from cabledyn.spectra import (
    CoherenceResult,
    PowerSpectrum,
    SpectralPeak,
    magnitude_squared_coherence,
    power_spectrum,
)
from cabledyn.study import StudyCaseResult, StudyResult, run_study
from cabledyn.summary import (
    ChannelSummary,
    LineSummary,
    SummaryTable,
    channel_summary,
    line_summary,
)
from cabledyn.sweep import parameter_grid
from cabledyn.touchdown import TouchdownHistory, touchdown_history

if TYPE_CHECKING:
    from cabledyn._lib import abi_minor as abi_minor
    from cabledyn._lib import abi_version as abi_version
    from cabledyn._lib import library_path as library_path
    from cabledyn._lib import version_string as version_string
    from cabledyn.model import CableDyn as CableDyn

__all__ = [
    "API_RP_2SK_SAFETY_FACTORS",
    "DNV_OS_E301_PARTIAL_FACTORS",
    "DNV_OS_E301_STRENGTH_FACTOR",
    "ArcProfile",
    "Bathymetry",
    "BendCheck",
    "BendLimits",
    "CableDynDriver",
    "CableDynError",
    "ChannelComparison",
    "ChannelDamage",
    "ChannelStatistics",
    "ChannelSummary",
    "ClearanceMatrix",
    "CoherenceResult",
    "ConvergenceError",
    "CoupledRun",
    "DamageProfile",
    "DeckFile",
    "DeckFormatError",
    "DeckModel",
    "DeckReferenceError",
    "DeckWriter",
    "DriverError",
    "DriverExecutionError",
    "DriverNotFoundError",
    "DriverResult",
    "FatigueCurve",
    "FatigueResult",
    "GeneratedCase",
    "GumbelFit",
    "HistoryComparison",
    "LifetimeFatigue",
    "LineClearance",
    "LineField",
    "LineGeometry",
    "LineNodeHistory",
    "LinePositions",
    "LineSegmentHistory",
    "LineSummary",
    "ModeShapes",
    "MoorDynLineHistory",
    "NaturalModes",
    "OutputFormatError",
    "OutputTable",
    "PowerSpectrum",
    "RainflowCycle",
    "RainflowHistogram",
    "RangeGraph",
    "Recorder",
    "SeaStateDamage",
    "Seabed",
    "SeabedClearance",
    "Snapshots",
    "SpatialStatistics",
    "SpectralPeak",
    "StaticLineSummary",
    "StaticProfile",
    "StudyCaseResult",
    "StudyFormatError",
    "StudyOutputError",
    "StudyResult",
    "SummaryTable",
    "SyropeEA",
    "TensionCheck",
    "TimeHistory",
    "Touchdown",
    "TouchdownHistory",
    "WaterSurface",
    "WeibullFit",
    "animate",
    "api_rp_2sk_curve",
    "available_quantities",
    "bend_check",
    "block_maxima",
    "cable_stress",
    "chain_nominal_area",
    "channel_damage",
    "channel_summary",
    "clearance_matrix",
    "compare_histories",
    "cycle_histogram",
    "damage_along_arc",
    "damage_equivalent_range",
    "dnv_os_e301_curve",
    "dnv_rp_c203_curve",
    "element_range_graph",
    "fft_filter",
    "fit_gumbel",
    "fit_weibull",
    "generate_deck_cases",
    "lifetime_fatigue",
    "line_clearance",
    "line_field",
    "line_geometry",
    "line_positions",
    "line_range_graph",
    "line_summary",
    "magnitude_squared_coherence",
    "mbr_utilisation",
    "miner_damage",
    "moving_average",
    "node_range_graph",
    "parameter_grid",
    "power_spectrum",
    "profile_at",
    "profiles_at",
    "rainflow_cycles",
    "read_bathymetry",
    "read_coupled_run",
    "read_moordyn_line",
    "read_moordyn_output",
    "read_openfast_output",
    "read_output",
    "read_range_graph",
    "read_range_graphs",
    "read_table",
    "resample",
    "run_study",
    "seabed_clearance",
    "segment_distance",
    "static_range_graph",
    "study_sea_state_damage",
    "tension_check",
    "touchdown_history",
    "upcrossing_maxima",
]

__version__ = "0.4.2"


def __getattr__(name: str) -> Any:
    """Load the optional shared-library API only when requested."""
    if name == "CableDyn":
        from cabledyn.model import CableDyn

        return CableDyn
    if name in {"abi_minor", "abi_version", "library_path", "version_string"}:
        from cabledyn import _lib

        return getattr(_lib, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
