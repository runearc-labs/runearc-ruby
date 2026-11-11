# frozen_string_literal: true

require "json"
require "openssl"

module Runearc
  # Standard Webhooks verification (https://www.standardwebhooks.com). Mirrors
  # +runearc_core::webhooks::sign+:
  #
  #   signature = "v1," + base64(HMAC-SHA256(base64decode(secret without "whsec_"),
  #                                          "{webhook-id}.{webhook-timestamp}.{body}"))
  module Webhook
    # Signatures older or newer than this many seconds are refused (replay protection).
    TOLERANCE_SECONDS = 5 * 60

    HEADER_NAMES = %w[webhook-id webhook-timestamp webhook-signature].freeze
    private_constant :HEADER_NAMES

    # Checks that a webhook request came from Runearc and is fresh, then returns the parsed event.
    #
    # @param payload [String] the raw request body, exactly as received; do not parse it and serialize it again
    # @param headers [Hash, #[]] the request headers: a Hash with keys in any case (or Rack style
    #   +HTTP_WEBHOOK_ID+ keys), or any object that answers +headers["webhook-id"]+
    # @param secret [String] the endpoint's signing secret, +whsec_...+, from +webhooks.create+
    # @param tolerance [Integer] seconds of clock difference allowed (default 300)
    # @param now [Integer, nil] for tests: the current time in seconds since the epoch
    # @return [Hash] the event: +:id+, +:type+, +:timestamp+ and +:data+ (symbol keys)
    # @raise [WebhookVerificationError] when the payload is not a genuine, fresh Runearc webhook;
    #   its +code+ is +missing_headers+, +invalid_timestamp+, +timestamp_out_of_range+, +invalid_secret+,
    #   +invalid_signature+ or +invalid_payload+
    def self.verify(payload:, headers:, secret:, tolerance: TOLERANCE_SECONDS, now: nil)
      id, timestamp, signatures = HEADER_NAMES.map { |name| header(headers, name) }
      if [id, timestamp, signatures].any? { |v| v.nil? || v.empty? }
        raise WebhookVerificationError.new(
          "the webhook-id, webhook-timestamp and webhook-signature headers are required",
          code: "missing_headers",
          fix: "Pass the request headers unchanged; check that a proxy does not strip them"
        )
      end
      check_timestamp(timestamp, tolerance, now || Time.now.to_i)

      body = payload.to_s.b
      expected = OpenSSL::HMAC.digest("SHA256", decode_secret(secret), "#{id}.#{timestamp}.".b + body)
      raise_invalid_signature unless signatures.split.any? { |part| match?(part, expected) }

      parse(body)
    end

    def self.check_timestamp(timestamp, tolerance, now)
      unless timestamp.strip.match?(/\A\d+\z/)
        raise WebhookVerificationError.new(
          "webhook-timestamp is not a number of seconds", code: "invalid_timestamp"
        )
      end
      return if (now - timestamp.to_i).abs <= tolerance

      raise WebhookVerificationError.new(
        "the webhook timestamp is more than #{tolerance} seconds from now",
        code: "timestamp_out_of_range",
        fix: "Check your server clock; old deliveries are refused to stop replays"
      )
    end

    def self.decode_secret(secret)
      secret.to_s.strip.delete_prefix("whsec_").unpack1("m0")
    rescue ArgumentError
      raise WebhookVerificationError.new(
        "the webhook secret is not valid base64",
        code: "invalid_secret",
        fix: "Use the secret returned by webhooks.create, which starts with whsec_"
      )
    end

    def self.match?(part, expected)
      version, sig = part.split(",", 2)
      return false unless version == "v1" && sig

      given = sig.unpack1("m0")
      given.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(given, expected)
    rescue ArgumentError
      false
    end

    def self.raise_invalid_signature
      raise WebhookVerificationError.new(
        "no webhook-signature matches the payload",
        code: "invalid_signature",
        fix: "Verify the raw body (not JSON parsed and serialized again) with this endpoint's whsec_ secret"
      )
    end

    def self.parse(body)
      JSON.parse(body.dup.force_encoding(Encoding::UTF_8), symbolize_names: true)
    rescue JSON::ParserError
      raise WebhookVerificationError.new("the webhook body is not JSON", code: "invalid_payload")
    end

    def self.header(headers, name)
      value = lookup(headers, name)
      value = value.join(" ") if value.is_a?(Array)
      value&.to_s
    end

    def self.lookup(headers, name)
      return headers[name] unless headers.is_a?(Hash)

      wanted = name.tr("-", "_")
      headers.each do |key, value|
        return value if key.to_s.downcase.delete_prefix("http_").tr("-", "_") == wanted
      end
      nil
    end

    private_class_method :check_timestamp, :decode_secret, :match?, :raise_invalid_signature, :parse, :header, :lookup
  end

  # Same as {Webhook.verify}.
  #
  # @return [Hash]
  def self.verify_webhook(**kwargs)
    Webhook.verify(**kwargs)
  end
end
