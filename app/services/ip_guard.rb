require "resolv"
require "ipaddr"

# Standalone SSRF guard. Faraday-agnostic so socket-level checkers (TCP, DNS,
# SSL) can call it before opening any connection.
#
# Fail-closed invariants:
# - NXDOMAIN (empty resolve) raises rather than passes.
# - Unparsable resolved addresses raise rather than being skipped.
# - Multi-address resolution: any single blocked address blocks the whole host.
#
# Does not protect against DNS rebinding. The resolved IP is checked at
# call-time; a TTL-0 rebind can switch the peer after the check returns.
# Full protection requires a custom adapter pinning the resolved peer for
# the connection lifetime — deferred to a future security epic.
class IpGuard
  class BlockedIpError < StandardError; end

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
    IPAddr.new("fe80::/10")        # IPv6 link-local
  ].freeze

  def self.check!(host_or_ip)
    if literal_ip?(host_or_ip)
      assert_public!(host_or_ip)
      return true
    end

    addresses = Resolv.getaddresses(host_or_ip)
    raise BlockedIpError, "SSRF blocked: #{host_or_ip} did not resolve" if addresses.empty?

    addresses.each { |addr| assert_public!(addr) }
    true
  end

  def self.literal_ip?(str)
    IPAddr.new(str.to_s)
    true
  rescue IPAddr::InvalidAddressError
    false
  end

  def self.assert_public!(addr)
    ip = IPAddr.new(addr.to_s)
    return unless BLOCKED_RANGES.any? { |range| range.include?(ip) }

    raise BlockedIpError, "SSRF blocked: #{addr} is a private/reserved address"
  rescue IPAddr::InvalidAddressError
    raise BlockedIpError, "SSRF blocked: #{addr} is not a valid IP address"
  end
end
