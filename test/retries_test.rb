# frozen_string_literal: true

require "test_helper"

# Retry behaviour. A tiny local HTTP server stands in for failures the real API cannot be
# made to produce on demand. The idempotency test puts that server in front of the REAL API
# as a proxy: the first send reaches the API and sends, then the proxy answers 503 as if the
# response was lost; the SDK's retry must reuse the same Idempotency-Key so the API returns
# the first email instead of sending a second one.
class RetriesTest < Minitest::Test
  UNAVAILABLE = JSON.generate(error: { code: "unavailable", message: "try again", fix: nil })
  JSON_TYPE = { "content-type" => "application/json" }.freeze

  def teardown
    @stub&.stop
  end

  def serve(&handler)
    @stub = HttpStub.new(&handler)
  end

  def test_retries_a_get_on_503_and_honours_retry_after
    times = []
    serve do |_req|
      times << Time.now
      times.length == 1 ? [503, JSON_TYPE.merge("retry-after" => "1"), UNAVAILABLE] : [200, JSON_TYPE, '{"data":[]}']
    end
    mb = Runearc::Client.new("mb_test", base_url: @stub.url)
    assert_equal({ data: [] }, mb.inboxes.list)
    assert_equal 2, times.length
    assert_operator times[1] - times[0], :>=, 0.95
  end

  def test_honours_a_retry_after_http_date
    times = []
    serve do |_req|
      times << Time.now
      if times.length == 1
        [503, JSON_TYPE.merge("retry-after" => (Time.now + 2).httpdate), UNAVAILABLE]
      else
        [200, JSON_TYPE, '{"data":[]}']
      end
    end
    Runearc::Client.new("mb_test", base_url: @stub.url).inboxes.list
    assert_operator times[1] - times[0], :>=, 0.5
  end

  def test_retries_429_even_on_a_post_without_a_key_and_gives_up_after_max_retries
    serve do |_req|
      [429, JSON_TYPE.merge("retry-after" => "0"),
       JSON.generate(error: { code: "rate_limited", message: "slow down", fix: "wait" })]
    end
    mb = Runearc::Client.new("mb_test", base_url: @stub.url, max_retries: 3)
    err = assert_raises(Runearc::RateLimitError) { mb.inboxes.create }
    assert_equal 4, @stub.requests.length
    assert_equal 429, err.status
    assert_equal "rate_limited", err.code
    assert_equal "rate_limited", err.kind
    assert_equal "wait", err.fix
    assert_equal 0, err.retry_after
  end

  def test_never_retries_other_4xx
    serve { |_req| [400, JSON_TYPE, JSON.generate(error: { code: "invalid_body", message: "bad", fix: "fix it" })] }
    mb = Runearc::Client.new("mb_test", base_url: @stub.url)
    err = assert_raises(Runearc::InvalidRequestError) { mb.emails.deliver(from: "a@b.c", to: "d@e.f", subject: "s") }
    assert_equal 1, @stub.requests.length
    assert_equal "invalid_body", err.code
    assert_equal "fix it", err.fix
  end

  def test_does_not_repeat_a_post_that_could_create_twice_on_5xx
    serve { |_req| [503, JSON_TYPE, UNAVAILABLE] }
    err = assert_raises(Runearc::ServerError) do
      Runearc::Client.new("mb_test", base_url: @stub.url).inboxes.create(local_part: "x")
    end
    assert_equal 1, @stub.requests.length
    assert_equal 503, err.status
    assert_equal "unavailable", err.kind
  end

  def test_retries_idempotent_posts_and_posts_with_a_key_on_5xx
    serve { |_req| [503, JSON_TYPE, UNAVAILABLE] }
    mb = Runearc::Client.new("mb_test", base_url: @stub.url, max_retries: 1)
    assert_raises(Runearc::ServerError) { mb.domains.verify("dom_1") }
    assert_equal 2, @stub.requests.length
    assert_raises(Runearc::ServerError) { mb.inboxes.create }
    assert_equal 3, @stub.requests.length
  end

  def test_retries_network_errors_and_reports_them_typed_when_they_persist
    serve { |_req| :close }
    mb = Runearc::Client.new("mb_test", base_url: @stub.url, max_retries: 1)
    err = assert_raises(Runearc::ConnectionError) { mb.domains.list }
    assert_equal 2, @stub.requests.length
    assert_equal 0, err.status
    assert_equal "network_error", err.code
    assert_equal "connection", err.kind
  end

  def test_times_out_per_attempt
    serve { |_req| :hang }
    mb = Runearc::Client.new("mb_test", base_url: @stub.url, max_retries: 0, timeout: 0.2)
    err = assert_raises(Runearc::TimeoutError) { mb.events.list }
    assert_kind_of Runearc::ConnectionError, err
    assert_equal "timeout", err.code
    assert_equal 0, err.status
  end

  def test_a_per_call_request_timeout_overrides_the_client_timeout
    serve { |_req| :hang }
    mb = Runearc::Client.new("mb_test", base_url: @stub.url, max_retries: 0, timeout: 30)
    started = Time.now
    assert_raises(Runearc::TimeoutError) { mb.events.list(request_timeout: 0.2) }
    assert_operator Time.now - started, :<, 5
  end

  def test_a_non_json_success_is_an_invalid_response_error
    serve { |_req| [200, { "content-type" => "text/html" }, "<html>"] }
    err = assert_raises(Runearc::ApiError) { Runearc::Client.new("mb_test", base_url: @stub.url).events.list }
    assert_equal "invalid_response", err.code
    assert_equal 200, err.status
  end

  def test_an_error_without_a_json_body_still_has_a_code_and_message
    serve { |_req| [502, { "content-type" => "text/plain" }, "bad gateway"] }
    err = assert_raises(Runearc::ServerError) do
      Runearc::Client.new("mb_test", base_url: @stub.url, max_retries: 0).events.list
    end
    assert_equal "http_502", err.code
    assert_equal "bad gateway", err.message
    assert_nil err.fix
  end

  def test_sends_the_key_user_agent_extra_headers_and_a_json_body
    serve { |_req| [201, JSON_TYPE, '{"id":"ibx_1"}'] }
    mb = Runearc::Client.new("mb_secret", base_url: "#{@stub.url}/v1/", headers: { "Runearc-Project" => "prj_1" })
    mb.inboxes.create(local_part: "a b", display_name: nil)
    req = @stub.requests.first
    assert_equal "POST", req.verb
    assert_equal "/v1/inboxes", req.path
    assert_equal "Bearer mb_secret", req.headers["authorization"]
    assert_equal "runearc-ruby/#{Runearc::VERSION}", req.headers["user-agent"]
    assert_equal "prj_1", req.headers["runearc-project"]
    assert_equal "application/json", req.headers["content-type"]
    assert_equal({ "local_part" => "a b" }, JSON.parse(req.body))
    refute req.headers.key?("idempotency-key")
  end

  def test_encodes_path_segments_and_query_parameters
    serve { |_req| [200, JSON_TYPE, '{"data":[]}'] }
    mb = Runearc::Client.new("mb_test", base_url: @stub.url)
    mb.suppressions.delete("a+b@example.org")
    mb.conversations.list(q: "a b&c", limit: 5, status: nil)
    assert_equal "/v1/suppressions/a%2Bb%40example.org", @stub.requests[0].path
    assert_equal "/v1/conversations?q=a+b%26c&limit=5", @stub.requests[1].path
  end

  def test_a_retried_send_reuses_its_idempotency_key_so_the_real_api_sends_once
    keys = []
    calls = 0
    serve do |req|
      calls += 1
      keys << req.headers["idempotency-key"]
      upstream = URI("#{stack.api_url}#{req.path}")
      res = Net::HTTP.post(upstream, req.body, "Authorization" => req.headers["authorization"],
                                               "Content-Type" => "application/json",
                                               "Idempotency-Key" => req.headers["idempotency-key"])
      # The first answer is "lost": the email was sent, but the client sees a 503.
      calls == 1 ? [503, JSON_TYPE, UNAVAILABLE] : [res.code.to_i, JSON_TYPE, res.body]
    end
    proxied = Runearc::Client.new(stack.api_key, base_url: @stub.url)
    subject = unique("retry once")
    id = proxied.emails.deliver(from: from, to: test_address, subject: subject, text: "once")[:id]
    assert_equal 2, calls
    assert_match(/\A[0-9a-f-]{36}\z/, keys[0])
    assert_equal keys[0], keys[1]
    sent = client.emails.list(limit: 100)[:data].select { |e| e[:subject] == subject }
    assert_equal([id], sent.map { |e| e[:id] })
  end
