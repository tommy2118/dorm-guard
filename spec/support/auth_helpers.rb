# Shared authentication helpers for request specs.
# Included automatically for type: :request specs via rails_helper.rb.
#
# Usage:
#   let(:user) { User.create!(email_address: "x@example.com", password: "a_secure_passphrase_16",
#                             password_confirmation: "a_secure_passphrase_16") }
#   before { sign_in_as(user) }
module AuthHelpers
  # POST to the session endpoint using the Rails 8 SessionsController.
  # Authenticates through the real session stack — no internal stubbing.
  def sign_in_as(user, password: "a_secure_passphrase_16")
    post session_path, params: { email_address: user.email_address, password: password }
  end
end
