require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Kamal's Thruster proxy probes /up over plain HTTP inside the container
  # before TLS is wired up. Both the SSL redirect middleware and the host
  # authorization middleware need to let /up through, so the exclusion
  # predicate is shared.
  health_check_exclude = ->(request) { request.path == "/up" }

  # Kamal's Thruster proxy terminates TLS and forwards to Puma over plain HTTP
  # inside the container; `assume_ssl` tells Rails to treat the forwarded
  # request as secure, and `force_ssl` redirects any still-plain-HTTP traffic
  # that reaches Puma directly.
  config.assume_ssl = true
  config.force_ssl = true
  config.ssl_options = { redirect: { exclude: health_check_exclude } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Deliver mail through SMTP. Provider is chosen at deploy time via
  # SMTP_ADDRESS; currently pointed at Amazon SES
  # (email-smtp.us-east-1.amazonaws.com, AUTH LOGIN, STARTTLS on 587).
  # Credentials come from ENV via .env / Kamal's secrets plumbing so
  # the image builds without master.key and CI stays symmetric with
  # laptop. Accepted trade-off: delivery errors are swallowed so a
  # transient SMTP hiccup doesn't pollute Solid Queue's failed-job
  # table on every downtime alert. Cost: outage or credential rot
  # silently drops alerts — smoke testing and the provider's
  # dashboard (CloudWatch / SES console for SES) are the external
  # backstops. Revisit in Epic 6 when mail is one of several alert
  # channels and per-channel error visibility matters more.
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = false
  config.action_mailer.smtp_settings = {
    address:              ENV.fetch("SMTP_ADDRESS", "email-smtp.us-east-1.amazonaws.com"),
    port:                 ENV.fetch("SMTP_PORT", "587").to_i,
    user_name:            ENV.fetch("SMTP_USER_NAME"),
    password:             ENV.fetch("SMTP_PASSWORD"),
    authentication:       :login,
    enable_starttls_auto: true
  }

  # Set host to be used by links generated in mailer templates. Host comes
  # from ENV so the same image deploys to any domain.
  config.action_mailer.default_url_options = {
    host: ENV.fetch("DORM_GUARD_HOST", "dorm-guard.com"),
    protocol: "https"
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other Host header attacks. The host
  # allowlist reads from the same ENV var as default_url_options so there's
  # exactly one source of truth for the public domain per deploy.
  config.hosts = [ ENV.fetch("DORM_GUARD_HOST", "dorm-guard.com") ]

  # Kamal's /up health probe arrives with the container's internal Host
  # header, not the public domain, so the allowlist needs to let it through.
  config.host_authorization = { exclude: health_check_exclude }
end
