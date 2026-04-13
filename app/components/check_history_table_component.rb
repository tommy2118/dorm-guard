class CheckHistoryTableComponent < ApplicationComponent
  def initialize(results:)
    @results = results
  end

  attr_reader :results

  def empty?
    results.empty?
  end

  def status_code_label(result)
    result.status_code.presence || "—"
  end

  def response_time_label(result)
    "#{result.response_time_ms} ms"
  end

  def error_label(result)
    result.error_message.presence || "—"
  end

  def checked_at_label(result)
    "#{helpers.time_ago_in_words(result.checked_at)} ago"
  end
end
