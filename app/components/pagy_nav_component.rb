class PagyNavComponent < ApplicationComponent
  def initialize(pagy:)
    @pagy = pagy
  end

  attr_reader :pagy

  def render?
    pagy.pages > 1
  end

  def url_for_page(page)
    helpers.pagy_url_for(pagy, page)
  end
end
