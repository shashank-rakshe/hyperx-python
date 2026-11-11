"""pyDEXPI MCP Server — expose pyDEXPI functionality via the Model Context Protocol."""

#: The SDK releases the server is written against; the ``mcp`` extra in pyproject.toml pins the
#: same range. Importing this module loads no SDK.
SDK_REQUIREMENT = "mcp>=2.3,<3"
