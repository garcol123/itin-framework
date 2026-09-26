# frozen_string_literal: true

require "optparse"
require_relative "../itinerary"

module Itinerary
  module CLI
    module_function

    def framework_root
      File.expand_path("../..", __dir__)
    end

    def add_trip_option(parser, options)
      parser.on("--trip PATH", "Trip instance directory") { |value| options[:trip] = value }
    end

    def resolve_trip(value)
      abort "Missing --trip TRIP_PATH." unless value

      path = File.expand_path(value)
      abort "Trip path does not exist: #{path}" unless File.directory?(path)
      abort "Trip path is missing site.yaml: #{path}" unless File.file?(File.join(path, "site.yaml"))
      path
    end

    def store(path)
      DataStore.new(path, framework_root: framework_root)
    rescue ArgumentError => error
      abort error.message
    end
  end
end
