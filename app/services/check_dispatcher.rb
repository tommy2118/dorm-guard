require "uri"

# Routes a Site to the checker implementation that matches its check_type.
#
# Contract: CheckDispatcher is a thin routing boundary. It may do exactly
# three things: read site.check_type, extract primitives from the Site record,
# and call the matching checker. It must NOT accumulate validation, status
# derivation, fallback behavior, retry, logging, or default substitution.
# Any logic that pools here is a god-object seed — every future check type
# inherits it. The dispatcher spec pins this public surface (only .call)
# structurally; adding a second public method turns it red on purpose.
class CheckDispatcher
  class UnknownCheckType < StandardError
    def initialize(check_type)
      super("CheckDispatcher has no route for check_type=#{check_type.inspect}")
    end
  end

  def self.call(site)
    case site.check_type
    when "http"
      HttpChecker.check(site.url)
    when "ssl"
      SslChecker.check(host: URI.parse(site.url).host, port: site.tls_port)
    when "tcp"
      TcpChecker.check(host: URI.parse(site.url).host, port: site.tcp_port)
    when "dns"
      DnsChecker.check(hostname: site.dns_hostname)
    when "content_match"
      ContentMatchChecker.check(url: site.url, pattern: site.content_match_pattern)
    else
      raise UnknownCheckType, site.check_type
    end
  end
end
