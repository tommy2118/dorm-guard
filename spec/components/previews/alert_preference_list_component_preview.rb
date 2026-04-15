class AlertPreferenceListComponentPreview < ViewComponent::Preview
  def empty
    render(AlertPreferenceListComponent.new(site: preview_site, alert_preferences: []))
  end

  def populated
    preferences = [
      AlertPreference.new(
        site: preview_site, channel: :email,
        target: "ops@example.com", events: %w[down up]
      ),
      AlertPreference.new(
        site: preview_site, channel: :slack,
        target: "https://hooks.slack.com/services/T/B/X",
        events: %w[down degraded]
      ),
      AlertPreference.new(
        site: preview_site, channel: :webhook,
        target: "https://example.com/hook",
        events: %w[down up degraded], enabled: false
      )
    ]
    render(AlertPreferenceListComponent.new(site: preview_site, alert_preferences: preferences))
  end

  private

  def preview_site
    @preview_site ||= Site.find_or_create_by!(name: "Example Site") do |s|
      s.url = "https://example.com"
      s.interval_seconds = 60
    end
  end
end
