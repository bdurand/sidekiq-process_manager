# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
