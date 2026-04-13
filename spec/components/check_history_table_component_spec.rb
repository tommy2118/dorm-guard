require "rails_helper"

RSpec.describe CheckHistoryTableComponent, type: :component do
  let(:successful_result) do
    CheckResult.new(
      status_code: 200,
      response_time_ms: 123,
      checked_at: 5.minutes.ago,
      error_message: nil
    )
  end

  let(:failed_result) do
    CheckResult.new(
      status_code: nil,
      response_time_ms: 5000,
      checked_at: 1.minute.ago,
      error_message: "Connection timed out"
    )
  end

  it "renders an empty-state message when there are no results" do
    render_inline(described_class.new(results: []))
    expect(page).to have_content("No check history yet")
    expect(page).to have_no_css("table")
  end

  it "renders a table when there are results" do
    render_inline(described_class.new(results: [ successful_result ]))
    expect(page).to have_css("table.table")
    expect(page).to have_css("th", text: "Checked")
    expect(page).to have_css("th", text: "Status code")
    expect(page).to have_css("th", text: "Response time")
    expect(page).to have_css("th", text: "Error")
  end

  it "renders the status code, response time, and relative checked time for a successful result" do
    render_inline(described_class.new(results: [ successful_result ]))
    expect(page).to have_content("200")
    expect(page).to have_content("123 ms")
    expect(page).to have_content("ago")
  end

  it "renders an em-dash for missing status codes and error messages" do
    render_inline(described_class.new(results: [ successful_result ]))
    expect(page).to have_content("—")
  end

  it "renders the error message for a failed result" do
    render_inline(described_class.new(results: [ failed_result ]))
    expect(page).to have_content("Connection timed out")
    expect(page).to have_content("5000 ms")
  end

  it "renders one row per result" do
    render_inline(described_class.new(results: [ successful_result, failed_result ]))
    expect(page).to have_css("tbody tr", count: 2)
  end
end
