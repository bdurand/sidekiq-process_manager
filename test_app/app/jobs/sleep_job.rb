# frozen_string_literal: true

# Harmless busy work. Useful for filling the queue so you can watch how in
# flight jobs are handled when a process is restarted or shut down.
class SleepJob
  include TestApp::JOB_MODULE

  sidekiq_options queue: "default", retry: false

  def perform(seconds = 5)
    TestApp.log("SleepJob sleeping for #{seconds} seconds")
    sleep(seconds.to_f)
    TestApp.log("SleepJob finished")
  end
end
