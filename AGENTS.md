# Framework invariants

- Treat each trip directory as the owner of `site.yaml`, `trip-brief.yaml`,
  `data/`, `assets/`, `public/`, and generated HTML.
- Keep destination, traveler, currency, transport-brand, and hosting facts out of
  `lib/`, `src/`, and `bin/`; express them in trip configuration or canonical data.
- Never invent bookings, opening hours, schedules, prices, or transport times.
  Preserve confirmed bookings and hard constraints unless the user changes them.
- Never publish `data/private-locations.yaml` or `journey-map.private.html`.
- Edit canonical YAML and shared templates, not generated pages.
- Preserve deterministic output and use only the Ruby standard library.

Before committing a framework change, run:

```sh
ruby bin/check --trip test/fixtures/generic
ruby bin/check --trip examples/japan
```

For Japan compatibility work, also run the full test suite and review desktop and
mobile renders of all three pages.
