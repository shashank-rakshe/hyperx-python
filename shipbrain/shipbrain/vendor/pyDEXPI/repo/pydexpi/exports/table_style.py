"""Industrial document styling for the Excel table export.

This module carries the style spec -- fonts, fills, borders, the title-block
layout -- applied by :func:`pydexpi.exports.table_export.export_tables` when
writing ``.xlsx`` files.  The styling is programmatic on purpose: the column
set of every table varies per model, so a static workbook template could not
carry the table body.  This module *is* the template.

The styled sheet layout is::

    row 1               sheet title (translated list name)
    rows 2 .. n+1       title block: label / value pairs for the fields in
                        TITLE_BLOCK_FIELDS that the model actually carries
    row n+2             blank spacer
    row n+3             data header (bold on dark fill, autofilter, frozen)
    rows n+4 ..         data, thin borders

With ``styled=False`` none of this applies and the data header sits in row 1,
matching the historical layout.  Use :func:`data_header_row` to compute the
``header=`` offset for reading a styled sheet back with ``pd.read_excel``.
"""

import pandas as pd
from openpyxl.styles import Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.workbook import Workbook
from openpyxl.worksheet.properties import PageSetupProperties
from openpyxl.worksheet.worksheet import Worksheet

from pydexpi.attribution import generator_string
from pydexpi.exports.table_locale import translate_label

__all__ = [
    "MAX_COLUMN_WIDTH",
    "TITLE_BLOCK_FIELDS",
    "data_header_row",
    "set_column_widths",
    "set_workbook_properties",
    "style_table",
    "title_block_rows",
    "write_title_block",
]

#: Title-block fields in display order: (provenance key, canonical English
#: label).  Keys are the ``get_model_provenance`` output keys; labels go
#: through :func:`pydexpi.exports.table_locale.translate_label`.
TITLE_BLOCK_FIELDS: tuple[tuple[str, str], ...] = (
    ("projectName", "Project"),
    ("drawingNumber", "Drawing number"),
    ("drawingName", "Drawing"),
    ("sheetNumber", "Sheet"),
    ("revisionNumber", "Revision"),
    ("creationDateRepresentation", "Date created"),
    ("creatorName", "Created by"),
    ("approverName", "Approved by"),
    ("originatingSystemName", "Originating system"),
    ("enterpriseName", "Enterprise"),
    ("siteName", "Site"),
    ("processPlantName", "Plant"),
    ("confidentiality", "Confidentiality"),
)

#: Column widths are content-sized but never wider than this (in Excel
#: character units), so a single long cell cannot blow up the layout.
MAX_COLUMN_WIDTH = 60

_ACCENT = "1F4E79"  # dark steel blue, the traditional engineering-register look
_THIN_SIDE = Side(style="thin", color="B0B0B0")
_MEDIUM_SIDE = Side(style="medium", color=_ACCENT)

TITLE_FONT = Font(bold=True, size=14)
LABEL_FONT = Font(bold=True, size=10)
HEADER_FONT = Font(bold=True, size=10, color="FFFFFF")
HEADER_FILL = PatternFill("solid", fgColor=_ACCENT)
HEADER_BORDER = Border(left=_THIN_SIDE, right=_THIN_SIDE, top=_MEDIUM_SIDE, bottom=_MEDIUM_SIDE)
DATA_BORDER = Border(left=_THIN_SIDE, right=_THIN_SIDE, top=_THIN_SIDE, bottom=_THIN_SIDE)


def title_block_rows(provenance: dict, language: str) -> list[tuple[str, str]]:
    """Build the (label, value) rows of the title block.

    Parameters
    ----------
    provenance : dict
        Output of :func:`pydexpi.toolkits.model_provenance.get_model_provenance`.
    language : str
        Language for the labels.

    Returns
    -------
    list[tuple[str, str]]
        One (translated label, value) pair per :data:`TITLE_BLOCK_FIELDS`
        entry present in *provenance*; absent fields are omitted.
    """
    rows = []
    for key, label in TITLE_BLOCK_FIELDS:
        value = provenance.get(key)
        if value is None:
            continue
        if key == "sheetNumber" and provenance.get("totalNumberOfSheets") is not None:
            value = f"{value} / {provenance['totalNumberOfSheets']}"
        rows.append((translate_label(label, language), str(value)))
    return rows


def data_header_row(provenance: dict, language: str, styled: bool) -> int:
    """Return the 1-based worksheet row that holds the data header.

    ``pd.read_excel(path, header=data_header_row(...) - 1)`` reads the data
    back regardless of styling.
    """
    if not styled:
        return 1
    # sheet title + title-block rows + blank spacer, then the header
    return len(title_block_rows(provenance, language)) + 3


