# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Sidekiq >= 6.1 is now supported
- Set $0 to "sidekiq" so instrumentation libraries detecting sidekiq server from the command will work.

## [1.0.1] - 2020-02-20
### Changed
- Remove auto require of `sidekiq/cli` so `require: false` does not need to be specified in a Gemfile.

## [1.0.0] - 2019-11-27

- Initial release