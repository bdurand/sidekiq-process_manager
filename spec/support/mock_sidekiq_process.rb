# frozen_string_literal: true

class MockSidekiqProcess
  attr_reader :pid, :signals, :application

  def initialize(application)
    @pid = ::Process.pid
    @application = application
    @signals = []
    @running = false
  end

  def run
    @running = true

    [:INT, :TERM, :USR1, :USR2, :TSTP, :TTIN].each do |signal|
      ::Signal.trap(signal) do
        @signals << signal
        if signal == :INT || signal == :TERM
          @running = false
        end
      end
    end

    timeout_time = monotonic_time + 10
    while running?
      sleep(0.01)
      if monotonic_time > timeout_time
        @running = false
      end
    end
  end

  def running?
    @running
  end

  private

  def monotonic_time
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
