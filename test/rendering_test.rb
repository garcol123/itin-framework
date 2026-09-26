# frozen_string_literal: true

require "json"
require "cgi"
require "minitest/autorun"
require "rexml/document"
require "rexml/xpath"
require_relative "../lib/itinerary"

class RenderingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  JAPAN = File.join(ROOT, "examples", "japan")
  SOURCE = File.join(ROOT, "test", "fixtures", "source-japan")

  def setup
    @store = Itinerary::DataStore.new(JAPAN, framework_root: ROOT)
  end

  def test_all_japan_pages_preserve_normalized_visible_content
    rendered = {
      "index.html" => Itinerary::Renderer.new(@store).render,
      "activity-options.html" => Itinerary::ActivityOptionsRenderer.new(@store).render,
      "journey-map.html" => Itinerary::JourneyMapRenderer.new(@store).render
    }
    rendered.each do |filename, html|
      assert_equal visible_text(File.read(File.join(SOURCE, filename), encoding: "UTF-8")), visible_text(html), filename
    end
  end

  def test_journey_payload_is_equivalent_after_identifier_generalization
    source = normalize_payload(journey_payload(File.read(File.join(SOURCE, "journey-map.html"), encoding: "UTF-8")))
    current = normalize_payload(journey_payload(Itinerary::JourneyMapRenderer.new(@store).render))
    assert_equal source, current
  end

  def test_rendering_is_deterministic_and_chooser_config_is_trip_owned
    renderers = [Itinerary::Renderer, Itinerary::ActivityOptionsRenderer, Itinerary::JourneyMapRenderer]
    renderers.each { |renderer| assert_equal renderer.new(@store).render, renderer.new(@store).render }
    chooser = Itinerary::ActivityOptionsRenderer.new(@store).render
    assert_includes chooser, '"storage_key":"japan-2026-activity-draft-v1"'
    assert_includes chooser, '"export_filename":"japan-2026-activity-draft.txt"'
  end

  def test_public_pages_exclude_private_coordinates_secrets_and_machine_paths
    sentinel = { "longitude" => 12.3456789, "latitude" => -45.6789123 }
    public_html = Itinerary::JourneyMapRenderer.new(@store).render
    private_html = Itinerary::JourneyMapRenderer.new(@store, location_overrides: { "sotetsu-fresa-inn-ginza-nanachome" => sentinel }, private_output: true).render
    refute_includes public_html, sentinel.fetch("longitude").to_s
    assert_includes private_html, sentinel.fetch("longitude").to_s

    [Itinerary::Renderer, Itinerary::ActivityOptionsRenderer, Itinerary::JourneyMapRenderer].each do |renderer|
      html = renderer.new(@store).render
      refute_includes html, ROOT
      refute_match(/(?:api[_-]?key|secret|token)\s*[:=]\s*[A-Za-z0-9_-]{12,}/i, html)
    end
  end

  private

  def visible_text(html)
    main = html.match(%r{<main\b.*?</main>}m)&.[](0)
    raise "Page has no main element" unless main

    CGI.unescapeHTML(main.gsub(/<[^>]+>/m, " ")).gsub(/\s+/, " ").strip
  end

  def journey_payload(html)
    JSON.parse(html.match(%r{<script id="journey-data" type="application/json">(.*?)</script>}m).captures.first)
  end

  def normalize_payload(payload)
    copy = Marshal.load(Marshal.dump(payload))
    copy.fetch("trip").delete("transport")
    copy.fetch("trip").delete("map")
    copy["fallback_country"] ||= copy.delete("fallback_geography")
    copy.delete("fallback_extent")
    rewrite = lambda do |value|
      case value
      when Hash then value.each_value { |child| rewrite.call(child) }
      when Array
        value.map! do |child|
          child == "high_speed_rail" ? "shinkansen" : child == "conventional_rail" ? "conventional" : rewrite.call(child) || child
        end
      end
      nil
    end
    rewrite.call(copy)
    copy
  end
end
