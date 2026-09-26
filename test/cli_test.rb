# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class CliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GENERIC = File.join(ROOT, "test", "fixtures", "generic")
  TEST_TRIP = File.join(ROOT, "trips", "test-trip")

  def teardown
    FileUtils.rm_rf(TEST_TRIP) if File.expand_path(TEST_TRIP).start_with?(File.join(ROOT, "trips") + File::SEPARATOR)
  end

  def test_validate_resolves_trip_paths_and_json_output
    stdout, stderr, status = run_cli("validate", "--trip", GENERIC, "--json")
    assert status.success?, stderr
    assert_equal [], JSON.parse(stdout)

    _stdout, missing_stderr, missing_status = run_cli("validate", "--trip", "does-not-exist")
    refute missing_status.success?
    assert_match(/Trip path does not exist/, missing_stderr)
  end

  def test_new_trip_success_invalid_slug_and_overwrite_refusal
    stdout, stderr, status = run_cli("new_trip", "test-trip")
    assert status.success?, stderr
    assert File.file?(File.join(TEST_TRIP, "site.yaml"))
    assert_equal "test-trip", YAML.safe_load_file(File.join(TEST_TRIP, "site.yaml")).fetch("trip_slug")
    assert_includes File.read(File.join(TEST_TRIP, "data", "trip.yaml")), "id: test-trip"
    assert_includes stdout, "Created"

    _stdout, overwrite_stderr, overwrite_status = run_cli("new_trip", "test-trip")
    refute overwrite_status.success?
    assert_match(/already exists/, overwrite_stderr)

    _stdout, invalid_stderr, invalid_status = run_cli("new_trip", "../unsafe")
    refute invalid_status.success?
    assert_match(/Invalid trip slug/, invalid_stderr)
  end

  def test_build_writes_only_inside_selected_trip
    Dir.mktmpdir("cli-trip") do |directory|
      FileUtils.cp_r(File.join(GENERIC, "."), directory)
      stdout, stderr, status = run_cli("build", "--trip", directory)
      assert status.success?, stderr
      %w[index.html journey-map.html activity-options.html].each do |filename|
        assert File.file?(File.join(directory, filename)), filename
      end
      assert_includes stdout, directory
    end
  end

  private

  def run_cli(name, *arguments)
    Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin", name), *arguments, chdir: ROOT)
  end
end
