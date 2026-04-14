require "openssl"
require "socket"
require "timeout"

# Opens a TLS socket to host:port, extracts the peer certificate, and reports
# :up / :down based on cert expiry. Two-state in Slice 3; Slice 10 extends to
# 3-state so certs expiring in 8-30 days flip Site.status to :degraded.
#
# Connection semantics: TCP connect bounded by CONNECT_TIMEOUT via Socket.tcp;
# TLS handshake bounded by HANDSHAKE_TIMEOUT via Timeout.timeout. The Timeout
# wrapper on socket I/O is technically unsafe (async interrupt can leak an FD)
# but the ensure block closes both sockets and the monitoring use case tolerates
# the rare leak — the stdlib alternative (non-blocking IO + IO.select) is much
# more code for a check that runs on a 60s cadence.
class SslChecker
  CONNECT_TIMEOUT = 5
  HANDSHAKE_TIMEOUT = 10
  CRITICAL_DAYS = 7

  RECOVERABLE_ERRORS = [
    IpGuard::BlockedIpError,
    SocketError,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    OpenSSL::SSL::SSLError,
    Timeout::Error
  ].freeze

  def self.check(host:, port:)
    new.check(host: host, port: port)
  end

  def check(host:, port:)
    started_at = Time.current
    IpGuard.check!(host)
    cert = with_tls_socket(host, port, &:peer_cert)
    classify(cert, started_at)
  rescue *RECOVERABLE_ERRORS => e
    error_outcome(e, started_at)
  end

  private

  def with_tls_socket(host, port)
    tcp = Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT)
    ssl = OpenSSL::SSL::SSLSocket.new(tcp)
    ssl.hostname = host
    Timeout.timeout(HANDSHAKE_TIMEOUT) { ssl.connect }
    yield ssl
  ensure
    ssl&.close
    tcp&.close
  end

  def classify(cert, started_at)
    days = days_until_expiry(cert)
    build_outcome(started_at, error: cert_error(days), metadata: cert_metadata(cert, days))
  end

  def days_until_expiry(cert)
    ((cert.not_after - Time.current) / 86_400).to_i
  end

  def cert_metadata(cert, days)
    {
      cert_not_after: cert.not_after,
      cert_subject: cert.subject.to_s,
      days_until_expiry: days
    }
  end

  def cert_error(days)
    return nil if days >= CRITICAL_DAYS

    "cert expires in #{days} days"
  end

  def build_outcome(started_at, error:, metadata: {})
    CheckOutcome.new(
      status_code: nil,
      response_time_ms: elapsed_ms(started_at),
      error_message: error,
      checked_at: started_at,
      body: nil,
      metadata: metadata
    )
  end

  def error_outcome(error, started_at)
    build_outcome(started_at, error: "#{error.class}: #{error.message}")
  end

  def elapsed_ms(started_at)
    ((Time.current - started_at) * 1000).round
  end
end
