# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added
- The process manager's child termination timeout can now be configured independently from Sidekiq's shutdown timeout with `--child-termination-timeout` or `SIDEKIQ_PROCESS_MANAGER_CHILD_TERMINATION_TIMEOUT`.

## 1.1.3

### Added
- The interval between memory checks can now be set with the `--memory-check-interval` command line argument or the `SIDEKIQ_MEMORY_CHECK_INTERVAL` environment variable. It still defaults to 60 seconds.

### Fixed
- Child processes now reset the signal handlers inherited from the process manager to their default behavior when they are forked. The inherited handlers do nothing outside of the master process, so any signal sent to a child process before sidekiq installed its own handlers was silently discarded and the process would only be stopped by the SIGKILL failsafe.
- Fixed race condition where a child process forked to replace a dead process while a TERM or INT signal was being handled would never receive the shutdown signal, leaving the process manager hung waiting on it.
- Child processes are now reaped while waiting for them to exit at shutdown, with a timeout, so the process manager can no longer hang forever waiting on zombie processes if it exits abnormally. All processes are polled on each pass so that one slow process cannot consume the entire timeout, and any that are still running when the timeout expires are killed with SIGKILL and reaped rather than being orphaned.
- Child processes spawned by libraries or application code (e.g. `ps` invoked by the get_process_mem gem) are no longer mistaken for sidekiq processes by the process monitor.
- The SIGKILL failsafe now uses the manager's list of running processes to determine liveness instead of a system call, removing the possibility of signaling an unrelated process if the operating system reuses a process id.
- The signal handling thread exits cleanly instead of busy-looping if the signal pipe is closed.
- Fixed the validation error message when the process count is less than one.
- The `sidekiq-process-manager` command line now accepts a max memory value in plain bytes and aborts with an error message on invalid values instead of silently ignoring them.

## 1.1.2

### Added
- Added thread to monitor child processes to make sure they exit after a SIGTERM signal has been sent. If a process does not exit after the configured Sidekiq timeout time, then it will be killed with a SIGKILL signal.

### Changed
- A SIGINT sent to the manager process will sent SIGTERM to the child processes to give them a chance to shutdown gracefully.

## 1.1.1

### Added
- Guards to ensure signal processing thread doesn't die.

## 1.1.0

### Added
- Sidekiq 7 support.
- Max memory setting to automatically restart processes suffering from memory bloat.
- Use a notification pipe to handle signals (@KevinCarterDev)

### Removed
- Sidekiq < 5.0 support.
- Ruby < 2.5 support.

## 1.0.4

### Fixed
- Set $0 to "sidekiq" in preforked process so instrumentation libraries detecting sidekiq server from the command line will work.

## 1.0.3

### Fixed
- Restore bin dir to gem distribution.

## 1.0.2

### Added
- Support for sidekiq >= 6.1.
- Set $0 to "sidekiq" so instrumentation libraries detecting sidekiq server from the command line will work.

### Changed
- Minimum Ruby version 2.3.

## 1.0.1

### Changed
- Remove auto require of `sidekiq/cli` so `require: false` does not need to be specified in a Gemfile.

## 1.0.0

### Added
- Initial release.
