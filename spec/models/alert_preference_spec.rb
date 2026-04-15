require "rails_helper"

RSpec.describe AlertPreference, type: :model do
  let(:site) { Site.create!(name: "Example", url: "https://example.com", interval_seconds: 60) }

  def valid_attrs(overrides = {})
    {
      site: site,
      channel: :email,
      target: "alerts@example.com",
      events: %w[down up]
    }.merge(overrides)
  end

  describe "associations" do
    it "belongs to a site" do
      pref = described_class.new(valid_attrs)
      expect(pref.site).to eq(site)
    end

    it "cascades delete when its site is destroyed" do
      described_class.create!(valid_attrs)
      expect { site.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  describe "defaults" do
    it "defaults enabled to true" do
      pref = described_class.new(valid_attrs)
      expect(pref.enabled).to be(true)
    end
  end

  describe "channel enum" do
    it "maps email/slack/webhook to integers 0/1/2" do
      expect(described_class.channels).to eq("email" => 0, "slack" => 1, "webhook" => 2)
    end
  end

  describe "events normalization" do
    it "coerces symbols and strings to a canonical string array" do
      pref = described_class.new(valid_attrs(events: [ :down, "up", "up", " degraded " ]))
      pref.valid?
      expect(pref.events).to eq(%w[down up degraded])
    end

    it "rejects blank and nil entries" do
      pref = described_class.new(valid_attrs(events: [ nil, "", "down" ]))
      pref.valid?
      expect(pref.events).to eq(%w[down])
    end

    it "round-trips through the database as a JSON array" do
      pref = described_class.create!(valid_attrs(events: %w[down up degraded]))
      expect(pref.reload.events).to eq(%w[down up degraded])
    end
  end

  describe "events validation" do
    it "requires at least one event" do
      pref = described_class.new(valid_attrs(events: []))
      expect(pref).not_to be_valid
      expect(pref.errors[:events]).to include(match(/at least one event/))
    end

    it "rejects events outside the canonical set" do
      pref = described_class.new(valid_attrs(events: %w[down something_else]))
      expect(pref).not_to be_valid
      expect(pref.errors[:events]).to include(match(/something_else/))
    end
  end

  describe "target normalization" do
    it "strips surrounding whitespace" do
      pref = described_class.new(valid_attrs(target: "  alerts@example.com  "))
      pref.valid?
      expect(pref.target).to eq("alerts@example.com")
    end
  end

  describe "target validation by channel" do
    context "when channel is :email" do
      it "accepts a syntactically valid email address" do
        expect(described_class.new(valid_attrs(target: "ops@example.com"))).to be_valid
      end

      it "rejects a non-email string" do
        pref = described_class.new(valid_attrs(target: "not-an-email"))
        expect(pref).not_to be_valid
        expect(pref.errors[:target]).to be_present
      end
    end

    context "when channel is :slack" do
      it "accepts a valid https webhook URL" do
        pref = described_class.new(valid_attrs(channel: :slack, target: "https://hooks.slack.com/services/T/B/X"))
        expect(pref).to be_valid
      end

      it "rejects http (non-TLS) URLs" do
        pref = described_class.new(valid_attrs(channel: :slack, target: "http://hooks.slack.com/services/T/B/X"))
        expect(pref).not_to be_valid
        expect(pref.errors[:target]).to include(match(/https/))
      end

      it "rejects URLs with no host" do
        pref = described_class.new(valid_attrs(channel: :slack, target: "https:///path"))
        expect(pref).not_to be_valid
        expect(pref.errors[:target]).to include(match(/host/))
      end

      it "rejects URLs with userinfo" do
        pref = described_class.new(valid_attrs(channel: :slack, target: "https://user:pass@hooks.slack.com/services/T/B/X"))
        expect(pref).not_to be_valid
        expect(pref.errors[:target]).to include(match(/userinfo/))
      end

      it "rejects relative URLs" do
        pref = described_class.new(valid_attrs(channel: :slack, target: "/services/T/B/X"))
        expect(pref).not_to be_valid
        expect(pref.errors[:target]).to be_present
      end
    end

    context "when channel is :webhook" do
      it "accepts a valid https URL" do
        pref = described_class.new(valid_attrs(channel: :webhook, target: "https://hooks.example.com/incoming"))
        expect(pref).to be_valid
      end

      it "rejects http URLs" do
        pref = described_class.new(valid_attrs(channel: :webhook, target: "http://hooks.example.com/incoming"))
        expect(pref).not_to be_valid
      end
    end
  end

  describe "presence validations" do
    it "requires a channel" do
      pref = described_class.new(valid_attrs.except(:channel))
      expect(pref).not_to be_valid
      expect(pref.errors[:channel]).to be_present
    end

    it "requires a target" do
      pref = described_class.new(valid_attrs(target: nil))
      expect(pref).not_to be_valid
      expect(pref.errors[:target]).to be_present
    end
  end

  describe "canonical event set" do
    it "references the same constant used by the dispatcher" do
      expect(described_class::EVENTS).to eq(%w[down up degraded])
    end
  end
end
