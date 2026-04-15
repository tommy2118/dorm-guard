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
        described_class.perform_now(site.id)
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
        described_class.perform_now(site.id)
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
        described_class.perform_now(site.id)
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
        described_class.perform_now(site.id)
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
          described_class.perform_now(ssl_site.id)
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
          described_class.perform_now(ssl_site.id)
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
        described_class.perform_now(site.id)
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
        described_class.perform_now(site.id)
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
          described_class.perform_now(site.id)
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
          described_class.perform_now(site.id)
          expect(site.reload).to be_down
        end
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
        described_class.perform_now(site.id)
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
        described_class.perform_now(site.id)
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
        described_class.perform_now(site.id)
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

  describe "downtime alert dispatch" do
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

    context "when status flips from unknown to down (first ever check)" do
      before { allow(CheckDispatcher).to receive(:call).with(site).and_return(down_result) }

      it "enqueues a DowntimeAlertMailer.site_down delivery for the site" do
        expect { described_class.perform_now(site.id) }
          .to have_enqueued_mail(DowntimeAlertMailer, :site_down).with(params: { site: site }, args: [])
      end
    end

    context "when status flips from up to down" do
      before do
        site.update!(status: :up)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(down_result)
      end

      it "enqueues a DowntimeAlertMailer.site_down delivery" do
        expect { described_class.perform_now(site.id) }
          .to have_enqueued_mail(DowntimeAlertMailer, :site_down).with(params: { site: site }, args: [])
      end
    end

    context "when the site was already down (down→down)" do
      before do
        site.update!(status: :down)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(down_result)
      end

      it "does NOT enqueue another alert (no spam)" do
        expect { described_class.perform_now(site.id) }
          .not_to have_enqueued_mail(DowntimeAlertMailer)
      end
    end

    context "when status flips from down to up (recovery)" do
      before do
        site.update!(status: :down)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(up_result)
      end

      it "does NOT enqueue an alert (no recovery emails in this slice)" do
        expect { described_class.perform_now(site.id) }
          .not_to have_enqueued_mail(DowntimeAlertMailer)
      end
    end

    context "when status flips to :degraded (not :down)" do
      let(:degraded_http_result) do
        CheckOutcome.new(
          status_code: 200,
          response_time_ms: 5000,
          error_message: nil,
          checked_at: Time.current,
          body: nil,
          metadata: {}
        )
      end

      before do
        site.update!(status: :up)
        # Force derive_status to return :degraded by stubbing it directly —
        # Slice 9 doesn't yet emit :degraded from any checker, so we simulate
        # the Slice 10 outcome to assert Slice 9's alert guard.
        allow_any_instance_of(described_class)
          .to receive(:derive_status).and_return(:degraded)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(degraded_http_result)
      end

      it "transitions the site to :degraded" do
        described_class.perform_now(site.id)
        expect(site.reload).to be_degraded
      end

      it "does NOT enqueue a downtime alert (degraded is neither failing nor healthy)" do
        expect { described_class.perform_now(site.id) }
          .not_to have_enqueued_mail(DowntimeAlertMailer)
      end
    end

    context "when the site stays up (up→up)" do
      before do
        site.update!(status: :up)
        allow(CheckDispatcher).to receive(:call).with(site).and_return(up_result)
      end

      it "does NOT enqueue an alert" do
        expect { described_class.perform_now(site.id) }
          .not_to have_enqueued_mail(DowntimeAlertMailer)
      end
    end
  end
end
