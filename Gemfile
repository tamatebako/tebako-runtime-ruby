# frozen_string_literal: true

source "https://rubygems.org"

require "yaml"

# contract.yml schema validation (scripts/check_contract_version.rb).
gem "json_schemer", "~> 2.4"

# The release machinery — the legs' publish/sign jobs and the publish.yml
# coordinator's audit. tamatebako/tebako-release is the single
# owner (ecosystem invariant 10); the pin lives in contract.yml's
# release_tooling so the bump is one contract edit, never a second
# hand-written copy of the machinery.
gem "tebako-release",
    git: "https://github.com/tamatebako/tebako-release.git",
    tag: YAML.load_file(File.expand_path("contract.yml", __dir__)).fetch("release_tooling")

# The registry render (tools/registry_update.rb — the coordinator's
# release job) talks to the releases API directly.
gem "octokit", "~> 7.1"

# octokit 7.x requires base64 without declaring it; a default gem on the
# CI ruby but bundled-gems-only on 4.0+ hosts (the maintainers' local
# rubies), where the undeclared require LoadErrors.
gem "base64", "~> 0.2"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.65", require: false
end
