require "rails_helper"

RSpec.describe PagyNavComponent, type: :component do
  def render_at(pagy, path: "/sites")
    with_request_url(path) do
      render_inline(described_class.new(pagy: pagy))
    end
  end

  describe "#render?" do
    it "skips rendering when there is only one page" do
      pagy = Pagy.new(count: 10, page: 1, limit: 25)
      render_at(pagy)
      expect(page).to have_no_css("nav")
    end

    it "renders when there are multiple pages" do
      pagy = Pagy.new(count: 100, page: 1, limit: 25)
      render_at(pagy)
      expect(page).to have_css("nav[aria-label='Pagination']")
    end
  end

  describe "DaisyUI structure" do
    it "wraps the buttons in a DaisyUI join container" do
      pagy = Pagy.new(count: 100, page: 2, limit: 25)
      render_at(pagy)
      expect(page).to have_css("div.join")
      expect(page).to have_css("a.join-item.btn.btn-sm", minimum: 1)
    end
  end

  describe "prev/next buttons" do
    it "renders prev as disabled and next as a link on the first page" do
      pagy = Pagy.new(count: 100, page: 1, limit: 25)
      render_at(pagy)
      expect(page).to have_css("span.btn-disabled", text: "«")
      expect(page).to have_css("a.join-item.btn", text: "»")
    end

    it "renders prev as a link and next as disabled on the last page" do
      pagy = Pagy.new(count: 100, page: 4, limit: 25)
      render_at(pagy)
      expect(page).to have_css("a.join-item.btn", text: "«")
      expect(page).to have_css("span.btn-disabled", text: "»")
    end

    it "renders both prev and next as links on a middle page" do
      pagy = Pagy.new(count: 100, page: 2, limit: 25)
      render_at(pagy)
      expect(page).to have_css("a.join-item.btn", text: "«")
      expect(page).to have_css("a.join-item.btn", text: "»")
    end
  end

  describe "page items" do
    it "marks the current page with btn-active and aria-current" do
      pagy = Pagy.new(count: 100, page: 2, limit: 25)
      render_at(pagy)
      expect(page).to have_css("span.btn-active[aria-current='page']", text: "2")
    end

    it "renders other pages as navigable links" do
      pagy = Pagy.new(count: 100, page: 2, limit: 25)
      render_at(pagy)
      expect(page).to have_css("a.join-item.btn", text: "1")
      expect(page).to have_css("a.join-item.btn", text: "3")
    end

    it "renders a disabled ellipsis for :gap entries in long paginations" do
      pagy = Pagy.new(count: 700, page: 1, limit: 25) # 28 pages → series has a :gap
      render_at(pagy)
      expect(page).to have_css("span.btn-disabled", text: "…")
    end
  end
end
