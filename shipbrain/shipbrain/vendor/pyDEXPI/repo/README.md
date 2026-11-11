<!-- omit from toc -->
# pyDEXPI by [<img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/logos/Process_Intelligence_Black_Horizontal.png" alt="Process Intelligence Research logo" height="40" style="background-color: white; padding: 10px;">](https://www.pi-research.org/)

<p align="center">
  <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/refs/heads/master/docs/logos/pydexpi_logo.png" alt="pyDEXPI logo" width="700" style="background-color: white; padding: 10px;">  
</p>

## Overview

pyDEXPI is an open-source engineering toolkit for working with Process Flow Diagrams (PFDs) and
Piping and Instrumentation Diagrams (P&IDs) using the [DEXPI](https://dexpi.org/) standard.
It brings together **import/export, analysis, visualization, and validation** through a
**Python library, command-line interface (CLI), and Model Context Protocol (MCP) server**.

Use pyDEXPI to integrate DEXPI models into engineering software, automate diagram workflows, or
give AI agents structured tools to inspect models. Import diagnostics, model validation,
and [format-fidelity tests](#format-fidelity-tests) support reliable data exchange.

The official DEXPI specification defines the engineering information model. pyDEXPI builds on
generated [Pydantic](https://docs.pydantic.dev/) classes with the tools needed to use that model
in applications.

Implements DEXPI version 2.0.1 (`pydexpi.DEXPI_SPEC_VERSION`), and writes DEXPI 2.0.1 XML and
JSON. DEXPI 2.0 files are read too, converted to 2.0.1 as they load.


<p align="center">
  <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/pyDEXPI_graphical_overview.png" alt="pyDEXPI graphical overview" width="700">  
</p>

### Features

- **Import and export:** load and save DEXPI XML and JSON, import legacy Proteus XML, and inspect
  parsing diagnostics.
- **Analyze and query:** find objects, inspect connectivity and paths with the
  [Query API](docs/mkdocs/query_api.md), and work with [NetworkX](https://networkx.org/) graphs.
- **Visualize:** render diagrams and component symbols to SVG, with optional
  [PNG and PDF exports](docs/mkdocs/png_pdf_export.md).
- **Automate:** use Python for integrations, the CLI for conversions and exports, and MCP tools
  for agent-driven model workflows.
- **Generate synthetic P&IDs:** assemble diagram patterns you provide for research and AI/ML
  datasets.

### Choose your interface

| Interface | Use it for | Start here |
| --- | --- | --- |
| Python library | Integrations, analysis, and rendering | [Python usage](docs/mkdocs/usage.md) |
| CLI (`pydexpi`) | Model summaries, format conversion, rendering, and table/graph exports | [Command-line usage](#command-line-usage) |
| MCP server (`pydexpi-mcp`) | Let an LLM client load, query, validate, and export models | [MCP setup](#mcp-server) |

### Citation

Please reference this software package as:

```
@InProceedings{pyDEXPI,
  author    = {Goldstein, Dominik P. and Schulze Balhorn, Lukas and Alimin, Achmad Anggawirya and Schweidtmann, Artur M.},
  booktitle = {Proceedings of the 35th European Symposium on Computer Aided Process Engineering (ESCAPE35)},
  title     = {pyDEXPI:{A} {Python} framework for piping and instrumentation diagrams using the {DEXPI} information model},
  year      = {2025},
  address   = {Ghent, Belgium},
  month     = {July},
  doi       = {https://doi.org/10.69997/sct.139043},
}
```

## Table of contents

- [Overview](#overview)
  - [Features](#features)
  - [Choose your interface](#choose-your-interface)
  - [Citation](#citation)
- [Table of contents](#table-of-contents)
- [Documentation](#documentation)
- [Installation](#installation)
- [Command-line usage](#command-line-usage)
- [MCP server](#mcp-server)
- [Getting started with pyDEXPI](#getting-started-with-pydexpi)
- [Development](#development)
- [Relevant applications and references](#relevant-applications-and-references)
- [Contributors](#contributors)
- [Copyright and license](#copyright-and-license)
- [Contact](#contact)

## Documentation

The [documentation](https://www.pydexpi.org/) covers Python workflows,
the CLI, and MCP, with application examples and an API reference.

## Installation

Install the pyDEXPI package via

```bash
pip install pydexpi
```

or from GitHub via:

```bash
pip install git+https://github.com/process-intelligence-research/pyDEXPI
```

Alternatively, get the latest updates by cloning the repo and installing the editable version of the package with:

```bash
git clone https://github.com/process-intelligence-research/pyDEXPI
cd pyDEXPI
pip install .
```

## Command-line usage

Install the CLI extra to use the `pydexpi` command:

```bash
pip install pydexpi[cli]
```

It wraps the most common pyDEXPI workflows so you can use them without writing Python.

```bash
# Print a model summary
pydexpi info data/reference_pid.xml

# Convert XML to JSON (or JSON to XML)
pydexpi convert data/reference_pid.xml -o output.json

# Render a P&ID to SVG
pydexpi svg data/reference_pid.xml -o diagram.svg

# Export equipment / line / instrument / valve tables to styled Excel
pydexpi export-table data/reference_pid.xml -o tables

# Same tables with German headers and sheet names
pydexpi export-table data/reference_pid.xml -o tabellen --language de

# Export the plant graph as GraphML
pydexpi export-graph data/reference_pid.xml -o graph.graphml --level process
```

Run `pydexpi --help` or `pydexpi <command> --help` for full option details.
See [CLI guide](docs/mkdocs/cli.md) for comprehensive documentation.

## MCP server

pyDEXPI includes a [Model Context Protocol](https://modelcontextprotocol.io/) server, so LLM
clients such as Claude Desktop, Claude Code and Cursor can load, query and export DEXPI
models. Install the `mcp` extra and register the `pydexpi-mcp` command with your client:

```bash
pip install "pydexpi[mcp]"
claude mcp add pydexpi -- pydexpi-mcp   # Claude Code
```

The server runs over stdio by default, or over streamable HTTP / SSE with a separate session per
client. See [docs/mkdocs/mcp.md](docs/mkdocs/mcp.md) for its tools, resources, transports and
client configuration.

## Getting started with pyDEXPI

```python
from pydexpi.loaders import DexpiXmlSerializer

directory_path = "data"
filename = "reference_pid.xml"
my_loader = DexpiXmlSerializer()
dexpi_model = my_loader.load(directory_path, filename)
```

## Development

Install the development dependencies and use the helper scripts in [`scripts/`](scripts/):

```bash
pip install -e ".[dev,export,cli,mcp]"

./scripts/lint    # format and lint with ruff
./scripts/test    # run the test suite with coverage
```

Both run on every pull request. The `export`, `cli` and `mcp` extras are installed in CI as well,
so the SVG/PNG/PDF conversion tests, the CLI suite and the MCP server suite run rather than skip.

`./scripts/test` measures coverage and fails if it drops below the floor in
`[tool.coverage.report] fail_under` in [`pyproject.toml`](pyproject.toml). The floor is seeded at
the value measured when it was introduced, not at an aspirational number: it is there to stop
coverage sliding backwards, so raise it as coverage improves. Set `COVERAGE=0` when running a
subset, since a partial run measures partial coverage and would trip the floor:

```bash
COVERAGE=0 ./scripts/test -k loaders
```

A full run writes `htmlcov/index.html` for browsing uncovered lines, and `coverage.json`, which
`scripts/coverage_report.py` renders as a per-package summary. CI publishes that summary to the
workflow's **Summary** tab on every pull request and uploads both files as an artifact, including
when the run fails.

### Format-fidelity tests

[`tests/test_roundtrip/`](tests/test_roundtrip/) checks the invariant that composes the
serializers rather than any one of them: a document that is exported and reloaded must be the same
document, across DEXPI XML and JSON. Proteus XML takes part as a source only -- its export path
was discontinued in v1.2.0 and raises, which the suite pins down rather than works around. It
covers golden-file round-trips over
`data/reference_pid.xml`, export determinism, a corpus sweep over `data/`, and property-based
round-trips of generated models via [hypothesis](https://hypothesis.readthedocs.io/).

Paths that are known to be broken carry strict `xfail` markers naming the issue that owns them, so
an `xfail` turning into a pass is a build failure that says "delete this marker" -- each of those
issues has an objective definition of done. Point `PYDEXPI_CORPUS_DIR` at a directory of DEXPI
files to include them in the corpus sweep, and run a deeper property search with:

```bash
COVERAGE=0 ./scripts/test -k roundtrip --hypothesis-profile=thorough
```

## Relevant applications and references

**Vision of GenAI for process engineering**

- Schweidtmann, A. M. (2024). Generative artificial intelligence in chemical engineering. Nature Chemical Engineering, 1(3), 193-193. [https://doi.org/10.1038/s44286-024-00041-5](https://doi.org/10.1038/s44286-024-00041-5)

**Chat interface for P&IDs using Large Language Models (LLMs)**
- Alimin, A. A., & Schweidtmann, A. M. (2026). GraphRAG for Engineering Diagrams: ChatP&ID Enables LLM Interaction with P&IDs. arXiv preprint arXiv:2603.22528. [https://doi.org/10.48550/arXiv.2603.22528](https://doi.org/10.48550/arXiv.2603.22528)
- Alimin, A. A., Goldstein, D. P., Schulze Balhorn, L., & Schweidtmann, A. M. (2025). Talking like piping and instrumentation diagrams (p&ids). Proceedings of the 35th European Symposium on Computer Aided Process Engineering (ESCAPE35), Ghent, Belgium. [https://doi.org/10.69997/sct.159477](https://doi.org/10.69997/sct.159477)

**Error correction of P&IDs**
- Schulze Balhorn, L., Seijsener, N., Dao, K., Kim, M., Goldstein, D. P., Driessen, G. H., & Schweidtmann, A. M. (2025). Rule-based autocorrection of Piping and Instrumentation Diagrams (P&IDs) on graphs. Proceedings of the 35th European Symposium on Computer Aided Process Engineering (ESCAPE35), Ghent, Belgium. [https://doi.org/10.69997/sct.150968](https://doi.org/10.69997/sct.150968)
- Schulze Balhorn, L., Caballero, M., & Schweidtmann, A. M. (2024). Toward autocorrection of chemical process flowsheets using large language models. In Computer Aided Chemical Engineering (Vol. 53, pp. 3109-3114). Elsevier. [https://doi.org/10.1016/B978-0-443-28824-1.50519-6](https://doi.org/10.1016/B978-0-443-28824-1.50519-6)

- Schulze Balhorn, L., Seijsener, N., Dao, K., Kim, M., Goldstein, D. P., Driessen, G. H., & Schweidtmann, A. M. (2025). Rule-based autocorrection of Piping and Instrumentation Diagrams (P&IDs) on graphs. Proceedings of the 35th European Symposium on Computer Aided Process Engineering (ESCAPE35), Ghent, Belgium. [https://doi.org/10.69997/sct.150968](https://doi.org/10.69997/sct.150968)
- Schulze Balhorn, L., Caballero, M., & Schweidtmann, A. M. (2024). Toward autocorrection of chemical process flowsheets using large language models. In Computer Aided Chemical Engineering (Vol. 53, pp. 3109-3114). Elsevier. [https://doi.org/10.1016/B978-0-443-28824-1.50519-6](https://doi.org/10.1016/B978-0-443-28824-1.50519-6)

**Process development**
- Vogel, G., Schulze Balhorn, L., & Schweidtmann, A. M. (2023). Learning from flowsheets: A generative transformer model for autocompletion of flowsheets. Computers & Chemical Engineering, 171, 108162. [https://doi.org/10.1016/j.compchemeng.2023.108162](https://doi.org/10.1016/j.compchemeng.2023.108162)
- Schulze Balhorn, L., Hirtreiter, E., Luderer, L., & Schweidtmann, A. M. (2023). Data augmentation for machine learning of chemical process flowsheets. In Computer Aided Chemical Engineering (Vol. 52, pp. 2011-2016). Elsevier. [https://doi.org/10.1016/B978-0-443-15274-0.50320-6](https://doi.org/10.1016/B978-0-443-15274-0.50320-6)
- Hirtreiter, E., Schulze Balhorn, L., & Schweidtmann, A. M. (2024). Toward automatic generation of control structures for process flow diagrams with large language models. AIChE Journal, 70(1), e18259. [https://doi.org/10.1002/aic.18259](https://doi.org/10.1002/aic.18259)
- Schulze Balhorn, L., Degens, K., & Schweidtmann, A. M. (2025). Graph-to-SFILES: Control structure prediction from process topologies using generative artificial intelligence. Computers & Chemical Engineering, 109121. [https://doi.org/10.1016/j.compchemeng.2025.109121](https://doi.org/10.1016/j.compchemeng.2025.109121)

**Digitization of paper P&IDs to smartP&IDs**
- Theisen, M. F., Flores, K. N., Schulze Balhorn, L., & Schweidtmann, A. M. (2023). Digitization of chemical process flow diagrams using deep convolutional neural networks. Digital chemical engineering, 6, 100072. [https://doi.org/10.1016/j.dche.2022.100072](https://doi.org/10.1016/j.dche.2022.100072)
- [Digitization Companion](https://www.digitization-companion.com/)

## Contributors

| | | |
| --- | --- | --- |
| <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/photos/Donimik.jpg" width="50"> | [Dominik P. Goldstein](https://www.pi-research.org/author/dominik-goldstein/) | <a href="https://www.linkedin.com/in/dominik-goldstein-9a669324b/" rel="nofollow noreferrer"> <img src="https://i.sstatic.net/gVE0j.png" >  </a> <a href="https://scholar.google.com/citations?user=4s7fSyIAAAAJ&hl=en" rel="nofollow noreferrer"> <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/logos/google-scholar-square.svg" width="14">  </a> |
| <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/photos/Lukas.jpg" width="50"> | [Lukas Schulze Balhorn](https://www.pi-research.org/author/lukas-schulze-balhorn/) | <a href="https://www.linkedin.com/in/lukas-schulze-balhorn-12a3a4205/" rel="nofollow noreferrer"> <img src="https://i.sstatic.net/gVE0j.png" >  </a> <a href="https://scholar.google.com/citations?user=LZZ7piQAAAAJ&hl=en" rel="nofollow noreferrer"> <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/logos/google-scholar-square.svg" width="14">  </a> |
| <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/photos/Achmad.png" width="50"> | [Achmad Anggawirya Alimin](https://www.pi-research.org/author/achmad-a.-alimin/) | <a href="https://www.linkedin.com/in/anggawirya/" rel="nofollow noreferrer"> <img src="https://i.sstatic.net/gVE0j.png" >  </a> <a href="https://scholar.google.com/citations?user=zO7yftgAAAAJ&hl=en" rel="nofollow noreferrer"> <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/logos/google-scholar-square.svg" width="14">  </a> |
| <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/photos/Artur.jpg" width="50"> | [Artur M. Schweidtmann](https://www.pi-research.org/author/artur-schweidtmann/) | <a href="https://www.linkedin.com/in/schweidtmann/" rel="nofollow noreferrer"> <img src="https://i.sstatic.net/gVE0j.png" >  </a> <a href="https://scholar.google.com/citations?user=g-GwouoAAAAJ&hl=en" rel="nofollow noreferrer"> <img src="https://raw.githubusercontent.com/process-intelligence-research/pyDEXPI/master/docs/logos/google-scholar-square.svg" width="14">  </a> |

## Copyright and license

This software is released under the [OSI-approved](https://opensource.org/license) **GNU Affero General Public License (AGPL-3.0) license**  (see [license file](LICENSE) file for details). We believe in open collaboration and knowledge sharing, and encourage use by **students, researchers, open-source contributors, and industry**. You are free to use, modify, and distribute the software under the given license terms. This is a copyleft license, which means that any software based on pyDEXPI, or any modified version thereof, must be published under the same open-source license.

**Third-party material.** pyDEXPI's generated DEXPI classes (`pydexpi/pydexpi_classes/`) are an
adaptation of the DEXPI Specification 2.0.1, and `data/reference_pid.xml` contains the reference
P&ID of the DEXPI Specification 2.0, both (c) DEXPI (DEXPI e.V.) and licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). [NOTICE](NOTICE) gives their
attribution and the changes made.

**Commercial or Proprietary Use?**

If you would like to:

- Use this software in a proprietary or closed-source product,
- Use it in a way that is not compatible with AGPL copyleft obligations, or
- Obtain dedicated support or feature extensions,

We’re happy to discuss a commercial or custom license on a case-by-case basis.  
Please reach out to us for more information.

Technische Universiteit Delft hereby disclaims all copyright interest in the program “pyDEXPI” - a Python tool for the DEXPI standard - written by Artur M. Schweidtmann. Paulien Herder, Dean of Applied Science

Copyright (C) 2025-2026 Artur Schweidtmann.

## Contact

<!-- omit from toc -->
### Artur Schweidtmann

📧 [Contact](mailto:a.schweidtmann@tudelft.nl)

<p align="left">
<a href="https://twitter.com/ASchweidtmann" target="blank"><img align="center" src="https://img.shields.io/badge/X-000000?style=for-the-badge&logo=x&logoColor=white" alt="fernandezbap" /></a>
</p>

<p align="left">
<a href="https://www.linkedin.com/in/schweidtmann/" target="blank"><img src="https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white" alt="https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white"  /></a>
</p>

<!-- omit from toc -->
### Process Intelligence Research Group

🌐 [PI research](https://pi-research.org)

<p align="left">
<a href="https://www.linkedin.com/company/84022065" target="blank"><img src="https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white" alt="https://img.shields.io/badge/LinkedIn-0077B5?style=for-the-badge&logo=linkedin&logoColor=white"  /></a>
</p>
