# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# The built gem: it builds, installs into a clean GEM_HOME, loads, sends through the real API,
# ships the LICENSE and has no runtime dependencies.
class PackageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_the_built_gem_installs_into_a_clean_gem_home_loads_and_sends_through_the_real_api
    Dir.mktmpdir("runearc-gem-") do |dir|
      gem = build_gem(dir)
      home = File.join(dir, "home")
      env = clean_env.merge("GEM_HOME" => home, "GEM_PATH" => home)
      out, status = Open3.capture2e(env, gem_bin, "install", "--local", "--no-document", gem)
      assert_predicate status, :success?, out

      script = <<~RUBY
        require "runearc"
        mb = Runearc::Client.new(ARGV[0], base_url: ARGV[1])
        puts mb.emails.deliver(from: ARGV[2], to: ARGV[3], subject: "from the installed gem", text: "x")[:id]
        puts Gem.loaded_specs.fetch("runearc").version
        puts File.realpath($LOADED_FEATURES.grep(/runearc/).first).start_with?(File.realpath(ARGV[4]))
      RUBY
      args = [stack.api_key, stack.api_url, "app@#{stack.domain}", test_address, home]
      out, status = Open3.capture2e(env, RbConfig.ruby, "-e", script, *args, chdir: dir)
      assert_predicate status, :success?, out
      id, version, installed = out.split("\n")
      assert_match(/\Aeml_/, id)
      assert_equal Runearc::VERSION, version
      assert_equal "true", installed
    end
  end

  def test_the_gemspec_has_no_runtime_dependencies_ships_the_license_and_declares_it
    spec = Gem::Specification.load(File.join(ROOT, "runearc.gemspec"))
    assert_empty spec.runtime_dependencies
    assert_includes spec.files, "LICENSE"
    assert_equal ["MIT"], spec.licenses
    assert_equal Gem::Requirement.new(">= 3.0"), spec.required_ruby_version
    assert_equal "runearc", spec.name
    assert_equal "0.1.0", spec.version.to_s
    assert_equal File.read(File.join(ROOT, "../sdk-node/LICENSE")), File.read(File.join(ROOT, "LICENSE"))
  end

  def test_the_library_requires_only_the_standard_library
    stdlib = %w[json net/http openssl securerandom time uri]
    required = Dir[File.join(ROOT, "lib/**/*.rb")].flat_map do |file|
      File.read(file).scan(/^\s*require "([^"]+)"/).flatten
    end
    assert_empty required.uniq - stdlib
  end

  private

  # Nothing of a surrounding Bundler or gem setup leaks into the child.
  def clean_env
    ENV.keys.grep(/\A(BUNDLE|BUNDLER|GEM_|RUBYOPT|RUBYLIB)/).to_h { |name| [name, nil] }
  end

  def gem_bin
    File.join(RbConfig::CONFIG["bindir"], "gem")
  end

  def build_gem(dir)
    out, status = Open3.capture2e(gem_bin, "build", "runearc.gemspec", "--output", File.join(dir, "runearc.gem"),
                                  chdir: ROOT)
    assert_predicate status, :success?, out
    File.join(dir, "runearc.gem")
  end
end
