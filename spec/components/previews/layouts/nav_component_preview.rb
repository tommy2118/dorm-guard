module Layouts
  class NavComponentPreview < ViewComponent::Preview
    def default
      render(Layouts::NavComponent.new)
    end
  end
end
