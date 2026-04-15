require "faraday"
require "json"

module AlertChannels
  # Posts to a Slack Incoming Webhook URL (the per-preference `target`).
  #
  # Locked payload contract (see plan's "Slack payload contract" decision):
  #
  #   {
  #     "text":   "[dorm-guard] <name> is <event>",   # always present, human-readable fallback
  #     "blocks": [...]                                # optional rich rendering, additive-only
  #   }
  #
  # Mobile notifications and low-fidelity bots fall back to `text` when they
  # cannot render `blocks`. Additional `blocks` entries may be added in later
  # slices without bumping the contract — the `text` field stays stable.
  class Slack < Base
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    def deliver(site:, event:, check_result:, target:)
      response = connection.post(target) do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(build_payload(site: site, event: event))
      end

      raise DeliveryError, "slack webhook returned HTTP #{response.status}" unless response.success?

      true
    rescue Faraday::Error => e
      raise DeliveryError, "slack delivery failed: #{e.class}: #{e.message}"
    end

    private

    def build_payload(site:, event:)
      {
        text: "[dorm-guard] #{site.name} is #{event}",
        blocks: [
          {
            type: "section",
            text: {
              type: "mrkdwn",
              text: "*#{site.name}* is *#{event}*\n<#{site.url}|#{site.url}>"
            }
          }
        ]
      }
    end

    def connection
      Faraday.new do |f|
        f.use SsrfGuard
        f.options.open_timeout = OPEN_TIMEOUT
        f.options.timeout = READ_TIMEOUT
      end
    end
  end
end
