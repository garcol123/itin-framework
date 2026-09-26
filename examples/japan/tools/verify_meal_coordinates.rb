#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "yaml"

ROOT = File.expand_path("..", __dir__)
MEALS_PATH = File.join(ROOT, "data/meal_options.yaml")
PLACES_PATH = File.join(ROOT, "data/places.yaml")
PROTECTED = %w[day-03-lunch day-03-dinner day-07-dinner day-08-breakfast day-14-dinner].freeze

def distance_km(a, b)
  radians = Math::PI / 180
  lat1, lon1 = a.map { |value| value * radians }
  lat2, lon2 = b.map { |value| value * radians }
  dlat = lat2 - lat1
  dlon = lon2 - lon1
  hav = Math.sin(dlat / 2)**2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dlon / 2)**2
  6371 * 2 * Math.atan2(Math.sqrt(hav), Math.sqrt(1 - hav))
end

def locality(slot_id)
  day = slot_id[/day-(\d+)/, 1].to_i
  return "Sydney Airport Australia" if day == 1
  return "Tokyo Japan" if day <= 5 && !slot_id.match?(/day-05-(lunch|dinner)/)
  return "Kanazawa Japan" if day <= 7
  return "Uji Kyoto Japan" if slot_id == "day-09-lunch"
  return "Arashiyama Kyoto Japan" if slot_id == "day-11-lunch"
  return "Nara Japan" if slot_id == "day-12-lunch"
  return "Himeji Japan" if slot_id == "day-13-lunch"
  return "Osaka Japan" if day >= 13 && slot_id != "day-15-preflight"
  return "Kansai International Airport Japan" if slot_id == "day-15-preflight"

  "Kyoto Japan"
end

meals = YAML.load_file(MEALS_PATH)
places = YAML.load_file(PLACES_PATH)
targets = meals.fetch("days").flat_map { |day| day.fetch("slots") }
  .reject { |slot| PROTECTED.include?(slot.fetch("id")) }
  .flat_map { |slot| slot.fetch("options").map { |option| [slot.fetch("id"), option.fetch("place_id")] } }

verified = 0
targets.each_with_index do |(slot_id, place_id), index|
  place = places.fetch("places").fetch(place_id)
  current = place.fetch("coordinates")
  center = [current.fetch("latitude"), current.fetch("longitude")]
  query = "#{place.fetch('name')} #{locality(slot_id)}"
  uri = URI("https://nominatim.openstreetmap.org/search")
  uri.query = URI.encode_www_form(q: query, format: "jsonv2", limit: 5, addressdetails: 1)
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "itin-meal-coordinate-audit/1.0 (local itinerary research)"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) { |http| http.request(request) }
  candidates = response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : []
  match = candidates.map { |candidate| [candidate, distance_km(center, [candidate.fetch("lat").to_f, candidate.fetch("lon").to_f])] }
    .select { |_candidate, distance| distance <= 4.0 }
    .min_by(&:last)
  if match
    candidate, = match
    type = {"N" => "node", "W" => "way", "R" => "relation"}.fetch(candidate.fetch("osm_type")[0].upcase)
    current.merge!(
      "longitude" => candidate.fetch("lon").to_f,
      "latitude" => candidate.fetch("lat").to_f,
      "precision" => candidate.fetch("type") == "administrative" ? "neighborhood" : "entrance",
      "status" => candidate.fetch("type") == "administrative" ? "provisional" : "verified",
      "source_url" => "https://www.openstreetmap.org/#{type}/#{candidate.fetch('osm_id')}",
      "checked_on" => "2026-09-12"
    )
    verified += 1 unless candidate.fetch("type") == "administrative"
  end
  warn "coordinate audit #{index + 1}/#{targets.length}: #{place_id} #{match ? 'matched' : 'unresolved'}"
  sleep 1.05 if index + 1 < targets.length
end

File.write(PLACES_PATH, YAML.dump(places, line_width: -1))
warn "Verified #{verified}/#{targets.length} candidate coordinates against an in-cluster OpenStreetMap feature."
