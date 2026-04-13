require "rails_helper"

RSpec.describe DeleteButtonComponent, type: :component do
  let(:site) do
    Site.create!(
      name: "Production API",
      url: "https://api.example.com",
      interval_seconds: 60
    )
  end

  it "renders a Delete button inside a form targeting the site path" do
    with_request_url "/sites" do
      render_inline(described_class.new(site: site))
    end
    expect(page).to have_css("form[action='/sites/#{site.id}']")
    expect(page).to have_button("Delete")
  end

  it "uses the DELETE HTTP method via Rails hidden _method input" do
    with_request_url "/sites" do
      render_inline(described_class.new(site: site))
    end
    expect(page).to have_css("input[name='_method'][value='delete']", visible: :all)
  end

  it "renders with DaisyUI error button classes" do
    with_request_url "/sites" do
      render_inline(described_class.new(site: site))
    end
    expect(page).to have_css("button.btn.btn-error.btn-sm")
  end

  it "renders a data-turbo-confirm attribute with the site name on the form" do
    with_request_url "/sites" do
      render_inline(described_class.new(site: site))
    end
    expect(page).to have_css("form[data-turbo-confirm='Delete Production API?']")
  end
end
