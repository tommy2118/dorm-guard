class AlertDispatcher
  # Canonical set of event atoms. AlertPreference::EVENTS references this.
  EVENTS = AlertChannels::EVENTS

  # Mapping from preference channel enum to concrete channel class.
  CHANNELS = {
    "email"   => AlertChannels::Email,
    "slack"   => AlertChannels::Slack,
    "webhook" => AlertChannels::Webhook
  }.freeze

  def self.call(site:, from:, to:, check_result:)
    new.call(site: site, from: from, to: to, check_result: check_result)
  end

  def call(site:, from:, to:, check_result:)
    event = event_from_transition(from, to)
    return if event.nil?

    # Quiet-hours gate: :down always fires (critical override), everything
    # else is dropped (not deferred) during the configured window.
    return if event != "down" && site.in_quiet_hours?

    # Event-level cooldown gate: a recent alert for the same event type
    # suppresses regardless of channel. Fires once per cooldown window.
    return unless site.alert_cooldown_expired?(event)

    delivered_any = false
    eligible_preferences(site, event).each do |preference|
      channel_class = CHANNELS[preference.channel]
      if channel_class.nil?
        # Unreachable under the current enum + CHANNELS alignment, but a
        # future epic adding a new channel value to AlertPreference.channel
        # without registering it here would silently drop those
        # preferences. Log so the drift is diagnosable from the ops
        # dashboard instead of invisible.
        Rails.logger.warn(
          "[AlertDispatcher] unknown channel #{preference.channel.inspect} " \
            "for site ##{site.id} preference ##{preference.id} — " \
            "missing CHANNELS entry? Skipping."
        )
        next
      end

      begin
        channel_class.new.deliver(
          site: site,
          event: event,
          check_result: check_result,
          target: preference.target
        )
        delivered_any = true
      rescue AlertChannels::DeliveryError => e
        Rails.logger.warn(
          "[AlertDispatcher] #{preference.channel} delivery failed for site ##{site.id} (#{event}): #{e.message}"
        )
      end
    end

    site.record_alert_sent!(event) if delivered_any
  end

  private

  # Transition rules:
  #   - same-state transitions → nil (no alert)
  #   - unknown → up / unknown → degraded → nil (no prior failure to recover from)
  #   - unknown → down → "down" (new failure worth alerting)
  #   - * → down → "down"
  #   - (up | degraded) → up → "up" (recovery)
  #   - down → up → "up" (recovery)
  #   - (up | down) → degraded → "degraded"
  #   - degraded → down → "down"
  #   - degraded → up → "up" (recovery from degraded)
  def event_from_transition(from, to)
    from_s = from.to_s
    to_s = to.to_s
    return nil if from_s == to_s
    return nil if from_s == "unknown" && %w[up degraded].include?(to_s)

    case to_s
    when "down"     then "down"
    when "up"       then "up"
    when "degraded" then "degraded"
    end
  end

  def eligible_preferences(site, event)
    site.alert_preferences.where(enabled: true).select do |preference|
      Array(preference.events).include?(event)
    end
  end
end
