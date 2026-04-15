# Faraday middleware that blocks outbound HTTP requests targeting private,
# loopback, link-local, or otherwise non-public IP space.
#
# Delegates the IP-range check to IpGuard so non-Faraday checkers (TCP, DNS,
# SSL) share the same blocked-range list.
#
# NOTE: Does not protect against DNS rebinding — see IpGuard for the rationale
# and the deferred follow-up.
#
# NOTE: Must be positioned before any redirect middleware so every hop in a
# redirect chain is revalidated. See http_checker.rb connection().
class SsrfGuard < Faraday::Middleware
  class BlockedIpError < Faraday::Error; end

  def call(env)
    IpGuard.check!(env.url.hostname.to_s)
    @app.call(env)
  rescue IpGuard::BlockedIpError => e
    raise BlockedIpError, e.message
  end
end
