# Architecture

## Ownership boundary

`lib/`, `src/`, `schemas/`, and `bin/` are shared. A trip directory is an isolated
instance. `Itinerary::DataStore` receives both roots: shared schemas/templates come
from the framework, while canonical YAML, assets, optional fallback geography, and
generated output come from the trip.

## Data flow

1. `site.yaml` supplies presentation and destination configuration.
2. Eight canonical YAML documents supply schedule, places, bookings, constraints,
   preferences, movements, activity options, and meal options.
3. JSON Schema validation checks structure; the Ruby validator checks references,
   chronology, pace, route directness, continuity, evidence, opening hours, meals,
   coordinates, and privacy-sensitive behavior.
4. three ERB renderers combine canonical data with shared HTML/CSS/JavaScript.
5. deterministic static files are written in the selected trip root.

Generated HTML is disposable. Never patch it directly.

## Generic abstractions

- Rail values are configuration-backed classifications such as
  `high_speed_rail` and `conventional_rail`; labels, icons, colors, and animation
  timing live in `site.yaml`.
- Meal conversion uses ISO `base_currency`, `quote_currency`, and
  `quote_per_base_rate`. Symbols, precision, and placement are configurable.
- Page titles, descriptions, social image, wordmark, chooser storage/export text,
  destination search hint, map URLs, and route-authoring user agent are trip-owned.
- Fallback geography is optional. The renderer always derives a padded extent from
  known place coordinates, so the dependency-free diagram remains safe without a
  country polygon.

## Validation policy

Normal validation blocks structural and semantic errors and reports planning risk
as warnings. Strict pace additionally treats the documented blocker codes as
failure. A migrated compatibility example may record its exact historical blocker
list in `site.yaml`; `check` asserts equality rather than concealing it. Ordinary
new trips use an empty list.

## Static-map privacy

The public map serializes only canonical public coordinates. `build_map --private`
validates an ignored override file and writes a separately ignored page. Runtime
pages contain no router calls, API keys, secrets, or machine paths.
