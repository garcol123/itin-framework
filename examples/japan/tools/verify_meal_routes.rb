#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "thread"
require "uri"
require "yaml"

ROOT = File.expand_path("..", __dir__)
MEALS_PATH = File.join(ROOT, "data/meal_options.yaml")
PLACES_PATH = File.join(ROOT, "data/places.yaml")
TRIP_PATH = File.join(ROOT, "data/trip.yaml")
PROTECTED = %w[day-03-lunch day-03-dinner day-07-dinner day-08-breakfast day-14-dinner].freeze
INDOOR = %w[day-01-dinner day-05-breakfast day-13-breakfast day-15-preflight].freeze
CURATED = %w[day-09-breakfast day-09-lunch day-12-lunch day-12-dinner day-13-breakfast].freeze
PACE_METERS_PER_MINUTE = 75.0
CHECKED_ON = "2026-09-24"

meals = YAML.load_file(MEALS_PATH)
places = YAML.load_file(PLACES_PATH).fetch("places")
trip = YAML.load_file(TRIP_PATH)
activities = trip.fetch("days").flat_map { |day| day.fetch("activities") }.to_h { |activity| [activity.fetch("id"), activity] }

coordinates = lambda do |place_id|
  point = places.dig(place_id, "coordinates")
  point && [point.fetch("longitude"), point.fetch("latitude")]
end

activity_point = lambda do |activity_ref, edge|
  next nil unless activity_ref && activities[activity_ref]

  points = activities.fetch(activity_ref).fetch("content").filter_map { |token| token["place"] }.filter_map { |place_id| coordinates.call(place_id) }
  edge == :from ? points.last : points.first
end

def osrm_url(points)
  encoded = points.map { |lon, lat| "#{lon},#{lat}" }.join(";")
  "https://routing.openstreetmap.de/routed-foot/route/v1/driving/#{encoded}?overview=false"
end

def straight_line_meters(left, right)
  radians = Math::PI / 180
  lon1, lat1 = left.map { |value| value * radians }
  lon2, lat2 = right.map { |value| value * radians }
  dlat = lat2 - lat1
  dlon = lon2 - lon1
  hav = Math.sin(dlat / 2)**2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dlon / 2)**2
  6_371_000 * 2 * Math.atan2(Math.sqrt(hav), Math.sqrt(1 - hav))
end

jobs = []
slots = meals.fetch("days").flat_map { |day| day.fetch("slots") }.reject { |slot| PROTECTED.include?(slot.fetch("id")) }
slots.each do |slot|
  if (INDOOR + CURATED).include?(slot.fetch("id"))
    slot.fetch("options").each do |option|
      route = option.fetch("route_fit")
      %w[walking_distance_meters walking_minutes direct_flow_minutes via_venue_flow_minutes incremental_detour_minutes provider source_url].each do |field|
        raise "#{option.fetch('id')} is missing curated route field #{field}" unless route.key?(field)
      end
      route_evidence = option.fetch("evidence").find { |entry| entry["title"] == "Walking-route evidence" }
      route_evidence&.merge!("url" => route.fetch("source_url"), "status" => route.fetch("status"))
    end
    next
  end

  slot.fetch("options").each do |option|
    route = option.fetch("route_fit")
    venue = coordinates.call(option.fetch("place_id"))
    from_point = activity_point.call(route["from_activity_ref"], :from)
    to_point = activity_point.call(route["to_activity_ref"], :to)
    anchor = coordinates.call(route.fetch("anchor_place_id")) || from_point || to_point
    origin = from_point || anchor
    destination = to_point || anchor
    jobs << [option, anchor, venue, origin, destination, places.dig(option.fetch("place_id"), "coordinates", "status") == "verified", !from_point.nil? && !to_point.nil?]
  end
end

