require "openssl"
require "socket"
require "timeout"

# Opens a TLS socket to host:port, extracts the peer certificate, and
# classifies into :up / :degraded / :down based on days until expiry.
# Classification lives in this checker (not PerformCheckJob) because the
# signal is temporal — the documented ownership exception from decision 3.
# The result's metadata carries classification: :up / :degraded / :down
# plus cert_not_after / cert_subject / days_until_expiry. The job's
# derive_status reads metadata[:classification] for :ssl sites.
#
# Classification thresholds:
#   < 8 days   -> :down    (error_message set)
#   8..30 days -> :degraded (error_message nil)
#   > 30 days  -> :up       (error_message nil)
#
# Connection semantics: TCP connect bounded by CONNECT_TIMEOUT via Socket.tcp;
# TLS handshake bounded by HANDSHAKE_TIMEOUT via Timeout.timeout. The Timeout
# wrapper on socket I/O is technically unsafe (async interrupt can leak an FD)
# but the ensure block closes both sockets and the monitoring use case tolerates
# the rare leak.
class SslChecker
  CONNECT_TIMEOUT = 5
  HANDSHAKE_TIMEOUT = 10
  CRITICAL_DAYS = 8
  WARN_DAYS = 30

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
    classification = classify_days(days)
    metadata = cert_metadata(cert, days, classification)
    error = classification == :down ? "cert expires in #{days} days" : nil
    build_outcome(started_at, error: error, metadata: metadata)
  end

  def classify_days(days)
    return :down if days < CRITICAL_DAYS
    return :degraded if days <= WARN_DAYS

    :up
  end

  def days_until_expiry(cert)
    ((cert.not_after - Time.current) / 86_400).to_i
  end

  def cert_metadata(cert, days, classification)
    {
      cert_not_after: cert.not_after,
      cert_subject: cert.subject.to_s,
      days_until_expiry: days,
      classification: classification
    }
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
