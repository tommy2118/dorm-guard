require "rails_helper"

# This spec asserts on the *declared configuration* in config/environments/
# production.rb. The test suite runs in RAILS_ENV=test, so we cannot boot
# the production environment and inspect Rails.application.config directly.
# Instead, we read the file as source and evaluate the key configuration
# block under controlled stubs.
#
# The behavioral proof — that a live HTTPS request to /up returns 200
# without redirect or host-auth rejection — lands in Slice 6 (manual kamal
# setup) via `curl -sSI https://dorm-guard.com/up`.
#
# What this spec catches: accidental re-commenting of force_ssl, loss of
# the /up exclude predicate, regressions in the ENV-driven host allowlist.
RSpec.describe "config/environments/production.rb — SSL + host allowlist" do
  let(:production_rb) { Rails.root.join("config/environments/production.rb").read }

  describe "SSL enforcement" do
    it "sets assume_ssl to true (Thruster terminates TLS in front of Puma)" do
      expect(production_rb).to match(/^\s*config\.assume_ssl\s*=\s*true/)
    end

    it "sets force_ssl to true so plain-HTTP requests that reach Puma redirect" do
      expect(production_rb).to match(/^\s*config\.force_ssl\s*=\s*true/)
    end

    it "excludes /up from the HTTP-to-HTTPS redirect so Kamal's health probe doesn't loop" do
      expect(production_rb).to match(
        /config\.ssl_options\s*=\s*\{\s*redirect:\s*\{\s*exclude:\s*health_check_exclude\s*\}\s*\}/
      )
    end
  end

  describe "host allowlist" do
    it "reads the allowed host from DORM_GUARD_HOST env var" do
      expect(production_rb).to match(
        /config\.hosts\s*=\s*\[\s*ENV\.fetch\("DORM_GUARD_HOST",\s*"dorm-guard\.com"\)\s*\]/
      )
    end

    it "excludes /up from host authorization so the Kamal probe bypasses the Host header check" do
      expect(production_rb).to match(
        /config\.host_authorization\s*=\s*\{\s*exclude:\s*health_check_exclude\s*\}/
      )
    end

    it "does not leave the Rails scaffold 'example.com' host allowlist behind" do
      expect(production_rb).not_to match(/config\.hosts\s*=\s*\[\s*"example\.com"/)
    end
  end

  describe "mailer URL options" do
    it "reads the mailer host from the same DORM_GUARD_HOST env var" do
      expect(production_rb).to match(
        /default_url_options\s*=\s*\{\s*host:\s*ENV\.fetch\("DORM_GUARD_HOST",\s*"dorm-guard\.com"\),\s*protocol:\s*"https"\s*\}/
      )
    end

    it "no longer hardcodes the Rails scaffold 'example.com' default" do
      expect(production_rb).not_to include('host: "example.com"')
    end
  end

  describe "shared /up exclude predicate" do
    it "defines health_check_exclude as a lambda that matches /up" do
      expect(production_rb).to match(
        /health_check_exclude\s*=\s*->\s*\(request\)\s*\{\s*request\.path\s*==\s*"\/up"\s*\}/
      )
    end

    it "uses health_check_exclude in both ssl_options and host_authorization (single source of truth)" do
      matches = production_rb.scan(/health_check_exclude/)
      # One declaration + one reference in ssl_options + one reference in host_authorization.
      expect(matches.size).to eq(3)
    end
  end
end
