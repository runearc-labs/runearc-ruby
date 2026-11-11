# frozen_string_literal: true

module Runearc
  # @api private
  class Resource
    def initialize(client)
      @client = client
    end

    private

    def call(method, path, **options)
      @client.request(method, path, **options)
    end

    def seg(value)
      Support.segment(value)
    end

    # `scheduled_at` may be a Time, an RFC 3339 string or the relative form (`in 1 hour`).
    def email_body(email)
      return email unless email.key?(:scheduled_at)

      email.merge(scheduled_at: Support.time(email[:scheduled_at]))
    end
  end

  # Sending, reading, scheduling and canceling email.
  #
  # Every method also takes +request_timeout:+ (seconds); the ones that change something take
  # +idempotency_key:+ where noted. +deliver+ and +batch+ get a random key when you give none.
  class Emails < Resource
    # Sends one email (or schedules it with +scheduled_at+). Named +deliver+ because +send+ is taken in Ruby.
    #
    # @param email [Hash] the email as the API takes it: +:from+, +:to+, +:subject+, and optionally +:cc+,
    #   +:bcc+, +:reply_to+, +:html+, +:text+, +:headers+, +:attachments+, +:tags+ and +:scheduled_at+
    #   (a +Time+, an RFC 3339 string with an offset, or +"in 1 hour"+; at most 30 days ahead)
    # @param idempotency_key [String, nil] makes the request safe to repeat: the API returns the first
    #   result for the same key for 24 hours
    # @param request_timeout [Numeric, nil]
    # @return [Hash] +{ id: "eml_..." }+
    def deliver(idempotency_key: nil, request_timeout: nil, **email)
      call(:post, "/v1/emails", body: email_body(email), sends_mail: true,
                                idempotency_key: idempotency_key, request_timeout: request_timeout)
    end

    # Sends up to 100 emails in one request.
    #
    # @param emails [Array<Hash>] each item has the shape of {#deliver}
    # @param batch_validation [String, Symbol, nil] +:strict+ (default): one invalid item refuses the whole
    #   batch with +invalid_batch+. +:permissive+: valid items send, invalid ones come back in +:errors+.
    # @param idempotency_key [String, nil]
    # @param request_timeout [Numeric, nil]
    # @return [Hash] +{ data: [{ id: }], errors: [...] }+ (+errors+ only when permissive and some were refused)
    def batch(emails, batch_validation: nil, idempotency_key: nil, request_timeout: nil)
      headers = batch_validation ? { "x-batch-validation" => batch_validation.to_s } : nil
      call(:post, "/v1/emails/batch", body: emails.map { |e| email_body(e) }, headers: headers, sends_mail: true,
                                      idempotency_key: idempotency_key, request_timeout: request_timeout)
    end

    # @param id [String] an email id (+eml_...+)
    # @return [Hash] the email with +:status+, +:last_event+, +:recipients+, +:html+, +:text+
    def get(id, request_timeout: nil)
      call(:get, "/v1/emails/#{seg(id)}", request_timeout: request_timeout)
    end

    # @param limit [Integer, nil] 1 to 100, default 50
    # @param cursor [String, nil] the +:next_cursor+ of the previous page
    # @return [Hash] +{ data: [...], next_cursor: }+; +next_cursor+ is nil on the last page
    def list(limit: nil, cursor: nil, request_timeout: nil)
      call(:get, "/v1/emails", query: { limit: limit, cursor: cursor }, request_timeout: request_timeout)
    end

    # Changes when a scheduled email sends.
    #
    # @param id [String]
    # @param scheduled_at [Time, String] a +Time+, an RFC 3339 string with an offset, or +"in 1 hour"+
    # @return [Hash] +{ object: "email", id: }+
    def update(id, scheduled_at:, request_timeout: nil)
      call(:patch, "/v1/emails/#{seg(id)}", body: { scheduled_at: Support.time(scheduled_at) },
                                            request_timeout: request_timeout)
    end

    # Shorthand for +update(id, scheduled_at: ...)+.
    #
    # @return [Hash]
    def reschedule(id, scheduled_at, request_timeout: nil)
      update(id, scheduled_at: scheduled_at, request_timeout: request_timeout)
    end

    # Cancels a scheduled email.
    #
    # @return [Hash] +{ object: "email", id: }+
    def cancel(id, request_timeout: nil)
      call(:post, "/v1/emails/#{seg(id)}/cancel", idempotent: true, request_timeout: request_timeout)
    end
  end

  # The addresses you can send from.
  class Senders < Resource
    # @return [Hash] +{ data: [{ address:, domain:, verified:, ... }] }+
    def list(request_timeout: nil)
      call(:get, "/v1/senders", request_timeout: request_timeout)
    end
  end

  # Inboxes receive mail. Give one to an agent.
  class Inboxes < Resource
    # @param local_part [String, nil] random when nil
    # @param display_name [String, nil]
    # @param domain [String, nil] a custom domain of the workspace; the shared domain when nil
    # @return [Hash] the inbox
    def create(local_part: nil, display_name: nil, domain: nil, request_timeout: nil)
      body = { local_part: local_part, display_name: display_name, domain: domain }.compact
      call(:post, "/v1/inboxes", body: body, request_timeout: request_timeout)
    end

    # @return [Hash] +{ data: [...] }+
    def list(request_timeout: nil)
      call(:get, "/v1/inboxes", request_timeout: request_timeout)
    end

    # @param id [String] an inbox id (+ibx_...+)
    # @return [Hash]
    def get(id, request_timeout: nil)
      call(:get, "/v1/inboxes/#{seg(id)}", request_timeout: request_timeout)
    end

    # @return [nil]
    def delete(id, request_timeout: nil)
      call(:delete, "/v1/inboxes/#{seg(id)}", request_timeout: request_timeout)
    end
  end

  # Messages of an inbox: read, wait for, send and reply.
  class Messages < Resource
    # Messages of an inbox, newest first.
    #
    # @param inbox_id [String]
    # @param limit [Integer, nil] 1 to 100, default 50
    # @param cursor [String, nil]
    # @return [Hash] +{ data: [...], next_cursor: }+
    def list(inbox_id, limit: nil, cursor: nil, request_timeout: nil)
      call(:get, "/v1/inboxes/#{seg(inbox_id)}/messages", query: { limit: limit, cursor: cursor },
                                                          request_timeout: request_timeout)
    end

    # @param id [String] a message id (+msg_...+)
    # @return [Hash]
    def get(id, request_timeout: nil)
      call(:get, "/v1/messages/#{seg(id)}", request_timeout: request_timeout)
    end

    # The message as received (RFC 822).
    #
    # @return [String]
    def raw(id, request_timeout: nil)
      call(:get, "/v1/messages/#{seg(id)}/raw", text: true, request_timeout: request_timeout)
    end

    # Blocks until a matching message arrives (up to +timeout+ seconds, max 120) and returns it
    # with the codes and links found in it. Returns nil when nothing arrived in time; calling
    # again is safe.
    #
    # @param inbox_id [String]
    # @param from [String, nil] case insensitive substring of the sender address, such as +"github.com"+
    # @param subject [String, nil] case insensitive substring of the subject
    # @param to [String, nil] a recipient address, matched exactly
    # @param timeout [Integer] seconds to wait, 1 to 120 (default 30)
    # @param after [Time, String, nil] only messages received after this time; defaults to when the wait starts
    # @param request_timeout [Numeric, nil] defaults to +timeout+ plus 15 seconds
    # @return [Hash, nil] +{ message:, codes:, links: }+
    def wait(inbox_id, from: nil, subject: nil, to: nil, timeout: 30, after: nil, request_timeout: nil)
      call(:get, "/v1/inboxes/#{seg(inbox_id)}/wait",
           query: { from: from, subject: subject, to: to, timeout: timeout, after: after },
           request_timeout: request_timeout || (timeout + 15))
    rescue ApiError => e
      raise unless e.code == "wait_timeout"
    end

    # Sends a new message from an inbox. Named +deliver+ because +send+ is taken in Ruby.
    #
    # @param inbox_id [String]
    # @param message [Hash] +:to+, +:subject+, and optionally +:cc+, +:bcc+, +:text+, +:html+, +:reply_to+,
    #   +:headers+, +:attachments+
    # @param idempotency_key [String, nil]
    # @return [Hash] the message
    def deliver(inbox_id, idempotency_key: nil, request_timeout: nil, **message)
      call(:post, "/v1/inboxes/#{seg(inbox_id)}/messages", body: message, sends_mail: true,
                                                           idempotency_key: idempotency_key,
                                                           request_timeout: request_timeout)
    end

    # Replies in the thread of a message.
    #
    # @param message_id [String]
    # @param reply [Hash] +:text+, +:html+, +:reply_all+, +:headers+, +:attachments+
    # @param idempotency_key [String, nil]
    # @return [Hash] the reply message
    def reply(message_id, idempotency_key: nil, request_timeout: nil, **reply)
      call(:post, "/v1/messages/#{seg(message_id)}/reply", body: reply, sends_mail: true,
                                                           idempotency_key: idempotency_key,
                                                           request_timeout: request_timeout)
    end
  end

  # Conversation threads.
  class Threads < Resource
    # @param inbox_id [String]
    # @return [Hash] +{ data: [...] }+
    def list(inbox_id, request_timeout: nil)
      call(:get, "/v1/inboxes/#{seg(inbox_id)}/threads", request_timeout: request_timeout)
    end

    # @param id [String] a thread id
    # @return [Hash] the thread with +:messages+
    def get(id, request_timeout: nil)
      call(:get, "/v1/threads/#{seg(id)}", request_timeout: request_timeout)
    end
  end

  # The shared support inbox view across every inbox you can read.
  class Conversations < Resource
    # @param status [String, nil] +"open"+, +"closed"+, +"snoozed"+ or +"all"+
    # @param assignee [String, nil] +"me"+, +"none"+ or a user id
    # @param project_id [String, nil]
    # @param inbox_id [String, nil]
    # @param q [String, nil] search text
    # @param cursor [String, nil]
    # @param limit [Integer, nil]
    # @return [Hash] +{ data: [...], next_cursor: }+
    def list(status: nil, assignee: nil, project_id: nil, inbox_id: nil, q: nil, cursor: nil, limit: nil,
             request_timeout: nil)
      query = { status: status, assignee: assignee, project_id: project_id, inbox_id: inbox_id, q: q,
                cursor: cursor, limit: limit }
      call(:get, "/v1/conversations", query: query, request_timeout: request_timeout)
    end

    # @return [Hash] +{ open:, assigned_to_me:, unassigned:, by_project:, by_inbox: }+
    def counts(request_timeout: nil)
      call(:get, "/v1/conversations/counts", request_timeout: request_timeout)
    end

    # Changes a conversation. Only the fields you pass are sent, and an explicit nil is sent as null.
    #
    # @param id [String] the thread id
    # @param fields [Hash] +status:+ (+"open"+ or +"closed"+), +assignee_user_id:+ (nil unassigns),
    #   +snoozed_until:+ (a +Time+ or RFC 3339 string; nil wakes the conversation)
    # @return [Hash] the conversation
    def update(id, request_timeout: nil, **fields)
      body = fields.key?(:snoozed_until) ? fields.merge(snoozed_until: Support.time(fields[:snoozed_until])) : fields
      call(:patch, "/v1/conversations/#{seg(id)}", body: body, request_timeout: request_timeout)
    end

    # Marks the conversation read.
    #
    # @return [nil]
    def read(id, request_timeout: nil)
      call(:post, "/v1/conversations/#{seg(id)}/read", idempotent: true, request_timeout: request_timeout)
    end

    # Marks the conversation unread.
    #
    # @return [nil]
    def unread(id, request_timeout: nil)
      call(:delete, "/v1/conversations/#{seg(id)}/read", request_timeout: request_timeout)
    end
  end

  # Sending and receiving domains.
  class Domains < Resource
    # @param name [String] such as +"acme.com"+
    # @return [Hash] the domain with the DNS +:records+ to publish and +:next_step+
    def create(name:, request_timeout: nil)
      call(:post, "/v1/domains", body: { name: name }, request_timeout: request_timeout)
    end

    # @return [Hash] +{ data: [...] }+
    def list(request_timeout: nil)
      call(:get, "/v1/domains", request_timeout: request_timeout)
    end

    # @param id [String] a domain id (+dom_...+) or the domain name
    # @return [Hash]
    def get(id, request_timeout: nil)
      call(:get, "/v1/domains/#{seg(id)}", request_timeout: request_timeout)
    end

    # @return [nil]
    def delete(id, request_timeout: nil)
      call(:delete, "/v1/domains/#{seg(id)}", request_timeout: request_timeout)
    end

    # Checks the DNS records now and returns the domain with each record's status.
    #
    # @return [Hash]
    def verify(id, request_timeout: nil)
      call(:post, "/v1/domains/#{seg(id)}/verify", idempotent: true, request_timeout: request_timeout)
    end
  end

  # Webhook endpoints and their deliveries.
  class Webhooks < Resource
    # @param url [String]
    # @param event_types [Array<String>, nil] empty or nil means every event type
    # @param inbox_id [String, nil] nil means every inbox in the project
    # @return [Hash] the webhook with its signing +:secret+ (+whsec_...+), shown once
    def create(url:, event_types: nil, inbox_id: nil, request_timeout: nil)
      body = { url: url, event_types: event_types, inbox_id: inbox_id }.compact
      call(:post, "/v1/webhooks", body: body, request_timeout: request_timeout)
    end

    # @return [Hash] +{ data: [...] }+
    def list(request_timeout: nil)
      call(:get, "/v1/webhooks", request_timeout: request_timeout)
    end

    # @return [nil]
    def delete(id, request_timeout: nil)
      call(:delete, "/v1/webhooks/#{seg(id)}", request_timeout: request_timeout)
    end

    # @param id [String] the webhook id
    # @param limit [Integer, nil]
    # @return [Hash] +{ data: [...] }+
    def deliveries(id, limit: nil, request_timeout: nil)
      call(:get, "/v1/webhooks/#{seg(id)}/deliveries", query: { limit: limit }, request_timeout: request_timeout)
    end

    # Delivers the event of a past delivery again.
    #
    # @param id [String] the webhook id
    # @param delivery_id [String]
    # @return [Hash] the new delivery
    def replay(id, delivery_id, request_timeout: nil)
      call(:post, "/v1/webhooks/#{seg(id)}/deliveries/#{seg(delivery_id)}/replay", request_timeout: request_timeout)
    end

    # Same as {Webhook.verify}.
    #
    # @return [Hash] the event
    def verify(**kwargs)
      Webhook.verify(**kwargs)
    end
  end

  # API keys.
  class Keys < Resource
    # @param name [String]
    # @param permissions [String, nil] +"full"+ (default), +"sending"+ or +"inbox"+
    # @param inbox_id [String, nil] inbox keys: the one inbox
    # @param domain_id [String, nil] sending keys: limit to one domain (id or name)
    # @return [Hash] +{ key:, secret: }+; the +secret+ is shown once
    def create(name:, permissions: nil, inbox_id: nil, domain_id: nil, request_timeout: nil)
      body = { name: name, permissions: permissions, inbox_id: inbox_id, domain_id: domain_id }.compact
      call(:post, "/v1/keys", body: body, request_timeout: request_timeout)
    end

    # @return [Hash] +{ data: [...] }+
    def list(request_timeout: nil)
      call(:get, "/v1/keys", request_timeout: request_timeout)
    end

    # Revokes the key at once.
    #
    # @return [nil]
    def delete(id, request_timeout: nil)
      call(:delete, "/v1/keys/#{seg(id)}", request_timeout: request_timeout)
    end
  end

  # Addresses mail is not sent to.
  class Suppressions < Resource
    # @return [Hash] +{ data: [{ address:, reason:, created_at: }] }+
    def list(request_timeout: nil)
      call(:get, "/v1/suppressions", request_timeout: request_timeout)
    end

    # Lets mail go to the address again.
    #
    # @param address [String]
    # @return [nil]
    def delete(address, request_timeout: nil)
      call(:delete, "/v1/suppressions/#{seg(address)}", request_timeout: request_timeout)
    end
  end

  # The event log.
  class Events < Resource
    # Events, oldest first. Pass the returned +:next_after+ as +after:+ to continue.
    #
    # @param after [String, nil] an event id
    # @param limit [Integer, nil]
    # @return [Hash] +{ data: [...], next_after: }+
    def list(after: nil, limit: nil, request_timeout: nil)
      call(:get, "/v1/events", query: { after: after, limit: limit }, request_timeout: request_timeout)
    end
  end
end
