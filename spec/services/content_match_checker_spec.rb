require "rails_helper"

RSpec.describe ContentMatchChecker do
  let(:url) { "https://example.com" }
  let(:pattern) { "Welcome" }
  let(:base_outcome_attrs) do
    {
      status_code: 200,
      response_time_ms: 42,
      error_message: nil,
      checked_at: Time.current,
      body: "Welcome to Example Inc",
      metadata: {}
    }
  end

  describe ".check" do
    context "when the HTTP response body contains the pattern" do
      before do
        allow(HttpChecker).to receive(:check).with(url).and_return(CheckOutcome.new(**base_outcome_attrs))
      end

      it "returns metadata[:matched] = true" do
        result = described_class.check(url: url, pattern: pattern)
        expect(result.metadata[:matched]).to be true
      end

      it "preserves pattern in metadata" do
        result = described_class.check(url: url, pattern: pattern)
        expect(result.metadata[:pattern]).to eq(pattern)
      end

      it "leaves error_message nil so the job classifies via metadata" do
        expect(described_class.check(url: url, pattern: pattern).error_message).to be_nil
      end

      it "passes through the HTTP status_code" do
        expect(described_class.check(url: url, pattern: pattern).status_code).to eq(200)
      end
    end

    context "when the HTTP response body does NOT contain the pattern" do
      before do
        allow(HttpChecker).to receive(:check).with(url)
          .and_return(CheckOutcome.new(**base_outcome_attrs.merge(body: "Hello from the other page")))
      end

      it "returns metadata[:matched] = false" do
        expect(described_class.check(url: url, pattern: pattern).metadata[:matched]).to be false
      end

      it "does NOT set error_message — the job decides via metadata[:matched]" do
        expect(described_class.check(url: url, pattern: pattern).error_message).to be_nil
      end
    end

    context "when the HTTP call fails at the transport layer" do
      let(:transport_failure) do
        CheckOutcome.new(**base_outcome_attrs.merge(
          status_code: nil,
          error_message: "Faraday::ConnectionFailed: refused",
          body: nil
        ))
      end

      before do
        allow(HttpChecker).to receive(:check).with(url).and_return(transport_failure)
      end

      it "passes the HTTP failure outcome through unchanged" do
        result = described_class.check(url: url, pattern: pattern)
        expect(result.error_message).to include("Faraday::ConnectionFailed")
        expect(result.metadata).to eq({})
      end
    end

    context "when the HTTP response has an empty body" do
      before do
        allow(HttpChecker).to receive(:check).with(url)
          .and_return(CheckOutcome.new(**base_outcome_attrs.merge(body: "")))
      end

      it "returns metadata[:matched] = false (empty body never matches a non-empty pattern)" do
        expect(described_class.check(url: url, pattern: pattern).metadata[:matched]).to be false
      end
    end

    context "when the HTTP response body is nil" do
      before do
        allow(HttpChecker).to receive(:check).with(url)
          .and_return(CheckOutcome.new(**base_outcome_attrs.merge(body: nil)))
      end

      it "handles nil body gracefully and returns metadata[:matched] = false" do
        expect(described_class.check(url: url, pattern: pattern).metadata[:matched]).to be false
      end
    end
  end
end
