# frozen_string_literal: true

require "test_helper"
require "openssl"

# Computed independently, the way runearc_core::webhooks::sign does it.
def sign(secret, id, timestamp, body)
  key = secret.delete_prefix("whsec_").unpack1("m0")
  "v1,#{[OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{body}")].pack("m0")}"
end

class VerifyWebhookTest < Minitest::Test
  def setup
    @secret = "whsec_#{[SecureRandom.random_bytes(32)].pack("m0")}"
    @body = JSON.generate(id: "evt_1", type: "message.delivered", timestamp: "2026-10-14T10:00:00.000Z",
                          data: { email_id: "eml_1" })
    @now = Time.now.to_i
    @headers = { "webhook-id" => "evt_1", "webhook-timestamp" => @now.to_s,
                 "webhook-signature" => sign(@secret, "evt_1", @now, @body) }
  end

  def test_matches_the_standard_webhooks_test_vector_same_as_the_rust_unit_test
    event = Runearc::Webhook.verify(
      payload: '{"test": 2432232314}',
      secret: "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw",
      headers: {
        "webhook-id" => "msg_p5jXN8AQM9LWM0D4loKWxJek",
        "webhook-timestamp" => "1614265330",
        "webhook-signature" => "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
      },
      now: 1_614_265_330
    )
    assert_equal({ test: 2_432_232_314 }, event)
  end

  def test_accepts_a_valid_signature_from_plain_headers_any_case_rack_env_and_a_headers_object
    event = Runearc::Webhook.verify(payload: @body, headers: @headers, secret: @secret)
    assert_equal "message.delivered", event[:type]
    assert_equal "eml_1", event[:data][:email_id]

    upper = @headers.transform_keys(&:upcase)
    assert_equal event, Runearc::Webhook.verify(payload: @body, headers: upper, secret: @secret)
    rack = @headers.transform_keys { |k| "HTTP_#{k.upcase.tr("-", "_")}" }
    assert_equal event, Runearc::Webhook.verify(payload: @body, headers: rack, secret: @secret)
    object = Struct.new(:h) { def [](name) = h[name] }.new(@headers)
    assert_equal event, Runearc.verify_webhook(payload: @body, headers: object, secret: @secret)
    # Several signatures (key rotation): any match passes.
    multi = @headers.merge("webhook-signature" => "v1,AAAA #{@headers["webhook-signature"]}")
    assert_equal event, Runearc::Webhook.verify(payload: @body, headers: multi, secret: @secret)
    # A binary (ASCII-8BIT) body, as Rack hands it over, verifies the same.
    assert_equal event, Runearc::Webhook.verify(payload: @body.b, headers: @headers, secret: @secret)
  end

  def test_refuses_tampered_bodies_and_wrong_secrets
    tampered = assert_raises(Runearc::WebhookVerificationError) do
      Runearc::Webhook.verify(payload: @body.sub("eml_1", "eml_2"), headers: @headers, secret: @secret)
    end
    assert_kind_of Runearc::Error, tampered
    assert_equal "invalid_signature", tampered.code
    assert_equal 0, tampered.status
    refute_nil tampered.fix

    other = "whsec_#{[SecureRandom.random_bytes(32)].pack("m0")}"
    wrong = assert_raises(Runearc::WebhookVerificationError) do
      Runearc::Webhook.verify(payload: @body, headers: @headers, secret: other)
    end
    assert_equal "invalid_signature", wrong.code
  end

  def test_refuses_stale_and_future_timestamps_and_honours_the_tolerance
    old = @now - 301
    headers = @headers.merge("webhook-timestamp" => old.to_s, "webhook-signature" => sign(@secret, "evt_1", old, @body))
    stale = assert_raises(Runearc::WebhookVerificationError) do
      Runearc::Webhook.verify(payload: @body, headers: headers, secret: @secret)
    end
    assert_equal "timestamp_out_of_range", stale.code
    assert_equal 300, Runearc::Webhook::TOLERANCE_SECONDS

    assert_equal "message.delivered",
                 Runearc::Webhook.verify(payload: @body, headers: headers, secret: @secret, tolerance: 600)[:type]
    future = assert_raises(Runearc::WebhookVerificationError) do
      Runearc::Webhook.verify(payload: @body, headers: @headers, secret: @secret, now: @now - 301)
    end
    assert_equal "timestamp_out_of_range", future.code
  end

  def test_refuses_missing_headers_bad_timestamps_secrets_and_payloads
    missing = assert_raises(Runearc::WebhookVerificationError) do
      Runearc::Webhook.verify(payload: @body, headers: { "webhook-id" => "evt_1" }, secret: @secret)
    end
    assert_equal "missing_headers", missing.code

    bad_ts = assert_raises(Runearc::WebhookVerificationError) do
      Runearc::Webhook.verify(payload: @body, headers: @headers.merge("webhook-timestamp" => "soon"), secret: @secret)
    end
    assert_equal "invalid_timestamp", bad_ts.code

    bad_secret = assert_raises(Runearc::WebhookVerificationError) do
      Runearc::Webhook.verify(payload: @body, headers: @headers, secret: "whsec_not base64!")
    end
    assert_equal "invalid_secret", bad_secret.code

    not_json = "not json"
    headers = @headers.merge("webhook-signature" => sign(@secret, "evt_1", @now, not_json))
    bad_body = assert_raises(Runearc::WebhookVerificationError) do
      Runearc::Webhook.verify(payload: not_json, headers: headers, secret: @secret)
    end
    assert_equal "invalid_payload", bad_body.code
  end

  def test_ignores_signatures_of_other_versions_and_garbage
    headers = @headers.merge("webhook-signature" => "v2,#{@headers["webhook-signature"][3..]} v1 v1,!!! v1,AA")
    err = assert_raises(Runearc::WebhookVerificationError) do
      Runearc::Webhook.verify(payload: @body, headers: headers, secret: @secret)
    end
    assert_equal "invalid_signature", err.code
  end
