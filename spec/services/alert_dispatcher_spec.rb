require "rails_helper"

RSpec.describe AlertDispatcher do
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
  let(:email_double) { instance_double("AlertChannels::Email", deliver: true) }
  let(:slack_double) { instance_double("AlertChannels::Slack", deliver: true) }
  let(:webhook_double) { instance_double("AlertChannels::Webhook", deliver: true) }

  before do
    allow(AlertChannels::Email).to receive(:new).and_return(email_double)
    allow(AlertChannels::Slack).to receive(:new).and_return(slack_double)
    allow(AlertChannels::Webhook).to receive(:new).and_return(webhook_double)
  end

  def create_pref(channel:, events: %w[down up degraded], target: nil, enabled: true)
    default_target = case channel
    when :email   then "ops@example.com"
    when :slack   then "https://hooks.slack.com/services/T/B/X"
    when :webhook then "https://example.com/hook"
    end
    AlertPreference.create!(
      site: site,
      channel: channel,
      events: events,
      target: target || default_target,
      enabled: enabled
    )
  end

  describe "::EVENTS" do
    it "matches the AlertChannels canonical set" do
      expect(described_class::EVENTS).to eq(AlertChannels::EVENTS)
    end
  end

  describe "event_from_transition (nil / no-alert transitions)" do
    it "drops same-state transitions (up → up)" do
      create_pref(channel: :email)
      described_class.call(site: site, from: "up", to: "up", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end

    it "drops unknown → up (initial healthy is silent)" do
      create_pref(channel: :email)
      described_class.call(site: site, from: "unknown", to: "up", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end

    it "drops unknown → degraded (initial degraded is silent)" do
      create_pref(channel: :email)
      described_class.call(site: site, from: "unknown", to: "degraded", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end
  end

  describe "positive transitions" do
    before { create_pref(channel: :email) }

    it "fires :down on unknown → down (first-ever failure)" do
      described_class.call(site: site, from: "unknown", to: "down", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(event: "down"))
    end

    it "fires :down on up → down" do
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(event: "down"))
    end

    it "fires :up on down → up (recovery)" do
      described_class.call(site: site, from: "down", to: "up", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(event: "up"))
    end

    it "fires :degraded on up → degraded" do
      described_class.call(site: site, from: "up", to: "degraded", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(event: "degraded"))
    end

    it "fires :down on degraded → down" do
      described_class.call(site: site, from: "degraded", to: "down", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(event: "down"))
    end

    it "fires :up on degraded → up (recovery from degraded)" do
      described_class.call(site: site, from: "degraded", to: "up", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(event: "up"))
    end

    it "fires :degraded on down → degraded" do
      described_class.call(site: site, from: "down", to: "degraded", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(event: "degraded"))
    end
  end

  describe "event-level cooldown" do
    before { create_pref(channel: :email) }

    it "suppresses a second :down alert inside the cooldown window" do
      site.update!(last_alerted_events: { "down" => 1.minute.ago.iso8601 })
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end

    it "allows a :down alert after the cooldown expires" do
      site.update!(last_alerted_events: { "down" => 10.minutes.ago.iso8601 })
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).to have_received(:deliver)
    end

    it "does NOT suppress :up when :down cooldown is active (per-event isolation)" do
      site.update!(last_alerted_events: { "down" => 1.minute.ago.iso8601 })
      described_class.call(site: site, from: "down", to: "up", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(event: "up"))
    end

    it "records the cooldown timestamp after successful delivery" do
      expect {
        described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      }.to change { site.reload.last_alerted_events["down"] }.from(nil)
    end
  end

  describe "partial-success contract (the BLOCKER fix)" do
    before do
      create_pref(channel: :email)
      create_pref(channel: :slack)
      create_pref(channel: :webhook)
      allow(slack_double).to receive(:deliver).and_raise(AlertChannels::DeliveryError, "slack fire")
    end

    it "records the cooldown even if one channel fails" do
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(site.reload.last_alerted_events["down"]).not_to be_nil
    end

    it "delivers to the non-failing channels despite Slack raising" do
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).to have_received(:deliver)
      expect(webhook_double).to have_received(:deliver)
    end

    it "does NOT retry Slack on the next run inside the cooldown window" do
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(slack_double).to have_received(:deliver).once
    end

    it "logs a warning for the failed channel" do
      expect(Rails.logger).to receive(:warn).with(/slack delivery failed|slack fire/)
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
    end
  end

  describe "quiet hours" do
    before do
      create_pref(channel: :email)
      site.update!(
        quiet_hours_start: "00:00",
        quiet_hours_end: "23:59",
        quiet_hours_timezone: "UTC"
      )
    end

    it "drops :up alerts during quiet hours" do
      described_class.call(site: site, from: "down", to: "up", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end

    it "drops :degraded alerts during quiet hours" do
      described_class.call(site: site, from: "up", to: "degraded", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end

    it "fires :down alerts during quiet hours (critical override)" do
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(event: "down"))
    end

    it "records the :down cooldown even when firing during quiet hours" do
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(site.reload.last_alerted_events["down"]).not_to be_nil
    end

    it "does NOT replay a suppressed :up at window-end (drop-not-defer)" do
      # Suppress during quiet hours
      described_class.call(site: site, from: "down", to: "up", check_result: check_result)
      # Disable quiet hours and simulate a subsequent no-op up → up check
      site.update!(quiet_hours_start: nil, quiet_hours_end: nil)
      described_class.call(site: site, from: "up", to: "up", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end
  end

  describe "preference filtering" do
    it "skips disabled preferences" do
      create_pref(channel: :email, enabled: false)
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end

    it "skips preferences whose events array does not include the event" do
      create_pref(channel: :email, events: %w[up])  # only wants recovery alerts
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end

    it "delivers only to preferences whose events include the event" do
      create_pref(channel: :email, events: %w[down])
      create_pref(channel: :slack, events: %w[up])
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).to have_received(:deliver)
      expect(slack_double).not_to have_received(:deliver)
    end
  end

  describe "unknown channel drift (review finding #2)" do
    # Simulates the future case where AlertPreference.channel gains a new
    # enum value (e.g., :sms) but AlertDispatcher::CHANNELS is not updated.
    # Today the branch is unreachable via the enum; we force it by
    # emptying the registry for the duration of the test.
    before do
      stub_const("AlertDispatcher::CHANNELS", {})
      create_pref(channel: :email)
    end

    it "logs a warning naming the unknown channel and the preference id" do
      expect(Rails.logger).to receive(:warn).with(/unknown channel.*email.*preference/)
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
    end

    it "does not call any channel's deliver" do
      allow(Rails.logger).to receive(:warn)
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).not_to have_received(:deliver)
    end

    it "does not record the cooldown (nothing was delivered)" do
      allow(Rails.logger).to receive(:warn)
      expect {
        described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      }.not_to change { site.reload.last_alerted_events["down"] }
    end
  end

  describe "multi-channel delivery" do
    before do
      create_pref(channel: :email)
      create_pref(channel: :slack)
      create_pref(channel: :webhook)
    end

    it "delivers to all eligible channels for a single event" do
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).to have_received(:deliver)
      expect(slack_double).to have_received(:deliver)
      expect(webhook_double).to have_received(:deliver)
    end

    it "passes the per-preference target to each channel" do
      described_class.call(site: site, from: "up", to: "down", check_result: check_result)
      expect(email_double).to have_received(:deliver).with(hash_including(target: "ops@example.com"))
      expect(slack_double).to have_received(:deliver).with(hash_including(target: "https://hooks.slack.com/services/T/B/X"))
      expect(webhook_double).to have_received(:deliver).with(hash_including(target: "https://example.com/hook"))
    end
  end
end
