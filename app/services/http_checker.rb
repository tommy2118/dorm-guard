require "faraday"

class HttpChecker
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10
  BODY_BYTE_CAP = 1_048_576 # 1 MiB

  def self.check(url)
    new.check(url)
  end

  def check(url)
    started_at = Time.current
    parsed = URI.parse(url)
    raise URI::InvalidURIError, "Unsupported scheme: #{parsed.scheme}" unless %w[http https].include?(parsed.scheme)
    response = connection.get(url)
    success_outcome(response, started_at)
  rescue Faraday::Error, URI::InvalidURIError => e
    error_outcome(e, started_at)
  end

  private

  def connection
    Faraday.new do |f|
      f.use SsrfGuard # must come before any redirect middleware added in the future
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout = READ_TIMEOUT
    end
  end

  def success_outcome(response, started_at)
    CheckOutcome.new(
      status_code: response.status,
      response_time_ms: elapsed_ms(started_at),
      error_message: nil,
      checked_at: started_at,
      body: truncate_body(response.body),
      metadata: {}
    )
  end

  def error_outcome(error, started_at)
    CheckOutcome.new(
      status_code: nil,
      response_time_ms: elapsed_ms(started_at),
      error_message: "#{error.class}: #{error.message}",
      checked_at: started_at,
      body: nil,
      metadata: {}
    )
  end

  def truncate_body(body)
    return nil if body.nil?

    truncated = body.to_s.byteslice(0, BODY_BYTE_CAP).dup
    truncated.force_encoding(Encoding::UTF_8).scrub("")
  end

  def elapsed_ms(started_at)
    ((Time.current - started_at) * 1000).round
  end
end
