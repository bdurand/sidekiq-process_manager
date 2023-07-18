# frozen_string_literal: true

module Sidekiq
  module ProcessManager
    VERSION = File.read(File.expand_path("../../../VERSION", __dir__)).strip
  end
end