end

class WebhooksApiTest < Minitest::Test
  def teardown
    @stub&.stop
  end

  def test_creates_a_webhook_receives_a_real_signed_delivery_verifies_it_lists_replays_and_deletes
    @stub = HttpStub.new { |_req| [200, {}, "ok"] }
    mb = client
    hook = mb.webhooks.create(url: "#{@stub.url}/hook", event_types: ["message.delivered"])
    refute_nil hook[:id]
    assert_match(/\Awhsec_/, hook[:secret])
    assert(mb.webhooks.list[:data].any? { |w| w[:id] == hook[:id] })

    id = mb.emails.deliver(from: from, to: test_address, subject: unique("hook"), text: "hi")[:id]
    first = eventually(30) { @stub.requests.find { |r| r.body.include?(id) } }
    event = mb.webhooks.verify(payload: first.body, headers: first.headers, secret: hook[:secret])
    assert_equal "message.delivered", event[:type]
    assert_equal first.headers["webhook-id"], event[:id]
    assert_includes JSON.generate(event[:data]), id

    deliveries = eventually do
      d = mb.webhooks.deliveries(hook[:id], limit: 10)
      d if !d[:data].empty? && d[:data].none? { |x| x[:status] == "pending" }
    end
    delivery = deliveries[:data].first
    before = @stub.requests.length
    replay = mb.webhooks.replay(hook[:id], delivery[:id])
    assert_equal delivery[:id], replay[:replay_of]
    again = eventually(30) { @stub.requests.last if @stub.requests.length > before }
    assert_equal "message.delivered",
                 Runearc::Webhook.verify(payload: again.body, headers: again.headers, secret: hook[:secret])[:type]

    assert_nil mb.webhooks.delete(hook[:id])
    refute(mb.webhooks.list[:data].any? { |w| w[:id] == hook[:id] })
  end
end
