# frozen_string_literal: true

require "json"
require "socket"

module TestApp
  # Gathers the current state of the sidekiq processes for the dashboard.
  #
  # Sidekiq's own process set is the starting point, but it is only refreshed by
  # a heartbeat every few seconds and dead processes linger in it for up to a
  # minute. Since everything here runs on one machine, the operating system is
  # consulted directly so a process that just died shows up as gone right away.
  class ProcessMonitor
    # Redis hash tracking every process the dashboard has ever seen, so
    # restarts remain visible after the process is gone.
    HISTORY_KEY = "test_app:process_history"

    # Number of exited processes to keep in the restart log.
    HISTORY_LIMIT = 25

    def snapshot
      processes = sidekiq_processes
      ps = ps_table(processes.map { |process| process[:pid] })

      processes.each do |process|
        info = ps[process[:pid]]
        process[:alive] = !info.nil?
        if info
          process[:rss_mb] = (info[:rss_kb] / 1024.0).round(1)
          process[:ppid] = info[:ppid]
        end
      end

      processes.sort_by! { |process| [process[:alive] ? 0 : 1, process[:started_at].to_f] }

      {
        generated_at: Time.now.to_f,
        redis_url: TestApp::REDIS_URL,
        hostname: hostname,
        manager: manager_process(processes),
        processes: processes,
        history: record_history(processes),
        stats: stats
      }
    end

    private

    def hostname
      @hostname ||= Socket.gethostname
    end

    def sidekiq_processes
      Sidekiq::ProcessSet.new.map do |process|
        started_at = process["started_at"].to_f
        beat = process["beat"].to_f
        {
          identity: process["identity"],
          pid: process["pid"].to_i,
          hostname: process["hostname"],
          tag: process["tag"],
          queues: Array(process["queues"]),
          concurrency: process["concurrency"].to_i,
          busy: process["busy"].to_i,
          quiet: (process["quiet"].to_s == "true"),
          started_at: started_at,
          uptime: (started_at > 0) ? (Time.now.to_f - started_at) : nil,
          beat_age: (beat > 0) ? (Time.now.to_f - beat) : nil,
          # Sidekiq reports rss in kilobytes as part of its heartbeat. It is
          # replaced with a live reading below for processes on this host.
          rss_mb: (process["rss"].to_i > 0) ? (process["rss"].to_i / 1024.0).round(1) : nil,
          alive: nil,
          ppid: nil
        }
      end
    rescue => e
      warn("Error reading sidekiq process set: #{e.inspect}")
      []
    end

    # The process manager is the parent of the sidekiq processes it forked.
    def manager_process(processes)
      ppids = processes.select { |process| process[:alive] }.map { |process| process[:ppid] }.compact.uniq
      return nil unless ppids.size == 1

      pid = ppids.first
      return nil if pid <= 1

      info = ps_table([pid])[pid]
      return nil unless info

      {
        pid: pid,
        rss_mb: (info[:rss_kb] / 1024.0).round(1),
        command: info[:command]
      }
    end

    # Ask the operating system about the given pids. Returns a hash keyed by pid
    # containing only the processes that actually exist.
    def ps_table(pids)
      pids = pids.map(&:to_i).select { |pid| pid > 0 }.uniq
      return {} if pids.empty?

      table = {}
      output = `ps -o pid=,ppid=,rss=,command= -p #{pids.join(",")} 2>/dev/null`
      output.each_line do |line|
        pid, ppid, rss, command = line.strip.split(/\s+/, 4)
        next if pid.nil? || command.nil?

        table[pid.to_i] = {
          ppid: ppid.to_i,
          rss_kb: rss.to_i,
          command: command
        }
      end
      table
    end

    def stats
      stats = Sidekiq::Stats.new
      {
        processed: stats.processed,
        failed: stats.failed,
        enqueued: stats.enqueued,
        retries: stats.retry_size,
        scheduled: stats.scheduled_size,
        dead: stats.dead_size,
        busy: stats.workers_size
      }
    rescue => e
      warn("Error reading sidekiq stats: #{e.inspect}")
      {}
    end

    # Track every process that has been seen so processes that have gone away
    # can be listed as restarts. This is only updated while the dashboard is
    # being polled, so it shows what happened while you were watching.
    #
    # @return [Array<Hash>] the processes that have exited, most recent first.
    def record_history(processes)
      now = Time.now.to_f
      live = {}
      processes.each do |process|
        live[process[:identity]] = process if process[:alive]
      end

      Sidekiq.redis do |redis|
        entries = {}
        redis.hgetall(HISTORY_KEY).each do |identity, json|
          entries[identity] = JSON.parse(json)
        rescue JSON::ParserError
          # Ignore corrupt entries; they get overwritten or trimmed away.
        end

        updates = {}

        live.each do |identity, process|
          entry = entries[identity] || {
            "identity" => identity,
            "pid" => process[:pid],
            "first_seen" => process[:started_at].to_f.positive? ? process[:started_at].to_f : now,
            "max_rss_mb" => 0
          }
          entry["last_seen"] = now
          entry["max_rss_mb"] = [entry["max_rss_mb"].to_f, process[:rss_mb].to_f].max.round(1)
          entries[identity] = entry
          updates[identity] = entry
        end

        entries.each do |identity, entry|
          next if live.key?(identity) || entry["exited_at"]

          entry["exited_at"] = entry["last_seen"] || now
          updates[identity] = entry
        end

        updates.each do |identity, entry|
          redis.hset(HISTORY_KEY, identity, entry.to_json)
        end
        redis.expire(HISTORY_KEY, 86400) unless updates.empty?

        exited = entries.values.select { |entry| entry["exited_at"] }.sort_by { |entry| -entry["exited_at"].to_f }

        if exited.size > HISTORY_LIMIT
          stale = exited[HISTORY_LIMIT..-1].map { |entry| entry["identity"] }
          redis.hdel(HISTORY_KEY, *stale) unless stale.empty?
          exited = exited[0, HISTORY_LIMIT]
        end

        exited.map do |entry|
          {
            identity: entry["identity"],
            pid: entry["pid"],
            first_seen: entry["first_seen"],
            exited_at: entry["exited_at"],
            lifetime: entry["exited_at"].to_f - entry["first_seen"].to_f,
            max_rss_mb: entry["max_rss_mb"]
          }
        end
      end
    rescue => e
      warn("Error recording process history: #{e.inspect}")
      []
    end
  end
end