urls = jobs.select { |_option, _anchor, _venue, _origin, _destination, exact, _two_sided| exact }.flat_map do |_option, anchor, venue, origin, destination, _exact, two_sided|
  [osrm_url([anchor, venue]), (osrm_url([origin, destination]) if two_sided), (osrm_url([origin, venue, destination]) if two_sided)].compact
end.uniq
queue = Queue.new
urls.each { |url| queue << url }
results = {}
mutex = Mutex.new
workers = 6.times.map do
  Thread.new do
    loop do
      url = queue.pop(true)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |http| http.get(uri.request_uri, {"User-Agent" => "itin-meal-route-audit/1.0"}) }
      payload = response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : {}
      distance = payload.dig("routes", 0, "distance")
      mutex.synchronize { results[url] = distance&.round }
    rescue ThreadError
      break
    rescue StandardError => error
      warn "route request failed: #{error.class}: #{error.message}"
      mutex.synchronize { results[url] = nil } if url
    end
  end
end
workers.each(&:join)

verified = 0
jobs.each do |option, anchor, venue, origin, destination, exact, two_sided|
  route = option.fetch("route_fit")
  if exact
    anchor_distance = results[osrm_url([anchor, venue])]
    direct_distance = two_sided ? results[osrm_url([origin, destination])] : 0
    via_distance = two_sided ? results[osrm_url([origin, venue, destination])] : anchor_distance
  end
  if !exact || [anchor_distance, direct_distance, via_distance].any?(&:nil?)
    exact = false
    anchor_distance = (straight_line_meters(anchor, venue) * 1.25).round
    direct_distance = two_sided ? (straight_line_meters(origin, destination) * 1.25).round : 0
    via_distance = if two_sided
      ((straight_line_meters(origin, venue) + straight_line_meters(venue, destination)) * 1.25).round
    else
      anchor_distance
    end
  end
  route_evidence = option.fetch("evidence").find { |entry| entry["title"] == "Walking-route evidence" }
  route_evidence&.merge!("url" => route.fetch("source_url"), "status" => route.fetch("status"))
  next unless anchor_distance && direct_distance && via_distance

  walking_minutes = [(anchor_distance / PACE_METERS_PER_MINUTE).ceil, 1].max
  direct_minutes = (direct_distance / PACE_METERS_PER_MINUTE).ceil
  via_minutes = (via_distance / PACE_METERS_PER_MINUTE).ceil
  detour = [via_minutes - direct_minutes, 0].max
  route.merge!(
    "walking_distance_meters" => anchor_distance,
    "walking_minutes" => walking_minutes,
    "direct_flow_minutes" => direct_minutes,
    "via_venue_flow_minutes" => via_minutes,
    "incremental_detour_minutes" => detour,
    "status" => exact ? "verified" : "provisional",
    "provider" => exact ? "OSRM pedestrian-network distance; walking time calculated at 75 metres per minute" : "Conservative 1.25× straight-line estimate from provisional candidate pin; walking time calculated at 75 metres per minute",
    "source_url" => if exact
      osrm_url(two_sided ? [origin, venue, destination] : [anchor, venue])
    else
      "https://www.google.com/maps/dir/?api=1&origin=#{anchor[1]},#{anchor[0]}&destination=#{venue[1]},#{venue[0]}&travelmode=walking"
    end,
    "checked_on" => CHECKED_ON
  )
  if exact
    route.delete("verification_note")
  else
    route["verification_note"] = "The route is conservative but remains provisional until the storefront pin can be matched to an unambiguous pedestrian-network feature."
  end
  route["distance_exception"] = {"reason" => "Distinctive option retained within the absolute 20-minute limit."} if detour.between?(16, 20)
  route.delete("distance_exception") if detour <= 15
  verified += 1 if exact
end

File.write(MEALS_PATH, YAML.dump(meals, line_width: -1))
warn "Audited #{verified}/#{jobs.length} non-indoor recommendation routes; verified storefront matches use OSRM and unresolved pins retain conservative provisional distances."
