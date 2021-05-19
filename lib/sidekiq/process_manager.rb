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
    end
  end
end
