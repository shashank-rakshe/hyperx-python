"""Translations and unit symbols for the table export.

This module is the single home for every language-dependent string used by
:mod:`pydexpi.exports.table_export` -- sheet names, fixed column headers,
title-block labels, curated attribute labels.  Quantity rendering -- the
unit-symbol map and float formatting -- lives one layer down in
:mod:`pydexpi.toolkits.quantity_format` (so model-level code can use it without
importing this package) and is re-exported here unchanged.  Do not add parallel
translation or unit tables elsewhere.

Canonical labels
----------------
The keys of :data:`LABELS` are the *canonical English* labels exactly as the
table builders produce them.  For attribute-derived headers that is the output
of :func:`pydexpi.exports.table_export.format_string`, whose acronym
lowercasing is therefore baked into the keys here: if that casing ever
changes, the keys change in lockstep.  English is the identity translation --
``translate_label(label, "en")`` returns the label unchanged -- so only
non-English languages carry a dictionary.

Uncurated labels fall back to the canonical English label.  Sub-equipment
headers ("Chamber 1, Nominal diameter") are composite and intentionally not
translated.

Adding a language
-----------------
Add the code to :data:`SUPPORTED_LANGUAGES` and a dictionary with the *same
key set* as the existing languages to :data:`LABELS` and :data:`SHEET_NAMES`
(``tests/test_exports/test_table_locale.py`` enforces both).
"""

from pydexpi.toolkits.quantity_format import UNIT_SYMBOLS, float_to_str, unit_symbol

__all__ = [
    "LABELS",
    "SHEET_NAMES",
    "SUPPORTED_LANGUAGES",
    "UNIT_SYMBOLS",
    "float_to_str",
    "get_sheet_name",
    "normalize_language",
    "translate_label",
    "unit_symbol",
]

#: Languages the table export can label. Language parameters accept any
#: IETF/BCP-47 tag whose primary subtag is listed here ("de-AT" -> "de").
SUPPORTED_LANGUAGES: tuple[str, ...] = ("en", "de", "nl", "zh")

#: Worksheet titles per language, keyed by the ``ListType`` value.  The English
#: entries are the historical sheet names, so ``language="en"`` (the default)
#: produces unchanged workbooks.
SHEET_NAMES: dict[str, dict[str, str]] = {
    "en": {
        "equipment": "Equipment",
        "line": "Line",
        "instrument": "Instrument",
        "piping component": "Piping component",
        "valve": "Valve",
    },
    "de": {
        "equipment": "Apparateliste",
        "line": "Rohrleitungsliste",
        "instrument": "PLT-Stellenliste",
        "piping component": "Rohrleitungsbauteile",
        "valve": "Armaturenliste",
    },
    "nl": {
        "equipment": "Apparatenlijst",
        "line": "Leidinglijst",
        "instrument": "Instrumentenlijst",
        "piping component": "Leidingcomponenten",
        "valve": "Afsluiterlijst",
    },
    "zh": {
        "equipment": "设备表",
        "line": "管线表",
        "instrument": "仪表索引",
        "piping component": "管道元件表",
        "valve": "阀门表",
    },
}

