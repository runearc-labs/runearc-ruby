# frozen_string_literal: true

require_relative "lib/runearc/version"

Gem::Specification.new do |spec|
  spec.name = "runearc"
  spec.version = Runearc::VERSION
  spec.authors = ["Runearc"]

  spec.summary = "Official Runearc SDK for Ruby: send and schedule email, read agent inboxes, " \
                 "manage domains, verify webhooks."
  spec.description = "Send, batch and schedule email, create inboxes your agents can read, manage domains " \
                     "and verify webhooks with the Runearc API. Standard library only."
  spec.homepage = "https://runearc.com/integrations/ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/runearc-labs/runearc-ruby"
  spec.metadata["bug_tracker_uri"] = "https://github.com/runearc-labs/runearc-ruby/issues"
  spec.metadata["documentation_uri"] = "https://runearc.com/docs/sdk"
  spec.metadata["changelog_uri"] = "https://github.com/runearc-labs/runearc-ruby/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]
end
