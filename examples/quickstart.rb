# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"
require "runearc"

runearc = Runearc::Client.new # reads RUNEARC_API_KEY and RUNEARC_BASE_URL

inbox = runearc.inboxes.create(display_name: "quickstart")
puts "inbox #{inbox[:address]}"

subject = "Hello from the Ruby SDK #{SecureRandom.hex(3)}"
sent = runearc.emails.deliver(from: ENV.fetch("RUNEARC_FROM"), to: inbox[:address], subject: subject, text: "It works.")
puts "sent #{sent[:id]}"

waited = runearc.messages.wait(inbox[:id], subject: subject, after: inbox[:created_at], timeout: 30)
abort "no message arrived within 30 seconds" unless waited
puts "received #{waited[:message][:subject]}"

# Sign a sample event the way Runearc does (Standard Webhooks), then verify it.
key = SecureRandom.random_bytes(32)
secret = "whsec_#{[key].pack("m0")}"
payload = JSON.generate(id: "evt_1", type: "message.delivered", data: { email_id: sent[:id] })
timestamp = Time.now.to_i.to_s
signature = [OpenSSL::HMAC.digest("SHA256", key, "evt_1.#{timestamp}.#{payload}")].pack("m0")
headers = { "webhook-id" => "evt_1", "webhook-timestamp" => timestamp, "webhook-signature" => "v1,#{signature}" }
Runearc::Webhook.verify(payload: payload, headers: headers, secret: secret)
puts "webhook verified"

runearc.inboxes.delete(inbox[:id])
