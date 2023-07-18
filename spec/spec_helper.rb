# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" if File.exist?(ENV["BUNDLE_GEMFILE"])

Bundler.require(:default, :test)

require "tempfile"

require_relative "../lib/sidekiq-process_manager"
require_relative "support/mocks"

RSpec.configure do |config|
  config.order = :random
end

Sidekiq.logger.level = :error
sidekiq_options = (Sidekiq.respond_to?(:default_configuration) ? Sidekiq.default_configuration : Sidekiq.options)
sidekiq_options[:timeout] = 0.1
