# frozen_string_literal: true

require "time"

module Runearc
  # @api private
  module Support
    # A +Time+ becomes the RFC 3339 string the API wants; anything else is returned as given.
    def self.time(value)
      value.is_a?(Time) ? value.getutc.iso8601(3) : value
    end

    # Percent-encodes one path segment.
    def self.segment(value)
      value.to_s.b.gsub(/[^A-Za-z0-9\-_.~]/n) { |byte| format("%%%02X", byte.ord) }
    end
  end
end
