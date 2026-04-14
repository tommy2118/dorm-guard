require "faraday"

class HttpChecker
  Result = Data.define(:status_code, :response_time_ms, :error_message, :checked_at)

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  def self.check(url)
    new.check(url)
  end

  def check(url)
    started_at = Time.current
    parsed = URI.parse(url)
    raise URI::InvalidURIError, "Unsupported scheme: #{parsed.scheme}" unless %w[http https].include?(parsed.scheme)
    response = connection.get(url)
    success_result(response, started_at)
  rescue Faraday::Error, URI::InvalidURIError => e
    error_result(e, started_at)
  end

  private

  def connection
    Faraday.new do |f|
      f.use SsrfGuard # must come before any redirect middleware added in the future
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout = READ_TIMEOUT
    end
  end

  def success_result(response, started_at)
    Result.new(
      status_code: response.status,
      response_time_ms: elapsed_ms(started_at),
      error_message: nil,
      checked_at: started_at
    )
  end

  def error_result(error, started_at)
    Result.new(
      status_code: nil,
      response_time_ms: elapsed_ms(started_at),
      error_message: "#{error.class}: #{error.message}",
      checked_at: started_at
    )
  end

  def elapsed_ms(started_at)
    ((Time.current - started_at) * 1000).round
  end
end
