require "rails_helper"

RSpec.describe User, type: :model do
  let(:valid_attrs) do
    { email_address: "admin@example.com", password: "a_secure_passphrase_here", password_confirmation: "a_secure_passphrase_here" }
  end

  subject(:user) { described_class.new(valid_attrs) }

  describe "email_address" do
    it "is valid with a properly formatted address" do
      expect(user).to be_valid
    end

    it "is required" do
      user.email_address = ""
      expect(user).not_to be_valid
    end

    it "must be a valid email format" do
      user.email_address = "not-an-email"
      expect(user).not_to be_valid
    end

    it "is normalised to lowercase and stripped on save" do
      user.email_address = "  Admin@Example.COM  "
      user.save!
      expect(user.reload.email_address).to eq("admin@example.com")
    end
  end

  describe "password" do
    it "requires a minimum of 16 characters" do
      user.password = "a" * 15
      user.password_confirmation = "a" * 15
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it "accepts a password of exactly 16 characters" do
      user.password = "a" * 16
      user.password_confirmation = "a" * 16
      expect(user).to be_valid
    end

    it "authenticates with the correct password" do
      password = "a_secure_passphrase_here"
      user.save!
      expect(user.authenticate(password)).to eq(user)
    end

    it "does not trigger length validation when updating other attributes on existing record" do
      user.save!
      reloaded = user.reload
      # password is nil after reload — updating email_address without re-supplying password must stay valid
      reloaded.email_address = "other@example.com"
      expect(reloaded).to be_valid
      expect { reloaded.save! }.not_to raise_error
    end
  end
end
