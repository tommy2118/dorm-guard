class AlertPreferenceListComponent < ApplicationComponent
  def initialize(site:, alert_preferences:)
    @site = site
    @alert_preferences = alert_preferences
  end

  attr_reader :site, :alert_preferences

  def empty?
    alert_preferences.none?
  end

  def channel_badge_class(channel)
    case channel
    when "email"   then "badge-info"
    when "slack"   then "badge-accent"
    when "webhook" then "badge-secondary"
    else "badge-neutral"
    end
  end

  def status_badge(preference)
    preference.enabled? ? "badge-success" : "badge-ghost"
  end
end
