class AlertPreferenceFormComponentPreview < ViewComponent::Preview
  def new_email_preference
    render(AlertPreferenceFormComponent.new(
      site: preview_site,
      alert_preference: preview_site.alert_preferences.new(channel: :email)
    ))
  end

  def new_slack_preference
    render(AlertPreferenceFormComponent.new(
      site: preview_site,
      alert_preference: preview_site.alert_preferences.new(channel: :slack)
    ))
  end

  def new_webhook_preference
    render(AlertPreferenceFormComponent.new(
      site: preview_site,
      alert_preference: preview_site.alert_preferences.new(channel: :webhook)
    ))
  end

  def edit_existing
    preference = AlertPreference.new(
      site: preview_site,
      channel: :slack,
      target: "https://hooks.slack.com/services/T/B/X",
      events: %w[down up]
    )
    preference.save(validate: false)
    render(AlertPreferenceFormComponent.new(site: preview_site, alert_preference: preference))
  end

  def with_errors
    preference = preview_site.alert_preferences.new(
      channel: :slack, target: "http://insecure.example.com", events: []
    )
    preference.valid?
    render(AlertPreferenceFormComponent.new(site: preview_site, alert_preference: preference))
  end

  private

  def preview_site
    @preview_site ||= Site.find_or_create_by!(name: "Example Site") do |s|
      s.url = "https://example.com"
      s.interval_seconds = 60
    end
  end
end
