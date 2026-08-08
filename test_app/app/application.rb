# frozen_string_literal: true

# Entry point for the test application. This is what the sidekiq processes load
# with `-r ./app/application.rb` and what the dashboard and the enqueue command
# load to get a configured sidekiq client.

require "sidekiq"
require "sidekiq/api"
require "sidekiq-process_manager"

module TestApp
  # The port of the dedicated valkey server started by bin/run-valkey, so this
  # app never stomps on anything else running locally. Set in .env.
  REDIS_URL = "redis://localhost:#{ENV.fetch("REDIS_PORT")}"

  # Sidekiq::Job replaced Sidekiq::Worker in sidekiq 6.3. Support both so this
  # app can be run against any sidekiq version the gem supports.
  JOB_MODULE = defined?(Sidekiq::Job) ? Sidekiq::Job : Sidekiq::Worker

  class << self
    def log(message)
      $stdout.write("[test_app pid=#{::Process.pid}] #{message}#{$/}")
      $stdout.flush
    end

    # Resident memory of a process in megabytes.
    def rss_mb(pid = ::Process.pid)
      kb = `ps -o rss= -p #{pid.to_i}`.to_i
      (kb / 1024.0).round(1)
    end
  end
end

Sidekiq.configure_server do |config|
  config.redis = {url: TestApp::REDIS_URL}
end

Sidekiq.configure_client do |config|
  config.redis = {url: TestApp::REDIS_URL}
end

# These hooks only do anything when running with --prefork, since that is the
# only mode where the application is loaded before the processes are forked.
# A real application would close and reopen its database connections here.
Sidekiq::ProcessManager.before_fork do
  TestApp.log("before_fork hook: application loaded, using #{TestApp.rss_mb}mb")
end

Sidekiq::ProcessManager.after_fork do
  TestApp.log("after_fork hook: child process ready")
end

require_relative "jobs/memory_hog_job"
require_relative "jobs/crash_job"
require_relative "jobs/sleep_job"
require_relative "enqueuer"
