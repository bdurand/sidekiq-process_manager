# Test Application

A small, complete sidekiq application for exercising `sidekiq-process_manager` by hand. The specs cover the manager's behavior with mock processes; this app is for watching real sidekiq processes get forked, bloat, die, and get replaced.

It contains:

- **Three sidekiq processes** managed by `sidekiq-process-manager`.
- **`MemoryHogJob`**, which allocates memory and never lets go of it, so processes eventually cross the `--max-memory` threshold.
- **`CrashJob`**, which kills the process running it, and **`SleepJob`** for harmless busy work.
- **A rack dashboard** showing the live state of the manager and its child processes, plus a log of every process that has exited while you were watching.

## Requirements

- `docker` or `container` for the redis server. [bin/run-valkey](bin/run-valkey) starts a valkey container on its own port so this app cannot touch anything else you have running.

```bash
cd test_app
bundle install
```

The `sidekiq-process_manager` gem is loaded from the parent directory, so any changes you make to the gem take effect the next time you start the processes.

## Configuration

Everything is set in [.env](.env), which every command loads with dotenv:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SIDEKIQ_PROCESSES` | `3` | Number of sidekiq processes to fork |
| `SIDEKIQ_MAX_MEMORY` | `100m` | Restart a process once it uses more than this |
| `SIDEKIQ_MEMORY_CHECK_INTERVAL` | `5` | Seconds between memory checks; the gem defaults to 60, which is a long time to sit and watch |
| `REDIS_PORT` | `28470` | Port the valkey server listens on; used by both `bin/run-valkey` and the app |
| `PORT` | `9292` | Port for the dashboard |

Anything already set in your environment wins, so `SIDEKIQ_MAX_MEMORY=150m bin/run` overrides the file for that run.

## Running it

```bash
bin/run
```

That brings up all three pieces — the valkey server, the sidekiq processes, and the dashboard — and shuts all three back down when you `Ctrl-C` it or send it a `TERM`. If any one of them exits on its own, the other two are stopped too, so a half running stack is never mistaken for a working one. Arguments are passed through to the process manager, so `bin/run --prefork` works.

Then open http://localhost:9292. The dashboard refreshes every two seconds and draws each process's memory usage against `SIDEKIQ_MAX_MEMORY`.

The pieces also run on their own, one per terminal, which is easier to read when you care about one of them in particular:

| Command | What it starts |
| --- | --- |
| [bin/run-valkey](bin/run-valkey) | A valkey container listening on `REDIS_PORT` |
| [bin/sidekiq](bin/sidekiq) | The process manager and its sidekiq processes; extra arguments go to `sidekiq-process-manager`, so `bin/sidekiq --prefork` or `bin/sidekiq --max-memory 150m` work as expected |
| [bin/ui](bin/ui) | The dashboard, bound to localhost since its controls enqueue jobs |

### Enqueuing jobs

Each job has its own card in the dashboard's "Enqueue jobs" panel, with its own settings and its own button:

| Card | What it does |
| --- | --- |
| `MemoryHogJob` | Retains a block of memory per job, forever. Set how many jobs, how many megabytes each retains, and how long each stays busy afterwards |
| `SleepJob` | Busy work that just sleeps, for filling the threads |
| `CrashJob` | Takes down the process running it, by SIGKILL, by exiting, or by raising an ordinary job failure |
| Queue | Drops everything still waiting to run |

The "Process manager" panel below shows the memory limit and check interval currently configured in `.env`, so you can see what the numbers you are enqueuing have to beat.

## What to look for

**Restart after a crash.** `CrashJob` is the fastest way to see the core behavior. The manager logs `Sidekiq process <pid> exited` followed immediately by `Forked sidekiq process with pid <new pid>`, and the dashboard swaps the dead pid for a new one with a fresh uptime.

**Restart from memory bloat.** Enqueue enough `MemoryHogJob` jobs to push each process past the limit shown in the "Process manager" panel. The jobs spread across all three processes, so what matters is roughly `megabytes × jobs ÷ 3` per process. The manager logs `Killing bloated sidekiq process <pid>: 128mb used` and forks a replacement. Watch the memory column climb across all three processes and then drop back to baseline as each is recycled. Only one process is killed per check, so with `SIDEKIQ_MEMORY_CHECK_INTERVAL=5` they go down about five seconds apart rather than all at once.

`MemoryHogJob` reads back the memory it is holding every few seconds. That is not incidental: an operating system evicts pages that are allocated and then never touched again — on macOS within about thirty seconds — which would drop resident memory right back to where it started and leave the memory monitor with nothing to react to. A real application that leaks memory keeps using it, and so does this job.

**Graceful shutdown.** Enqueue 9 `SleepJob` jobs of 5 seconds, then hit `Ctrl-C` in the terminal running `bin/run` (or `bin/sidekiq`). The manager forwards `TERM` to every child, each child finishes its in-flight jobs, and the manager waits for all of them before exiting.

Now do the same thing with jobs that outlast the 10 second `timeout` in [config/sidekiq.yml](config/sidekiq.yml) — 9 sleep jobs of 30 seconds. Sidekiq pushes the unfinished jobs back onto the queue, and the process manager's failsafe steps in for processes that are still alive when the timeout expires:

```
Sidekiq process 93081 failed to exit after 10.0 seconds; killed with SIGKILL
All sidekiq processes have exited
Process manager exiting
```

Either way nothing should be left behind — `ps -ax | grep sidekiq` should come back empty.

**Signal forwarding.** Send signals to the manager pid (shown at the top of the dashboard) and they are forwarded to all three processes:

```bash
kill -TSTP <manager pid>   # quiet: stop fetching new jobs, dashboard shows "quiet"
kill -TTIN <manager pid>   # dump thread backtraces to the log
kill -TERM <manager pid>   # graceful shutdown
```

Under `bin/run` that last one stops everything, since `bin/run` takes the rest of the stack down when the manager exits. Signal `bin/run` itself to get the same result.

**Pre-forking.** `bin/run --prefork` loads the application in the manager before forking, and you will see the `before_fork` and `after_fork` hooks from [app/application.rb](app/application.rb) run. The child processes start faster and share memory with the parent through copy-on-write.

## Layout

| Path | Purpose |
| --- | --- |
| [app/application.rb](app/application.rb) | Redis configuration, fork hooks, job loading; what sidekiq loads with `-r` |
| [app/jobs/](app/jobs) | The jobs used to abuse the processes |
| [app/enqueuer.rb](app/enqueuer.rb) | Enqueues the jobs the dashboard buttons post to `/enqueue` |
| [app/process_monitor.rb](app/process_monitor.rb) | Collects process state from sidekiq and from the OS |
| [app/dashboard.rb](app/dashboard.rb) | Rack app serving the dashboard and its `/data.json` feed |
| [config/sidekiq.yml](config/sidekiq.yml) | Concurrency of 3 and a short shutdown timeout |

The dashboard determines whether a process is really alive by asking the operating system rather than trusting sidekiq's heartbeat, which lags by several seconds and leaves dead processes in the process set for up to a minute. The restart log is only updated while the page is being polled, so it shows what happened while you were watching.
