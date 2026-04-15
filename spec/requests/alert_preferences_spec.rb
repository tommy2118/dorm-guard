require "rails_helper"

RSpec.describe "Alert preferences", type: :request do
  let(:user) do
    User.create!(
      email_address: "admin@example.com",
      password: "a_secure_passphrase_16",
      password_confirmation: "a_secure_passphrase_16"
    )
  end
  let(:site) do
    Site.create!(name: "Example Site", url: "https://example.com", interval_seconds: 60)
  end
  let(:other_site) do
    Site.create!(name: "Other Site", url: "https://example.org", interval_seconds: 60)
  end

  before { sign_in_as(user) }

  describe "GET /sites/:site_id/alert_preferences" do
    it "returns http success for a site with no preferences" do
      get site_alert_preferences_path(site)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No alert preferences configured")
    end

    it "lists only preferences belonging to the nested site" do
      AlertPreference.create!(
        site: site, channel: :email, target: "on-this-site@example.com", events: %w[down]
      )
      AlertPreference.create!(
        site: other_site, channel: :email, target: "on-other-site@example.com", events: %w[down]
      )

      get site_alert_preferences_path(site)
      expect(response.body).to include("on-this-site@example.com")
      expect(response.body).not_to include("on-other-site@example.com")
    end

    it "requires authentication" do
      delete session_path
      get site_alert_preferences_path(site)
      expect(response).to redirect_to(new_session_path)
    end
  end

  describe "GET /sites/:site_id/alert_preferences/new" do
    it "renders the form" do
      get new_site_alert_preference_path(site)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("New alert preference")
    end
  end

  describe "POST /sites/:site_id/alert_preferences" do
    let(:valid_params) do
      {
        alert_preference: {
          channel: "email",
          target: "ops@example.com",
          events: [ "down", "up" ],
          enabled: "1"
        }
      }
    end

    it "creates a preference belonging to the nested site" do
      expect {
        post site_alert_preferences_path(site), params: valid_params
      }.to change(AlertPreference, :count).by(1)

      created = AlertPreference.last
      expect(created.site).to eq(site)
      expect(created.channel).to eq("email")
      expect(created.target).to eq("ops@example.com")
      expect(created.events).to eq(%w[down up])
    end

    it "redirects to the nested index on success" do
      post site_alert_preferences_path(site), params: valid_params
      expect(response).to redirect_to(site_alert_preferences_path(site))
    end

    it "renders the form with errors on invalid params" do
      post site_alert_preferences_path(site), params: {
        alert_preference: { channel: "email", target: "not-an-email", events: [] }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("is not a valid email address").or include("at least one event")
    end
  end

  describe "GET /sites/:site_id/alert_preferences/:id (cross-site scoping)" do
    let(:other_site_preference) do
      AlertPreference.create!(
        site: other_site, channel: :slack,
        target: "https://hooks.slack.com/services/T/B/X",
        events: %w[down]
      )
    end

    it "returns 404 when the preference id belongs to a DIFFERENT site" do
      get edit_site_alert_preference_path(site_id: site.id, id: other_site_preference.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /sites/:site_id/alert_preferences/:id" do
    let(:preference) do
      AlertPreference.create!(
        site: site, channel: :email, target: "old@example.com", events: %w[down]
      )
    end

    it "updates the target and events" do
      patch site_alert_preference_path(site, preference), params: {
        alert_preference: { target: "new@example.com", events: %w[down up], enabled: "1" }
      }
      expect(response).to redirect_to(site_alert_preferences_path(site))
      preference.reload
      expect(preference.target).to eq("new@example.com")
      expect(preference.events).to eq(%w[down up])
    end

    it "rejects invalid target with 422" do
      patch site_alert_preference_path(site, preference), params: {
        alert_preference: { channel: "slack", target: "http://insecure.example.com/hook", events: %w[down] }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /sites/:site_id/alert_preferences/:id" do
    let!(:preference) do
      AlertPreference.create!(
        site: site, channel: :email, target: "ops@example.com", events: %w[down]
      )
    end

    it "deletes the preference and redirects to the nested index" do
      expect {
        delete site_alert_preference_path(site, preference)
      }.to change(AlertPreference, :count).by(-1)
      expect(response).to redirect_to(site_alert_preferences_path(site))
    end
  end
end
