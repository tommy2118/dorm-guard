require "rails_helper"

RSpec.describe HttpChecker do
  describe ".check" do
    let(:url) { "https://example.com" }

    context "with a 200 response" do
      before { stub_request(:get, url).to_return(status: 200, body: "ok") }

      it "returns a Result with the status code" do
        expect(described_class.check(url).status_code).to eq(200)
      end

      it "leaves error_message blank" do
        expect(described_class.check(url).error_message).to be_nil
      end

      it "measures a non-negative response_time_ms" do
        expect(described_class.check(url).response_time_ms).to be >= 0
      end

      it "records the time the check started in checked_at" do
        before_call = Time.current
        result = described_class.check(url)
        expect(result.checked_at).to be_between(before_call, Time.current)
      end
    end

    context "with a 4xx response" do
      before { stub_request(:get, url).to_return(status: 404) }

      it "records the status code and does not flag it as an error" do
        result = described_class.check(url)
        expect(result.status_code).to eq(404)
        expect(result.error_message).to be_nil
      end
    end

    context "with a 5xx response" do
      before { stub_request(:get, url).to_return(status: 503) }

      it "records the status code and does not flag it as an error" do
        result = described_class.check(url)
        expect(result.status_code).to eq(503)
        expect(result.error_message).to be_nil
      end
    end

    context "on a timeout" do
      before { stub_request(:get, url).to_timeout }

      it "returns a Result with no status_code" do
        expect(described_class.check(url).status_code).to be_nil
      end

      it "populates error_message" do
        expect(described_class.check(url).error_message).to be_present
      end

      it "still records a response_time_ms" do
        expect(described_class.check(url).response_time_ms).to be >= 0
      end
    end

    context "on a transport-level failure (DNS, connection refused, TLS)" do
      # Webmock raises the underlying stdlib error (SocketError), Faraday wraps
      # it as Faraday::ConnectionFailed. The normalization to a single error
      # hierarchy is a design win — it's why we're using Faraday instead of
      # rescuing a grab bag of Net::HTTP / Socket / OpenSSL classes.
      before { stub_request(:get, url).to_raise(SocketError.new("getaddrinfo failed")) }

      it "returns a Result with no status_code" do
        expect(described_class.check(url).status_code).to be_nil
      end

      it "surfaces the normalized Faraday error class in error_message" do
        expect(described_class.check(url).error_message).to include("Faraday::ConnectionFailed")
      end
    end

    context "with a plain http URL" do
      let(:url) { "http://example.com" }
      before { stub_request(:get, url).to_return(status: 200) }

      it "fetches without SSL" do
        expect(described_class.check(url).status_code).to eq(200)
      end
    end

    context "with a non-http(s) scheme (service-level defence-in-depth)" do
      it "rejects ftp:// and reports the unsupported scheme" do
        result = described_class.check("ftp://example.com")
        expect(result.status_code).to be_nil
        expect(result.error_message).to include("Unsupported scheme: ftp")
      end

      it "rejects javascript: scheme" do
        result = described_class.check("javascript:alert(1)")
        expect(result.status_code).to be_nil
        expect(result.error_message).to be_present
      end
    end

    context "with a URL targeting a private IP (SSRF guard)" do
      it "returns an error result without making a TCP connection" do
        result = described_class.check("http://127.0.0.1/admin")
        expect(result.status_code).to be_nil
        expect(result.error_message).to match(/blocked/i)
      end

      it "blocks cloud metadata endpoint 169.254.169.254" do
        result = described_class.check("http://169.254.169.254/latest/meta-data/")
        expect(result.status_code).to be_nil
        expect(result.error_message).to match(/blocked/i)
      end
    end
  end
end
