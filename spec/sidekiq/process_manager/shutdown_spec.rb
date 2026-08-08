# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::ProcessManager::Manager do
  # The manager is intentionally not started in these tests. The shutdown logic
  # is exercised directly against child processes that refuse to exit so that
  # no monitoring thread is running to reap them first.
  let(:manager) do
    Sidekiq::ProcessManager::Manager.new(process_count: 2, mode: :testing, silent: true)
  end

  after do
    Array(@forked_pids).each do |pid|
      ::Process.kill(:KILL, pid)
      ::Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      # The process is already gone.
    end
  end

  # Fork a child process that ignores TERM. The pipe handshake guarantees the
  # signal handler is installed before the caller signals the process; otherwise
  # the default handler could terminate it first and the test would silently
  # exercise the fast path instead.
  def fork_unresponsive_process
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      ::Signal.trap(:TERM) {}
      writer.puts("ready")
      writer.close
      sleep(30)
    end
    writer.close
    raise "child process #{pid} never became ready" unless reader.gets
    reader.close
    (@forked_pids ||= []) << pid
    pid
  end

  def fork_process(&block)
    pid = fork(&block)
    (@forked_pids ||= []) << pid
    pid
  end

  def monotonic_time
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  # Reap a process and return its exit status. waitpid2 returns the status
  # directly so this does not depend on the $CHILD_STATUS global, which is only
  # defined when the English library happens to be loaded.
  def wait_for_reap(pid, timeout = 5)
    end_time = monotonic_time + timeout
    while monotonic_time < end_time
      _, status = ::Process.waitpid2(pid, ::Process::WNOHANG)
      return status if status
      sleep(0.01)
    end
    nil
  rescue Errno::ECHILD
    nil
  end

  def process_running?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  describe "waiting for child processes to exit" do
    it "should kill and reap processes that do not exit on their own" do
      pids = 2.times.collect { fork_unresponsive_process }
      manager.instance_variable_set(:@pids, pids.dup)
      pids.each { |pid| ::Process.kill(:TERM, pid) }

      manager.send(:wait_for_children_to_exit)

      expect(manager.pids).to eq []
      pids.each do |pid|
        expect(process_running?(pid)).to eq false
      end
    end

    it "should not let a process that is slow to exit prevent others from being reaped" do
      unresponsive = fork_unresponsive_process
      quick = fork_process { sleep(0.1) }
      manager.instance_variable_set(:@pids, [unresponsive, quick])
      ::Process.kill(:TERM, unresponsive)

      remaining = manager.send(:reap_child_processes, [unresponsive, quick], monotonic_time + 2)

      # The quick process must be reaped even though it is listed after a
      # process that never exits.
      expect(remaining).to eq [unresponsive]
      expect(manager.pids).to eq [unresponsive]
    end

    it "should keep processes that were not reaped in the pid list" do
      pid = fork_unresponsive_process
      manager.instance_variable_set(:@pids, [pid])
      ::Process.kill(:TERM, pid)

      # ensure_pid_dies uses the pid list to determine liveness, so a process
      # that has not been reaped has to remain in the list for the SIGKILL
      # failsafe to fire.
      expect(manager.send(:reap_child_process, pid)).to eq false
      expect(manager.pids).to eq [pid]

      manager.send(:ensure_pid_dies, pid)

      status = wait_for_reap(pid)
      expect(status).to_not eq nil
      expect(status.termsig).to eq Signal.list["KILL"]
    end
  end
end
