require "rails_helper"

RSpec.describe Site, type: :model do
  let(:valid_attrs) do
    {
      name: "Example",
      url: "https://example.com",
      interval_seconds: 60
    }
  end

  describe "validations" do
    it "is valid with all required attributes" do
      expect(described_class.new(valid_attrs)).to be_valid
    end

    it "requires a name" do
      site = described_class.new(valid_attrs.merge(name: nil))
      expect(site).not_to be_valid
      expect(site.errors[:name]).to be_present
    end

    it "requires a url" do
      site = described_class.new(valid_attrs.merge(url: nil))
      expect(site).not_to be_valid
      expect(site.errors[:url]).to be_present
    end

    it "rejects a url without an http or https scheme" do
      site = described_class.new(valid_attrs.merge(url: "example.com"))
      expect(site).not_to be_valid
      expect(site.errors[:url]).to be_present
    end

    it "accepts both http and https urls" do
      expect(described_class.new(valid_attrs.merge(url: "http://example.com"))).to be_valid
      expect(described_class.new(valid_attrs.merge(url: "https://example.com"))).to be_valid
    end

    it "requires an interval_seconds" do
      site = described_class.new(valid_attrs.merge(interval_seconds: nil))
      expect(site).not_to be_valid
      expect(site.errors[:interval_seconds]).to be_present
    end

    it "rejects an interval_seconds below the 30 second floor" do
      site = described_class.new(valid_attrs.merge(interval_seconds: 29))
      expect(site).not_to be_valid
      expect(site.errors[:interval_seconds]).to be_present
    end

    it "accepts the exact 30 second floor" do
      expect(described_class.new(valid_attrs.merge(interval_seconds: 30))).to be_valid
    end
  end

  describe "status enum" do
    it "defaults to unknown" do
      expect(described_class.new(valid_attrs).status).to eq("unknown")
    end

    it "supports up and down transitions via the enum" do
      site = described_class.new(valid_attrs)

      site.status = :up
      expect(site).to be_up

      site.status = :down
      expect(site).to be_down
    end
  end

  describe "check_results association" do
    let(:site) { described_class.create!(valid_attrs) }

    it "starts with no check results" do
      expect(site.check_results).to be_empty
    end

    it "lets check results be associated via the reverse side" do
      result = site.check_results.create!(
        status_code: 200,
        response_time_ms: 123,
        checked_at: Time.current
      )
      expect(site.reload.check_results).to contain_exactly(result)
    end

    it "cascade-deletes check results when the site is destroyed" do
      site.check_results.create!(
        status_code: 200,
        response_time_ms: 123,
        checked_at: Time.current
      )
      expect { site.destroy }.to change(CheckResult, :count).from(1).to(0)
    end
  end

  describe "#due?" do
    it "is true when the site has never been checked" do
      site = described_class.new(valid_attrs.merge(last_checked_at: nil))
      expect(site).to be_due
    end

    it "is true when last_checked_at is older than interval_seconds" do
      site = described_class.new(valid_attrs.merge(last_checked_at: 90.seconds.ago))
      expect(site).to be_due
    end

    it "is false when last_checked_at is within interval_seconds" do
      site = described_class.new(valid_attrs.merge(last_checked_at: 30.seconds.ago))
      expect(site).not_to be_due
    end

    it "is true at the exact boundary" do
      site = described_class.new(valid_attrs.merge(last_checked_at: 60.seconds.ago))
      expect(site).to be_due
    end
  end
end
