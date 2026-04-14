class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("DORM_GUARD_MAIL_FROM", "dorm-guard@dorm-guard.com")
  layout "mailer"
end
