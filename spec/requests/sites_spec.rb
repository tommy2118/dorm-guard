require "rails_helper"

RSpec.describe "Sites", type: :request do
  describe "GET /sites" do
    let!(:up_site) do
      Site.create!(
        name: "Healthy",
        url: "https://healthy.example.com",
        interval_seconds: 60,
        status: :up,
        last_checked_at: 1.minute.ago
      )
    end
    let!(:down_site) do
      Site.create!(
        name: "Broken",
        url: "https://broken.example.com",
        interval_seconds: 60,
        status: :down,
        last_checked_at: 2.minutes.ago
      )
    end

    it "returns http success" do
      get sites_path
      expect(response).to have_http_status(:ok)
    end

    it "lists all site names" do
      get sites_path
      expect(response.body).to include("Healthy")
      expect(response.body).to include("Broken")
    end

    it "shows each site's URL" do
      get sites_path
      expect(response.body).to include("https://healthy.example.com")
      expect(response.body).to include("https://broken.example.com")
    end

    it "shows each site's status" do
      get sites_path
      expect(response.body).to include("up")
      expect(response.body).to include("down")
    end
  end
end
