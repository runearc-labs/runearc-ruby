# frozen_string_literal: true

module Runearc
  # Every failure the SDK reports. API errors carry the API's +code+, +message+ and +fix+;
  # failures before a response arrives use +status+ 0 and the codes +network_error+,
  # +timeout+, +missing_api_key+ or, for webhooks, +invalid_signature+ and friends.
  #
  # Rescue +Runearc::Error+ for everything, or one of its subclasses:
  #
  #   Error
  #   +-- ConfigurationError        no API key (status 0)
  #   +-- ConnectionError           no response arrived (status 0)
  #   |   +-- TimeoutError
  #   +-- WebhookVerificationError  not a genuine, fresh Runearc webhook (status 0)
  #   +-- ApiError                  the API answered with an error
  #       +-- InvalidRequestError   400
  #       +-- AuthenticationError   401
  #       +-- LimitReachedError     402
  #       +-- PermissionError       403
  #       +-- NotFoundError         404
  #       +-- ConflictError         409
  #       +-- RateLimitError        429
  #       +-- ServerError           5xx
  class Error < StandardError
    # @return [Integer] the HTTP status, or 0 when no response arrived
    attr_reader :status

    # @return [String] a stable machine readable code, such as +"invalid_from"+ or +"rate_limited"+
    attr_reader :code

    # @return [String, nil] the error kind: +"invalid"+, +"unauthorized"+, +"limit_reached"+, +"forbidden"+,
    #   +"not_found"+, +"conflict"+, +"rate_limited"+, +"unavailable"+ or +"internal"+ (derived from the
    #   status when the API sends none), or +"connection"+ when no response arrived
    attr_reader :kind

    # @return [String, nil] what to do about it, when there is something you can do
    attr_reader :fix

    # @return [Array<Hash>, nil] +invalid_batch+ only: every refused item (+:index+, +:code+, +:message+, +:fix+)
    attr_reader :errors

    # @return [Integer, nil] seconds the API asked us to wait (+Retry-After+), when it sent one
    attr_reader :retry_after

    # @param message [String, nil]
    # @param status [Integer]
    # @param code [String]
    # @param kind [String, nil]
    # @param fix [String, nil]
    # @param errors [Array<Hash>, nil]
    # @param retry_after [Integer, nil]
    def initialize(message = nil, status: 0, code: "error", kind: nil, fix: nil, errors: nil, retry_after: nil)
      super(message || code)
      @status = status
      @code = code
      @kind = kind
      @fix = fix
      @errors = errors
      @retry_after = retry_after
    end

    # @return [Hash] the error as plain data, for logging or a JSON response
    def to_h
      { name: self.class.name, status: status, code: code, kind: kind, message: message, fix: fix,
        errors: errors }.compact
    end
  end

  # No API key was given and +RUNEARC_API_KEY+ is not set. Code +missing_api_key+.
  class ConfigurationError < Error
    def initialize(message = nil, **fields)
      super(message, code: "missing_api_key", kind: "invalid", **fields)
    end
  end

  # No response arrived: the network failed. Code +network_error+.
  class ConnectionError < Error
    def initialize(message = nil, **fields)
      super(message, code: "network_error", kind: "connection", **fields)
    end
  end

  # No response arrived within the per attempt timeout. Code +timeout+.
  class TimeoutError < ConnectionError
    def initialize(message = nil, **fields)
      super(message, code: "timeout", **fields)
    end
  end

  # Raised by {Webhook.verify} when a payload is not a genuine, fresh Runearc webhook.
  class WebhookVerificationError < Error
    def initialize(message = nil, **fields)
      super(message, kind: "invalid", **fields)
    end
  end

  # The API answered with an error status.
  class ApiError < Error
    # Builds the error class for a failed response, chosen by its status.
    #
    # @param message [String]
    # @param status [Integer]
    # @return [ApiError]
    def self.build(message, status:, **fields)
      kind = fields.delete(:kind) || default_kind(status)
      class_for(status).new(message, status: status, kind: kind, **fields)
    end

    def self.class_for(status)
      case status
      when 400 then InvalidRequestError
      when 401 then AuthenticationError
      when 402 then LimitReachedError
      when 403 then PermissionError
      when 404 then NotFoundError
      when 409 then ConflictError
      when 429 then RateLimitError
      when 500.. then ServerError
      else ApiError
      end
    end

    def self.default_kind(status)
      case status
      when 401 then "unauthorized"
      when 402 then "limit_reached"
      when 403 then "forbidden"
      when 404 then "not_found"
      when 409 then "conflict"
      when 429 then "rate_limited"
      when 503 then "unavailable"
      when 500.. then "internal"
      else "invalid"
      end
    end

    private_class_method :class_for, :default_kind
  end

  # 400: the request was refused as invalid.
  class InvalidRequestError < ApiError; end

  # 401: the API key is missing, wrong or revoked.
  class AuthenticationError < ApiError; end

  # 402: a plan limit was reached.
  class LimitReachedError < ApiError; end

  # 403: the key may not do this.
  class PermissionError < ApiError; end

  # 404: no such resource.
  class NotFoundError < ApiError; end

  # 409: the request conflicts with the current state, for example a reused idempotency key.
  class ConflictError < ApiError; end

  # 429: rate limited. {Error#retry_after} has the wait the API asked for.
  class RateLimitError < ApiError; end

  # 5xx: the API failed.
  class ServerError < ApiError; end
end
