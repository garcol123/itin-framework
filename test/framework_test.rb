# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/itinerary"

class FrameworkTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.join(ROOT, "test", "fixtures", "generic")

  def test_generic_fixture_validates_strictly_and_renders_every_page
    store = Itinerary::DataStore.new(FIXTURE, framework_root: ROOT)
    validator = Itinerary::Validator.new(store)
    assert_empty validator.validate.select { |issue| issue.severity == :error }
    assert_empty validator.strict_blockers
    assert_includes Itinerary::Renderer.new(store).render, "Example Coast Itinerary"
    assert_includes Itinerary::ActivityOptionsRenderer.new(store).render, "example-coast-2027-activity-draft-v1"
    assert_includes Itinerary::JourneyMapRenderer.new(store).render, '"fallback_geography":null'
  end

  def test_configuration_and_currency_pair_are_validated
    with_fixture do |directory|
      site = load_yaml(File.join(directory, "site.yaml"))
      site.delete("locale")
      write_yaml(File.join(directory, "site.yaml"), site)
      assert_includes validate(directory).map(&:code), "schema-violation"
    end

    with_fixture do |directory|
      meals = load_yaml(File.join(directory, "data", "meal_options.yaml"))
      meals.fetch("exchange_rate")["base_currency"] = "CAD"
      write_yaml(File.join(directory, "data", "meal_options.yaml"), meals)
      assert_includes validate(directory).map(&:code), "currency-pair-mismatch"
    end
  end

  def test_references_and_transport_presentations_are_validated
    with_fixture do |directory|
      trip = load_yaml(File.join(directory, "data", "trip.yaml"))
      trip.fetch("days").first.fetch("activities").first["booking_refs"] = ["missing-booking"]
      trip.fetch("days").first.fetch("activities").first["rail_types"] = ["unknown_rail"]
      write_yaml(File.join(directory, "data", "trip.yaml"), trip)
      codes = validate(directory).map(&:code)
      assert_includes codes, "unknown-booking"
      assert_includes codes, "unknown-rail-classification"
    end
  end

  def test_missing_data_has_an_actionable_error
    Dir.mktmpdir("missing-trip") do |directory|
      FileUtils.cp(File.join(FIXTURE, "site.yaml"), directory)
      error = assert_raises(ArgumentError) { Itinerary::DataStore.new(directory, framework_root: ROOT) }
      assert_match(/Missing required file .*data\/trip\.yaml/, error.message)
    end
  end

  private

  def with_fixture
    Dir.mktmpdir("generic-trip") do |directory|
      FileUtils.cp_r(File.join(FIXTURE, "."), directory)
      yield directory
    end
  end

  def load_yaml(path)
    YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false)
  end

  def write_yaml(path, value)
    File.write(path, YAML.dump(value), encoding: "UTF-8")
  end

  def validate(directory)
    Itinerary::Validator.new(Itinerary::DataStore.new(directory, framework_root: ROOT)).validate
  end
end
