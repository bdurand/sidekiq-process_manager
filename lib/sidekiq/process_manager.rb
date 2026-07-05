# frozen_string_literal: true

require_relative "process_manager/version"
require_relative "process_manager/manager"

module Sidekiq
  module ProcessManager
    class << self
      def before_fork(&block)
        @before_fork ||= []
        @before_fork << block
      end

      def after_fork(&block)
        @after_fork ||= []
        @after_fork << block
      end

      def run_before_fork_hooks
        if defined?(@before_fork) && @before_fork
          @before_fork.each do |block|
            block.call
          end
        end
        @before_fork = nil
      end

      def run_after_fork_hooks
        if defined?(@after_fork) && @after_fork
          @after_fork.each do |block|
            block.call
          end
        end
        @after_fork = nil
      end

      # Parse a max memory value into a number of bytes. The value can be a plain
      # number of bytes or a number suffixed with "m" for megabytes or "g" for
      # gigabytes (case insensitive).
      #
      # @param value [String, nil] The value to parse.
      # @return [Float, nil] The number of bytes or nil if the value is blank.
      # @raise [ArgumentError] If the value cannot be parsed.
      def parse_max_memory(value)
        value = value.to_s.strip
        return nil if value.empty?

        matched = value.match(/\A(\d+(?:\.\d+)?)([mg]?)\z/i)
        raise ArgumentError.new("Invalid max memory value: #{value.inspect}") unless matched

        bytes = matched[1].to_f
        case matched[2].downcase
        when "m"
          bytes *= 1024**2
        when "g"
          bytes *= 1024**3
        end

        bytes
      end
    end
  end
end
