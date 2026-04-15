require "faraday"
require "json"

module AlertChannels
  # Posts a documented JSON payload to a generic webhook URL (the
  # per-preference `target`). Stable payload schema:
  #
  #   {
  #     "schema_version": 1,
  #     "site":           { "id": Integer, "name": String, "url": String },
  #     "event":          "down" | "up" | "degraded",
  #     "check_result":   {
  #       "status_code":      Integer | null,
  #       "response_time_ms": Integer | null,
  #       "error_message":    String  | null,
  #       "checked_at":       ISO8601 String
  #     },
  #     "sent_at": ISO8601 String
  #   }
  #
  # Future fields are additive only — existing consumers will not break.
  # The `schema_version` bumps only on a shape change that breaks backwards
  # compatibility.
  class Webhook < Base
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    PAYLOAD_SCHEMA_VERSION = 1

    def deliver(site:, event:, check_result:, target:)
      response = connection.post(target) do |req|
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(build_payload(site: site, event: event, check_result: check_result))
      end

      raise DeliveryError, "webhook returned HTTP #{response.status}" unless response.success?

      true
    rescue Faraday::Error => e
      raise DeliveryError, "webhook delivery failed: #{e.class}: #{e.message}"
    end

    private

    def build_payload(site:, event:, check_result:)
      {
        schema_version: PAYLOAD_SCHEMA_VERSION,
        site: {
          id: site.id,
          name: site.name,
          url: site.url
        },
        event: event.to_s,
        check_result: serialize_check_result(check_result),
        sent_at: Time.current.iso8601
      }
    end

    def serialize_check_result(check_result)
      return nil if check_result.nil?

      {
        status_code: check_result.status_code,
        response_time_ms: check_result.response_time_ms,
        error_message: check_result.error_message,
        checked_at: check_result.checked_at&.iso8601
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
