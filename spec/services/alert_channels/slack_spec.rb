require "rails_helper"
require "support/alert_channel_contract"

RSpec.describe AlertChannels::Slack do
  let(:site) { Site.create!(name: "Example Site", url: "https://example.com", interval_seconds: 60) }
  let(:check_result) do
    CheckResult.create!(
      site: site,
      status_code: 500,
      response_time_ms: 120,
      checked_at: Time.current
    )
  end
  let(:channel) { described_class.new }
  let(:webhook_url) { "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXX" }

  it_behaves_like "an alert channel"

  describe "#deliver" do
    before do
      stub_request(:post, webhook_url).to_return(status: 200, body: "ok")
    end

    it "POSTs JSON to the target webhook URL" do
      channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      expect(WebMock).to have_requested(:post, webhook_url).with(
        headers: { "Content-Type" => "application/json" }
      )
    end

    it "includes the locked `text` field with site name and event" do
      channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      expect(WebMock).to have_requested(:post, webhook_url).with { |req|
        body = JSON.parse(req.body)
        body["text"] == "[dorm-guard] Example Site is down"
      }
    end

    it "includes the site URL in the additive blocks section" do
      channel.deliver(site: site, event: :up, check_result: check_result, target: webhook_url)
      expect(WebMock).to have_requested(:post, webhook_url).with { |req|
        body = JSON.parse(req.body)
        body["blocks"].any? { |block| block.to_s.include?("https://example.com") }
      }
    end

    it "returns true on a 2xx response" do
      result = channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      expect(result).to be(true)
    end

    it "raises DeliveryError on a non-2xx response" do
      stub_request(:post, webhook_url).to_return(status: 500, body: "nope")
      expect {
        channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      }.to raise_error(AlertChannels::DeliveryError, /HTTP 500/)
    end

    it "raises DeliveryError on a Faraday transport failure" do
      stub_request(:post, webhook_url).to_timeout
      expect {
        channel.deliver(site: site, event: :down, check_result: check_result, target: webhook_url)
      }.to raise_error(AlertChannels::DeliveryError, /slack delivery failed/)
    end

    it "is blocked by SsrfGuard for private-range targets" do
      private_target = "https://127.0.0.1/webhook"
      expect {
        channel.deliver(site: site, event: :down, check_result: check_result, target: private_target)
      }.to raise_error(AlertChannels::DeliveryError)
    end
  end
end
