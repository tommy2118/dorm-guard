module AlertChannels
  # Canonical set of event atoms. Referenced by AlertPreference validation,
  # AlertDispatcher transition logic, Email channel mailer-action lookup,
  # Webhook channel payload building, and the UI. Change in one place.
  EVENTS = %w[down up degraded].freeze

  # Raised by concrete channels on delivery failure. The dispatcher catches
  # this per-channel and logs + continues; any other exception bubbles up and
  # the job retries under the Solid Queue default policy.
  class DeliveryError < StandardError; end
end
