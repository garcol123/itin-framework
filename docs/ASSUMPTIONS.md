# Source assumption inventory

The original implementation mixed the following instance facts into shared code.
They are migration targets, not framework defaults.

- **Destination/country:** Japan in metadata, search queries, page titles, chooser
  exports, fallback country GeoJSON, and route-authoring user agent.
- **Travelers/origin:** Sydney in the journey-map initial label and return-flight
  wording; exact hotels, trip ID, dates, preferences, constraints, and bookings in
  canonical data.
- **Currency:** AUD/JPY schema constants, `jpy_per_aud`, symbol branching, and
  Japan-specific source-rate field names.
- **Transport:** `shinkansen`/`conventional` enum values, presentation strings,
  CSS classes, animation timing, legend text, and validator wording.
- **Branding/hosting:** fixed wordmark, year, descriptions, Open Graph title/image,
  storage key, export title/filename, and a deployment-specific canonical URL.
- **Map/provider:** fixed MapLibre/OpenFreeMap URLs and language handling, embedded
  Japan GeoJSON, and a Japan-specific authoring user agent.
- **Paths:** commands assume the repository root is also the trip root; renderers
  load templates/assets/schemas from that same root.
- **Optimization semantics:** relaxed-only pace analysis, fixed thresholds,
  three-option meal rules, 3 km meal clustering, route-direction rules, and
  source-specific evidence requirements. These are retained as framework policy
  because they are destination-neutral behavioral requirements.
