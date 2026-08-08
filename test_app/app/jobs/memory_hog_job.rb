# frozen_string_literal: true

require "securerandom"

# A deliberately badly behaved job. Every run allocates a chunk of memory and
# holds onto it for the life of the process, so the resident memory of whatever
# sidekiq process runs it grows and never comes back down. Run enough of these
# and the process manager's --max-memory monitor will restart the process.
class MemoryHogJob
  include TestApp::JOB_MODULE

  sidekiq_options queue: "default", retry: false

  # Memory that is intentionally never released. Allocated in one megabyte
  # blocks of random bytes so nothing can be deduplicated or compressed away.
  BALLAST = []
  MUTEX = Mutex.new

  PAGE_SIZE = 4096

  # How often the retained memory is read back. An operating system will evict
  # pages that are allocated and then never looked at again, which on macOS
  # happens within about 30 seconds and would drop the process's resident
  # memory right back down to where it started. A real application that leaks
  # memory keeps using it; this thread does the same so that the ballast stays
  # resident and the memory monitor has something to react to.
  TOUCH_INTERVAL = 5

  class << self
    # Retain a block of memory and report how much this process is now holding.
    #
    # @return [Integer] total megabytes retained by this process.
    def retain(megabytes)
      chunk = Array.new(megabytes) { SecureRandom.bytes(1024 * 1024) }
      MUTEX.synchronize do
        BALLAST << chunk
        start_touch_thread
        BALLAST.sum(&:size)
      end
    end

    private

    # Read and rewrite one byte of every page of the retained memory so the
    # operating system keeps it resident. Only started once, and only once
    # there is something to keep resident.
    def start_touch_thread
      @touch_thread ||= Thread.new do
        Thread.current.name = "memory-hog-ballast"
        loop do
          sleep(TOUCH_INTERVAL)
          MUTEX.synchronize do
            BALLAST.each do |chunk|
              chunk.each do |block|
                index = 0
                while index < block.bytesize
                  block.setbyte(index, block.getbyte(index))
                  index += PAGE_SIZE
                end
              end
            end
          end
        end
      end
    end
  end

  def perform(megabytes = 25, hold_seconds = 0)
    retained = self.class.retain(megabytes.to_i)

    sleep(hold_seconds.to_f) if hold_seconds.to_f > 0

    TestApp.log("MemoryHogJob allocated #{megabytes}mb (#{retained}mb retained, #{TestApp.rss_mb}mb rss)")
  end
end
