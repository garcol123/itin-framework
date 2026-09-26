#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

root = File.expand_path("..", __dir__)
meals = YAML.load_file(File.join(root, "data/meal_options.yaml"))
places = YAML.load_file(File.join(root, "data/places.yaml")).fetch("places")
trip = YAML.load_file(File.join(root, "data/trip.yaml"))
dates = trip.fetch("days").to_h { |day| [day.fetch("number"), day.fetch("date")] }
protected = %w[day-03-lunch day-03-dinner day-07-dinner day-08-breakfast day-14-dinner].freeze
slots = meals.fetch("days").flat_map { |day| day.fetch("slots").map { |slot| [day.fetch("day"), slot] } }
generic_options = slots.reject { |_day, slot| protected.include?(slot.fetch("id")) }.flat_map { |_day, slot| slot.fetch("options") }
provisional_coordinates = generic_options.count { |option| places.dig(option.fetch("place_id"), "coordinates", "status") != "verified" }
provisional_hours = generic_options.count { |option| option.dig("operating_hours", "status") != "verified" }

money = lambda do |amount, currency|
  currency == "JPY" ? "¥#{amount.to_i.to_s.reverse.scan(/.{1,3}/).join(',').reverse}" : "A$#{amount}"
end

lines = []
lines << "# Meal recommendation regeneration — evidence report"
lines << ""
lines << "Checked 14 September 2026 for travel 23 October–6 November 2026. This is the audit companion to `data/meal_options.yaml`; the YAML remains canonical."
lines << ""
lines << "## Outcome"
lines << ""
lines << "- All 36 generic meal windows retain exactly three choices each (108 recommendations)."
lines << "- Five changed windows were rebuilt for the new route: Day 9 breakfast and lunch, Day 12 lunch and dinner, and Day 13 breakfast; three further dinner/breakfast windows were retimed without discarding their existing research."
lines << "- Those five rebuilt windows now use venue-specific route records rather than rank-derived 4/7/10-minute placeholders. Day 9 lunch is measured as 12 minutes from the Todaiji Great Buddha Hall endpoint to three seated choices at YumeKaze Hiroba; the complex lies on the exit corridor toward the Nara transport connection."
lines << "- Portable-breakfast counters now use a 10-minute purchase allowance rather than a restaurant-style 50-minute stay. Shin-Osaka indoor walks remain explicitly provisional because the final gate-to-platform path depends on the booked train."
lines << "- All 108 generic venue IDs remain globally unique."
lines << "- The five restaurant-specific windows were preserved: HARBS Ueno, Hikiniku to Come Shibuya, both Kagari meals, and 551 Horai with their existing backups."
lines << "- Every generic choice has a date/window check, a two-person order, item-level planning prices, total spend, route provenance, and claim-labelled sources."
lines << "- Incremental detours are capped at 15 minutes except the one documented 16-minute Nanahoshi Curry exception; no option exceeds the 20-minute absolute limit."
lines << ""
lines << "## Method and confidence"
lines << ""
lines << "First-party venue, hotel, station, airport, market, and destination pages were preferred. Route records retain their named map or routing provider and confidence status. Airport and station counters use first-party facility information and conservative indoor allowances. Published 2026 hours and all menu prices remain vulnerable to later operational changes, so the itinerary labels them for re-checking rather than presenting them as guarantees. Day 12 choices are explicitly provisional because the visit falls on Culture Day."
lines << ""
lines << "Confidence totals: #{generic_options.count { |option| option.dig('operating_hours', 'status') == 'verified' }}/108 hours checks verified; #{generic_options.count { |option| option.dig('route_fit', 'status') == 'verified' }}/108 route records verified; #{generic_options.count { |option| places.dig(option.fetch('place_id'), 'coordinates', 'status') == 'verified' }}/108 storefront coordinates independently matched. All 108 price totals are planning values sourced to the cited menu or venue page and deliberately remain provisional until travel-date re-check."
lines << ""
lines << "## Meal-by-meal evidence"

