# frozen_string_literal: true

require "stringio"

class MockSidekiqCLI
  attr_reader :application
  attr_writer :silent

  def initialize(silent = false)
    @processes = {}
    @application = nil
    @pipe_reader, @pipe_writer = IO.pipe
    @process_output = StringIO.new
    @silent = silent
  end

  def output_for(pid)
    read_process_output!
    marker = "pid(#{pid}):"
    @process_output.string.split("\n").select { |line| line.start_with?("pid(#{pid}):") }.collect { |line| line.sub(marker, "").strip }
  end

  # Wait for a child process to write the expected number of lines. Forking a
  # child process says nothing about how far it has gotten, so the output is not
  # necessarily there the moment the pid shows up in the manager's process list.
  def wait_for_output(pid, count, timeout = 5)
    end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    output = output_for(pid)
    while output.size < count && ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) < end_time
      sleep(0.01)
      output = output_for(pid)
    end
    output
  end

  def run
    unless Sidekiq::CLI.instance.public_methods.include?(:run)
      raise "Sidekiq::CLI #{Sidekiq::VERSION} does not defined a run method"
    end
    $PROGRAM_NAME = "mock sidekiq"
    boot_mock_application
    process = MockSidekiqProcess.new(@application)
    @processes[process.pid] = process
    process.run
  rescue => e
    warn e.inpsect, e.backtrace.join("\n")
  end

  def parse
    unless Sidekiq::CLI.instance.public_methods.include?(:parse)
      raise "Sidekiq::CLI #{Sidekiq::VERSION} does not defined a parse method"
    end
  end

  def reset!
    @processes.clear
    @process_output = StringIO.new
  end

  def processes
    @processes.values
  end

  private

  class_eval <<-RUBY, __FILE__, __LINE__ + 1
    def #{(Sidekiq::VERSION.to_f < 6.0) ? "boot_system" : "boot_application"}
      boot_mock_application
    end
  RUBY

  def boot_mock_application
    return if @application
    @application = MockApplication.new(output: @pipe_writer, silent: @silent)
    @application.start
  rescue => e
    warn e.inpsect, e.backtrace.join("\n")
  end

  def read_process_output!
    loop { @process_output << @pipe_reader.read_nonblock(4096) }
  rescue IO::EAGAINWaitReadable
    nil
  end
end
