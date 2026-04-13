require "rails_helper"

RSpec.describe Layouts::NavComponent, type: :component do
  it "renders the dorm-guard brand link to the sites index" do
    with_request_url "/sites" do
      render_inline(described_class.new)
    end
    expect(page).to have_link("dorm-guard", href: "/sites")
  end

  it "renders a Sites nav link" do
    with_request_url "/sites" do
      render_inline(described_class.new)
    end
    expect(page).to have_link("Sites", href: "/sites")
  end

  it "uses DaisyUI navbar classes" do
    with_request_url "/sites" do
      render_inline(described_class.new)
    end
    expect(page).to have_css("div.navbar.bg-base-200")
  end
end
