# frozen_string_literal: true

SIDEKIQ_MAJOR_RELEASES = ["6", "5", "4", "3"].freeze

SIDEKIQ_MAJOR_RELEASES.each do |version|
  appraise "sidekiq-#{version}" do
    gem "sidekiq", "~> #{version}.0"
    remove_gem "standard"
  end
end
