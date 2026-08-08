# frozen_string_literal: true

module TestApp
  # Enqueues the test jobs. Called by the dashboard controls, which post to
  # /enqueue, so every option coming in has to be validated.
  module Enqueuer
    JOBS = %w[memory crash sleep clear].freeze

    # Default options per job.
    DEFAULTS = {
      "memory" => {count: 10, megabytes: 25, hold: 0}.freeze,
      "crash" => {count: 1, mode: "kill"}.freeze,
      "sleep" => {count: 10, seconds: 10}.freeze,
      "clear" => {}.freeze
    }.freeze

    CRASH_MODES = %w[kill exit raise].freeze

    MAX_COUNT = 500
    MAX_MEGABYTES = 500
    MAX_SECONDS = 300

    class << self
      # Enqueue jobs of the given type.
      #
      # @param job [String] one of JOBS.
      # @param options [Hash] overrides for the job's DEFAULTS. Nil values are ignored.
      # @return [String] description of what was done.
      # @raise [ArgumentError] if the job or any of the options are invalid.
      def call(job, options = {})
        job = job.to_s.strip.downcase
        raise ArgumentError.new("Unknown job #{job.inspect}; must be one of #{JOBS.join(", ")}") unless JOBS.include?(job)

        options = DEFAULTS[job].merge(compact_options(options))

        case job
        when "memory"
          count = bounded_integer(options[:count], 1, MAX_COUNT, "Job count")
          megabytes = bounded_integer(options[:megabytes], 1, MAX_MEGABYTES, "Megabytes")
          hold = bounded_number(options[:hold], 0, MAX_SECONDS, "Hold seconds")
          count.times { MemoryHogJob.perform_async(megabytes, hold) }
          "Enqueued #{pluralize(count, "MemoryHogJob job")} retaining #{megabytes}mb each (#{count * megabytes}mb total)"
        when "crash"
          count = bounded_integer(options[:count], 1, MAX_COUNT, "Job count")
          mode = options[:mode].to_s
          unless CRASH_MODES.include?(mode)
            raise ArgumentError.new("Crash mode must be one of #{CRASH_MODES.join(", ")}")
          end
          count.times { CrashJob.perform_async(mode) }
          "Enqueued #{pluralize(count, "CrashJob job")} with mode #{mode}"
        when "sleep"
          count = bounded_integer(options[:count], 1, MAX_COUNT, "Job count")
          seconds = bounded_number(options[:seconds], 0, MAX_SECONDS, "Sleep seconds")
          count.times { SleepJob.perform_async(seconds) }
          "Enqueued #{pluralize(count, "SleepJob job")} sleeping #{seconds} seconds each"
        when "clear"
          queue = Sidekiq::Queue.new("default")
          size = queue.size
          queue.clear
          "Cleared #{pluralize(size, "job")} from the default queue"
        end
      end

      private

      def pluralize(count, word)
        "#{count} #{word}#{"s" unless count == 1}"
      end

      def compact_options(options)
        options.each_with_object({}) do |(key, value), hash|
          hash[key.to_sym] = value unless value.nil? || value.to_s.strip.empty?
        end
      end

      def bounded_integer(value, min, max, name)
        integer = begin
          Integer(value.to_s.strip, 10)
        rescue ArgumentError
          raise ArgumentError.new("#{name} must be a whole number")
        end
        raise ArgumentError.new("#{name} must be between #{min} and #{max}") unless integer.between?(min, max)

        integer
      end

      def bounded_number(value, min, max, name)
        number = begin
          Float(value.to_s.strip)
        rescue ArgumentError
          raise ArgumentError.new("#{name} must be a number")
        end
        raise ArgumentError.new("#{name} must be between #{min} and #{max}") unless number.between?(min, max)

        number
      end
    end
  end
end
