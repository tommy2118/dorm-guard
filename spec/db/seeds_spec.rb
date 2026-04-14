require "rails_helper"

# db/seeds.rb has two guards:
#
#  - Rails.env.development? — populates 32 dev fixture sites
#  - ENV["SMOKE_SEED"]     — populates 2 external smoke sites
#
# The test suite runs in RAILS_ENV=test, so Rails.env.development? is
# always false here. That means these specs only exercise the
# SMOKE_SEED branch directly. The production safety ("with neither
# guard set, seeds creates zero rows") is demonstrated by loading the
# file with ENV["SMOKE_SEED"] unset and asserting Site.count stays 0.
RSpec.describe "db/seeds.rb" do
  let(:seeds_path) { Rails.root.join("db/seeds.rb") }

  before { Site.destroy_all }

  def run_seeds(smoke_seed: nil)
    original = ENV.fetch("SMOKE_SEED", nil)
    ENV["SMOKE_SEED"] = smoke_seed
    load seeds_path.to_s
  ensure
    ENV["SMOKE_SEED"] = original
  end

  describe "default (production-equivalent: no guards set)" do
    it "creates zero sites when neither Rails.env.development? nor SMOKE_SEED is truthy" do
      run_seeds(smoke_seed: nil)
      expect(Site.count).to eq(0)
    end
  end

  describe "SMOKE_SEED guard" do
    it "creates exactly two smoke sites when SMOKE_SEED is set" do
      run_seeds(smoke_seed: "1")
      expect(Site.count).to eq(2)
    end

    it "includes a guaranteed-up example.com site" do
      run_seeds(smoke_seed: "1")
      up_site = Site.find_by(name: "Smoke (example.com, up)")
      expect(up_site).not_to be_nil
      expect(up_site.url).to eq("https://example.com")
      expect(up_site.interval_seconds).to eq(60)
    end

    it "includes a guaranteed-down TEST-NET-1 site (RFC 5737)" do
      run_seeds(smoke_seed: "1")
      down_site = Site.find_by(name: "Smoke (TEST-NET-1, down)")
      expect(down_site).not_to be_nil
      expect(down_site.url).to eq("https://192.0.2.1/")
      expect(down_site.interval_seconds).to eq(60)
    end

    it "is idempotent — re-running with SMOKE_SEED doesn't duplicate" do
      run_seeds(smoke_seed: "1")
      run_seeds(smoke_seed: "1")
      expect(Site.count).to eq(2)
    end
  end

  describe "no loopback / private-range targets (SSRF hygiene)" do
    # Only inspect actual `site.url = "..."` assignments — prose comments
    # are allowed to MENTION loopback or private ranges as the forbidden
    # category. What matters is the concrete values seeded into Site.url.
    let(:url_lines) do
      seeds_path.read.scan(/site\.url\s*=\s*"([^"]+)"/).flatten
    end

    it "does not seed any loopback address" do
      expect(url_lines).not_to include(match(/127\.0\.0\.1|localhost/i))
    end

    it "does not seed any RFC 1918 private range" do
      expect(url_lines).not_to include(match(/\b10\.|\b172\.(1[6-9]|2[0-9]|3[01])\.|\b192\.168\./))
    end
  end
end