end

class ClientConfigTest < Minitest::Test
  def test_reads_runearc_api_key_and_runearc_base_url_from_the_environment
    with_env("RUNEARC_API_KEY" => nil, "RUNEARC_BASE_URL" => nil) do
      err = assert_raises(Runearc::ConfigurationError) { Runearc::Client.new }
      assert_equal "missing_api_key", err.code
      assert_equal 0, err.status
      refute_nil err.fix
      ENV["RUNEARC_API_KEY"] = "mb_from_env"
      assert_equal "https://api.runearc.com", Runearc::Client.new.base_url
      ENV["RUNEARC_BASE_URL"] = "http://127.0.0.1:1/v1/"
      assert_equal "http://127.0.0.1:1", Runearc::Client.new.base_url
    end
  end

  def test_an_explicit_argument_wins_over_the_environment_and_a_trailing_v1_is_fine
    with_env("RUNEARC_API_KEY" => "mb_env", "RUNEARC_BASE_URL" => "http://env.example") do
      mb = Runearc::Client.new("mb_explicit", base_url: "https://api.example.com/v1")
      assert_equal "https://api.example.com", mb.base_url
      assert_equal 2, mb.max_retries
      assert_equal 60, mb.timeout
    end
  end

  def test_inspect_never_shows_the_api_key
    refute_includes Runearc::Client.new("mb_super_secret").inspect, "mb_super_secret"
  end

  def test_exposes_every_resource
    mb = Runearc::Client.new("mb_test")
    %i[emails senders inboxes messages threads conversations domains webhooks keys suppressions events].each do |name|
      assert_kind_of Runearc::Resource, mb.public_send(name)
    end
  end
end
