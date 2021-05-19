# frozen_string_literal: true

class MockApplication
  attr_reader :hooks

  def initialize(output: nil, silent: false)
    @hooks = []
    @output = output
    @silent = silent
  end

  def start
    Sidekiq::ProcessManager.before_fork do
      record_hook(:before_fork_1)
    end

    Sidekiq::ProcessManager.before_fork do
      record_hook(:before_fork_2)
    end

    Sidekiq::ProcessManager.after_fork do
      record_hook(:after_fork_1)
    end

    Sidekiq::ProcessManager.after_fork do
      record_hook(:after_fork_2)
    end
  end

  private

  def record_hook(message)
    @hooks << message
    if @output
      @output.write("pid(#{::Process.pid}): #{message}\n")
      @output.flush
    end
    if $stdout.tty? && !@silent
      $stdout.write("pid(#{::Process.pid}): #{message}\n")
      $stdout.flush
    end
  end
end
