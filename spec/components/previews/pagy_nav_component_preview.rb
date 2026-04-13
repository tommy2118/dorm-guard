class PagyNavComponentPreview < ViewComponent::Preview
  def first_page_of_four
    render(PagyNavComponent.new(pagy: Pagy.new(count: 100, page: 1, limit: 25)))
  end

  def middle_page_of_four
    render(PagyNavComponent.new(pagy: Pagy.new(count: 100, page: 2, limit: 25)))
  end

  def last_page_of_four
    render(PagyNavComponent.new(pagy: Pagy.new(count: 100, page: 4, limit: 25)))
  end

  def long_pagination_with_gap
    render(PagyNavComponent.new(pagy: Pagy.new(count: 700, page: 1, limit: 25)))
  end

  def single_page_renders_nothing
    render(PagyNavComponent.new(pagy: Pagy.new(count: 10, page: 1, limit: 25)))
  end
end
