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
      it "dispatches to HttpChecker.check with the site url and follow_redirects flag" do
        expect(HttpChecker).to receive(:check)
          .with(http_site.url, follow_redirects: true)
          .and_return(outcome)

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

    context "with a :tcp site" do
      let(:tcp_site) do
        Site.create!(
          name: "SSH",
          url: "https://example.com",
          interval_seconds: 60,
          check_type: :tcp,
          tcp_port: 22
        )
      end

      it "dispatches to TcpChecker.check with host derived from the url and the tcp_port" do
        expect(TcpChecker).to receive(:check).with(host: "example.com", port: 22).and_return(outcome)

        expect(described_class.call(tcp_site)).to eq(outcome)
      end
    end

    context "with a :dns site" do
      let(:dns_site) do
        Site.create!(
          name: "DNS check",
          interval_seconds: 60,
          check_type: :dns,
          dns_hostname: "example.com"
        )
      end

      it "dispatches to DnsChecker.check with the dns_hostname" do
        expect(DnsChecker).to receive(:check).with(hostname: "example.com").and_return(outcome)

        expect(described_class.call(dns_site)).to eq(outcome)
      end
    end

    context "with a :content_match site" do
      let(:content_match_site) do
        Site.create!(
          name: "Homepage",
          url: "https://example.com",
          interval_seconds: 60,
          check_type: :content_match,
          content_match_pattern: "Welcome"
        )
      end

      it "dispatches to ContentMatchChecker.check with url, pattern, and follow_redirects" do
        expect(ContentMatchChecker).to receive(:check)
          .with(url: "https://example.com", pattern: "Welcome", follow_redirects: true)
          .and_return(outcome)

        expect(described_class.call(content_match_site)).to eq(outcome)
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
