# Security policy

pyDEXPI parses XML and JSON files that often come from third-party engineering tools, and its MCP
server can be exposed over a network. Please report a suspected vulnerability privately.

## Reporting a vulnerability

Use GitHub's [private vulnerability reporting](https://github.com/process-intelligence-research/pyDEXPI/security/advisories/new),
or email [a.schweidtmann@tudelft.nl](mailto:a.schweidtmann@tudelft.nl). Please do not open a public
issue. A useful report says which version is affected and includes a minimal file or steps that
reproduce the problem.

## Supported versions

Security fixes go into the latest release on PyPI only.

## Things that are not vulnerabilities

- Unpickling runs code the file names. `PickleSerializer.load` checks that a pickle fits the current
  classes, which is no security measure: load pickles only from sources you trust.
- The MCP server's network transports isolate clients from each other and restrict file access, but
  do not authenticate anyone. See the [MCP documentation](docs/mkdocs/mcp.md) before exposing one.
