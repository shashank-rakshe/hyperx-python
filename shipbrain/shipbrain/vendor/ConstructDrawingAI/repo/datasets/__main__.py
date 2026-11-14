"""``python -m datasets`` — pointer to the registry sub-commands."""

from __future__ import annotations

import sys


def main() -> int:
    """Print the available dataset sub-commands."""
    print(
        "datasets — dataset registry + license-aware prep/audit\n\n"
        "Commands:\n"
        "  python -m datasets.prepare --list      list registered datasets\n"
        "  python -m datasets.prepare <name>      download + convert one dataset to CIR\n"
        "  python -m datasets.prepare --all       prepare every dataset\n"
        "  python -m datasets.audit               fail if any commercial-lane source is unsafe\n"
    )
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
