require "rails_helper"

# Text-level assertions on the production SMTP wiring. Same pattern as
# spec/config/production_ssl_spec.rb — the test suite runs in
# RAILS_ENV=test and cannot boot the production environment, so we read
# production.rb as source and verify the declared configuration.
#
# The behavioral proof (a delivered DowntimeAlertMailer message
# observed in the recipient inbox + provider dashboard) lands in
# Slice 7's end-to-end smoke.
#
# The SMTP provider is currently Amazon SES
# (email-smtp.us-east-1.amazonaws.com) — chosen in Slice 5B after
# Mailgun's free tier turned out to be unavailable. The env var
# names are provider-neutral (SMTP_*) so swapping providers in the
# future is a .env change, not another rename.
RSpec.describe "config/environments/production.rb — SMTP wiring" do
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
    it "reads the SMTP address from SMTP_ADDRESS with an SES us-east-1 default" do
      expect(production_rb).to match(
        /address:\s*ENV\.fetch\("SMTP_ADDRESS",\s*"email-smtp\.us-east-1\.amazonaws\.com"\)/
      )
    end

    it "reads the SMTP port from SMTP_PORT and coerces to Integer" do
      expect(production_rb).to match(
        /port:\s*ENV\.fetch\("SMTP_PORT",\s*"587"\)\.to_i/
      )
    end

    it "requires SMTP_USER_NAME (no default — fail-fast on missing credential)" do
      expect(production_rb).to match(/user_name:\s*ENV\.fetch\("SMTP_USER_NAME"\)/)
    end

    it "requires SMTP_PASSWORD (no default — fail-fast on missing credential)" do
      expect(production_rb).to match(/password:\s*ENV\.fetch\("SMTP_PASSWORD"\)/)
    end

    it "uses :login authentication (Amazon SES expects SMTP AUTH LOGIN)" do
      expect(production_rb).to match(/authentication:\s*:login/)
    end

    it "enables STARTTLS auto-upgrade on port 587" do
      expect(production_rb).to match(/enable_starttls_auto:\s*true/)
    end
  end

  describe "scaffold + Mailgun cleanup" do
    it "no longer references the Rails credentials-based scaffold SMTP stub" do
      expect(production_rb).not_to include("Rails.application.credentials.dig(:smtp")
    end

    it "no longer references smtp.example.com" do
      expect(production_rb).not_to include("smtp.example.com")
    end

    it "no longer uses the provider-scoped MAILGUN_* env var names" do
      expect(production_rb).not_to include("MAILGUN_SMTP")
    end

    it "no longer references smtp.mailgun.org as a default" do
      expect(production_rb).not_to include("smtp.mailgun.org")
    end
  end
end
