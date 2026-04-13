require "rails_helper"

# Text-level assertions on the production SMTP wiring. Same pattern as
# spec/config/production_ssl_spec.rb — the test suite runs in
# RAILS_ENV=test and cannot boot the production environment, so we read
# production.rb as source and verify the declared configuration.
#
# The behavioral proof (an actual Mailgun-delivered DowntimeAlertMailer
# message observed in the recipient inbox + Mailgun dashboard) lands in
# Slice 7's end-to-end smoke.
RSpec.describe "config/environments/production.rb — Mailgun SMTP wiring" do
  let(:production_rb) { Rails.root.join("config/environments/production.rb").read }

  describe "delivery method" do
    it "uses SMTP in production (not the scaffold-default :test or letter_opener)" do
      expect(production_rb).to match(/config\.action_mailer\.delivery_method\s*=\s*:smtp/)
    end

    it "performs deliveries (delivery is not stubbed)" do
      expect(production_rb).to match(/config\.action_mailer\.perform_deliveries\s*=\s*true/)
    end

    it "does not raise delivery errors (accepted trade-off — documented in the slice commit)" do
      expect(production_rb).to match(/config\.action_mailer\.raise_delivery_errors\s*=\s*false/)
    end
  end

  describe "smtp_settings block" do
    it "reads the SMTP address from MAILGUN_SMTP_ADDRESS with a smtp.mailgun.org default" do
      expect(production_rb).to match(
        /address:\s*ENV\.fetch\("MAILGUN_SMTP_ADDRESS",\s*"smtp\.mailgun\.org"\)/
      )
    end

    it "reads the SMTP port from MAILGUN_SMTP_PORT and coerces to Integer" do
      expect(production_rb).to match(
        /port:\s*ENV\.fetch\("MAILGUN_SMTP_PORT",\s*"587"\)\.to_i/
      )
    end

    it "requires MAILGUN_SMTP_USER_NAME (no default — fail-fast on missing credential)" do
      expect(production_rb).to match(/user_name:\s*ENV\.fetch\("MAILGUN_SMTP_USER_NAME"\)/)
    end

    it "requires MAILGUN_SMTP_PASSWORD (no default — fail-fast on missing credential)" do
      expect(production_rb).to match(/password:\s*ENV\.fetch\("MAILGUN_SMTP_PASSWORD"\)/)
    end

    it "uses :plain authentication (Mailgun expects SMTP AUTH PLAIN)" do
      expect(production_rb).to match(/authentication:\s*:plain/)
    end

    it "enables STARTTLS auto-upgrade on port 587" do
      expect(production_rb).to match(/enable_starttls_auto:\s*true/)
    end
  end

  describe "scaffold cleanup" do
    it "no longer references the Rails credentials-based scaffold SMTP stub" do
      expect(production_rb).not_to include("Rails.application.credentials.dig(:smtp")
    end

    it "no longer references smtp.example.com" do
      expect(production_rb).not_to include("smtp.example.com")
    end
  end
end
