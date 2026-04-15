require "rails_helper"
require "support/alert_channel_contract"

RSpec.describe AlertChannels::Webhook do
  let(:site) { Site.create!(name: "Example Site", url: "https://example.com", interval_seconds: 60) }
  let(:check_result) do
    CheckResult.create!(
      site: site,
      status_code: 500,
      response_time_ms: 120,
      error_message: "HTTP 500",
      checked_at: Time.zone.parse("2026-04-15T10:00:00Z")
    )
  end
  let(:channel) { described_class.new }
  let(:webhook_url) { "https://example.com/webhook-inbound" }

  it_behaves_like "an alert channel"

  describe "::PAYLOAD_SCHEMA_VERSION" do
    it "is pinned to an integer version so consumers can branch on it" do
      expect(described_class::PAYLOAD_SCHEMA_VERSION).to be_a(Integer)
    end
  end

  describe "#deliver" do
    before do
      stub_request(:post, webhook_url).to_return(status: 200, body: "{}")
    end

    it "POSTs JSON to the target URL" do
      channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      expect(WebMock).to have_requested(:post, webhook_url).with(
        headers: { "Content-Type" => "application/json" }
      )
    end

    it "includes the schema version, event atom, and site block" do
      channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      expect(WebMock).to have_requested(:post, webhook_url).with { |req|
        body = JSON.parse(req.body)
        body["schema_version"] == 1 &&
          body["event"] == "down" &&
          body["site"]["id"] == site.id &&
          body["site"]["name"] == "Example Site" &&
          body["site"]["url"] == "https://example.com"
      }
    end

    it "includes the check_result block" do
      channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      expect(WebMock).to have_requested(:post, webhook_url).with { |req|
        body = JSON.parse(req.body)
        body["check_result"]["status_code"] == 500 &&
          body["check_result"]["response_time_ms"] == 120 &&
          body["check_result"]["error_message"] == "HTTP 500" &&
          body["check_result"]["checked_at"] == "2026-04-15T10:00:00Z"
      }
    end

    it "includes a sent_at timestamp" do
      channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      expect(WebMock).to have_requested(:post, webhook_url).with { |req|
        body = JSON.parse(req.body)
        body["sent_at"].present?
      }
    end

    it "handles a nil check_result gracefully" do
      channel.deliver(site: site, event: :up, check_result: nil, target: webhook_url)
      expect(WebMock).to have_requested(:post, webhook_url).with { |req|
        body = JSON.parse(req.body)
        body["check_result"].nil?
      }
    end

    it "returns true on a 2xx response" do
      result = channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      expect(result).to be(true)
    end

    it "raises DeliveryError on a non-2xx response" do
      stub_request(:post, webhook_url).to_return(status: 502, body: "bad gateway")
      expect {
        channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      }.to raise_error(AlertChannels::DeliveryError, /HTTP 502/)
    end

    it "raises DeliveryError on a Faraday transport failure" do
      stub_request(:post, webhook_url).to_timeout
      expect {
        channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      }.to raise_error(AlertChannels::DeliveryError, /webhook delivery failed/)
    end

    it "is blocked by SsrfGuard for private-range targets" do
      private_target = "https://10.0.0.1/webhook"
      expect {
        channel.deliver(site: site, event: :down, check_result: check_result, target: private_target)
      }.to raise_error(AlertChannels::DeliveryError)
    end
  end
end
