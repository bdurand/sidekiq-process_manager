# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - Unreleased

### Added
- Sidekiq 7 support.
- Max memory setting to automatically restart processes suffering from memory bloat.

### Removed
- Sidekiq 3 support.
- Ruby 2.3 and 2.4 support.

## [1.0.4] - 2021-05-20

### Fixed
- Set $0 to "sidekiq" in preforked process so instrumentation libraries detecting sidekiq server from the command line will work.

## [1.0.3] - 2021-05-19

### Fixed
- Restore bin dir to gem distribution.

## [1.0.2] - 2021-05-19

### Added
- Support for sidekiq >= 6.1.
- Set $0 to "sidekiq" so instrumentation libraries detecting sidekiq server from the command line will work.

### Changed
- Minimum Ruby version 2.3.

## [1.0.1] - 2020-02-20

### Changed
- Remove auto require of `sidekiq/cli` so `require: false` does not need to be specified in a Gemfile.

## [1.0.0] - 2019-11-27

### Added
- Initial release.
