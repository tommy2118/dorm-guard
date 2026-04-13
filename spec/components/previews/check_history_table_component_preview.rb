class CheckHistoryTableComponentPreview < ViewComponent::Preview
  def empty
    render(CheckHistoryTableComponent.new(results: []))
  end

  def with_results
    render(CheckHistoryTableComponent.new(results: sample_results))
  end

  private

  def sample_results
    [
      CheckResult.new(status_code: 200, response_time_ms: 123, checked_at: 30.seconds.ago),
      CheckResult.new(status_code: 200, response_time_ms: 145, checked_at: 2.minutes.ago),
      CheckResult.new(status_code: 500, response_time_ms: 1200, checked_at: 5.minutes.ago, error_message: "Upstream 500"),
      CheckResult.new(status_code: nil, response_time_ms: 5000, checked_at: 8.minutes.ago, error_message: "Connection timed out")
    ]
  end
end