#: Translations of canonical English labels, per non-English language.  Covers
#: three groups under one namespace (the groups never collide): fixed column
#: headers, title-block labels, and curated attribute labels keyed by
#: ``format_string`` output.
LABELS: dict[str, dict[str, str]] = {
    "de": {
        # Fixed column headers
        "Tag": "Kennzeichen",
        "Equipment type": "Apparatetyp",
        "Valve type": "Armaturentyp",
        "Operated valve": "Betätigte Armatur",
        "Sensing location": "Messort",
        "Piping component": "Rohrleitungsbauteil",
        "Piping component number": "Bauteilnummer",
        "Segment number": "Segmentnummer",
        "Line number": "Leitungsnummer",
        "Nominal diameter": "Nennweite",
        # Title-block labels
        "Project": "Projekt",
        "Drawing number": "Zeichnungsnummer",
        "Drawing": "Zeichnung",
        "Sheet": "Blatt",
        "Revision": "Revision",
        "Date created": "Erstellt am",
        "Created by": "Erstellt von",
        "Approved by": "Genehmigt von",
        "Originating system": "Quellsystem",
        "Enterprise": "Unternehmen",
        "Site": "Standort",
        "Plant": "Anlage",
        "Confidentiality": "Vertraulichkeit",
        # Curated attribute labels (keys = format_string output)
        "Design pressure": "Auslegungsdruck",
        "Design temperature": "Auslegungstemperatur",
        "Operating pressure": "Betriebsdruck",
        "Operating temperature": "Betriebstemperatur",
        "Lower limit design pressure": "Min. Auslegungsdruck",
        "Upper limit design pressure": "Max. Auslegungsdruck",
        "Lower limit design temperature": "Min. Auslegungstemperatur",
        "Upper limit design temperature": "Max. Auslegungstemperatur",
        "Design pressure head": "Auslegungsförderhöhe",
        "Design rotational speed": "Auslegungsdrehzahl",
        "Design shaft power": "Auslegungswellenleistung",
        "Design volume flow rate": "Auslegungsvolumenstrom",
        "Design heat flow rate": "Auslegungswärmestrom",
        "Design heat transfer area": "Wärmeübertragungsfläche (Auslegung)",
        "Nominal capacity volume": "Nennvolumen",
        "Material of construction code": "Werkstoffcode",
        "Fluid code": "Medium-Code",
        "Insulation thickness": "Isolierdicke",
        "Insulation type": "Isolierart",
        "Piping class code": "Rohrklasse",
        "Nominal diameter standard": "Nennweitennorm",
        "Nominal diameter representation": "Nennweite (Darstellung)",
        "Nominal diameter type representation": "Nennweitentyp",
        "Nominal diameter numerical value representation": "Nennweite (Zahlenwert)",
        "Primary secondary piping network segment": "Primär-/Sekundärleitung",
        "Set pressure high": "Ansprechdruck hoch",
        "Set pressure low": "Ansprechdruck niedrig",
        "Position number": "Positionsnummer",
        "Piping component name": "Bauteilname",
        "Number of ports": "Anzahl Anschlüsse",
        "Operation": "Betätigungsart",
        "Location": "Einbauort",
        "Process instrumentation function category": "PLT-Funktionskategorie",
        "Process instrumentation function number": "PLT-Funktionsnummer",
        "Process instrumentation functions": "PLT-Funktionen",
        "Heat tracing type": "Begleitheizungsart",
        "Flow direction": "Durchflussrichtung",
        "Inclination": "Neigung",
        "On hold": "Zurückgestellt",
        "Pressure test circuit number": "Druckprüfkreisnummer",
    },
    "nl": {
        # Fixed column headers
        "Tag": "Tag",
        "Equipment type": "Apparaattype",
        "Valve type": "Afsluitertype",
        "Operated valve": "Bediende afsluiter",
        "Sensing location": "Meetlocatie",
        "Piping component": "Leidingcomponent",
        "Piping component number": "Componentnummer",
        "Segment number": "Segmentnummer",
        "Line number": "Leidingnummer",
        "Nominal diameter": "Nominale diameter",
        # Title-block labels
        "Project": "Project",
        "Drawing number": "Tekeningnummer",
        "Drawing": "Tekening",
        "Sheet": "Blad",
        "Revision": "Revisie",
        "Date created": "Aangemaakt op",
        "Created by": "Aangemaakt door",
        "Approved by": "Goedgekeurd door",
        "Originating system": "Bronsysteem",
        "Enterprise": "Onderneming",
        "Site": "Locatie",
        "Plant": "Installatie",
        "Confidentiality": "Vertrouwelijkheid",
        # Curated attribute labels (keys = format_string output)
        "Design pressure": "Ontwerpdruk",
        "Design temperature": "Ontwerptemperatuur",
        "Operating pressure": "Bedrijfsdruk",
        "Operating temperature": "Bedrijfstemperatuur",
        "Lower limit design pressure": "Min. ontwerpdruk",
        "Upper limit design pressure": "Max. ontwerpdruk",
        "Lower limit design temperature": "Min. ontwerptemperatuur",
        "Upper limit design temperature": "Max. ontwerptemperatuur",
        "Design pressure head": "Ontwerpopvoerhoogte",
        "Design rotational speed": "Ontwerptoerental",
        "Design shaft power": "Ontwerpasvermogen",
        "Design volume flow rate": "Ontwerpvolumedebiet",
        "Design heat flow rate": "Ontwerpwarmtestroom",
        "Design heat transfer area": "Warmteoverdrachtsoppervlak (ontwerp)",
        "Nominal capacity volume": "Nominaal volume",
        "Material of construction code": "Materiaalcode",
        "Fluid code": "Mediumcode",
        "Insulation thickness": "Isolatiedikte",
        "Insulation type": "Isolatietype",
        "Piping class code": "Leidingklasse",
        "Nominal diameter standard": "Norm nominale diameter",
        "Nominal diameter representation": "Nominale diameter (weergave)",
        "Nominal diameter type representation": "Type nominale diameter",
        "Nominal diameter numerical value representation": "Nominale diameter (getalswaarde)",
        "Primary secondary piping network segment": "Primaire/secundaire leiding",
        "Set pressure high": "Insteldruk hoog",
        "Set pressure low": "Insteldruk laag",
        "Position number": "Positienummer",
        "Piping component name": "Componentnaam",
        "Number of ports": "Aantal aansluitingen",
        "Operation": "Bediening",
        "Location": "Montagelocatie",
        "Process instrumentation function category": "Instrumentfunctiecategorie",
        "Process instrumentation function number": "Instrumentfunctienummer",
        "Process instrumentation functions": "Instrumentfuncties",
        "Heat tracing type": "Tracingtype",
        "Flow direction": "Stromingsrichting",
        "Inclination": "Helling",
        "On hold": "Aangehouden",
        "Pressure test circuit number": "Druktestcircuitnummer",
    },
    "zh": {
        # Fixed column headers
        "Tag": "位号",
        "Equipment type": "设备类型",
        "Valve type": "阀门类型",
        "Operated valve": "操作阀门",
        "Sensing location": "测量位置",
        "Piping component": "管道元件",
        "Piping component number": "元件编号",
        "Segment number": "管段编号",
        "Line number": "管线号",
        "Nominal diameter": "公称直径",
        # Title-block labels
        "Project": "项目",
        "Drawing number": "图号",
        "Drawing": "图纸",
        "Sheet": "图页",
        "Revision": "版次",
        "Date created": "创建日期",
        "Created by": "编制",
        "Approved by": "批准",
        "Originating system": "来源系统",
        "Enterprise": "企业",
        "Site": "厂区",
        "Plant": "装置",
        "Confidentiality": "保密级别",
        # Curated attribute labels (keys = format_string output)
        "Design pressure": "设计压力",
        "Design temperature": "设计温度",
        "Operating pressure": "操作压力",
        "Operating temperature": "操作温度",
        "Lower limit design pressure": "设计压力下限",
        "Upper limit design pressure": "设计压力上限",
        "Lower limit design temperature": "设计温度下限",
        "Upper limit design temperature": "设计温度上限",
        "Design pressure head": "设计扬程",
        "Design rotational speed": "设计转速",
        "Design shaft power": "设计轴功率",
        "Design volume flow rate": "设计体积流量",
        "Design heat flow rate": "设计热负荷",
        "Design heat transfer area": "设计换热面积",
        "Nominal capacity volume": "公称容积",
        "Material of construction code": "材质代号",
        "Fluid code": "介质代号",
        "Insulation thickness": "绝热厚度",
        "Insulation type": "绝热类型",
        "Piping class code": "管道等级",
        "Nominal diameter standard": "公称直径标准",
        "Nominal diameter representation": "公称直径表示",
        "Nominal diameter type representation": "公称直径类型",
        "Nominal diameter numerical value representation": "公称直径数值",
        "Primary secondary piping network segment": "主/次管段",
        "Set pressure high": "整定压力（高）",
        "Set pressure low": "整定压力（低）",
        "Position number": "位置编号",
        "Piping component name": "元件名称",
        "Number of ports": "接口数量",
        "Operation": "操作方式",
        "Location": "安装位置",
        "Process instrumentation function category": "仪表功能类别",
        "Process instrumentation function number": "仪表功能编号",
        "Process instrumentation functions": "仪表功能",
        "Heat tracing type": "伴热类型",
        "Flow direction": "流向",
        "Inclination": "坡度",
        "On hold": "暂缓",
        "Pressure test circuit number": "压力试验回路号",
    },
}


