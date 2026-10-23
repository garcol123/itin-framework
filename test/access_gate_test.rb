# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/itinerary"

class AccessGateTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RENDERERS = [Itinerary::Renderer, Itinerary::ActivityOptionsRenderer, Itinerary::JourneyMapRenderer].freeze

  def setup
    @store = Itinerary::DataStore.new(File.join(ROOT, "test/fixtures/generic"), framework_root: ROOT)
  end

  def test_gate_is_optional_and_shared_by_all_trip_pages
    RENDERERS.each { |renderer| refute_includes renderer.new(@store).render, "trip-access-gate" }
    @store.site["access_gate"] = { "password" => "sample-pass" }
    assert_empty Itinerary::Validator.new(@store).validate.select { |issue| issue.severity == :error }
    RENDERERS.each do |renderer|
      html = renderer.new(@store).render
      assert_match(/\A<!DOCTYPE html>\n/, html)
      assert_includes html, 'const expected = "sample-pass";'
      assert_includes html, 'const storageKey = "example-coast-2027-access-v1";'
      assert_includes html, "dialog.showModal()"
    end
  end

  def test_empty_password_is_rejected
    @store.site["access_gate"] = { "password" => "" }
    assert_includes Itinerary::Validator.new(@store).validate.map(&:code), "schema-violation"
  end

  def test_password_cannot_close_the_inline_script
    @store.site["access_gate"] = { "password" => '</script><script>alert("test")</script>' }
    html = Itinerary::Renderer.new(@store).render
    refute_includes html, '</script><script>alert'
    assert_includes html, '\u003c/script>'
  end
end
