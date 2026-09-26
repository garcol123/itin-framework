# Create a trip with Codex

## 1. Initialize

```sh
ruby bin/new_trip my-trip-2027
```

The command accepts only lowercase kebab-case slugs and never overwrites an
existing directory.

## 2. Complete the brief

Edit `trips/my-trip-2027/trip-brief.yaml`. Record travelers, origin, destination,
dates, confirmed bookings, hard constraints, interests, pace, accessibility needs,
budget, and open questions. Unknown is better than invented.

## 3. Ask Codex to populate canonical data

Use the copy-paste prompt in the root README. Codex should:

- treat confirmed bookings and hard constraints as fixed;
- research only missing itinerary-critical facts;
- record URL, checked date, and verification status;
- label unpublished schedules and prices provisional;
- keep alternatives untimed and the default itinerary executable;
- put country-specific tooling and fallback geography inside the trip; and
- never add private coordinates to committed/public data.

## 4. Iterate in dependency order

Populate `places.yaml`, then bookings/constraints/preferences, then `trip.yaml`,
movements, activities, and meals. Validate after each coherent change:

```sh
ruby bin/validate --trip trips/my-trip-2027
ruby bin/validate --trip trips/my-trip-2027 --strict-pace
ruby bin/build --trip trips/my-trip-2027
```

Use `refresh_routes --dry-run` before writing walking geometry. Select with
`--day N` or `--leg ID`; omit both to process every walking leg.

## 5. Finish

```sh
ruby bin/check --trip trips/my-trip-2027
ruby -run -e httpd trips/my-trip-2027 -p 8000
```

Inspect itinerary, chooser, and map at desktop and mobile widths. Confirm chooser
defaults, map timeline/stop order, fallback mode, reduced motion, and private-map
separation before deployment.
