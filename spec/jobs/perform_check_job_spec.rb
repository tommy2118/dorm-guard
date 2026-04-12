require "rails_helper"

RSpec.describe PerformCheckJob, type: :job do
  let(:site) do
    Site.create!(name: "Example", url: "https://example.com", interval_seconds: 60)
  end
  let(:checked_at) { Time.current }
  let(:result) do
    HttpChecker::Result.new(
      status_code: 200,
      response_time_ms: 42,
      error_message: nil,
      checked_at: checked_at
    )
  end

  before do
    allow(HttpChecker).to receive(:check).with(site.url).and_return(result)
  end

  describe "#perform" do
    it "creates a CheckResult from the HttpChecker response" do
      expect { described_class.perform_now(site.id) }.to change(CheckResult, :count).by(1)

      check = CheckResult.last
      expect(check.site).to eq(site)
      expect(check.status_code).to eq(200)
      expect(check.response_time_ms).to eq(42)
      expect(check.checked_at).to be_within(1.second).of(checked_at)
    end

    it "updates the site's last_checked_at" do
      described_class.perform_now(site.id)
      expect(site.reload.last_checked_at).to be_within(1.second).of(checked_at)
    end

    context "when the check returns 2xx" do
      it "marks the site as up" do
        described_class.perform_now(site.id)
        expect(site.reload).to be_up
      end
    end

    context "when the check returns 3xx" do
      let(:result) do
        HttpChecker::Result.new(status_code: 302, response_time_ms: 10, error_message: nil, checked_at: checked_at)
      end

      it "marks the site as up" do
        described_class.perform_now(site.id)
        expect(site.reload).to be_up
      end
    end

    context "when the check returns 4xx" do
      let(:result) do
        HttpChecker::Result.new(status_code: 404, response_time_ms: 10, error_message: nil, checked_at: checked_at)
      end

      it "marks the site as down" do
        described_class.perform_now(site.id)
        expect(site.reload).to be_down
      end
    end

    context "when the check returns 5xx" do
      let(:result) do
        HttpChecker::Result.new(status_code: 503, response_time_ms: 10, error_message: nil, checked_at: checked_at)
      end

      it "marks the site as down" do
        described_class.perform_now(site.id)
        expect(site.reload).to be_down
      end
    end

    context "when the check has a transport-level error" do
      let(:result) do
        HttpChecker::Result.new(
          status_code: nil,
          response_time_ms: 500,
          error_message: "Faraday::ConnectionFailed: refused",
          checked_at: checked_at
        )
      end

      it "marks the site as down" do
        described_class.perform_now(site.id)
        expect(site.reload).to be_down
      end

      it "persists the error_message on the CheckResult" do
        described_class.perform_now(site.id)
        expect(CheckResult.last.error_message).to include("Faraday::ConnectionFailed")
      end

      it "persists a nil status_code on the CheckResult" do
        described_class.perform_now(site.id)
        expect(CheckResult.last.status_code).to be_nil
      end
    end
  end
end
