require "rails_helper"

RSpec.describe AlertPreferenceFormComponent, type: :component do
  let(:site) do
    Site.create!(name: "Example Site", url: "https://example.com", interval_seconds: 60)
  end
  let(:new_preference) { site.alert_preferences.new }
  let(:persisted_preference) do
    AlertPreference.create!(
      site: site,
      channel: :slack,
      target: "https://hooks.slack.com/services/T/B/X",
      events: %w[down up]
    )
  end

  describe "#heading and #submit_label" do
    it "uses new-record labels for an unpersisted preference" do
      component = described_class.new(site: site, alert_preference: new_preference)
      expect(component.heading).to eq("New alert preference")
      expect(component.submit_label).to eq("Create preference")
    end

    it "uses edit-record labels for a persisted preference" do
      component = described_class.new(site: site, alert_preference: persisted_preference)
      expect(component.heading).to eq("Edit alert preference")
      expect(component.submit_label).to eq("Update preference")
    end
  end

  describe "channel_options" do
    it "offers email, slack, and webhook in display order" do
      component = described_class.new(site: site, alert_preference: new_preference)
      expect(component.channel_options.map(&:last)).to eq(%w[email slack webhook])
    end
  end

  describe "event_options" do
    it "matches the AlertPreference canonical event set" do
      component = described_class.new(site: site, alert_preference: new_preference)
      expect(component.event_options).to eq(AlertPreference::EVENTS)
    end
  end

  describe "target_label_for" do
    it "returns channel-specific labels" do
      component = described_class.new(site: site, alert_preference: new_preference)
      expect(component.target_label_for("email")).to match(/email/i)
      expect(component.target_label_for("slack")).to match(/slack/i)
      expect(component.target_label_for("webhook")).to match(/webhook/i)
    end
  end

  describe "rendering for a new preference" do
    before do
      with_request_url "/sites/#{site.id}/alert_preferences/new" do
        render_inline(described_class.new(site: site, alert_preference: new_preference))
      end
    end

    it "names the site in the header" do
      expect(page).to have_text("Example Site")
    end

    it "renders the channel select" do
      expect(page).to have_css("select[name='alert_preference[channel]']")
    end

    it "renders the target input" do
      expect(page).to have_css("input[name='alert_preference[target]']")
    end

    it "renders checkboxes for each canonical event atom" do
      AlertPreference::EVENTS.each do |event|
        expect(page).to have_css("input[name='alert_preference[events][]'][value='#{event}']")
      end
    end

    it "renders the enabled checkbox" do
      expect(page).to have_css("input[type='checkbox'][name='alert_preference[enabled]']")
    end
  end

  describe "rendering for a persisted preference" do
    before do
      with_request_url "/sites/#{site.id}/alert_preferences/#{persisted_preference.id}/edit" do
        render_inline(described_class.new(site: site, alert_preference: persisted_preference))
      end
    end

    it "pre-selects the existing channel" do
      expect(page).to have_css("select[name='alert_preference[channel]'] option[value='slack'][selected]")
    end

    it "pre-fills the target input" do
      expect(page).to have_css("input[name='alert_preference[target]'][value='https://hooks.slack.com/services/T/B/X']")
    end

    it "checks the events the preference fires on" do
      expect(page).to have_css("input[name='alert_preference[events][]'][value='down'][checked]")
      expect(page).to have_css("input[name='alert_preference[events][]'][value='up'][checked]")
      expect(page).not_to have_css("input[name='alert_preference[events][]'][value='degraded'][checked]")
    end
  end

  describe "rendering errors" do
    it "flags an invalid target with the error class" do
      invalid = site.alert_preferences.new(channel: :slack, target: "http://insecure.example.com", events: %w[down])
      invalid.valid?

      with_request_url "/sites/#{site.id}/alert_preferences/new" do
        render_inline(described_class.new(site: site, alert_preference: invalid))
      end

      expect(page).to have_css("input[name='alert_preference[target]'].input-error")
    end
  end
end
