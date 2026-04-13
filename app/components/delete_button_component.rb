class DeleteButtonComponent < ApplicationComponent
  def initialize(site:)
    @site = site
  end

  attr_reader :site

  def confirm_message
    "Delete #{site.name}?"
  end
end