def normalize_language(language: str) -> str:
    """Reduce an IETF/BCP-47 language tag to a supported primary subtag.

    Parameters
    ----------
    language : str
        A language tag such as ``"de"``, ``"de-AT"`` or ``"nl_NL"``.

    Returns
    -------
    str
        The lowercase primary subtag, guaranteed to be in
        :data:`SUPPORTED_LANGUAGES`.

    Raises
    ------
    ValueError
        If the primary subtag is not a supported language.
    """
    primary = language.replace("_", "-").split("-", 1)[0].lower()
    if primary not in SUPPORTED_LANGUAGES:
        supported = ", ".join(SUPPORTED_LANGUAGES)
        raise ValueError(f"Unsupported language {language!r}; supported languages: {supported}")
    return primary


def translate_label(label: str, language: str) -> str:
    """Translate a canonical English label, falling back to the label itself.

    Parameters
    ----------
    label : str
        The canonical English label as produced by the table builders.
    language : str
        Target language tag (any form accepted by :func:`normalize_language`).

    Returns
    -------
    str
        The translated label, or *label* unchanged for English and for
        uncurated labels.
    """
    primary = normalize_language(language)
    if primary == "en":
        return label
    return LABELS[primary].get(label, label)


def get_sheet_name(list_type: str, language: str) -> str:
    """Return the worksheet title for a list type in the given language.

    Parameters
    ----------
    list_type : str
        A ``ListType`` value such as ``"equipment"`` or ``"piping component"``.
    language : str
        Target language tag (any form accepted by :func:`normalize_language`).

    Returns
    -------
    str
        The translated sheet name.
    """
    return SHEET_NAMES[normalize_language(language)][list_type]
