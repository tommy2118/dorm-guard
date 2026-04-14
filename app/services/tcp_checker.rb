require "socket"

# Opens a TCP socket to host:port with a bounded connect timeout, succeeds if
# the connection opens, immediately closes. "Is a port open?" — not "does it
# speak a protocol."
#
# Connection semantics: Socket.tcp(host, port, connect_timeout: N) enforces
# the connect timeout at the socket layer. Do NOT wrap a bare TCPSocket.new
# in Timeout.timeout — Ruby's Timeout uses async interrupts which leak FDs
# on socket operations. Do NOT reinvent the connect_nonblock + IO.select
# dance — Socket.tcp already does it correctly.
class TcpChecker
  CONNECT_TIMEOUT = 5

  RECOVERABLE_ERRORS = [
    IpGuard::BlockedIpError,
    SocketError,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Errno::EADDRNOTAVAIL
  ].freeze

  def self.check(host:, port:)
    new.check(host: host, port: port)
  end

  def check(host:, port:)
    started_at = Time.current
    IpGuard.check!(host)
    Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT, &:close)
    success_outcome(started_at)
  rescue *RECOVERABLE_ERRORS => e
    error_outcome(e, started_at)
  end

  private

  def success_outcome(started_at)
    build_outcome(started_at, error: nil)
  end

  def error_outcome(error, started_at)
    build_outcome(started_at, error: "#{error.class}: #{error.message}")
  end

  def build_outcome(started_at, error:)
    CheckOutcome.new(
      status_code: nil,
      response_time_ms: elapsed_ms(started_at),
      error_message: error,
      checked_at: started_at,
      body: nil,
      metadata: {}
    )
  end

  def elapsed_ms(started_at)
    ((Time.current - started_at) * 1000).round
  end
end
