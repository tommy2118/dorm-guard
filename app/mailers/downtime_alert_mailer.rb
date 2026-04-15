class DowntimeAlertMailer < ApplicationMailer
  DEFAULT_RECIPIENT = "alerts@dorm-guard.local".freeze

  def site_down
    deliver_alert("is down")
  end

  def site_recovered
    deliver_alert("has recovered")
  end

  def site_degraded
    deliver_alert("is degraded")
  end

  private

  def deliver_alert(descriptor)
    @site = params[:site]
    mail(to: recipient, subject: "[dorm-guard] #{@site.name} #{descriptor}")
  end

  # Prefer the per-preference recipient passed through .with(recipient:),
  # fall back to ENV (single-recipient mode from before Epic 6), and
  # finally the hardcoded dev default.
  def recipient
    params[:recipient].presence || ENV.fetch("DORM_GUARD_ALERT_TO", DEFAULT_RECIPIENT)
  end
end
