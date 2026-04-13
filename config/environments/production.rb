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

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates. Host comes
  # from ENV so the same image deploys to any domain.
  config.action_mailer.default_url_options = {
    host: ENV.fetch("DORM_GUARD_HOST", "dorm-guard.com"),
    protocol: "https"
  }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

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
