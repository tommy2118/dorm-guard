require "rails_helper"

RSpec.describe ApplicationMailer do
  describe "default from-address" do
    it "defaults to the production sender when DORM_GUARD_MAIL_FROM is unset" do
      expect(ApplicationMailer.default[:from]).to eq("dorm-guard@dorm-guard.com")
    end

    it "is not the Rails scaffold placeholder" do
      expect(ApplicationMailer.default[:from]).not_to eq("from@example.com")
    end

    it "is read via ENV.fetch so deploys can override per-environment" do
      mailer_source = Rails.root.join("app/mailers/application_mailer.rb").read
      expect(mailer_source).to match(/ENV\.fetch\("DORM_GUARD_MAIL_FROM",\s*"dorm-guard@dorm-guard\.com"\)/)
    end
  end
end
