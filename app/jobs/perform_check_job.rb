class PerformCheckJob < ApplicationJob
  queue_as :default

  def perform(site_id)
    site = Site.find(site_id)
    previous_status = site.status
    result = CheckDispatcher.call(site)
    apply_result(site, result)
    notify_if_newly_down(site, previous_status)
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
    site.update!(
      status: derive_status(site, result),
      last_checked_at: result.checked_at
    )
  end

  # Classification rules (decision 3 + plan Slice 10):
  #   1. SSL sites carry a self-classification in metadata[:classification]
  #      because the signal is temporal — checker owns it, job just reads it.
  #   2. Any error_message means :down.
  #   3. A content-match site with metadata[:matched] == false means :down
  #      even if the underlying HTTP call returned 200.
  #   4. Non-HTTP checks (TCP / DNS) signal success via nil error_message and
  #      no status_code.
  #   5. HTTP and content-match sites with an explicit expected_status_codes
  #      list use the list as a full override (not additive).
  #   6. HTTP and content-match sites with a slow_threshold_ms and a
  #      response_time exceeding it go :degraded (Slice 10 emission path).
  #   7. Otherwise HTTP sites fall back to the default 200-399 range.
  def derive_status(site, result)
    return result.metadata[:classification] if site.ssl? && result.metadata[:classification]
    return :down if result.error_message.present?
    return :down if result.metadata[:matched] == false
    return :up if result.status_code.nil?

    if site.expected_status_codes.present?
      return site.expected_status_codes.include?(result.status_code) ? :up : :down
    end

    return :degraded if slow_http_response?(site, result)

    result.status_code.between?(200, 399) ? :up : :down
  end

  def slow_http_response?(site, result)
    return false unless site.http? || site.content_match?
    return false if site.slow_threshold_ms.blank?
    return false if result.response_time_ms.nil?

    result.response_time_ms > site.slow_threshold_ms
  end

  def notify_if_newly_down(site, previous_status)
    return unless site.failing?
    return if previous_status == "down"

    DowntimeAlertMailer.with(site: site).site_down.deliver_later
  end
end
