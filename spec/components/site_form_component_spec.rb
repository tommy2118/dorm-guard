require "rails_helper"

RSpec.describe SiteFormComponent, type: :component do
  let(:new_site) { Site.new }
  let(:persisted_site) do
    Site.create!(
      name: "Example",
      url: "https://example.com",
      interval_seconds: 60
    )
  end

  describe "#heading and #submit_label" do
    it "uses the new labels for an unpersisted record" do
      component = described_class.new(site: new_site)
      expect(component.heading).to eq("New site")
      expect(component.submit_label).to eq("Create site")
    end

    it "uses the edit labels for a persisted record" do
      component = described_class.new(site: persisted_site)
      expect(component.heading).to eq("Edit site")
      expect(component.submit_label).to eq("Update site")
    end
  end

  describe "rendering for a new site" do
    before do
      with_request_url "/sites/new" do
        render_inline(described_class.new(site: new_site))
      end
    end

    it "renders the 'New site' heading" do
      expect(page).to have_css("h1", text: "New site")
    end

    it "renders the 'Create site' submit button" do
      expect(page).to have_button("Create site")
    end

    it "renders DaisyUI bordered inputs for name, url, and interval_seconds" do
      expect(page).to have_css("input[name='site[name]'].input.input-bordered")
      expect(page).to have_css("input[name='site[url]'].input.input-bordered")
      expect(page).to have_css("input[name='site[interval_seconds]'].input.input-bordered")
    end

    it "renders a Cancel link to the sites index" do
      expect(page).to have_link("Cancel", href: "/sites")
    end
  end

  describe "rendering with validation errors" do
    it "renders inline errors and input-error classes for invalid fields" do
      invalid_site = Site.new(name: "", url: "not-a-url", interval_seconds: 10)
      invalid_site.valid?

      with_request_url "/sites" do
        render_inline(described_class.new(site: invalid_site))
      end

      expect(page).to have_css("input[name='site[name]'].input-error")
      expect(page).to have_css("input[name='site[url]'].input-error")
      expect(page).to have_css("input[name='site[interval_seconds]'].input-error")
      expect(page).to have_css("p.text-error", minimum: 3)
    end
  end
end
