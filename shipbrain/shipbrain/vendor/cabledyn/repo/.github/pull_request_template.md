<!-- SPDX-License-Identifier: Apache-2.0 -->

## Summary

<!-- What this pull request changes and why. Link the issue it resolves (Fixes #123). -->

## Tests

<!-- Tests added or updated, and what they cover. -->

## Checklist

- [ ] `pre-commit run --all-files` passes
- [ ] `ctest --test-dir build --output-on-failure` passes
- [ ] `python -m pytest tests python/tests` passes (if Python or validation records changed)
- [ ] [VALIDATION.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/VALIDATION.md) updated if a validation result changed
- [ ] [CHANGELOG.md](https://github.com/SMI-Lab-Inha/CableDyn/blob/main/CHANGELOG.md) updated under `[Unreleased]` (heading added if missing) for user-visible changes
- [ ] Documentation in `doc/` updated for changed inputs, options, or outputs
- [ ] Conventional Commit title (`feat:`, `fix:`, `docs:`, ...)
- [ ] Commits are signed off (`git commit -s`) under the
      [Developer Certificate of Origin](https://developercertificate.org/)
