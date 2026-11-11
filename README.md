# runearc

Send email and give your agents an inbox, from Ruby.

```sh
gem install runearc
```

```ruby
require "runearc"

runearc = Runearc::Client.new(ENV["RUNEARC_API_KEY"])
email = runearc.emails.deliver(from: "Acme <noreply@acme.com>", to: "bob@example.com", subject: "Welcome to Acme", html: "<p>Thanks for signing up.</p>")
```

See [runearc.com/integrations/ruby](https://runearc.com/integrations/ruby) for the guide and more examples.

The official Ruby SDK for [Runearc](https://runearc.com): send, batch and schedule email, create inboxes your agents can read, manage domains and verify webhooks.

Standard library only (`net/http`, `json`, `openssl`), no runtime dependencies. Ruby 3.0 or later.

## Install

```sh
gem install runearc
```

Or in a `Gemfile`:

```ruby
gem "runearc"
```

## Quick start

```ruby
require "runearc"

runearc = Runearc::Client.new(ENV["RUNEARC_API_KEY"])

email = runearc.emails.deliver(
  from: "Acme <noreply@acme.com>",
  to: "bob@example.com",
  subject: "Welcome to Acme",
  html: "<p>Thanks for signing up.</p>"
)
email[:id] # => "eml_..."
```

`Runearc::Client.new` with no key reads `RUNEARC_API_KEY`. Keyword options:

| Option | Default | |
|---|---|---|
| `base_url:` | `RUNEARC_BASE_URL`, else `https://api.runearc.com` | A trailing `/v1` is fine. |
| `max_retries:` | `2` | Retries after the first attempt (see [Retries](#retries)). |
| `timeout:` | `60` | Seconds, per attempt. |
| `headers:` | none | Sent with every request, such as `"Runearc-Project"`. |

Responses are the API's JSON as Hashes with symbol keys, and field names are the API's own snake case (`reply_to`, `scheduled_at`, `next_cursor`), so the [API reference](https://runearc.com/docs) and this SDK read the same. Every method also takes `request_timeout:` (seconds, overrides `timeout:` for that call), and the methods that send mail take `idempotency_key:`.

Ruby already has `Object#send`, so sending is `emails.deliver` and `messages.deliver`.

To try things without sending real mail, send to `delivered@test.runearc.com`. `bounced@` and `complained@` at the same domain simulate those outcomes.

## Errors

Methods return the parsed response and raise a `Runearc::Error` when something fails. There is no result wrapper.

```ruby
begin
  runearc.emails.deliver(from: "noreply@acme.com", to: "bob@example.com", subject: "Hi", text: "Hi")
rescue Runearc::Error => e
  e.status  # => 403
  e.code    # => "sender_not_verified", a stable string to branch on
  e.kind    # => "forbidden"
  e.message
  e.fix     # what to do about it, when there is something to do
  raise
end
```

`Runearc::Error` has `status` (the HTTP status, or `0` when no response came back), `code`, `kind`, `message`, `fix`, `retry_after` (seconds, when the API sent `Retry-After`) and, for a refused batch, `errors`. `to_h` gives all of it as a Hash. `kind` is the API's error kind (`invalid`, `unauthorized`, `limit_reached`, `forbidden`, `not_found`, `conflict`, `rate_limited`, `unavailable`, `internal`), worked out from the status, or `connection` when no response came back.

Rescue one class for everything, or a narrower one:

```
Runearc::Error
  ConfigurationError        no API key (code missing_api_key)
  ConnectionError           network failed (code network_error)
    TimeoutError            code timeout
  WebhookVerificationError  see Verifying webhooks
  ApiError                  the API answered with an error
    InvalidRequestError     400
    AuthenticationError     401
    LimitReachedError       402
    PermissionError         403
    NotFoundError           404
    ConflictError           409
    RateLimitError          429
    ServerError             5xx
```

Lists come back as the API sends them: `{ data: [...] }`, plus `next_cursor` on paginated lists.

## Emails

```ruby
# Send
id = runearc.emails.deliver(
  from: "Acme <noreply@acme.com>",
  to: ["bob@example.com"],
  cc: "carol@example.com",
  reply_to: "support@acme.com",
  subject: "Your receipt",
  html: "<p>Thanks for your order.</p>",
  text: "Thanks for your order.",
  attachments: [{ filename: "receipt.pdf", content: Base64.strict_encode64(pdf) }],
  tags: [{ name: "kind", value: "receipt" }]
)[:id]

# Read
email = runearc.emails.get(id) # :status, :last_event, :recipients, :html, :text
page = runearc.emails.list(limit: 50)
more = runearc.emails.list(cursor: page[:next_cursor]) if page[:next_cursor]
```

### Scheduled send

Pass `scheduled_at:` as a `Time`, an RFC 3339 time with an offset, or the relative form `in <n> <unit>`. Up to 30 days ahead.

```ruby
id = runearc.emails.deliver(
  from: "Acme <noreply@acme.com>",
  to: "bob@example.com",
  subject: "Your trial ends tomorrow",
  text: "Here is what happens next.",
  scheduled_at: Time.now + 24 * 60 * 60 # or "2026-10-20T09:00:00Z", or "in 1 day"
)[:id]

runearc.emails.get(id)                     # status: "scheduled", scheduled_at: "..."
runearc.emails.reschedule(id, "in 2 days") # same as emails.update(id, scheduled_at: ...)
runearc.emails.cancel(id)                  # status: "canceled"
```

Rescheduling or canceling an email that is no longer scheduled raises `ConflictError` with the code `email_not_scheduled`.

### Batch send

Up to 100 emails in one request. Each item has the shape of `emails.deliver`, `scheduled_at` included.

```ruby
ids = runearc.emails.batch([
  { from: "Acme <noreply@acme.com>", to: "bob@example.com", subject: "Hi Bob", text: "..." },
  { from: "Acme <noreply@acme.com>", to: "carol@example.com", subject: "Hi Carol", text: "..." }
])[:data] # [{ id: }, { id: }] in request order
```

By default validation is strict: if any item is invalid nothing is sent, and the error lists every bad item.

```ruby
begin
  runearc.emails.batch(emails)
rescue Runearc::InvalidRequestError => e
  e.errors.each { |item| puts [item[:index], item[:code], item[:message], item[:fix]].inspect } if e.code == "invalid_batch"
end
```

With `batch_validation: :permissive` the valid items are sent and the invalid ones are reported:

```ruby
result = runearc.emails.batch(emails, batch_validation: :permissive)
result[:data]   # the emails sent
result[:errors] # the items refused, each with its :index
```

### Senders

```ruby
runearc.senders.list[:data] # addresses you can use as `from`
```

## Inboxes and messages

Inboxes receive mail. Give one to an agent, wait for a message, read the code in it, reply.

```ruby
inbox = runearc.inboxes.create(local_part: "signup-bot", display_name: "Signup bot")
runearc.inboxes.list
runearc.inboxes.get(inbox[:id])

# Wait up to 120 seconds for a matching message. Returns nil when none arrived.
got = runearc.messages.wait(inbox[:id], from: "github.com", subject: "verify", timeout: 60)
puts got[:codes], got[:links], got[:message][:subject] if got

page = runearc.messages.list(inbox[:id], limit: 20)
message = runearc.messages.get(page[:data].first[:id])
rfc822 = runearc.messages.raw(message[:id])

# Send from the inbox, and reply in a thread
runearc.messages.deliver(inbox[:id], to: "bob@example.com", subject: "Hello", text: "Hi Bob")
runearc.messages.reply(message[:id], text: "Thanks, on it", reply_all: false)

# Threads
runearc.threads.list(inbox[:id])
thread = runearc.threads.get(message[:thread_id]) # with :messages

runearc.inboxes.delete(inbox[:id])
```

## Conversations

The shared support inbox view across every inbox you can read.

```ruby
conversations = runearc.conversations.list(status: "open", assignee: "none", q: "refund")[:data]
id = conversations.first[:id]
runearc.conversations.counts
runearc.conversations.update(id, status: "closed")
runearc.conversations.update(id, snoozed_until: Time.now + 3600)
runearc.conversations.update(id, assignee_user_id: nil) # an explicit nil is sent as null: unassigns
runearc.conversations.read(id)
runearc.conversations.unread(id)
```

## Domains

```ruby
domain = runearc.domains.create(name: "acme.com")
domain[:records]   # the DNS records to publish
domain[:next_step]

runearc.domains.verify(domain[:id]) # checks DNS now
runearc.domains.list
runearc.domains.get("acme.com")     # id or name
runearc.domains.delete(domain[:id])
```

## Webhooks

```ruby
hook = runearc.webhooks.create(
  url: "https://acme.com/runearc/webhook",
  event_types: ["message.received", "message.delivered", "message.bounced"]
)
# hook[:secret] ("whsec_...") is shown once: store it, you need it to verify deliveries.

runearc.webhooks.list
deliveries = runearc.webhooks.deliveries(hook[:id], limit: 20)[:data]
runearc.webhooks.replay(hook[:id], deliveries.first[:id])
runearc.webhooks.delete(hook[:id])
```

### Verifying webhooks

Runearc signs every delivery with [Standard Webhooks](https://www.standardwebhooks.com): headers `webhook-id`, `webhook-timestamp` and `webhook-signature` (`v1,<base64 HMAC SHA256>`). `Runearc::Webhook.verify` (also `runearc.webhooks.verify` and `Runearc.verify_webhook`) checks the signature with OpenSSL and a constant time comparison, refuses timestamps more than 5 minutes off (`tolerance:` changes that), and returns the parsed event. It raises `Runearc::WebhookVerificationError`, a `Runearc::Error`, otherwise; its `code` is one of `missing_headers`, `invalid_timestamp`, `timestamp_out_of_range`, `invalid_secret`, `invalid_signature` or `invalid_payload`. Always pass the raw body, not JSON you parsed and serialized again.

`headers:` is a Hash with keys in any case, a Rack env (`HTTP_WEBHOOK_ID` keys), or any object that answers `headers["webhook-id"]`, such as Rails' `request.headers`.

Rails controller:

```ruby
class RunearcWebhooksController < ApplicationController
  skip_forgery_protection

  def create
    event = Runearc::Webhook.verify(
      payload: request.raw_post,
      headers: request.headers,
      secret: ENV.fetch("RUNEARC_WEBHOOK_SECRET")
    )
    if event[:type] == "message.received"
      # event[:data][:message_id], event[:data][:inbox_id], ...
    end
    head :no_content
  rescue Runearc::WebhookVerificationError => e
    render plain: e.message, status: :bad_request
  end
end
```

Sinatra or plain Rack:

```ruby
post "/runearc/webhook" do
  event = Runearc::Webhook.verify(
    payload: request.body.read,
    headers: request.env,
    secret: ENV.fetch("RUNEARC_WEBHOOK_SECRET")
  )
  puts event[:type], event[:id] # event[:id] is the webhook-id: use it to drop duplicates
  status 204
rescue Runearc::WebhookVerificationError
  halt 400, "invalid signature"
end
```

## API keys, suppressions and events

```ruby
created = runearc.keys.create(name: "app", permissions: "sending", domain_id: "acme.com")
created[:secret] # shown once
runearc.keys.list
runearc.keys.delete(created[:key][:id]) # revokes at once

runearc.suppressions.list
runearc.suppressions.delete("bob@example.com") # lets mail go to bob again

page = runearc.events.list(limit: 100) # oldest first
page = runearc.events.list(after: page[:next_after])
```

## Retries

The SDK retries a request up to `max_retries` times (default 2) with exponential backoff and jitter, and waits as long as the API's `Retry-After` header asks (seconds or an HTTP date, at most 60 seconds). It retries:

* 429 (rate limited), always;
* 5xx, network errors and timeouts, when the request is safe to repeat: GET, PATCH and DELETE, and any POST that carries an `Idempotency-Key`.

It never retries other 4xx errors. A POST that could create something twice (such as creating an inbox) is not repeated after a 5xx or a network error; the error is raised instead.

## Idempotency

Every call that sends mail (`emails.deliver`, `emails.batch`, `messages.deliver`, `messages.reply`) gets an `Idempotency-Key` automatically when you do not give one, and every retry reuses it, so a retry never sends twice. Runearc remembers keys for 24 hours. To make your own retries safe too, for example from a job queue, pass a key that is stable for that piece of work:

```ruby
runearc.emails.deliver(idempotency_key: "welcome/#{user.id}", **email)
```

Repeating a key with the same body returns the first result. The same key with a different body raises `ConflictError` with the code `idempotency_conflict`.

## Types

RBS signatures for the whole public surface ship in `sig/runearc.rbs`, and every public method has YARD docs.

## Development

Tests run against a real local API and Postgres: `Stack` in `test/support/stack.rb` creates a throwaway database, bootstraps the API, and starts `runearc-api` and `runearc-worker` from `RUNEARC_BIN_DIR` (default `../../target/agent-sdk/debug`). Build them with `CARGO_TARGET_DIR=../../target/agent-sdk cargo build -p runearc-api -p runearc-worker`. Postgres must be on localhost with `createdb`, `dropdb` and `psql` on `PATH`.

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

## License

MIT, see [LICENSE](LICENSE). Copyright Runearc.
