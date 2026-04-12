require "rails_helper"

RSpec.describe CheckResult, type: :model do
  let(:site) { Site.create!(name: "Example", url: "https://example.com", interval_seconds: 60) }
  let(:valid_attrs) do
    {
      site: site,
      status_code: 200,
      response_time_ms: 120,
      checked_at: Time.current
    }
  end

  describe "validations" do
    it "is valid with all required attributes" do
      expect(described_class.new(valid_attrs)).to be_valid
    end

    it "requires a site" do
      result = described_class.new(valid_attrs.merge(site: nil))
      expect(result).not_to be_valid
      expect(result.errors[:site]).to be_present
    end

    it "requires a checked_at timestamp" do
      result = described_class.new(valid_attrs.merge(checked_at: nil))
      expect(result).not_to be_valid
      expect(result.errors[:checked_at]).to be_present
    end

    it "requires a response_time_ms" do
      result = described_class.new(valid_attrs.merge(response_time_ms: nil))
      expect(result).not_to be_valid
      expect(result.errors[:response_time_ms]).to be_present
    end

    it "allows a missing status_code (for transport-level errors like timeouts)" do
      result = described_class.new(valid_attrs.merge(status_code: nil, error_message: "Timeout"))
      expect(result).to be_valid
    end

    it "allows a missing error_message (for successful responses)" do
      expect(described_class.new(valid_attrs.merge(error_message: nil))).to be_valid
    end
  end
end
