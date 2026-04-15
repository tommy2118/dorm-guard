class PerformCheckJob < ApplicationJob
  queue_as :default

  def perform(site_id)
    site = Site.find(site_id)
    previous_status = site.status
    result = CheckDispatcher.call(site)
    apply_result(site, result)
    AlertDispatcher.call(site: site, from: previous_status, to: site.status, check_result: latest_check_result(site))
  end

  private

  def apply_result(site, result)
    site.transaction do
      record_check(site, result)
      update_site(site, result)
    end
  end

  def record_check(site, result)
    CheckResult.create!(
      site: site,
      status_code: result.status_code,
      response_time_ms: result.response_time_ms,
      error_message: result.error_message,
      checked_at: result.checked_at
    )
  end

  def update_site(site, result)
    derived = derive_status(site, result)
    proposed = site.propose_status(derived)
    site.update!(
      status: proposed,
      candidate_status: site.candidate_status,
      candidate_status_at: site.candidate_status_at,
      last_checked_at: result.checked_at
    )
  end

  # Classification rules (decision 3 + plan Slice 10, corrected by PR #26 review):
  #   1. SSL sites carry a self-classification in metadata[:classification]
  #      because the signal is temporal — checker owns it, job just reads it.
  #   2. Any error_message means :down.
  #   3. A content-match site with metadata[:matched] == false means :down
  #      even if the underlying HTTP call returned 200.
  #   4. Non-HTTP checks (TCP / DNS) signal success via nil error_message and
  #      no status_code.
  #   5. HTTP/content-match status verdict comes from the explicit
  #      expected_status_codes allowlist (full override when set) or the
  #      default 200-399 range.
  #   6. A :down HTTP verdict is final — failure trumps slowness.
  #   7. A :up HTTP verdict is downgraded to :degraded when slow_threshold_ms
  #      is set and response_time_ms exceeds it. This applies symmetrically
  #      to allowlist-success and 200-399-success paths.
  def derive_status(site, result)
    return result.metadata[:classification] if site.ssl? && result.metadata[:classification]
    return :down if result.error_message.present?
    return :down if result.metadata[:matched] == false
    return :up if result.status_code.nil?

    verdict = http_status_verdict(site, result)
    return :down if verdict == :down
    return :degraded if slow_http_response?(site, result)

    verdict
  end

  def http_status_verdict(site, result)
    if site.expected_status_codes.present?
      return site.expected_status_codes.include?(result.status_code) ? :up : :down
    end

    result.status_code.between?(200, 399) ? :up : :down
  end

  def slow_http_response?(site, result)
    return false unless site.http? || site.content_match?
    return false if site.slow_threshold_ms.blank?
    return false if result.response_time_ms.nil?

    result.response_time_ms > site.slow_threshold_ms
  end

  # Fetch the row PerformCheckJob just inserted. The dispatcher needs a
  # persisted CheckResult to serialize into the webhook payload; reading
  # from the database (rather than constructing from the CheckOutcome)
  # keeps the payload contract aligned with what the UI shows.
  def latest_check_result(site)
    site.check_results.order(checked_at: :desc).first
  end
end
