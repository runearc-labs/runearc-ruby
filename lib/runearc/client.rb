# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "time"
require "uri"

module Runearc
  # The Runearc API client. Create one and use its resources:
  #
  #   runearc = Runearc::Client.new(ENV["RUNEARC_API_KEY"])
  #   runearc.emails.deliver(from: "Acme <noreply@acme.com>", to: "bob@example.com", subject: "Hi", text: "Hi")
  #
  # Responses are the API's JSON as Hashes with symbol keys, so the API reference and the
  # SDK read the same (+:next_cursor+, +:scheduled_at+). Failures raise {Runearc::Error}.
  #
  # Every method takes the per call options +idempotency_key:+ and +request_timeout:+ (seconds).
  class Client
    # Retries after the first attempt, on 429, 5xx and network errors.
    DEFAULT_MAX_RETRIES = 2

    # Per attempt timeout in seconds.
    DEFAULT_TIMEOUT = 60

    # Longest wait between attempts, in seconds, even when +Retry-After+ asks for more.
    MAX_RETRY_WAIT = 60

    NETWORK_ERRORS = [
      SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError, Net::ProtocolError
    ].freeze
    private_constant :NETWORK_ERRORS

    TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze
    private_constant :TIMEOUT_ERRORS

    HTTP_METHODS = {
      get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch, delete: Net::HTTP::Delete
    }.freeze
    private_constant :HTTP_METHODS

    # @return [String] the API origin, without a trailing +/v1+
    attr_reader :base_url

    # @return [Integer] retries after the first attempt
    attr_reader :max_retries

    # @return [Numeric] per attempt timeout in seconds
    attr_reader :timeout

    # @return [Emails]
    attr_reader :emails
    # @return [Senders]
    attr_reader :senders
    # @return [Inboxes]
    attr_reader :inboxes
    # @return [Messages]
    attr_reader :messages
    # @return [Threads]
    attr_reader :threads
    # @return [Conversations]
    attr_reader :conversations
    # @return [Domains]
    attr_reader :domains
    # @return [Webhooks]
    attr_reader :webhooks
    # @return [Keys]
    attr_reader :keys
    # @return [Suppressions]
    attr_reader :suppressions
    # @return [Events]
    attr_reader :events

    # @param api_key [String, nil] the API key; +RUNEARC_API_KEY+ when nil
    # @param base_url [String, nil] API origin. Default +RUNEARC_BASE_URL+ or https://api.runearc.com.
    #   A trailing +/v1+ is fine.
    # @param max_retries [Integer] retries after the first attempt, on 429, 5xx and network errors (default 2)
    # @param timeout [Numeric] per attempt timeout in seconds (default 60)
    # @param headers [Hash{String => String}] extra headers sent with every request, such as +Runearc-Project+
    # @raise [ConfigurationError] when there is no API key
    def initialize(api_key = nil, base_url: nil, max_retries: DEFAULT_MAX_RETRIES, timeout: DEFAULT_TIMEOUT,
                   headers: {})
      @api_key = present(api_key) || present(ENV.fetch("RUNEARC_API_KEY", nil)) || raise(missing_key)
      base = present(base_url) || present(ENV.fetch("RUNEARC_BASE_URL", nil)) || DEFAULT_BASE_URL
      @base_url = base.sub(%r{/+\z}, "").sub(%r{/v1\z}, "")
      @max_retries = [max_retries, 0].max
      @timeout = timeout
      @headers = headers.to_h { |k, v| [k.to_s, v.to_s] }
      build_resources
    end

    # Hides the API key.
    #
    # @return [String]
    def inspect
      "#<#{self.class.name} base_url=#{base_url.inspect}>"
    end

    # Every API call goes through here.
    #
    # @api private
    # @return [Hash, Array, String, nil] the parsed JSON, the body when +text+, or nil for an empty body
    def request(method, path, query: nil, body: nil, headers: nil, sends_mail: false, idempotent: false,
                text: false, idempotency_key: nil, request_timeout: nil)
      uri = build_uri(path, query)
      idem = idempotency_key || (SecureRandom.uuid if sends_mail)
      head = build_headers(headers, idem, body)
      payload = JSON.generate(body) unless body.nil?
      # Repeating must not create a second resource: GET, DELETE and PATCH are idempotent,
      # and a POST is when it carries an Idempotency-Key.
      repeatable = method != :post || !idem.nil? || idempotent
      seconds = request_timeout || timeout

      attempt = 0
      loop do
        last = attempt >= max_retries
        begin
          res = perform(method, uri, head, payload, seconds)
        rescue *TIMEOUT_ERRORS, *NETWORK_ERRORS => e
          raise connection_error(e, idem, seconds) unless repeatable && !last

          sleep(backoff(attempt))
          attempt += 1
          next
        end
        return parse_success(res, text) if res.is_a?(Net::HTTPSuccess)

        wait = retry_after(res["retry-after"])
        status = res.code.to_i
        if (status == 429 || (status >= 500 && repeatable)) && !last
          sleep([wait || backoff(attempt), MAX_RETRY_WAIT].min)
          attempt += 1
          next
        end
        raise api_error(res, wait)
      end
    end

    private

    def present(value)
      value unless value.nil? || value.to_s.empty?
    end

    def missing_key
      ConfigurationError.new(
        "no Runearc API key was given",
        code: "missing_api_key",
        fix: "Pass it as Runearc::Client.new('mb_...') or set RUNEARC_API_KEY"
      )
    end

    def build_resources
      @emails = Emails.new(self)
      @senders = Senders.new(self)
      @inboxes = Inboxes.new(self)
      @messages = Messages.new(self)
      @threads = Threads.new(self)
      @conversations = Conversations.new(self)
      @domains = Domains.new(self)
      @webhooks = Webhooks.new(self)
      @keys = Keys.new(self)
      @suppressions = Suppressions.new(self)
      @events = Events.new(self)
    end

    def build_uri(path, query)
      uri = URI.parse(base_url + path)
      pairs = (query || {}).compact.map { |k, v| [k.to_s, Support.time(v).to_s] }
      uri.query = URI.encode_www_form(pairs) unless pairs.empty?
      uri
    end

    def build_headers(extra, idempotency_key, body)
      head = { "Accept" => "application/json", "User-Agent" => "runearc-ruby/#{VERSION}" }
      head.merge!(@headers)
      head.merge!(extra) if extra
      head["Authorization"] = "Bearer #{@api_key}"
      head["Idempotency-Key"] = idempotency_key if idempotency_key
      head["Content-Type"] = "application/json" unless body.nil?
      head
    end

    def perform(method, uri, headers, payload, seconds)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = http.write_timeout = seconds
      # Net::HTTP would repeat idempotent requests by itself; the SDK owns retries.
      http.max_retries = 0
      req = HTTP_METHODS.fetch(method).new(uri.request_uri, headers)
      req.body = payload if payload
      http.start { |conn| conn.request(req) }
    end

    # Seconds to wait from a Retry-After header (seconds or an HTTP date).
    def retry_after(value)
      return nil if value.nil? || value.empty?

      seconds = Float(value, exception: false)
      return [seconds, 0].max if seconds&.finite?

      at = http_date(value)
      at && [at - Time.now, 0].max
    end

    def http_date(value)
      Time.httpdate(value)
    rescue ArgumentError
      nil
    end

    def backoff(attempt)
      cap = [8.0, 0.5 * (2**attempt)].min
      (cap / 2) + (rand * (cap / 2))
    end

    def parse_success(res, text)
      raw = res.body.to_s.dup.force_encoding(Encoding::UTF_8)
      return raw if text
      return nil if raw.empty?

      JSON.parse(raw, symbolize_names: true)
    rescue JSON::ParserError => e
      raise ApiError.build(
        "the API sent a response that is not JSON (#{e.message[0, 80]})",
        status: res.code.to_i, code: "invalid_response", fix: "Check that base_url points at the Runearc API"
      )
    end

    def connection_error(cause, idempotency_key, seconds)
      fix = if idempotency_key
              "Retry with the same idempotency_key (#{idempotency_key}) so the email is not sent twice"
            else
              "Check your network and base_url, then retry"
            end
      if TIMEOUT_ERRORS.any? { |k| cause.is_a?(k) }
        TimeoutError.new("no response from #{base_url} within #{seconds} s", fix: fix)
      else
        ConnectionError.new("could not reach #{base_url}: #{cause.message}", fix: fix)
      end
    end

    def api_error(res, wait)
      status = res.code.to_i
      text = res.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      info = begin
        JSON.parse(text, symbolize_names: true)[:error]
      rescue JSON::ParserError, TypeError, NoMethodError
        nil
      end
      info = {} unless info.is_a?(Hash)
      fallback = text.empty? ? "HTTP #{status}" : text[0, 500]
      ApiError.build(
        info[:message] || fallback,
        status: status,
        code: info[:code] || "http_#{status}",
        kind: info[:kind],
        fix: info[:fix],
        errors: (info[:errors] if info[:errors].is_a?(Array)),
        retry_after: wait&.ceil
      )
    end
  end
end
