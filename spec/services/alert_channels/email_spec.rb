require "rails_helper"
require "support/alert_channel_contract"

RSpec.describe AlertChannels::Email do
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

  it_behaves_like "an alert channel"

  describe "#deliver" do
    it "enqueues site_down mailer for :down events" do
      expect {
        channel.deliver(site: site, event: :down, check_result: check_result, target: "ops@example.com")
      }.to have_enqueued_mail(DowntimeAlertMailer, :site_down).with(params: { site: site, recipient: "ops@example.com" }, args: [])
    end

    it "enqueues site_recovered mailer for :up events" do
      expect {
        channel.deliver(site: site, event: :up, check_result: check_result, target: "ops@example.com")
      }.to have_enqueued_mail(DowntimeAlertMailer, :site_recovered).with(params: { site: site, recipient: "ops@example.com" }, args: [])
    end

    it "enqueues site_degraded mailer for :degraded events" do
      expect {
        channel.deliver(site: site, event: :degraded, check_result: check_result, target: "ops@example.com")
      }.to have_enqueued_mail(DowntimeAlertMailer, :site_degraded).with(params: { site: site, recipient: "ops@example.com" }, args: [])
    end

    it "accepts event as a string" do
      expect {
        channel.deliver(site: site, event: "down", check_result: check_result, target: "ops@example.com")
      }.to have_enqueued_mail(DowntimeAlertMailer, :site_down)
    end

    it "returns truthy on successful enqueue" do
      expect(channel.deliver(site: site, event: :down, check_result: check_result, target: "ops@example.com")).to be_truthy
    end

    it "raises DeliveryError on an unsupported event" do
      expect {
        channel.deliver(site: site, event: :exploded, check_result: check_result, target: "ops@example.com")
      }.to raise_error(AlertChannels::DeliveryError, /unsupported event/)
    end

    it "routes the email to the per-preference target, not the ENV fallback" do
      mail = DowntimeAlertMailer.with(site: site, recipient: "specific@example.com").site_down
      expect(mail.to).to eq([ "specific@example.com" ])
    end
  end
end
