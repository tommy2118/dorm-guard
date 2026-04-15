require "rails_helper"

RSpec.describe AlertPreferenceListComponent, type: :component do
  let(:site) do
    Site.create!(name: "Example Site", url: "https://example.com", interval_seconds: 60)
  end

  describe "empty state" do
    before do
      with_request_url "/sites/#{site.id}/alert_preferences" do
        render_inline(described_class.new(site: site, alert_preferences: []))
      end
    end

    it "renders an empty-state message" do
      expect(page).to have_text("No alert preferences configured")
    end

    it "still links to the new-preference form" do
      expect(page).to have_link("New preference")
    end
  end

  describe "with preferences" do
    let(:email_pref) do
      AlertPreference.create!(
        site: site, channel: :email, target: "ops@example.com", events: %w[down up]
      )
    end
    let(:slack_pref) do
      AlertPreference.create!(
        site: site, channel: :slack,
        target: "https://hooks.slack.com/services/T/B/X",
        events: %w[down], enabled: false
      )
    end

    before do
      with_request_url "/sites/#{site.id}/alert_preferences" do
        render_inline(described_class.new(site: site, alert_preferences: [ email_pref, slack_pref ]))
      end
    end

    it "renders one row per preference" do
      expect(page).to have_css("tbody tr", count: 2)
    end

    it "shows the channel as a badge" do
      expect(page).to have_css(".badge.badge-info", text: "email")
      expect(page).to have_css(".badge.badge-accent", text: "slack")
    end

    it "shows the target" do
      expect(page).to have_text("ops@example.com")
      expect(page).to have_text("hooks.slack.com")
    end

    it "shows each event as an outline badge" do
      expect(page).to have_css(".badge.badge-outline", text: "down")
      expect(page).to have_css(".badge.badge-outline", text: "up")
    end

    it "distinguishes enabled vs disabled preferences" do
      expect(page).to have_css(".badge.badge-success", text: "enabled")
      expect(page).to have_css(".badge.badge-ghost", text: "disabled")
    end

    it "offers edit and delete actions" do
      expect(page).to have_link("Edit", count: 2)
      expect(page).to have_button("Delete", count: 2)
    end
  end
end
