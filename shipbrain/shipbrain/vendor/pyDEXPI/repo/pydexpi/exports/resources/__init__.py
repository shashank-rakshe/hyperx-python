"""Packaged static resources for :mod:`pydexpi.exports`.

This package exists so the bundled data files can be located with
:func:`importlib.resources.files`, which works regardless of whether pyDEXPI is
installed as a directory, a wheel or a zip import::

    from importlib.resources import files

    stylesheet = (
        files("pydexpi.exports.resources")
        .joinpath("pydexpi-neo4j-browser.grass")
        .read_text(encoding="utf-8")
    )

Contents
--------
pydexpi-neo4j-browser.grass
    Optional Neo4j Browser graph stylesheet (GRASS) for graphs exported by
    :mod:`pydexpi.exports.neo4j_export`.  Visualisation only — it never affects
    exported data.
"""
