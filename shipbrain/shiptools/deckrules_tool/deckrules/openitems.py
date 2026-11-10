"""P9 (review 2026-10-26): a rule that fails is never silent. record() keeps the place and the error; the deck report and the build
report list them as open items, and the run continues."""
import traceback

ERRORS = []


def record(where, exc):
    tb = traceback.extract_tb(exc.__traceback__)
    at = f'{tb[-1].filename.split("/")[-1]}:{tb[-1].lineno}' if tb else ''
    ERRORS.append({'where': where, 'error': f'{type(exc).__name__}: {exc}'[:300], 'at': at})
