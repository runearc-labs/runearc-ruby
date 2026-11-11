# frozen_string_literal: true

require "test_helper"

class EmailsTest < Minitest::Test
  def setup
    @mb = client
  end

  def test_sends_to_a_simulated_recipient_and_reads_it_back
    subject = unique("send")
    id = @mb.emails.deliver(from: from, to: test_address, subject: subject, html: "<p>Hello</p>", text: "Hello",
                            tags: [{ name: "kind", value: "test" }])[:id]
    assert_match(/\Aeml_/, id)
    got = eventually do
      e = @mb.emails.get(id)
      e if e[:status] == "delivered"
    end
    assert_equal "email", got[:object]
    assert_equal subject, got[:subject]
    assert_equal [test_address], got[:to]
    assert_equal "delivered", got[:recipients].first[:status]
    assert_equal [{ name: "kind", value: "test" }], got[:tags]

    page = @mb.emails.list(limit: 100)
    assert(page[:data].any? { |e| e[:id] == id })
    assert page.key?(:next_cursor)
  end

  def test_returns_the_same_id_for_a_repeated_idempotency_key_and_refuses_a_different_body
    key = SecureRandom.uuid
    body = { from: from, to: test_address, subject: unique("idem"), text: "once" }
    a = @mb.emails.deliver(idempotency_key: key, **body)
    b = @mb.emails.deliver(idempotency_key: key, **body)
    assert_equal a[:id], b[:id]
    err = assert_raises(Runearc::ConflictError) { @mb.emails.deliver(idempotency_key: key, **body, text: "different") }
    assert_equal 409, err.status
    assert_equal "idempotency_conflict", err.code
    assert_equal "conflict", err.kind
  end

  def test_raises_typed_errors_with_a_code_and_a_fix
    err = assert_raises(Runearc::PermissionError) do
      @mb.emails.deliver(from: "nobody@not-my-domain.example", to: test_address, subject: "x", text: "x")
    end
    assert_kind_of Runearc::ApiError, err
    assert_kind_of Runearc::Error, err
    assert_equal 403, err.status
    assert_equal "sender_not_verified", err.code
    assert_equal "forbidden", err.kind
    refute_nil err.fix
    assert_equal "sender_not_verified", err.to_h[:code]

    bad = Runearc::Client.new("mb_live_not_a_real_key", base_url: stack.api_url)
    unauth = assert_raises(Runearc::AuthenticationError) { bad.emails.list }
    assert_equal 401, unauth.status
    assert_equal "invalid_api_key", unauth.code
    assert_equal "unauthorized", unauth.kind
    refute_nil unauth.fix

    missing = assert_raises(Runearc::NotFoundError) { @mb.emails.get("eml_00000000000000000000000000") }
    assert_equal 404, missing.status
  end

  def test_lists_senders_including_the_verified_domain
    data = @mb.senders.list[:data]
    assert(data.any? { |s| s[:domain] == stack.domain && s[:verified] })
  end
end

class BatchTest < Minitest::Test
  def setup
    @mb = client
  end

  def test_sends_every_valid_item_and_returns_ids_in_order
    subjects = [unique("batch a"), unique("batch b"), unique("batch c")]
    res = @mb.emails.batch(subjects.map { |subject| { from: from, to: test_address, subject: subject, text: "hi" } })
    assert_equal 3, res[:data].length
    res[:data].each_with_index { |item, i| assert_equal subjects[i], @mb.emails.get(item[:id])[:subject] }
    assert_empty res[:errors] || []
  end

  def test_strict_one_bad_item_refuses_the_whole_batch_with_errors
    subject = unique("strict")
    err = assert_raises(Runearc::InvalidRequestError) do
      @mb.emails.batch([
                         { from: from, to: test_address, subject: subject, text: "ok" },
                         { from: "nobody@not-my-domain.example", to: test_address, subject: subject, text: "bad" },
                         { from: from, to: test_address, subject: subject, text: "ok" }
                       ])
    end
    assert_equal 400, err.status
    assert_equal "invalid_batch", err.code
    assert_includes err.message, "emails[1]"
    assert_equal 1, err.errors.length
    assert_equal 1, err.errors.first[:index]
    refute_nil err.errors.first[:code]
    assert_empty(@mb.emails.list(limit: 100)[:data].select { |e| e[:subject] == subject })
  end

  def test_permissive_valid_items_send_and_invalid_ones_come_back_in_errors
    res = @mb.emails.batch(
      [
        { from: from, to: test_address, subject: unique("perm"), text: "ok" },
        { from: "nobody@not-my-domain.example", to: test_address, subject: "bad", text: "bad" }
      ],
      batch_validation: :permissive
    )
    assert_equal 1, res[:data].length
    assert_equal 1, res[:errors].length
    assert_equal 1, res[:errors].first[:index]
  end

  def test_repeats_with_the_same_idempotency_key_return_the_same_ids
    items = [{ from: from, to: test_address, subject: unique("batch idem"), text: "x" }]
    key = SecureRandom.uuid
    a = @mb.emails.batch(items, idempotency_key: key)
    b = @mb.emails.batch(items, idempotency_key: key)
    assert_equal a[:data], b[:data]
  end
end

class ScheduledEmailsTest < Minitest::Test
  def setup
    @mb = client
  end

  def test_schedules_reschedules_and_cancels
    at = Time.now + 3600
    id = @mb.emails.deliver(from: from, to: test_address, subject: unique("scheduled"), text: "later",
                            scheduled_at: at)[:id]
    email = @mb.emails.get(id)
    assert_equal "scheduled", email[:status]
    assert_equal "scheduled", email[:last_event]
    assert_in_delta at.to_f, Time.parse(email[:scheduled_at]).to_f, 1

    later = Time.now + 7200
    assert_equal({ object: "email", id: id }, @mb.emails.reschedule(id, later))
    assert_in_delta later.to_f, Time.parse(@mb.emails.get(id)[:scheduled_at]).to_f, 1

    assert_equal({ object: "email", id: id }, @mb.emails.cancel(id))
    assert_equal "canceled", @mb.emails.get(id)[:status]

    err = assert_raises(Runearc::ConflictError) { @mb.emails.update(id, scheduled_at: "in 1 hour") }
    assert_equal 409, err.status
    assert_equal "email_not_scheduled", err.code
  end

  def test_accepts_the_relative_form_and_refuses_times_without_an_offset
    id = @mb.emails.deliver(from: from, to: test_address, subject: unique("relative"), text: "later",
                            scheduled_at: "in 2 hours")[:id]
    assert_equal "scheduled", @mb.emails.get(id)[:status]
    @mb.emails.cancel(id)

    err = assert_raises(Runearc::InvalidRequestError) do
      @mb.emails.deliver(from: from, to: test_address, subject: "x", text: "x", scheduled_at: "tomorrow at 9am")
    end
    assert_equal 400, err.status
    assert_equal "invalid_scheduled_at", err.code
    refute_nil err.fix
  end

  def test_refuses_to_cancel_an_email_that_was_sent
    id = @mb.emails.deliver(from: from, to: test_address, subject: unique("now"), text: "now")[:id]
    err = assert_raises(Runearc::ConflictError) { @mb.emails.cancel(id) }
    assert_equal 409, err.status
    assert_equal "email_not_scheduled", err.code
  end
end
