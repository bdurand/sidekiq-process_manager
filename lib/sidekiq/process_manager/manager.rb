# frozen_string_literal: true

require "sidekiq"
require "get_process_mem"

module Sidekiq
  module ProcessManager
    # Process manager for sidekiq. This class is responsible for starting and monitoring
    # that the specified number of sidekiq processes are running. It will also forward
    # signals sent to the main process to the child processes.
    class Manager
      attr_reader :cli

      # Create a new process manager.
      #
      # @param process_count [Integer] The number of sidekiq processes to start.
      # @param prefork [Boolean] If true, the process manager will load the application before forking.
      # @param preboot [String] If set, the process manager will require the specified file before forking the child processes.
      # @param mode [Symbol] If set to :testing, the process manager will use a mock CLI.
      # @param silent [Boolean] If true, the process manager will not output any messages.
      def initialize(process_count: 1, prefork: false, preboot: nil, max_memory: nil, mode: nil, silent: false)
        require "sidekiq/cli"

        # Get the number of processes to fork
        @process_count = process_count
        raise ArgumentError.new("Process count must be greater than 1") if @process_count < 1

        @prefork = (prefork && process_count > 1)
        @preboot = preboot if process_count > 1 && !prefork
        @max_memory = ((max_memory.to_i > 0) ? max_memory.to_i : nil)

        if mode == :testing
          require_relative "../../../spec/support/mocks"
          @cli = MockSidekiqCLI.new(silent)
          @memory_check_interval = 1
        else
          @cli = Sidekiq::CLI.instance
          @memory_check_interval = 60
        end

        @silent = silent
        @pids = []
        @terminated_pids = []
        @started = false
        @mutex = Mutex.new
      end

      # Start the process manager. This method will start the specified number
      # of sidekiq processes and monitor them. It will only exit once all child
      # processes have exited. If a child process dies unexpectedly, it will be
      # restarted.
      #
      # Child processes are manged by sending the signals you would normally send
      # to a sidekiq process to the process manager instead.
      #
      # @return [void]
      def start
        raise "Process manager already started" if started?
        @started = true

        load_sidekiq

        master_pid = ::Process.pid

        @signal_pipe_read, @signal_pipe_write = IO.pipe

        @signal_thread = Thread.new do
          Thread.current.name = "signal-handler"

          while @signal_pipe_read.wait_readable
            begin
              signal = @signal_pipe_read.gets.strip
              send_signal_to_children(signal.to_sym)
            rescue => e
              log_error("Error handling signal #{signal}: #{e.message}")
            end
          end
        end

        # Trap signals that will be forwarded to child processes
        [:INT, :TERM, :USR1, :USR2, :TSTP, :TTIN].each do |signal|
          ::Signal.trap(signal) do
            if ::Process.pid == master_pid
              @signal_pipe_write.puts(signal)
            end
          end
        end

        # Ensure that child processes receive the term signal when the master process exits.
        at_exit do
          if ::Process.pid == master_pid && @process_count > 0
            send_signal_to_children(:TERM)
          end
        end

        GC.start
        GC.compact if GC.respond_to?(:compact)
        # I'm not sure why, but running GC operations blocks until we try to write some I/O.
        File.write("/dev/null", "0")

        @process_count.times do
          start_child_process!
        end

        start_memory_monitor if @max_memory

        log_info("Process manager started with pid #{::Process.pid}")
        monitor_child_processes
        log_info("Process manager #{::Process.pid} exiting")
      end

      # Helper to wait on the manager to wait on child processes to start up.
      #
      # @param timeout [Integer] The number of seconds to wait for child processes to start.
      # @return [void]
      def wait(timeout = 5)
        timeout_time = monotonic_time + timeout
        while monotonic_time <= timeout_time
          return if @pids.size == @process_count
          sleep(0.01)
        end

        raise Timeout::Error.new("child processes failed to start in #{timeout} seconds")
      end

      # Helper to gracefully stop all child processes.
      #
      # @return [void]
      def stop
        stop_memory_monitor
        @process_count = 0
        send_signal_to_children(:TSTP)
        send_signal_to_children(:TERM)
      end

      # Get all chile process pids.
      #
      # @return [Array<Integer>]
      def pids
        @mutex.synchronize { @pids.dup }
      end

      # Return true if the process manager has started.
      #
      # @return [Boolean]
      def started?
        @started
      end

      private

      def log_info(message)
        return if @silent
        if $stderr.tty?
          $stderr.write("#{message}#{$/}")
          $stderr.flush
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

      def monotonic_time
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end

      def sidekiq_options
        if Sidekiq.respond_to?(:default_configuration)
          Sidekiq.default_configuration
        else
          Sidekiq.options
        end
      end

      def load_sidekiq
        @cli.parse

        # Disable daemonization and pidfile creation for child processes (sidekiq < 6.0)
        if Gem::Version.new(Sidekiq::VERSION) < Gem::Version.new("6.0")
          sidekiq_options[:daemon] = false
          sidekiq_options[:pidfile] = false
        end

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
        $PROGRAM_NAME = "sidekiq process manager #{sidekiq_options[:tag]} [#{@pids.size} processes]"
      end

      def start_child_process!
        pid = fork do
          # Set $0 so instrumentation libraries detecting sidekiq from the command run will work properly.
          $0 = File.join(File.dirname($0), "sidekiq")
          @process_count = 0
          @pids.clear
          @signal_thread.kill
          @signal_pipe_read.close
          @signal_pipe_write.close
          Sidekiq::ProcessManager.run_after_fork_hooks
          @cli.run
        end
        @mutex.synchronize { @pids << pid }
        log_info("Forked sidekiq process with pid #{pid}")
        set_program_name!
      end

      def send_signal_to_children(signal)
        log_info("Process manager trapped signal #{signal}")
        @process_count = 0 if signal == :INT || signal == :TERM
        pids.each do |pid|
          begin
            log_info("Sending signal #{signal} to sidekiq process #{pid}")
            ::Process.kill(signal, pid)
          rescue => e
            log_warning("Error sending signal #{signal} to sidekiq process #{pid}: #{e.inspect}")
          end
        end
        wait_for_children_to_exit(pids) if @process_count == 0
      end

      def start_memory_monitor
        log_info("Starting memory monitor with max memory #{(@max_memory / (1024**2)).round}mb")

        @memory_monitor = Thread.new do
          Thread.current.name = "memory-monitor"
          loop do
            sleep(@memory_check_interval)

            pids.each do |pid|
              begin
                memory = GetProcessMem.new(pid)
                if memory.bytes > @max_memory
                  log_warning("Kill bloated sidekiq process #{pid}: #{memory.mb.round}mb used")
                  begin
                    ::Process.kill(:TERM, pid)
                  rescue Errno::ESRCH
                    # The process is already dead
                  end
                  break
                end
              rescue => e
                log_warning("Error monitoring memory for sidekiq process #{pid}: #{e.inspect}")
              end
            end
          end
        end
      end

      def stop_memory_monitor
        if defined?(@memory_monitor) && @memory_monitor
          @memory_monitor.kill
        end
      end

      def wait_for_children_to_exit(pids)
        timeout = monotonic_time + (sidekiq_options[:timeout] || 25).to_f
        pids.each do |pid|
          while monotonic_time < timeout
            break unless process_alive?(pid)
            sleep(0.01)
          end
        end

        pids.each do |pid|
          begin
            ::Process.kill(:INT, pid) if process_alive?(pid)
          rescue
            # Ignore errors so we can continue to kill other processes.
          end
        end
      end

      def process_alive?(pid)
        begin
          ::Process.getpgid(pid)
          true
        rescue Errno::ESRCH
          false
        end
      end

      # Listen for child processes dying and restart if necessary.
      def monitor_child_processes
        loop do
          pid = ::Process.wait
          @mutex.synchronize { @pids.delete(pid) }

          log_info("Sidekiq process #{pid} exited")

          # If there are not enough processes running, start a replacement one.
          if @process_count > @pids.size
            start_child_process!
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
