require "resolv"
require "ipaddr"

# Faraday middleware that blocks outbound HTTP requests targeting private,
# loopback, link-local, or otherwise non-public IP space.
#
# Applies a two-phase check:
#   1. Literal IP fast path — if the hostname parses as an IP address,
#      evaluate it directly without DNS resolution.
#   2. DNS resolution — for hostname-based URLs, resolve all A/AAAA records
#      and block if any resolved address falls in a blocked range.
#
# Raises BlockedIpError (a Faraday::Error subclass) so the existing
# `rescue Faraday::Error` in HttpChecker catches it and returns an error
# Result rather than propagating an unhandled exception.
#
# NOTE: This guard does not protect against DNS rebinding attacks. The resolved
# IP is checked at request-initiation time only; a TTL-0 rebinding attack can
# switch the IP after this check completes. Full rebinding protection requires
# a custom adapter that pins the resolved peer for the lifetime of the
# connection — deferred to a future security epic.
#
# NOTE: If redirect-following middleware is added to the Faraday stack in the
# future, SsrfGuard must be positioned before it so every hop is validated.
class SsrfGuard < Faraday::Middleware
  # All non-public unicast ranges. Defined as "anything that is not globally
  # routable public address space" rather than a partial denylist.
  BLOCKED_RANGES = [
    IPAddr.new("0.0.0.0/8"),       # This-network (RFC 1122)
    IPAddr.new("10.0.0.0/8"),      # RFC 1918 private
    IPAddr.new("100.64.0.0/10"),   # Carrier-grade NAT (RFC 6598)
    IPAddr.new("127.0.0.0/8"),     # Loopback (RFC 1122)
    IPAddr.new("169.254.0.0/16"),  # Link-local + cloud metadata (RFC 3927)
    IPAddr.new("172.16.0.0/12"),   # RFC 1918 private
    IPAddr.new("192.168.0.0/16"),  # RFC 1918 private
    IPAddr.new("198.18.0.0/15"),   # Benchmark testing (RFC 2544)
    IPAddr.new("::1/128"),         # IPv6 loopback
    IPAddr.new("fc00::/7"),        # IPv6 ULA — covers fc00::/8 and fd00::/8
    IPAddr.new("fe80::/10")       # IPv6 link-local
  ].freeze

  class BlockedIpError < Faraday::Error; end

  def call(env)
    hostname = env.url.hostname.to_s

    block!(hostname) if blocked_literal_ip?(hostname)

    addresses = Resolv.getaddresses(hostname)
    raise BlockedIpError, "SSRF blocked: #{hostname} did not resolve" if addresses.empty?

    addresses.each { |addr| block!(addr) }

    @app.call(env)
  end

  private

  # Returns true when +str+ is a valid IP address literal that falls within
  # a blocked range. Returns false when +str+ is a hostname (not an IP literal),
  # allowing the caller to proceed to DNS resolution.
  def blocked_literal_ip?(str)
    ip = IPAddr.new(str)
    BLOCKED_RANGES.any? { |range| range.include?(ip) }
  rescue IPAddr::InvalidAddressError
    false # str is a hostname, not a literal IP — proceed to DNS resolution
  end

  # Raises BlockedIpError if +addr+ is in a blocked range or cannot be parsed.
  # Fail-closed: an unparsable resolved address is treated as blocked.
  def block!(addr)
    ip = IPAddr.new(addr.to_s)
    if BLOCKED_RANGES.any? { |range| range.include?(ip) }
      raise BlockedIpError, "SSRF blocked: #{addr} is a private/reserved address"
    end
  rescue IPAddr::InvalidAddressError
    raise BlockedIpError, "SSRF blocked: #{addr} is not a valid IP address"
  end
end
