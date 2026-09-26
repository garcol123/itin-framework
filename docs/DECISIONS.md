# Migration and decision log

## 2026-09-26 — source baseline

- Source: the adjacent read-only `itin` repository supplied for migration
- Commit: `99797e19e1e82d893e094cdbfa44ab540ac4a2f0`
- Initial status: clean on `main`
- Tracked-index digest: `6d94d129f0549f14d8d7d217278089c1ae0cbe98a8df390df809c086b30c0b8c`
- Worktree-diff digest: empty SHA-256
  (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`)
- Normal validation: 0 errors, 7 warnings.
- Strict validation: the same warnings plus 6 strict blockers. This pre-existing
  baseline conflicts with the requested strict-pass completion criterion. Japan
  compatibility therefore preserves the exact finding; the framework `check`
  command reports strict blockers for Japan unless the reference itinerary itself
  is deliberately changed.
- Tests: 62 runs, 5,009 assertions, 0 failures/errors/skips.

## Architectural decisions

- Shared code reads templates/schemas from the framework root and all mutable trip
  inputs/outputs from a supplied trip root.
- Presentation labels and icons are configuration. Canonical rail classifications
  are `high_speed_rail` and `conventional_rail`.
- Money uses ISO codes plus `quote_per_base_rate`; display symbols, precision, and
  placement come from `site.yaml`.
- Country fallback geometry is optional trip data. Without it, the map derives a
  padded extent from known trip coordinates.
- The baseline strict-pace inconsistency is never hidden or weakened. It remains a
  documented limitation unless a product decision authorizes itinerary changes.
