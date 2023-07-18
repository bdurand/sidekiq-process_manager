source "https://rubygems.org"

# Cover security vulnerability of not loading github gems over HTTPS (just in case...)
git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

gemspec

gem "rake"
gem "rspec", "~>3.0"
gem "appraisal"
gem "standard", "~>1.0", require: false
