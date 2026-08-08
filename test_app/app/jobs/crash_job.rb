# frozen_string_literal: true

# Kills the sidekiq process running it. The process manager should notice the
# dead child and immediately fork a replacement.
class CrashJob
  include TestApp::JOB_MODULE

  sidekiq_options queue: "default", retry: false

  # @param mode ["kill", "exit", "raise"] how the process should go down.
  #   "kill" simulates an external SIGKILL (i.e. the OOM killer), "exit"
  #   simulates the process exiting on its own, and "raise" is an ordinary job
  #   failure that should *not* restart anything.
  def perform(mode = "kill")
    TestApp.log("CrashJob taking down this process with mode #{mode.inspect}")

    case mode.to_s
    when "kill"
      ::Process.kill("KILL", ::Process.pid)
    when "exit"
      exit!(1)
    when "raise"
      raise "CrashJob failed on purpose"
    else
      raise ArgumentError.new("Unknown crash mode #{mode.inspect}")
    end
  end
end
