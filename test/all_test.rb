# frozen_string_literal: true

Dir[File.expand_path("*_test.rb", __dir__)].sort.each do |path|
  next if File.basename(path) == File.basename(__FILE__)
  require path
end
