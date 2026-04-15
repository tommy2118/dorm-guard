module AlertChannels
  class Email < Base
    # Selects the mailer action by event and enqueues the mailer job, directing
    # it to `target` (a per-preference email address). Returns truthy on
    # successful enqueue; raises DeliveryError if the event is unsupported
    # or the underlying job cannot be serialized.
    def deliver(site:, event:, check_result:, target:)
      action = action_for(event)
      raise DeliveryError, "unsupported event: #{event.inspect}" if action.nil?

      DowntimeAlertMailer
        .with(site: site, recipient: target)
        .public_send(action)
        .deliver_later
      true
    rescue ActiveJob::SerializationError => e
      raise DeliveryError, "failed to enqueue #{action} for site ##{site.id}: #{e.message}"
    end

    private

    def action_for(event)
      case event.to_s
      when "down"     then :site_down
      when "up"       then :site_recovered
      when "degraded" then :site_degraded
      end
    end
  end
end
