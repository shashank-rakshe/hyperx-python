# Configuration file for the Sphinx documentation builder.
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
#
# Build locally (as in doc/installation.rst):
#   python -m sphinx -b html -W --keep-going -n doc build/docs-html
# (or `make -C doc html`).  Read the Docs uses ../.readthedocs.yaml.

import re
import sys
from pathlib import Path

# Make the pure-Python package importable for autodoc in local builds. The
# package defers its optional shared-library load, so documenting the standalone
# API never requires a native CableDyn DLL.
_REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_REPO_ROOT / "python"))

# -- Project information -----------------------------------------------------

project = "CableDyn"
author = "Jae Hoon Seo"
project_copyright = "2026, Jae Hoon Seo, SMI Lab, Inha University"


def _cmake_project_version() -> str:
    """Return the ``project(... VERSION x.y.z ...)`` value of the top-level CMakeLists.txt.

    The CMake project version is the single source of the release number. Read the Docs
    installs only doc/requirements.txt and the pure-Python package, so the version is parsed
    from the build file rather than taken from an installed distribution.
    """
    text = (_REPO_ROOT / "CMakeLists.txt").read_text(encoding="utf-8")
    match = re.search(r"^\s*project\s*\([^)]*?\bVERSION\s+([0-9]+(?:\.[0-9]+)*)", text,
                      re.MULTILINE | re.IGNORECASE)
    if match is None:
        raise RuntimeError("CMakeLists.txt has no project(... VERSION x.y.z ...) declaration")
    return match.group(1)


release = _cmake_project_version()
version = release

# -- General configuration ---------------------------------------------------

extensions = [
    "myst_parser",
    "sphinx_copybutton",
    "sphinx.ext.autosectionlabel",
    "sphinx.ext.autodoc",
    "sphinx.ext.mathjax",
    "sphinx.ext.napoleon",
    "sphinx.ext.intersphinx",
    "sphinx.ext.githubpages",
]

# The manual is written in reStructuredText; MyST-Markdown lets it include the repository's
# Markdown pages (VALIDATION.md, CHANGELOG.md, and a few reference pages) verbatim.
myst_enable_extensions = [
    "amsmath",
    "attrs_inline",
    "colon_fence",
    "deflist",
    "dollarmath",
    "fieldlist",
    "substitution",
    "tasklist",
]
myst_heading_anchors = 3

# Documents share a heading namespace; prefix section labels by document so the
# large included reference docs cannot collide.
autosectionlabel_prefix_document = True
autosectionlabel_maxdepth = 3

source_suffix = {".rst": "restructuredtext", ".md": "markdown"}
master_doc = "index"
templates_path = ["_templates"]
exclude_patterns = ["_build", "Thumbs.db", ".DS_Store"]

# Included Markdown (../VALIDATION.md, ../CHANGELOG.md, ...) must use absolute GitHub URLs
# for repository files outside doc/, so unresolved cross-references are real errors.
suppress_warnings = ["autosectionlabel.*", "myst.header"]

# `make linkcheck`: these URLs become live only when the release is published.
linkcheck_ignore = [
    r"https://cabledyn\.readthedocs\.io/.*",
    r"https://readthedocs\.org/projects/cabledyn/.*",
    r"https://github\.com/SMI-Lab-Inha/CableDyn/releases/.*",
    r"https://github\.com/SMI-Lab-Inha/CableDyn/tree/v[0-9].*",
    r"https://github\.com/SMI-Lab-Inha/CableDyn/blob/v[0-9].*",
]

# -- HTML output -------------------------------------------------------------

# The official Read the Docs Sphinx theme.
html_theme = "sphinx_rtd_theme"
html_title = "CableDyn documentation"
html_short_title = "CableDyn"
html_last_updated_fmt = "%Y-%m-%d"
html_show_sourcelink = False

html_theme_options = {
    "navigation_depth": 3,
    "collapse_navigation": False,
    "sticky_navigation": True,
    "titles_only": False,
    "style_external_links": True,
    "prev_next_buttons_location": "both",
}

html_context = {
    "display_github": True,
    "github_user": "SMI-Lab-Inha",
    "github_repo": "CableDyn",
    "github_version": "main",
    "conf_py_path": "/doc/",
}

autodoc_typehints = "none"
autodoc_member_order = "bysource"

# Third-party and standard-library types named in docstrings. They are not documented here, and
# the build must not depend on network access to external inventories.
nitpick_ignore = [
    ("py:class", name)
    for name in (
        "array_like",
        "collections.abc.Callable",
        "collections.abc.Iterable",
        "collections.abc.Mapping",
        "collections.abc.Sequence",
        "matplotlib.axes.Axes",
        "mpl_toolkits.mplot3d.Axes3D",
        "numpy.ndarray",
        "numpy.typing.ArrayLike",
        "os.PathLike",
        "pandas.DataFrame",
        "pathlib.Path",
        # NumPy-style type annotations: an optional argument and a set of string choices.
        "optional",
        '{"linear"',
        '"nearest"}',
    )
]
# The DeckModel row and object classes of cabledyn.builder are described by the DeckModel
# methods that create them and are not documented one by one.
nitpick_ignore += [
    ("py:class", name)
    for name in (
        "Attachment",
        "Body",
        "Control",
        "EndConnection",
        "EquivalentBuoyancy",
        "ExternalLoad",
        "Failure",
        "LineType",
        "MoorDynBody",
        "OptionSet",
        "OutputList",
        "Point",
        "Rod",
        "RodEnd",
        "RodType",
        "Section",
        "Stiffener",
        "SyropeIC",
        "Turbine",
    )
]

# -- LaTeX / PDF output ------------------------------------------------------

# XeLaTeX handles the Unicode used throughout the manual (Greek symbols, arrows, the
# multiplication sign) without per-character declarations.
latex_engine = "xelatex"
latex_elements = {
    "papersize": "a4paper",
    "pointsize": "10pt",
}
latex_documents = [
    ("index", "CableDyn.tex", "CableDyn documentation", author, "manual"),
]

# -- EPUB output -------------------------------------------------------------

epub_title = project
epub_author = author
epub_publisher = author
epub_copyright = project_copyright
epub_show_urls = "footnote"
# sphinx.ext.githubpages writes .nojekyll, which has no EPUB media type.
epub_exclude_files = [".nojekyll"]

# Copy-button: strip shell/REPL prompts when copying code blocks.
copybutton_prompt_text = r">>> |\.\.\. |\$ |PS [^>]*> "
copybutton_prompt_is_regexp = True
