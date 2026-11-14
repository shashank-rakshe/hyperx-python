# Contributing to pyDEXPI

## Contribution terms

By submitting a contribution to this repository, you agree to make it available under the public license applicable to that part of the repository. You also grant a non-exclusive, worldwide, perpetual, irrevocable, royalty-free license to use, reproduce, modify, distribute, and sublicense your contribution under other terms. You retain ownership of your contribution.

## How a contribution reaches a release

pyDEXPI is developed in a private repository, and each release is copied to this public one as a
single commit. A pull request here is therefore not merged directly: a maintainer applies it in the
development repository, with credit to you, and it arrives here with the next release. Open issues
and pull requests here as usual.

## Error handling and logging

pyDEXPI uses two complementary error-reporting mechanisms:

- **`ErrorRegistry`** — a structured, caller-inspectable collection of errors that
  are returned to the library user. Add an entry with `register_error(...)` when a
  parsing step fails in a way that should be reported on the loaded model but must
  not necessarily abort parsing.
- **Standard-library `logging`** — diagnostic output for developers and operators.
  Use it for tracebacks and runtime diagnostics. The package root attaches a
  `logging.NullHandler()` so pyDEXPI never configures logging or emits to `stderr`
  unless the host application configures it.

### When to use each

- Use `ErrorRegistry` for recoverable parsing/model errors that callers may want to
  inspect programmatically: unknown attributes, invalid references, failed
  instantiations, etc.
- Use `logging` for diagnostics that are useful when debugging an import but that a
  caller consuming a loaded model usually does not need: full tracebacks, internal
  state, progress information.
- Every broad `except Exception` that is intentionally kept to avoid aborting a
  per-element parser loop must:
  1. Include a short comment explaining why a broad catch is required.
  2. Log the failure with `logger.debug(..., exc_info=True)` so the traceback is
     recoverable when someone turns DEBUG on.
  3. Register the failure with `ErrorRegistry` so the caller can still see it.

### Choosing a level

**Anything that is also written to the `ErrorRegistry` is logged at `DEBUG`.** This is
the rule that matters most in the loaders, and it is not a style preference:

- The registry is the caller-facing contract. It is structured, collectable, and already
  carries the exception object via `register_error(..., exception=e)`. A log record for
  the same event adds nothing the caller cannot already reach.
- `logging.NullHandler()` on the package root only protects consumers who have *not*
  configured logging. It does not stop propagation — a consumer who calls
  `logging.basicConfig()` (which is most of them) sees every record pyDEXPI emits, at
  their default level. Logging a handled, registered, recoverable condition at `ERROR`
  therefore puts a traceback in someone else's log for something pyDEXPI does not
  consider a failure, once per malformed element.

So: `logger.debug` for anything registered, `logger.debug` for traversal and progress
detail, and reserve `WARNING`/`ERROR` for conditions that are **not** reported on any
caller-facing channel and that the consuming application genuinely has to act on. Do not
log and register the same condition at `WARNING` or above, and do not log and raise the
same condition at all.

**As of today nothing in pyDEXPI meets that bar**, so every logging call in the package is
`DEBUG`. `tests/test_logging_convention.py` enforces this by walking the AST of
`pydexpi/`; if you have a genuinely actionable, un-reported condition, add it to that
test's `ALLOWED_LOUD_CALLS` with a justification rather than deleting the guard.

### Outside the loaders

The `ErrorRegistry` is a loader concept. `toolkits/`, `exports/`, `syndata/`
and `query/` do not have one, and mostly do not need one — they raise on bad input rather
than swallowing it, which is the right behaviour for a toolkit function. What they lack is
*diagnostics*: a caller cannot see what a long traversal tried, or why an index came back
empty.

The rule there is the same, and the caller-facing channel is whatever the function already
returns or raises:

- Log at `DEBUG` when the information would otherwise be **destroyed** — a rejected branch
  in a search that later reports only "no valid branch found", a count of objects an index
  could not tag.
- Log at `DEBUG` for progress through long or opaque operations — generation steps, what an
  export wrote.
- Do not log a condition the function is about to raise on. The exception carries it.

### Preferred patterns

```python
logger = logging.getLogger(__name__)

# Specific, expected failure. DEBUG, because register_error is what the caller reads.
try:
    value = int(raw_string)
except (ValueError, TypeError) as e:
    logger.debug("Cannot parse integer from %r", raw_string, exc_info=True)
    self.register_error(f"Cannot parse integer: {e}", level=ErrorLevels.WARNING, exception=e)
    value = None

# Intentionally broad: per-element parser loop must not abort the whole document
try:
    result = parse_many_attributes(element)
except Exception as e:
    # Broad exception handler: this loop processes many attribute types, any of
    # which can raise arbitrary runtime errors on malformed input.
    logger.debug("Error parsing attributes for element %s", element_id, exc_info=True)
    self.register_error(f"Error parsing attributes: {e}", level=ErrorLevels.ERROR, exception=e)
    result = {}
```

Avoid bare `except:` and avoid `except Exception` unless the surrounding context is
an element-level loop that must continue processing the rest of the document.
