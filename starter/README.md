# New trip starter

1. Complete `trip-brief.yaml` without inventing unknown facts.
2. Ask Codex to read the framework `AGENTS.md` and `docs/CREATE_TRIP.md`.
3. Replace every `TODO` value and populate the canonical files in `data/`.
4. Add trip-owned images beneath `assets/` and social media under `public/`.
5. Iterate with `ruby bin/check --trip trips/TRIP_SLUG` from the framework root.

This starter is intentionally incomplete. Validation failures identify the missing
canonical records. It contains no destination-specific itinerary defaults.
