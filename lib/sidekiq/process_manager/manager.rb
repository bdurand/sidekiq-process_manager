# frozen_string_literal: true

require "sidekiq"
require "get_process_mem"
require "timeout"

module Sidekiq
  module ProcessManager
    # Process manager for sidekiq. This class is responsible for starting and monitoring
    # that the specified number of sidekiq processes are running. It will also forward
    # signals sent to the main process to the child processes.
    class Manager
      # Signals that are trapped by the process manager and forwarded to the child processes.
      SIGNALS = [:INT, :TERM, :USR1, :USR2, :TSTP, :TTIN].freeze

      # Number of seconds between memory checks when a max memory is set.
      DEFAULT_MEMORY_CHECK_INTERVAL = 60

      attr_reader :cli

      # Create a new process manager.
      #
      # @param process_count [Integer] The number of sidekiq processes to start.
      # @param prefork [Boolean] If true, the process manager will load the application before forking.
      # @param preboot [String] If set, the process manager will require the specified file before forking the child processes.
      # @param memory_check_interval [Numeric] The number of seconds between memory checks
      #   when a max memory is set.
      # @param child_termination_timeout [Numeric] The number of seconds to wait for a child
      #   to exit after TERM before killing it. Defaults to Sidekiq's shutdown timeout.
      # @param mode [Symbol] If set to :testing, the process manager will use a mock CLI.
      # @param silent [Boolean] If true, the process manager will not output any messages.
      def initialize(process_count: 1, prefork: false, preboot: nil, max_memory: nil, memory_check_interval: nil, child_termination_timeout: nil, mode: nil, silent: false)
        require "sidekiq/cli"

        # Get the number of processes to fork
        @process_count = process_count
        raise ArgumentError.new("Process count must be greater than 0") if @process_count < 1

        @prefork = prefork && process_count > 1
        @preboot = preboot if process_count > 1 && !prefork
        @max_memory = ((max_memory.to_i > 0) ? max_memory.to_i : nil)

        if !memory_check_interval.nil? && memory_check_interval.to_f <= 0
          raise ArgumentError.new("Memory check interval must be greater than 0")
        end

        if !child_termination_timeout.nil?
          timeout = child_termination_timeout.to_f
          unless timeout.finite? && timeout > 0
            raise ArgumentError.new("Child termination timeout must be greater than 0")
          end
        end
        @child_termination_timeout = child_termination_timeout&.to_f

        if mode == :testing
          require_relative "../../../spec/support/mocks"
          @cli = MockSidekiqCLI.new(silent)
          @memory_check_interval = (memory_check_interval || 1).to_f
          @exit_grace_period = 0.5
        else
          @cli = Sidekiq::CLI.instance
          @memory_check_interval = (memory_check_interval || DEFAULT_MEMORY_CHECK_INTERVAL).to_f
          @exit_grace_period = 5
        end

        @silent = silent
        @pids = []
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
              signal = @signal_pipe_read.gets
              break if signal.nil?

              signal = signal.strip
              send_signal_to_children(signal.to_sym)
            rescue => e
              log_warning("Error sending signal #{signal} to child processes: #{e.message}")
            end
          end
        end

        # Trap signals that will be forwarded to child processes
        SIGNALS.each do |signal|
          ::Signal.trap(signal) do
            if ::Process.pid == master_pid
              signal = :TERM if signal == :INT
              @signal_pipe_write.puts(signal)
            end
          end
        end

        # Ensure that child processes receive the term signal when the master process exits.
        at_exit do
          if ::Process.pid == master_pid
            if @process_count > 0
              send_signal_to_children(:TERM)
            end
            wait_for_children_to_exit
            log_info("Process manager exiting")
          end
        end

        GC.start
        GC.compact if GC.respond_to?(:compact)
        # I'm not sure why, but running GC operations blocks until we try to write some I/O.
        File.write(File::NULL, "0")

        @process_count.times do
          start_child_process!
        end

        start_memory_monitor if @max_memory

        log_info("Process manager started")
        monitor_child_processes
      end

      # Helper to wait on the manager to wait on child processes to start up.
      #
      # @param timeout [Integer] The number of seconds to wait for child processes to start.
      # @return [void]
      def wait(timeout = 5)
        timeout_time = monotonic_time + timeout
        while monotonic_time <= timeout_time
          return if pids.size == @process_count
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
        $PROGRAM_NAME = "sidekiq process manager #{sidekiq_options[:tag]} [#{pids.size} processes]"
      end

      def start_child_process!
        pid = fork do
          # Child processes inherit the signal handlers installed by the process
          # manager. Those handlers only do anything in the master process, so
          # leaving them in place would silently discard any signal sent to the
          # child before sidekiq installs its own handlers. Restore the default
          # behavior until then so signals are never swallowed.
          SIGNALS.each do |signal|
            ::Signal.trap(signal, "DEFAULT")
          end

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
        shutting_down = false
        @mutex.synchronize do
          @pids << pid
          shutting_down = @process_count < 1
        end
        log_info("Forked sidekiq process with pid #{pid}")
        # A shutdown signal may have been forwarded to the other processes while
        # this one was being forked; it needs to get the signal as well.
        send_signal_to_pid(:TERM, pid) if shutting_down
        set_program_name!
      end

      def send_signal_to_children(signal)
        log_info("Process manager trapped signal #{signal}")
        child_pids = @mutex.synchronize do
          @process_count = 0 if signal == :INT || signal == :TERM
          @pids.dup
        end
        child_pids.each do |pid|
          send_signal_to_pid(signal, pid)
        end
      end

      def send_signal_to_pid(signal, pid)
        signal = signal.to_sym
        begin
          log_info("Sending signal #{signal} to sidekiq process #{pid}")
          ::Process.kill(signal, pid)
          if [:TERM, :INT].include?(signal)
            Thread.new do
              Thread.current.name = "pid-#{pid}-killer"
              ensure_pid_dies(pid)
            end
          end
        rescue Errno::ESRCH
          # The process is already dead
        end
      end

      def start_memory_monitor
        log_info("Starting memory monitor with max memory #{(@max_memory / (1024**2)).round}mb checked every #{@memory_check_interval} seconds")

        @memory_monitor = Thread.new do
          Thread.current.name = "memory-monitor"
          loop do
            sleep(@memory_check_interval)

            pids.each do |pid|
              memory = GetProcessMem.new(pid)
              if memory.bytes > @max_memory
                log_warning("Killing bloated sidekiq process #{pid}: #{memory.mb.round}mb used")
                send_signal_to_pid(:TERM, pid)
                break
              end
            rescue => e
              log_warning("Error monitoring memory for sidekiq process #{pid}: #{e.inspect}")
            end
          end
        end
      end

      def stop_memory_monitor
        if defined?(@memory_monitor) && @memory_monitor
          @memory_monitor.kill
        end
      end

      def wait_for_children_to_exit
        # Allow the SIGKILL failsafe in ensure_pid_dies time to fire before giving up on a process.
        remaining = reap_child_processes(pids, monotonic_time + child_termination_timeout + @exit_grace_period)

        unless remaining.empty?
          # Don't leave orphaned processes behind. These pids were never reaped,
          # so the operating system cannot have reused them for another process
          # and it is safe to signal them.
          remaining.each do |pid|
            ::Process.kill(:KILL, pid)
            log_warning("Sidekiq process #{pid} failed to exit; killed with SIGKILL")
          rescue Errno::ESRCH
            # The process is already dead
          end

          # SIGKILL cannot be caught or ignored, so the processes will exit, but
          # not necessarily by the time the signal is sent. Wait for them so they
          # are not left behind as zombies.
          remaining = reap_child_processes(remaining, monotonic_time + @exit_grace_period)
        end

        if remaining.empty?
          log_info("All sidekiq processes have exited")
        else
          log_warning("Gave up waiting on sidekiq processes: #{remaining.join(", ")}")
        end
      end

      # Reap child processes as they exit until they have all been reaped or the
      # deadline passes.
      #
      # @return [Array<Integer>] The pids that were not reaped.
      def reap_child_processes(child_pids, deadline)
        remaining = child_pids.dup
        until remaining.empty?
          # Poll all of the processes on each pass so that one slow process
          # cannot consume the entire timeout waiting for the others.
          remaining.delete_if { |pid| reap_child_process(pid) }
          break if remaining.empty? || monotonic_time >= deadline
          sleep(0.01)
        end
        remaining
      end

      # Reap a child process if it has exited. The pid is only removed from the
      # list of running processes when it is actually reaped so that the SIGKILL
      # failsafe in ensure_pid_dies still sees it as running until then.
      #
      # @return [Boolean] true if the process has been reaped or is no longer a child process.
      def reap_child_process(pid)
        reaped = begin
          # The monitoring loop may no longer be running, so reap the child
          # process here rather than just polling for it to disappear.
          ::Process.waitpid(pid, ::Process::WNOHANG)
        rescue Errno::ECHILD, Errno::ESRCH
          # The process has already been reaped.
          pid
        end
        return false unless reaped

        @mutex.synchronize { @pids.delete(pid) }
        true
      end

      def child_termination_timeout
        @child_termination_timeout || (sidekiq_options[:timeout] || 25).to_f
      end

      def ensure_pid_dies(pid)
        # Wait for the process to die, or kill it after a timeout. A pid is
        # removed from the list only once it has been reaped, so the list is the
        # source of truth for liveness; a pid still in it cannot have been reused
        # by the operating system for a different process. Checking with a system
        # call is not reliable since it cannot distinguish a recycled pid.
        end_time = monotonic_time + child_termination_timeout
        while monotonic_time < end_time && pids.include?(pid)
          sleep(0.1)
        end

        if pids.include?(pid)
          begin
            ::Process.kill(:KILL, pid)
            log_warning("Sidekiq process #{pid} failed to exit after #{child_termination_timeout} seconds; killed with SIGKILL")
          rescue Errno::ESRCH
            # The process is already dead
          end
        end
      end

      # Listen for child processes dying and restart if necessary.
      def monitor_child_processes
        loop do
          begin
            pid = ::Process.wait
          rescue Errno::ECHILD
            # All child processes are already gone.
            @mutex.synchronize { @pids.clear }
            break
          end

          # Process.wait reaps any child process, including ones spawned by
          # libraries or application code (i.e. get_process_mem shelling out
          # to ps). Only act on processes forked by the manager.
          removed = @mutex.synchronize { @pids.delete(pid) }
          next unless removed

          log_info("Sidekiq process #{pid} exited")

          # If there are not enough processes running, start a replacement one.
          if @process_count > pids.size
            start_child_process!
          end

          set_program_name!

          if pids.empty?
            break
          end
        end
      end
    end
  end
end
