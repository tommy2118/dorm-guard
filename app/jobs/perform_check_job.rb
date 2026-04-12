class PerformCheckJob < ApplicationJob
  queue_as :default

  def perform(site_id)
    site = Site.find(site_id)
    result = HttpChecker.check(site.url)
    site.transaction do
      record_check(site, result)
      update_site(site, result)
    end
  end

  private

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
      status: derive_status(result),
      last_checked_at: result.checked_at
    )
  end

  def derive_status(result)
    return :down if result.error_message.present?

    result.status_code.between?(200, 399) ? :up : :down
  end
end
