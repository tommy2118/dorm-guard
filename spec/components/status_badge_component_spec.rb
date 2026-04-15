require "rails_helper"

RSpec.describe StatusBadgeComponent, type: :component do
  it "renders an up status as a success badge" do
    render_inline(described_class.new(status: :up))
    expect(page).to have_css("span.badge.badge-success", text: "up")
  end

  it "renders a down status as an error badge" do
    render_inline(described_class.new(status: :down))
    expect(page).to have_css("span.badge.badge-error", text: "down")
  end

  it "renders a degraded status as a warning badge" do
    render_inline(described_class.new(status: :degraded))
    expect(page).to have_css("span.badge.badge-warning", text: "degraded")
  end

  it "renders an unknown status as a ghost badge" do
    render_inline(described_class.new(status: :unknown))
    expect(page).to have_css("span.badge.badge-ghost", text: "unknown")
  end

  it "falls back to the unknown class set for any unrecognised status" do
    render_inline(described_class.new(status: :pending))
    expect(page).to have_css("span.badge.badge-ghost", text: "pending")
  end

  it "accepts string statuses by coercing to a symbol" do
    render_inline(described_class.new(status: "up"))
    expect(page).to have_css("span.badge.badge-success", text: "up")
  end
end
