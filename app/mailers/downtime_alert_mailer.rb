class DowntimeAlertMailer < ApplicationMailer
  DEFAULT_RECIPIENT = "alerts@dorm-guard.local".freeze

  def site_down
    @site = params[:site]
    mail(to: recipient, subject: "[dorm-guard] #{@site.name} is down")
  end

  def site_recovered
    @site = params[:site]
    mail(to: recipient, subject: "[dorm-guard] #{@site.name} has recovered")
  end

  def site_degraded
    @site = params[:site]
    mail(to: recipient, subject: "[dorm-guard] #{@site.name} is degraded")
  end

  private

  def recipient
    ENV.fetch("DORM_GUARD_ALERT_TO", DEFAULT_RECIPIENT)
  end
end
