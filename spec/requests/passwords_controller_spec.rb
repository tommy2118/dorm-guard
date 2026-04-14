require "rails_helper"

RSpec.describe "PasswordsController", type: :request do
  let(:user) do
    User.create!(
      email_address: "admin@example.com",
      password: "a_secure_passphrase_16",
      password_confirmation: "a_secure_passphrase_16"
    )
  end

  describe "GET /passwords/new" do
    it "is accessible without authentication" do
      get new_password_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /passwords" do
    it "redirects with a notice when the email matches a user" do
      user # ensure created
      post passwords_path, params: { email_address: user.email_address }
      expect(response).to redirect_to(new_session_path)
      expect(flash[:notice]).to be_present
    end

    it "redirects with the same notice when the email does not match (no enumeration)" do
      post passwords_path, params: { email_address: "nobody@example.com" }
      expect(response).to redirect_to(new_session_path)
      expect(flash[:notice]).to be_present
    end
  end

  describe "GET /passwords/:token/edit" do
    it "renders the reset form for a valid token" do
      token = user.generate_token_for(:password_reset)
      get edit_password_path(token)
      expect(response).to have_http_status(:ok)
    end

    it "redirects to the new password path for an invalid token" do
      get edit_password_path("not-a-valid-token")
      expect(response).to redirect_to(new_password_path)
    end
  end

  describe "PATCH /passwords/:token" do
    let(:token) { user.generate_token_for(:password_reset) }

    it "resets the password and invalidates all sessions when passwords match and meet the floor" do
      user.sessions.create!(user_agent: "test", ip_address: "127.0.0.1")
      patch password_path(token), params: {
        password: "a_new_secure_passphrase_16",
        password_confirmation: "a_new_secure_passphrase_16"
      }
      expect(response).to redirect_to(new_session_path)
      expect(flash[:notice]).to be_present
      expect(user.reload.sessions.count).to eq(0)
    end

    it "redirects with an alert when passwords do not match" do
      patch password_path(token), params: {
        password: "a_new_secure_passphrase_16",
        password_confirmation: "different_passphrase_16!"
      }
      expect(response).to redirect_to(edit_password_path(token))
      expect(flash[:alert]).to be_present
    end

    # Known UX debt: the alert message says "Passwords did not match" even when
    # the real failure is the 16-character minimum. This is generated code; the
    # message is misleading but not a security defect.
    it "redirects with an alert when the new password is below the 16-character floor" do
      patch password_path(token), params: {
        password: "tooshort",
        password_confirmation: "tooshort"
      }
      expect(response).to redirect_to(edit_password_path(token))
      expect(flash[:alert]).to be_present
    end

    it "rejects an invalid token" do
      patch password_path("not-a-valid-token"), params: {
        password: "a_new_secure_passphrase_16",
        password_confirmation: "a_new_secure_passphrase_16"
      }
      expect(response).to redirect_to(new_password_path)
    end
  end
end
