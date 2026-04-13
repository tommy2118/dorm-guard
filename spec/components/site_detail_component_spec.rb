require "rails_helper"

RSpec.describe SiteDetailComponent, type: :component do
  let(:site) do
    Site.create!(
      name: "Example",
      url: "https://example.com",
      interval_seconds: 60,
      status: :up,
      last_checked_at: 2.minutes.ago
    )
  end

  it "renders the site name and url as a link" do
    render_inline(described_class.new(site: site))
    expect(page).to have_css("h2", text: "Example")
    expect(page).to have_link("https://example.com", href: "https://example.com")
  end

  it "renders a status badge" do
    render_inline(described_class.new(site: site))
    expect(page).to have_css("span.badge.badge-success", text: "up")
  end

  it "renders the interval in seconds" do
    render_inline(described_class.new(site: site))
    expect(page).to have_content("60 seconds")
  end

  it "renders a 'Never' last-checked label when the site has never been checked" do
    site.last_checked_at = nil
    render_inline(described_class.new(site: site))
    expect(page).to have_content("Never")
  end

  it "renders a relative last-checked label when the site has been checked" do
    render_inline(described_class.new(site: site))
    expect(page).to have_content("ago")
  end
end
