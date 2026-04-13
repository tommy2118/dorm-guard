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

  describe "GET /sites/:id" do
    let(:site) do
      Site.create!(
        name: "Example",
        url: "https://example.com",
        interval_seconds: 60,
        status: :up,
        last_checked_at: 1.minute.ago
      )
    end

    it "returns http success" do
      get site_path(site)
      expect(response).to have_http_status(:ok)
    end

    it "renders the site name" do
      get site_path(site)
      expect(response.body).to include("Example")
    end

    it "shows an empty check history message when the site has no check results" do
      get site_path(site)
      expect(response.body).to include("No check history yet")
    end

    it "renders recent check results in the history table when they exist" do
      site.check_results.create!(status_code: 200, response_time_ms: 123, checked_at: 30.seconds.ago)
      site.check_results.create!(status_code: 500, response_time_ms: 1200, checked_at: 2.minutes.ago, error_message: "Upstream 500")

      get site_path(site)

      expect(response.body).to include("200")
      expect(response.body).to include("123 ms")
      expect(response.body).to include("Upstream 500")
    end

    it "paginates the check history at the configured Pagy limit" do
      27.times do |i|
        site.check_results.create!(
          status_code: 200,
          response_time_ms: 100 + i,
          checked_at: i.minutes.ago
        )
      end

      get site_path(site)

      expect(response.body.scan(/<tr>/).count - 1).to eq(25)
      expect(response.body).to include("pagy")
    end

    it "returns 404 when the site does not exist" do
      get site_path(id: 999_999)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /sites/new" do
    it "returns http success" do
      get new_site_path
      expect(response).to have_http_status(:ok)
    end

    it "renders the site form" do
      get new_site_path
      expect(response.body).to include("New site")
      expect(response.body).to include("Create site")
    end
  end

  describe "POST /sites" do
    let(:valid_params) do
      {
        site: {
          name: "Example",
          url: "https://example.com",
          interval_seconds: 60
        }
      }
    end

    let(:invalid_params) do
      {
        site: {
          name: "",
          url: "not-a-url",
          interval_seconds: 10
        }
      }
    end

    it "creates a site with valid params and redirects to the index" do
      expect {
        post sites_path, params: valid_params
      }.to change(Site, :count).by(1)

      expect(response).to redirect_to(sites_path)
      follow_redirect!
      expect(response.body).to include("Site created.")
    end

    it "ignores user-supplied status and last_checked_at" do
      post sites_path, params: {
        site: valid_params[:site].merge(status: "up", last_checked_at: 1.hour.ago)
      }
      expect(Site.last.status).to eq("unknown")
      expect(Site.last.last_checked_at).to be_nil
    end

    it "rejects invalid params with 422 and renders the form with errors" do
      expect {
        post sites_path, params: invalid_params
      }.not_to change(Site, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("can&#39;t be blank").or include("is invalid")
    end
  end
end
