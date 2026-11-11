# frozen_string_literal: true

require "test_helper"

class ResourcesTest < Minitest::Test
  def setup
    @mb = client
  end

  def test_inboxes_messages_threads_and_conversations
    local = "sdk-#{Time.now.to_i.to_s(36)}#{SecureRandom.hex(2)}"
    inbox = @mb.inboxes.create(local_part: local, display_name: "SDK")
    assert_match(/\Aibx_/, inbox[:id])
    assert_equal local, inbox[:local_part]
    assert inbox[:domain].end_with?(stack.shared_domain)
    assert_equal inbox[:address], @mb.inboxes.get(inbox[:id])[:address]
    assert(@mb.inboxes.list[:data].any? { |i| i[:id] == inbox[:id] })

    subject = unique("inbox send")
    sent = @mb.messages.deliver(inbox[:id], to: test_address, subject: subject, text: "Hello from an inbox")
    assert_match(/\Amsg_/, sent[:id])
    assert_equal subject, sent[:subject]

    # Same key twice: one message.
    key = SecureRandom.uuid
    a = @mb.messages.deliver(inbox[:id], idempotency_key: key, to: test_address, subject: unique("inbox idem"),
                                         text: "x")
    b = @mb.messages.deliver(inbox[:id], idempotency_key: key, to: test_address, subject: a[:subject], text: "x")
    assert_equal a[:id], b[:id]

    assert(@mb.messages.list(inbox[:id], limit: 10)[:data].any? { |m| m[:id] == sent[:id] })
    assert_equal sent[:thread_id], @mb.messages.get(sent[:id])[:thread_id]
    assert_includes @mb.messages.raw(sent[:id]), "Subject: #{subject}"

    reply = @mb.messages.reply(sent[:id], text: "A follow up")
    assert_equal sent[:thread_id], reply[:thread_id]
    assert_equal sent[:rfc_message_id], reply[:in_reply_to]

    assert(@mb.threads.list(inbox[:id])[:data].any? { |t| t[:id] == sent[:thread_id] })
    thread = @mb.threads.get(sent[:thread_id])
    assert_includes thread[:messages].map { |m| m[:id] }, sent[:id]
    assert_includes thread[:messages].map { |m| m[:id] }, reply[:id]

    # Nothing inbound arrives (no SMTP server in this run): wait returns nil.
    assert_nil @mb.messages.wait(inbox[:id], timeout: 1)

    assert_kind_of Array, @mb.conversations.list(inbox_id: inbox[:id], status: "all")[:data]
    assert_kind_of Integer, @mb.conversations.counts[:open]
    assert_equal "closed", @mb.conversations.update(sent[:thread_id], status: "closed")[:status]
    assert_equal "open", @mb.conversations.update(sent[:thread_id], status: "open")[:status]
    snoozed = @mb.conversations.update(sent[:thread_id], snoozed_until: Time.now + 3600)
    refute_nil snoozed[:snoozed_until]
    assert_nil @mb.conversations.update(sent[:thread_id], snoozed_until: nil)[:snoozed_until]
    assert_nil @mb.conversations.read(sent[:thread_id])
    assert_nil @mb.conversations.unread(sent[:thread_id])

    assert_nil @mb.inboxes.delete(inbox[:id])
    gone = assert_raises(Runearc::NotFoundError) { @mb.inboxes.get(inbox[:id]) }
    assert_equal 404, gone.status
  end

  def test_domains_add_list_get_by_id_and_name_verify_and_delete
    name = "sdk-crud-#{Time.now.to_i.to_s(36)}#{SecureRandom.hex(2)}.example.com"
    added = @mb.domains.create(name: name)
    assert_equal name, added[:name]
    assert_equal "pending", added[:status]
    refute_empty added[:records]
    assert(@mb.domains.list[:data].any? { |d| d[:id] == added[:id] })
    assert_equal name, @mb.domains.get(added[:id])[:name]
    assert_equal added[:id], @mb.domains.get(name)[:id]
    checked = @mb.domains.verify(added[:id])
    assert_equal added[:id], checked[:id]
    refute_equal "verified", checked[:status]
    @mb.domains.delete(added[:id])
    assert_equal 404, assert_raises(Runearc::NotFoundError) { @mb.domains.get(added[:id]) }.status
  end

  def test_keys_create_a_sending_key_that_works_list_it_and_revoke_it
    created = @mb.keys.create(name: "sdk sending", permissions: "sending", domain_id: stack.domain_id)
    refute_nil created[:secret]
    assert_equal "sending", created[:key][:permissions]
    assert(@mb.keys.list[:data].any? { |k| k[:id] == created[:key][:id] })

    sender = Runearc::Client.new(created[:secret], base_url: stack.api_url)
    id = sender.emails.deliver(from: "app@#{stack.domain}", to: test_address, subject: unique("sending key"),
                               text: "x")[:id]
    assert_match(/\Aeml_/, id)
    # A sending key cannot manage inboxes.
    assert_equal 403, assert_raises(Runearc::PermissionError) { sender.inboxes.create }.status

    @mb.keys.delete(created[:key][:id])
    assert_equal 401, assert_raises(Runearc::AuthenticationError) { sender.emails.list }.status
  end

  def test_suppressions_and_events
    # The API has no POST for suppressions (bounces and complaints add them, and simulated test
    # recipients are never suppressed), so one row is added with SQL, the way core's
    # add_suppression stores it.
    id = @mb.emails.deliver(from: "app@#{stack.domain}", to: test_address, subject: unique("events"), text: "x")[:id]
    project_id = @mb.emails.get(id)[:project_id]
    address = "blocked-#{Time.now.to_i.to_s(36)}@example.org"
    Stack.psql(stack.db_url, "INSERT INTO suppressions (org_id, project_id, address, reason) " \
                             "VALUES ('#{stack.org_id}', '#{project_id}', '#{address}', 'manual')")
    assert_equal "manual", @mb.suppressions.list[:data].find { |s| s[:address] == address }[:reason]
    @mb.suppressions.delete(address)
    refute(@mb.suppressions.list[:data].any? { |s| s[:address] == address })

    first = @mb.events.list(limit: 100)
    refute_empty first[:data]
    assert(first[:data].any? { |e| e[:type].start_with?("message.") })
    assert_equal first[:data].last[:id], first[:next_after]
    following = @mb.events.list(after: first[:next_after], limit: 100)
    assert(following[:data].all? { |e| e[:id] > first[:next_after] })
  end
end
