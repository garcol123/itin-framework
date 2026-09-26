# frozen_string_literal: true

require "digest"
require "fileutils"
require "minitest/autorun"
require "rexml/document"
require "rexml/xpath"
require "tmpdir"
require "yaml"
require_relative "../lib/itinerary"

class JapanCompatibilityTest < Minitest::Test
  FRAMEWORK_ROOT = File.expand_path("..", __dir__)
  TRIP_ROOT = File.join(FRAMEWORK_ROOT, "examples", "japan")

  def setup
    @store = Itinerary::DataStore.new(TRIP_ROOT, framework_root: FRAMEWORK_ROOT)
    @issues = Itinerary::Validator.new(@store).validate
  end

  def test_canonical_data_has_no_validation_errors
    assert_empty @issues.select { |issue| issue.severity == :error }
  end

  def test_current_risks_are_reported
    codes = @issues.map(&:code)
    refute_includes codes, "missing-travel-buffer"
    assert_includes codes, "opening-hours-unverified"
    refute_includes codes, "movement-route-unresolved"
    strict = Itinerary::Validator.new(@store).tap(&:validate).strict_blockers
    assert_equal %w[
      pace-active-span pace-commitment pace-transport pace-major-anchors pace-clusters pace-too-many-amber
    ], strict.map(&:code)
  end

  def test_user_directed_route_uses_confirmed_hotels_and_combined_nara_uji_day
    nights = @store.days.filter_map do |day|
      day.fetch("sleep_base", []).find { |fragment| fragment.key?("place") }&.fetch("place")
    end.tally
    assert_equal({ "tokyo" => 3, "kanazawa" => 2, "yamanaka-onsen" => 1, "kyoto" => 4, "osaka" => 3 }, nights)

    active = YAML.dump(
      "trip" => @store.trip,
      "places" => @store.places,
      "bookings" => @store.bookings,
      "constraints" => @store.constraints,
      "movements" => @store.movements
    ).downcase
    refute_match(/hiroshima|miyajima|peace memorial/, active)
    refute_match(/\b(?:okuhida|hirayu|fukuji|takayama|shirakawa-go|wada house|sanmachi|hida beef|nagoya)\b/, active)

    stay = @store.booking_list.find { |booking| booking.fetch("id") == "kagari-kisshotei-stay" }
    assert_equal "confirmed", stay.fetch("status")
    assert_equal "Thu 29 → Fri 30 Oct 2026", stay.fetch("date_label")
    assert_match(/hoshi/i, stay.fetch("instructions"))
    assert_equal "kagari-kisshotei-ryokan", stay.fetch("place_id")
    assert_equal "hotel", @store.place_catalog.fetch(stay.fetch("place_id")).fetch("kind")
    assert_equal "restaurant", @store.place_catalog.fetch("kagari-kisshotei").fetch("kind")

    confirmed_stays = {
      "sotetsu-fresa-inn-ginza-nanachome-stay" => ["sotetsu-fresa-inn-ginza-nanachome", "Sat 24 → Tue 27 Oct 2026"],
      "hotel-amanek-kanazawa-stay" => ["hotel-amanek-kanazawa", "Tue 27 → Thu 29 Oct 2026"],
      "kagari-kisshotei-stay" => ["kagari-kisshotei-ryokan", "Thu 29 → Fri 30 Oct 2026"],
      "sotetsu-fresa-inn-kyoto-kiyomizu-gojo-stay" => ["sotetsu-fresa-inn-kyoto-kiyomizu-gojo", "Fri 30 Oct → Tue 3 Nov 2026"],
      "sotetsu-fresa-inn-osaka-namba-stay" => ["sotetsu-fresa-inn-osaka-namba", "Tue 3 → Fri 6 Nov 2026"]
    }
    confirmed_stays.each do |booking_id, (place_id, date_label)|
      booking = @store.booking_list.find { |candidate| candidate.fetch("id") == booking_id }
      assert_equal ["confirmed", place_id, date_label], booking.values_at("status", "place_id", "date_label")
      assert_equal "hotel", @store.place_catalog.fetch(place_id).fetch("kind")
    end
    refute @store.place_catalog.key?("stay-sakura-kyoto-station-shichijo")
    assert_match(/Breakfast is not included/, @store.booking_list.find { |booking| booking.fetch("id") == "sotetsu-fresa-inn-kyoto-kiyomizu-gojo-stay" }.fetch("instructions"))

    analyzer = Itinerary::PaceAnalyzer.new(@store)
    day_7 = analyzer.day_metrics.find { |metric| metric.fetch("day") == 7 }
    day_8 = analyzer.day_metrics.find { |metric| metric.fetch("day") == 8 }
    day_9 = analyzer.day_metrics.find { |metric| metric.fetch("day") == 9 }
    assert_equal ["AMBER", 109], day_7.values_at("classification", "transport_minutes")
    assert_equal ["GREEN", 175], day_8.values_at("classification", "transport_minutes")
    assert_equal ["RED", 195], day_9.values_at("classification", "transport_minutes")

    combined_day = @store.days.find { |day| day.fetch("number") == 9 }
    osaka_transfer_day = @store.days.find { |day| day.fetch("number") == 12 }
    %w[todai-ji byodoin fushimi-inari].each do |place_id|
      assert combined_day.fetch("activities").any? { |activity| !activity.fetch("optional") && activity.fetch("content").any? { |token| token["place"] == place_id } }
    end
    refute osaka_transfer_day.fetch("activities").any? { |activity| activity.fetch("content").any? { |token| %w[nara uji].include?(token["place"]) } }
    shopping = combined_day.fetch("activities").find { |activity| activity.fetch("id") == "day-09-matcha-shopping" }
    assert_equal ["14:45", "16:45", 120], shopping.fetch("time").values_at("start", "end") + [Itinerary::PaceAnalyzer.duration(shopping)]
    assert_includes shopping.fetch("content").filter_map { |token| token["place"] }, "fukujuen-uji-kobo"
    fushimi = combined_day.fetch("activities").find { |activity| activity.fetch("id") == "day-09-fushimi" }
    assert_equal [false, "scheduled"], [fushimi.fetch("optional"), fushimi.dig("time", "precision")]
    assert_includes fushimi.fetch("constraint_refs"), "fushimi-lower-gates-only"

    default_places = @store.days.flat_map { |day| day.fetch("activities") }
      .reject { |activity| activity.fetch("optional") }
      .flat_map { |activity| activity.fetch("content").filter_map { |token| token["place"] } }
    %w[meiji-shrine harajuku shibuya yonex-tokyo-showroom fushimi-inari].each do |place_id|
      assert_includes default_places, place_id
    end
    kaiyukan = @store.days.find { |day| day.fetch("number") == 14 }.fetch("activities")
      .find { |activity| activity.fetch("id") == "day-14-kaiyukan-alternative" }
    assert_equal [true, "label_only", 300], [kaiyukan.fetch("optional"), kaiyukan.dig("time", "precision"), kaiyukan.dig("time", "estimated_duration_minutes")]

    transfer = osaka_transfer_day.dig("planning", "transfer")
    assert_equal({ "origin" => "kyoto", "destination" => "osaka", "direct_travel_minutes" => 90, "direction" => "direct" }, transfer)
    refute @store.days.find { |day| day.fetch("number") == 13 }.dig("planning").key?("transfer")
    day = Itinerary::PaceAnalyzer.new(@store).day_metrics.find { |metric| metric.fetch("day") == 13 }
    assert_equal ["AMBER", 180, nil], day.values_at("classification", "transport_minutes", "incremental_travel_minutes")

    luggage = @store.constraint_list.find { |constraint| constraint.fetch("id") == "forward-luggage-to-osaka" }
    assert_equal %w[day-10-05-luggage day-12-osaka-checkin], luggage.fetch("activity_refs")
    assert_match(/two-night essentials bag/, luggage.fetch("description"))
  end

  def test_pace_analyzer_uses_exact_relaxed_span_boundaries
    current = Itinerary::PaceAnalyzer.new(@store).day_metrics.find { |day| day.fetch("day") == 14 }
    assert_equal 600, current.fetch("active_span_minutes")
    assert_equal "GREEN", current.fetch("classification")

    analyzer = analyze_mutation("trip.yaml") do |document|
      activity = document.fetch("days")[13].fetch("activities").find { |candidate| candidate.fetch("id") == "day-14-02" }
      activity.fetch("time")["start"] = "09:59"
    end
    day = analyzer.day_metrics.find { |metric| metric.fetch("day") == 14 }
    assert_equal 601, day.fetch("active_span_minutes")
    assert_equal "AMBER", day.fetch("classification")
  end

  def test_optional_alternatives_are_excluded_from_default_metrics
    day = Itinerary::PaceAnalyzer.new(@store).day_metrics.find { |metric| metric.fetch("day") == 14 }
    assert_equal 10, day.fetch("default_activity_count")
    assert_equal 2, day.fetch("optional_activity_count")
    assert_equal 390, day.fetch("optional_estimated_minutes")
    assert_equal 590, day.fetch("scheduled_default_minutes")
  end

  def test_validator_rejects_a_timed_optional_alternative
    issues = validate_mutation("trip.yaml") do |document|
      time = document.fetch("days")[13].fetch("activities")[0].fetch("time")
      time["precision"] = "scheduled"
      time["start"] = "09:00"
      time["end"] = "10:30"
    end
    assert_includes issues.map(&:code), "optional-timed"
  end

  def test_validator_requires_explicit_intercluster_transport
    issues = validate_mutation("trip.yaml") do |document|
      day = document.fetch("days")[13]
      day.fetch("planning")["clusters"] = %w[horie-shinsaibashi minamisenba]
      activity = day.fetch("activities").find { |candidate| candidate.fetch("id") == "day-14-03" }
      activity["cluster"] = "minamisenba"
    end
    assert_includes issues.map(&:code), "missing-intercluster-transport"
  end

  def test_reverse_transfer_over_threshold_is_a_strict_blocker
    issues = validate_mutation("trip.yaml") do |document|
      transfer = document.fetch("days")[4].fetch("planning").fetch("transfer")
      transfer["direction"] = "reverse"
      transfer["direct_travel_minutes"] = 100
    end
    assert_includes issues.map(&:code), "route-reverse-detour"
  end

  def test_long_transfer_exception_requires_no_anchor_and_recovery
    analyzer = analyze_mutation("trip.yaml") do |document|
      day = document.fetch("days")[7]
      day.fetch("activities").each { |activity| activity["pace_role"] = "minor" if activity["pace_role"] == "major" }
      dinner = day.fetch("activities").last
      dinner["pace_role"] = "recovery"
    end
    day = analyzer.day_metrics.find { |metric| metric.fetch("day") == 8 }
    refute_includes day.fetch("blocking_reasons").map { |reason| reason.fetch("code") }, "pace-transfer-load"
  end

  def test_trip_analyzer_detects_consecutive_amber_days
    analyzer = analyze_mutation("trip.yaml") do |document|
      document.fetch("days")[3].fetch("activities").last.fetch("time")["end"] = "18:15"
    end
    assert_includes analyzer.trip_metrics.fetch("blocking_reasons").map { |reason| reason.fetch("code") }, "pace-consecutive-amber"
  end

  def test_trip_analyzer_detects_one_night_base_friction
    analyzer = analyze_mutation("trip.yaml") do |document|
      day = document.fetch("days")[2]
      day["sleep_base"] = [{ "place" => "kanazawa", "label" => "Kanazawa" }]
      day.fetch("activities").first.fetch("time")["start"] = "06:00"
      day.fetch("activities").last.fetch("time")["end"] = "22:00"
      next_day = document.fetch("days")[3]
      next_day.fetch("activities").first.fetch("time")["start"] = "06:00"
      next_day.fetch("activities").last.fetch("time")["end"] = "22:00"
    end
    assert_includes analyzer.trip_metrics.fetch("blocking_reasons").map { |reason| reason.fetch("code") }, "base-one-night-friction"
  end

  def test_generated_html_is_current_and_preserves_visible_content
    rendered = Itinerary::Renderer.new(@store).render
    assert_equal rendered, File.read(File.join(TRIP_ROOT, "index.html"), encoding: "UTF-8")

    document = REXML::Document.new(rendered)
    main = REXML::XPath.first(document, "//main")
    visible = REXML::XPath.match(main, ".//text()").map(&:value).join(" ").gsub(/\s+/, " ").strip
    expected = File.read(File.join(FRAMEWORK_ROOT, "test", "fixtures", "itinerary_visible.sha256")).strip
    assert_equal expected, Digest::SHA256.hexdigest(visible)
  end

  def test_removed_chooser_pages_are_not_built_or_linked
    %w[meal-options.html hotel-options.html].each do |filename|
      refute File.exist?(File.join(TRIP_ROOT, filename))
    end

    %w[index.html journey-map.html activity-options.html].each do |filename|
      rendered = File.read(File.join(TRIP_ROOT, filename), encoding: "UTF-8")
      refute_match(/(?:meal|hotel)-options\.html/, rendered)
    end

    build = File.read(File.join(FRAMEWORK_ROOT, "bin", "build"), encoding: "UTF-8")
    assert_equal %w[index.html journey-map.html activity-options.html].sort,
      build.scan(/"([a-z-]+\.html)" =>/).flatten.sort
  end

  def test_inline_meal_shortlists_cover_every_meal
    slots = @store.meal_option_days.flat_map { |day| day.fetch("slots") }
    assert_equal 41, slots.length
    assert_equal({ 3 => 39, 1 => 2 }, slots.group_by { |slot| slot.fetch("options").length }.transform_values(&:length))
    protected = %w[day-03-lunch day-03-dinner day-07-dinner day-08-breakfast day-14-dinner]
    generic = slots.reject { |slot| protected.include?(slot.fetch("id")) }
    assert_equal 36, generic.length
    assert_equal 108, generic.sum { |slot| slot.fetch("options").length }
    assert_equal 108, generic.flat_map { |slot| slot.fetch("options") }.map { |option| option.fetch("place_id") }.uniq.length
    slots.each do |slot|
      expected = slot.fetch("status") == "fixed" ? [1] : [1, 2, 3]
      assert_equal expected, slot.fetch("options").map { |option| option.fetch("rank") }.sort, slot.fetch("id")
      slot.fetch("options").each { |option| refute_empty option.dig("order_for_two", "items"), option.fetch("id") }
    end
    generic.each do |slot|
      slot.fetch("options").each do |option|
        assert_equal true, option.dig("operating_hours", "compatible"), option.fetch("id")
        assert_equal slot.fetch("time_label"), option.dig("operating_hours", "meal_window"), option.fetch("id")
        detour = option.dig("route_fit", "incremental_detour_minutes")
        if detour > 15
          assert_operator detour, :<=, 20, option.fetch("id")
          assert option.dig("route_fit", "distance_exception", "reason"), option.fetch("id")
        else
          assert_operator detour, :<=, 15, option.fetch("id")
        end
        assert_equal option.dig("route_fit", "incremental_detour_minutes"), option.dig("route_fit", "via_venue_flow_minutes") - option.dig("route_fit", "direct_flow_minutes"), option.fetch("id")
        option.dig("order_for_two", "items").each { |item| assert item.dig("unit_price", "source_url"), option.fetch("id") }
      end
    end

    expected_protected = {
      "day-03-lunch" => %w[harbs-ueno inshotei ueno-yoshoku-toyama],
      "day-03-dinner" => %w[hikiniku-to-come-shibuya hachiya-curry-shibuya uobei-shibuya-dogenzaka],
      "day-07-dinner" => %w[kagari-kisshotei],
      "day-08-breakfast" => %w[kagari-kisshotei],
      "day-14-dinner" => %w[551-horai-main-store ajino-ya-honten takoyaki-wanaka-sennichimae]
    }
    expected_protected.each do |slot_id, place_ids|
      slot = slots.find { |candidate| candidate.fetch("id") == slot_id }
      assert_equal place_ids, slot.fetch("options").map { |option| option.fetch("place_id") }
    end

    kyoto_hotel_meals = %w[
      day-08-dinner day-09-dinner day-10-breakfast day-10-dinner
      day-11-breakfast day-11-dinner day-12-breakfast
    ].map { |slot_id| slots.find { |slot| slot.fetch("id") == slot_id } }
    assert kyoto_hotel_meals.all? { |slot| slot.fetch("options").all? { |option| option.dig("route_fit", "anchor_place_id") == "sotetsu-fresa-inn-kyoto-kiyomizu-gojo" } }
    assert kyoto_hotel_meals.flat_map { |slot| slot.fetch("options") }.all? { |option| option.dig("route_fit", "walking_minutes") <= 20 }
    assert_match(/Breakfast is not included/, slots.find { |slot| slot.fetch("id") == "day-10-breakfast" }.fetch("context"))

    rendered = Itinerary::Renderer.new(@store).render
    assert_includes rendered, '<span class="meal-summary-count">3 nearby options</span>'
    assert_includes rendered, '<span class="meal-summary-count">Planned venue + 2 backups</span>'
    assert_includes rendered, '<span class="meal-summary-count">Confirmed meal</span>'
    assert_includes rendered, "Order for two:"
    assert_includes rendered, "Ueno Yōshoku Tōyama"
    assert_includes rendered, "Uobei Shibuya Dogenzaka"
  end

  def test_changed_meal_windows_use_measured_routes_instead_of_rank_placeholders
    slots = @store.meal_option_days.flat_map { |day| day.fetch("slots") }.to_h { |slot| [slot.fetch("id"), slot] }

    nara_lunch = slots.fetch("day-09-lunch").fetch("options")
    assert_equal %w[izasa-yumekaze warabe-yorokobian-yumekaze yamato-beef-ramen-jo-yumekaze],
      nara_lunch.map { |option| option.fetch("place_id") }
    assert_equal [12, 12, 12], nara_lunch.map { |option| option.dig("route_fit", "walking_minutes") }
    assert nara_lunch.all? { |option| option.dig("route_fit", "anchor_place_id") == "todai-ji" }

    assert_equal [7, 8, 15], slots.fetch("day-12-lunch").fetch("options").map { |option| option.dig("route_fit", "walking_minutes") }
    assert_equal [10, 10, 10], slots.fetch("day-12-dinner").fetch("options").map { |option| option.dig("route_fit", "walking_minutes") }
    assert_equal [2, 5, 3], slots.fetch("day-13-breakfast").fetch("options").map { |option| option.dig("route_fit", "walking_minutes") }

    changed = %w[day-09-breakfast day-09-lunch day-12-lunch day-12-dinner day-13-breakfast]
      .flat_map { |slot_id| slots.fetch(slot_id).fetch("options") }
    refute changed.any? { |option| option.dig("route_fit", "provider").include?("Named-venue map search") }
    assert_equal [10], slots.fetch("day-09-breakfast").fetch("options").map { |option| option.dig("stay_minutes", "recommended") }.uniq
    assert_equal [10], slots.fetch("day-13-breakfast").fetch("options").map { |option| option.dig("stay_minutes", "recommended") }.uniq

    route_scripts = %w[regenerate_generic_meals.rb verify_meal_routes.rb].map do |filename|
      File.read(File.join(TRIP_ROOT, "tools", filename), encoding: "UTF-8")
    end.join("\n")
    refute_includes route_scripts, "walk = [4, 7, 10][index]"
    refute_includes route_scripts, "detour = [2, 6, 10][index]"
  end

  def test_meal_option_validator_requires_three_nonfixed_options
    issues = validate_mutation("meal_options.yaml") do |document|
      slot = document.fetch("days").flat_map { |day| day.fetch("slots") }.find { |candidate| candidate.fetch("status") == "scheduled" }
      slot.fetch("options").pop
    end
    assert_includes issues.map(&:code), "meal-option-count"
  end

  def test_meal_option_validator_rejects_restaurants_outside_the_nearby_cluster
    issues = validate_mutation("places.yaml") do |document|
      coordinates = document.fetch("places").fetch("ekibenya-odori").fetch("coordinates")
      coordinates["latitude"] = 35.6584958
      coordinates["longitude"] = 139.7023944
    end
    assert_includes issues.map(&:code), "distant-meal-options"
  end

  def test_generic_meal_validator_rejects_global_venue_reuse
    issues = validate_mutation("meal_options.yaml") do |document|
      slots = document.fetch("days").flat_map { |day| day.fetch("slots") }
      slots.find { |slot| slot.fetch("id") == "day-02-dinner" }.fetch("options").first["place_id"] =
        slots.find { |slot| slot.fetch("id") == "day-01-dinner" }.fetch("options").first.fetch("place_id")
    end
    assert_includes issues.map(&:code), "reused-generic-meal-place"
  end

  def test_generic_meal_validator_requires_hours_and_sourced_item_prices
    issues = validate_mutation("meal_options.yaml") do |document|
      option = document.fetch("days").first.fetch("slots").first.fetch("options").first
      option.delete("operating_hours")
      option.dig("order_for_two", "items").first.delete("unit_price")
    end
    assert_includes issues.map(&:code), "meal-hours-missing"
    assert_includes issues.map(&:code), "meal-item-price"
  end

  def test_generic_meal_validator_requires_exception_for_long_detour
    issues = validate_mutation("meal_options.yaml") do |document|
      route = document.fetch("days").first.fetch("slots").first.fetch("options").first.fetch("route_fit")
      route["incremental_detour_minutes"] = 16
      route["via_venue_flow_minutes"] = route.fetch("direct_flow_minutes") + 16
    end
    assert_includes issues.map(&:code), "meal-detour-exception"
  end

  def test_train_types_are_canonical_and_rendered_as_emoji
    activities = @store.activities.to_h { |activity| [activity.fetch("id"), activity] }
    assert_equal ["high_speed_rail"], activities.fetch("day-05-01").fetch("rail_types")
    assert_equal ["high_speed_rail"], activities.fetch("day-07-06").fetch("rail_types")
    assert_equal %w[high_speed_rail conventional_rail], activities.fetch("day-08-05").fetch("rail_types")
    assert_equal %w[conventional_rail high_speed_rail], activities.fetch("day-13-01").fetch("rail_types")
    assert_equal %w[high_speed_rail conventional_rail], activities.fetch("day-13-04").fetch("rail_types")
    assert_equal ["conventional_rail"], activities.fetch("day-15-05").fetch("rail_types")

    rendered = Itinerary::Renderer.new(@store).render
    assert_includes rendered, "Shinkansen (bullet train)"
    assert_includes rendered, "Regular train"
    assert_match(/data-activity-id="day-05-01".*?aria-label="Shinkansen \(bullet train\)".*?🚅/m, rendered)
    assert_match(/data-activity-id="day-08-05".*?aria-label="Shinkansen \(bullet train\) then regular train".*?🚅 🚂/m, rendered)
    assert_match(/data-activity-id="day-15-05".*?aria-label="regular train".*?🚂/m, rendered)
  end

  def test_validator_rejects_rail_types_on_non_transport_activity
    issues = validate_mutation("trip.yaml") do |document|
      document.fetch("days").first.fetch("activities")[1]["rail_types"] = ["conventional_rail"]
    end
    assert_includes issues.map(&:code), "rail-type-category"
  end

  def test_activity_chooser_is_current_complete_and_trip_derived
    rendered = Itinerary::ActivityOptionsRenderer.new(@store).render
    assert_equal rendered, File.read(File.join(TRIP_ROOT, "activity-options.html"), encoding: "UTF-8")

    destinations = @store.activity_option_destinations
    assert_equal @store.trip_metadata.fetch("route").uniq, destinations.map { |destination| destination.fetch("place_id") }
    option_ids = destinations.flat_map { |destination| destination.fetch("options").map { |option| option.fetch("place_id") } }
    assert_operator option_ids.length, :>=, 90
    assert_equal option_ids.uniq, option_ids
    refute_match(/^\s+selected:/, YAML.dump(@store.activity_options))

    occurrences = Hash.new { |hash, key| hash[key] = [] }
    @store.days.each do |day|
      day.fetch("activities").each do |activity|
        activity.fetch("content").filter_map { |token| token["place"] }.uniq.each do |place_id|
          occurrences[place_id] << [day, activity]
        end
      end
    end

    cards = rendered.scan(%r{<article class="activity-card(?: is-community)?".*?</article>}m)
    assert_equal option_ids.length, cards.length
    cards.each do |card|
      place_id = card[/value="([^"]+)"/, 1]
      refute_nil place_id
      default_occurrences = occurrences[place_id].reject { |(_day, activity)| activity.fetch("optional") }
      alternative_occurrences = occurrences[place_id].select { |(_day, activity)| activity.fetch("optional") }
      expected_state = if default_occurrences.any?
        "selected"
      elsif alternative_occurrences.any?
        "alternative"
      else
        "unscheduled"
      end
      assert_includes card, %(data-state="#{expected_state}")
      assert_equal default_occurrences.any?, card.include?('checked="checked"'), place_id
      assert_includes card, "Currently scheduled" if default_occurrences.any?
      assert_includes card, "Existing alternative" if default_occurrences.empty? && alternative_occurrences.any?
      assert_match(/<img alt="[^"]+"[^>]+loading="(?:eager|lazy)"[^>]+src="assets\/activity-options\/[a-z0-9-]+\.jpg"/, card)
      image_path = card[/src="([^"]+)"/, 1]
      assert File.file?(File.join(TRIP_ROOT, image_path)), image_path
      assert_includes card, "https://www.google.com/search?q="
      assert_includes card, "Relaxed visit"
      assert_match(/<strong>[^<]*(?:minutes|hours|Overnight)[^<]*<\/strong>/, card)
      assert_match(/<section class="duration-guidance".*?<p>[^<]{40,}<\/p>/m, card)
    end

    community_options = destinations.flat_map { |destination| destination.fetch("options") }.select { |option| option.key?("community_source") }
    community_cards = cards.select { |card| card.include?('data-community="true"') }
    assert_operator community_options.length, :>=, 20
    assert_equal community_options.length, community_cards.length
    community_cards.each do |card|
      assert_includes card, "People’s pick · Reddit"
      assert_includes card, "Traveler signal:"
      assert_includes card, "https://www.reddit.com/"
    end

    chooser_script = File.read(File.join(FRAMEWORK_ROOT, "src", "activity-options.js"), encoding: "UTF-8")
    assert_includes chooser_script, "CHANGES FROM CURRENT ITINERARY"
    assert_includes chooser_script, "appendGroups(lines, 'ADDED'"
    assert_includes chooser_script, "appendGroups(lines, 'REMOVED'"
    assert_includes chooser_script, "card.dataset.change = state"

    chooser_styles = File.read(File.join(FRAMEWORK_ROOT, "src", "activity-options.css"), encoding: "UTF-8")
    assert_includes chooser_styles, '[data-change="added"]'
    assert_includes chooser_styles, '[data-change="removed"]'
    assert_includes chooser_styles, ".activity-card.is-community"
  end


  def test_concurrent_meals_are_contained_and_do_not_double_count_commitment
    day = @store.days.find { |candidate| candidate.fetch("number") == 5 }
    breakfast = day.fetch("activities").find { |activity| activity.fetch("id") == "day-05-breakfast" }
    assert_equal "day-05-01", breakfast.dig("time", "concurrent_with_activity_ref")
    raw_minutes = day.fetch("activities").reject { |activity| activity.fetch("optional") }.sum { |activity| Itinerary::PaceAnalyzer.duration(activity) }
    metric = Itinerary::PaceAnalyzer.new(@store).day_metrics.find { |candidate| candidate.fetch("day") == 5 }
    assert_equal 35, raw_minutes - metric.fetch("scheduled_default_minutes")

    issues = validate_mutation("trip.yaml") do |document|
      meal = document.fetch("days")[4].fetch("activities").find { |activity| activity.fetch("id") == "day-05-breakfast" }
      meal.fetch("time")["end"] = "12:11"
    end
    assert_includes issues.map(&:code), "concurrent-meal-containment"
  end

  def test_every_meal_has_a_canonical_type
    meal_types = @store.activities.select { |activity| activity.fetch("category") == "meal" }
      .map { |activity| activity.fetch("meal_type") }
      .tally
    assert_equal({ "breakfast" => 13, "lunch" => 13, "dinner" => 15 }, meal_types)
  end

  def test_validator_requires_meal_type_only_on_meals
    missing = validate_mutation("trip.yaml") do |document|
      meal = document.fetch("days").flat_map { |day| day.fetch("activities") }
        .find { |activity| activity.fetch("category") == "meal" }
      meal.delete("meal_type")
    end
    assert_includes missing.map(&:code), "schema-required"

    misplaced = validate_mutation("trip.yaml") do |document|
      nonmeal = document.fetch("days").flat_map { |day| day.fetch("activities") }
        .find { |activity| activity.fetch("category") != "meal" }
      nonmeal["meal_type"] = "breakfast"
    end
    assert_includes misplaced.map(&:code), "meal-type-category"
  end

  def test_hard_morning_constraint_rejects_a_default_activity_before_0800
    issues = validate_mutation("trip.yaml") do |document|
      breakfast = document.fetch("days")[2].fetch("activities")
        .find { |activity| activity.fetch("id") == "day-03-breakfast" }
      breakfast.fetch("time")["start"] = "07:59"
    end
    assert_includes issues.select { |issue| issue.severity == :error }.map(&:code), "daily-start-too-early"
  end

  def test_hard_meal_constraint_rejects_a_59_minute_ordinary_meal
    issues = validate_mutation("trip.yaml") do |document|
      dinner = document.fetch("days")[1].fetch("activities")
        .find { |activity| activity.fetch("id") == "day-02-05" }
      dinner.fetch("time")["end"] = "19:44"
    end
    assert_includes issues.select { |issue| issue.severity == :error }.map(&:code), "meal-duration-too-short"
  end

  def test_only_the_four_declared_meal_exceptions_are_shorter_than_60_minutes
    constraint = @store.constraint_list.find { |candidate| candidate.fetch("id") == "meals-minimum-60" }
    exception_ids = constraint.fetch("exceptions").map { |exception| exception.fetch("activity_ref") }
    assert_equal %w[day-04-breakfast day-04-lunch day-05-breakfast day-13-breakfast], exception_ids

    activities = @store.activities.to_h { |activity| [activity.fetch("id"), activity] }
    assert_equal [45, 45, 35, 35], exception_ids.map { |id| Itinerary::PaceAnalyzer.duration(activities.fetch(id)) }
    short_default_meals = @store.activities.select do |activity|
      !activity.fetch("optional") && activity.fetch("category") == "meal" && Itinerary::PaceAnalyzer.duration(activity) < 60
    end
    assert_equal exception_ids.sort, short_default_meals.map { |activity| activity.fetch("id") }.sort
  end

  def test_revised_meal_windows_are_canonical
    expected = {
      "day-01-02" => %w[19:30 20:30],
      "day-02-05" => %w[18:45 20:15],
      "day-03-breakfast" => %w[08:15 09:15],
      "day-03-02" => %w[11:50 13:05],
      "day-03-07" => %w[18:00 19:15],
      "day-04-breakfast" => %w[08:00 08:45],
      "day-04-lunch" => %w[11:15 12:00],
      "day-04-05" => %w[16:00 17:30],
      "day-05-breakfast" => %w[09:15 09:50],
      "day-05-02" => %w[12:25 13:40],
      "day-05-06" => %w[16:40 18:10],
      "day-06-breakfast" => %w[08:30 09:30],
      "day-06-03" => %w[11:45 13:00],
      "day-06-06" => %w[17:00 18:30],
      "day-07-breakfast" => %w[08:00 09:00],
      "day-07-04" => %w[11:00 12:00],
      "day-07-09" => %w[17:30 19:30],
      "day-08-01" => %w[08:00 09:00],
      "day-08-06" => %w[13:10 14:10],
      "day-08-09" => %w[16:30 18:00],
      "day-09-breakfast" => %w[08:00 09:00],
      "day-09-lunch" => %w[11:15 12:15],
      "day-09-dinner" => %w[18:30 20:00],
      "day-10-breakfast" => %w[08:00 09:00],
      "day-10-03" => %w[12:15 13:30],
      "day-10-06" => %w[16:30 18:00],
      "day-11-breakfast" => %w[08:00 09:00],
      "day-11-03" => %w[12:30 14:00],
      "day-11-06" => %w[16:30 18:00],
      "day-12-breakfast" => %w[08:00 09:00],
      "day-12-lunch" => %w[11:30 12:30],
      "day-12-dinner" => %w[16:30 18:00],
      "day-13-breakfast" => %w[08:45 09:20],
      "day-13-03" => %w[12:45 13:45],
      "day-13-07" => %w[17:00 18:30],
      "day-14-02" => %w[10:00 11:00],
      "day-14-05" => %w[13:20 14:30],
      "day-14-08-dinner" => %w[18:00 19:30],
      "day-15-breakfast" => %w[08:00 09:00],
      "day-15-03" => %w[11:00 12:00],
      "day-15-06-dinner" => %w[16:00 17:15]
    }
    actual = @store.activities.select { |activity| activity.fetch("category") == "meal" }
      .to_h { |activity| [activity.fetch("id"), activity.fetch("time").values_at("start", "end")] }
    assert_equal expected, actual
  end

  def test_short_ordinary_dinner_raises_the_soft_preference_warning
    issues = validate_mutation("trip.yaml") do |document|
      dinner = document.fetch("days")[1].fetch("activities")
        .find { |activity| activity.fetch("id") == "day-02-05" }
      dinner.fetch("time")["end"] = "20:14"
    end
    warnings = issues.select { |issue| issue.severity == :warning }
    assert_includes warnings.map(&:code), "preferred-meal-duration"
    refute_includes issues.select { |issue| issue.severity == :error }.map(&:code), "meal-duration-too-short"
  end

  def test_portable_breakfasts_are_contained_within_intercity_train_activities
    activities = @store.activities.to_h { |activity| [activity.fetch("id"), activity] }
    %w[day-05-breakfast day-13-breakfast].each do |breakfast_id|
      breakfast = activities.fetch(breakfast_id)
      train = activities.fetch(breakfast.dig("time", "concurrent_with_activity_ref"))
      assert_equal "transport", train.fetch("category")
      assert_includes train.fetch("rail_types"), "high_speed_rail"
      assert_operator Itinerary::PaceAnalyzer.minutes(breakfast.dig("time", "start")), :>=, Itinerary::PaceAnalyzer.minutes(train.dig("time", "start"))
      assert_operator Itinerary::PaceAnalyzer.minutes(breakfast.dig("time", "end")), :<=, Itinerary::PaceAnalyzer.minutes(train.dig("time", "end"))
    end

    breakfast = activities.fetch("day-09-breakfast")
    train = activities.fetch(breakfast.dig("time", "concurrent_with_activity_ref"))
    assert_equal ["transport", ["conventional_rail"], 60], [train.fetch("category"), train.fetch("rail_types"), Itinerary::PaceAnalyzer.duration(breakfast)]
  end

  def test_himeji_admission_and_booking_are_provisionally_set_for_1000
    activity = @store.activities.find { |candidate| candidate.fetch("id") == "day-13-02" }
    assert_equal ["10:00", "12:30"], activity.fetch("time").values_at("start", "end")
    booking = @store.booking_list.find { |candidate| candidate.fetch("id") == "himeji-rail-and-castle" }
    assert_equal "required", booking.fetch("status")
    assert_match(/10:00/, booking.fetch("instructions"))
    assert_match(/Osaka-Himeji/, booking.fetch("instructions"))
    assert_match(/existing Osaka base/, booking.fetch("instructions"))
    assert_match(/provisional/i, booking.fetch("instructions"))
  end

  def test_kanazawa_castle_area_is_an_untimed_replacement_only
    activity = @store.activities.find { |candidate| candidate.fetch("id") == "day-05-04" }
    assert_equal [true, "optional", "label_only", 60], [
      activity.fetch("optional"), activity.fetch("priority"),
      activity.dig("time", "precision"), activity.dig("time", "estimated_duration_minutes")
    ]
    assert_match(/replacement, never as an addition/i, activity.fetch("content").filter_map { |token| token["text"] }.join)
  end

  def test_promoted_meals_preserve_target_pace_profile_and_departure_rule
    metrics = Itinerary::PaceAnalyzer.new(@store).day_metrics.to_h { |day| [day.fetch("day"), day] }
    assert_equal [3, 7, 13], metrics.values.select { |day| day.fetch("classification") == "AMBER" }.map { |day| day.fetch("day") }
    [4, 5, 6, 10, 11, 12, 15].each { |day| assert_equal "GREEN", metrics.fetch(day).fetch("classification"), "Day #{day}" }
    assert_equal ["RED", %w[pace-active-span pace-commitment pace-transport pace-major-anchors pace-clusters]], [metrics.fetch(9).fetch("classification"), metrics.fetch(9).fetch("blocking_reasons").map { |reason| reason.fetch("code") }]
    assert_empty metrics.fetch(13).fetch("blocking_reasons")
    assert_equal 660, metrics.fetch(15).fetch("active_span_minutes")
    assert_operator metrics.fetch(15).fetch("departure_protection_minutes"), :>=, 120
  end


  def test_activity_chooser_validator_rejects_drift
    duplicate_issues = validate_mutation("activity_options.yaml") do |document|
      options = document.fetch("destinations").first.fetch("options")
      options << Marshal.load(Marshal.dump(options.first))
    end
    assert_includes duplicate_issues.map(&:code), "duplicate-activity-option"

    image_issues = validate_mutation("activity_options.yaml") do |document|
      document.fetch("destinations").first.fetch("options").first["image_id"] = "missing-image"
    end
    assert_includes image_issues.map(&:code), "unknown-activity-image"

    duration_issues = validate_mutation("activity_options.yaml") do |document|
      first_option = document.fetch("destinations").first.fetch("options").first.fetch("place_id")
      document.fetch("relaxed_visits").delete(first_option)
    end
    assert_includes duration_issues.map(&:code), "missing-relaxed-visit"

    orphan_duration_issues = validate_mutation("activity_options.yaml") do |document|
      document.fetch("relaxed_visits")["not-an-option"] = {
        "duration" => "60 minutes",
        "description" => "A deliberately orphaned duration record used to prove validator coverage."
      }
    end
    assert_includes orphan_duration_issues.map(&:code), "orphan-relaxed-visit"
  end

  def test_generated_journey_map_is_current_and_contains_canonical_route_data
    rendered = Itinerary::JourneyMapRenderer.new(@store).render
    assert_equal rendered, File.read(File.join(TRIP_ROOT, "journey-map.html"), encoding: "UTF-8")

    payload = journey_payload(rendered)
    assert_equal @store.movement_days.length, payload.fetch("days").length
    payload.fetch("days").each do |day|
      itinerary_day = @store.days.find { |candidate| candidate.fetch("number") == day.fetch("day") }
      expected_event_ids = itinerary_day.fetch("activities").reject { |activity| activity.fetch("optional") }.map { |activity| activity.fetch("id") }
      assert_equal expected_event_ids, day.fetch("events").map { |event| event.fetch("id") }, "Day #{day.fetch('day')} journey events must mirror the canonical itinerary"
      day.fetch("events").each do |event|
        activity = itinerary_day.fetch("activities").find { |candidate| candidate.fetch("id") == event.fetch("id") }
        assert_equal event.fetch("category") == "transport", event.fetch("in_transit"), "#{event.fetch('id')} transit state must match its itinerary category"
        assert_equal activity.fetch("meal_type"), event.fetch("meal_type"), "#{event.fetch('id')} must preserve its canonical meal type" if event.fetch("category") == "meal"
      end
    end
    assert_equal 2, payload.fetch("transitions").length
    assert_equal %w[flight-syd-nrt flight-kix-syd], payload.fetch("transitions").map { |transition| transition.dig("booking", "id") }
    day = payload.fetch("days").find { |candidate| candidate.fetch("day") == 14 }
    expected_walks = @store.movement_days.find { |candidate| candidate.fetch("day") == 14 }.fetch("legs").select { |leg| leg.fetch("mode") == "walk" }
    assert_equal expected_walks.sum { |leg| leg.fetch("distance_meters") }, day.fetch("walking_distance_meters")
    assert_equal expected_walks.sum { |leg| leg.fetch("duration_minutes") }, day.fetch("walking_duration_minutes")
    assert day.fetch("legs").reject { |leg| leg.fetch("status") == "unresolved" }.all? { |leg| leg.dig("geometry", "coordinates").length >= 2 }
    assert day.fetch("legs").select { |leg| leg.fetch("status") == "unresolved" }.all? { |leg| !leg.key?("geometry") && !leg.key?("distance_meters") }
    refute_match(/api[_-]?key/i, rendered)
    refute_includes rendered, "document.write"
    assert_includes rendered, ">Play trip<"
    assert_includes rendered, 'aria-keyshortcuts="Space"'
    assert_includes rendered, 'event.code !== "Space"'
    assert_includes rendered, "input:not([type='range'])"
    assert_includes rendered, "followScrubCamera(previousSegment)"
    assert_includes rendered, "const STOP_FOCUS_ZOOM = 15"
    assert_includes rendered, "const UNCERTAIN_STOP_FOCUS_ZOOM = 12.5"
    assert_includes rendered, "function cameraTargetKey(day, state)"
    assert_includes rendered, "function fallbackViewportCoordinates(context)"
    assert_includes rendered, "renderDay(true)"
    assert_includes rendered, "fitCurrentState(state, true)"
    assert_includes rendered, "function recenterRoute()"
    assert_match(/function startPlayback\(\) \{.*?recenterRoute\(\);/m, rendered)
    assert_includes rendered, 'elements.mapRecenter.addEventListener("click", recenterRoute)'
    refute_includes rendered, "!movementState(state)) return"
    refute_includes rendered, "function fitDay(day)"
    assert_includes rendered, 'elements.play.setAttribute("aria-pressed", "true")'
    assert_includes rendered, "resumePlaybackAfterScrub = Boolean(playbackFrame)"
    assert_includes rendered, 'range.addEventListener("pointerdown", beginTimelineScrub)'
    assert_includes rendered, 'window.addEventListener("pointerup", endTimelineScrub)'
    assert_includes rendered, 'window.addEventListener("pointercancel", endTimelineScrub)'
    assert_includes rendered, "if (shouldResume && !playbackFrame) startPlayback()"
    assert_includes rendered, 'return visits.length ? `${visits.join(" + ")} day route`'
    assert_includes rendered, 'id="selected-route-title"'
    refute_includes rendered, 'id="selected-day-label"'
    refute_includes rendered, 'id="selected-day-summary"'
    refute_includes rendered, 'class="journey-badges"'
    refute_includes rendered, 'class="journey-metrics"'
    refute_includes rendered, 'class="current-segment"'
    refute_includes rendered, 'class="walking-note"'
    assert_includes rendered, 'class="mode-meal">1</i>Planned / recommended restaurant'
    assert_includes rendered, 'class="mode-meal mode-meal--alternative">2</i>Nearby alternative'
    assert_includes rendered, 'const activeMealAt = (day, minute)'
    assert_includes rendered, 'const activeMealOptionsAt = (day, minute)'
    assert_includes rendered, 'const activeMealLocationAt = (day, state, minute)'
    assert_includes rendered, 'role: "meal_option"'
    assert_includes rendered, 'stop.role === "meal_option"'
    assert_includes rendered, 'trail-position--meal'
    assert_includes rendered, 'trail-position--meal-area'
    assert_includes rendered, 'glyph.textContent = String(stop.rank)'
    assert_includes rendered, '`${event.meal_options.length} nearby options`'
    refute_includes rendered, 'Venue not selected'
    assert_includes rendered, 'function renderMealOptions(event)'
    assert_includes rendered, 'function focusMealOption(option)'
    assert_includes rendered, "text-overflow: ellipsis;"
    assert_includes rendered, "padding: 6px 5px 6px 9px;"
    assert_includes rendered, 'id="day-stop-viewport"'
    assert_includes rendered, 'id="show-current-row"'
    assert_includes rendered, 'class="day-stops__hint">Select a row to jump'
    assert_includes rendered, "function revealCurrentRow(force = false)"
    assert_includes rendered, 'item.setAttribute("aria-current", "true")'
    assert_includes rendered, 'control.className = "itinerary-row"'
    assert_includes rendered, 'control.setAttribute("aria-label", `Skip to ${eventClockLabel(event)}, ${event.title}${locationStatus'
    assert_includes rendered, 'control.addEventListener("click", () => selectItineraryEvent(day, event))'
    assert_includes rendered, 'control.addEventListener("click", () => selectBoundaryPoint(fraction))'
    assert_includes rendered, 'renderDay(true, false, event.id)'
    assert_includes rendered, 'activeBoundaryFraction = 1'
    assert_includes rendered, 'elements.dayStopViewport.addEventListener("wheel", suspendCurrentRowFollowing'
    assert_includes rendered, 'id="trip-range" min="0" max="1" step="0.001"'
    assert_includes rendered, 'id="day-range" min="1110" max="1290" step="0.1"'
    assert_includes rendered, 'id="journey-route-overlay"'
    assert_includes rendered, "renderRouteOverlay"
    assert_includes rendered, "buildTimelineSegments"
    assert_includes rendered, 'id="trip-segments"'
    assert_includes rendered, 'id="overnight-status"'
    assert_includes rendered, 'class="overnight-wash"'
    assert_includes rendered, 'id="trip-ticks" role="group" aria-label="Jump to day"'
    assert_includes rendered, "function renderTripSegments()"
    assert_includes rendered, "function syncTripTimelineState()"
    assert_includes rendered, 'band.className = `trip-segment trip-segment--${segment.kind}`'
    assert_includes rendered, 'content: "☾"'
    assert_includes rendered, 'elements.mapWrap.classList.add("is-overnight")'
    assert_includes rendered, 'elements.journeyDetail.classList.add("is-overnight")'
    assert_includes rendered, 'if (context.state.kind === "overnight") return;'
    assert_includes rendered, 'const adjacentSegment = Math.abs(context.segmentIndex - previousSegmentIndex) === 1'
    assert_includes rendered, 'const zoom = Math.max(map.getZoom(), 13)'
    assert_includes rendered, 'const OVERNIGHT_PLAYBACK_MS = 1200'
    refute_includes rendered, 'renderBoundaryStops([{ time: "Night"'
    assert_includes rendered, 'tick.innerHTML = `<strong>${day.day}</strong>`'
    assert_includes rendered, 'tick.setAttribute("aria-current", "step")'
    assert_includes rendered, 'elements.tripRange.setAttribute("aria-valuetext"'
    assert_includes rendered, "window.requestAnimationFrame(playbackTick)"
    assert_includes rendered, "updateMotionOverlay"
    assert_includes rendered, "activeEventsAt"
    assert_includes rendered, "eventProgress"
    assert_includes rendered, "stop-countdown"
    assert_includes rendered, "trail-stop-duration-label"
    assert_includes rendered, "stationaryTimerEventAt"
    assert_includes rendered, "if (!day || movementState(state)) return null"
    assert_includes rendered, 'const timerLabel = (event) => `${timerDescriptor(event)} · ${formatDuration(eventDuration(event))}`'
    assert_includes rendered, 'return `Wait for ${wait[1].toLowerCase()}`'
    assert_includes rendered, 'return "Forward luggage"'
    assert_includes rendered, 'return "Airport formalities"'
    assert_includes rendered, "const MIN_STAY_PLAYBACK_MS = 750"
    assert_includes rendered, "durationMs: Math.max(MIN_STAY_PLAYBACK_MS, naturalDurationMs)"
    assert_includes rendered, "playbackStationaryTiming"
    assert_includes rendered, "trail-stop-timer-progress"
    assert_includes rendered, "trail-stop-duration-label"
    assert_includes rendered, "trail-position--schematic"
    assert_includes rendered, "trail-tbd-progress"
    assert_includes rendered, "trail-high-speed-rail"
    assert_includes rendered, "high-speed-rail-whoosh"
    assert_includes rendered, "🚅 Shinkansen · bullet train"
    assert_includes rendered, "presentation.playback_ms"
    assert_includes rendered, "trail-conventional-rail"
    assert_includes rendered, "conventional-rail-rhythm"
    assert_includes rendered, "🚂 Regular train"
    assert_includes rendered, "trail-bus"
    assert_includes rendered, "bus-road-crawl"
    assert_includes rendered, "🚌 Bus"
    assert_includes rendered, "BUS_PLAYBACK_MS"
    refute_includes rendered, "window.setInterval"
    assert_includes rendered, "route and distance TBD"
    assert_includes rendered, 'state.kind !== "unresolved_leg"'
    assert_includes rendered, 'const uncertainBase = uncertainLodging(stop)'
    assert_includes rendered, 'const exactLocation = (place) =>'
    assert_includes rendered, "Sotetsu Fresa Inn Ginza-Nanachome"
    assert_includes rendered, "Hotel Amanek Kanazawa"
    assert_includes rendered, "Sotetsu Fresa Inn Kyoto-Kiyomizu Gojo"
    assert_includes rendered, "Sotetsu Fresa Inn Osaka-Namba"
    assert_includes rendered, '((segment.start + segment.weight / 2) / timelineTotal) * 100'
    assert_includes rendered, "Confirmed overnight flight"
    assert_includes rendered, 'style: mapConfig.style_url'
    assert_includes rendered, '"style_url":"https://tiles.openfreemap.org/styles/liberty"'
    assert_includes rendered, 'attributionControl: { compact: true }'
    assert_includes rendered, "function collapseAttributionControl()"
    assert_includes rendered, 'control.classList.remove("maplibregl-compact-show")'
    refute_includes rendered, 'class="map-attribution-note"'
    assert_includes rendered, '["get", "name:en"]'
    assert_includes rendered, '["get", "name:latin"], ""'
    refute_includes rendered, 'fetch("https://tiles.openfreemap.org/styles/liberty")'
    assert_includes rendered, "function scheduleBaseMapFailureCheck()"
    assert_includes rendered, "BASE_MAP_FAILURE_GRACE_MS"
    assert_includes rendered, "Street map unavailable. Showing the route diagram instead."
    refute_includes rendered, "tile.openstreetmap.org"

    shinkansen_leg = payload.fetch("days").find { |candidate| candidate.fetch("day") == 5 }.fetch("legs").find { |leg| leg.fetch("id") == "day-05-tokyo-kanazawa" }
    assert_equal ["high_speed_rail"], shinkansen_leg.fetch("rail_types")
    mixed_leg = payload.fetch("days").find { |candidate| candidate.fetch("day") == 8 }.fetch("legs").find { |leg| leg.fetch("id") == "day-08-kaga-onsen-kyoto" }
    assert_equal %w[high_speed_rail conventional_rail], mixed_leg.fetch("rail_types")

    day_nine = payload.fetch("days").find { |candidate| candidate.fetch("day") == 9 }
    assert_equal "08:00", day_nine.fetch("window_start")
    assert_equal 11, day_nine.fetch("events").length
    byodoin_event = day_nine.fetch("events").find { |event| event.fetch("id") == "day-09-byodoin" }
    assert_equal ["Byodoin"], byodoin_event.fetch("places").map { |place| place.fetch("name") }
    assert_equal "Byodoin + Hoshokan Museum", byodoin_event.fetch("title")
    shopping = day_nine.fetch("events").find { |event| event.fetch("id") == "day-09-matcha-shopping" }
    assert_equal ["Byodoin Omotesando", "Fukujuen Uji Kobo", "Nakamura Tokichi Uji Honten"], shopping.fetch("places").map { |place| place.fetch("name") }
    assert_equal ["14:45", "16:45"], shopping.values_at("start_time", "end_time")

    day_twelve = payload.fetch("days").find { |candidate| candidate.fetch("day") == 12 }
    assert_equal ["day-12-kyoto-osaka"], day_twelve.fetch("legs").map { |leg| leg.fetch("id") }
    open_afternoon = day_twelve.fetch("events").find { |event| event.fetch("id") == "day-12-open-afternoon" }
    assert_equal ["Protected open Osaka afternoon — activities TBC", ["Sotetsu Fresa Inn Osaka-Namba"]], [open_afternoon.fetch("title"), open_afternoon.fetch("places").map { |place| place.fetch("name") }]

    day_thirteen = payload.fetch("days").find { |candidate| candidate.fetch("day") == 13 }
    assert_equal %w[day-13-osaka-himeji day-13-himeji-castle day-13-castle-himeji day-13-himeji-osaka], day_thirteen.fetch("legs").map { |leg| leg.fetch("id") }
    assert_equal "Sotetsu Fresa Inn Osaka-Namba", day_thirteen.fetch("stops").first.fetch("place").fetch("name")
    assert_equal "Sotetsu Fresa Inn Osaka-Namba", day_thirteen.fetch("stops").last.fetch("place").fetch("name")

    day_six = payload.fetch("days").find { |candidate| candidate.fetch("day") == 6 }
    kanazawa_luggage = day_six.fetch("events").find { |event| event.fetch("id") == "day-06-01" }
    assert_equal ["Hotel Amanek Kanazawa"], kanazawa_luggage.fetch("places").map { |place| place.fetch("name") }
    refute_includes kanazawa_luggage.fetch("places").map { |place| place.fetch("name") }, "Kyoto"
    kanazawa_dinner = day_six.fetch("events").find { |event| event.fetch("id") == "day-06-06" }
    assert_equal "Dinner", kanazawa_dinner.fetch("title")

    day_ten = payload.fetch("days").find { |candidate| candidate.fetch("day") == 10 }
    kyoto_luggage = day_ten.fetch("events").find { |event| event.fetch("id") == "day-10-05-luggage" }
    assert_equal ["Sotetsu Fresa Inn Kyoto-Kiyomizu Gojo"], kyoto_luggage.fetch("places").map { |place| place.fetch("name") }
    refute_includes kyoto_luggage.fetch("places").map { |place| place.fetch("name") }, "Osaka"

    venue_events = payload.fetch("days").flat_map { |candidate| candidate.fetch("events") }
      .select { |event| event.key?("venue") }
      .to_h { |event| [event.fetch("id"), event.dig("venue", "id")] }
    assert_equal(
      {
        "day-03-02" => "harbs-ueno",
        "day-03-07" => "hikiniku-to-come-shibuya",
        "day-07-09" => "kagari-kisshotei",
        "day-08-01" => "kagari-kisshotei",
        "day-14-08-dinner" => "551-horai-main-store"
      },
      venue_events
    )
    dinner = payload.fetch("days").find { |candidate| candidate.fetch("day") == 14 }.fetch("events")
      .find { |event| event.fetch("id") == "day-14-08-dinner" }
    assert_equal "Dinner · 551 Horai Main Store", dinner.fetch("title")
    assert_equal "entrance", dinner.dig("venue", "coordinates", "precision")
    assert_equal [1, 2, 3], dinner.fetch("meal_options").map { |option| option.fetch("rank") }
    assert_equal %w[planned alternative alternative], dinner.fetch("meal_options").map { |option| option.fetch("role") }
    assert_equal "551-horai-main-store", dinner.dig("meal_options", 0, "place", "id")
    generic_lunch = payload.fetch("days").find { |candidate| candidate.fetch("day") == 6 }.fetch("events")
      .find { |event| event.fetch("id") == "day-06-03" }
    refute generic_lunch.key?("venue")
    assert_equal 3, generic_lunch.fetch("meal_options").length
    assert_equal "recommended", generic_lunch.dig("meal_options", 0, "role")

    breakfast = payload.fetch("days").find { |candidate| candidate.fetch("day") == 3 }.fetch("events")
      .find { |event| event.fetch("id") == "day-03-breakfast" }
    refute breakfast.key?("venue")
    assert_equal 3, breakfast.fetch("meal_options").length
    assert_equal "Katsuki at Sotetsu Fresa Inn Ginza-Nanachome", breakfast.dig("meal_options", 0, "place", "name")

    kagari = payload.fetch("days").find { |candidate| candidate.fetch("day") == 8 }.fetch("events")
      .find { |event| event.fetch("id") == "day-08-01" }
    assert_equal 1, kagari.fetch("meal_options").length
    assert_equal "planned", kagari.dig("meal_options", 0, "role")
  end

  def test_named_restaurant_coordinates_are_current_and_verified
    expected = {
      "harbs-ueno" => [139.7731425, 35.7068359, "https://www.openstreetmap.org/node/5211537225"],
      "hikiniku-to-come-shibuya" => [139.6976023, 35.659255, "https://hikinikutocome.com/en/visit/shibuya/"],
      "kagari-kisshotei" => [136.3714805, 36.2422894, "https://kagari-kisshotei.com/english/restaurant/"],
      "551-horai-main-store" => [135.5013457, 34.6664051, "https://www.551horai.co.jp/shop/list/13/"]
    }
    expected.each do |place_id, (longitude, latitude, source_url)|
      place = @store.place_catalog.fetch(place_id)
      assert_equal "restaurant", place.fetch("kind")
      assert_equal [longitude, latitude], place.fetch("coordinates").values_at("longitude", "latitude")
      assert_includes %w[exact entrance], place.dig("coordinates", "precision")
      assert_equal ["verified", source_url, "2026-09-11"], place.fetch("coordinates").values_at("status", "source_url", "checked_on")
    end
    assert_match(/PARCO_ya Ueno/, @store.place_catalog.dig("harbs-ueno", "description"))
  end

  def test_every_logistics_activity_has_a_specific_journey_title
    expected = {
      "day-01-airport-processing" => "Airport check-in, security and outbound border processing",
      "day-01-gate-buffer" => "Walk to the gate and protect the boarding buffer",
      "day-02-03-recovery" => "Hotel check-in and post-flight recovery",
      "day-05-05-recovery" => "Hotel check-in and recovery",
      "day-06-01" => "Forward luggage to Kyoto",
      "day-06-05-recovery" => "Hotel rest after the museum route",
      "day-07-08" => "Ryokan check-in, onsen and rest",
      "day-08-02" => "Final onsen, pack and wait for shuttle",
      "day-08-04" => "Wait for train at Kaga-Onsen Station",
      "day-08-08" => "Kyoto hotel check-in and recovery",
      "day-10-05-luggage" => "Forward luggage to Osaka and rest",
      "day-11-05-recovery" => "Hotel recovery after Arashiyama",
      "day-12-checkout" => "Final pack and Kyoto hotel checkout",
      "day-12-bag-drop" => "Leave essentials bag at the Osaka hotel",
      "day-12-open-afternoon" => "Protected open Osaka afternoon — activities TBC",
      "day-12-osaka-checkin" => "Osaka hotel check-in, collect luggage and reset",
      "day-13-06-recovery" => "Hotel recovery after the Himeji day trip",
      "day-15-01" => "Check out and leave bags",
      "day-15-04" => "Collect bags and walk to Nankai Namba",
      "day-15-06" => "Airport check-in, security and immigration",
      "day-15-06-gate-buffer" => "Hydrate, charge devices and wait near the gate"
    }
    logistics = @store.activities.select { |activity| activity.fetch("category") == "logistics" }
    assert_equal expected, logistics.to_h { |activity| [activity.fetch("id"), activity.fetch("title")] }

    payload = journey_payload(Itinerary::JourneyMapRenderer.new(@store).render)
    rendered_titles = payload.fetch("days").flat_map { |day| day.fetch("events") }
      .select { |event| event.fetch("category") == "logistics" }
      .to_h { |event| [event.fetch("id"), event.fetch("title")] }
    assert_equal expected, rendered_titles
    refute_includes rendered_titles.values, "Logistics"

    missing_title_issues = validate_mutation("trip.yaml") do |document|
      activity = document.fetch("days").flat_map { |day| day.fetch("activities") }
        .find { |candidate| candidate.fetch("category") == "logistics" }
      activity.delete("title")
    end
    assert_includes missing_title_issues.map(&:code), "missing-logistics-title"
  end

  def test_movement_validator_requires_train_type_metadata
    missing_issues = validate_mutation("movements.yaml") do |document|
      rail = document.fetch("days").flat_map { |day| day.fetch("legs") }.find { |leg| leg.fetch("mode") == "rail" }
      rail.delete("rail_types")
    end
    assert_includes missing_issues.map(&:code), "movement-rail-types-missing"

    invalid_mode_issues = validate_mutation("movements.yaml") do |document|
      walk = document.fetch("days").flat_map { |day| day.fetch("legs") }.find { |leg| leg.fetch("mode") == "walk" }
      walk["rail_types"] = ["conventional_rail"]
    end
    assert_includes invalid_mode_issues.map(&:code), "movement-rail-types-mode"
  end

  def test_every_walking_leg_has_verified_routed_distance
    walks = @store.movement_days.flat_map { |day| day.fetch("legs") }.select { |leg| leg.fetch("mode") == "walk" }
    assert_operator walks.length, :>, 20
    walks.each do |leg|
      assert_equal "routed", leg.fetch("geometry_kind"), leg.fetch("id")
      assert_equal "verified", leg.fetch("status"), leg.fetch("id")
      assert_operator leg.fetch("distance_meters"), :>, 0, leg.fetch("id")
      assert_equal "foot", leg.dig("source", "profile"), leg.fetch("id")
    end
  end

  def test_combined_nara_day_local_transfers_are_not_counted_as_between_stop_walking
    day = journey_payload(Itinerary::JourneyMapRenderer.new(@store).render).fetch("days").find { |candidate| candidate.fetch("day") == 9 }
    assert_equal %w[taxi taxi], day.fetch("legs").values_at(1, 2).map { |leg| leg.fetch("mode") }
    assert_equal 0, day.fetch("walking_distance_meters")
    assert_equal 0, day.fetch("walking_duration_minutes")
  end

  def test_validator_rejects_unverified_walking_geometry
    issues = validate_mutation("movements.yaml") do |document|
      walk = document.fetch("days").flat_map { |day| day.fetch("legs") }.find { |leg| leg.fetch("mode") == "walk" }
      walk["geometry_kind"] = "schematic"
      walk["status"] = "provisional"
    end
    assert_includes issues.map(&:code), "walking-route-unverified"
  end

  def test_unresolved_transfer_requires_a_matching_transport_activity
    issues = validate_mutation("movements.yaml") do |document|
      leg = document.fetch("days")[1].fetch("legs").first
      leg["mode"] = "local_transit"
      leg["duration_basis"] = "allowance"
      leg["status"] = "unresolved"
      %w[distance_meters geometry_kind geometry source].each { |field| leg.delete(field) }
      leg["activity_ref"] = "day-02-04-visit"
    end
    assert_includes issues.map(&:code), "unresolved-movement-activity"
  end

  def test_shortlisted_hotel_transfers_are_resolved
    legs = @store.movement_days.flat_map { |day| day.fetch("legs") }.select { |leg| leg.fetch("status") == "unresolved" }
    assert_empty legs
  end

  def test_validator_rejects_missing_stop_to_stop_movement
    issues = validate_mutation("movements.yaml") do |document|
      document.fetch("days")[3].fetch("legs").shift
    end
    assert_includes issues.map(&:code), "movement-continuity-gap"
  end

  def test_validator_rejects_missing_tokyo_return_leg
    issues = validate_mutation("movements.yaml") do |document|
      day = document.fetch("days").find { |candidate| candidate.fetch("day") == 2 }
      day.fetch("legs").reject! { |leg| leg.fetch("id") == "day-02-yonex-tokyo" }
    end
    assert_includes issues.map(&:code), "movement-continuity-gap"
  end

  def test_validator_rejects_missing_tokyo_outbound_leg
    issues = validate_mutation("movements.yaml") do |document|
      day = document.fetch("days").find { |candidate| candidate.fetch("day") == 3 }
      day.fetch("legs").reject! { |leg| leg.fetch("id") == "day-03-hotel-ueno" }
    end
    assert_includes issues.map(&:code), "movement-continuity-gap"
  end

  def test_validator_requires_the_declared_sleep_base_as_the_final_stop
    issues = validate_mutation("movements.yaml") do |document|
      day = document.fetch("days").find { |candidate| candidate.fetch("day") == 2 }
      day.fetch("stops").last["role"] = "activity"
    end
    assert_includes issues.map(&:code), "movement-sleep-base"
  end

  def test_validator_rejects_unexplained_day_boundary_jump
    issues = validate_mutation("movements.yaml") do |document|
      document.fetch("days")[2].fetch("stops").first["place_id"] = "shibuya"
    end
    assert_includes issues.map(&:code), "movement-day-boundary"
  end

  def test_flight_transition_requires_a_confirmed_flight_booking
    issues = validate_mutation("movements.yaml") do |document|
      document.fetch("transitions").first["booking_ref"] = "kagari-kisshotei-stay"
    end
    assert_includes issues.map(&:code), "movement-transition-booking"
  end

  def test_hotel_boundaries_are_continuous
    days = @store.movement_days.to_h { |day| [day.fetch("day"), day] }
    assert_equal "sotetsu-fresa-inn-ginza-nanachome", days.fetch(2).fetch("stops").last.fetch("place_id")
    assert_equal "sotetsu-fresa-inn-ginza-nanachome", days.fetch(3).fetch("stops").first.fetch("place_id")
    assert_equal "sotetsu-fresa-inn-osaka-namba", days.fetch(13).fetch("stops").last.fetch("place_id")
    assert_equal "sotetsu-fresa-inn-osaka-namba", days.fetch(14).fetch("stops").first.fetch("place_id")
    assert_equal "sotetsu-fresa-inn-osaka-namba", days.fetch(14).fetch("stops").last.fetch("place_id")
    assert_equal "sotetsu-fresa-inn-osaka-namba", days.fetch(15).fetch("stops").first.fetch("place_id")
  end

  def test_private_location_overrides_never_enter_the_public_map
    private_coordinate = { "longitude" => 12.3456789, "latitude" => -45.6789123 }
    public_rendered = Itinerary::JourneyMapRenderer.new(@store).render
    private_rendered = Itinerary::JourneyMapRenderer.new(
      @store,
      location_overrides: { "sotetsu-fresa-inn-ginza-nanachome" => private_coordinate },
      private_output: true
    ).render
    public_payload = journey_payload(public_rendered)
    private_payload = journey_payload(private_rendered)

    public_hotel = public_payload.fetch("days").flat_map { |day| day.fetch("stops") }.find { |stop| stop.dig("place", "id") == "sotetsu-fresa-inn-ginza-nanachome" }
    private_hotel = private_payload.fetch("days").flat_map { |day| day.fetch("stops") }.find { |stop| stop.dig("place", "id") == "sotetsu-fresa-inn-ginza-nanachome" }
    refute_equal private_coordinate.fetch("longitude"), public_hotel.dig("place", "coordinates", "longitude")
    assert_equal private_coordinate.fetch("longitude"), private_hotel.dig("place", "coordinates", "longitude")
    assert_equal true, private_hotel.dig("place", "private_override")
    assert_equal true, private_payload.dig("trip", "private")
    refute_includes public_rendered, private_coordinate.fetch("longitude").to_s
    assert_includes private_rendered, private_coordinate.fetch("longitude").to_s
  end

  def test_confirmed_flights_wrap_the_complete_playback_sequence
    transitions = journey_payload(Itinerary::JourneyMapRenderer.new(@store).render).fetch("transitions")
    outbound, inbound = transitions
    assert_equal [1, 2], outbound.values_at("after_day", "before_day")
    assert_equal [15, nil], inbound.values_at("after_day", "before_day")
    assert_equal "sydney-airport-t1-international", outbound.fetch("from_place_id")
    assert_equal "narita-international-airport", outbound.fetch("to_place_id")
    assert_equal "kansai-international-airport", inbound.fetch("from_place_id")
    assert_equal "sydney-airport-t1-international", inbound.fetch("to_place_id")
  end

  def test_optional_alternatives_render_outside_the_timed_timeline
    document = REXML::Document.new(File.read(File.join(TRIP_ROOT, "index.html"), encoding: "UTF-8"))
    optional = REXML::XPath.first(document, "//*[@data-activity-id='day-14-01']")
    refute_nil optional
    assert_equal "section", optional.parent.parent.name
    assert_equal "alternatives", optional.parent.parent.attributes["class"]
    assert_nil REXML::XPath.first(document, "//ol[contains(concat(' ', @class, ' '), ' timeline ')]//*[@data-activity-id='day-14-01']")
  end

  def test_every_tooltip_button_controls_an_existing_description
    document = REXML::Document.new(File.read(File.join(TRIP_ROOT, "index.html"), encoding: "UTF-8"))
    buttons = REXML::XPath.match(document, "//button[contains(concat(' ', @class, ' '), ' info-button ')]")
    assert_operator buttons.length, :>, 100
    buttons.each do |button|
      target = button.attributes["aria-controls"].to_s
      refute_empty target
      assert REXML::XPath.first(document, "//*[@id='#{target}' and @role='tooltip']"), "Missing tooltip #{target}"
      assert_equal "false", button.attributes["aria-expanded"].to_s
      refute_empty button.attributes["aria-label"].to_s
    end
  end

  def test_validator_detects_chronological_conflicts
    issues = validate_mutation("trip.yaml") do |document|
      activity = document.fetch("days")[2].fetch("activities").find { |candidate| candidate.fetch("id") == "day-03-02" }
      activity.fetch("time")["start"] = "09:00"
    end
    assert_includes issues.map(&:code), "chronological-conflict"
  end

  def test_validator_detects_invalid_dates
    issues = validate_mutation("trip.yaml") { |document| document.fetch("days")[1]["date"] = "2026-02-30" }
    assert_includes issues.map(&:code), "invalid-date"
  end

  def test_json_schema_rejects_unknown_activity_fields
    issues = validate_mutation("trip.yaml") do |document|
      document.fetch("days")[0].fetch("activities")[0]["invented_field"] = true
    end
    assert_includes issues.map(&:code), "schema-violation"
  end

  def test_validator_detects_duplicate_entities
    issues = validate_mutation("places.yaml") do |document|
      duplicate = Marshal.load(Marshal.dump(document.fetch("places").fetch("tokyo")))
      document.fetch("places")["tokyo-duplicate"] = duplicate.merge("url" => "https://example.com/tokyo-copy")
    end
    assert_includes issues.map(&:code), "duplicate-place-name"
  end

  def test_validator_detects_booking_dependency_problems
    issues = validate_mutation("bookings.yaml") do |document|
      document.fetch("bookings")[2]["depends_on"] = ["missing-booking"]
    end
    assert_includes issues.map(&:code), "unknown-booking-dependency"
  end

  def test_validator_detects_opening_hour_risks
    issues = validate_mutation("trip.yaml") do |document|
      activity = document.fetch("days")[5].fetch("activities").find { |candidate| candidate.fetch("id") == "day-06-04" }
      activity.fetch("time")["end"] = "17:30"
    end
    assert_includes issues.map(&:code), "opening-hours-risk"
  end

  private

  def journey_payload(rendered)
    match = rendered.match(%r{<script id="journey-data" type="application/json">(.*?)</script>}m)
    refute_nil match
    JSON.parse(match[1])
  end

  def validate_mutation(filename)
    Dir.mktmpdir("itinerary-test") do |directory|
      FileUtils.cp_r(File.join(TRIP_ROOT, "data"), directory)
      FileUtils.cp_r(File.join(TRIP_ROOT, "assets"), directory)
      FileUtils.cp(File.join(TRIP_ROOT, "site.yaml"), directory)
      path = File.join(directory, "data", filename)
      document = YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false)
      yield document
      File.write(path, YAML.dump(document), encoding: "UTF-8")
      return Itinerary::Validator.new(Itinerary::DataStore.new(directory, framework_root: FRAMEWORK_ROOT)).validate
    end
  end

  def analyze_mutation(filename)
    Dir.mktmpdir("itinerary-test") do |directory|
      FileUtils.cp_r(File.join(TRIP_ROOT, "data"), directory)
      FileUtils.cp(File.join(TRIP_ROOT, "site.yaml"), directory)
      path = File.join(directory, "data", filename)
      document = YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false)
      yield document
      File.write(path, YAML.dump(document), encoding: "UTF-8")
      return Itinerary::PaceAnalyzer.new(Itinerary::DataStore.new(directory, framework_root: FRAMEWORK_ROOT))
    end
  end
end
