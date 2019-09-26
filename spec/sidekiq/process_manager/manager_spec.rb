# frozen_string_literal: true

require "spec_helper"

describe Sidekiq::ProcessManager::Manager do

  let!(:manager) do
    manager = Sidekiq::ProcessManager::Manager.new(process_count: process_count, prefork: prefork, preboot: preboot, mode: :testing, silent: true)
    Thread.new { manager.start }
    manager.wait(1)
    manager
  end

  let(:prefork) { false }
  let(:preboot) { nil }
  let(:process_count) { 2 }

  after do
    manager.stop
    manager.wait(5)
  end

  describe "managing processes" do
    it "should start a specified number of processes" do
      expect(manager.pids.size).to eq 2
    end

    it "should forward signals to child processes" do
      signals = [:USR1, :USR2, :TSTP, :TTIN]
      signals.each do |signal|
        ::Process.kill(signal, ::Process.pid)
      end
      manager.pids.each do |pid|
        manager.cli.processes.each do |process|
          expect(process.signals).to match_array(signals)
        end
      end
    end

    it "should exit when all child processes have terminated with an INT signal" do
      ::Process.kill(:INT, ::Process.pid)
      manager.wait
      expect(manager.pids.size).to eq 0
    end

    it "should exit when all child processes have terminated with a TERM signal" do
      ::Process.kill(:TERM, ::Process.pid)
      manager.wait
      expect(manager.pids.size).to eq 0
    end

    it "should restart child processes if they unexpectedly die" do
      pids = manager.pids
      kill_pid = pids.first
      keep_pid = pids.last
      ::Process.kill(:TERM, kill_pid)
      sleep(1)
      manager.wait
      expect(manager.pids.size).to eq 2
      expect(manager.pids).to_not include(kill_pid)
      expect(manager.pids).to include(keep_pid)
    end

    it "should not be able to start the process manager twice" do
      expect { manager.start }.to raise_error("Process manager already started")
    end
  end

  describe "without pre-forking processes" do
    it "should not preload the application" do
      expect(manager.cli.application).to eq nil
    end

    it "should not call before or after fork hooks on the child processes" do
      manager.pids.each do |pid|
        expect(manager.cli.output_for(pid)).to eq []
      end
    end
  end

  describe "with pre-forking processes" do
    let(:prefork) { true }

    it "should preload the application" do
      expect(manager.cli.application).to_not eq nil
    end

    it "should call before fork hooks on the parent process" do
      expect(manager.cli.application.hooks).to eq [:before_fork_1, :before_fork_2]
    end

    it "should call after fork hooks on the child processes" do
      manager.pids.each do |pid|
        expect(manager.cli.output_for(pid)).to eq ["after_fork_1", "after_fork_2"]
      end
    end
  end

  describe "with pre-booting code" do
    let(:preboot) do
      file = Tempfile.new(["preboot", ".rb"])
      file.write("$prebooted = true")
      file.flush
      file.path
    end

    after(:each) do
      $prebooted = false
      File.unlink(preboot)
    end

    it "should load the config/boot.rb file" do
      manager
      expect($prebooted).to eq true
    end

    it "should not call before or after fork hooks on the child processes" do
      manager.pids.each do |pid|
        expect(manager.cli.output_for(pid)).to eq []
      end
    end
  end

end

