# frozen_string_literal: true

require "cgi"
require "date"
require "erb"
require "json"
require "pathname"
require "set"
require "uri"
require "yaml"

module Itinerary
  Issue = Data.define(:severity, :code, :path, :message) do
    def to_h
      { severity: severity, code: code, path: path, message: message }
    end

    def to_s
      "#{severity.upcase} [#{code}] #{path}: #{message}"
    end
  end

  class DataStore
    FILES = %w[trip places bookings constraints preferences movements activity_options meal_options].freeze

    attr_reader(*FILES.map(&:to_sym), :root, :framework_root, :site)

    def initialize(root, framework_root: File.expand_path("..", __dir__))
      @root = Pathname(root).expand_path
      @framework_root = Pathname(framework_root).expand_path
      @site = load_yaml(@root.join("site.yaml"))
      FILES.each do |name|
        path = @root.join("data", "#{name}.yaml")
        value = load_yaml(path)
        instance_variable_set("@#{name}", value)
      end
    end

    def site_metadata = site
    def days = trip.fetch("days")
    def trip_metadata = trip.fetch("trip")
    def place_catalog = places.fetch("places")
    def booking_list = bookings.fetch("bookings")
    def constraint_list = constraints.fetch("constraints")
    def preference_data = preferences.fetch("preferences")
    def movement_days = movements.fetch("days")
    def movement_transitions = movements.fetch("transitions")
    def movement_alternatives = movements.fetch("alternatives")
    def activity_option_destinations = activity_options.fetch("destinations")
    def meal_option_days = meal_options.fetch("days")

    def activities
      days.flat_map { |day| day.fetch("activities") }
    end

    private

    def load_yaml(path)
      value = YAML.safe_load_file(path, permitted_classes: [Date], permitted_symbols: [], aliases: false)
      normalize_dates(value)
    rescue Errno::ENOENT
      raise ArgumentError, "Missing required file #{path}"
    rescue Psych::Exception => error
      raise ArgumentError, "Cannot parse #{path}: #{error.message}"
    end

    def normalize_dates(value)
      case value
      when Date then value.iso8601
      when Array then value.map { |item| normalize_dates(item) }
      when Hash then value.transform_values { |item| normalize_dates(item) }
      else value
      end
    end
  end

  # Dependency-free evaluator for the JSON Schema features used by this
  # repository. Cross-document and itinerary-specific rules remain in
  # Validator below.
  class SchemaValidator
    Result = Data.define(:path, :message)

    TYPE_CHECKS = {
      "object" => ->(value) { value.is_a?(Hash) },
      "array" => ->(value) { value.is_a?(Array) },
      "string" => ->(value) { value.is_a?(String) },
      "integer" => ->(value) { value.is_a?(Integer) },
      "number" => ->(value) { value.is_a?(Numeric) },
      "boolean" => ->(value) { value == true || value == false }
    }.freeze

    def initialize(schema)
      @root = schema
    end

    def validate(value, schema = @root, path = "$")
      schema = resolve(schema.fetch("$ref")) if schema.key?("$ref")
      results = []

      if schema.key?("oneOf")
        matches = schema.fetch("oneOf").count { |candidate| validate(value, candidate, path).empty? }
        results << Result.new(path:, message: "must match exactly one allowed shape") unless matches == 1
        return results
      end

      if schema.key?("type")
        checker = TYPE_CHECKS.fetch(schema.fetch("type"))
        unless checker.call(value)
          return [Result.new(path:, message: "must be #{schema.fetch('type')}, got #{value.class}")]
        end
      end

      results << Result.new(path:, message: "must equal #{schema['const'].inspect}") if schema.key?("const") && value != schema["const"]
      results << Result.new(path:, message: "must be one of #{schema['enum'].join(', ')}") if schema.key?("enum") && !schema["enum"].include?(value)

      case value
      when Hash
        results.concat(validate_object(value, schema, path))
      when Array
        results.concat(validate_array(value, schema, path))
      when String
        results.concat(validate_string(value, schema, path))
      when Numeric
        results << Result.new(path:, message: "must be at least #{schema['minimum']}") if schema.key?("minimum") && value < schema["minimum"]
        results << Result.new(path:, message: "must be at most #{schema['maximum']}") if schema.key?("maximum") && value > schema["maximum"]
      end
      results
    end

    private

    def validate_object(value, schema, path)
      results = []
      schema.fetch("required", []).each do |key|
        results << Result.new(path:, message: "is missing required property #{key.inspect}") unless value.key?(key)
      end
      results << Result.new(path:, message: "must contain at least #{schema['minProperties']} properties") if schema.key?("minProperties") && value.length < schema["minProperties"]

      if (name_schema = schema["propertyNames"])
        value.each_key { |key| results.concat(validate(key, name_schema, "#{path}.#{key}")) }
      end

      properties = schema.fetch("properties", {})
      value.each do |key, child|
        child_path = "#{path}.#{key}"
        if properties.key?(key)
          results.concat(validate(child, properties.fetch(key), child_path))
        elsif schema["additionalProperties"] == false
          results << Result.new(path: child_path, message: "is not an allowed property")
        elsif schema["additionalProperties"].is_a?(Hash)
          results.concat(validate(child, schema.fetch("additionalProperties"), child_path))
        end
      end
      results
    end

    def validate_array(value, schema, path)
      results = []
      results << Result.new(path:, message: "must contain at least #{schema['minItems']} items") if schema.key?("minItems") && value.length < schema["minItems"]
      results << Result.new(path:, message: "must contain unique items") if schema["uniqueItems"] && value.uniq.length != value.length
      if schema["items"]
        value.each_with_index { |child, index| results.concat(validate(child, schema.fetch("items"), "#{path}[#{index}]")) }
      end
      results
    end

    def validate_string(value, schema, path)
      results = []
      results << Result.new(path:, message: "must contain at least #{schema['minLength']} characters") if schema.key?("minLength") && value.length < schema["minLength"]
      if schema["pattern"] && !value.match?(Regexp.new(schema.fetch("pattern")))
        results << Result.new(path:, message: "must match #{schema['pattern'].inspect}")
      end
      case schema["format"]
      when "date"
        begin
          Date.iso8601(value)
        rescue Date::Error
          results << Result.new(path:, message: "must be an ISO 8601 date")
        end
      when "uri"
        begin
          uri = URI.parse(value)
          results << Result.new(path:, message: "must be an absolute URI") unless uri.absolute?
        rescue URI::InvalidURIError
          results << Result.new(path:, message: "must be a valid URI")
        end
      end
      results
    end

    def resolve(reference)
      raise ArgumentError, "Only local JSON Schema references are supported: #{reference}" unless reference.start_with?("#/")

      reference.delete_prefix("#/").split("/").reduce(@root) do |value, token|
        value.fetch(token.gsub("~1", "/").gsub("~0", "~"))
      end
    end
  end

  class PaceAnalyzer
    GREEN = {
      active_span_minutes: 600,
      commitment_minutes: 510,
      transport_minutes: 120,
      discretionary_slack_minutes: 90,
      major_anchors: 2,
      clusters: 2
    }.freeze
    RED = {
      active_span_minutes: 690,
      commitment_minutes: 570,
      transport_minutes: 180,
      discretionary_slack_minutes: 60,
      major_anchors: 2,
      clusters: 2
    }.freeze
    TRANSFER_GREEN_MINUTES = 240
    TRANSFER_AMBER_MINUTES = 300
    LONG_TRANSFER_RECOVERY_MINUTES = 120
    DEPARTURE_PROTECTION_MINUTES = 120
    DETOUR_RED_MINUTES = 45
    MAX_AMBER_DAYS = 2

    attr_reader :day_metrics, :trip_metrics, :strict_blockers

    def initialize(store)
      @store = store
      unless store.preference_data.fetch("pace") == "relaxed"
        raise ArgumentError, "Strict itinerary analysis requires preferences.pace to be relaxed."
      end

      @day_metrics = store.days.map { |day| analyze_day(day) }
      @trip_metrics = analyze_trip
      @strict_blockers = @day_metrics.flat_map { |day| day.fetch("blocking_reasons").map { |reason| reason.merge("day" => day.fetch("day")) } }
      @strict_blockers.concat(@trip_metrics.fetch("blocking_reasons"))
    end

    def self.minutes(clock)
      hour, minute = clock.split(":").map(&:to_i)
      hour * 60 + minute
    end

    def self.duration(activity)
      start_clock = activity.dig("time", "start")
      end_clock = activity.dig("time", "end")
      return activity.dig("time", "estimated_duration_minutes").to_i unless start_clock && end_clock

      [minutes(end_clock) - minutes(start_clock), 0].max
    end

    private

    def scheduled_default_activities(day)
      day.fetch("activities").select do |activity|
        next false if activity.fetch("optional")
        time = activity.fetch("time")
        (time["date"].nil? || time["date"] == day.fetch("date")) && (time["start"] || time["end"])
      end
    end

    def conservative_gap_minutes(activities)
      activities = activities.reject { |activity| activity.dig("time", "concurrent_with_activity_ref") }
      activities.each_cons(2).sum do |previous, current|
        previous_end = previous.dig("time", "end") || previous.dig("time", "start")
        current_start = current.dig("time", "start")
        next 0 unless previous_end && current_start

        gap = self.class.minutes(current_start) - self.class.minutes(previous_end)
        gap >= 30 ? gap - 15 : 0
      end
    end

    def analyze_day(day)
      defaults = scheduled_default_activities(day)
      alternatives = day.fetch("activities").select { |activity| activity.fetch("optional") }
      starts = defaults.filter_map { |activity| activity.dig("time", "start") }
      finishes = defaults.filter_map { |activity| activity.dig("time", "end") || activity.dig("time", "start") }
      active_span = starts.empty? ? 0 : self.class.minutes(finishes.last) - self.class.minutes(starts.first)
      concurrent, sequential = defaults.partition { |activity| activity.dig("time", "concurrent_with_activity_ref") }
      scheduled = sequential.sum { |activity| self.class.duration(activity) }
      sequential_recovery = sequential.select { |activity| activity.fetch("pace_role") == "recovery" }.sum { |activity| self.class.duration(activity) }
      concurrent_recovery = concurrent.select { |activity| activity.fetch("pace_role") == "recovery" }.sum { |activity| self.class.duration(activity) }
      recovery = sequential_recovery + concurrent_recovery
      commitment = scheduled - sequential_recovery
      transport = defaults.select { |activity| activity.fetch("category") == "transport" }.sum { |activity| self.class.duration(activity) }
      slack = recovery + conservative_gap_minutes(defaults)
      anchors = defaults.count { |activity| activity.fetch("pace_role") == "major" }
      clusters = defaults.filter_map { |activity| activity["cluster"] }.uniq
      optional_minutes = alternatives.sum { |activity| self.class.duration(activity) }
      transfer = day.dig("planning", "transfer")
      detour = transfer ? [transport - transfer.fetch("direct_travel_minutes"), 0].max : 0
      departure_protection = defaults.select { |activity| activity.fetch("tags").include?("international-flight-protection") }.sum { |activity| self.class.duration(activity) }

      values = {
        active_span_minutes: active_span,
        commitment_minutes: commitment,
        transport_minutes: transport,
        discretionary_slack_minutes: slack,
        major_anchors: anchors,
        clusters: clusters.length,
        departure_protection_minutes: departure_protection
      }
      blocking = blocking_reasons(day, values, recovery, detour)
      classification = classify(day, values, recovery, blocking)
      amber_reasons = classification == "AMBER" ? green_shortfalls(day, values) : []

      {
        "day" => day.fetch("number"),
        "date" => day.fetch("date"),
        "day_type" => day.fetch("day_type"),
        "classification" => classification,
        "default_activity_count" => defaults.length,
        "optional_activity_count" => alternatives.length,
        "optional_estimated_minutes" => optional_minutes,
        "first_start" => starts.first,
        "last_finish" => finishes.last,
        "active_span_minutes" => active_span,
        "scheduled_default_minutes" => scheduled,
        "commitment_minutes" => commitment,
        "recovery_minutes" => recovery,
        "transport_minutes" => transport,
        "discretionary_slack_minutes" => slack,
        "major_anchors" => anchors,
        "clusters" => clusters,
        "route_pattern" => day.dig("planning", "route_pattern"),
        "direct_travel_minutes" => transfer&.fetch("direct_travel_minutes", nil),
        "incremental_travel_minutes" => transfer ? detour : nil,
        "direction" => transfer&.fetch("direction", nil),
        "departure_protection_minutes" => departure_protection,
        "blocking_reasons" => blocking,
        "amber_reasons" => amber_reasons
      }
    end

    def blocking_reasons(day, values, recovery, detour)
      return [] if day.fetch("day_type") == "overnight_flight"

      reasons = []
      add_over(reasons, "pace-active-span", "Active span", values[:active_span_minutes], RED[:active_span_minutes]) unless day.fetch("day_type") == "departure"
      add_over(reasons, "pace-commitment", "Commitments", values[:commitment_minutes], RED[:commitment_minutes])
      add_under(reasons, "pace-slack", "Discretionary slack", values[:discretionary_slack_minutes], RED[:discretionary_slack_minutes]) unless day.fetch("day_type") == "departure"

      if %w[sightseeing recovery].include?(day.fetch("day_type"))
        add_over(reasons, "pace-transport", "Transport", values[:transport_minutes], RED[:transport_minutes])
        add_over(reasons, "pace-major-anchors", "Major anchors", values[:major_anchors], RED[:major_anchors])
        add_over(reasons, "pace-clusters", "Geographic clusters", values[:clusters], RED[:clusters])
      elsif day.fetch("day_type") == "transfer"
        add_over(reasons, "pace-major-anchors", "Major anchors", values[:major_anchors], 1)
        if values[:transport_minutes] > TRANSFER_AMBER_MINUTES && !(values[:major_anchors].zero? && recovery >= LONG_TRANSFER_RECOVERY_MINUTES)
          reasons << reason("pace-transfer-load", "#{values[:transport_minutes]} transport minutes require a pure transfer and at least #{LONG_TRANSFER_RECOVERY_MINUTES} recovery minutes.")
        end
      elsif %w[arrival departure].include?(day.fetch("day_type")) && values[:major_anchors] > 1
        reasons << reason("pace-arrival-departure-anchors", "#{day.fetch('day_type').capitalize} day has #{values[:major_anchors]} major anchors; at most one light anchor is allowed.")
      end
      if day.fetch("day_type") == "departure" && values[:departure_protection_minutes] < DEPARTURE_PROTECTION_MINUTES
        reasons << reason("pace-departure-protection", "International departure protection #{values[:departure_protection_minutes]} minutes is below #{DEPARTURE_PROTECTION_MINUTES}.")
      end

      transfer = day.dig("planning", "transfer")
      if transfer && %w[lateral reverse].include?(transfer.fetch("direction")) && detour >= DETOUR_RED_MINUTES
        reasons << reason("route-reverse-detour", "#{transfer.fetch('direction').capitalize} routing adds #{detour} minutes over the direct transfer.")
      end
      reasons
    end

    def classify(day, values, recovery, blocking)
      return "LOGISTICS" if day.fetch("day_type") == "overnight_flight"
      return "RED" unless blocking.empty?

      if day.fetch("day_type") == "departure"
        return values[:commitment_minutes] <= GREEN[:commitment_minutes] &&
          values[:major_anchors] <= 1 && values[:departure_protection_minutes] >= DEPARTURE_PROTECTION_MINUTES ? "GREEN" : "AMBER"
      end

      green = values[:active_span_minutes] <= GREEN[:active_span_minutes] &&
        values[:commitment_minutes] <= GREEN[:commitment_minutes] &&
        values[:discretionary_slack_minutes] >= GREEN[:discretionary_slack_minutes]

      case day.fetch("day_type")
      when "sightseeing", "recovery"
        green &&= values[:transport_minutes] <= GREEN[:transport_minutes] &&
          values[:major_anchors] <= GREEN[:major_anchors] && values[:clusters] <= GREEN[:clusters]
      when "transfer"
        green &&= values[:transport_minutes] <= TRANSFER_GREEN_MINUTES && values[:major_anchors] <= 1
        return "AMBER" if values[:transport_minutes] > TRANSFER_AMBER_MINUTES && values[:major_anchors].zero? && recovery >= LONG_TRANSFER_RECOVERY_MINUTES
      when "arrival", "departure"
        green &&= values[:major_anchors] <= 1
      end
      green ? "GREEN" : "AMBER"
    end

    def green_shortfalls(day, values)
      reasons = []
      if day.fetch("day_type") == "departure"
        reasons << "commitments exceed #{GREEN[:commitment_minutes]} minutes" if values[:commitment_minutes] > GREEN[:commitment_minutes]
        reasons << "major anchors exceed 1" if values[:major_anchors] > 1
        reasons << "international departure protection is below #{DEPARTURE_PROTECTION_MINUTES} minutes" if values[:departure_protection_minutes] < DEPARTURE_PROTECTION_MINUTES
        return reasons
      end
      reasons << "active span exceeds #{GREEN[:active_span_minutes]} minutes" if values[:active_span_minutes] > GREEN[:active_span_minutes]
      reasons << "commitments exceed #{GREEN[:commitment_minutes]} minutes" if values[:commitment_minutes] > GREEN[:commitment_minutes]
      reasons << "slack is below #{GREEN[:discretionary_slack_minutes]} minutes" if values[:discretionary_slack_minutes] < GREEN[:discretionary_slack_minutes]
      if %w[sightseeing recovery].include?(day.fetch("day_type"))
        reasons << "transport exceeds #{GREEN[:transport_minutes]} minutes" if values[:transport_minutes] > GREEN[:transport_minutes]
        reasons << "major anchors exceed #{GREEN[:major_anchors]}" if values[:major_anchors] > GREEN[:major_anchors]
        reasons << "clusters exceed #{GREEN[:clusters]}" if values[:clusters] > GREEN[:clusters]
      elsif day.fetch("day_type") == "transfer"
        reasons << "transport exceeds #{TRANSFER_GREEN_MINUTES} minutes" if values[:transport_minutes] > TRANSFER_GREEN_MINUTES
      end
      reasons
    end

    def analyze_trip
      rated = @day_metrics.reject { |day| day.fetch("classification") == "LOGISTICS" }
      amber = rated.select { |day| day.fetch("classification") == "AMBER" }.map { |day| day.fetch("day") }
      red = rated.select { |day| day.fetch("classification") == "RED" }.map { |day| day.fetch("day") }
      blockers = []
      blockers << reason("pace-too-many-amber", "#{amber.length} AMBER days exceed the trip maximum of #{MAX_AMBER_DAYS}.") if amber.length > MAX_AMBER_DAYS
      amber.each_cons(2) do |left, right|
        blockers << reason("pace-consecutive-amber", "Days #{left} and #{right} are consecutive AMBER days.") if right == left + 1
      end

      base_runs = base_runs()
      base_runs.select { |run| run.fetch("nights") == 1 }.each do |run|
        arrival = @day_metrics.find { |day| day.fetch("day") == run.fetch("first_day") }
        departure = @day_metrics.find { |day| day.fetch("day") == run.fetch("first_day") + 1 }
        next unless arrival && departure
        next unless %w[AMBER RED].include?(arrival.fetch("classification")) && %w[AMBER RED].include?(departure.fetch("classification"))

        blockers << reason("base-one-night-friction", "One-night #{run.fetch('place_id')} base has demanding arrival day #{arrival.fetch('day')} and departure day #{departure.fetch('day')}.")
      end

      {
        "pace_counts" => @day_metrics.group_by { |day| day.fetch("classification") }.transform_values(&:length),
        "red_days" => red,
        "amber_days" => amber,
        "base_runs" => base_runs,
        "hotel_changes" => [base_runs.length - 1, 0].max,
        "total_default_minutes" => @day_metrics.sum { |day| day.fetch("scheduled_default_minutes") },
        "total_transport_minutes" => @day_metrics.sum { |day| day.fetch("transport_minutes") },
        "total_optional_estimated_minutes" => @day_metrics.sum { |day| day.fetch("optional_estimated_minutes") },
        "blocking_reasons" => blockers
      }
    end

    def base_runs
      bases = @store.days.filter_map do |day|
        base = day.fetch("sleep_base").filter_map { |token| token["place"] }.first
        [day.fetch("number"), base] if base
      end
      bases.chunk_while { |left, right| left.last == right.last }.map do |run|
        { "place_id" => run.first.last, "first_day" => run.first.first, "last_day" => run.last.first, "nights" => run.length }
      end
    end

    def add_over(reasons, code, label, value, limit)
      reasons << reason(code, "#{label} #{value} exceeds #{limit}.") if value > limit
    end

    def add_under(reasons, code, label, value, limit)
      reasons << reason(code, "#{label} #{value} is below #{limit}.") if value < limit
    end

    def reason(code, message)
      { "code" => code, "message" => message }
    end
  end

  class Validator
    TIME_PATTERN = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/
    ID_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    BOOKING_KINDS_REQUIRING_BUFFER = %w[bus rail rail_and_entry shuttle timed_entry].freeze
    WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze
    MEAL_OPTION_MAX_SEPARATION_KM = 3.0
    STRICT_PACE_CODES = %w[
      optional-timed optional-priority missing-pace-cluster planning-cluster-mismatch
      missing-intercluster-transport missing-transfer-planning route-underestimated
      pace-active-span pace-commitment pace-transport pace-slack pace-major-anchors
      pace-clusters pace-transfer-load pace-arrival-departure-anchors
      pace-departure-protection
      route-reverse-detour pace-too-many-amber pace-consecutive-amber
      base-one-night-friction
    ].freeze

    attr_reader :issues

    def initialize(store)
      @store = store
      @issues = []
      @activity_by_id = {}
      @booking_by_id = {}
      @constraint_by_id = {}
    end

    def validate
      issues.clear
      validate_schema_documents
      validate_shapes
      fatal_codes = %w[invalid-schema schema-type schema-required schema-version]
      return issues if issues.any? { |issue| issue.severity == :error && fatal_codes.include?(issue.code) }

      index_records
      validate_dates
      validate_references
      validate_journey_labels
      validate_rail_types
      validate_currencies
      validate_activity_options
      validate_meal_options
      validate_duplicate_entities
      validate_booking_dependencies
      validate_timeline
      validate_schedule_constraints
      validate_movements
      validate_travel_buffers
      validate_opening_hours
      validate_pace_structure
      validate_pace_analysis
      issues
    rescue KeyError, NoMethodError, TypeError => error
      add(:error, "invalid-structure", "data", "Validation stopped because the data shape is invalid: #{error.message}")
      issues
    end

    def errors? = issues.any? { |issue| issue.severity == :error }
    def strict_blockers = issues.select { |issue| STRICT_PACE_CODES.include?(issue.code) }

    private

    def add(severity, code, path, message)
      issues << Issue.new(severity:, code:, path:, message:)
    end

    def coordinate_distance_km(left, right)
      radians = Math::PI / 180
      left_latitude = left.fetch("latitude") * radians
      right_latitude = right.fetch("latitude") * radians
      latitude_delta = (right.fetch("latitude") - left.fetch("latitude")) * radians
      longitude_delta = (right.fetch("longitude") - left.fetch("longitude")) * radians
      haversine = Math.sin(latitude_delta / 2)**2 + Math.cos(left_latitude) * Math.cos(right_latitude) * Math.sin(longitude_delta / 2)**2
      6371 * 2 * Math.asin(Math.sqrt(haversine))
    end

    def validate_schema_documents
      documents = {
        "site" => @store.site,
        "trip" => @store.trip,
        "places" => @store.places,
        "bookings" => @store.bookings,
        "constraints" => @store.constraints,
        "preferences" => @store.preferences,
        "movements" => @store.movements,
        "activity_options" => @store.activity_options,
        "meal_options" => @store.meal_options
      }
      Dir[@store.framework_root.join("schemas", "*.schema.json")].sort.each do |path|
        schema = JSON.parse(File.read(path, encoding: "UTF-8"))
        unless schema.is_a?(Hash)
          add(:error, "invalid-schema", path, "Schema must be a JSON object.")
          next
        end
        name = File.basename(path, ".schema.json")
        document = documents.fetch(name)
        SchemaValidator.new(schema).validate(document).each do |result|
          add(:error, "schema-violation", "#{name}.yaml#{result.path}", result.message)
        end
      rescue JSON::ParserError => error
        add(:error, "invalid-schema", path, error.message)
      rescue ArgumentError, KeyError => error
        add(:error, "invalid-schema", path, error.message)
      end
    end

    def validate_shapes
      {
        "site.yaml" => [@store.site, %w[schema_version trip_slug storage_namespace locale title subtitle destination currencies metadata branding transport map route_authoring]],
        "trip.yaml" => [@store.trip, %w[schema_version trip days]],
        "places.yaml" => [@store.places, %w[schema_version places]],
        "bookings.yaml" => [@store.bookings, %w[schema_version bookings]],
        "constraints.yaml" => [@store.constraints, %w[schema_version constraints]],
        "preferences.yaml" => [@store.preferences, %w[schema_version preferences]],
        "movements.yaml" => [@store.movements, %w[schema_version days transitions alternatives]],
        "activity_options.yaml" => [@store.activity_options, %w[schema_version checked_on image_sources relaxed_visits destinations]],
        "meal_options.yaml" => [@store.meal_options, %w[schema_version checked_on exchange_rate ranking image_sources days]]
      }.each do |path, (document, keys)|
        unless document.is_a?(Hash)
          add(:error, "schema-type", path, "Document must be a mapping.")
          next
        end
        keys.each { |key| add(:error, "schema-required", path, "Missing required key #{key.inspect}.") unless document.key?(key) }
        expected_version = if path == "meal_options.yaml"
          3
        elsif path == "movements.yaml"
          2
        else
          1
        end
        add(:error, "schema-version", path, "schema_version must be #{expected_version}.") unless document["schema_version"] == expected_version
      end

      require_hash(@store.site["destination"], "site.yaml#destination", %w[name search_hint timezones])
      require_hash(@store.site["currencies"], "site.yaml#currencies", %w[base quote display])
      require_hash(@store.site["transport"], "site.yaml#transport", %w[classifications])
      require_hash(@store.site["map"], "site.yaml#map", %w[provider_name style_url library_css_url library_js_url library_module_url])
      require_hash(@store.trip["trip"], "trip.yaml#trip", %w[id title subtitle timezone origin_timezone start_date end_date facts route booking_refs])
      require_array(@store.trip["days"], "trip.yaml#days")
      require_hash(@store.places["places"], "places.yaml#places")
      require_array(@store.bookings["bookings"], "bookings.yaml#bookings")
      require_array(@store.constraints["constraints"], "constraints.yaml#constraints")
      require_hash(@store.preferences["preferences"], "preferences.yaml#preferences", %w[pace minimum_transfer_buffer_minutes priorities optimization_rules])
      require_array(@store.movements["days"], "movements.yaml#days")
      require_array(@store.movements["transitions"], "movements.yaml#transitions")
      require_array(@store.movements["alternatives"], "movements.yaml#alternatives")
      require_hash(@store.activity_options["image_sources"], "activity_options.yaml#image_sources")
      require_hash(@store.activity_options["relaxed_visits"], "activity_options.yaml#relaxed_visits")
      require_array(@store.activity_options["destinations"], "activity_options.yaml#destinations")
      require_array(@store.meal_options["days"], "meal_options.yaml#days")

      Array(@store.trip["days"]).each_with_index do |day, index|
        require_hash(day, "trip.yaml#days/#{index}", %w[number date label day_type planning sleep_base activities])
        require_hash(day["planning"], "trip.yaml#days/#{index}/planning", %w[route_pattern clusters]) if day.is_a?(Hash)
        require_array(day["sleep_base"], "trip.yaml#days/#{index}/sleep_base") if day.is_a?(Hash)
        require_array(day["activities"], "trip.yaml#days/#{index}/activities") if day.is_a?(Hash)
        Array(day["activities"]).each_with_index do |activity, activity_index|
          path = "trip.yaml#days/#{index}/activities/#{activity_index}"
          required = %w[id time category priority optional pace_role tags content booking_refs constraint_refs]
          required << "meal_type" if activity.is_a?(Hash) && activity["category"] == "meal"
          require_hash(activity, path, required)
          require_hash(activity["time"], "#{path}/time", %w[label]) if activity.is_a?(Hash)
          require_array(activity["content"], "#{path}/content") if activity.is_a?(Hash)
          if activity.is_a?(Hash) && activity["category"] != "meal" && activity.key?("meal_type")
            add(:error, "meal-type-category", "#{path}/meal_type", "meal_type is allowed only on meal activities.")
          end
        end
      end

      @store.place_catalog.each do |id, place|
        add(:error, "invalid-id", "places.yaml#places/#{id}", "Place ID must be kebab-case.") unless id.match?(ID_PATTERN)
        require_hash(place, "places.yaml#places/#{id}", %w[name description url kind])
      end if @store.places["places"].is_a?(Hash)

      @store.booking_list.each_with_index { |booking, index| require_hash(booking, "bookings.yaml#bookings/#{index}", %w[id kind status]) } if @store.bookings["bookings"].is_a?(Array)
      @store.constraint_list.each_with_index { |constraint, index| require_hash(constraint, "constraints.yaml#constraints/#{index}", %w[id kind severity description]) } if @store.constraints["constraints"].is_a?(Array)
      @store.activity_option_destinations.each_with_index do |destination, index|
        path = "activity_options.yaml#destinations/#{index}"
        require_hash(destination, path, %w[place_id summary planning_note recommendation_source fallback_image_id options])
        require_array(destination["options"], "#{path}/options") if destination.is_a?(Hash)
        Array(destination["options"]).each_with_index do |option, option_index|
          require_hash(option, "#{path}/options/#{option_index}", %w[place_id category source_url])
        end
      end if @store.activity_options["destinations"].is_a?(Array)

    end

    def require_hash(value, path, required = [])
      unless value.is_a?(Hash)
        add(:error, "schema-type", path, "Expected a mapping.")
        return
      end
      required.each { |key| add(:error, "schema-required", path, "Missing required key #{key.inspect}.") unless value.key?(key) }
    end

    def require_array(value, path)
      add(:error, "schema-type", path, "Expected a list.") unless value.is_a?(Array)
    end

    def index_records
      @store.activities.each do |activity|
        id = activity.fetch("id")
        add(:error, "duplicate-activity", "trip.yaml", "Activity ID #{id.inspect} is duplicated.") if @activity_by_id.key?(id)
        @activity_by_id[id] = activity
      end
      @store.booking_list.each do |booking|
        id = booking.fetch("id")
        add(:error, "duplicate-booking", "bookings.yaml", "Booking ID #{id.inspect} is duplicated.") if @booking_by_id.key?(id)
        @booking_by_id[id] = booking
      end
      @store.constraint_list.each do |constraint|
        id = constraint.fetch("id")
        add(:error, "duplicate-constraint", "constraints.yaml", "Constraint ID #{id.inspect} is duplicated.") if @constraint_by_id.key?(id)
        @constraint_by_id[id] = constraint
      end
    end

    def validate_dates
      metadata = @store.trip_metadata
      start_date = parse_date(metadata["start_date"], "trip.yaml#trip/start_date")
      end_date = parse_date(metadata["end_date"], "trip.yaml#trip/end_date")
      add(:error, "invalid-date-range", "trip.yaml#trip", "end_date precedes start_date.") if start_date && end_date && end_date < start_date

      previous_date = nil
      @store.days.each_with_index do |day, index|
        path = "trip.yaml#days/#{index}"
        date = parse_date(day["date"], "#{path}/date")
        add(:error, "day-number", "#{path}/number", "Expected day number #{index + 1}.") unless day["number"] == index + 1
        if previous_date && date && date != previous_date + 1
          add(:error, "nonconsecutive-days", "#{path}/date", "Itinerary days must be consecutive; expected #{previous_date + 1}.")
        end
        if date && start_date && end_date && !date.between?(start_date, end_date)
          add(:error, "date-outside-trip", "#{path}/date", "Day is outside the trip date range.")
        end
        previous_date = date if date
      end
      if start_date && @store.days.first && @store.days.first["date"] != start_date.iso8601
        add(:error, "start-date-mismatch", "trip.yaml#trip/start_date", "Does not match the first itinerary day.")
      end
      if end_date && @store.days.last && @store.days.last["date"] != end_date.iso8601
        add(:error, "end-date-mismatch", "trip.yaml#trip/end_date", "Does not match the last itinerary day.")
      end
    end

    def parse_date(value, path)
      Date.iso8601(value.to_s)
    rescue Date::Error
      add(:error, "invalid-date", path, "Expected an ISO 8601 date, got #{value.inspect}.")
      nil
    end

    def validate_references
      places = @store.place_catalog
      @store.trip_metadata.fetch("route").each do |place_id|
        add(:error, "unknown-place", "trip.yaml#trip/route", "Unknown place #{place_id.inspect}.") unless places.key?(place_id)
      end
      @store.trip_metadata.fetch("booking_refs").each do |booking_id|
        add(:error, "unknown-booking", "trip.yaml#trip/booking_refs", "Unknown booking #{booking_id.inspect}.") unless @booking_by_id.key?(booking_id)
      end

      @store.days.each_with_index do |day, day_index|
        validate_content_refs(day.fetch("sleep_base"), "trip.yaml#days/#{day_index}/sleep_base", places)
        day.fetch("activities").each_with_index do |activity, activity_index|
          path = "trip.yaml#days/#{day_index}/activities/#{activity_index}"
          validate_content_refs(activity.fetch("content"), "#{path}/content", places)
          activity.fetch("booking_refs").each do |booking_id|
            add(:error, "unknown-booking", "#{path}/booking_refs", "Unknown booking #{booking_id.inspect}.") unless @booking_by_id.key?(booking_id)
          end
          activity.fetch("constraint_refs").each do |constraint_id|
            add(:error, "unknown-constraint", "#{path}/constraint_refs", "Unknown constraint #{constraint_id.inspect}.") unless @constraint_by_id.key?(constraint_id)
          end
        end
        transfer = day.dig("planning", "transfer")
        if transfer
          %w[origin destination].each do |field|
            place_id = transfer.fetch(field)
            add(:error, "unknown-place", "trip.yaml#days/#{day_index}/planning/transfer/#{field}", "Unknown place #{place_id.inspect}.") unless places.key?(place_id)
          end
        end
      end

      @store.booking_list.each_with_index do |booking, index|
        path = "bookings.yaml#bookings/#{index}"
        if booking["activity_id"] && !@activity_by_id.key?(booking["activity_id"])
          add(:error, "unknown-activity", path, "Unknown activity #{booking['activity_id'].inspect}.")
        end
        booking.fetch("activity_refs", []).each do |activity_id|
          add(:error, "unknown-activity", path, "Unknown activity #{activity_id.inspect}.") unless @activity_by_id.key?(activity_id)
        end
        if booking["place_id"] && !places.key?(booking["place_id"])
          add(:error, "unknown-place", path, "Unknown place #{booking['place_id'].inspect}.")
        end
      end

      @store.constraint_list.each_with_index do |constraint, index|
        path = "constraints.yaml#constraints/#{index}"
        constraint.fetch("activity_refs", []).each { |id| add(:error, "unknown-activity", path, "Unknown activity #{id.inspect}.") unless @activity_by_id.key?(id) }
        constraint.fetch("booking_refs", []).each { |id| add(:error, "unknown-booking", path, "Unknown booking #{id.inspect}.") unless @booking_by_id.key?(id) }
        constraint.fetch("exceptions", []).each do |exception|
          id = exception.fetch("activity_ref")
          add(:error, "unknown-activity", path, "Unknown exception activity #{id.inspect}.") unless @activity_by_id.key?(id)
        end
      end

      @store.activity_option_destinations.each_with_index do |destination, destination_index|
        path = "activity_options.yaml#destinations/#{destination_index}"
        place_id = destination.fetch("place_id")
        add(:error, "unknown-place", "#{path}/place_id", "Unknown destination #{place_id.inspect}.") unless places.key?(place_id)
        destination.fetch("options").each_with_index do |option, option_index|
          option_place_id = option.fetch("place_id")
          add(:error, "unknown-place", "#{path}/options/#{option_index}/place_id", "Unknown option place #{option_place_id.inspect}.") unless places.key?(option_place_id)
        end
      end
    end

    def validate_content_refs(tokens, path, places)
      tokens.each_with_index do |token, index|
        unless token.is_a?(Hash) && ((token.keys & %w[text place]).length == 1)
          add(:error, "invalid-content-token", "#{path}/#{index}", "Each token must contain exactly one of text or place.")
          next
        end
        place_id = token["place"]
        add(:error, "unknown-place", "#{path}/#{index}", "Unknown place #{place_id.inspect}.") if place_id && !places.key?(place_id)
      end
    end

    def validate_rail_types
      configured = @store.site.dig("transport", "classifications") || {}
      @store.days.each_with_index do |day, day_index|
        day.fetch("activities").each_with_index do |activity, activity_index|
          next unless activity.key?("rail_types")
          path = "trip.yaml#days/#{day_index}/activities/#{activity_index}/rail_types"
          if activity.fetch("category") != "transport"
            add(:error, "rail-type-category", path, "Rail classifications may only be assigned to transport activities.")
          end
          activity.fetch("rail_types").each do |classification|
            add(:error, "unknown-rail-classification", path, "Unknown transport classification #{classification.inspect}.") unless configured.key?(classification)
          end
        end
      end
    end

    def validate_currencies
      configured = @store.site.fetch("currencies")
      display = configured.fetch("display")
      base = configured.fetch("base")
      quote = configured.fetch("quote")
      [base, quote].each do |currency|
        add(:error, "currency-display-missing", "site.yaml#currencies/display", "Missing display formatting for #{currency}.") unless display.key?(currency)
      end

      exchange = @store.meal_options.fetch("exchange_rate")
      unless exchange.values_at("base_currency", "quote_currency") == [base, quote]
        add(:error, "currency-pair-mismatch", "meal_options.yaml#exchange_rate", "Exchange-rate currencies must match site.yaml base and quote currencies.")
      end
      allowed = [base, quote]
      @store.meal_option_days.flat_map { |day| day.fetch("slots") }.flat_map { |slot| slot.fetch("options") }.each do |option|
        order = option.fetch("order_for_two")
        prices = order.fetch("items").filter_map { |item| item["unit_price"] } + [order.fetch("estimated_total_spend")]
        prices.each do |price|
          currency = price.fetch("currency")
          add(:error, "unsupported-currency", "meal_options.yaml", "Currency #{currency.inspect} is not configured for this trip.") unless allowed.include?(currency)
        end
      end
    end

    def validate_journey_labels
      @store.days.each_with_index do |day, day_index|
        day.fetch("activities").each_with_index do |activity, activity_index|
          next unless activity.fetch("category") == "logistics"

          title = activity["title"].to_s.strip
          path = "trip.yaml#days/#{day_index}/activities/#{activity_index}/title"
          if title.empty?
            add(:error, "missing-logistics-title", path, "Logistics activities need a specific journey title.")
          elsif title.casecmp?("logistics")
            add(:error, "generic-logistics-title", path, "Replace the generic Logistics title with the activity being performed.")
          end
        end
      end
    end

    def validate_activity_options
      destination_ids = @store.activity_option_destinations.map { |destination| destination.fetch("place_id") }
      expected_ids = @store.trip_metadata.fetch("route").uniq
      unless destination_ids == expected_ids
        add(:error, "activity-option-destinations", "activity_options.yaml#destinations", "Expected destination order #{expected_ids.inspect}, got #{destination_ids.inspect}.")
      end

      image_sources = @store.activity_options.fetch("image_sources")
      image_sources.each_key do |image_id|
        matches = Dir[@store.root.join("assets", "activity-options", "#{image_id}.{jpg,jpeg,png,webp,svg}")]
        add(:error, "missing-activity-image", "activity_options.yaml#image_sources/#{image_id}", "Missing local activity image for #{image_id.inspect}.") if matches.empty?
      end

      seen_options = Set.new
      @store.activity_option_destinations.each_with_index do |destination, destination_index|
        path = "activity_options.yaml#destinations/#{destination_index}"
        fallback_id = destination.fetch("fallback_image_id")
        add(:error, "unknown-activity-image", "#{path}/fallback_image_id", "Unknown image #{fallback_id.inspect}.") unless image_sources.key?(fallback_id)
        add(:error, "activity-option-count", "#{path}/options", "Each destination needs at least five curated options.") if destination.fetch("options").length < 5

        destination.fetch("options").each_with_index do |option, option_index|
          option_path = "#{path}/options/#{option_index}"
          place_id = option.fetch("place_id")
          if seen_options.include?(place_id)
            add(:error, "duplicate-activity-option", option_path, "Option #{place_id.inspect} appears more than once.")
          else
            seen_options << place_id
          end
          image_id = option.fetch("image_id", fallback_id)
          add(:error, "unknown-activity-image", "#{option_path}/image_id", "Unknown image #{image_id.inspect}.") unless image_sources.key?(image_id)
          add(:error, "persisted-activity-selection", option_path, "Selection state must be derived from trip.yaml, not stored in activity_options.yaml.") if option.key?("selected")
        end
      end

      relaxed_visit_ids = @store.activity_options.fetch("relaxed_visits").keys.to_set
      missing_duration_ids = seen_options - relaxed_visit_ids
      extra_duration_ids = relaxed_visit_ids - seen_options
      unless missing_duration_ids.empty?
        add(:error, "missing-relaxed-visit", "activity_options.yaml#relaxed_visits", "Missing duration guidance for #{missing_duration_ids.to_a.sort.join(', ')}.")
      end
      unless extra_duration_ids.empty?
        add(:error, "orphan-relaxed-visit", "activity_options.yaml#relaxed_visits", "Duration guidance has no matching option for #{extra_duration_ids.to_a.sort.join(', ')}.")
      end
    end

    def validate_meal_options
      expected_meals = @store.days.flat_map do |day|
        day.fetch("activities").select { |activity| activity.fetch("category") == "meal" }
          .map { |activity| [activity.fetch("id"), [day, activity]] }
      end.to_h
      slots = @store.meal_option_days.flat_map { |meal_day| meal_day.fetch("slots") }
      slot_refs = slots.map { |slot| slot.fetch("itinerary_activity_ref") }

      unless slot_refs.sort == expected_meals.keys.sort
        add(:error, "meal-option-coverage", "meal_options.yaml#days", "Meal options must cover every canonical meal activity exactly once.")
      end
      if slot_refs.uniq.length != slot_refs.length
        add(:error, "duplicate-meal-slot", "meal_options.yaml#days", "A canonical meal activity may appear in only one meal slot.")
      end

      option_ids = Set.new
      generic_place_uses = Hash.new { |hash, key| hash[key] = [] }
      slots.each do |slot|
        path = "meal_options.yaml##{slot.fetch('id')}"
        day, activity = expected_meals[slot.fetch("itinerary_activity_ref")]
        unless activity
          add(:error, "unknown-activity", path, "Unknown meal activity #{slot.fetch('itinerary_activity_ref').inspect}.")
          next
        end
        add(:error, "meal-activity-day", path, "Meal slot is assigned to the wrong itinerary day.") unless day.fetch("number") == @store.meal_option_days.find { |entry| entry.fetch("slots").include?(slot) }.fetch("day")
        add(:error, "meal-type-mismatch", path, "Meal type must match the canonical activity.") unless slot.fetch("meal") == activity.fetch("meal_type")
        add(:error, "meal-time-mismatch", path, "Meal time must match the canonical activity.") unless slot.fetch("time_label") == activity.dig("time", "label")

        canonical_restaurant_ids = activity.fetch("content").filter_map { |token| token["place"] }
          .select { |place_id| %w[restaurant shop].include?(@store.place_catalog.dig(place_id, "kind")) }
        restaurant_specific = canonical_restaurant_ids.any?

        options = slot.fetch("options")
        expected_count = slot.fetch("status") == "fixed" ? 1 : 3
        add(:error, "meal-option-count", "#{path}/options", "#{slot.fetch('status').capitalize} meal slots require exactly #{expected_count} option#{expected_count == 1 ? '' : 's'}.") unless options.length == expected_count
        ranks = options.map { |option| option.fetch("rank") }
        add(:error, "meal-ranks", "#{path}/options", "Meal option ranks must be consecutive from one.") unless ranks.sort == (1..expected_count).to_a
        place_ids = options.map { |option| option.fetch("place_id") }
        add(:error, "duplicate-meal-place", "#{path}/options", "A meal slot cannot repeat a venue.") unless place_ids.uniq.length == place_ids.length

        options.each_with_index do |option, index|
          option_path = "#{path}/options/#{index}"
          add(:error, "duplicate-meal-option", option_path, "Meal option IDs must be unique.") unless option_ids.add?(option.fetch("id"))
          place = @store.place_catalog[option.fetch("place_id")]
          if place.nil?
            add(:error, "unknown-place", "#{option_path}/place_id", "Unknown meal venue #{option.fetch('place_id').inspect}.")
            next
          end
          add(:error, "invalid-meal-place-kind", "#{option_path}/place_id", "Meal venues must be restaurants or shops.") unless %w[restaurant shop].include?(place.fetch("kind"))
          coordinates = place["coordinates"]
          if coordinates.nil? || !%w[exact entrance].include?(coordinates["precision"])
            add(:error, "imprecise-meal-coordinates", "#{option_path}/place_id", "Meal venues require storefront or entrance coordinates.")
          end
          add(:error, "meal-order-empty", "#{option_path}/order_for_two/items", "Recommended order for two cannot be empty.") if option.dig("order_for_two", "items").empty?
          option.fetch("route_fit").slice("from_activity_ref", "to_activity_ref").each_value do |activity_ref|
            add(:error, "meal-route-activity-day", "#{option_path}/route_fit", "Route activity #{activity_ref.inspect} must be on Day #{day.fetch('number')}.") unless day.fetch("activities").any? { |candidate| candidate.fetch("id") == activity_ref }
          end

          next if restaurant_specific

          generic_place_uses[option.fetch("place_id")] << slot.fetch("id")
          route = option.fetch("route_fit")
          %w[walking_distance_meters direct_flow_minutes via_venue_flow_minutes provider].each do |field|
            add(:error, "meal-route-evidence", "#{option_path}/route_fit/#{field}", "Generic meal routes require #{field}.") unless route.key?(field)
          end
          detour = route.fetch("incremental_detour_minutes")
          if detour > 20
            add(:error, "meal-detour-absolute-limit", "#{option_path}/route_fit/incremental_detour_minutes", "Meal detours may never exceed 20 minutes.")
          elsif detour > 15 && !route.key?("distance_exception")
            add(:error, "meal-detour-exception", "#{option_path}/route_fit", "A 16–20 minute detour requires an explicit exception reason.")
          elsif detour <= 15 && route.key?("distance_exception")
            add(:error, "unneeded-meal-detour-exception", "#{option_path}/route_fit", "Distance exceptions are only valid for 16–20 minute detours.")
          end
          if route["via_venue_flow_minutes"] && route["direct_flow_minutes"] && route["via_venue_flow_minutes"] - route["direct_flow_minutes"] != detour
            add(:error, "meal-route-arithmetic", "#{option_path}/route_fit", "Via-flow minus direct-flow minutes must equal incremental detour minutes.")
          end
          if route["status"] != "verified" && !route["verification_note"]
            add(:error, "meal-route-unverified", "#{option_path}/route_fit/status", "A provisional generic-meal route requires an explicit verification note.")
          end

          hours = option["operating_hours"]
          if hours.nil?
            add(:error, "meal-hours-missing", "#{option_path}/operating_hours", "Generic meal choices require date-specific operating-hours evidence.")
          else
            add(:error, "meal-hours-window", "#{option_path}/operating_hours/meal_window", "Hours evidence must identify the canonical meal window.") unless hours["meal_window"] == slot.fetch("time_label")
            add(:error, "meal-hours-incompatible", "#{option_path}/operating_hours/compatible", "A visible recommendation must be open for its meal window.") unless hours["compatible"] == true
            add(:error, "meal-hours-source", "#{option_path}/operating_hours/source_url", "Hours evidence requires a source URL.") unless hours["source_url"]&.start_with?("http")
          end

          option.fetch("order_for_two").fetch("items").each_with_index do |item, item_index|
            price = item["unit_price"]
            add(:error, "meal-item-price", "#{option_path}/order_for_two/items/#{item_index}/unit_price", "Every generic-meal order item requires a sourced unit price.") unless price&.fetch("source_url", nil)&.start_with?("http")
          end
          evidence = option.fetch("evidence")
          add(:error, "meal-evidence-count", "#{option_path}/evidence", "Generic recommendations require both venue/hours and route evidence.") if evidence.length < 2
          evidence.each_with_index do |source, evidence_index|
            add(:error, "meal-evidence-purpose", "#{option_path}/evidence/#{evidence_index}", "Evidence must state its title and supported claim.") unless source["title"] && source["supports"]
          end
        end

        options.combination(2).each do |left, right|
          left_coordinates = @store.place_catalog.dig(left.fetch("place_id"), "coordinates")
          right_coordinates = @store.place_catalog.dig(right.fetch("place_id"), "coordinates")
          next unless left_coordinates&.key?("latitude") && left_coordinates&.key?("longitude") && right_coordinates&.key?("latitude") && right_coordinates&.key?("longitude")
          next unless coordinate_distance_km(left_coordinates, right_coordinates) > MEAL_OPTION_MAX_SEPARATION_KM

          add(:error, "distant-meal-options", "#{path}/options", "Nearby meal options #{left.fetch('place_id').inspect} and #{right.fetch('place_id').inspect} are more than #{MEAL_OPTION_MAX_SEPARATION_KM.to_i} km apart.")
        end

        canonical_place_ids = activity.fetch("content").filter_map { |token| token["place"] } & place_ids
        if slot.fetch("status") == "fixed" && canonical_place_ids != [options.first.fetch("place_id")]
          add(:error, "fixed-meal-unselected", path, "Fixed meals must point to their rank-one canonical venue.")
        elsif canonical_place_ids.any? && canonical_place_ids != [options.first.fetch("place_id")]
          add(:error, "meal-selected-rank", path, "A canonical restaurant must be the rank-one meal option.")
        end
      end

      generic_place_uses.each do |place_id, slot_ids|
        next if slot_ids.length == 1

        add(:error, "reused-generic-meal-place", "meal_options.yaml#days", "Generic meal venue #{place_id.inspect} is reused in #{slot_ids.join(', ')}; each window requires an independent shortlist.")
      end
    end


    def validate_duplicate_entities
      by_name = Hash.new { |hash, key| hash[key] = [] }
      by_url = Hash.new { |hash, key| hash[key] = [] }
      @store.place_catalog.each do |id, place|
        normalized_name = place.fetch("name").downcase.gsub(/[^a-z0-9]/, "")
        normalized_url = place.fetch("url").downcase.sub(%r{/\z}, "")
        by_name[normalized_name] << id
        by_url[normalized_url] << id
      end
      by_name.each_value { |ids| add(:error, "duplicate-place-name", "places.yaml", "Possible duplicate places: #{ids.join(', ')}.") if ids.length > 1 }
      by_url.each_value do |ids|
        next unless ids.length > 1
        kinds = ids.map { |id| @store.place_catalog.fetch(id).fetch("kind") }
        next if kinds.all? { |kind| %w[restaurant shop].include?(kind) }
        add(:error, "duplicate-place-url", "places.yaml", "Places share a URL: #{ids.join(', ')}.")
      end
    end

    def validate_booking_dependencies
      @store.booking_list.each do |booking|
        booking.fetch("depends_on", []).each do |dependency|
          add(:error, "unknown-booking-dependency", "bookings.yaml##{booking['id']}", "Unknown dependency #{dependency.inspect}.") unless @booking_by_id.key?(dependency)
          add(:error, "self-booking-dependency", "bookings.yaml##{booking['id']}", "A booking cannot depend on itself.") if dependency == booking["id"]
        end
      end

      visiting = {}
      visited = {}
      visit = lambda do |id|
        return if visited[id]
        if visiting[id]
          add(:error, "booking-dependency-cycle", "bookings.yaml##{id}", "Booking dependency cycle detected.")
          return
        end
        visiting[id] = true
        @booking_by_id.fetch(id).fetch("depends_on", []).each { |dependency| visit.call(dependency) if @booking_by_id.key?(dependency) }
        visiting.delete(id)
        visited[id] = true
      end
      @booking_by_id.each_key { |id| visit.call(id) }
    end

    def validate_timeline
      @store.days.each_with_index do |day, day_index|
        previous_start = nil
        previous_id = nil
        timed_activities = []
        day.fetch("activities").each_with_index do |activity, activity_index|
          path = "trip.yaml#days/#{day_index}/activities/#{activity_index}/time"
          time = activity.fetch("time")
          %w[start end].each do |field|
            value = time[field]
            add(:error, "invalid-time", "#{path}/#{field}", "Expected HH:MM, got #{value.inspect}.") if value && !value.match?(TIME_PATTERN)
          end
          date = parse_date(time.fetch("date", day.fetch("date")), "#{path}/date")
          next unless date

          start_at = date_time(date, time["start"])
          end_at = date_time(date, time["end"])
          if start_at && end_at && end_at < start_at
            add(:error, "invalid-time-range", path, "End time precedes start time.")
          end
          marker = start_at || end_at
          if marker && previous_start && marker < previous_start
            add(:error, "chronological-order", path, "#{activity['id']} appears before #{previous_id}.")
          end
          concurrent_ref = time["concurrent_with_activity_ref"]
          if concurrent_ref
            host = @activity_by_id[concurrent_ref]
            host_time = host&.fetch("time", nil)
            host_start = host_time && date_time(date, host_time["start"])
            host_end = host_time && date_time(date, host_time["end"])
            if activity.fetch("category") != "meal" || !host || !%w[transport logistics].include?(host.fetch("category"))
              add(:error, "invalid-concurrent-meal", "#{path}/concurrent_with_activity_ref", "Concurrency is allowed only for a meal inside a transport or logistics activity.")
            elsif !start_at || !end_at || !host_start || !host_end || start_at < host_start || end_at > host_end
              add(:error, "concurrent-meal-containment", path, "Concurrent meal must be wholly contained by #{concurrent_ref}.")
            elsif !day.fetch("activities").include?(host)
              add(:error, "concurrent-meal-day", path, "Concurrent host #{concurrent_ref} must be on the same day.")
            end
          end
          timed_activities.each do |prior|
            next unless start_at && prior.fetch(:end_at) && start_at < prior.fetch(:end_at)
            next if concurrent_ref == prior.fetch(:activity).fetch("id")
            add(:error, "chronological-conflict", path, "#{activity['id']} overlaps #{prior.fetch(:activity).fetch('id')} without declared concurrency.")
          end
          previous_start = marker if marker
          previous_id = activity.fetch("id") if marker
          timed_activities << { activity: activity, end_at: end_at || start_at } if marker
        end
      end
    end

    def validate_schedule_constraints
      @store.constraint_list.each do |constraint|
        case constraint.fetch("kind")
        when "daily_start"
          validate_daily_start_constraint(constraint)
        when "minimum_duration"
          validate_minimum_duration_constraint(constraint)
        end
      end
    end

    def validate_daily_start_constraint(constraint)
      threshold = minutes(constraint.fetch("wake_not_before")) + constraint.fetch("readiness_minutes")
      severity = constraint.fetch("severity") == "hard" ? :error : :warning

      @store.days.each_with_index do |day, day_index|
        first = day.fetch("activities").reject { |activity| activity.fetch("optional") }
          .select { |activity| activity.dig("time", "start") }
          .min_by { |activity| minutes(activity.dig("time", "start")) }
        next unless first && minutes(first.dig("time", "start")) < threshold

        add(severity, "daily-start-too-early", "trip.yaml#days/#{day_index}",
          "#{first.fetch('id')} starts at #{first.dig('time', 'start')}; #{constraint.fetch('id')} requires the first default activity at or after #{format('%02d:%02d', threshold / 60, threshold % 60)}.")
      end
    end

    def validate_minimum_duration_constraint(constraint)
      severity = constraint.fetch("severity") == "hard" ? :error : :warning
      minimum = constraint.fetch("minimum_duration_minutes")
      exceptions = constraint.fetch("exceptions", []).to_h { |exception| [exception.fetch("activity_ref"), exception.fetch("reason")] }

      @store.days.each_with_index do |day, day_index|
        day.fetch("activities").each_with_index do |activity, activity_index|
          next if activity.fetch("optional") || activity.fetch("category") != constraint.fetch("activity_category")
          next if constraint["meal_type"] && activity["meal_type"] != constraint.fetch("meal_type")
          next if exceptions.key?(activity.fetch("id"))

          duration = PaceAnalyzer.duration(activity)
          next if duration >= minimum

          code = constraint.fetch("severity") == "hard" ? "meal-duration-too-short" : "preferred-meal-duration"
          add(severity, code, "trip.yaml#days/#{day_index}/activities/#{activity_index}",
            "#{activity.fetch('id')} lasts #{duration} minutes; #{constraint.fetch('id')} requires at least #{minimum} minutes.")
        end
      end
    end

    def validate_movements
      places = @store.place_catalog
      trip_days = @store.days.to_h { |day| [day.fetch("number"), day] }
      movement_numbers = @store.movement_days.map { |day| day.fetch("day") }
      expected_numbers = trip_days.keys
      unless movement_numbers == expected_numbers
        add(:error, "movement-days", "movements.yaml#days", "Expected movement days #{expected_numbers.inspect}, got #{movement_numbers.inspect}.")
      end

      seen_stop_ids = {}
      seen_leg_ids = {}
      @store.movement_days.each_with_index do |movement_day, day_index|
        path = "movements.yaml#days/#{day_index}"
        trip_day = trip_days[movement_day.fetch("day")]
        next unless trip_day

        window_start = minutes(movement_day.fetch("window_start"))
        window_end = minutes(movement_day.fetch("window_end"))
        add(:error, "movement-window", path, "Movement window ends before it starts.") if window_end < window_start
        day_activities = trip_day.fetch("activities").to_h { |activity| [activity.fetch("id"), activity] }
        day_activity_ids = day_activities.keys.to_set
        stops = {}

        movement_day.fetch("stops").each_with_index do |stop, stop_index|
          stop_path = "#{path}/stops/#{stop_index}"
          id = stop.fetch("id")
          if seen_stop_ids.key?(id)
            add(:error, "duplicate-movement-stop", stop_path, "Stop ID #{id.inspect} is duplicated.")
          else
            seen_stop_ids[id] = true
          end
          stops[id] = stop

          place_id = stop.fetch("place_id")
          place = places[place_id]
          if place.nil?
            add(:error, "unknown-place", stop_path, "Unknown movement place #{place_id.inspect}.")
          elsif !place["coordinates"]
            add(:error, "missing-place-coordinates", stop_path, "Movement place #{place_id.inspect} requires public coordinates.")
          end

          start_minute = minutes(stop.fetch("start_time"))
          end_minute = minutes(stop.fetch("end_time"))
          add(:error, "movement-time-range", stop_path, "Stop ends before it starts.") if end_minute < start_minute
          if start_minute < window_start || end_minute > window_end
            add(:error, "movement-outside-window", stop_path, "Stop lies outside the day's movement window.")
          end
          stop.fetch("activity_refs").each do |activity_id|
            add(:error, "movement-activity-day", stop_path, "Activity #{activity_id.inspect} is not on day #{movement_day.fetch('day')}.") unless day_activity_ids.include?(activity_id)
          end
        end

        previous_leg_end = nil
        movement_day.fetch("legs").each_with_index do |leg, leg_index|
          leg_path = "#{path}/legs/#{leg_index}"
          id = leg.fetch("id")
          if seen_leg_ids.key?(id)
            add(:error, "duplicate-movement-leg", leg_path, "Leg ID #{id.inspect} is duplicated.")
          else
            seen_leg_ids[id] = true
          end

          from = stops[leg.fetch("from_stop")]
          to = stops[leg.fetch("to_stop")]
          add(:error, "unknown-movement-stop", leg_path, "Unknown from_stop #{leg.fetch('from_stop').inspect}.") unless from
          add(:error, "unknown-movement-stop", leg_path, "Unknown to_stop #{leg.fetch('to_stop').inspect}.") unless to

          start_minute = minutes(leg.fetch("start_time"))
          end_minute = minutes(leg.fetch("end_time"))
          add(:error, "movement-time-range", leg_path, "Leg ends before it starts.") if end_minute < start_minute
          if start_minute < window_start || end_minute > window_end
            add(:error, "movement-outside-window", leg_path, "Leg lies outside the day's movement window.")
          end
          if previous_leg_end && start_minute < previous_leg_end
            add(:error, "movement-overlap", leg_path, "Movement legs overlap or are out of order.")
          end
          previous_leg_end = end_minute

          if leg.fetch("mode") == "rail"
            add(:error, "movement-rail-types-missing", "#{leg_path}/rail_types", "Rail legs must identify one or more configured transport classifications.") unless leg.key?("rail_types")
            Array(leg["rail_types"]).each do |classification|
              add(:error, "unknown-rail-classification", "#{leg_path}/rail_types", "Unknown transport classification #{classification.inspect}.") unless @store.site.dig("transport", "classifications").key?(classification)
            end
          elsif leg.key?("rail_types")
            add(:error, "movement-rail-types-mode", "#{leg_path}/rail_types", "Only rail legs may declare rail types.")
          end

          coordinates = leg.dig("geometry", "coordinates")
          Array(coordinates).each_with_index do |coordinate, coordinate_index|
            longitude, latitude = coordinate
            unless longitude.is_a?(Numeric) && latitude.is_a?(Numeric) && longitude.between?(-180, 180) && latitude.between?(-90, 90)
              add(:error, "movement-coordinate", "#{leg_path}/geometry/coordinates/#{coordinate_index}", "Expected [longitude, latitude] within geographic bounds.")
            end
          end

          if leg.fetch("status") == "unresolved"
            activity = day_activities[leg.fetch("activity_ref")]
            unless activity && !activity.fetch("optional") && activity.fetch("category") == "transport"
              add(:error, "unresolved-movement-activity", leg_path, "Unresolved transfer requires a default transport activity.")
            end
            if activity && (activity.dig("time", "start") != leg.fetch("start_time") || activity.dig("time", "end") != leg.fetch("end_time"))
              add(:error, "unresolved-movement-time", leg_path, "Allowance leg must exactly match its transport activity window.")
            end
            unless [from, to].compact.any? { |stop| stop["role"] == "lodging_base" }
              add(:error, "unresolved-movement-base", leg_path, "Unresolved transfers are allowed only when one endpoint is an unconfirmed lodging base.")
            end
            if end_minute - start_minute != leg.fetch("duration_minutes")
              add(:error, "unresolved-movement-duration", leg_path, "Allowance duration must match its timed window.")
            end
            add(:warning, "movement-route-unresolved", leg_path, "Hotel transfer uses a protected #{leg.fetch('duration_minutes')}-minute allowance; route and distance remain TBD.")
            next
          end

          next unless leg.fetch("mode") == "walk"

          add(:error, "walking-distance-missing", leg_path, "Walking legs require routed distance_meters.") unless leg["distance_meters"]
          unless leg.fetch("geometry_kind") == "routed" && leg.fetch("status") == "verified"
            add(:error, "walking-route-unverified", leg_path, "Walking metrics require verified routed geometry.")
          end
          add(:error, "walking-source-missing", leg_path, "Walking legs require a routing profile.") unless leg.dig("source", "profile")
        end
      end

      validate_movement_continuity(trip_days)

      @store.movement_alternatives.each_with_index do |alternative, alternative_index|
        path = "movements.yaml#alternatives/#{alternative_index}"
        add(:error, "movement-alternative-day", path, "Unknown itinerary day #{alternative.fetch('day')}.") unless trip_days.key?(alternative.fetch("day"))
        alternative.fetch("legs").each_with_index do |leg, leg_index|
          leg_path = "#{path}/legs/#{leg_index}"
          %w[from_place_id to_place_id].each do |field|
            place_id = leg.fetch(field)
            add(:error, "unknown-place", path, "Unknown alternative place #{place_id.inspect}.") unless places.key?(place_id)
          end
          if leg.fetch("mode") == "rail"
            add(:error, "movement-rail-types-missing", "#{leg_path}/rail_types", "Rail legs must identify one or more configured transport classifications.") unless leg.key?("rail_types")
            Array(leg["rail_types"]).each do |classification|
              add(:error, "unknown-rail-classification", "#{leg_path}/rail_types", "Unknown transport classification #{classification.inspect}.") unless @store.site.dig("transport", "classifications").key?(classification)
            end
          elsif leg.key?("rail_types")
            add(:error, "movement-rail-types-mode", "#{leg_path}/rail_types", "Only rail legs may declare rail types.")
          end
        end
      end

      validate_movement_transitions(trip_days, places)
    end

    def validate_movement_continuity(trip_days)
      movement_by_day = @store.movement_days.to_h { |day| [day.fetch("day"), day] }
      transitions_by_boundary = @store.movement_transitions.select { |transition| transition["before_day"] }
        .to_h { |transition| [[transition.fetch("after_day"), transition.fetch("before_day")], transition] }

      @store.movement_days.each_with_index do |movement_day, day_index|
        path = "movements.yaml#days/#{day_index}"
        stops = movement_day.fetch("stops")
        legs = movement_day.fetch("legs")
        stops.each_cons(2) do |from, to|
          matching = legs.select { |leg| leg.fetch("from_stop") == from.fetch("id") && leg.fetch("to_stop") == to.fetch("id") }
          if matching.empty?
            add(:error, "movement-continuity-gap", path, "No movement leg connects #{from.fetch('id')} to #{to.fetch('id')}.")
          elsif matching.length > 1
            add(:error, "movement-continuity-duplicate", path, "Multiple movement legs connect #{from.fetch('id')} to #{to.fetch('id')}.")
          else
            leg = matching.first
            if minutes(leg.fetch("start_time")) < minutes(from.fetch("end_time")) || minutes(leg.fetch("end_time")) > minutes(to.fetch("start_time"))
              add(:error, "movement-continuity-time", path, "#{leg.fetch('id')} overlaps its origin or destination stop.")
            end
          end
        end

        sleep_places = trip_days.fetch(movement_day.fetch("day")).fetch("sleep_base").filter_map { |token| token["place"] }.to_set
        next if sleep_places.empty?

        final_stop = stops.last
        unless final_stop["role"] == "lodging_base" && sleep_places.include?(final_stop.fetch("place_id"))
          add(:error, "movement-sleep-base", path, "Day must finish at a declared lodging base.")
        end
      end

      @store.movement_days.each_cons(2) do |from_day, to_day|
        from_stop = from_day.fetch("stops").last
        to_stop = to_day.fetch("stops").first
        same_base = from_stop["role"] == "lodging_base" && to_stop["role"] == "lodging_base" && from_stop.fetch("place_id") == to_stop.fetch("place_id")
        next if same_base
        next if transitions_by_boundary.key?([from_day.fetch("day"), to_day.fetch("day")])

        add(:error, "movement-day-boundary", "movements.yaml#days", "Unexplained jump from day #{from_day.fetch('day')} #{from_stop.fetch('place_id')} to day #{to_day.fetch('day')} #{to_stop.fetch('place_id')}.")
      end
    end

    def validate_movement_transitions(trip_days, places)
      seen_ids = Set.new
      @store.movement_transitions.each_with_index do |transition, index|
        path = "movements.yaml#transitions/#{index}"
        id = transition.fetch("id")
        if seen_ids.include?(id)
          add(:error, "duplicate-movement-transition", path, "Transition ID #{id.inspect} is duplicated.")
        else
          seen_ids << id
        end

        after_day = transition.fetch("after_day")
        before_day = transition["before_day"]
        add(:error, "movement-transition-day", path, "Unknown after_day #{after_day}.") unless trip_days.key?(after_day)
        add(:error, "movement-transition-day", path, "Unknown before_day #{before_day}.") if before_day && !trip_days.key?(before_day)
        if before_day && before_day != after_day + 1
          add(:error, "movement-transition-order", path, "before_day must immediately follow after_day.")
        end

        from_place = transition.fetch("from_place_id")
        to_place = transition.fetch("to_place_id")
        add(:error, "unknown-place", path, "Unknown transition origin #{from_place.inspect}.") unless places.key?(from_place)
        add(:error, "unknown-place", path, "Unknown transition destination #{to_place.inspect}.") unless places.key?(to_place)

        booking = @booking_by_id[transition.fetch("booking_ref")]
        unless booking && booking.fetch("kind") == "flight" && booking.fetch("status") == "confirmed"
          add(:error, "movement-transition-booking", path, "Flight transition requires a confirmed flight booking.")
        end

        from_day = @store.movement_days.find { |day| day.fetch("day") == after_day }
        if from_day && from_day.fetch("stops").last.fetch("place_id") != from_place
          add(:error, "movement-transition-origin", path, "Transition origin must match day #{after_day}'s final stop.")
        end
        if before_day
          to_day = @store.movement_days.find { |day| day.fetch("day") == before_day }
          if to_day && to_day.fetch("stops").first.fetch("place_id") != to_place
            add(:error, "movement-transition-destination", path, "Transition destination must match day #{before_day}'s first stop.")
          end
        end
      end
    end

    def validate_travel_buffers
      default_buffer = Integer(@store.preference_data.fetch("minimum_transfer_buffer_minutes"))
      booking_for_activity = @store.booking_list.select { |booking| booking["activity_id"] }.to_h { |booking| [booking["activity_id"], booking] }

      @store.days.each_with_index do |day, day_index|
        previous = nil
        day.fetch("activities").each_with_index do |activity, activity_index|
          if previous
            booking = booking_for_activity[activity.fetch("id")]
            required = activity["minimum_buffer_before_minutes"]
            required ||= default_buffer if booking && BOOKING_KINDS_REQUIRING_BUFFER.include?(booking.fetch("kind"))
            if required
              gap = gap_minutes(day, previous, activity)
              if gap && gap < required
                add(:warning, "missing-travel-buffer", "trip.yaml#days/#{day_index}/activities/#{activity_index}", "Only #{gap} minutes before #{activity['id']}; #{required} required for this timed transport or booking.")
              end
            end
          end
          previous = activity
        end
      end
    end

    def validate_opening_hours
      @store.days.each_with_index do |day, day_index|
        date = parse_date(day.fetch("date"), "trip.yaml#days/#{day_index}/date")
        next unless date

        day.fetch("activities").each_with_index do |activity, activity_index|
          activity.fetch("content").filter_map { |token| token["place"] }.uniq.each do |place_id|
            hours = @store.place_catalog.fetch(place_id)["opening_hours"]
            next unless hours
            path = "trip.yaml#days/#{day_index}/activities/#{activity_index}"
            unless hours.fetch("days", WEEKDAYS).include?(WEEKDAYS[date.wday])
              add(:warning, "opening-hours-risk", path, "#{place_id} is not marked open on #{WEEKDAYS[date.wday]}.")
            end
            start_time = activity.dig("time", "start")
            end_time = activity.dig("time", "end")
            if start_time && hours["opens"] && minutes(start_time) < minutes(hours["opens"])
              add(:warning, "opening-hours-risk", path, "#{place_id} starts before its recorded opening time #{hours['opens']}.")
            end
            if end_time && hours["closes"] && minutes(end_time) > minutes(hours["closes"])
              add(:warning, "opening-hours-risk", path, "#{place_id} ends after its recorded closing time #{hours['closes']}.")
            end
          end
        end
      end

      @store.constraint_list.select { |constraint| constraint["kind"] == "opening_hours" }.each do |constraint|
        constraint.fetch("activity_refs", []).each do |activity_id|
          activity = @activity_by_id.fetch(activity_id)
          places = activity.fetch("content").filter_map { |token| token["place"] }
          if places.none? { |place_id| @store.place_catalog.fetch(place_id)["opening_hours"] }
            add(:warning, "opening-hours-unverified", "constraints.yaml##{constraint['id']}", "Opening-hours constraint has no machine-readable hours; re-check before optimization.")
          end
        end
      end
    end

    def validate_pace_structure
      @store.days.each_with_index do |day, day_index|
        path = "trip.yaml#days/#{day_index}"
        activities = day.fetch("activities")
        default_clusters = []

        activities.each_with_index do |activity, activity_index|
          activity_path = "#{path}/activities/#{activity_index}"
          time = activity.fetch("time")
          if activity.fetch("optional")
            add(:warning, "optional-priority", activity_path, "Optional activity must also use priority: optional.") unless activity.fetch("priority") == "optional"
            if time["start"] || time["end"] || time.fetch("precision") != "label_only"
              add(:warning, "optional-timed", activity_path, "Optional alternatives must be untimed and use label_only precision.")
            end
          elsif activity.fetch("priority") == "optional"
            add(:warning, "optional-priority", activity_path, "priority: optional requires optional: true.")
          end

          if !activity.fetch("optional") && %w[major minor].include?(activity.fetch("pace_role"))
            if activity["cluster"]
              default_clusters << activity.fetch("cluster") unless default_clusters.last == activity.fetch("cluster")
            else
              add(:warning, "missing-pace-cluster", activity_path, "Default major/minor activity requires a geographic cluster.")
            end
          end
        end

        expected_clusters = default_clusters.uniq
        if day.dig("planning", "clusters") != expected_clusters
          add(:warning, "planning-cluster-mismatch", "#{path}/planning/clusters", "Expected ordered default clusters #{expected_clusters.inspect}.")
        end

        if day.fetch("day_type") == "transfer" && !day.dig("planning", "transfer")
          add(:warning, "missing-transfer-planning", "#{path}/planning", "Transfer day requires origin, destination, direct minutes, and direction.")
        end
        if (transfer = day.dig("planning", "transfer"))
          planned_transport = activities.reject { |activity| activity.fetch("optional") }
            .select { |activity| activity.fetch("category") == "transport" }
            .sum { |activity| PaceAnalyzer.duration(activity) }
          if planned_transport < transfer.fetch("direct_travel_minutes")
            add(:warning, "route-underestimated", "#{path}/planning/transfer", "Planned transport #{planned_transport} minutes is below the direct door-to-door baseline #{transfer.fetch('direct_travel_minutes')}.")
          end
        end

        clustered = activities.each_with_index.filter_map do |activity, index|
          next if activity.fetch("optional") || !%w[major minor].include?(activity.fetch("pace_role")) || !activity["cluster"]
          [index, activity]
        end
        clustered.each_cons(2) do |(left_index, left), (right_index, right)|
          next if left.fetch("cluster") == right.fetch("cluster")
          between = activities[(left_index + 1)...right_index]
          unless between.any? { |activity| !activity.fetch("optional") && activity.fetch("category") == "transport" }
            add(:warning, "missing-intercluster-transport", "#{path}/activities/#{right_index}", "No explicit transport block from #{left.fetch('cluster')} to #{right.fetch('cluster')}.")
          end
        end
      end
    end

    def validate_pace_analysis
      analyzer = PaceAnalyzer.new(@store)
      analyzer.day_metrics.each_with_index do |day, index|
        day.fetch("blocking_reasons").each do |reason|
          add(:warning, reason.fetch("code"), "trip.yaml#days/#{index}", reason.fetch("message"))
        end
      end
      analyzer.trip_metrics.fetch("blocking_reasons").each do |reason|
        add(:warning, reason.fetch("code"), "trip.yaml", reason.fetch("message"))
      end
    end

    def date_time(date, value)
      return nil unless value&.match?(TIME_PATTERN)
      hour, minute = value.split(":").map(&:to_i)
      DateTime.new(date.year, date.month, date.day, hour, minute, 0)
    end

    def minutes(value)
      hour, minute = value.split(":").map(&:to_i)
      hour * 60 + minute
    end

    def gap_minutes(day, previous, current)
      previous_end = previous.dig("time", "end") || previous.dig("time", "start")
      current_start = current.dig("time", "start")
      return nil unless previous_end && current_start
      date = Date.iso8601(day.fetch("date"))
      previous_at = date_time(date, previous_end)
      current_date = Date.iso8601(current.dig("time", "date") || day.fetch("date"))
      current_at = date_time(current_date, current_start)
      ((current_at - previous_at) * 24 * 60).to_i
    end
  end


  class Renderer
    def initialize(store)
      @store = store
      @places = store.place_catalog
      @mention_index = 0
      @pace_by_day = PaceAnalyzer.new(store).day_metrics.to_h { |day| [day.fetch("day"), day] }
      @meal_slot_by_activity = store.meal_option_days.flat_map { |day| day.fetch("slots") }.to_h { |slot| [slot.fetch("itinerary_activity_ref"), slot] }
    end

    def render
      template = @store.framework_root.join("src", "index.html.erb").read(encoding: "UTF-8")
      ERB.new(template, trim_mode: "-").result(binding)
    end

    private

    def h(value) = CGI.escapeHTML(value.to_s)
    def site = @store.site_metadata
    def trip = @store.trip_metadata
    def days = @store.days
    def preferences = @store.preference_data
    def flights = @store.booking_list.select { |booking| booking["kind"] == "flight" && booking["status"] == "confirmed" }
    def styles = @store.framework_root.join("src", "styles.css").read(encoding: "UTF-8")
    def script = @store.framework_root.join("src", "app.js").read(encoding: "UTF-8")
    def page_metadata = site.dig("metadata", "pages", "itinerary")
    def social_image_url
      image = site.dig("metadata", "social_image")
      base = site.dig("metadata", "site_url")
      base && image ? "#{base.sub(%r{/\z}, '')}/#{image.sub(%r{\Apublic/}, '')}" : image
    end
    def default_activities(day) = day.fetch("activities").reject { |activity| activity.fetch("optional") }
    def optional_activities(day) = day.fetch("activities").select { |activity| activity.fetch("optional") }
    def pace_for(day) = @pace_by_day.fetch(day.fetch("number"))
    def meal_slot_for(activity) = @meal_slot_by_activity[activity.fetch("id")]
    def meal_venue(option) = @places.fetch(option.fetch("place_id"))

    def canonical_meal_place_id(slot)
      activity = @store.activities.find { |candidate| candidate.fetch("id") == slot.fetch("itinerary_activity_ref") }
      place_ids = activity.fetch("content").filter_map { |token| token["place"] }
      (place_ids & slot.fetch("options").map { |option| option.fetch("place_id") }).first
    end

    def meal_panel_label(slot)
      return "Confirmed meal" if slot.fetch("status") == "fixed"
      canonical_meal_place_id(slot) ? "Planned venue + 2 backups" : "3 nearby options"
    end

    def meal_map_url(place)
      coordinates = place.fetch("coordinates")
      latitude = coordinates.fetch("latitude")
      longitude = coordinates.fetch("longitude")
      "https://www.openstreetmap.org/?mlat=#{latitude}&mlon=#{longitude}#map=19/#{latitude}/#{longitude}"
    end
    def meal_source_url(option)
      evidence = option.fetch("evidence")
      preferred = evidence.find { |source| source.fetch("kind").start_with?("official-") && source.fetch("status") == "verified" }
      (preferred || evidence.first).fetch("url")
    end

    def meal_order_summary(option)
      option.dig("order_for_two", "items").map do |item|
        suffix = item.fetch("sharing") == "shared" ? " to share" : ""
        price = item["unit_price"]
        price_suffix = if price
          amount = price.fetch("amount")
          " (#{format_currency(amount, price.fetch('currency'), compact: true)})"
        else
          ""
        end
        "#{item.fetch('quantity')}× #{item.fetch('name')}#{price_suffix}#{suffix}"
      end.join(" · ")
    end

    def meal_spend_summary(option)
      spend = option.dig("order_for_two", "estimated_total_spend")
      exchange = @store.meal_options.fetch("exchange_rate")
      base_currency = exchange.fetch("base_currency")
      quote_currency = exchange.fetch("quote_currency")
      rate = exchange.fetch("quote_per_base_rate").to_f
      if spend.fetch("currency") == quote_currency
        quote_amount = spend.fetch("amount")
        base_amount = quote_amount / rate
      else
        base_amount = spend.fetch("amount")
        quote_amount = (base_amount * rate).round
      end
      "Est. #{format_currency(quote_amount, quote_currency)} · #{format_currency(base_amount, base_currency)} total"
    end

    def format_currency(amount, currency, compact: false)
      display = site.dig("currencies", "display", currency)
      decimals = compact && amount.to_f == amount.to_i ? 0 : display.fetch("decimals")
      formatted = format("%.#{decimals}f", amount)
      integer, fraction = formatted.split(".", 2)
      integer = integer.reverse.scan(/.{1,3}/).join(",").reverse unless compact
      formatted = fraction ? "#{integer}.#{fraction}" : integer
      display.fetch("symbol_position") == "after" ? "#{formatted}#{display.fetch('symbol')}" : "#{display.fetch('symbol')}#{formatted}"
    end

    def meal_evidence_status(option)
      statuses = [option.dig("route_fit", "status"), option.dig("order_for_two", "estimated_total_spend", "status")] + option.fetch("evidence").map { |evidence| evidence.fetch("status") }
      statuses.include?("provisional") ? "Provisional — re-check" : "Verified sources"
    end

    def format_minutes(value)
      hours, minutes = value.divmod(60)
      return "#{minutes}m" if hours.zero?
      minutes.zero? ? "#{hours}h" : "#{hours}h #{minutes}m"
    end

    def render_route_place(place_id)
      place = @places.fetch(place_id)
      link(place, place.fetch("name")) + descriptor(place, visible_parentheses: true)
    end

    def render_rail_badge(activity)
      rail_types = activity.fetch("rail_types", [])
      return "" if rail_types.empty?

      symbols, labels = rail_types.map do |rail_type|
        presentation = site.dig("transport", "classifications").fetch(rail_type)
        [presentation.fetch("icon"), presentation.fetch("label")]
      end.transpose
      label = labels.join(" then ")
      %(<span class="rail-symbols" role="img" aria-label="#{h(label)}" title="#{h(label)}">#{symbols.join(" ")}</span>)
    end

    def render_content(tokens, interactive_descriptions: true)
      tokens.map do |token|
        next h(token["text"]) if token.key?("text")

        place = @places.fetch(token.fetch("place"))
        label = token.fetch("label", place.fetch("name"))
        next link(place, label) + descriptor(place, visible_parentheses: true) unless interactive_descriptions

        @mention_index += 1
        tooltip_id = "place-note-#{@mention_index}"
        button = %(<button class="info-button" type="button" aria-label="About #{h(label)}" aria-expanded="false" aria-controls="#{tooltip_id}"><i class="fa-solid fa-circle-info" aria-hidden="true"></i></button>)
        trigger = %(<span class="place-note-trigger">#{link(place, label)}#{button}</span>)
        trigger + %(<span class="descriptor" id="#{tooltip_id}" role="tooltip">(#{h(place.fetch('description'))})</span>)
      end.join
    end

    def link(place, label)
      %(<a class="place-link" href="#{h(place.fetch('url'))}" rel="noopener noreferrer" target="_blank">#{h(label)}</a>)
    end

    def descriptor(place, visible_parentheses:)
      text = visible_parentheses ? "(#{place.fetch('description')})" : place.fetch("description")
      %(<span class="descriptor">#{h(text)}</span>)
    end

    def activity_classes(activity)
      (["timeline-item"] + activity.fetch("tags")).uniq.select { |name| name.match?(/\A[a-z0-9-]+\z/) }.join(" ")
    end

    def machine_time(day, activity)
      time = activity.fetch("time")
      clock = time["start"] || time["end"]
      [time.fetch("date", day.fetch("date")), clock].compact.join("T")
    end
  end

  class ActivityOptionsRenderer
    def initialize(store)
      @store = store
      @places = store.place_catalog
      @occurrences = Hash.new { |hash, key| hash[key] = [] }
      store.days.each do |day|
        day.fetch("activities").each do |activity|
          activity.fetch("content").filter_map { |token| token["place"] }.uniq.each do |place_id|
            @occurrences[place_id] << { "day" => day, "activity" => activity }
          end
        end
      end
    end

    def render
      template = @store.framework_root.join("src", "activity-options.html.erb").read(encoding: "UTF-8")
      ERB.new(template, trim_mode: "-").result(binding)
    end

    private

    def h(value) = CGI.escapeHTML(value.to_s)
    def site = @store.site_metadata
    def trip = @store.trip_metadata
    def destinations = @store.activity_option_destinations
    def image_sources = @store.activity_options.fetch("image_sources")
    def relaxed_visit(place_id) = @store.activity_options.fetch("relaxed_visits").fetch(place_id)
    def styles = @store.framework_root.join("src", "activity-options.css").read(encoding: "UTF-8")
    def script = @store.framework_root.join("src", "activity-options.js").read(encoding: "UTF-8")
    def page_metadata = site.dig("metadata", "pages", "activities")
    def social_image_url
      image = site.dig("metadata", "social_image")
      base = site.dig("metadata", "site_url")
      base && image ? "#{base.sub(%r{/\z}, '')}/#{image.sub(%r{\Apublic/}, '')}" : image
    end
    def chooser_config_json
      JSON.generate(
        "storage_key" => "#{site.fetch('storage_namespace')}-activity-draft-v1",
        "export_title" => site.dig("branding", "chooser_export_title"),
        "export_filename" => site.dig("branding", "chooser_export_filename")
      ).gsub("<", "\\u003c")
    end
    def place(place_id) = @places.fetch(place_id)
    def occurrences(place_id) = @occurrences.fetch(place_id, [])
    def selected_occurrences(place_id) = occurrences(place_id).reject { |entry| entry.fetch("activity").fetch("optional") }
    def alternative_occurrences(place_id) = occurrences(place_id).select { |entry| entry.fetch("activity").fetch("optional") }
    def selected?(place_id) = selected_occurrences(place_id).any?

    def option_state(place_id)
      return "selected" if selected?(place_id)
      return "alternative" if alternative_occurrences(place_id).any?

      "unscheduled"
    end

    def option_count = destinations.sum { |destination| destination.fetch("options").length }
    def selected_count = destinations.sum { |destination| destination.fetch("options").count { |option| selected?(option.fetch("place_id")) } }

    def schedule_notes(place_id)
      selected = selected_occurrences(place_id)
      entries = selected.any? ? selected : alternative_occurrences(place_id)
      entries.map do |entry|
        day = entry.fetch("day")
        activity = entry.fetch("activity")
        prefix = activity.fetch("optional") ? "Existing alternative" : "Currently scheduled"
        "#{prefix} · Day #{day.fetch('number')}, #{day.fetch('label')} · #{activity.dig('time', 'label')}"
      end
    end

    def google_url(place_id, destination_place_id)
      query = "#{place(place_id).fetch('name')} #{place(destination_place_id).fetch('name')} #{site.dig('destination', 'search_hint')}"
      "https://www.google.com/search?q=#{URI.encode_www_form_component(query)}"
    end

    def category_label(value)
      value.split("-").map(&:capitalize).join(" ")
    end

    def option_image(destination, option)
      image_id = option.fetch("image_id", destination.fetch("fallback_image_id"))
      path = Dir[@store.root.join("assets", "activity-options", "#{image_id}.{jpg,jpeg,png,webp,svg}")].sort.first
      {
        "path" => Pathname(path).relative_path_from(@store.root).to_s,
        "alt" => "#{place(option.fetch('place_id')).fetch('name')} in #{place(destination.fetch('place_id')).fetch('name')}",
        "source_url" => image_sources.fetch(image_id)
      }
    end
  end


  class JourneyMapRenderer
    def initialize(store, location_overrides: {}, private_output: false)
      @store = store
      @places = store.place_catalog
      @location_overrides = location_overrides
      @private_output = private_output
      @pace_by_day = PaceAnalyzer.new(store).day_metrics.to_h { |day| [day.fetch("day"), day] }
      @meal_slot_by_activity = store.meal_option_days.flat_map { |day| day.fetch("slots") }.to_h { |slot| [slot.fetch("itinerary_activity_ref"), slot] }
    end

    def render
      template = @store.framework_root.join("src", "journey-map.html.erb").read(encoding: "UTF-8")
      ERB.new(template, trim_mode: "-").result(binding)
    end

    private

    def h(value) = CGI.escapeHTML(value.to_s)
    def site = @store.site_metadata
    def trip = @store.trip_metadata
    def days = @store.days
    def styles = @store.framework_root.join("src", "journey-map.css").read(encoding: "UTF-8")
    def script = @store.framework_root.join("src", "journey-map.js").read(encoding: "UTF-8")
    def page_metadata = site.dig("metadata", "pages", "map")
    def social_image_url
      image = site.dig("metadata", "social_image")
      base = site.dig("metadata", "site_url")
      base && image ? "#{base.sub(%r{/\z}, '')}/#{image.sub(%r{\Apublic/}, '')}" : image
    end
    def initial_place_name
      place_id = site.dig("map", "initial_place_id") || @store.movement_days.first.fetch("stops").first.fetch("place_id")
      @places.fetch(place_id).fetch("name")
    end

    def map_json
      JSON.generate(map_payload).gsub("<", "\\u003c")
    end

    def map_payload
      trip_days = @store.days.to_h { |day| [day.fetch("number"), day] }
      alternatives_by_day = @store.movement_alternatives.group_by { |alternative| alternative.fetch("day") }
      {
        "trip" => {
          "title" => trip.fetch("title"),
          "subtitle" => trip.fetch("subtitle"),
          "start_date" => trip.fetch("start_date"),
          "end_date" => trip.fetch("end_date"),
          "private" => @private_output,
          "transport" => site.fetch("transport"),
          "map" => site.fetch("map")
        },
        "days" => @store.movement_days.map do |movement_day|
          day_number = movement_day.fetch("day")
          trip_day = trip_days.fetch(day_number)
          legs = movement_day.fetch("legs")
          stops = movement_day.fetch("stops").map { |stop| enrich_stop(stop) }
          walking = legs.select { |leg| leg.fetch("mode") == "walk" && leg.fetch("geometry_kind") == "routed" && leg.fetch("status") == "verified" }
          movement_day.merge(
            "date" => trip_day.fetch("date"),
            "label" => trip_day.fetch("label"),
            "day_type" => trip_day.fetch("day_type"),
            "pace" => @pace_by_day.fetch(day_number).fetch("classification"),
            "walking_distance_meters" => walking.sum { |leg| leg.fetch("distance_meters") },
            "walking_duration_minutes" => walking.sum { |leg| leg.fetch("duration_minutes") },
            "stops" => stops,
            "events" => itinerary_events(trip_day, stops, legs),
            "window_start" => journey_window_start(trip_day, movement_day),
            "window_end" => journey_window_end(trip_day, movement_day),
            "alternatives" => Array(alternatives_by_day[day_number]).map { |alternative| enrich_alternative(alternative) }
          )
        end,
        "transitions" => @store.movement_transitions.map { |transition| enrich_transition(transition) },
        "fallback_geography" => fallback_geography,
        "fallback_extent" => fallback_extent
      }
    end

    def fallback_geography
      relative = site.dig("map", "fallback_geography")
      return unless relative

      JSON.parse(@store.root.join(relative).read(encoding: "UTF-8"))
    rescue Errno::ENOENT, JSON::ParserError => error
      raise ArgumentError, "Cannot load configured fallback geography #{relative.inspect}: #{error.message}"
    end

    def fallback_extent
      coordinates = @store.place_catalog.values.filter_map { |place| place["coordinates"] }
      longitudes = coordinates.map { |value| value.fetch("longitude") }
      latitudes = coordinates.map { |value| value.fetch("latitude") }
      return nil if longitudes.empty?

      longitude_padding = [(longitudes.max - longitudes.min) * 0.08, 0.1].max
      latitude_padding = [(latitudes.max - latitudes.min) * 0.08, 0.1].max
      [longitudes.min - longitude_padding, latitudes.min - latitude_padding,
       longitudes.max + longitude_padding, latitudes.max + latitude_padding]
    end

    def enrich_stop(stop)
      place_id = stop.fetch("place_id")
      place = @places.fetch(place_id)
      stop.merge(
        "place" => {
          "id" => place_id,
          "name" => place.fetch("name"),
          "coordinates" => coordinates_for(place_id),
          "private_override" => @location_overrides.key?(place_id)
        }
      )
    end

    def itinerary_events(day, stops, legs)
      stops_by_id = stops.to_h { |stop| [stop.fetch("id"), stop] }
      day.fetch("activities").reject { |activity| activity.fetch("optional") }.map do |activity|
        time = activity.fetch("time")
        matching_leg = legs.find do |leg|
          time["start"] == leg.fetch("start_time") && time["end"] == leg.fetch("end_time")
        end
        activity_stops = stops.select { |stop| stop.fetch("activity_refs").include?(activity.fetch("id")) }
        stop_places = activity_stops
          .map { |stop| stop.fetch("place").slice("id", "name", "coordinates") }
          .uniq { |place| place.fetch("id") }
        place_ids = activity.fetch("content").filter_map { |token| token["place"] }.uniq
        content_places = place_ids.filter_map do |place_id|
          place = @places.fetch(place_id)
          next unless place["coordinates"]

          {
            "id" => place_id,
            "name" => place.fetch("name"),
            "coordinates" => coordinates_for(place_id)
          }
        end
        venue = meal_venue(activity, place_ids)
        # Logistics prose can name a parcel's destination even though the travelers
        # remain at the stop where they hand it over. Map the performed task, not
        # every place referenced in its instructions.
        mapped_places = activity.fetch("category") == "logistics" && !stop_places.empty? ? stop_places : content_places
        mapped_places = stop_places if mapped_places.empty?
        if activity.fetch("category") == "transport" && matching_leg
          leg_places = %w[from_stop to_stop].map { |field| stops_by_id.fetch(matching_leg.fetch(field)).fetch("place").slice("id", "name", "coordinates") }
          mapped_places = (leg_places + mapped_places).uniq { |place| place.fetch("id") }
        end

        event = {
          "id" => activity.fetch("id"),
          "time_label" => time.fetch("label"),
          "start_time" => time["start"],
          "end_time" => time["end"],
          "date" => time["date"],
          "same_day" => !time["date"] || time.fetch("date") == day.fetch("date"),
          "category" => activity.fetch("category"),
          "in_transit" => activity.fetch("category") == "transport",
          "pace_role" => activity.fetch("pace_role"),
          "title" => event_title(activity, place_ids, matching_leg, stops_by_id, venue),
          "places" => mapped_places
        }
        event["meal_type"] = activity.fetch("meal_type") if activity.fetch("category") == "meal"
        event["venue"] = venue if venue
        event["meal_options"] = meal_options_for(activity, venue) if activity.fetch("category") == "meal"
        event
      end
    end

    def meal_options_for(activity, venue)
      slot = @meal_slot_by_activity.fetch(activity.fetch("id"))
      slot.fetch("options").sort_by { |option| option.fetch("rank") }.map do |option|
        place_id = option.fetch("place_id")
        place = @places.fetch(place_id)
        statuses = [place.dig("coordinates", "status"), option.dig("route_fit", "status")] + option.fetch("evidence").map { |entry| entry.fetch("status") }
        {
          "rank" => option.fetch("rank"),
          "role" => if option.fetch("rank") == 1
            venue&.fetch("id") == place_id ? "planned" : "recommended"
          else
            "alternative"
          end,
          "walking_minutes" => option.dig("route_fit", "walking_minutes"),
          "order_summary" => option.dig("order_for_two", "items").map { |item| "#{item.fetch('quantity')}× #{item.fetch('name')}#{item.fetch('sharing') == 'shared' ? ' to share' : ''}" }.join(" · "),
          "evidence_status" => statuses.include?("provisional") ? "provisional" : "verified",
          "place" => {
            "id" => place_id,
            "name" => place.fetch("name"),
            "url" => place.fetch("url"),
            "coordinates" => coordinates_for(place_id)
          }
        }
      end
    end

    def meal_venue(activity, place_ids)
      return unless activity.fetch("category") == "meal"

      place_id = place_ids.find do |candidate|
        place = @places.fetch(candidate)
        coordinates = place["coordinates"]
        place.fetch("kind") == "restaurant" && coordinates &&
          coordinates.fetch("status") == "verified" && %w[exact entrance].include?(coordinates.fetch("precision"))
      end
      return unless place_id

      place = @places.fetch(place_id)
      {
        "id" => place_id,
        "name" => place.fetch("name"),
        "coordinates" => coordinates_for(place_id)
      }
    end

    def event_title(activity, place_ids, matching_leg, stops_by_id, venue = nil)
      return activity.fetch("title") if activity["title"]

      names = place_ids.map { |place_id| @places.fetch(place_id).fetch("name") }.uniq
      text = activity.fetch("content").filter_map { |token| token["text"] }.join(" ").gsub(/\s+/, " ").strip

      case activity.fetch("category")
      when "transport"
        if matching_leg
          from = stops_by_id.fetch(matching_leg.fetch("from_stop")).dig("place", "name")
          to = stops_by_id.fetch(matching_leg.fetch("to_stop")).dig("place", "name")
          return "#{from} → #{to}"
        end
        return "#{names.first} → #{names.last}" if names.length >= 2
        return "Travel · #{names.first}" if names.length == 1
        "Travel"
      when "meal"
        meal = activity.fetch("meal_type").capitalize
        venue_name = venue&.fetch("name")
        names.empty? && !venue_name ? meal : "#{meal} · #{venue_name || names.first}"
      when "logistics"
        activity.fetch("title")
      else
        names.empty? ? activity.fetch("category").capitalize : names.first(3).join(" + ")
      end
    end

    def journey_window_start(day, movement_day)
      event_times_for_day(day).min || movement_day.fetch("window_start")
    end

    def journey_window_end(day, movement_day)
      event_times_for_day(day).max || movement_day.fetch("window_end")
    end

    def event_times_for_day(day)
      day.fetch("activities").reject { |activity| activity.fetch("optional") }.flat_map do |activity|
        time = activity.fetch("time")
        next [] if time["date"] && time.fetch("date") != day.fetch("date")

        [time["start"], time["end"]].compact
      end
    end

    def enrich_alternative(alternative)
      alternative.merge(
        "legs" => alternative.fetch("legs").map do |leg|
          leg.merge(
            "from_place" => alternative_place(leg.fetch("from_place_id")),
            "to_place" => alternative_place(leg.fetch("to_place_id"))
          )
        end
      )
    end

    def enrich_transition(transition)
      booking = @store.booking_list.find { |candidate| candidate.fetch("id") == transition.fetch("booking_ref") }
      transition.merge(
        "from_place" => alternative_place(transition.fetch("from_place_id")),
        "to_place" => alternative_place(transition.fetch("to_place_id")),
        "booking" => booking.slice("id", "departure_date", "arrival_date", "departure_time", "arrival_time", "date_label", "description")
      )
    end

    def alternative_place(place_id)
      place = @places.fetch(place_id)
      { "id" => place_id, "name" => place.fetch("name"), "coordinates" => coordinates_for(place_id) }
    end

    def coordinates_for(place_id)
      public_coordinates = @places.fetch(place_id).fetch("coordinates")
      override = @location_overrides[place_id]
      override ? public_coordinates.merge(override).merge("precision" => "exact", "status" => "verified") : public_coordinates
    end

  end
end