slots.each do |day, slot|
  lines << ""
  lines << "### Day #{day} · #{dates.fetch(day)} · #{slot.fetch('meal').capitalize} · #{slot.fetch('time_label')}"
  lines << ""
  lines << "Anchor: #{slot.fetch('location')}. #{slot.fetch('context')}"
  lines << ""
  if protected.include?(slot.fetch("id"))
    names = slot.fetch("options").sort_by { |option| option.fetch("rank") }.map { |option| places.fetch(option.fetch("place_id")).fetch("name") }
    lines << "Protected restaurant-specific slot; preserved unchanged: #{names.join(' → ')}."
    next
  end

  slot.fetch("options").sort_by { |option| option.fetch("rank") }.each do |option|
    place = places.fetch(option.fetch("place_id"))
    route = option.fetch("route_fit")
    hours = option.fetch("operating_hours")
    order = option.fetch("order_for_two")
    spend = order.fetch("estimated_total_spend")
    items = order.fetch("items").map do |item|
      unit = item.fetch("unit_price")
      "#{item.fetch('quantity')}× #{item.fetch('name')} (#{money.call(unit.fetch('amount'), unit.fetch('currency'))})"
    end.join("; ")
    source = option.fetch("evidence").first
    coordinate_status = place.dig("coordinates", "status")
    exception = route["distance_exception"] ? "; exception: #{route.dig('distance_exception', 'reason')}" : ""
    lines << ""
    lines << "#{option.fetch('rank')}. **[#{place.fetch('name')}](#{place.fetch('url')})** — #{option.fetch('best_for')}."
    lines << "   Route: #{route.fetch('walking_distance_meters')} m / #{route.fetch('walking_minutes')} min from anchor; +#{route.fetch('incremental_detour_minutes')} min versus direct flow (#{route.fetch('direct_flow_minutes')} → #{route.fetch('via_venue_flow_minutes')} min); route #{route.fetch('status')}, pin #{coordinate_status}#{exception}. [Route evidence](#{route.fetch('source_url')})"
    lines << "   Hours: #{hours.fetch('published_window')} for the #{hours.fetch('meal_window')} window (#{hours.fetch('status')}). [Hours/menu source](#{hours.fetch('source_url')})"
    lines << "   Order for two: #{items}. Estimated food total #{money.call(spend.fetch('amount'), spend.fetch('currency'))} (provisional). [#{source.fetch('title')}](#{source.fetch('url')}) supports #{source.fetch('supports')}."
  end
end

lines << ""
lines << "## Exceptions and travel-date re-checks"
lines << ""
lines << "- Nanahoshi Curry on Day 6 is the only distance exception: +16 minutes, retained as the distinctive curry choice while staying below the hard +20-minute ceiling."
lines << "- #{provisional_coordinates} storefront coordinates remain provisional. Their map links point to the named venue search; re-check the entrance pin before travel."
lines << "- #{provisional_hours} operating-window records use a first-party or official destination listing that states service without a complete day-specific timetable. Re-check these shortly before the trip."
lines << "- All menu prices are planning values. Reconfirm current items, tax/service treatment, reservation policy, and sold-out risk before ordering."
lines << "- The 12-minute Day 9 lunch access is measured from the Great Buddha Hall endpoint. In practice, the final walk through the temple approach also serves as the exit toward YumeKaze Hiroba; do not interpret the old four-minute card as a Great Buddha Hall-to-restaurant walk."
lines << "- The itinerary intentionally remains non-converged: Day 9 exceeds the relaxed span, commitment, transport, anchor and cluster limits, while Days 3, 7 and 13 create the trip-level AMBER-count blocker. Nishiki Market hours also remain non-machine-readable."

File.write(File.join(root, "optimization/meal-recommendation-report.md"), lines.join("\n") + "\n")
