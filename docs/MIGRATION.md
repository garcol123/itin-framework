# Japan migration and parity report

## Baseline

The read-only source was commit `99797e19e1e82d893e094cdbfa44ab540ac4a2f0`
with a clean `main` worktree. Its validator produced 0 errors and 7 warnings; strict
mode identified 6 blockers. Its test suite passed 62 runs and 5,009 assertions.
Raw committed source pages are retained under `test/fixtures/source-japan`.

## Preserved

- All canonical schedule, places, bookings, constraints, preferences, movements,
  activity choices, meal choices, evidence, and media were mechanically migrated.
- Ported semantic/regression tests retain the source's detailed itinerary, pace,
  map, meal, tooltip, private-location, and interaction assertions.
- Normalized visible content is compared for all three pages.
- The journey payload is compared after normalizing only the intentional generic
  identifier/config additions below.
- Chooser defaults, storage behavior, exports, map stop order, movement geometry,
  flights, hotel continuity, meal pins, fallback diagram, and reduced-motion code
  remain covered.

## Intentional differences

1. Files now live below `examples/japan`; shared implementation lives at the
   framework root.
2. `site.yaml` supplies metadata, branding, search hint, currencies, transport
   presentation, map provider, user agent, and the Japan fallback GeoJSON path.
3. Canonical rail identifiers changed from destination-branded values to
   `high_speed_rail` and `conventional_rail`. Japan-visible labels are unchanged.
4. `jpy_per_aud` became `quote_per_base_rate`; ISO currency codes and source-rate
   evidence remain in the Japan data.
5. The embedded map payload adds configured transport/map presentation, renames
   `fallback_country` to `fallback_geography`, and adds a coordinate-derived
   `fallback_extent`. Compatibility comparison normalizes only these fields.
6. Transport CSS class names are generic. Visual colors, timing, and labels are
   equivalent for the Japan configuration.
7. HTML language is the configured `en-AU`, and metadata serialization may differ.
   Normalized user-visible page content remains equal.
8. Strict pace still reports the source's exact six blockers. `check` verifies that
   documented compatibility baseline while `validate --strict-pace` continues to
   fail, so the risk cannot be mistaken for a clean strict result.

Raw HTML is intentionally not byte-identical because paths, configuration payload,
generic identifiers, and metadata serialization changed.

## Visual review

Desktop (1440×900) and mobile (390×844) screenshots for itinerary, chooser,
and journey map are stored under `test/fixtures/visual`, alongside matching
`source-*` captures from the untouched source repository. The itinerary captures
and mobile map capture are byte-identical. Chooser differences are confined to
lazy-loaded image/checkbox pixels; exact normalized visible-content and payload
tests cover all three pages. Live review found no horizontal overflow or console
errors, loaded the MapLibre map, verified chooser persistence/reset, and exercised
timeline day selection and play/pause. Basemap tile pixels are intentionally not a
strict comparison surface because they are fetched at runtime.
