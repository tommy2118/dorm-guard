require "rails_helper"

RSpec.describe "Authentication boundary", type: :request do
  let(:user) do
    User.create!(
      email_address: "admin@example.com",
      password: "a_secure_passphrase_16",
      password_confirmation: "a_secure_passphrase_16"
    )
  end

  describe "unauthenticated access" do
    it "redirects GET /sites to the login page" do
      get sites_path
      expect(response).to redirect_to(new_session_path)
    end

    it "redirects the root path to the login page" do
      get root_path
      expect(response).to redirect_to(new_session_path)
    end

    it "leaves GET /up accessible without login (Kamal health probe)" do
      get "/up"
      expect(response).to have_http_status(:ok)
    end

    it "leaves GET /session/new accessible without login" do
      get new_session_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "authenticated access" do
    before { sign_in_as(user) }

    it "allows GET /sites" do
      get sites_path
      expect(response).to have_http_status(:ok)
    end

    it "allows GET / (root)" do
      get root_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "session lifecycle" do
    it "redirects to the originally requested URL after login" do
      get new_site_path
      expect(response).to redirect_to(new_session_path)

      post session_path, params: { email_address: user.email_address, password: "a_secure_passphrase_16" }
      expect(response).to redirect_to(new_site_path)
    end

    it "destroys the session on logout and requires re-authentication" do
      sign_in_as(user)
      delete session_path
      get sites_path
      expect(response).to redirect_to(new_session_path)
    end
  end
end
