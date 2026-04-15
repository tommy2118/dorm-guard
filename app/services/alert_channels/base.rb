module AlertChannels
  # Abstract interface. Exists only to pin the signature — concrete channels
  # implement #deliver and raise AlertChannels::DeliveryError on failure.
  #
  # `target` is the per-preference destination: an email address for the
  # Email channel, a webhook URL for Slack/Webhook. Each concrete channel
  # interprets it independently.
  class Base
    def deliver(site:, event:, check_result:, target:)
      raise NotImplementedError
    end
  end
end
