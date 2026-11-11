# frozen_string_literal: true

# Starts a real Runearc API (and worker) against a throwaway Postgres database for the
# test run, then tears both down. Nothing in the mail path is mocked: sends go to the
# platform's simulated test recipients (+delivered@test.<platform domain>+), which the API
# records as delivered without an MTA.
#
# Needs: Postgres on localhost (createdb, dropdb, psql on PATH) and the Rust binaries, built with:
#   CARGO_TARGET_DIR=../../target/agent-sdk cargo build -p runearc-api -p runearc-worker
# Override the binary directory with RUNEARC_BIN_DIR.

require "fileutils"
require "json"
require "net/http"
require "open3"
require "securerandom"
require "socket"
require "tmpdir"

module Stack
  REPO = File.expand_path("../../../..", __dir__)
  BIN_DIR = ENV.fetch("RUNEARC_BIN_DIR") { File.join(REPO, "target/agent-sdk/debug") }
  PG_BASE = "postgres://localhost"

  Info = Struct.new(:api_url, :api_key, :db_url, :org_id, :domain, :domain_id, :test_domain, :shared_domain)

  class << self
    # @return [Info] the running stack, started on first use
    def info
      @info ||= start
    end

    def psql(db_url, sql)
      out, status = Open3.capture2e("psql", db_url, "-v", "ON_ERROR_STOP=1", "-tA", "-c", sql)
      raise "psql failed: #{out}" unless status.success?

      out.strip
    end

    def stop
      return unless @db_name

      @children.each { |pid| signal("TERM", pid) }
      @children.reverse_each { |pid| reap(pid) }
      unless ENV["RUNEARC_KEEP_TEST_DB"] == "1"
        system("dropdb", "-h", "localhost", "--force", "--if-exists", @db_name, exception: true)
      end
      FileUtils.rm_rf(@blob_dir)
      @db_name = nil
    end

    private

    def start
      %w[runearc-api runearc-worker].each do |bin|
        next if File.exist?(File.join(BIN_DIR, bin))

        raise "#{File.join(BIN_DIR,
                           bin)} is missing. Build it: CARGO_TARGET_DIR=#{File.join(REPO, "target/agent-sdk")} " \
              "cargo build -p runearc-api -p runearc-worker"
      end
      @children = []
      @logs = []
      @db_name = "runearc_sdk_test_#{SecureRandom.hex(6)}"
      system("createdb", "-h", "localhost", @db_name, exception: true)
      db_url = "#{PG_BASE}/#{@db_name}"
      @blob_dir = Dir.mktmpdir("runearc-sdk-blobs-")
      port = free_port
      api_url = "http://127.0.0.1:#{port}"
      env = environment(db_url, port)

      api_key, org_id = bootstrap(env)
      # Room for the CRUD tests: the free plan allows 3 inboxes and 3 domains.
      psql(db_url, "UPDATE orgs SET plan = 'scale' WHERE id = '#{org_id}'")

      launch("runearc-api", env)
      wait_healthy(api_url)
      launch("runearc-worker", env)
      platform = JSON.parse(Net::HTTP.get(URI("#{api_url}/v1/platform")))
      domain, domain_id = verified_domain(api_url, api_key, db_url)

      Info.new(api_url, api_key, db_url, org_id, domain, domain_id, platform["test_domain"], platform["shared_domain"])
    rescue StandardError
      stop
      raise
    end

    # A clean environment: none of the developer's RUNEARC_* or KUMO_* settings leak in.
    def environment(db_url, port)
      {
        "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"),
        "HOME" => ENV.fetch("HOME", Dir.tmpdir),
        "RUST_LOG" => "warn",
        "DATABASE_URL" => db_url,
        "BLOB_URL" => "file://#{@blob_dir}",
        "RUNEARC_SECRET_KEY" => SecureRandom.hex(32),
        "LISTEN_ADDR" => "127.0.0.1:#{port}",
        "RUNEARC_ALLOW_LOCAL_WEBHOOKS" => "1",
        # The platform refuses to start without a provider. Test recipients are recorded as
        # delivered without touching it, so this relay is never connected to.
        "RUNEARC_OUTBOUND_PROVIDER" => "smtp",
        "RUNEARC_SMTP_RELAY" => "127.0.0.1:1"
      }
    end

    # Runs the migrations and prints the key once (never logged here).
    def bootstrap(env)
      out, status = Open3.capture2e(env, File.join(BIN_DIR, "runearc-api"), "bootstrap", "sdk-#{SecureRandom.hex(3)}",
                                    unsetenv_others: true)
      raise "bootstrap failed: #{out}" unless status.success?

      key = out[/api key \(shown once\): (\S+)/, 1]
      org = out[/org: (org_\S+)/, 1]
      raise "bootstrap did not print an org and a key" unless key && org

      [key, org]
    end

    def launch(bin, env)
      log = File.join(@blob_dir, "#{bin}.log")
      pid = Process.spawn(env, File.join(BIN_DIR, bin), unsetenv_others: true, in: File::NULL, out: log, err: log)
      @children << pid
      @logs << log
    end

    def wait_healthy(api_url)
      pid = @children.last
      log = @logs.last
      deadline = Time.now + 60
      while Time.now < deadline
        raise "runearc-api exited:\n#{File.read(log)}" if Process.waitpid(pid, Process::WNOHANG)

        begin
          return if Net::HTTP.get_response(URI("#{api_url}/healthz")).is_a?(Net::HTTPSuccess)
        rescue SystemCallError
          sleep 0.2
        end
      end
      raise "runearc-api did not become healthy:\n#{File.read(log)}"
    end

    # One verified sending domain for the whole run, as the Rust tests do it: added through
    # the API, marked verified with one UPDATE (verification needs public DNS).
    def verified_domain(api_url, api_key, db_url)
      domain = "sdk-#{SecureRandom.hex(4)}.example.com"
      uri = URI("#{api_url}/v1/domains")
      res = Net::HTTP.post(uri, JSON.generate(name: domain),
                           "Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json")
      raise "adding the test domain failed: #{res.code} #{res.body}" unless res.code == "201"

      domain_id = JSON.parse(res.body).fetch("id")
      psql(db_url, "UPDATE domains SET status = 'verified', verified_at = now() WHERE id = '#{domain_id}'")
      [domain, domain_id]
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def signal(name, pid)
      Process.kill(name, pid)
    rescue Errno::ESRCH
      nil
    end

    def reap(pid)
      deadline = Time.now + 5
      loop do
        return if Process.waitpid(pid, Process::WNOHANG)

        if Time.now > deadline
          signal("KILL", pid)
          Process.waitpid(pid)
          return
        end
        sleep 0.05
      end
    rescue Errno::ECHILD
      nil
    end
  end
end
