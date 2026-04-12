class DowntimeAlertMailer < ApplicationMailer
  DEFAULT_RECIPIENT = "alerts@dorm-guard.local".freeze

  def site_down
    @site = params[:site]
    mail(
      to: ENV.fetch("DORM_GUARD_ALERT_TO", DEFAULT_RECIPIENT),
      subject: "[dorm-guard] #{@site.name} is down"
    )
  end
end
