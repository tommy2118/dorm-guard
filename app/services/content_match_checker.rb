# Content-match check: HTTP GET + body substring assertion. Catches "the
# server is up but serving a blank page" and "the server is returning a
# cached error page."
#
# Wraps HttpChecker — inherits body truncation (1 MiB), scheme whitelist,
# and SsrfGuard Faraday middleware. Passes follow_redirects through so
# Site-level HTTP options apply to content-match sites too.
#
# Classification rule: the match result lives in metadata[:matched] as
# an explicit true/false. The job's derive_status reads metadata[:matched]
# and maps false to :down, so ContentMatchChecker stays in the "return
# raw signals" role per decision 3's health-classification ownership rule.
class ContentMatchChecker
  def self.check(url:, pattern:, follow_redirects: true)
    new.check(url: url, pattern: pattern, follow_redirects: follow_redirects)
  end

  def check(url:, pattern:, follow_redirects: true)
    http_outcome = HttpChecker.check(url, follow_redirects: follow_redirects)
    return http_outcome if http_outcome.error_message.present?

    matched = http_outcome.body.to_s.include?(pattern.to_s)
    CheckOutcome.new(
      status_code: http_outcome.status_code,
      response_time_ms: http_outcome.response_time_ms,
      error_message: nil,
      checked_at: http_outcome.checked_at,
      body: http_outcome.body,
      metadata: { matched: matched, pattern: pattern }
    )
  end
end
