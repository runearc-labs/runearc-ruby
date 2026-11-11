# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "securerandom"
require "runearc"
require_relative "support/stack"
require_relative "support/http_stub"

Minitest.after_run { Stack.stop }

# Helpers for tests that talk to the real API.
module ApiHelpers
  def stack
    Stack.info
  end

  def client(key = stack.api_key, **options)
    Runearc::Client.new(key, base_url: stack.api_url, **options)
  end

  # A simulated recipient: delivered (or bounced/complained) without an MTA.
  def test_address(local = "delivered")
    "#{local}@#{stack.test_domain}"
  end

  def from(local = "app")
    "SDK Tests <#{local}@#{stack.domain}>"
  end

  def unique(prefix)
    "#{prefix} #{Time.now.to_i.to_s(36)}#{SecureRandom.hex(3)}"
  end

  # Polls the block until it returns something truthy.
  def eventually(seconds = 15)
    deadline = Time.now + seconds
    last = nil
    while Time.now < deadline
      begin
        value = yield
        return value if value
      rescue Runearc::Error => e
        last = e
      end
      sleep 0.15
    end
    flunk "condition not met in #{seconds} s#{": #{last.message}" if last}"
  end
end

Minitest::Test.include(ApiHelpers)

# Sets environment variables for the block and restores them.
def with_env(vars)
  saved = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  vars.each { |k, v| ENV[k] = v }
  yield
ensure
  saved.each { |k, v| ENV[k] = v }
end
