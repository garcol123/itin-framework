# Itinerary framework

A destination-neutral, data-first generator for three static trip pages:

- `index.html` — the canonical day-by-day itinerary with inline meal choices;
- `activity-options.html` — a traveler-controlled activity shortlist; and
- `journey-map.html` — a timeline-driven map with public/private location modes.

The framework uses only the Ruby standard library. It has no package install,
frontend framework, database, API key, or runtime service. Ruby 3.2 or newer is
required because the validator uses `Data.define`.

`examples/japan` is the complete migrated reference. `test/fixtures/generic` is a
small non-Japan trip that proves the framework is not coupled to that example.

## Quick start

```sh
git clone PATH_TO_THIS_REPOSITORY
cd itin-framework
ruby bin/validate --trip examples/japan
ruby bin/build --trip examples/japan
ruby -run -e httpd examples/japan -p 8000
```

Open `http://localhost:8000/`. Use an HTTP server for the map; do not open it as a
`file://` page.

## Commands

```sh
ruby bin/new_trip TRIP_SLUG
ruby bin/validate --trip TRIP_PATH
ruby bin/validate --trip TRIP_PATH --strict-pace
ruby bin/validate --trip TRIP_PATH --json
ruby bin/build --trip TRIP_PATH
ruby bin/build_map --trip TRIP_PATH
ruby bin/build_map --trip TRIP_PATH --private
ruby bin/refresh_routes --trip TRIP_PATH [--day N] [--leg ID] [--dry-run]
ruby bin/build-site --trip TRIP_PATH
ruby bin/check --trip TRIP_PATH
```

Make targets use `TRIP=examples/japan` by default:

```sh
make validate
make build TRIP=trips/my-trip
make check TRIP=trips/my-trip
make refresh-routes TRIP=trips/my-trip ARGS="--day 4 --dry-run"
```

`check` runs normal validation, verifies strict-pace findings, runs the complete
test suite, builds twice, and compares generated hashes. The Japan example records
the source repository's six pre-existing strict blockers as a compatibility
baseline; `validate --strict-pace` still exits unsuccessfully for them. New trips
have an empty expected baseline and must have no strict blockers.

## Trip structure

Every trip owns its configuration, canonical data, media, and generated pages:

```text
trip/
├── site.yaml
├── trip-brief.yaml
├── data/
├── assets/
├── public/
├── index.html
├── activity-options.html
└── journey-map.html
```

`site.yaml` controls destination presentation, locale, storage namespace,
currencies, metadata, transport labels/icons, map provider, and optional fallback
geography. Traveler schedule facts remain in `data/`. Styling and application
behavior remain in `src/` and `lib/`.

See [architecture](docs/ARCHITECTURE.md), [trip creation](docs/CREATE_TRIP.md), and
the [migration/parity report](docs/MIGRATION.md).

## Create a trip

```sh
ruby bin/new_trip korea-2027
```

Fill in `trips/korea-2027/trip-brief.yaml`, then give Codex this prompt:

```text
Read AGENTS.md and docs/CREATE_TRIP.md in this repository, then read
trips/korea-2027/trip-brief.yaml. Create this trip by populating site.yaml and the
canonical files under data/. Research only facts missing from the brief. Treat
confirmed bookings and hard constraints as fixed. Prefer authoritative first-party
sources, record each source URL and checked date, label unpublished facts
provisional, and never invent schedules, opening hours, prices, or transport times.
Keep destination facts inside the trip directory and do not modify framework code
or examples/japan. Add trip-owned assets, build all three static pages, and iterate
until `ruby bin/check --trip trips/korea-2027` passes. Summarize sources, assumptions,
warnings, and any facts the traveler still needs to confirm.
```

The starter intentionally fails validation until its `TODO` records are replaced;
errors identify the incomplete sections. It contains no Japan itinerary facts.

## Privacy

Public coordinates belong in `data/places.yaml`. For a sensitive lodging location:

```sh
cp trips/my-trip/data/private-locations.example.yaml \
  trips/my-trip/data/private-locations.yaml
ruby bin/build_map --trip trips/my-trip --private
```

The private source and `journey-map.private.html` are ignored by Git. Never deploy
them. Normal builds use only public canonical coordinates and make no routing calls
from the browser.

## Deployment

The three generated pages and trip-owned `assets/` and `public/` directories are a
plain static site. Deploy the trip directory directly, or run `bin/build-site` to
prepare the same layout under `TRIP_PATH/dist/client` plus the small static Sites
worker in `TRIP_PATH/dist/server`. Configure `metadata.site_url` only when a stable
public URL exists; no hosting provider is assumed by the shared code.
