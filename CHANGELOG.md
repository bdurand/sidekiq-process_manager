# Unreleased

* Set $0 to "sidekiq" so instrumentation libraries detecting sidekiq server from the command will work.

# 1.0.1

* Remove auto require of `sidekiq/cli` so `require: false` does not need to be specified in a Gemfile.

# 1.0.0

* Initial release
