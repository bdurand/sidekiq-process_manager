# frozen_string_literal: true

require "sidekiq"
require "sidekiq/util"

module Sidekiq
  module ProcessManager
    class Manager
      include Sidekiq::Util

      attr_reader :cli

      def initialize(process_count: 1, prefork: false, preboot: nil, mode: nil, silent: false)
        require "sidekiq/cli"

        # Get the number of processes to fork
        @process_count = process_count
        raise ArgumentError.new("Process count must be greater than 1") if @process_count < 1

        @prefork = (prefork && process_count > 1)
        @preboot = preboot if process_count > 1 && !prefork

        if mode == :testing
          require_relative "../../../spec/support/mocks"
          @cli = MockSidekiqCLI.new(silent)
        else
          @cli = Sidekiq::CLI.instance
        end

        @silent = silent
        @pids = []
        @terminated_pids = []
        @started = false
        @monitor = Monitor.new
      end

      # Start the process manager. This method will start the specified number
      # of sidekiq processes and monitor them. It will only exit once all child
      # processes have exited. If a child process dies unexpectedly, it will be
      # restarted.
      #
      # Child processes are manged by sending the signals you would normally send
      # to a sidekiq process to the process manager instead.
      def start
        raise "Process manager already started" if started?
        @started = true

        load_sidekiq

        master_pid = ::Process.pid

        signal_pipe_read, signal_pipe_write = IO.pipe

        # Trap signals that will be forwarded to child processes
        [:INT, :TERM, :USR1, :USR2, :TSTP, :TTIN].each do |signal|
          ::Signal.trap(signal) do
            signal_pipe_write.puts(signal) if ::Process.pid == master_pid
          end
        end

        @signal_thread = safe_thread("signal_handler") do
          while signal_pipe_read.wait_readable
            signal = signal_pipe_read.gets.strip
            send_signal_to_children(signal.to_sym)
          end
        end

        # Ensure that child processes receive the term signal when the master process exits.
        at_exit do
          if ::Process.pid == master_pid && @process_count > 0
            @pids.each do |pid|
              send_signal_to_children(:TERM)
            end
          end
        end

        @process_count.times do
          start_child_process!
        end

        log_info("Process manager started with pid #{::Process.pid}")
        monitor_child_processes
        log_info("Process manager #{::Process.pid} exiting")
      end

      # Helper to wait on the manager to wait on child processes to start up.
      def wait(timeout = 5)
        start_time = Time.now
        while Time.now < start_time + timeout
          return if @pids.size == @process_count
          sleep(0.01)
        end

        raise Timeout::Error.new("child processes failed to start in #{timeout} seconds")
      end

      # Helper to gracefully stop all child processes.
      def stop
        @process_count = 0
        send_signal_to_children(:TSTP)
        send_signal_to_children(:TERM)
      end

      def pids
        @pids.dup
      end

      def started?
        @started
      end

      private

      def log_info(message)
        return if @silent
        if $stdout.tty?
          $stdout.write("#{message}#{$/}")
          $stdout.flush
        else
          Sidekiq.logger.info(message)
        end
      end

      def log_warning(message)
        return if @silent
        if $stderr.tty?
          $stderr.write("#{message}#{$/}")
          $stderr.flush
        else
          Sidekiq.logger.warn(message)
        end
      end

      def load_sidekiq
        @cli.parse
        Sidekiq.options[:daemon] = false
        Sidekiq.options[:pidfile] = false
        if @prefork
          log_info("Pre-forking application")
          # Set $0 so instrumentation libraries detecting sidekiq from the command run will work properly.
          save_command_line = $0
          $0 = File.join(File.dirname($0), "sidekiq")
          # Prior to sidekiq 6.1 the method to boot the application was boot_system
          if @cli.methods.include?(:boot_application) || @cli.private_methods.include?(:boot_application)
            @cli.send(:boot_application)
          else
            @cli.send(:boot_system)
          end
          $0 = save_command_line
          Sidekiq::ProcessManager.run_before_fork_hooks
        elsif @preboot && !@preboot.empty?
          if ::File.exist?(@preboot)
            require ::File.expand_path(@preboot).sub(/\.rb\Z/, "")
          else
            log_warning("Could not find preboot file #{@preboot}")
          end
        end
      end

      def set_program_name!
        $PROGRAM_NAME = "sidekiq process manager #{Sidekiq.options[:tag]} [#{@pids.size} processes]"
      end

      def start_child_process!
        @pids << fork do
          # Set $0 so instrumentation libraries detecting sidekiq from the command run will work properly.
          $0 = File.join(File.dirname($0), "sidekiq")
          @process_count = 0
          @pids.clear
          Sidekiq::ProcessManager.run_after_fork_hooks
          @cli.run
        end
        log_info("Forked sidekiq process with pid #{@pids.last}")
        set_program_name!
      end

      def send_signal_to_children(signal)
        log_info("Process manager trapped signal #{signal}")
        @process_count = 0 if signal == :INT || signal == :TERM
        @pids.each do |pid|
          begin
            log_info("Sending signal #{signal} to sidekiq process #{pid}")
            ::Process.kill(signal, pid)
          rescue => e
            log_warning("Error sending signal #{signal} to sidekiq process #{pid}: #{e.inspect}")
          end
        end
      end

      # Listen for child processes dying and restart if necessary.
      def monitor_child_processes
        loop do
          pid = ::Process.wait
          @pids.delete(pid)
          log_info("Sidekiq process #{pid} exited")

          # If there are not enough processes running, start a replacement one.
          if @process_count > @pids.size
            start_child_process! if @pids.size < @process_count
          end

          set_program_name!

          if @pids.empty?
            break
          end
        end
      end
    end
  end
end
