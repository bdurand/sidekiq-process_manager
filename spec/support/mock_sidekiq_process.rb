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

    while running? do
      sleep(0.01)
    end
  end

  def running?
    @running
  end

end
