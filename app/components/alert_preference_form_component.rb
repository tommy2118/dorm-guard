class AlertPreferenceFormComponent < ApplicationComponent
  CHANNEL_LABELS = {
    "email" => "Email",
    "slack" => "Slack incoming webhook",
    "webhook" => "Generic JSON webhook"
  }.freeze

  def initialize(site:, alert_preference:)
    @site = site
    @alert_preference = alert_preference
  end

  attr_reader :site, :alert_preference

  def submit_label
    alert_preference.persisted? ? "Update preference" : "Create preference"
  end

  def heading
    alert_preference.persisted? ? "Edit alert preference" : "New alert preference"
  end

  def field_error(attribute)
    messages = alert_preference.errors[attribute]
    messages.first if messages.any?
  end

  def channel_options
    CHANNEL_LABELS.map { |value, label| [ label, value ] }
  end

  def event_options
    AlertPreference::EVENTS
  end

  def target_label_for(channel)
    case channel.to_s
    when "email"   then "Recipient email address"
    when "slack"   then "Slack incoming webhook URL (https://hooks.slack.com/services/...)"
    when "webhook" then "Webhook URL (https://)"
    else "Target"
    end
  end

  def selected_channel
    alert_preference.channel.presence || "email"
  end

  def checked_events
    Array(alert_preference.events)
  end
end
