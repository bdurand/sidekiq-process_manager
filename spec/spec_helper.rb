# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" if File.exist?(ENV["BUNDLE_GEMFILE"])

begin
  require "simplecov"
  SimpleCov.start do
    skip ["/spec/"]
  end
rescue LoadError
end

Bundler.require(:default, :test)

require "tempfile"

require_relative "../lib/sidekiq-process_manager"
require_relative "support/mocks"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end

Sidekiq.logger.level = :error
sidekiq_options = (Sidekiq.respond_to?(:default_configuration) ? Sidekiq.default_configuration : Sidekiq.options)
sidekiq_options[:timeout] = 0.1
