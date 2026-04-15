require "rails_helper"

RSpec.describe DowntimeAlertMailer, type: :mailer do
  describe "#site_down" do
    let(:site) do
      Site.create!(name: "Example Site", url: "https://example.com", interval_seconds: 60)
    end
    let(:mail) { described_class.with(site: site).site_down }

    it "is sent to the default fallback recipient when DORM_GUARD_ALERT_TO is unset" do
      expect(mail.to).to eq([ "alerts@dorm-guard.local" ])
    end

    it "names the site in the subject" do
      expect(mail.subject).to eq("[dorm-guard] Example Site is down")
    end

    it "includes the site name in the html body" do
      expect(mail.html_part.body.to_s).to include("Example Site")
    end

    it "includes the site URL in the html body" do
      expect(mail.html_part.body.to_s).to include("https://example.com")
    end

    it "includes the site name in the text body" do
      expect(mail.text_part.body.to_s).to include("Example Site")
    end

    it "includes the site URL in the text body" do
      expect(mail.text_part.body.to_s).to include("https://example.com")
    end

    context "when DORM_GUARD_ALERT_TO is set in the environment" do
      around do |example|
        original = ENV["DORM_GUARD_ALERT_TO"]
        ENV["DORM_GUARD_ALERT_TO"] = "ops@example.com"
        example.run
      ensure
        ENV["DORM_GUARD_ALERT_TO"] = original
      end

      it "sends to the configured address" do
        expect(mail.to).to eq([ "ops@example.com" ])
      end
    end

    context "when a per-preference recipient is passed via .with(recipient:)" do
      let(:mail) { described_class.with(site: site, recipient: "specific@example.com").site_down }

      it "routes to the override address instead of ENV/default" do
        expect(mail.to).to eq([ "specific@example.com" ])
      end
    end
  end

  describe "#site_recovered" do
    let(:site) { Site.create!(name: "Example Site", url: "https://example.com", interval_seconds: 60) }
    let(:mail) { described_class.with(site: site).site_recovered }

    it "names the site in the subject" do
      expect(mail.subject).to eq("[dorm-guard] Example Site has recovered")
    end

    it "includes the site name in both bodies" do
      expect(mail.html_part.body.to_s).to include("Example Site")
      expect(mail.text_part.body.to_s).to include("Example Site")
    end

    it "mentions recovery in the html body" do
      expect(mail.html_part.body.to_s).to include("back up")
    end

    it "uses the configured recipient" do
      expect(mail.to).to eq([ "alerts@dorm-guard.local" ])
    end
  end

  describe "#site_degraded" do
    let(:site) { Site.create!(name: "Example Site", url: "https://example.com", interval_seconds: 60) }
    let(:mail) { described_class.with(site: site).site_degraded }

    it "names the site in the subject" do
      expect(mail.subject).to eq("[dorm-guard] Example Site is degraded")
    end

    it "includes the site name in both bodies" do
      expect(mail.html_part.body.to_s).to include("Example Site")
      expect(mail.text_part.body.to_s).to include("Example Site")
    end

    it "mentions degradation in the html body" do
      expect(mail.html_part.body.to_s).to include("degraded")
    end
  end
end