def write_title_block(ws: Worksheet, rows: list[tuple[str, str]], sheet_title: str) -> None:
    """Write the sheet title and the label / value rows above the table.

    Parameters
    ----------
    ws : Worksheet
        The worksheet to write into.
    rows : list[tuple[str, str]]
        Output of :func:`title_block_rows`.
    sheet_title : str
        The (translated) list name shown in row 1.
    """
    ws.cell(row=1, column=1, value=sheet_title).font = TITLE_FONT
    for row_index, (label, value) in enumerate(rows, start=2):
        ws.cell(row=row_index, column=1, value=label).font = LABEL_FONT
        ws.cell(row=row_index, column=2, value=value)


def style_table(ws: Worksheet, *, header_row: int, n_rows: int, n_cols: int) -> None:
    """Style the data table and set up filtering, freezing, and printing.

    Parameters
    ----------
    ws : Worksheet
        The worksheet holding the table.
    header_row : int
        1-based row of the data header.
    n_rows, n_cols : int
        Data dimensions; with ``n_cols == 0`` (an empty table) only the pane
        freeze and print setup are applied.
    """
    if n_cols:
        for column in range(1, n_cols + 1):
            cell = ws.cell(row=header_row, column=column)
            cell.font = HEADER_FONT
            cell.fill = HEADER_FILL
            cell.border = HEADER_BORDER
        for row in range(header_row + 1, header_row + 1 + n_rows):
            for column in range(1, n_cols + 1):
                ws.cell(row=row, column=column).border = DATA_BORDER
        last_cell = f"{get_column_letter(n_cols)}{header_row + n_rows}"
        ws.auto_filter.ref = f"A{header_row}:{last_cell}"
    ws.freeze_panes = f"A{header_row + 1}"
    ws.page_setup.orientation = "landscape"
    ws.page_setup.fitToWidth = 1
    ws.page_setup.fitToHeight = 0
    ws.sheet_properties.pageSetUpPr = PageSetupProperties(fitToPage=True)
    ws.print_title_rows = f"{header_row}:{header_row}"


def set_column_widths(
    ws: Worksheet, df: pd.DataFrame, extra_first_column_texts: tuple[str, ...] = ()
) -> None:
    """Size the columns: first column to its content, the rest to the header.

    Parameters
    ----------
    ws : Worksheet
        The worksheet to size.
    df : pd.DataFrame
        The table the sheet holds, used to measure content.
    extra_first_column_texts : tuple[str, ...], optional
        Additional texts sharing column A (the sheet title and the
        title-block labels), so they stay visible too.
    """
    extra_lengths = [len(str(text)) for text in extra_first_column_texts]
    if len(df.columns) == 0:
        if extra_lengths:
            ws.column_dimensions["A"].width = min(max(extra_lengths) + 2, MAX_COLUMN_WIDTH)
        return
    for index, column in enumerate(df.columns, 1):
        if index == 1:
            lengths = [len(str(cell)) for cell in df[column].astype(str).tolist()]
            lengths += [len(str(column)), *extra_lengths]
            width = max(lengths) + 2
        else:
            width = len(str(column)) + 2
        ws.column_dimensions[get_column_letter(index)].width = min(width, MAX_COLUMN_WIDTH)


def set_workbook_properties(wb: Workbook, provenance: dict) -> None:
    """Fill the workbook's core document properties from model provenance.

    The Excel "Company" property lives in the extended properties, which
    openpyxl regenerates at save time, so ``enterpriseName`` goes into the
    description instead.
    """
    properties = wb.properties
    if (value := provenance.get("drawingName")) is not None:
        properties.title = str(value)
    if (value := provenance.get("creatorName")) is not None:
        properties.creator = str(value)
    if (value := provenance.get("projectName")) is not None:
        properties.subject = str(value)
    if (value := provenance.get("confidentiality")) is not None:
        properties.category = str(value)
    keywords = [
        str(provenance[key])
        for key in ("drawingNumber", "revisionNumber", "projectNumber")
        if provenance.get(key) is not None
    ]
    if keywords:
        properties.keywords = ", ".join(keywords)
    description = [
        str(provenance[key])
        for key in ("enterpriseName", "siteName", "processPlantName")
        if provenance.get(key) is not None
    ]
    if (value := provenance.get("originatingSystemName")) is not None:
        description.append(f"Exported from {value}")
    # Distinct from the line above: that names the tool that authored the P&ID,
    # this names the tool that wrote this workbook. Kept out of the title block so
    # the data header row does not move.
    description.append(f"Generated with {generator_string()}")
    if description:
        properties.description = "; ".join(description)
