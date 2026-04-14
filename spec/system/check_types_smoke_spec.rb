require "rails_helper"

# Smoke gate for Epic 5: exercises all four new check types end-to-end
# through the controller, model, dispatcher, job, and index view. All
# external boundaries (HttpChecker, SslChecker, TcpChecker, DnsChecker,
# ContentMatchChecker) are stubbed at the class-method level — this spec
# is network-free per the plan's locked rule and tests the wiring, not
# the individual checkers' logic (those have their own specs).
RSpec.describe "Epic 5 check types smoke", type: :request do
  include AuthHelpers

  let(:user) { User.create!(email_address: "admin@example.com", password: "a_secure_passphrase_16") }

  before { sign_in_as(user) }

  def successful_outcome
    CheckOutcome.new(
      status_code: 200,
      response_time_ms: 15,
      error_message: nil,
      checked_at: Time.current,
      body: "ok",
      metadata: {}
    )
  end

  def failing_outcome(message)
    CheckOutcome.new(
      status_code: nil,
      response_time_ms: 15,
      error_message: message,
      checked_at: Time.current,
      body: nil,
      metadata: {}
    )
  end

  shared_examples "a check type end-to-end" do |check_type:, create_params:, checker_class:, happy_outcome: nil|
    let(:happy) { happy_outcome || successful_outcome }

    it "creates via form, flips to up on success, and flips to down on failure" do
      # Happy path: form submit → site created
      expect {
        post sites_path, params: { site: create_params }
      }.to change(Site, :count).by(1)
      expect(response).to redirect_to(sites_path)

      site = Site.last
      expect(site.check_type).to eq(check_type.to_s)
      expect(site.status).to eq("unknown")

      # Happy path: job run → :up
      allow(checker_class).to receive(:check).and_return(happy)
      PerformCheckJob.perform_now(site.id)
      expect(site.reload.status).to eq("up")

      # Index renders the "up" badge
      get sites_path
      expect(response.body).to include("badge-success")

      # Sad path: same site, job re-run with failing stub → :down
      allow(checker_class).to receive(:check).and_return(failing_outcome("#{check_type} failed"))
      PerformCheckJob.perform_now(site.id)
      expect(site.reload.status).to eq("down")

      get sites_path
      expect(response.body).to include("badge-error")
    end
  end

  describe ":http" do
    include_examples "a check type end-to-end",
                     check_type: :http,
                     create_params: {
                       name: "HTTP site",
                       url: "https://example.com",
                       interval_seconds: 60,
                       check_type: "http"
                     },
                     checker_class: HttpChecker
  end

  describe ":ssl" do
    include_examples "a check type end-to-end",
                     check_type: :ssl,
                     create_params: {
                       name: "SSL site",
                       url: "https://example.com",
                       interval_seconds: 60,
                       check_type: "ssl",
                       tls_port: 443
                     },
                     checker_class: SslChecker
  end

  describe ":tcp" do
    include_examples "a check type end-to-end",
                     check_type: :tcp,
                     create_params: {
                     name: "TCP site",
                       url: "https://example.com",
                       interval_seconds: 60,
                       check_type: "tcp",
                       tcp_port: 22
                     },
                     checker_class: TcpChecker
  end

  describe ":dns" do
    include_examples "a check type end-to-end",
                     check_type: :dns,
                     create_params: {
                       name: "DNS site",
                       interval_seconds: 60,
                       check_type: "dns",
                       dns_hostname: "example.com"
                     },
                     checker_class: DnsChecker
  end

  describe ":content_match" do
    let(:match_outcome) do
      CheckOutcome.new(
        status_code: 200,
        response_time_ms: 10,
        error_message: nil,
        checked_at: Time.current,
        body: "Welcome",
        metadata: { matched: true, pattern: "Welcome" }
      )
    end

    include_examples "a check type end-to-end",
                     check_type: :content_match,
                     create_params: {
                       name: "Content match site",
                       url: "https://example.com",
                       interval_seconds: 60,
                       check_type: "content_match",
                       content_match_pattern: "Welcome"
                     },
                     checker_class: ContentMatchChecker
  end

  describe "rejected input — :tcp site submitted with no tcp_port" do
    it "re-renders new with validation errors" do
      expect {
        post sites_path, params: {
          site: {
            name: "Bad TCP",
            url: "https://example.com",
            interval_seconds: 60,
            check_type: "tcp"
            # tcp_port intentionally missing
          }
        }
      }.not_to change(Site, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("TCP port")
    end
  end
end
