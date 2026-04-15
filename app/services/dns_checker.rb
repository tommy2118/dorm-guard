require "resolv"

# Resolves a hostname via Resolv.getaddresses. Succeeds if ≥1 address.
#
# Does NOT use IpGuard — DNS resolution is the check itself, not the target
# of a connect. Blocking lookups of private hostnames would defeat the point
# of monitoring whether they resolve (an "internal.corp" DNS check is
# explicitly asking "does our internal DNS still work?").
class DnsChecker
  RECOVERABLE_ERRORS = [
    Resolv::ResolvError,
    IOError
  ].freeze

  def self.check(hostname:)
    new.check(hostname: hostname)
  end

  def check(hostname:)
    started_at = Time.current
    addresses = Resolv.getaddresses(hostname.to_s)
    if addresses.empty?
      build_outcome(started_at, error: "no addresses resolved for #{hostname}", metadata: { resolved_addresses: [] })
    else
      build_outcome(started_at, error: nil, metadata: { resolved_addresses: addresses })
    end
  rescue *RECOVERABLE_ERRORS => e
    build_outcome(started_at, error: "#{e.class}: #{e.message}", metadata: {})
  end

  private

  def build_outcome(started_at, error:, metadata:)
    CheckOutcome.new(
      status_code: nil,
      response_time_ms: elapsed_ms(started_at),
      error_message: error,
      checked_at: started_at,
      body: nil,
      metadata: metadata
    )
  end

  def elapsed_ms(started_at)
    ((Time.current - started_at) * 1000).round
  end
end
