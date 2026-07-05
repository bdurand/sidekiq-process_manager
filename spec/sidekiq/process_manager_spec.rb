# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::ProcessManager do
  describe ".parse_max_memory" do
    it "should return nil for blank values" do
      expect(Sidekiq::ProcessManager.parse_max_memory(nil)).to eq nil
      expect(Sidekiq::ProcessManager.parse_max_memory("")).to eq nil
      expect(Sidekiq::ProcessManager.parse_max_memory("  ")).to eq nil
    end

    it "should parse a plain number as bytes" do
      expect(Sidekiq::ProcessManager.parse_max_memory("1048576")).to eq 1024**2
    end

    it "should parse a number with an m suffix as megabytes" do
      expect(Sidekiq::ProcessManager.parse_max_memory("512m")).to eq 512 * 1024**2
      expect(Sidekiq::ProcessManager.parse_max_memory("512M")).to eq 512 * 1024**2
      expect(Sidekiq::ProcessManager.parse_max_memory("1.5m")).to eq 1.5 * 1024**2
    end

    it "should parse a number with a g suffix as gigabytes" do
      expect(Sidekiq::ProcessManager.parse_max_memory("2g")).to eq 2 * 1024**3
      expect(Sidekiq::ProcessManager.parse_max_memory("2G")).to eq 2 * 1024**3
    end

    it "should raise an error for unparseable values" do
      expect { Sidekiq::ProcessManager.parse_max_memory("lots") }.to raise_error(ArgumentError)
      expect { Sidekiq::ProcessManager.parse_max_memory("512k") }.to raise_error(ArgumentError)
    end
  end
end
