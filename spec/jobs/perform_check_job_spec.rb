require "rails_helper"

RSpec.describe PerformCheckJob, type: :job do
  let(:site) do
    Site.create!(name: "Example", url: "https://example.com", interval_seconds: 60)
  end
  let(:checked_at) { Time.current }
  let(:result) do
    CheckOutcome.new(
      status_code: 200,
      response_time_ms: 42,
      error_message: nil,
      checked_at: checked_at,
      body: nil,
      metadata: {}
    )
  end

  before do
    allow(CheckDispatcher).to receive(:call).with(site).and_return(result)
  end

  # The N=2 debounce introduced in Slice 3 requires two consecutive same-status
  # checks before Site#status commits. Use this helper wherever a test is
  # asserting the CONFIRMED status after a transition.
  def run_until_confirmed(target_site = site)
    2.times { described_class.perform_now(target_site.id) }
  end

  describe "#perform" do
    it "creates a CheckResult from the dispatched checker response" do
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
        run_until_confirmed
        expect(site.reload).to be_up
      end
    end

    context "when the check returns 3xx" do
      let(:result) do
        CheckOutcome.new(
          status_code: 302,
          response_time_ms: 10,
          error_message: nil,
          checked_at: checked_at,
          body: nil,
          metadata: {}
        )
      end

      it "marks the site as up" do
        run_until_confirmed
        expect(site.reload).to be_up
      end
    end

    context "when the check returns 4xx" do
      let(:result) do
        CheckOutcome.new(
          status_code: 404,
          response_time_ms: 10,
          error_message: nil,
          checked_at: checked_at,
          body: nil,
          metadata: {}
        )
      end

      it "marks the site as down" do
        run_until_confirmed
        expect(site.reload).to be_down
      end
    end

    context "when the check returns 5xx" do
      let(:result) do
        CheckOutcome.new(
          status_code: 503,
          response_time_ms: 10,
          error_message: nil,
          checked_at: checked_at,
          body: nil,
          metadata: {}
        )
      end

      it "marks the site as down" do
        run_until_confirmed
        expect(site.reload).to be_down
      end
    end

    context "when an SSL site's result carries metadata[:classification]" do
      let(:ssl_site) do
        Site.create!(
          name: "Secure site",
          url: "https://example.com",
          interval_seconds: 60,
          check_type: :ssl,
          tls_port: 443
        )
      end

      before { allow(CheckDispatcher).to receive(:call).with(ssl_site).and_return(classified_result) }

      context "with classification :degraded" do
        let(:classified_result) do
          CheckOutcome.new(
            status_code: nil,
            response_time_ms: 120,
            error_message: nil,
            checked_at: checked_at,
            body: nil,
            metadata: { cert_not_after: Time.current + 20 * 86_400, classification: :degraded }
          )
        end

        it "transitions the site to :degraded" do
          run_until_confirmed(ssl_site)
          expect(ssl_site.reload).to be_degraded
        end
      end

      context "with classification :up" do
        let(:classified_result) do
          CheckOutcome.new(
            status_code: nil,
            response_time_ms: 120,
            error_message: nil,
            checked_at: checked_at,
            body: nil,
            metadata: { cert_not_after: Time.current + 60 * 86_400, classification: :up }
          )
        end

        it "transitions the site to :up" do
          run_until_confirmed(ssl_site)
          expect(ssl_site.reload).to be_up
        end
      end
    end

    context "when an HTTP site's response exceeds slow_threshold_ms" do
      let(:site) do
        Site.create!(
          name: "Slow API", url: "https://example.com",
          interval_seconds: 60, slow_threshold_ms: 500
        )
      end

      let(:result) do
        CheckOutcome.new(
          status_code: 200,
          response_time_ms: 1200,
          error_message: nil,
          checked_at: checked_at,
          body: nil,
          metadata: {}
        )
      end

      it "transitions the site to :degraded" do
        run_until_confirmed
        expect(site.reload).to be_degraded
      end
    end

    context "when an HTTP site's response is faster than slow_threshold_ms" do
      let(:site) do
        Site.create!(
          name: "Fast API", url: "https://example.com",
          interval_seconds: 60, slow_threshold_ms: 500
        )
      end

      let(:result) do
        CheckOutcome.new(
          status_code: 200,
          response_time_ms: 100,
          error_message: nil,
          checked_at: checked_at,
          body: nil,
          metadata: {}
        )
      end

      it "keeps the site :up" do
        run_until_confirmed
        expect(site.reload).to be_up
      end
    end

    context "when the site has expected_status_codes set" do
      let(:site) do
        Site.create!(
          name: "API", url: "https://example.com", interval_seconds: 60,
          expected_status_codes: [ 200, 301 ]
        )
      end

      context "and the response status is in the allowlist" do
        let(:result) do
          CheckOutcome.new(
            status_code: 301,
            response_time_ms: 10,
            error_message: nil,
            checked_at: checked_at,
            body: nil,
            metadata: {}
          )
        end

        it "marks the site as up" do
          run_until_confirmed
          expect(site.reload).to be_up
        end
      end

      context "and the response status is NOT in the allowlist" do
        let(:result) do
          CheckOutcome.new(
            status_code: 202,
            response_time_ms: 10,
            error_message: nil,
            checked_at: checked_at,
            body: nil,
            metadata: {}
          )
        end

        it "marks the site as down (allowlist is an override, not an addition)" do
          run_until_confirmed
          expect(site.reload).to be_down
        end
      end
    end

    # PR #26 review finding: the slow-response downgrade must apply AFTER
    # the allowlist success verdict, not be short-circuited by it. A 200 in
    # the allowlist that's also slow should be :degraded, not :up.
    context "when an allowlist-success site is also slow" do
      let(:site) do
        Site.create!(
          name: "Slow allowlisted API",
          url: "https://example.com",
          interval_seconds: 60,
          expected_status_codes: [ 200, 301 ],
          slow_threshold_ms: 500
        )
      end

      let(:result) do
        CheckOutcome.new(
          status_code: 200,
          response_time_ms: 1200,
          error_message: nil,
          checked_at: checked_at,
          body: nil,
          metadata: {}
        )
      end

      it "downgrades allowlist-success to :degraded on slow response" do
        run_until_confirmed
        expect(site.reload).to be_degraded
      end
    end

    context "when an allowlist-miss response is also slow" do
      let(:site) do
        Site.create!(
          name: "Failing slow API",
          url: "https://example.com",
          interval_seconds: 60,
          expected_status_codes: [ 200, 301 ],
          slow_threshold_ms: 500
        )
      end

      let(:result) do
        CheckOutcome.new(
          status_code: 500,
          response_time_ms: 1200,
          error_message: nil,
          checked_at: checked_at,
          body: nil,
          metadata: {}
        )
      end

      it "stays :down — failure trumps slowness" do
        run_until_confirmed
        expect(site.reload).to be_down
      end
    end

    context "when a content-match check reports matched: false" do
      let(:result) do
        CheckOutcome.new(
          status_code: 200,
          response_time_ms: 42,
          error_message: nil,
          checked_at: checked_at,
          body: "hello",
          metadata: { matched: false, pattern: "welcome" }
        )
      end

      it "marks the site as down even though HTTP returned 200" do
        run_until_confirmed
        expect(site.reload).to be_down
      end
    end

    context "when a content-match check reports matched: true" do
      let(:result) do
        CheckOutcome.new(
          status_code: 200,
          response_time_ms: 42,
          error_message: nil,
          checked_at: checked_at,
          body: "welcome aboard",
          metadata: { matched: true, pattern: "welcome" }
        )
      end

      it "marks the site as up" do
        run_until_confirmed
        expect(site.reload).to be_up
      end
    end

    context "when the check succeeds with nil status_code (non-HTTP check type)" do
      let(:result) do
        CheckOutcome.new(
          status_code: nil,
          response_time_ms: 12,
          error_message: nil,
          checked_at: checked_at,
          body: nil,
          metadata: { cert_not_after: Time.current + 90 * 86_400 }
        )
      end

      it "marks the site as up (nil status_code + nil error_message = success for non-HTTP)" do
        run_until_confirmed
        expect(site.reload).to be_up
      end
    end

    context "when the check has a transport-level error" do
      let(:result) do
        CheckOutcome.new(
          status_code: nil,
          response_time_ms: 500,
          error_message: "Faraday::ConnectionFailed: refused",
          checked_at: checked_at,
          body: nil,
          metadata: {}
        )
      end

      it "marks the site as down" do
        run_until_confirmed
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

  describe "AlertDispatcher integration" do
    let(:down_result) do
      CheckOutcome.new(
        status_code: 503,
        response_time_ms: 50,
        error_message: nil,
        checked_at: Time.current,
        body: nil,
        metadata: {}
      )
    end
    let(:up_result) do
      CheckOutcome.new(
        status_code: 200,
        response_time_ms: 50,
        error_message: nil,
        checked_at: Time.current,
        body: nil,
        metadata: {}
      )
    end

    context "when the debounce confirms a up → down transition (after 2 consecutive checks)" do
      before do
        site.update!(status: :up)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(down_result)
      end

      it "invokes AlertDispatcher with from: 'up' and to: 'down' on the committing check" do
        described_class.perform_now(site.id)  # stashes candidate=down
        expect(AlertDispatcher).to receive(:call).with(
          hash_including(site: site, from: "up", to: "down")
        )
        described_class.perform_now(site.id)  # commits → dispatcher fires
      end
    end

    context "when the debounce confirms a down → up transition (after 2 consecutive checks)" do
      before do
        site.update!(status: :down)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(up_result)
      end

      it "invokes AlertDispatcher with from: 'down' and to: 'up' on the committing check" do
        described_class.perform_now(site.id)  # stashes candidate=up
        expect(AlertDispatcher).to receive(:call).with(
          hash_including(site: site, from: "down", to: "up")
        )
        described_class.perform_now(site.id)  # commits → dispatcher fires
      end
    end

    context "when the debounce confirms a up → degraded transition" do
      before do
        site.update!(status: :up, slow_threshold_ms: 500)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(
          CheckOutcome.new(
            status_code: 200,
            response_time_ms: 5000,
            error_message: nil,
            checked_at: Time.current,
            body: nil,
            metadata: {}
          )
        )
      end

      it "invokes AlertDispatcher with from: 'up' and to: 'degraded' on the committing check" do
        described_class.perform_now(site.id)
        expect(AlertDispatcher).to receive(:call).with(
          hash_including(site: site, from: "up", to: "degraded")
        )
        described_class.perform_now(site.id)
      end
    end

    context "when a single-check blip does NOT commit a status change" do
      before do
        site.update!(status: :up)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(down_result)
      end

      it "invokes AlertDispatcher with from: 'up' and to: 'up' (the debounce stash) — no event" do
        # The first check stashes candidate=:down but does NOT commit status. The
        # dispatcher sees up → up and returns early without dispatching anything.
        expect(AlertDispatcher).to receive(:call).with(
          hash_including(site: site, from: "up", to: "up")
        )
        described_class.perform_now(site.id)
      end
    end

    context "when the site stays :up (up → up, stable)" do
      before do
        site.update!(status: :up)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(up_result)
      end

      it "invokes AlertDispatcher with from: 'up' and to: 'up' (a no-alert transition)" do
        expect(AlertDispatcher).to receive(:call).with(
          hash_including(site: site, from: "up", to: "up")
        )
        described_class.perform_now(site.id)
      end
    end
  end
end
