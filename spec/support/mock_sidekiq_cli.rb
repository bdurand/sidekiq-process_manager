# frozen_string_literal: true

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

  def run
    unless Sidekiq::CLI.instance.public_methods.include?(:run)
      raise 'Sidekiq::CLI#run not defined'
    end
    $PROGRAM_NAME = "mock sidekiq"
    boot_system
    process = MockSidekiqProcess.new(@application)
    @processes[process.pid] = process
    process.run
  end

  def parse
    unless Sidekiq::CLI.instance.public_methods.include?(:parse)
      raise 'Sidekiq::CLI#parse not defined'
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

  def boot_system
    return if @application

    unless Sidekiq::CLI.instance.methods.include?(:boot_system) || Sidekiq::CLI.instance.private_methods.include?(:boot_system)
      raise 'Sidekiq::CLI#boot_system not defined'
    end

    @application = MockApplication.new(output: @pipe_writer, silent: @silent)
    @application.start
  end

  def read_process_output!
    begin
      loop { @process_output << @pipe_reader.read_nonblock(4096) }
    rescue IO::EAGAINWaitReadable
      return
    end
  end

end