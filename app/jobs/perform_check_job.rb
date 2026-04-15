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

  def derive_status(site, result)
    return :down if result.error_message.present?
    return :down if result.metadata[:matched] == false # content-match miss
    return :up if result.status_code.nil? # non-HTTP checks signal success via nil error_message

    if site.expected_status_codes.present?
      return site.expected_status_codes.include?(result.status_code) ? :up : :down
    end

    result.status_code.between?(200, 399) ? :up : :down
  end

  def notify_if_newly_down(site, previous_status)
    return unless site.failing?
    return if previous_status == "down"

    DowntimeAlertMailer.with(site: site).site_down.deliver_later
  end
end
