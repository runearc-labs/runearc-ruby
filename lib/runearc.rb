# frozen_string_literal: true

require_relative "runearc/version"

# The official Ruby SDK for the Runearc email API. Start with {Runearc::Client}.
module Runearc
  # The API origin used when neither +base_url:+ nor +RUNEARC_BASE_URL+ is set.
  DEFAULT_BASE_URL = "https://api.runearc.com"
end

require_relative "runearc/errors"
require_relative "runearc/support"
require_relative "runearc/webhook"
require_relative "runearc/resources"
require_relative "runearc/client"
