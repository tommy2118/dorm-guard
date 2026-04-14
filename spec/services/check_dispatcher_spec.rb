require "rails_helper"

RSpec.describe CheckDispatcher do
  let(:http_site) do
    Site.create!(name: "Example", url: "https://example.com", interval_seconds: 60)
  end
  let(:outcome) do
    CheckOutcome.new(
      status_code: 200,
      response_time_ms: 10,
      error_message: nil,
      checked_at: Time.current,
      body: "ok",
      metadata: {}
    )
  end

  describe ".call" do
    context "with an :http site" do
      it "dispatches to HttpChecker.check with the site url" do
        expect(HttpChecker).to receive(:check).with(http_site.url).and_return(outcome)

        expect(described_class.call(http_site)).to eq(outcome)
      end
    end

    context "with an :ssl site" do
      let(:ssl_site) do
        Site.create!(
          name: "Secure",
          url: "https://example.com",
          interval_seconds: 60,
          check_type: :ssl,
          tls_port: 443
        )
      end

      it "dispatches to SslChecker.check with host derived from the url and the tls_port" do
        expect(SslChecker).to receive(:check).with(host: "example.com", port: 443).and_return(outcome)

        expect(described_class.call(ssl_site)).to eq(outcome)
      end
    end

    context "with an unrouted check_type" do
      let(:phantom_site) { instance_double(Site, check_type: "phantom", url: "https://example.com") }

      it "raises UnknownCheckType loudly rather than falling back to HTTP" do
        expect { described_class.call(phantom_site) }
          .to raise_error(described_class::UnknownCheckType, /phantom/)
      end

      it "does not call HttpChecker as a fallback" do
        expect(HttpChecker).not_to receive(:check)

        expect { described_class.call(phantom_site) }.to raise_error(described_class::UnknownCheckType)
      end
    end
  end

  describe "public surface (structural assertion)" do
    # If this spec turns red, someone added a second public method to
    # CheckDispatcher. The dispatcher is a thin routing boundary — any new
    # method is a god-object seed. Move the logic into a checker or into the
    # job instead of extending the dispatcher's surface.
    it "exposes exactly one public singleton method: .call" do
      expect(described_class.singleton_methods(false)).to contain_exactly(:call)
    end

    it "exposes exactly one public constant: UnknownCheckType" do
      expect(described_class.constants).to contain_exactly(:UnknownCheckType)
    end

    it "exposes no public instance methods" do
      expect(described_class.public_instance_methods(false)).to be_empty
    end
  end
end
