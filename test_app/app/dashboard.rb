# frozen_string_literal: true

require "json"
require_relative "process_monitor"

module TestApp
  # Rack application that shows the current state of the sidekiq processes
  # managed by sidekiq-process_manager. It serves a single page that polls
  # /data.json a couple of times a second, and accepts posts to /enqueue from
  # the controls on that page.
  class Dashboard
    POLL_INTERVAL = 2

    # More than enough for the handful of options an enqueue request carries.
    MAX_REQUEST_SIZE = 4096

    def initialize
      @monitor = ProcessMonitor.new
      @max_memory = Sidekiq::ProcessManager.parse_max_memory(ENV["SIDEKIQ_MAX_MEMORY"])
      @memory_check_interval = ENV.fetch(
        "SIDEKIQ_MEMORY_CHECK_INTERVAL",
        Sidekiq::ProcessManager::Manager::DEFAULT_MEMORY_CHECK_INTERVAL
      ).to_f
    end

    def call(env)
      case env["PATH_INFO"]
      when "", "/"
        respond(200, "text/html; charset=utf-8", HTML)
      when "/data.json"
        respond(200, "application/json", JSON.generate(payload))
      when "/enqueue"
        return respond(405, "text/plain; charset=utf-8", "Method not allowed") unless env["REQUEST_METHOD"] == "POST"

        enqueue(env)
      else
        respond(404, "text/plain; charset=utf-8", "Not found")
      end
    end

    private

    def payload
      @monitor.snapshot.merge(
        poll_interval: POLL_INTERVAL,
        max_memory_mb: @max_memory ? (@max_memory / (1024.0**2)).round : nil,
        memory_check_interval: (@memory_check_interval > 0) ? @memory_check_interval : nil,
        process_count: ENV["SIDEKIQ_PROCESSES"]&.to_i
      )
    end

    def enqueue(env)
      params = JSON.parse(env["rack.input"].read(MAX_REQUEST_SIZE).to_s)
      raise ArgumentError.new("Invalid request") unless params.is_a?(Hash)

      message = Enqueuer.call(params["job"], params)
      respond(200, "application/json", JSON.generate(ok: true, message: message))
    rescue JSON::ParserError
      respond(400, "application/json", JSON.generate(ok: false, message: "Could not parse request"))
    rescue ArgumentError => e
      respond(422, "application/json", JSON.generate(ok: false, message: e.message))
    rescue => e
      respond(500, "application/json", JSON.generate(ok: false, message: e.message))
    end

    def respond(status, content_type, body)
      [status, {"content-type" => content_type, "cache-control" => "no-store"}, [body]]
    end

    HTML = <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Sidekiq Process Manager</title>
        <style>
          :root {
            color-scheme: dark;
            --bg: #14161a;
            --panel: #1c1f26;
            --border: #2c313b;
            --text: #e6e9ef;
            --muted: #8b93a3;
            --green: #4ec9a5;
            --amber: #e2b341;
            --red: #e2685f;
            --blue: #6aa6f8;
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            padding: 24px;
            background: var(--bg);
            color: var(--text);
            font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          }
          h1 { font-size: 18px; margin: 0; }
          h2 { font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); margin: 0 0 10px; }
          header { display: flex; align-items: baseline; gap: 16px; flex-wrap: wrap; margin-bottom: 20px; }
          header .meta { color: var(--muted); font-size: 12px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          section { margin-bottom: 24px; }
          .panel { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 16px; }
          .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 12px; }
          .stat { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 12px 14px; }
          .stat .label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
          .stat .value { font-size: 22px; font-variant-numeric: tabular-nums; margin-top: 4px; }
          table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
          th { text-align: left; font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); font-weight: 500; padding: 0 10px 8px 0; }
          td { padding: 9px 10px 9px 0; border-top: 1px solid var(--border); }
          tr.dead td { color: var(--muted); }
          tr.fresh td { background: rgba(78, 201, 165, 0.10); }
          tr td { transition: background 1.2s ease; }
          .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 8px; vertical-align: middle; }
          .dot.live { background: var(--green); }
          .dot.quiet { background: var(--amber); }
          .dot.dead { background: var(--red); }
          .bar { position: relative; height: 6px; width: 120px; background: var(--border); border-radius: 3px; overflow: hidden; margin-top: 5px; }
          .bar > span { position: absolute; left: 0; top: 0; bottom: 0; background: var(--blue); }
          .bar > span.warn { background: var(--amber); }
          .bar > span.hot { background: var(--red); }
          .empty { color: var(--muted); padding: 8px 0; }
          .pulse { display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: var(--green); margin-right: 6px; }
          .pulse.stale { background: var(--red); }
          .controls { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px; align-items: stretch; }
          .control {
            display: flex; flex-direction: column; gap: 12px; background: rgba(0,0,0,0.18);
            border: 1px solid var(--border); border-radius: 6px; padding: 14px;
          }
          .control-name { font-weight: 600; }
          .control-note { display: block; margin-top: 3px; color: var(--muted); font-size: 12px; }
          .control-fields { display: flex; flex-direction: column; gap: 8px; flex: 1; }
          .control label { display: flex; flex-direction: column; gap: 4px; color: var(--muted); font-size: 12px; }
          .control input, .control select {
            width: 100%; background: var(--bg); color: var(--text); border: 1px solid var(--border);
            border-radius: 4px; padding: 6px 8px; font: inherit; font-size: 13px; font-variant-numeric: tabular-nums;
          }
          .control input:focus, .control select:focus { outline: 1px solid var(--blue); border-color: var(--blue); }
          .control button {
            background: var(--blue); color: #10131a; border: 0; border-radius: 4px;
            padding: 8px 14px; font: inherit; font-weight: 600; font-size: 13px; cursor: pointer;
          }
          .control button:hover { filter: brightness(1.12); }
          .control button:disabled { opacity: 0.5; cursor: default; }
          .control[data-job="crash"] button, .control[data-job="clear"] button { background: var(--amber); }
          .control-result { margin-top: 14px; min-height: 20px; font-size: 13px; color: var(--green); }
          .control-result.error { color: var(--red); }
          .settings { display: flex; flex-wrap: wrap; gap: 8px 24px; margin-top: 10px; padding-top: 12px; border-top: 1px solid var(--border); }
          .settings div { font-size: 12px; }
          .settings .label { color: var(--muted); margin-right: 6px; }
        </style>
      </head>
      <body>
        <header>
          <h1>Sidekiq Process Manager</h1>
          <div class="meta"><span class="pulse" id="pulse"></span><span id="updated">connecting…</span></div>
          <div class="meta" id="redis"></div>
        </header>

        <section class="stats" id="stats"></section>

        <section>
          <h2>Enqueue jobs</h2>
          <div class="panel">
            <div class="controls">
              <form class="control" data-job="memory">
                <div>
                  <span class="control-name">MemoryHogJob</span>
                  <span class="control-note">Allocates memory it never releases</span>
                </div>
                <div class="control-fields">
                  <label>jobs <input type="number" name="count" value="10" min="1" max="500" step="1"></label>
                  <label>mb each <input type="number" name="megabytes" value="25" min="1" max="500" step="1"></label>
                  <label>hold seconds <input type="number" name="hold" value="0" min="0" max="300" step="1"></label>
                </div>
                <button type="submit">Enqueue</button>
              </form>
              <form class="control" data-job="sleep">
                <div>
                  <span class="control-name">SleepJob</span>
                  <span class="control-note">Harmless busy work</span>
                </div>
                <div class="control-fields">
                  <label>jobs <input type="number" name="count" value="10" min="1" max="500" step="1"></label>
                  <label>seconds each <input type="number" name="seconds" value="10" min="0" max="300" step="1"></label>
                </div>
                <button type="submit">Enqueue</button>
              </form>
              <form class="control" data-job="crash">
                <div>
                  <span class="control-name">CrashJob</span>
                  <span class="control-note">Takes down the process running it</span>
                </div>
                <div class="control-fields">
                  <label>jobs <input type="number" name="count" value="1" min="1" max="500" step="1"></label>
                  <label>how it dies
                    <select name="mode">
                      <option value="kill">kill &mdash; SIGKILL, like an OOM kill</option>
                      <option value="exit">exit &mdash; process exits on its own</option>
                      <option value="raise">raise &mdash; job fails, no restart</option>
                    </select>
                  </label>
                </div>
                <button type="submit">Enqueue</button>
              </form>
              <form class="control" data-job="clear">
                <div>
                  <span class="control-name">Queue</span>
                  <span class="control-note">Drop everything still waiting to run</span>
                </div>
                <div class="control-fields"></div>
                <button type="submit">Clear</button>
              </form>
            </div>
            <div class="control-result" id="control-result"></div>
          </div>
        </section>

        <section>
          <h2>Process manager <span class="meta">&mdash; settings from .env</span></h2>
          <div class="panel">
            <div class="mono" id="manager">Waiting for data…</div>
            <div class="settings" id="settings"></div>
          </div>
        </section>

        <section>
          <h2>Sidekiq processes</h2>
          <div class="panel">
            <table>
              <thead>
                <tr>
                  <th>PID</th><th>Status</th><th>Uptime</th><th>Threads</th><th>Memory</th><th>Queues</th><th>Identity</th>
                </tr>
              </thead>
              <tbody id="processes"></tbody>
            </table>
            <div class="empty" id="processes-empty" hidden>No sidekiq processes are running.</div>
          </div>
        </section>

        <section>
          <h2>Restarts observed</h2>
          <div class="panel">
            <table>
              <thead>
                <tr><th>PID</th><th>Exited</th><th>Lifetime</th><th>Peak memory</th><th>Identity</th></tr>
              </thead>
              <tbody id="history"></tbody>
            </table>
            <div class="empty" id="history-empty">No processes have exited while this page has been open.</div>
          </div>
        </section>

        <script>
          const seen = new Map();
          let firstLoad = true;

          const fmtDuration = (seconds) => {
            if (seconds == null || isNaN(seconds)) return "—";
            seconds = Math.max(0, Math.round(seconds));
            if (seconds < 60) return seconds + "s";
            const m = Math.floor(seconds / 60), s = seconds % 60;
            if (m < 60) return m + "m " + s + "s";
            const h = Math.floor(m / 60);
            return h + "h " + (m % 60) + "m";
          };

          const fmtAgo = (timestamp, now) => timestamp ? fmtDuration(now - timestamp) + " ago" : "—";
          const fmtMb = (mb) => (mb == null) ? "—" : mb.toFixed(1) + " mb";

          const memoryBar = (mb, limit) => {
            if (mb == null || !limit) return "";
            const pct = Math.min(100, (mb / limit) * 100);
            const cls = pct > 90 ? "hot" : (pct > 70 ? "warn" : "");
            return '<div class="bar"><span class="' + cls + '" style="width:' + pct.toFixed(1) + '%"></span></div>';
          };

          const el = (id) => document.getElementById(id);

          const renderStats = (data) => {
            const alive = data.processes.filter((p) => p.alive).length;
            const stats = data.stats || {};
            const cards = [
              ["Processes", alive],
              ["Restarts", data.history.length],
              ["Busy threads", stats.busy ?? "—"],
              ["Enqueued", stats.enqueued ?? "—"],
              ["Processed", stats.processed ?? "—"],
              ["Failed", stats.failed ?? "—"]
            ];
            el("stats").innerHTML = cards.map(([label, value]) =>
              '<div class="stat"><div class="label">' + label + '</div><div class="value">' + value + "</div></div>"
            ).join("");
          };

          const renderManager = (data) => {
            if (data.manager) {
              el("manager").innerHTML =
                "pid " + data.manager.pid + " &middot; " + fmtMb(data.manager.rss_mb) + " rss<br>" +
                '<span style="color:var(--muted)">' + escapeHtml(data.manager.command) + "</span>";
            } else {
              el("manager").textContent =
                "No process manager detected. The sidekiq processes are either not running or were not forked by sidekiq-process-manager.";
            }

            const settings = [
              ["processes", data.process_count || "—"],
              ["max memory", data.max_memory_mb ? data.max_memory_mb + " mb" : "not set"],
              ["memory check interval", data.memory_check_interval ? data.memory_check_interval + "s" : "—"]
            ];
            el("settings").innerHTML = settings.map(([label, value]) =>
              '<div><span class="label">' + label + "</span>" + escapeHtml(value) + "</div>"
            ).join("");
          };

          const escapeHtml = (value) =>
            String(value ?? "").replace(/[&<>"']/g, (c) =>
              ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

          const renderProcesses = (data) => {
            const rows = data.processes.map((p) => {
              if (!seen.has(p.identity)) seen.set(p.identity, firstLoad ? 0 : Date.now());
              const isNew = Date.now() - seen.get(p.identity) < 8000 && seen.get(p.identity) > 0;
              const status = !p.alive ? ["dead", "exited"] : (p.quiet ? ["quiet", "quiet"] : ["live", "running"]);
              return "<tr class='" + (p.alive ? "" : "dead") + (isNew ? " fresh" : "") + "'>" +
                '<td class="mono">' + p.pid + "</td>" +
                '<td><span class="dot ' + status[0] + '"></span>' + status[1] + "</td>" +
                "<td>" + fmtDuration(p.uptime) + "</td>" +
                "<td>" + p.busy + " / " + p.concurrency + "</td>" +
                "<td>" + fmtMb(p.rss_mb) + memoryBar(p.rss_mb, data.max_memory_mb) + "</td>" +
                "<td>" + escapeHtml(p.queues.join(", ")) + "</td>" +
                '<td class="mono" style="color:var(--muted)">' + escapeHtml(p.identity) + "</td>" +
                "</tr>";
            });
            el("processes").innerHTML = rows.join("");
            el("processes-empty").hidden = rows.length > 0;
          };

          const renderHistory = (data) => {
            const now = data.generated_at;
            el("history").innerHTML = data.history.map((h) =>
              "<tr>" +
              '<td class="mono">' + h.pid + "</td>" +
              "<td>" + fmtAgo(h.exited_at, now) + "</td>" +
              "<td>" + fmtDuration(h.lifetime) + "</td>" +
              "<td>" + fmtMb(h.max_rss_mb) + "</td>" +
              '<td class="mono" style="color:var(--muted)">' + escapeHtml(h.identity) + "</td>" +
              "</tr>"
            ).join("");
            el("history-empty").hidden = data.history.length > 0;
          };

          const poll = async () => {
            try {
              const response = await fetch("/data.json", { cache: "no-store" });
              const data = await response.json();
              renderStats(data);
              renderManager(data);
              renderProcesses(data);
              renderHistory(data);
              el("redis").textContent = data.redis_url + " @ " + data.hostname;
              el("updated").textContent = "updated " + new Date().toLocaleTimeString();
              el("pulse").classList.remove("stale");
              firstLoad = false;
            } catch (error) {
              el("updated").textContent = "dashboard cannot reach the server";
              el("pulse").classList.add("stale");
            }
          };

          const showResult = (message, isError) => {
            const result = el("control-result");
            result.textContent = message;
            result.classList.toggle("error", !!isError);
          };

          document.querySelectorAll(".control").forEach((form) => {
            form.addEventListener("submit", async (event) => {
              event.preventDefault();
              const button = form.querySelector("button");
              const body = { job: form.dataset.job };
              form.querySelectorAll("input, select").forEach((field) => {
                body[field.name] = field.value;
              });

              button.disabled = true;
              try {
                const response = await fetch("/enqueue", {
                  method: "POST",
                  headers: { "content-type": "application/json" },
                  body: JSON.stringify(body)
                });
                const data = await response.json();
                showResult(data.message, !data.ok);
              } catch (error) {
                showResult("Could not reach the server", true);
              } finally {
                button.disabled = false;
              }
              poll();
            });
          });

          poll();
          setInterval(poll, #{POLL_INTERVAL * 1000});
        </script>
      </body>
      </html>
    HTML
  end
end
